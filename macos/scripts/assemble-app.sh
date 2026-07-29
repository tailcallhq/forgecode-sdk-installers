#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

require_command plutil
require_command lipo
require_command python3
require_command codesign

app_binary=${APP_BINARY:-}
assets_dir=${ASSETS_DIR:-}

[ -n "$app_binary" ] || app_binary=$(sh "$SCRIPT_DIR/build-universal.sh" | tail -n 1)
[ -n "$assets_dir" ] || assets_dir=$(sh "$SCRIPT_DIR/generate-assets.sh" | tail -n 1)

[ -x "$app_binary" ] || fail "app executable is missing: $app_binary"
[ -f "$assets_dir/AppIcon.icns" ] || fail "AppIcon.icns is missing: $assets_dir/AppIcon.icns"
[ -f "$INFO_PLIST_TEMPLATE" ] || fail "Info.plist template is missing"

mkdir -p "$DIST_DIR"
staging="$DIST_DIR/.$APP_NAME.app.staging.$$"
safe_remove "$staging"
cleanup() { safe_remove "$staging"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources"
install -m 0755 "$app_binary" "$staging/Contents/MacOS/$APP_EXECUTABLE"
install -m 0644 "$assets_dir/AppIcon.icns" "$staging/Contents/Resources/AppIcon.icns"

python3 - "$INFO_PLIST_TEMPLATE" "$staging/Contents/Info.plist" \
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
printf 'APPL????' > "$staging/Contents/PkgInfo"

validate_macho "$staging/Contents/MacOS/$APP_EXECUTABLE" arm64 x86_64
verify_info_plist_and_resources "$staging"
assert_no_packaged_runtime "$staging" "staged app bundle"

# Every assembled app is sealed before publication. The unsigned artifact keeps
# this ad-hoc seal; the signed release path deliberately replaces it with the
# configured Developer ID identity before notarization.
ad_hoc_sign_app "$staging"
verify_app_inventory "$staging"

safe_remove "$APP_BUNDLE" "$DMG_PATH" "$MANIFEST_PATH" "$CHECKSUMS_PATH"
mv "$staging" "$APP_BUNDLE"
trap - EXIT HUP INT TERM
write_manifest
verify_manifest
printf '%s\n' "$APP_BUNDLE"
