#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

arch=${1:-$(uname -m)}
case "$arch" in
  arm64) swift_arch="arm64" ;;
  x86_64) swift_arch="x86_64" ;;
  *) fail "unsupported architecture: $arch" ;;
esac

require_command swift
require_command xcrun
output="$ARTIFACTS_DIR/swift-$arch"
safe_remove "$output"

printf 'Building app executable for %s...\n' "$arch"
SDKROOT=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
export SDKROOT
swift build \
  --package-path "$PROJECT_ROOT" \
  --configuration release \
  --arch "$swift_arch" \
  --scratch-path "$output"

binary="$output/$swift_arch-apple-macosx/release/ForgeMenuBar"
[ -x "$binary" ] || fail "expected executable not produced: $binary"
validate_macho "$binary" "$swift_arch"
printf '%s\n' "$binary"
