#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

require_command plutil
require_command lipo
require_command python3

app_binary=${APP_BINARY:-}
helper_binary=${FORGE3_BINARY:-}
assets_dir=${ASSETS_DIR:-}

[ -n "$app_binary" ] || app_binary=$(sh "$SCRIPT_DIR/build-universal.sh" | tail -n 1)
[ -n "$helper_binary" ] || helper_binary=$(sh "$SCRIPT_DIR/build-helper.sh" | tail -n 1)
[ -n "$assets_dir" ] || assets_dir=$(sh "$SCRIPT_DIR/generate-assets.sh" | tail -n 1)

[ -x "$app_binary" ] || fail "app executable is missing: $app_binary"
[ -x "$helper_binary" ] || fail "forge3 helper is missing: $helper_binary"
[ -f "$assets_dir/AppIcon.icns" ] || fail "AppIcon.icns is missing: $assets_dir/AppIcon.icns"
[ -f "$INFO_PLIST_TEMPLATE" ] || fail "Info.plist template is missing"

safe_remove "$DIST_DIR"
mkdir -p "$DIST_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Helpers" "$APP_BUNDLE/Contents/Resources"
install -m 0755 "$app_binary" "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE"
install -m 0755 "$helper_binary" "$APP_BUNDLE/Contents/Helpers/$HELPER_EXECUTABLE"
install -m 0644 "$assets_dir/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

python3 - "$INFO_PLIST_TEMPLATE" "$APP_BUNDLE/Contents/Info.plist" \
  "$APP_NAME" "$APP_EXECUTABLE" "$BUNDLE_ID" "$APP_VERSION" "$BUILD_NUMBER" "$MINIMUM_MACOS_VERSION" <<'PY'
import plistlib
import sys

source, destination, app_name, executable, bundle_id, version, build, minimum = sys.argv[1:]
with open(source, "rb") as handle:
    plist = plistlib.load(handle)
plist["CFBundleDisplayName"] = app_name
plist["CFBundleExecutable"] = executable
plist["CFBundleIdentifier"] = bundle_id
plist["CFBundleName"] = app_name
plist["CFBundleShortVersionString"] = version
plist["CFBundleVersion"] = build
plist["LSMinimumSystemVersion"] = minimum
with open(destination, "wb") as handle:
    plistlib.dump(plist, handle, fmt=plistlib.FMT_XML, sort_keys=False)
PY
plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null
[ "$(plist_value "$APP_BUNDLE/Contents/Info.plist" CFBundleShortVersionString)" = "$APP_VERSION" ] || fail "app version substitution failed"
[ "$(plist_value "$APP_BUNDLE/Contents/Info.plist" CFBundleVersion)" = "$BUILD_NUMBER" ] || fail "build number substitution failed"

# Finder treats this file as a conventional bundle marker.
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

validate_macho "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE" arm64 x86_64
validate_macho "$APP_BUNDLE/Contents/Helpers/$HELPER_EXECUTABLE" arm64 x86_64
write_manifest
safe_remove "$CHECKSUMS_PATH"
printf '%s\n' "$APP_BUNDLE"
