#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
HELPER="$SCRIPT_DIR/release-finalization.sh"
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/release-finalization-test.XXXXXX")
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "expected file: $1"
}

assert_absent() {
  [ ! -e "$1" ] || fail "expected path to be absent: $1"
}

assert_output() {
  expected=$1
  actual=$2
  [ "$actual" = "$expected" ] || fail "expected output '$expected', got '$actual'"
}

printf 'fixture: stale workspace cleanup\n'
mkdir -p "$WORKDIR/cleanup/candidate" "$WORKDIR/cleanup/release-transfer"
printf stale > "$WORKDIR/cleanup/candidate/stale"
printf stale > "$WORKDIR/cleanup/release-transfer/stale"
(
  cd "$WORKDIR/cleanup"
  "$HELPER" clean-workspace candidate release-transfer
)
assert_absent "$WORKDIR/cleanup/candidate"
assert_absent "$WORKDIR/cleanup/release-transfer"

printf 'fixture: archive transfer and AppleDouble rejection\n'
mkdir -p "$WORKDIR/archive/source/signed" "$WORKDIR/archive/source/sparkle"
printf dmg > "$WORKDIR/archive/source/signed/ForgeCode-1.2.3.dmg"
printf tool > "$WORKDIR/archive/source/sparkle/sign_update"
if command -v xattr >/dev/null 2>&1; then
  xattr -w com.forge.fixture metadata "$WORKDIR/archive/source/signed/ForgeCode-1.2.3.dmg"
fi
"$HELPER" create-archive "$WORKDIR/archive/transfer.tar.gz" "$WORKDIR/archive/source"
if tar -tzf "$WORKDIR/archive/transfer.tar.gz" | grep -Eq '(^|/)\._'; then
  fail "COPYFILE_DISABLE archive contains an AppleDouble entry"
fi
mkdir -p "$WORKDIR/archive/extracted"
python3 - "$WORKDIR/archive/transfer.tar.gz" "$WORKDIR/archive/extracted" <<'PY'
import pathlib
import tarfile
import sys

archive = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
with tarfile.open(archive, "r:gz") as transfer:
    transfer.extractall(destination)
PY
assert_file "$WORKDIR/archive/extracted/signed/ForgeCode-1.2.3.dmg"
assert_file "$WORKDIR/archive/extracted/sparkle/sign_update"
"$HELPER" reject-appledouble "$WORKDIR/archive/extracted"
printf malicious > "$WORKDIR/archive/extracted/signed/._malicious"
if "$HELPER" reject-appledouble "$WORKDIR/archive/extracted" >/dev/null 2>&1; then
  fail "AppleDouble fixture should be rejected after extraction"
fi

printf 'fixture: appcast staging modes\n'
mkdir -p "$WORKDIR/staging/dist"
printf dmg > "$WORKDIR/staging/dist/ForgeCode-1.2.3.dmg"
printf appcast > "$WORKDIR/staging/dist/appcast.xml"
"$HELPER" stage-final "$WORKDIR/staging/dist" "$WORKDIR/staging/true" ForgeCode-1.2.3.dmg true
assert_file "$WORKDIR/staging/true/ForgeCode-1.2.3.dmg"
assert_file "$WORKDIR/staging/true/appcast.xml"
assert_file "$WORKDIR/staging/true/SHA256SUMS.transfer"
"$HELPER" verify-transfer "$WORKDIR/staging/true"
printf changed >> "$WORKDIR/staging/true/ForgeCode-1.2.3.dmg"
if "$HELPER" verify-transfer "$WORKDIR/staging/true" >/dev/null 2>&1; then
  fail "modified staged artifact should fail transfer checksum verification"
fi
"$HELPER" stage-final "$WORKDIR/staging/dist" "$WORKDIR/staging/false" ForgeCode-1.2.3.dmg false
assert_file "$WORKDIR/staging/false/ForgeCode-1.2.3.dmg"
assert_file "$WORKDIR/staging/false/SHA256SUMS.transfer"
assert_absent "$WORKDIR/staging/false/appcast.xml"
"$HELPER" verify-transfer "$WORKDIR/staging/false"
rm "$WORKDIR/staging/dist/appcast.xml"
if "$HELPER" stage-final "$WORKDIR/staging/dist" "$WORKDIR/staging/missing" ForgeCode-1.2.3.dmg true >/dev/null 2>&1; then
  fail "enabled appcast mode should require appcast.xml"
fi

printf 'fixture: obsolete asset cleanup selection\n'
assets=$(cat <<'EOF' | "$HELPER" obsolete-assets ForgeCode-1.2.3.dmg false
ForgeCode-1.2.2.dmg
ForgeCode-1.2.3.dmg
ForgeCode-unsigned.dmg
appcast.xml
notes.txt
other.dmg
EOF
)
assert_output $'ForgeCode-1.2.2.dmg\nForgeCode-unsigned.dmg\nappcast.xml' "$assets"
assets=$(printf '%s\n' appcast.xml | "$HELPER" obsolete-assets ForgeCode-1.2.3.dmg true)
assert_output '' "$assets"

printf 'All release finalization fixtures passed.\n'
