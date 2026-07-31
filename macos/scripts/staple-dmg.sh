#!/bin/sh
set -eu

# Staple Apple's already-issued ticket to a previously signed and accepted DMG,
# then validate the exact final bytes that are eligible for publication.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD_FLAVOR=signed
export BUILD_FLAVOR
. "$SCRIPT_DIR/common.sh"

require_command xcrun

[ -f "$DMG_PATH" ] || fail "accepted DMG is missing: $DMG_PATH"
[ "$(signature_kind "$DMG_PATH")" = "developer-id" ] \
  || fail "accepted DMG is not Developer ID signed"

xcrun stapler staple "$DMG_PATH"

# Stapling changes the DMG bytes, so checksums must be regenerated only after
# the ticket is attached. The comprehensive verifier validates the final DMG.
finalize_release_metadata
VERIFY_SIGNATURES=1 VERIFY_DMG_NOTARIZATION=1 sh "$SCRIPT_DIR/verify-release.sh"

printf 'Stapled and validated release DMG: %s\n' "$DMG_PATH"
