#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

require_command plutil
require_command lipo
require_command codesign
require_command hdiutil
require_command otool

[ -d "$APP_BUNDLE" ] || fail "app bundle is missing"
[ -x "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE" ] || fail "app executable is missing"
[ -x "$APP_BUNDLE/Contents/Helpers/$HELPER_EXECUTABLE" ] || fail "universal forge3 helper is missing"
[ ! -e "$APP_BUNDLE/Contents/Resources/forge3" ] || fail "legacy architecture-specific helper layout is present"
plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_BUNDLE/Contents/Info.plist")" = "$MINIMUM_MACOS_VERSION" ] || fail "minimum macOS version mismatch"
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP_BUNDLE/Contents/Info.plist")" = "true" ] || fail "LSUIElement must be true"
validate_macho "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE" arm64 x86_64
validate_macho "$APP_BUNDLE/Contents/Helpers/$HELPER_EXECUTABLE" arm64 x86_64

if [ "${VERIFY_SIGNATURES:-0}" = "1" ]; then
  require_command spctl
  verify_signed_app "$APP_BUNDLE"
fi

if [ -f "$DMG_PATH" ]; then
  hdiutil verify "$DMG_PATH" >/dev/null
  verify_mount="$ARTIFACTS_DIR/verify-release-mount"
  attach_plist="$ARTIFACTS_DIR/verify-release-attach.plist"
  safe_remove "$verify_mount" "$attach_plist"
  mkdir -p "$verify_mount"
  hdiutil attach -plist -readonly -noverify -noautoopen -mountpoint "$verify_mount" "$DMG_PATH" > "$attach_plist"
  device=$(attach_plist_value "$attach_plist" dev-entry)
  actual_mount=$(attach_plist_value "$attach_plist" mount-point)
  [ -n "$device" ] || fail "could not mount DMG for payload verification"
  [ -n "$actual_mount" ] || fail "DMG attach did not report a mount point"
  [ "$(canonical_path "$actual_mount")" = "$(canonical_path "$verify_mount")" ] \
    || fail "DMG mounted at unexpected path: $actual_mount"
  cleanup() { hdiutil detach -quiet "$device" >/dev/null 2>&1 || true; safe_remove "$verify_mount" "$attach_plist"; }
  trap cleanup EXIT HUP INT TERM
  [ -d "$verify_mount/$APP_NAME.app" ] || fail "DMG payload app is missing"
  [ -L "$verify_mount/Applications" ] || fail "DMG Applications symlink is missing"
  [ "$(readlink "$verify_mount/Applications")" = "/Applications" ] || fail "DMG Applications symlink has unexpected target"
  verify_app_bundle_matches "$APP_BUNDLE" "$verify_mount/$APP_NAME.app"
  if [ "${VERIFY_SIGNATURES:-0}" = "1" ]; then
    verify_signed_app "$verify_mount/$APP_NAME.app"
  fi
  hdiutil detach -quiet "$device"
  trap - EXIT HUP INT TERM
  safe_remove "$verify_mount" "$attach_plist"
  if [ "${VERIFY_SIGNATURES:-0}" = "1" ]; then
    codesign --verify --strict --verbose=2 "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
  fi
fi

if [ -f "$CHECKSUMS_PATH" ]; then
  verify_checksums
fi
printf 'Verified %s\n' "$APP_BUNDLE"
