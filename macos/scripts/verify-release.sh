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
assert_packaging_is_offline
assert_no_packaged_runtime "$APP_BUNDLE" "app bundle"
verify_info_plist_and_resources "$APP_BUNDLE"
verify_app_inventory "$APP_BUNDLE"
validate_macho "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE" arm64 x86_64

case "$BUILD_FLAVOR" in
  unsigned)
    [ "$(signature_kind "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE")" = "adhoc" ] \
      || fail "unsigned app executable must be ad-hoc signed"
    [ "$(signature_kind "$APP_BUNDLE")" = "adhoc" ] \
      || fail "unsigned app bundle must be ad-hoc signed"
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
    ;;
  signed)
    [ "${VERIFY_SIGNATURES:-0}" = "1" ] || fail "signed verification requires VERIFY_SIGNATURES=1"
    require_command spctl
    verify_signed_app "$APP_BUNDLE"
    ;;
esac

verify_manifest

if [ -f "$DMG_PATH" ]; then
  hdiutil verify "$DMG_PATH" >/dev/null
  verify_mount="$ARTIFACTS_DIR/verify-release-mount.$$"
  attach_plist="$ARTIFACTS_DIR/verify-release-attach.$$.plist"
  safe_remove_unmounted "$verify_mount"
  safe_remove "$attach_plist"
  mkdir -p "$verify_mount"
  device=
  cleanup() {
    status=$?
    if [ -n "$device" ]; then
      if detach_and_cleanup "$device" "$verify_mount" "$attach_plist"; then
        device=
      else
        status=1
      fi
    else
      safe_remove_unmounted "$verify_mount"
      safe_remove "$attach_plist"
    fi
    exit "$status"
  }
  trap cleanup EXIT HUP INT TERM
  hdiutil attach -plist -readonly -noverify -noautoopen -mountpoint "$verify_mount" "$DMG_PATH" > "$attach_plist"
  device=$(attach_plist_value "$attach_plist" dev-entry)
  actual_mount=$(attach_plist_value "$attach_plist" mount-point)
  [ -n "$device" ] || fail "could not mount DMG for payload verification"
  [ -n "$actual_mount" ] || fail "DMG attach did not report a mount point"
  [ "$(canonical_path "$actual_mount")" = "$(canonical_path "$verify_mount")" ] \
    || fail "DMG mounted at unexpected path: $actual_mount"
  verify_dmg_inventory "$verify_mount"
  verify_app_bundle_matches "$APP_BUNDLE" "$verify_mount/$APP_NAME.app"
  if [ "$BUILD_FLAVOR" = "signed" ]; then
    verify_signed_app "$verify_mount/$APP_NAME.app"
  fi
  if detach_and_cleanup "$device" "$verify_mount" "$attach_plist"; then
    device=
  else
    fail "could not detach DMG verification mount"
  fi
  trap - EXIT HUP INT TERM
  safe_remove_unmounted "$verify_mount"
  safe_remove "$attach_plist"

  if [ "$BUILD_FLAVOR" = "signed" ]; then
    [ "$(signature_kind "$DMG_PATH")" = "developer-id" ] || fail "DMG is not Developer ID signed"
    codesign --verify --strict --verbose=2 "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
  else
    [ "$(signature_kind "$DMG_PATH")" = "none" ] || fail "unsigned DMG must not carry a code signature"
  fi
  verify_manifest
  verify_checksums
else
  [ ! -e "$CHECKSUMS_PATH" ] || fail "checksums must not be published before the final DMG exists"
fi
printf 'Verified %s\n' "$APP_BUNDLE"
