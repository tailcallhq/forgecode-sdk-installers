#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
export PROJECT_ROOT

. "$SCRIPT_DIR/versions.sh"

ARTIFACTS_DIR=${ARTIFACTS_DIR:-"$PROJECT_ROOT/.build-artifacts"}
DIST_ROOT=${DIST_ROOT:-"$PROJECT_ROOT/dist"}
APP_NAME="ForgeCode"
BUNDLE_ID="dev.forgecode.menubar"
APP_VERSION=${APP_VERSION:-"$APP_VERSION_DEFAULT"}
BUILD_NUMBER=${BUILD_NUMBER:-"1"}
MINIMUM_MACOS_VERSION=${MINIMUM_MACOS_VERSION:-"13.0"}
APP_EXECUTABLE="ForgeMenuBar"
HELPER_EXECUTABLE="forge3"
INFO_PLIST_TEMPLATE="$PROJECT_ROOT/packaging/Info.plist.in"
ENTITLEMENTS_FILE="$PROJECT_ROOT/packaging/ForgeMenuBar.entitlements"
DMG_NAME=${DMG_NAME:-"ForgeCode-$APP_VERSION"}
BUILD_FLAVOR=${BUILD_FLAVOR:-unsigned}
case "$BUILD_FLAVOR" in
  unsigned|signed) ;;
  *) printf 'error: BUILD_FLAVOR must be unsigned or signed\n' >&2; exit 1 ;;
esac
DIST_DIR=${DIST_DIR:-"$DIST_ROOT/$BUILD_FLAVOR"}
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$DMG_NAME.dmg"
MANIFEST_PATH="$DIST_DIR/manifest.txt"
CHECKSUMS_PATH="$DIST_DIR/SHA256SUMS"
NOTARIZATION_LOG_DIR="$ARTIFACTS_DIR/notarization-logs"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

canonical_path() {
  require_command python3
  python3 - "$1" <<'PY'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
}

CANONICAL_PROJECT_ROOT=$(canonical_path "$PROJECT_ROOT")

assert_inside_project() {
  target=$(canonical_path "$1")
  case "$target" in
    "$CANONICAL_PROJECT_ROOT"/*) ;;
    *) fail "refusing destructive operation outside project: $1 resolves to $target" ;;
  esac
  [ "$target" != "$CANONICAL_PROJECT_ROOT" ] || fail "refusing destructive operation on project root"
}

safe_remove() {
  [ "$#" -gt 0 ] || fail "safe_remove requires at least one path"
  for target in "$@"; do
    [ -n "$target" ] || fail "refusing to remove an empty path"
    assert_inside_project "$target"
  done
  rm -rf -- "$@"
}

validate_release_inputs() {
  printf '%s\n' "$APP_VERSION" | awk '/^[0-9]+([.][0-9]+){0,2}$/ { ok=1 } END { exit !ok }' \
    || fail "APP_VERSION must contain one to three dot-separated numeric components"
  printf '%s\n' "$BUILD_NUMBER" | awk '/^[0-9]+([.][0-9]+){0,2}$/ { ok=1 } END { exit !ok }' \
    || fail "BUILD_NUMBER must contain one to three dot-separated numeric components"
  printf '%s\n' "$MINIMUM_MACOS_VERSION" | awk '/^[0-9]+([.][0-9]+){1,2}$/ { ok=1 } END { exit !ok }' \
    || fail "MINIMUM_MACOS_VERSION must contain two or three numeric components"
}

packaging_preflight() {
  validate_release_inputs
  mkdir -p "$ARTIFACTS_DIR" "$DIST_ROOT" "$NOTARIZATION_LOG_DIR"
  safe_remove "$DIST_ROOT/$APP_NAME.app"
  for legacy_dmg in "$DIST_ROOT"/ForgeMenuBar-*.dmg "$DIST_ROOT"/ForgeCode-*.dmg; do
    [ -e "$legacy_dmg" ] || [ -L "$legacy_dmg" ] || continue
    safe_remove "$legacy_dmg"
  done
}

validate_release_inputs
assert_inside_project "$ARTIFACTS_DIR"
assert_inside_project "$DIST_ROOT"
assert_inside_project "$DIST_DIR"
assert_inside_project "$NOTARIZATION_LOG_DIR"
mkdir -p "$ARTIFACTS_DIR" "$DIST_DIR" "$NOTARIZATION_LOG_DIR"

run_tests() {
  require_command swift
  printf 'Running mandatory Swift tests...\n'
  swift test --package-path "$PROJECT_ROOT"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

binary_arches() {
  lipo -archs "$1" 2>/dev/null || true
}

minimum_macos_for_arch() {
  binary=$1
  arch=$2
  otool -arch "$arch" -l "$binary" 2>/dev/null | awk '
    /LC_BUILD_VERSION/ { in_build=1; in_old=0; next }
    in_build && /minos/ { print $2; exit }
    /LC_VERSION_MIN_MACOSX/ { in_old=1; in_build=0; next }
    in_old && /version/ { print $2; exit }
  '
}

version_le() {
  awk -v left="$1" -v right="$2" 'BEGIN {
    split(left, a, "."); split(right, b, ".")
    for (i = 1; i <= 4; i++) {
      av = (a[i] == "" ? 0 : a[i]) + 0
      bv = (b[i] == "" ? 0 : b[i]) + 0
      if (av < bv) exit 0
      if (av > bv) exit 1
    }
    exit 0
  }'
}

validate_macho() {
  binary=$1
  shift
  [ -x "$binary" ] || fail "executable is missing: $binary"
  require_command lipo
  require_command otool
  for arch in "$@"; do
    lipo "$binary" -verify_arch "$arch" || fail "$binary is missing $arch"
    minos=$(minimum_macos_for_arch "$binary" "$arch")
    [ -n "$minos" ] || fail "could not determine minimum macOS for $binary ($arch)"
    version_le "$minos" "$MINIMUM_MACOS_VERSION" || fail "$binary ($arch) requires macOS $minos, above declared $MINIMUM_MACOS_VERSION"
  done
  unexpected=$(otool -L "$binary" | awk '/^[[:space:]]+\// || /^[[:space:]]+@/ {print $1}' | awk '!/^\/System\/Library\// && !/^\/usr\/lib\// && !/^@rpath\// && !/^@loader_path\// && !/^@executable_path\// {print}')
  [ -z "$unexpected" ] || fail "$binary has unexpected external dependencies: $unexpected"
}

write_manifest() {
  [ -d "$APP_BUNDLE" ] || fail "app bundle is missing"
  safe_remove "$MANIFEST_PATH"
  {
    printf 'app_name=%s\n' "$APP_NAME"
    printf 'bundle_id=%s\n' "$BUNDLE_ID"
    printf 'app_version=%s\n' "$APP_VERSION"
    printf 'build_number=%s\n' "$BUILD_NUMBER"
    printf 'minimum_macos=%s\n' "$MINIMUM_MACOS_VERSION"
    printf 'forge3_version=%s\n' "$FORGE3_VERSION"
    printf 'build_flavor=%s\n' "$BUILD_FLAVOR"
    printf 'app_executable_arches=%s\n' "$(binary_arches "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE")"
    printf 'helper_arches=%s\n' "$(binary_arches "$APP_BUNDLE/Contents/Helpers/$HELPER_EXECUTABLE")"
  } > "$MANIFEST_PATH"
}

generate_checksums() {
  [ -d "$APP_BUNDLE" ] || fail "app bundle is missing"
  safe_remove "$CHECKSUMS_PATH"
  for artifact in "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE" "$APP_BUNDLE/Contents/Helpers/$HELPER_EXECUTABLE" "$DMG_PATH"; do
    [ -f "$artifact" ] || continue
    printf '%s  %s\n' "$(sha256_file "$artifact")" "${artifact#$DIST_DIR/}" >> "$CHECKSUMS_PATH"
  done
}

verify_checksums() {
  [ -s "$CHECKSUMS_PATH" ] || fail "checksums are missing or empty: $CHECKSUMS_PATH"
  while IFS= read -r line; do
    expected=${line%%  *}
    relative=${line#*  }
    [ "$relative" != "$line" ] || fail "malformed checksum line"
    [ -n "$expected" ] && [ -n "$relative" ] || fail "malformed checksum line"
    case "$relative" in
      /*|../*|*/../*|*/..|..|*\\*) fail "unsafe checksum path: $relative" ;;
    esac
    artifact="$DIST_DIR/$relative"
    assert_inside_project "$artifact"
    [ -f "$artifact" ] || fail "checksummed artifact is missing: $relative"
    actual=$(sha256_file "$artifact")
    [ "$actual" = "$expected" ] || fail "checksum mismatch for $relative"
  done < "$CHECKSUMS_PATH"
}

verify_app_bundle_matches() {
  expected=$1
  actual=$2
  [ -d "$expected" ] || fail "expected app bundle is missing: $expected"
  [ -d "$actual" ] || fail "actual app bundle is missing: $actual"
  python3 - "$expected" "$actual" <<'PY' || fail "mounted DMG app bundle differs from staged app"
import hashlib
import os
import stat
import sys

left, right = map(os.path.abspath, sys.argv[1:])

def inventory(root):
    result = {}
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        names = list(directories) + list(files)
        for name in names:
            path = os.path.join(current, name)
            relative = os.path.relpath(path, root)
            info = os.lstat(path)
            mode = stat.S_IMODE(info.st_mode)
            if stat.S_ISLNK(info.st_mode):
                result[relative] = ("link", mode, os.readlink(path))
                if name in directories:
                    directories.remove(name)
            elif stat.S_ISDIR(info.st_mode):
                result[relative] = ("dir", mode)
            elif stat.S_ISREG(info.st_mode):
                digest = hashlib.sha256()
                with open(path, "rb") as handle:
                    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                        digest.update(chunk)
                result[relative] = ("file", mode, info.st_size, digest.hexdigest())
            else:
                result[relative] = ("other", mode)
    return result

left_inventory = inventory(left)
right_inventory = inventory(right)
if left_inventory != right_inventory:
    left_keys = set(left_inventory)
    right_keys = set(right_inventory)
    for path in sorted(left_keys - right_keys):
        print(f"missing from mounted app: {path}", file=sys.stderr)
    for path in sorted(right_keys - left_keys):
        print(f"unexpected in mounted app: {path}", file=sys.stderr)
    for path in sorted(left_keys & right_keys):
        if left_inventory[path] != right_inventory[path]:
            print(f"different app member: {path}", file=sys.stderr)
    raise SystemExit(1)
PY
}

attach_plist_value() {
  python3 - "$1" "$2" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as handle:
    entities = plistlib.load(handle).get("system-entities", [])
key = sys.argv[2]
for entity in entities:
    value = entity.get(key)
    if value:
        print(value)
        break
PY
}

verify_signed_app() {
  app=$1
  codesign --verify --deep --strict --verbose=2 "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=4 "$app"
  if [ -n "${SIGNING_TEAM_ID:-}" ]; then
    actual_team=$(codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')
    [ "$actual_team" = "$SIGNING_TEAM_ID" ] \
      || fail "signed app team mismatch: expected $SIGNING_TEAM_ID, got ${actual_team:-none}"
  fi
}
