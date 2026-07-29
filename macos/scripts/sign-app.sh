#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

require_command codesign

identity=${SIGNING_IDENTITY:-}
team_id=${SIGNING_TEAM_ID:-}
[ -n "$identity" ] || fail "SIGNING_IDENTITY is required (Developer ID Application: …)"
[ -d "$APP_BUNDLE" ] || fail "app bundle is missing; run scripts/assemble-app.sh"
[ -f "$ENTITLEMENTS_FILE" ] || fail "entitlements file is missing: $ENTITLEMENTS_FILE"
plutil -lint "$ENTITLEMENTS_FILE" >/dev/null
security find-identity -v -p codesigning | grep -F "$identity" >/dev/null || fail "configured signing identity is not available: $identity"

# Sign the executable explicitly, then seal the outer bundle. Avoid --deep so
# any future nested code must be added deliberately and remains visible.
codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS_FILE" --sign "$identity" \
  "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE"
codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS_FILE" --sign "$identity" \
  "$APP_BUNDLE"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
actual_team=$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')
if [ -n "$team_id" ]; then
  [ "$actual_team" = "$team_id" ] || fail "signed app team mismatch: expected $team_id, got ${actual_team:-none}"
fi
actual_entitlements="$ARTIFACTS_DIR/signed-app-entitlements.plist"
codesign -d --entitlements :- "$APP_BUNDLE" > "$actual_entitlements" 2>/dev/null
plutil -lint "$actual_entitlements" >/dev/null
verify_app_inventory "$APP_BUNDLE"
write_manifest
verify_manifest
safe_remove "$CHECKSUMS_PATH"
printf '%s\n' "$APP_BUNDLE"
