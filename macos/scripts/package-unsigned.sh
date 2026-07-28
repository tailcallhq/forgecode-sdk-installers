#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

[ "$BUILD_FLAVOR" = "unsigned" ] || fail "package-unsigned.sh requires BUILD_FLAVOR=unsigned"
packaging_preflight
run_tests
sh "$SCRIPT_DIR/fetch-forge3.sh"
sh "$SCRIPT_DIR/assemble-app.sh"
sh "$SCRIPT_DIR/verify-release.sh"
sh "$SCRIPT_DIR/create-dmg.sh"
sh "$SCRIPT_DIR/verify-release.sh"
printf 'Unsigned artifacts: %s\n' "$DIST_DIR"
