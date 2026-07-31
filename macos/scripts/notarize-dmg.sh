#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

require_command xcrun
require_command plutil

profile=${NOTARY_PROFILE:-}
[ -n "$profile" ] || fail "NOTARY_PROFILE is required (created with notarytool store-credentials)"
[ -f "$DMG_PATH" ] || fail "DMG is missing; run scripts/create-dmg.sh"
submission_json="$NOTARIZATION_LOG_DIR/dmg-submit.json"
safe_remove "$submission_json"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$profile" --no-wait --output-format json > "$submission_json"
submission_id=$(plutil -extract id raw -o - "$submission_json" 2>/dev/null || true)
[ -n "$submission_id" ] || fail "DMG notarization submission did not return an id; see $submission_json"
printf '%s\n' "$submission_id"
