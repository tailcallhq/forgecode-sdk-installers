#!/bin/sh
set -eu

# Build and Developer ID sign the release DMG. Notarization is deliberately
# performed by the release workflow on Linux after this script completes, and
# stapling/final validation are deliberately performed by a later macOS job.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD_FLAVOR=signed
export BUILD_FLAVOR
. "$SCRIPT_DIR/common.sh"
[ -n "${SIGNING_IDENTITY:-}" ] || fail "SIGNING_IDENTITY is required"

packaging_preflight
run_tests
sh "$SCRIPT_DIR/assemble-app.sh"
sh "$SCRIPT_DIR/sign-app.sh"
sh "$SCRIPT_DIR/create-dmg.sh"
sh "$SCRIPT_DIR/sign-dmg.sh"
VERIFY_SIGNATURES=1 VERIFY_DMG_NOTARIZATION=0 sh "$SCRIPT_DIR/verify-release.sh"

printf 'Signed release ready for notarization: %s\nManifest: %s\nChecksums: %s\n' \
  "$DMG_PATH" "$MANIFEST_PATH" "$CHECKSUMS_PATH"
