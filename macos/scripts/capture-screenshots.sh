#!/bin/sh
set -eu

# Renders the menu panel and writes PNGs for visual review.
#
# The panel's backdrop is chosen at runtime: Liquid Glass (NSGlassEffectView) on
# macOS 26, the legacy NSVisualEffectView material below it. Neither source
# review nor the unit tests can show what that actually looks like.
#
# The app supports macOS 13 and later, so the fallback needs reviewing too. Two
# mechanisms cover that, because neither alone is sufficient:
#
#   1. On macOS 26 the harness also forces the legacy material, so both appear
#      in one run. That checks the fallback's own layout and colours.
#   2. CI additionally runs this same binary on older runners. Only a real
#      older AppKit shows how the fallback truly composites -- forcing the
#      backend on 26 still leaves you on macOS 26's AppKit.
#
# Hence BINARY: the executable is built once against the newest SDK and then
# handed to older runners, which is exactly how the shipped app reaches users.
# When BINARY is unset the script builds from source, which requires an SDK new
# enough for the macOS 26 symbols.
#
# This is a review aid, not a gate. The workflow marks the step
# continue-on-error: a capture failure says nothing about whether the app works.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

OUTPUT_DIR=${OUTPUT_DIR:-"$DIST_ROOT/screenshots"}
safe_remove "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

if [ -n "${BINARY:-}" ]; then
  binary=$BINARY
  printf 'Using prebuilt executable: %s\n' "$binary"
else
  printf 'Building app executable for screenshots...\n'
  swift build --package-path "$PROJECT_ROOT" --configuration debug --product ForgeMenuBar
  binary="$PROJECT_ROOT/.build/debug/ForgeMenuBar"
fi
[ -x "$binary" ] || fail "screenshot executable is missing or not executable: $binary"

# Recorded alongside the images so a reviewer can tell which OS produced them.
os_version=$(sw_vers -productVersion)
printf 'Capturing on macOS %s\n' "$os_version"

# Screen capture needs a window server. A CI runner's default shell session is
# not attached to one, so the binary is launched through `launchctl asuser` in
# the console user's GUI session. Without this the process gets a null graphics
# context and every capture comes back empty.
console_uid=$(stat -f %u /dev/console 2>/dev/null || echo "")
if [ -z "$console_uid" ]; then
  fail "could not determine the console user; no GUI session to render in"
fi
printf 'Rendering in GUI session for uid %s...\n' "$console_uid"

# Launches the app once for a single shot, bounded by its own timeout.
#
# One process per shot: a single process looping over every shot wedged after
# the first capture on CI, and one hang then cost the entire run. Isolating them
# means a wedge costs one image, and each capture starts from clean process
# state. $1 is the shot index, or empty to ask the app for the shot count.
run_shot() {
  shot_index=${1:-}
  set +e
  if [ -n "$shot_index" ]; then
    launchctl asuser "$console_uid" \
      env FORGE_SCREENSHOT_DIR="$OUTPUT_DIR" FORGE_SCREENSHOT_INDEX="$shot_index" \
      "$binary" &
  else
    launchctl asuser "$console_uid" \
      env FORGE_SCREENSHOT_DIR="$OUTPUT_DIR" \
      "$binary" >"$OUTPUT_DIR/.plan" &
  fi
  app_pid=$!

  waited=0
  while kill -0 "$app_pid" 2>/dev/null; do
    if [ "$waited" -ge 30 ]; then
      printf 'shot %s exceeded 30s; terminating.\n' "${shot_index:-plan}" >&2
      kill -TERM "$app_pid" 2>/dev/null
      sleep 1
      kill -KILL "$app_pid" 2>/dev/null
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$app_pid" 2>/dev/null
  set -e
}

# Ask the app how many shots this OS can produce. The count varies: macOS 26
# renders both the glass and the forced fallback, older systems only the latter.
run_shot ""
shot_count=$(tr -dc '0-9' <"$OUTPUT_DIR/.plan" 2>/dev/null || echo "")
rm -f "$OUTPUT_DIR/.plan"
if [ -z "$shot_count" ] || [ "$shot_count" -eq 0 ] 2>/dev/null; then
  fail "could not determine the shot count; the app did not report a plan"
fi
printf 'Capturing %s shot(s), one process each...\n' "$shot_count"

# Retried once because failures observed on CI were sporadic and per-process
# rather than systematic: a run produced 17 of 20, with the gaps scattered
# rather than clustered. Shots are independent, so re-running one is safe and
# cannot corrupt the others.
i=0
while [ "$i" -lt "$shot_count" ]; do
  before=$(find "$OUTPUT_DIR" -name '*.png' -type f | wc -l | tr -d ' ')
  run_shot "$i"
  after=$(find "$OUTPUT_DIR" -name '*.png' -type f | wc -l | tr -d ' ')
  if [ "$after" -eq "$before" ]; then
    printf 'shot %s produced no image; retrying once.\n' "$i" >&2
    run_shot "$i"
  fi
  i=$((i + 1))
done

count=$(find "$OUTPUT_DIR" -name '*.png' -type f | wc -l | tr -d ' ')
if [ "$count" -eq 0 ]; then
  fail "no screenshots were produced in $OUTPUT_DIR"
fi
if [ "$count" -lt "$shot_count" ]; then
  printf 'WARNING: %s of %s shots produced an image.\n' "$count" "$shot_count" >&2
fi

if [ -f "$OUTPUT_DIR/environment.txt" ]; then
  printf '\n--- capture environment ---\n'
  cat "$OUTPUT_DIR/environment.txt"
fi

printf '\nWrote %s screenshot(s) for macOS %s to %s\n' "$count" "$os_version" "$OUTPUT_DIR"
find "$OUTPUT_DIR" -type f | sort
