#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

require_command ditto
require_command xcrun
require_command spctl

profile=${NOTARY_PROFILE:-}
[ -n "$profile" ] || fail "NOTARY_PROFILE is required (created with notarytool store-credentials)"
[ -d "$APP_BUNDLE" ] || fail "app bundle is missing"

archive="$ARTIFACTS_DIR/ForgeMenuBar-notarization.zip"
submission_json="$NOTARIZATION_LOG_DIR/app-submit.json"
safe_remove "$archive" "$submission_json"
ditto -c -k --keepParent "$APP_BUNDLE" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait --output-format json > "$submission_json"
submission_id=$(plutil -extract id raw -o - "$submission_json" 2>/dev/null || true)
status=$(plutil -extract status raw -o - "$submission_json" 2>/dev/null || true)
[ "$status" = "Accepted" ] || fail "app notarization was not accepted (status: ${status:-unknown}; see $submission_json)"
if [ -n "$submission_id" ]; then
  xcrun notarytool log "$submission_id" --keychain-profile "$profile" "$NOTARIZATION_LOG_DIR/app-$submission_id.json" || true
fi
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"
spctl --assess --type execute --verbose=4 "$APP_BUNDLE"
