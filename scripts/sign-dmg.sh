#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

require_command codesign

identity=${SIGNING_IDENTITY:-}
[ -n "$identity" ] || fail "SIGNING_IDENTITY is required (Developer ID Application: …)"
[ -f "$DMG_PATH" ] || fail "DMG is missing; run scripts/create-dmg.sh"
codesign --force --timestamp --sign "$identity" "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"
if [ -n "${SIGNING_TEAM_ID:-}" ]; then
  actual_team=$(codesign -dv --verbose=4 "$DMG_PATH" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')
  [ "$actual_team" = "$SIGNING_TEAM_ID" ] || fail "signed DMG team mismatch: expected $SIGNING_TEAM_ID, got ${actual_team:-none}"
fi
write_manifest
generate_checksums
