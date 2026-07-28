#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

require_command hdiutil
require_command osascript
require_command ditto

[ -d "$APP_BUNDLE" ] || fail "app bundle is missing; run scripts/assemble-app.sh"
assets_dir=${ASSETS_DIR:-"$ARTIFACTS_DIR/assets"}
[ -f "$assets_dir/dmg-background.png" ] || fail "DMG background is missing; run scripts/generate-assets.sh"

stage="$ARTIFACTS_DIR/dmg-stage"
rw_dmg="$ARTIFACTS_DIR/$DMG_NAME-rw.dmg"
safe_remove "$stage" "$rw_dmg" "$DMG_PATH"
mkdir -p "$stage/.background"
ditto "$APP_BUNDLE" "$stage/$APP_NAME.app"
install -m 0644 "$assets_dir/dmg-background.png" "$stage/.background/background.png"
ln -s /Applications "$stage/Applications"

hdiutil create -quiet -fs HFS+ -format UDRW -volname "$APP_NAME" -srcfolder "$stage" "$rw_dmg"
mount_dir="$ARTIFACTS_DIR/dmg-mount-rw"
safe_remove "$mount_dir"
mkdir -p "$mount_dir"
attach_plist="$ARTIFACTS_DIR/dmg-attach-rw.plist"
safe_remove "$attach_plist"
hdiutil attach -plist -readwrite -noverify -noautoopen -mountpoint "$mount_dir" "$rw_dmg" > "$attach_plist"
device=$(attach_plist_value "$attach_plist" dev-entry)
actual_mount=$(attach_plist_value "$attach_plist" mount-point)
[ -n "$device" ] || fail "could not attach writable DMG"
[ -n "$actual_mount" ] || fail "writable DMG attach did not report a mount point"
[ "$(canonical_path "$actual_mount")" = "$(canonical_path "$mount_dir")" ] \
  || fail "writable DMG mounted at unexpected path: ${actual_mount:-none}"
cleanup() { hdiutil detach -quiet "$device" >/dev/null 2>&1 || true; safe_remove "$mount_dir" "$attach_plist"; }
trap cleanup EXIT HUP INT TERM
osascript "$PROJECT_ROOT/packaging/dmg-layout.applescript" "$mount_dir"
sync
hdiutil detach -quiet "$device"
trap - EXIT HUP INT TERM
safe_remove "$mount_dir" "$attach_plist"
hdiutil convert -quiet "$rw_dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
safe_remove "$rw_dmg"
hdiutil verify "$DMG_PATH" >/dev/null

verify_mount="$ARTIFACTS_DIR/dmg-mount-verify"
safe_remove "$verify_mount"
mkdir -p "$verify_mount"
verify_attach_plist="$ARTIFACTS_DIR/dmg-attach-verify.plist"
safe_remove "$verify_attach_plist"
hdiutil attach -plist -readonly -noverify -noautoopen -mountpoint "$verify_mount" "$DMG_PATH" > "$verify_attach_plist"
verify_device=$(attach_plist_value "$verify_attach_plist" dev-entry)
actual_verify_mount=$(attach_plist_value "$verify_attach_plist" mount-point)
[ -n "$verify_device" ] || fail "could not attach final DMG"
[ -n "$actual_verify_mount" ] || fail "final DMG attach did not report a mount point"
[ "$(canonical_path "$actual_verify_mount")" = "$(canonical_path "$verify_mount")" ] \
  || fail "final DMG mounted at unexpected path: ${actual_verify_mount:-none}"
verify_cleanup() { hdiutil detach -quiet "$verify_device" >/dev/null 2>&1 || true; safe_remove "$verify_mount" "$verify_attach_plist"; }
trap verify_cleanup EXIT HUP INT TERM
[ -d "$verify_mount/$APP_NAME.app" ] || fail "final DMG is missing the app bundle"
[ -L "$verify_mount/Applications" ] || fail "final DMG is missing the Applications symlink"
[ "$(readlink "$verify_mount/Applications")" = "/Applications" ] || fail "Applications symlink has unexpected target"
verify_app_bundle_matches "$APP_BUNDLE" "$verify_mount/$APP_NAME.app"
if [ "$BUILD_FLAVOR" = "signed" ]; then
  verify_signed_app "$verify_mount/$APP_NAME.app"
fi
hdiutil detach -quiet "$verify_device"
trap - EXIT HUP INT TERM
safe_remove "$verify_mount" "$verify_attach_plist"
write_manifest
generate_checksums
printf '%s\n' "$DMG_PATH"
