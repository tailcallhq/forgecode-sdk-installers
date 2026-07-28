#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

require_command lipo

arm="$PROJECT_ROOT/Vendor/forge3/aarch64/forge3-aarch64"
x86="$PROJECT_ROOT/Vendor/forge3/x86_64/forge3-x86_64"
[ -x "$arm" ] || fail "missing staged arm64 forge3 binary; run scripts/fetch-forge3.sh"
[ -x "$x86" ] || fail "missing staged x86_64 forge3 binary; run scripts/fetch-forge3.sh"

output_dir="$ARTIFACTS_DIR/forge3-universal"
output="$output_dir/$HELPER_EXECUTABLE"
safe_remove "$output_dir"
mkdir -p "$output_dir"
lipo -create "$arm" "$x86" -output "$output"
chmod 0755 "$output"
lipo "$output" -verify_arch arm64 x86_64
printf '%s\n' "$output"
