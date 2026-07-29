#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

require_command xcrun
require_command spctl

profile=${NOTARY_PROFILE:-}
[ -n "$profile" ] || fail "NOTARY_PROFILE is required (created with notarytool store-credentials)"
[ -f "$DMG_PATH" ] || fail "DMG is missing; run scripts/create-dmg.sh"
submission_json="$NOTARIZATION_LOG_DIR/dmg-submit.json"
safe_remove "$submission_json"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$profile" --wait --output-format json > "$submission_json"
submission_id=$(plutil -extract id raw -o - "$submission_json" 2>/dev/null || true)
status=$(plutil -extract status raw -o - "$submission_json" 2>/dev/null || true)
[ "$status" = "Accepted" ] || fail "DMG notarization was not accepted (status: ${status:-unknown}; see $submission_json)"
if [ -n "$submission_id" ]; then
  xcrun notarytool log "$submission_id" --keychain-profile "$profile" "$NOTARIZATION_LOG_DIR/dmg-$submission_id.json" || true
fi
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
finalize_release_metadata
