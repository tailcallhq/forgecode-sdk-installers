#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

require_command hdiutil
require_command osascript
require_command ditto

[ -d "$APP_BUNDLE" ] || fail "app bundle is missing; run scripts/assemble-app.sh"
verify_app_inventory "$APP_BUNDLE"
verify_info_plist_and_resources "$APP_BUNDLE"
assert_no_packaged_runtime "$APP_BUNDLE" "app bundle"
assets_dir=${ASSETS_DIR:-"$ARTIFACTS_DIR/assets"}
[ -f "$assets_dir/dmg-background.png" ] || fail "DMG background is missing; run scripts/generate-assets.sh"

stage="$ARTIFACTS_DIR/dmg-stage.$$"
rw_dmg="$ARTIFACTS_DIR/$DMG_NAME-rw.$$.dmg"
staged_dmg="$DIST_DIR/.$DMG_NAME.staging.$$.dmg"
mount_dir="$ARTIFACTS_DIR/dmg-mount-rw.$$"
attach_plist="$ARTIFACTS_DIR/dmg-attach-rw.$$.plist"
verify_mount="$ARTIFACTS_DIR/dmg-mount-verify.$$"
verify_attach_plist="$ARTIFACTS_DIR/dmg-attach-verify.$$.plist"

rw_device=
verify_device=
cleanup() {
  status=$?
  if [ -n "$rw_device" ]; then
    if detach_and_cleanup "$rw_device" "$mount_dir" "$attach_plist"; then
      rw_device=
    else
      status=1
    fi
  else
    safe_remove_unmounted "$mount_dir"
    safe_remove "$attach_plist"
  fi
  if [ -n "$verify_device" ]; then
    if detach_and_cleanup "$verify_device" "$verify_mount" "$verify_attach_plist"; then
      verify_device=
    else
      status=1
    fi
  else
    safe_remove_unmounted "$verify_mount"
    safe_remove "$verify_attach_plist"
  fi
  safe_remove "$stage" "$rw_dmg" "$staged_dmg"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

safe_remove "$stage" "$rw_dmg" "$staged_dmg" "$attach_plist" "$verify_attach_plist"
safe_remove_unmounted "$mount_dir" "$verify_mount"
mkdir -p "$stage/.background"
ditto "$APP_BUNDLE" "$stage/$APP_NAME.app"
install -m 0644 "$assets_dir/dmg-background.png" "$stage/.background/background.png"
ln -s /Applications "$stage/Applications"

hdiutil create -quiet -fs HFS+ -format UDRW -volname "$APP_NAME" -srcfolder "$stage" "$rw_dmg"
mkdir -p "$mount_dir"
hdiutil attach -plist -readwrite -noverify -noautoopen -mountpoint "$mount_dir" "$rw_dmg" > "$attach_plist"
rw_device=$(attach_plist_value "$attach_plist" dev-entry)
actual_mount=$(attach_plist_value "$attach_plist" mount-point)
[ -n "$rw_device" ] || fail "could not attach writable DMG"
[ -n "$actual_mount" ] || fail "writable DMG attach did not report a mount point"
[ "$(canonical_path "$actual_mount")" = "$(canonical_path "$mount_dir")" ] \
  || fail "writable DMG mounted at unexpected path: ${actual_mount:-none}"
osascript "$PROJECT_ROOT/packaging/dmg-layout.applescript" "$mount_dir"
# HFS+ may create filesystem-event bookkeeping while mounted. It is not part of
# the release payload, so remove it before freezing and verifying the allowlist.
if [ -d "$mount_dir/.fseventsd" ]; then
  safe_remove "$mount_dir/.fseventsd"
fi
sync
if detach_and_cleanup "$rw_device" "$mount_dir" "$attach_plist"; then
  rw_device=
else
  fail "could not detach writable DMG"
fi

hdiutil convert -quiet "$rw_dmg" -format UDZO -imagekey zlib-level=9 -o "$staged_dmg"
hdiutil verify "$staged_dmg" >/dev/null
safe_remove "$rw_dmg" "$stage"

mkdir -p "$verify_mount"
hdiutil attach -plist -readonly -noverify -noautoopen -mountpoint "$verify_mount" "$staged_dmg" > "$verify_attach_plist"
verify_device=$(attach_plist_value "$verify_attach_plist" dev-entry)
actual_verify_mount=$(attach_plist_value "$verify_attach_plist" mount-point)
[ -n "$verify_device" ] || fail "could not attach final DMG"
[ -n "$actual_verify_mount" ] || fail "final DMG attach did not report a mount point"
[ "$(canonical_path "$actual_verify_mount")" = "$(canonical_path "$verify_mount")" ] \
  || fail "final DMG mounted at unexpected path: ${actual_verify_mount:-none}"
verify_dmg_inventory "$verify_mount"
verify_app_bundle_matches "$APP_BUNDLE" "$verify_mount/$APP_NAME.app"
if [ "$BUILD_FLAVOR" = "signed" ]; then
  verify_signed_app "$verify_mount/$APP_NAME.app"
fi
if detach_and_cleanup "$verify_device" "$verify_mount" "$verify_attach_plist"; then
  verify_device=
else
  fail "could not detach final DMG"
fi

safe_remove "$DMG_PATH"
mv "$staged_dmg" "$DMG_PATH"
write_manifest
verify_manifest
if [ "$BUILD_FLAVOR" = "unsigned" ]; then
  finalize_release_metadata
fi

trap - EXIT HUP INT TERM
safe_remove_unmounted "$mount_dir" "$verify_mount"
safe_remove "$stage" "$rw_dmg" "$staged_dmg" "$attach_plist" "$verify_attach_plist"
printf '%s\n' "$DMG_PATH"
