#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD_FLAVOR=signed
export BUILD_FLAVOR
. "$SCRIPT_DIR/common.sh"
[ -n "${SIGNING_IDENTITY:-}" ] || fail "SIGNING_IDENTITY is required"
[ -n "${NOTARY_PROFILE:-}" ] || fail "NOTARY_PROFILE is required"

packaging_preflight
run_tests
sh "$SCRIPT_DIR/assemble-app.sh"
sh "$SCRIPT_DIR/sign-app.sh"
sh "$SCRIPT_DIR/create-dmg.sh"
sh "$SCRIPT_DIR/sign-dmg.sh"
VERIFY_SIGNATURES=1 VERIFY_NOTARIZATION=0 sh "$SCRIPT_DIR/verify-release.sh"
sh "$SCRIPT_DIR/notarize-dmg.sh"

printf 'Release submitted: %s\nManifest: %s\nChecksums: %s\nNotarization submission: %s\n' "$DMG_PATH" "$MANIFEST_PATH" "$CHECKSUMS_PATH" "$NOTARIZATION_LOG_DIR/dmg-submit.json"
