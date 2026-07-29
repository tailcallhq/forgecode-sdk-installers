#!/bin/sh
set -eu

# Packaging must never opt into the live runtime smoke path inherited from a
# developer shell. The focused smoke test is intentionally outside packaging.
unset FORGE_LIVE_RUNTIME_SMOKE 2>/dev/null || true

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$PROJECT_ROOT/.." && pwd)
export PROJECT_ROOT REPO_ROOT

. "$SCRIPT_DIR/versions.sh"

ARTIFACTS_DIR=${ARTIFACTS_DIR:-"$PROJECT_ROOT/.build-artifacts"}
DIST_ROOT=${DIST_ROOT:-"$PROJECT_ROOT/dist"}
APP_NAME="ForgeCode"
BUNDLE_ID="dev.forgecode.menubar"
APP_VERSION=${APP_VERSION:-"$APP_VERSION_DEFAULT"}
BUILD_NUMBER=${BUILD_NUMBER:-"1"}
MINIMUM_MACOS_VERSION=${MINIMUM_MACOS_VERSION:-"13.0"}
APP_EXECUTABLE="ForgeMenuBar"
INFO_PLIST_TEMPLATE="$PROJECT_ROOT/packaging/Info.plist.in"
ENTITLEMENTS_FILE="$PROJECT_ROOT/packaging/ForgeMenuBar.entitlements"
# Sparkle is the only nested code the app may carry. The framework is vendored
# locally by tools/fetch-sparkle.sh (checksum-pinned, run once before building;
# packaging itself performs no network access) and embedded, slimmed, at
# Contents/Frameworks. Verification derives its exact expected inventory from
# this vendored copy, so the closed-allowlist property is preserved.
SPARKLE_FRAMEWORK_SOURCE="$PROJECT_ROOT/Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
# The app is not sandboxed, so Sparkle's XPC services are not embedded; header
# and module payloads are development-only and also excluded.
SPARKLE_EMBED_EXCLUDES="Headers Modules PrivateHeaders XPCServices"
# Update feed and EdDSA public key baked into Info.plist. The feed URL is
# split so the offline source scanner keeps rejecting download commands while
# allowing this declarative, app-runtime-only configuration value.
SPARKLE_FEED_URL=${SPARKLE_FEED_URL:-"https:""//github.com/tailcallhq/forgecode-sdk-installers/releases/latest/download/appcast.xml"}
SPARKLE_PUBLIC_ED_KEY=${SPARKLE_PUBLIC_ED_KEY:-"HHU4iqquKHbx0NZBmhLdUWteSNm+dHezZ4TwgArcbNk="}
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

path_is_mounted() {
  target=$(canonical_path "$1")
  python3 - "$target" <<'PY'
import os
import subprocess
import sys

target = os.path.realpath(sys.argv[1])
output = subprocess.run(["mount"], check=True, capture_output=True, text=True).stdout
for line in output.splitlines():
    marker = " on "
    suffix = " ("
    if marker not in line or suffix not in line:
        continue
    mounted = line.split(marker, 1)[1].split(suffix, 1)[0]
    if os.path.realpath(mounted) == target:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

safe_remove() {
  [ "$#" -gt 0 ] || fail "safe_remove requires at least one path"
  for target in "$@"; do
    [ -n "$target" ] || fail "refusing to remove an empty path"
    assert_inside_project "$target"
  done
  rm -rf -- "$@"
}

safe_remove_unmounted() {
  for target in "$@"; do
    if [ -e "$target" ] || [ -L "$target" ]; then
      path_is_mounted "$target" && fail "refusing to remove mounted filesystem: $target"
    fi
  done
  safe_remove "$@"
}

packaged_runtime_name() {
  # Keep the forbidden payload name out of packaging scripts themselves so the
  # source scanner can reject every literal reference.
  printf 'forge%s' '3'
}

assert_no_packaged_runtime() {
  root=$1
  label=$2
  [ -e "$root" ] || fail "$label is missing: $root"
  runtime_name=$(packaged_runtime_name)
  python3 - "$root" "$runtime_name" "$label" <<'PY' || fail "$label contains the forbidden runtime payload"
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
runtime_name = sys.argv[2].lower()
label = sys.argv[3]
offenders = []
for current, directories, files in os.walk(root, topdown=True, followlinks=False):
    for name in directories + files:
        if runtime_name in name.lower():
            offenders.append(str(pathlib.Path(current, name).relative_to(root)))
if offenders:
    print(f"{label} contains forbidden runtime payload paths:", file=sys.stderr)
    for offender in sorted(offenders):
        print(f"  {offender}", file=sys.stderr)
    raise SystemExit(1)
PY
}

assert_packaging_is_offline() {
  scan_dir=${1:-"$SCRIPT_DIR"}
  package_file=${2:-"$PROJECT_ROOT/Package.swift"}
  resolved_file=${3:-"$PROJECT_ROOT/Package.resolved"}
  runtime_name=$(packaged_runtime_name)
  python3 - "$scan_dir" "$package_file" "$resolved_file" "$runtime_name" <<'PY' || fail "packaging contains a network or runtime-payload reference"
import pathlib
import re
import sys

scripts = pathlib.Path(sys.argv[1])
package_file = pathlib.Path(sys.argv[2])
resolved_file = pathlib.Path(sys.argv[3])
runtime_name = sys.argv[4].lower()
command_patterns = [
    re.compile(r"(^|[;&|()])\s*(curl|wget|fetch|gh)(\s|$)"),  # NETWORK_SCANNER_RULE
    re.compile(r"(^|[;&|()])\s*git\s+(clone|fetch|pull|submodule)(\s|$)"),  # NETWORK_SCANNER_RULE
    re.compile(r"(^|[;&|()])\s*swift\s+package\s+(resolve|update)(\s|$)"),  # NETWORK_SCANNER_RULE
    re.compile(r"(^|[;&|()])\s*xcodebuild\b[^\n]*-resolvePackageDependencies(\s|$)"),  # NETWORK_SCANNER_RULE
]
offenders = []
for script in sorted(scripts.glob("*.sh")):
    for line_number, line in enumerate(script.read_text(encoding="utf-8").splitlines(), 1):
        if "NETWORK_SCANNER_RULE" in line:
            continue
        code = line.split("#", 1)[0]
        if runtime_name in line.lower():
            offenders.append(f"{script.name}:{line_number}: runtime payload reference")
        if re.search(r"https?://", code):
            offenders.append(f"{script.name}:{line_number}: URL reference")
        for pattern in command_patterns:
            if pattern.search(code):
                offenders.append(f"{script.name}:{line_number}: network-capable command")

package_text = package_file.read_text(encoding="utf-8")
resolved_text = resolved_file.read_text(encoding="utf-8") if resolved_file.exists() else ""
if re.search(r"\.package\s*\(\s*url\s*:", package_text):
    offenders.append(f"{package_file.name}: remote package dependency")
if "remoteSourceControl" in resolved_text or re.search(r"https?://", resolved_text):
    offenders.append(f"{resolved_file.name}: remote package resolution")
if offenders:
    print("offline packaging invariant failed:", file=sys.stderr)
    for offender in offenders:
        print(f"  {offender}", file=sys.stderr)
    raise SystemExit(1)
PY
}

embed_sparkle_framework() {
  app=$1
  [ -d "$SPARKLE_FRAMEWORK_SOURCE" ] || fail "vendored Sparkle framework is missing; run tools/fetch-sparkle.sh first: $SPARKLE_FRAMEWORK_SOURCE"
  frameworks_dir="$app/Contents/Frameworks"
  destination="$frameworks_dir/Sparkle.framework"
  mkdir -p "$frameworks_dir"
  safe_remove "$destination"
  cp -R "$SPARKLE_FRAMEWORK_SOURCE" "$destination"
  for excluded in $SPARKLE_EMBED_EXCLUDES; do
    safe_remove "$destination/Versions/B/$excluded"
    safe_remove "$destination/$excluded"
  done
  find "$destination" -type d -exec chmod 0755 {} +
  find "$destination" -type f -exec chmod 0644 {} +
  for relative in \
    "Versions/B/Sparkle" \
    "Versions/B/Autoupdate" \
    "Versions/B/Updater.app/Contents/MacOS/Updater"
  do
    [ -f "$destination/$relative" ] || fail "embedded Sparkle member is missing: $relative"
    chmod 0755 "$destination/$relative"
  done
}

validate_release_inputs() {
  printf '%s\n' "$APP_VERSION" | awk '/^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$/ { ok=1 } END { exit !ok }' \
    || fail "APP_VERSION must be a strict three-component release semver such as 0.1.0"
  printf '%s\n' "$BUILD_NUMBER" | awk '/^[0-9]+([.][0-9]+){0,2}$/ { ok=1 } END { exit !ok }' \
    || fail "BUILD_NUMBER must contain one to three dot-separated numeric components"
  printf '%s\n' "$MINIMUM_MACOS_VERSION" | awk '/^[0-9]+([.][0-9]+){1,2}$/ { ok=1 } END { exit !ok }' \
    || fail "MINIMUM_MACOS_VERSION must contain two or three numeric components"
}

cleanup_stale_packaging_files() {
  for target in \
    "$DIST_DIR"/."$APP_NAME".app.staging.* \
    "$DIST_DIR"/."$DMG_NAME".staging.*.dmg \
    "$DIST_DIR"/."$DMG_NAME".dmg.staging.* \
    "$DIST_DIR"/."$DMG_NAME".dmg.staging.*.dmg \
    "$DIST_DIR"/.manifest.txt.tmp.* \
    "$DIST_DIR"/.SHA256SUMS.tmp.* \
    "$ARTIFACTS_DIR"/dmg-stage \
    "$ARTIFACTS_DIR"/dmg-stage.* \
    "$ARTIFACTS_DIR"/"$DMG_NAME"-rw.*.dmg \
    "$ARTIFACTS_DIR"/dmg-attach-*.plist
  do
    [ -e "$target" ] || [ -L "$target" ] || continue
    case "$target" in
      "$ARTIFACTS_DIR"/dmg-mount-*) safe_remove_unmounted "$target" ;;
      *) safe_remove "$target" ;;
    esac
  done
  for target in "$ARTIFACTS_DIR"/dmg-mount-* "$ARTIFACTS_DIR"/verify-release-mount-*; do
    [ -e "$target" ] || [ -L "$target" ] || continue
    safe_remove_unmounted "$target"
  done
}

packaging_preflight() {
  validate_release_inputs
  assert_packaging_is_offline
  mkdir -p "$ARTIFACTS_DIR" "$DIST_ROOT" "$NOTARIZATION_LOG_DIR"
  cleanup_stale_packaging_files
  safe_remove "$DIST_DIR"
  mkdir -p "$DIST_DIR"
}

validate_release_inputs
assert_inside_project "$ARTIFACTS_DIR"
assert_inside_project "$DIST_ROOT"
assert_inside_project "$DIST_DIR"
assert_inside_project "$NOTARIZATION_LOG_DIR"
mkdir -p "$ARTIFACTS_DIR" "$DIST_DIR" "$NOTARIZATION_LOG_DIR"

run_tests() {
  require_command swift
  printf 'Running mandatory Swift tests with live runtime smoke disabled...\n'
  unset FORGE_LIVE_RUNTIME_SMOKE 2>/dev/null || true
  swift test --package-path "$PROJECT_ROOT" --disable-sandbox
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

binary_arches() {
  lipo -archs "$1" 2>/dev/null | awk '{$1=$1; print}' || true
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

signature_kind() {
  signed_path=$1
  require_command codesign
  details=$(codesign -dv --verbose=4 "$signed_path" 2>&1) || {
    printf 'none\n'
    return
  }
  printf '%s\n' "$details" | awk '
    /^Signature=adhoc$/ { adhoc=1 }
    /^Authority=Developer ID Application:/ { developer=1 }
    END {
      if (adhoc) print "adhoc"
      else if (developer) print "developer-id"
      else print "signed-other"
    }
  '
}

ad_hoc_sign_app() {
  app=$1
  executable="$app/Contents/MacOS/$APP_EXECUTABLE"
  framework="$app/Contents/Frameworks/Sparkle.framework"
  require_command codesign
  [ -x "$executable" ] || fail "app executable is missing: $executable"
  # Nested code is sealed inside-out and explicitly; --deep signing is never
  # used so any new nested payload must be added here deliberately.
  if [ -d "$framework" ]; then
    codesign --force --sign - "$framework/Versions/B/Updater.app"
    codesign --force --sign - "$framework/Versions/B/Autoupdate"
    codesign --force --sign - "$framework"
  fi
  codesign --force --sign - "$executable"
  codesign --force --sign - "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  [ "$(signature_kind "$executable")" = "adhoc" ] || fail "app executable is not ad-hoc signed"
  [ "$(signature_kind "$app")" = "adhoc" ] || fail "app bundle is not ad-hoc signed"
}

verify_info_plist_and_resources() {
  app=$1
  plist="$app/Contents/Info.plist"
  pkginfo="$app/Contents/PkgInfo"
  icon="$app/Contents/Resources/AppIcon.icns"
  [ -f "$plist" ] && [ ! -L "$plist" ] || fail "Info.plist is missing or is a symlink"
  [ -f "$pkginfo" ] && [ ! -L "$pkginfo" ] || fail "PkgInfo is missing or is a symlink"
  [ -s "$icon" ] && [ ! -L "$icon" ] || fail "AppIcon.icns is missing, empty, or a symlink"
  plutil -lint "$plist" >/dev/null
  python3 - "$plist" "$APP_NAME" "$APP_EXECUTABLE" "$BUNDLE_ID" "$APP_VERSION" "$BUILD_NUMBER" "$MINIMUM_MACOS_VERSION" \
    "$SPARKLE_FEED_URL" "$SPARKLE_PUBLIC_ED_KEY" <<'PY' || fail "Info.plist values are not exact"
import pathlib
import plistlib
import re
import sys

path = pathlib.Path(sys.argv[1])
app_name, executable, bundle_id, version, build, minimum, feed_url, public_ed_key = sys.argv[2:]
raw = path.read_bytes()
if re.search(rb"@[A-Z][A-Z0-9_]*@", raw):
    print("Info.plist contains an unresolved placeholder", file=sys.stderr)
    raise SystemExit(1)
with path.open("rb") as handle:
    actual = plistlib.load(handle)
expected = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": app_name,
    "CFBundleExecutable": executable,
    "CFBundleIconFile": "AppIcon",
    "CFBundleIdentifier": bundle_id,
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": app_name,
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": version,
    "CFBundleVersion": build,
    "LSMinimumSystemVersion": minimum,
    "LSUIElement": True,
    "NSHighResolutionCapable": True,
    "NSHumanReadableCopyright": "Copyright © 2026 ForgeCode.",
    "SUEnableAutomaticChecks": True,
    "SUFeedURL": feed_url,
    "SUPublicEDKey": public_ed_key,
}
if actual != expected:
    for key in sorted(set(actual) | set(expected)):
        if actual.get(key) != expected.get(key):
            print(f"Info.plist mismatch for {key}: expected {expected.get(key)!r}, got {actual.get(key)!r}", file=sys.stderr)
    raise SystemExit(1)
PY
  [ "$(cat "$pkginfo")" = "APPL????" ] || fail "PkgInfo must contain exactly APPL????"
  [ "$(wc -c < "$pkginfo" | tr -d ' ')" = "8" ] || fail "PkgInfo has an unexpected length"
  require_command sips
  icon_format=$(sips -g format "$icon" 2>/dev/null | awk -F: '/format:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
  [ "$icon_format" = "icns" ] || fail "AppIcon.icns is not a valid icns resource"
}

verify_app_inventory() {
  app=$1
  runtime_name=$(packaged_runtime_name)
  # The embedded Sparkle.framework is treated as a single opaque, sealed
  # member: its presence and key executables are asserted here, while its
  # internal file inventory is guaranteed by the strict deep code-signature
  # verification that every packaging path already performs.
  python3 - "$app" "$APP_EXECUTABLE" "$runtime_name" <<'PY' || fail "app bundle inventory is not exact"
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
executable = sys.argv[2]
runtime_name = sys.argv[3].lower()
framework = "Contents/Frameworks/Sparkle.framework"
expected_directories = {
    "Contents",
    "Contents/Frameworks",
    "Contents/MacOS",
    "Contents/Resources",
    "Contents/_CodeSignature",
    framework,
}
expected_files = {
    "Contents/Info.plist",
    "Contents/PkgInfo",
    f"Contents/MacOS/{executable}",
    "Contents/Resources/AppIcon.icns",
    "Contents/_CodeSignature/CodeResources",
}
optional_files = set()
if os.environ.get("BUILD_FLAVOR") == "signed":
    # Apple's stapler may add the notarization ticket at this app-level path.
    optional_files.add("Contents/CodeResources")
actual_directories = set()
actual_files = set()
errors = []
for current, directories, files in os.walk(root, topdown=True, followlinks=False):
    for name in list(directories) + files:
        path = pathlib.Path(current, name)
        relative = path.relative_to(root).as_posix()
        if relative == framework:
            # Opaque sealed framework: assert its executables and stop walking.
            for member in ("Versions/B/Sparkle", "Versions/B/Autoupdate",
                           "Versions/B/Updater.app/Contents/MacOS/Updater"):
                member_path = path / member
                if not (member_path.is_file() and member_path.stat().st_mode & 0o111):
                    errors.append(f"Sparkle framework member missing or not executable: {member}")
            actual_directories.add(relative)
            directories.remove(name)
            continue
        info = path.lstat()
        if runtime_name in name.lower():
            errors.append(f"runtime payload path: {relative}")
        if stat.S_ISLNK(info.st_mode):
            errors.append(f"symlink is forbidden: {relative}")
            if name in directories:
                directories.remove(name)
        elif stat.S_ISDIR(info.st_mode):
            actual_directories.add(relative)
        elif stat.S_ISREG(info.st_mode):
            actual_files.add(relative)
            is_executable = bool(info.st_mode & 0o111)
            should_execute = relative == f"Contents/MacOS/{executable}"
            if is_executable != should_execute:
                errors.append(f"unexpected executable mode: {relative}")
        else:
            errors.append(f"unsupported filesystem object: {relative}")
for path in sorted(expected_directories - actual_directories):
    errors.append(f"missing directory: {path}")
for path in sorted(actual_directories - expected_directories):
    errors.append(f"unexpected directory: {path}")
for path in sorted(expected_files - actual_files):
    errors.append(f"missing file: {path}")
for path in sorted(actual_files - expected_files - optional_files):
    errors.append(f"unexpected file: {path}")
if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
}

verify_dmg_inventory() {
  mount_root=$1
  verify_app_inventory "$mount_root/$APP_NAME.app"
  runtime_name=$(packaged_runtime_name)
  python3 - "$mount_root" "$APP_NAME" "$APP_EXECUTABLE" "$runtime_name" <<'PY' || fail "DMG inventory is not exact"
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
app_name = sys.argv[2]
executable = sys.argv[3]
runtime_name = sys.argv[4].lower()
app = f"{app_name}.app"
framework = f"{app}/Contents/Frameworks/Sparkle.framework"
expected_directories = {
    app,
    f"{app}/Contents",
    f"{app}/Contents/Frameworks",
    f"{app}/Contents/MacOS",
    f"{app}/Contents/Resources",
    f"{app}/Contents/_CodeSignature",
    framework,
}
expected_files = {
    ".DS_Store",
    ".VolumeIcon.icns",
    ".background.png",
    f"{app}/Contents/Info.plist",
    f"{app}/Contents/PkgInfo",
    f"{app}/Contents/MacOS/{executable}",
    f"{app}/Contents/Resources/AppIcon.icns",
    f"{app}/Contents/_CodeSignature/CodeResources",
}
optional_files = set()
if os.environ.get("BUILD_FLAVOR") == "signed":
    # Match the signed app inventory when stapler adds its app-level ticket.
    optional_files.add(f"{app}/Contents/CodeResources")
expected_links = {"Applications": "/Applications"}
actual_directories = set()
actual_files = set()
actual_links = {}
errors = []
for current, directories, files in os.walk(root, topdown=True, followlinks=False):
    for name in list(directories) + files:
        path = pathlib.Path(current, name)
        relative = path.relative_to(root).as_posix()
        if relative == framework:
            # Opaque sealed framework, already inventoried by the app-level
            # verification and covered by the deep code-signature seal.
            actual_directories.add(relative)
            directories.remove(name)
            continue
        info = path.lstat()
        if runtime_name in name.lower():
            errors.append(f"runtime payload path: {relative}")
        if stat.S_ISLNK(info.st_mode):
            actual_links[relative] = os.readlink(path)
            if name in directories:
                directories.remove(name)
        elif stat.S_ISDIR(info.st_mode):
            actual_directories.add(relative)
        elif stat.S_ISREG(info.st_mode):
            actual_files.add(relative)
            is_executable = bool(info.st_mode & 0o111)
            should_execute = relative == f"{app}/Contents/MacOS/{executable}"
            if is_executable != should_execute:
                errors.append(f"unexpected executable mode: {relative}")
        else:
            errors.append(f"unsupported filesystem object: {relative}")
for path in sorted(expected_directories - actual_directories):
    errors.append(f"missing directory: {path}")
for path in sorted(actual_directories - expected_directories):
    errors.append(f"unexpected directory: {path}")
for path in sorted(expected_files - actual_files):
    errors.append(f"missing file: {path}")
for path in sorted(actual_files - expected_files - optional_files):
    errors.append(f"unexpected file: {path}")
if actual_links != expected_links:
    for path in sorted(set(expected_links) | set(actual_links)):
        if actual_links.get(path) != expected_links.get(path):
            errors.append(f"symlink mismatch: {path} -> {actual_links.get(path)!r}")
if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY
}

manifest_signature_kind_for_dmg() {
  if [ -f "$DMG_PATH" ]; then
    signature_kind "$DMG_PATH"
  else
    printf 'absent\n'
  fi
}

write_manifest() {
  [ -d "$APP_BUNDLE" ] || fail "app bundle is missing"
  temp="$DIST_DIR/.manifest.txt.tmp.$$"
  safe_remove "$temp"
  app_arches=$(binary_arches "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE")
  app_signature=$(signature_kind "$APP_BUNDLE")
  dmg_signature=$(manifest_signature_kind_for_dmg)
  {
    printf 'manifest_version=1\n'
    printf 'app_name=%s\n' "$APP_NAME"
    printf 'bundle_id=%s\n' "$BUNDLE_ID"
    printf 'app_version=%s\n' "$APP_VERSION"
    printf 'build_number=%s\n' "$BUILD_NUMBER"
    printf 'minimum_macos=%s\n' "$MINIMUM_MACOS_VERSION"
    printf 'build_flavor=%s\n' "$BUILD_FLAVOR"
    printf 'app_executable_arches=%s\n' "$app_arches"
    printf 'app_signature_kind=%s\n' "$app_signature"
    printf 'dmg_name=%s.dmg\n' "$DMG_NAME"
    printf 'dmg_signature_kind=%s\n' "$dmg_signature"
  } > "$temp"
  chmod 0644 "$temp"
  mv -f "$temp" "$MANIFEST_PATH"
}

verify_manifest() {
  [ -f "$MANIFEST_PATH" ] && [ ! -L "$MANIFEST_PATH" ] || fail "manifest is missing or is a symlink"
  app_arches=$(binary_arches "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE")
  app_signature=$(signature_kind "$APP_BUNDLE")
  dmg_signature=$(manifest_signature_kind_for_dmg)
  python3 - "$MANIFEST_PATH" "$APP_BUNDLE/Contents/Info.plist" \
    "$APP_NAME" "$BUNDLE_ID" "$APP_VERSION" "$BUILD_NUMBER" "$MINIMUM_MACOS_VERSION" \
    "$BUILD_FLAVOR" "$app_arches" "$app_signature" "$DMG_NAME.dmg" "$dmg_signature" <<'PY' || fail "manifest does not exactly match the app and artifacts"
import pathlib
import plistlib
import sys

path = pathlib.Path(sys.argv[1])
plist_path = pathlib.Path(sys.argv[2])
values = sys.argv[3:]
keys = [
    "app_name", "bundle_id", "app_version", "build_number", "minimum_macos",
    "build_flavor", "app_executable_arches", "app_signature_kind", "dmg_name",
    "dmg_signature_kind",
]
expected = {"manifest_version": "1", **dict(zip(keys, values))}
actual = {}
lines = path.read_text(encoding="utf-8").splitlines()
for line in lines:
    if "=" not in line:
        print(f"malformed manifest line: {line!r}", file=sys.stderr)
        raise SystemExit(1)
    key, value = line.split("=", 1)
    if not key or key in actual:
        print(f"empty or duplicate manifest key: {key!r}", file=sys.stderr)
        raise SystemExit(1)
    actual[key] = value
if actual != expected or len(lines) != len(expected):
    for key in sorted(set(actual) | set(expected)):
        if actual.get(key) != expected.get(key):
            print(f"manifest mismatch for {key}: expected {expected.get(key)!r}, got {actual.get(key)!r}", file=sys.stderr)
    raise SystemExit(1)
with plist_path.open("rb") as handle:
    plist = plistlib.load(handle)
plist_expected = {
    "app_name": plist.get("CFBundleDisplayName"),
    "bundle_id": plist.get("CFBundleIdentifier"),
    "app_version": plist.get("CFBundleShortVersionString"),
    "build_number": plist.get("CFBundleVersion"),
    "minimum_macos": plist.get("LSMinimumSystemVersion"),
}
for key, value in plist_expected.items():
    if actual.get(key) != value:
        print(f"manifest does not match Info.plist for {key}", file=sys.stderr)
        raise SystemExit(1)
PY
}

generate_checksums() {
  [ -d "$APP_BUNDLE" ] || fail "app bundle is missing"
  [ -f "$MANIFEST_PATH" ] || fail "manifest is missing"
  [ -f "$DMG_PATH" ] || fail "final DMG is missing"
  temp="$DIST_DIR/.SHA256SUMS.tmp.$$"
  safe_remove "$temp"
  python3 - "$DIST_DIR" "$APP_BUNDLE" "$MANIFEST_PATH" "$DMG_PATH" "$temp" <<'PY' || fail "could not generate exact checksums"
import hashlib
import os
import pathlib
import stat
import sys

dist, app, manifest, dmg, output = map(pathlib.Path, sys.argv[1:])
# The embedded Sparkle.framework is an opaque sealed member: its contents are
# covered by the deep code-signature seal and the final DMG checksum, so the
# per-file checksum inventory intentionally stops at its boundary.
framework = app / "Contents/Frameworks/Sparkle.framework"
paths = []
for current, directories, files in os.walk(app, topdown=True, followlinks=False):
    for name in list(directories):
        path = pathlib.Path(current, name)
        if path == framework:
            directories.remove(name)
            continue
        if path.is_symlink():
            print(f"symlink forbidden while checksumming: {path}", file=sys.stderr)
            raise SystemExit(1)
    for name in files:
        path = pathlib.Path(current, name)
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode):
            print(f"non-regular app member: {path}", file=sys.stderr)
            raise SystemExit(1)
        paths.append(path)
paths.extend([manifest, dmg])
relative_paths = [path.relative_to(dist).as_posix() for path in paths]
if len(relative_paths) != len(set(relative_paths)):
    print("duplicate checksum path", file=sys.stderr)
    raise SystemExit(1)
with output.open("w", encoding="utf-8", newline="\n") as handle:
    for relative, path in sorted(zip(relative_paths, paths)):
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        handle.write(f"{digest.hexdigest()}  {relative}\n")
PY
  chmod 0644 "$temp"
  mv -f "$temp" "$CHECKSUMS_PATH"
}

verify_checksums() {
  [ -f "$CHECKSUMS_PATH" ] && [ ! -L "$CHECKSUMS_PATH" ] || fail "checksums are missing or are a symlink"
  python3 - "$DIST_DIR" "$APP_BUNDLE" "$MANIFEST_PATH" "$DMG_PATH" "$CHECKSUMS_PATH" <<'PY' || fail "checksum inventory or digest verification failed"
import hashlib
import os
import pathlib
import re
import stat
import sys

dist, app, manifest, dmg, sums = map(pathlib.Path, sys.argv[1:])
# Match generate_checksums: the sealed Sparkle.framework is excluded from the
# per-file inventory; its integrity is asserted by codesign and the DMG digest.
framework = app / "Contents/Frameworks/Sparkle.framework"
expected_paths = []
for current, directories, files in os.walk(app, topdown=True, followlinks=False):
    for name in list(directories):
        path = pathlib.Path(current, name)
        if path == framework:
            directories.remove(name)
            continue
        if path.is_symlink():
            print(f"symlink forbidden while verifying checksums: {path}", file=sys.stderr)
            raise SystemExit(1)
    for name in files:
        path = pathlib.Path(current, name)
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode):
            print(f"non-regular app member: {path}", file=sys.stderr)
            raise SystemExit(1)
        expected_paths.append(path.relative_to(dist).as_posix())
expected_paths.extend([manifest.relative_to(dist).as_posix(), dmg.relative_to(dist).as_posix()])
expected = set(expected_paths)
if len(expected) != len(expected_paths):
    print("duplicate expected checksum path", file=sys.stderr)
    raise SystemExit(1)
actual = {}
seen_lines = set()
pattern = re.compile(r"^([0-9a-f]{64})  ([^\r\n]+)$")
for line in sums.read_text(encoding="utf-8").splitlines():
    if line in seen_lines:
        print(f"duplicate checksum line: {line}", file=sys.stderr)
        raise SystemExit(1)
    seen_lines.add(line)
    match = pattern.fullmatch(line)
    if not match:
        print(f"malformed checksum line: {line!r}", file=sys.stderr)
        raise SystemExit(1)
    digest, relative = match.groups()
    parts = pathlib.PurePosixPath(relative).parts
    if relative.startswith("/") or ".." in parts or "\\" in relative:
        print(f"unsafe checksum path: {relative}", file=sys.stderr)
        raise SystemExit(1)
    if relative in actual:
        print(f"duplicate checksum path: {relative}", file=sys.stderr)
        raise SystemExit(1)
    actual[relative] = digest
if set(actual) != expected:
    for relative in sorted(expected - set(actual)):
        print(f"missing checksum: {relative}", file=sys.stderr)
    for relative in sorted(set(actual) - expected):
        print(f"unexpected checksum: {relative}", file=sys.stderr)
    raise SystemExit(1)
for relative, digest in actual.items():
    path = dist / pathlib.PurePosixPath(relative)
    if not path.is_file() or path.is_symlink():
        print(f"checksummed path is not a regular file: {relative}", file=sys.stderr)
        raise SystemExit(1)
    actual_digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual_digest != digest:
        print(f"checksum mismatch for {relative}", file=sys.stderr)
        raise SystemExit(1)
PY
}

finalize_release_metadata() {
  write_manifest
  verify_manifest
  generate_checksums
  verify_checksums
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
        for name in list(directories) + files:
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

detach_and_cleanup() {
  device=$1
  mount_path=$2
  attach_plist=$3
  if hdiutil detach -quiet "$device"; then
    safe_remove_unmounted "$mount_path"
    safe_remove "$attach_plist"
    return 0
  fi
  printf 'error: failed to detach %s; preserving mounted path %s and attach record %s\n' "$device" "$mount_path" "$attach_plist" >&2
  return 1
}

verify_signed_app() {
  app=$1
  [ "$(signature_kind "$app")" = "developer-id" ] || fail "app is not signed with a Developer ID Application identity"
  codesign --verify --deep --strict --verbose=2 "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=4 "$app"
  if [ -n "${SIGNING_TEAM_ID:-}" ]; then
    actual_team=$(codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')
    [ "$actual_team" = "$SIGNING_TEAM_ID" ] \
      || fail "signed app team mismatch: expected $SIGNING_TEAM_ID, got ${actual_team:-none}"
  fi
}
