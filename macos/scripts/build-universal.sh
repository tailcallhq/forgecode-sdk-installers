#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

require_command lipo

# The two slices are independent release builds against separate scratch paths,
# so they run concurrently. This roughly halves the dominant cost of packaging.
# Each slice logs to its own file so interleaved output stays readable, and the
# logs are replayed in a deterministic order once both have finished.
arm_log="$ARTIFACTS_DIR/build-thin-arm64.$$.log"
x86_log="$ARTIFACTS_DIR/build-thin-x86_64.$$.log"
arm_result="$ARTIFACTS_DIR/build-thin-arm64.$$.path"
x86_result="$ARTIFACTS_DIR/build-thin-x86_64.$$.path"
safe_remove "$arm_log" "$x86_log" "$arm_result" "$x86_result"
cleanup() { safe_remove "$arm_log" "$x86_log" "$arm_result" "$x86_result"; }
trap cleanup EXIT HUP INT TERM

sh "$SCRIPT_DIR/build-thin.sh" arm64 > "$arm_result" 2> "$arm_log" &
arm_pid=$!
sh "$SCRIPT_DIR/build-thin.sh" x86_64 > "$x86_result" 2> "$x86_log" &
x86_pid=$!

arm_status=0
x86_status=0
wait "$arm_pid" || arm_status=$?
wait "$x86_pid" || x86_status=$?

cat "$arm_log" >&2
cat "$x86_log" >&2
[ "$arm_status" -eq 0 ] || fail "arm64 slice build failed"
[ "$x86_status" -eq 0 ] || fail "x86_64 slice build failed"

arm_binary=$(tail -n 1 "$arm_result")
x86_binary=$(tail -n 1 "$x86_result")
[ -x "$arm_binary" ] || fail "arm64 slice is missing: $arm_binary"
[ -x "$x86_binary" ] || fail "x86_64 slice is missing: $x86_binary"

output_dir="$ARTIFACTS_DIR/swift-universal"
output="$output_dir/$APP_EXECUTABLE"
safe_remove "$output_dir"
mkdir -p "$output_dir"

lipo -create "$arm_binary" "$x86_binary" -output "$output"
chmod 0755 "$output"
lipo "$output" -verify_arch arm64 x86_64
printf '%s\n' "$output"
