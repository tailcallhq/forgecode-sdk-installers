#!/bin/sh
set -eu

# Downloads the pinned Sparkle release into macos/Vendor/Sparkle. This is a
# one-time setup step for developers and CI, deliberately kept outside
# macos/scripts/ so the packaging pipeline itself stays offline: the offline
# source scanner rejects network commands in packaging scripts, and packaging
# only ever consumes the already-vendored files that this script verifies.
#
# The archive is pinned by exact version and SHA-256, so the vendored bytes
# are as reproducible as a committed copy without polluting the repository
# with binaries. Bump both values together when upgrading Sparkle.

SPARKLE_VERSION="2.9.4"
SPARKLE_SHA256="cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-for-Swift-Package-Manager.zip"

TOOLS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$TOOLS_DIR/.." && pwd)
VENDOR_DIR="$PROJECT_ROOT/Vendor/Sparkle"
STAMP_FILE="$VENDOR_DIR/VERSION"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE")" = "$SPARKLE_VERSION" ] \
  && [ -d "$VENDOR_DIR/Sparkle.xcframework" ] \
  && [ -x "$VENDOR_DIR/bin/sign_update" ] \
  && [ -x "$VENDOR_DIR/bin/generate_appcast" ] \
  && [ -x "$VENDOR_DIR/bin/generate_keys" ]; then
  printf 'Sparkle %s is already vendored at %s\n' "$SPARKLE_VERSION" "$VENDOR_DIR"
  exit 0
fi

command -v curl >/dev/null 2>&1 || fail "required command not found: curl"
command -v unzip >/dev/null 2>&1 || fail "required command not found: unzip"

workdir=$(mktemp -d "${TMPDIR:-/tmp}/sparkle-fetch.XXXXXX")
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT HUP INT TERM

archive="$workdir/sparkle.zip"
curl -fsSL --retry 3 -o "$archive" "$SPARKLE_URL"

actual_sha256=$(shasum -a 256 "$archive" | awk '{print $1}')
[ "$actual_sha256" = "$SPARKLE_SHA256" ] \
  || fail "Sparkle archive checksum mismatch: expected $SPARKLE_SHA256, got $actual_sha256"

unzip -q "$archive" -d "$workdir/extracted"
[ -d "$workdir/extracted/Sparkle.xcframework" ] || fail "Sparkle archive layout changed: Sparkle.xcframework not found"
for tool in sign_update generate_appcast generate_keys; do
  [ -x "$workdir/extracted/bin/$tool" ] || fail "Sparkle archive layout changed: bin/$tool not found"
done

# Strip debug symbols; they are large and packaging never uses them.
rm -rf "$workdir/extracted/Sparkle.xcframework/macos-arm64_x86_64/dSYMs"

staging="$VENDOR_DIR.staging.$$"
rm -rf "$staging"
mkdir -p "$staging/bin"
cp -R "$workdir/extracted/Sparkle.xcframework" "$staging/Sparkle.xcframework"
for tool in sign_update generate_appcast generate_keys; do
  cp "$workdir/extracted/bin/$tool" "$staging/bin/$tool"
  chmod 0755 "$staging/bin/$tool"
done
printf '%s\n' "$SPARKLE_VERSION" > "$staging/VERSION"

rm -rf "$VENDOR_DIR"
mkdir -p "$(dirname "$VENDOR_DIR")"
mv "$staging" "$VENDOR_DIR"
printf 'Vendored Sparkle %s at %s\n' "$SPARKLE_VERSION" "$VENDOR_DIR"
