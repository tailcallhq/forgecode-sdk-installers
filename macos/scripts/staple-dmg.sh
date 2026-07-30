#!/bin/sh
set -eu

# Poll Apple's notary service for a previously submitted DMG and, once the
# submission is Accepted, staple the ticket to the DMG and verify it. This is
# the decoupled second half of notarization: scripts/submit-dmg.sh performs a
# non-blocking `notarytool submit --no-wait`, and this script (driven by the
# scheduled finalize workflow) finishes the job without the build ever having
# blocked on Apple.
#
# Exit status communicates the outcome to the finalize workflow, which is
# careful to only report a *rejection* (and fail red for that reason) on a
# definite Apple verdict, so transient/infra flakes never post a false
# "rejected" and never publish:
#   0   -> Accepted and stapled; the DMG is ready to publish.
#   75  -> Not terminal yet (In Progress, or a transient error such as a failed
#          `notarytool info` call or an unknown status); retry next cron tick.
#   1   -> Definite Apple Invalid/Rejected verdict; CI must fail and report it.
#   >1  -> Local/infra hard error (missing DMG, staple/verify failure, etc.);
#          CI fails but this is NOT reported as an Apple rejection.
#
# Inputs:
#   NOTARY_PROFILE       keychain profile created with notarytool store-credentials (required)
#   SUBMISSION_ID        notary submission UUID (optional; falls back to the id
#                        recorded next to the DMG by submit-dmg.sh)

EXIT_IN_PROGRESS=75
EXIT_REJECTED=1
EXIT_LOCAL_ERROR=2

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

# Local/infra failures must NOT collide with EXIT_REJECTED (1), which the
# finalize workflow treats as a definite Apple rejection. Every guard and
# verification failure in this script therefore uses local_fail (exit 2); only
# the explicit Invalid/Rejected verdict below exits 1.
local_fail() {
  printf 'error: %s\n' "$*" >&2
  exit "$EXIT_LOCAL_ERROR"
}

command -v xcrun >/dev/null 2>&1 || local_fail "required command not found: xcrun"

profile=${NOTARY_PROFILE:-}
[ -n "$profile" ] || local_fail "NOTARY_PROFILE is required (created with notarytool store-credentials)"
[ -f "$DMG_PATH" ] || local_fail "DMG is missing: $DMG_PATH"

submission_id=${SUBMISSION_ID:-}
if [ -z "$submission_id" ]; then
  [ -f "$SUBMISSION_ID_PATH" ] || local_fail "no submission id provided and none recorded at $SUBMISSION_ID_PATH"
  submission_id=$(tr -d '[:space:]' < "$SUBMISSION_ID_PATH")
fi
[ -n "$submission_id" ] || local_fail "notary submission id is empty"

info_json="$NOTARIZATION_LOG_DIR/dmg-info.json"
safe_remove "$info_json"
# A failed `notarytool info` (network/service blip) is transient, not a
# rejection: report retry so the next cron tick tries again.
if ! xcrun notarytool info "$submission_id" --keychain-profile "$profile" --output-format json > "$info_json"; then
  printf 'notarytool info failed for %s (transient); retry later.\n' "$submission_id" >&2
  exit "$EXIT_IN_PROGRESS"
fi
status=$(plutil -extract status raw -o - "$info_json" 2>/dev/null || true)

case "$status" in
  Accepted)
    ;;
  "In Progress")
    printf 'Notarization still in progress for %s; retry later.\n' "$submission_id"
    exit "$EXIT_IN_PROGRESS"
    ;;
  Invalid|Rejected)
    # Definite Apple verdict: fail with the dedicated rejection code so the
    # finalize workflow reports it and stops retrying.
    log_json="$NOTARIZATION_LOG_DIR/dmg-$submission_id.json"
    xcrun notarytool log "$submission_id" --keychain-profile "$profile" "$log_json" || true
    [ -f "$log_json" ] && cat "$log_json" >&2 || true
    printf 'error: notarization was not accepted (status: %s; see %s)\n' "$status" "$log_json" >&2
    exit "$EXIT_REJECTED"
    ;;
  *)
    # Empty or unrecognized status is treated as not-yet-terminal, not a
    # rejection, so a surprising transient response just retries.
    printf 'unexpected/non-terminal notarization status: %s (see %s); retry later.\n' "${status:-unknown}" "$info_json" >&2
    exit "$EXIT_IN_PROGRESS"
    ;;
esac

# Accepted. Everything below is local work (staple + verify). Any failure here
# is a local/infra error, NOT an Apple rejection, so a single trap installed now
# remaps every non-zero exit for the rest of the script to EXIT_LOCAL_ERROR (2)
# and cleans up the verification mount. This keeps exit code 1 reserved for the
# definite Apple rejection handled above.
device=
verify_mount="$ARTIFACTS_DIR/staple-verify-mount.$$"
attach_plist="$ARTIFACTS_DIR/staple-verify-attach.$$.plist"
cleanup() {
  cleanup_status=$?
  if [ -n "$device" ]; then
    detach_and_cleanup "$device" "$verify_mount" "$attach_plist" || cleanup_status=1
  else
    safe_remove_unmounted "$verify_mount" 2>/dev/null || true
    safe_remove "$attach_plist" 2>/dev/null || true
  fi
  [ "$cleanup_status" -eq 0 ] || cleanup_status=$EXIT_LOCAL_ERROR
  exit "$cleanup_status"
}
trap cleanup EXIT HUP INT TERM

# Capture the log for the record, then staple and verify the DMG itself.
xcrun notarytool log "$submission_id" --keychain-profile "$profile" \
  "$NOTARIZATION_LOG_DIR/dmg-$submission_id.json" || true
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
require_command spctl
require_command hdiutil
hdiutil verify "$DMG_PATH" >/dev/null
[ "$(signature_kind "$DMG_PATH")" = "developer-id" ] || fail "stapled DMG is not Developer ID signed"
codesign --verify --strict --verbose=2 "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

# Verify the notarized payload by mounting the stapled DMG. This is
# self-contained (no standalone app bundle is required, which the finalize
# workflow does not carry): stapling rewrites only the DMG's own bytes, and the
# app inside is now recursively notarized, so Gatekeeper assesses it as trusted
# even though the individual ticket lives on the DMG.
BUILD_FLAVOR=signed
export BUILD_FLAVOR
safe_remove_unmounted "$verify_mount"
safe_remove "$attach_plist"
mkdir -p "$verify_mount"
hdiutil attach -plist -readonly -noverify -noautoopen -mountpoint "$verify_mount" "$DMG_PATH" > "$attach_plist"
device=$(attach_plist_value "$attach_plist" dev-entry)
[ -n "$device" ] || fail "could not mount stapled DMG for verification"
verify_dmg_inventory "$verify_mount"
mounted_app="$verify_mount/$APP_NAME.app"
[ "$(signature_kind "$mounted_app")" = "developer-id" ] || fail "app inside stapled DMG is not Developer ID signed"
codesign --verify --deep --strict --verbose=2 "$mounted_app"
spctl --assess --type execute --verbose=4 "$mounted_app" || fail "notarized app inside DMG failed Gatekeeper assessment"
if [ -n "${SIGNING_TEAM_ID:-}" ]; then
  actual_team=$(codesign -dv --verbose=4 "$mounted_app" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')
  [ "$actual_team" = "$SIGNING_TEAM_ID" ] || fail "app team mismatch: expected $SIGNING_TEAM_ID, got ${actual_team:-none}"
fi
detach_and_cleanup "$device" "$verify_mount" "$attach_plist" || fail "could not detach verification mount"
device=
trap - EXIT HUP INT TERM

printf 'Notarization accepted and stapled: %s\n' "$DMG_PATH"
