#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

require_command lipo

arm_binary=$(sh "$SCRIPT_DIR/build-thin.sh" arm64 | tail -n 1)
x86_binary=$(sh "$SCRIPT_DIR/build-thin.sh" x86_64 | tail -n 1)
output_dir="$ARTIFACTS_DIR/swift-universal"
output="$output_dir/$APP_EXECUTABLE"
safe_remove "$output_dir"
mkdir -p "$output_dir"

lipo -create "$arm_binary" "$x86_binary" -output "$output"
chmod 0755 "$output"
lipo "$output" -verify_arch arm64 x86_64
printf '%s\n' "$output"
