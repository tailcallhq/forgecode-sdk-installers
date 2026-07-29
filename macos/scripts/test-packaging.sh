#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

require_command codesign
require_command python3

fixtures="$ARTIFACTS_DIR/packaging-tests.$$"
safe_remove "$fixtures"
mkdir -p "$fixtures"
cleanup() { safe_remove "$fixtures"; }
trap cleanup EXIT HUP INT TERM

pass_count=0
pass() {
  pass_count=$((pass_count + 1))
  printf 'ok %d - %s\n' "$pass_count" "$1"
}

expect_failure() {
  label=$1
  shift
  if ( "$@" ) >/dev/null 2>&1; then
    fail "expected packaging fixture to fail: $label"
  fi
  pass "$label"
}

make_fixture_app() {
  app=$1
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp /usr/bin/true "$app/Contents/MacOS/$APP_EXECUTABLE"
  chmod 0755 "$app/Contents/MacOS/$APP_EXECUTABLE"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>$APP_NAME</string>
<key>CFBundleExecutable</key><string>$APP_EXECUTABLE</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>$MINIMUM_MACOS_VERSION</string>
</dict></plist>
PLIST
  printf 'icon' > "$app/Contents/Resources/AppIcon.icns"
  printf 'APPL????' > "$app/Contents/PkgInfo"
  embed_sparkle_framework "$app"
  ad_hoc_sign_app "$app"
}

make_fixture_dmg_mount() {
  mount_root=$1
  mkdir -p "$mount_root/.background"
  make_fixture_app "$mount_root/$APP_NAME.app"
  printf 'finder-layout-fixture' > "$mount_root/.DS_Store"
  printf 'background-fixture' > "$mount_root/.background/background.png"
  ln -s /Applications "$mount_root/Applications"
}

printf '1..20\n'

[ -z "${FORGE_LIVE_RUNTIME_SMOKE+x}" ] || fail "packaging did not unset FORGE_LIVE_RUNTIME_SMOKE"
pass "live runtime smoke is unset"

assert_packaging_is_offline
pass "packaging source and package resolution are offline"

network_scripts="$fixtures/network-scripts"
mkdir -p "$network_scripts"
download_command=$(printf 'cu%s' 'rl')
download_url=$(printf 'https%s' '://example.invalid/payload')
printf '%s\n' '#!/bin/sh' "$download_command $download_url" > "$network_scripts/bad.sh"
expect_failure "network command scanner rejects shell downloads" \
  assert_packaging_is_offline "$network_scripts" "$PROJECT_ROOT/Package.swift" "$PROJECT_ROOT/Package.resolved"

fixture_app="$fixtures/Fixture.app"
make_fixture_app "$fixture_app"
[ "$(signature_kind "$fixture_app/Contents/MacOS/$APP_EXECUTABLE")" = "adhoc" ] || fail "fixture executable is not ad-hoc signed"
[ "$(signature_kind "$fixture_app")" = "adhoc" ] || fail "fixture app is not ad-hoc signed"
pass "ad-hoc signing seals executable and bundle"

inventory_app="$fixtures/Inventory.app"
make_fixture_app "$inventory_app"
verify_app_inventory "$inventory_app"
printf 'unexpected' > "$inventory_app/Contents/Resources/unexpected.txt"
expect_failure "app inventory rejects unexpected files" verify_app_inventory "$inventory_app"

symlink_app="$fixtures/Symlink.app"
make_fixture_app "$symlink_app"
ln -s AppIcon.icns "$symlink_app/Contents/Resources/link.icns"
expect_failure "app inventory rejects symlinks" verify_app_inventory "$symlink_app"

sparkle_missing_app="$fixtures/SparkleMissing.app"
make_fixture_app "$sparkle_missing_app"
safe_remove "$sparkle_missing_app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
expect_failure "app inventory rejects an incomplete Sparkle framework" \
  verify_app_inventory "$sparkle_missing_app"

sparkle_link_app="$fixtures/SparkleLink.app"
make_fixture_app "$sparkle_link_app"
rm "$sparkle_link_app/Contents/Frameworks/Sparkle.framework/Sparkle"
ln -s Versions/B/Autoupdate "$sparkle_link_app/Contents/Frameworks/Sparkle.framework/Sparkle"
expect_failure "app inventory rejects a retargeted Sparkle symlink" \
  verify_app_inventory "$sparkle_link_app"

sparkle_extra_app="$fixtures/SparkleExtra.app"
make_fixture_app "$sparkle_extra_app"
printf 'payload' > "$sparkle_extra_app/Contents/Frameworks/Sparkle.framework/Versions/B/extra"
expect_failure "app inventory rejects extra files inside the Sparkle framework" \
  verify_app_inventory "$sparkle_extra_app"

runtime_app="$fixtures/Runtime.app"
make_fixture_app "$runtime_app"
runtime_name=$(packaged_runtime_name)
printf 'payload' > "$runtime_app/Contents/Resources/$runtime_name"
expect_failure "app inventory rejects runtime payload names" verify_app_inventory "$runtime_app"

stapled_app="$fixtures/Stapled.app"
make_fixture_app "$stapled_app"
printf 'notarization-ticket-fixture' > "$stapled_app/Contents/CodeResources"
old_build_flavor=$BUILD_FLAVOR
BUILD_FLAVOR=signed
export BUILD_FLAVOR
verify_app_inventory "$stapled_app"
BUILD_FLAVOR=$old_build_flavor
export BUILD_FLAVOR
pass "signed app inventory permits the notarization ticket path"

stapled_dmg_mount="$fixtures/stapled-dmg-mount"
make_fixture_dmg_mount "$stapled_dmg_mount"
printf 'notarization-ticket-fixture' > "$stapled_dmg_mount/$APP_NAME.app/Contents/CodeResources"
BUILD_FLAVOR=signed
export BUILD_FLAVOR
verify_dmg_inventory "$stapled_dmg_mount"
pass "signed DMG inventory permits the app-level notarization ticket"
BUILD_FLAVOR=unsigned
export BUILD_FLAVOR
expect_failure "unsigned DMG inventory rejects the app-level notarization ticket" \
  verify_dmg_inventory "$stapled_dmg_mount"
BUILD_FLAVOR=$old_build_flavor
export BUILD_FLAVOR

metadata_dist="$fixtures/metadata-dist"
mkdir -p "$metadata_dist"
old_dist_dir=$DIST_DIR
old_app_bundle=$APP_BUNDLE
old_dmg_path=$DMG_PATH
old_manifest_path=$MANIFEST_PATH
old_checksums_path=$CHECKSUMS_PATH
DIST_DIR=$metadata_dist
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$DMG_NAME.dmg"
MANIFEST_PATH="$DIST_DIR/manifest.txt"
CHECKSUMS_PATH="$DIST_DIR/SHA256SUMS"
make_fixture_app "$APP_BUNDLE"
printf 'dmg fixture' > "$DMG_PATH"
write_manifest
verify_manifest
printf 'duplicate=bad\n' >> "$MANIFEST_PATH"
expect_failure "manifest verification rejects extra or duplicate keys" verify_manifest
write_manifest
generate_checksums
verify_checksums
first_line=$(sed -n '1p' "$CHECKSUMS_PATH")
printf '%s\n' "$first_line" >> "$CHECKSUMS_PATH"
expect_failure "checksum verification rejects duplicate entries" verify_checksums

rm -f "$CHECKSUMS_PATH"
generate_checksums
printf 'tamper' >> "$APP_BUNDLE/Contents/PkgInfo"
expect_failure "checksum verification covers every app regular file" verify_checksums

DIST_DIR=$old_dist_dir
APP_BUNDLE=$old_app_bundle
DMG_PATH=$old_dmg_path
MANIFEST_PATH=$old_manifest_path
CHECKSUMS_PATH=$old_checksums_path

stale_dir="$fixtures/stale-dir"
mkdir -p "$stale_dir"
printf 'stale' > "$stale_dir/file"
safe_remove_unmounted "$stale_dir"
[ ! -e "$stale_dir" ] || fail "stale directory was not removed"
pass "unmounted staging cleanup removes stale files"

legacy_stage="$ARTIFACTS_DIR/dmg-stage"
mkdir -p "$legacy_stage"
printf 'stale' > "$legacy_stage/file"
cleanup_stale_packaging_files
[ ! -e "$legacy_stage" ] || fail "legacy fixed-name DMG staging directory was not removed"
pass "legacy fixed-name DMG staging residue is removed"

fake_bin="$fixtures/fake-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/hdiutil" <<'SH'
#!/bin/sh
exit 1
SH
chmod 0755 "$fake_bin/hdiutil"
mount_fixture="$fixtures/preserved-mount"
attach_fixture="$fixtures/preserved-attach.plist"
mkdir -p "$mount_fixture"
printf 'attach' > "$attach_fixture"
PATH="$fake_bin:$PATH"
export PATH
expect_failure "detach failure is surfaced" detach_and_cleanup /dev/fake "$mount_fixture" "$attach_fixture"
[ -d "$mount_fixture" ] || fail "mount path was removed after detach failure"
[ -f "$attach_fixture" ] || fail "attach record was removed after detach failure"
pass "detach failure preserves mount path and attach record"

printf 'Focused packaging regression checks passed.\n'
