#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

# No `xz` binary required: extraction uses bsdtar's built-in libarchive xz
# support (tar -xJf) and Python's stdlib lzma (tarfile "r:xz"), both present on
# a stock macOS. Requiring `xz` would force a Homebrew dependency on CI runners.
require_command tar
require_command python3
require_command lipo
require_command file

fetch_arch() {
  arch=$1
  archive=$2
  expected_sha=$3
  output_name=$4
  destination="$PROJECT_ROOT/Vendor/forge3/$arch"
  archive_path="$ARTIFACTS_DIR/$archive"
  extract_dir="$ARTIFACTS_DIR/extract-$arch"
  url="https://github.com/$FORGE3_REPOSITORY/releases/download/$FORGE3_VERSION/$archive"

  assert_inside_project "$destination"
  mkdir -p "$destination"

  printf 'Fetching %s from immutable release %s...\n' "$arch" "$FORGE3_VERSION"
  if [ "${FORGE3_OFFLINE:-0}" = "1" ]; then
    [ -f "$archive_path" ] || fail "offline mode requires cached archive: $archive_path"
  else
    safe_remove "$archive_path.tmp"
    # $FORGE3_REPOSITORY is private, so every download path needs credentials.
    # Unauthenticated requests return 404 (not 401), which is why an explicit
    # preflight check is worth more than letting curl fail opaquely.
    token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      gh release download "$FORGE3_VERSION" \
        --repo "$FORGE3_REPOSITORY" \
        --pattern "$archive" \
        --dir "$ARTIFACTS_DIR" \
        --clobber
    elif [ -n "$token" ]; then
      # Private-repo assets cannot be fetched from the browser download URL;
      # resolve the asset id via the API, then request the octet-stream.
      require_command curl
      asset_url=$(
        curl --fail --silent --location --proto '=https' --tlsv1.2 --retry 3 \
          --header "Authorization: Bearer $token" \
          --header "Accept: application/vnd.github+json" \
          "https://api.github.com/repos/$FORGE3_REPOSITORY/releases/tags/$FORGE3_VERSION" |
          python3 -c '
import json, sys
wanted = sys.argv[1]
data = json.load(sys.stdin)
for asset in data.get("assets", []):
    if asset.get("name") == wanted:
        print(asset["url"])
        break
' "$archive"
      ) || fail "unable to query release $FORGE3_VERSION in $FORGE3_REPOSITORY (check token scope: needs 'repo')"
      [ -n "$asset_url" ] || fail "release $FORGE3_VERSION has no asset named $archive"
      curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
        --header "Authorization: Bearer $token" \
        --header "Accept: application/octet-stream" \
        --output "$archive_path.tmp" "$asset_url"
      mv "$archive_path.tmp" "$archive_path"
    else
      fail "$FORGE3_REPOSITORY is private and no credentials were found.
Provide one of:
  - an authenticated 'gh' CLI (run: gh auth login), or
  - a GH_TOKEN/GITHUB_TOKEN environment variable with 'repo' scope.
Alternatively set FORGE3_OFFLINE=1 to reuse a cached archive at:
  $archive_path
Release URL: $url"
    fi
  fi

  actual_sha=$(sha256_file "$archive_path")
  [ "$actual_sha" = "$expected_sha" ] || fail "$archive checksum mismatch: expected $expected_sha, got $actual_sha"

  safe_remove "$extract_dir"
  mkdir -p "$extract_dir"
  case "$(file -b "$archive_path")" in
    *"XZ compressed data"*) ;;
    *) fail "$archive is not an XZ-compressed archive" ;;
  esac
  python3 - "$archive_path" "$archive" <<'PY' || fail "invalid forge3 archive structure"
import pathlib
import sys
import tarfile

archive_path, archive_name = sys.argv[1:]
seen = set()
forge_members = []
with tarfile.open(archive_path, mode="r:xz") as archive:
    members = archive.getmembers()
    if not members:
        raise SystemExit(f"{archive_name} is empty")
    for member in members:
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or "\\" in member.name:
            raise SystemExit(f"unsafe archive path in {archive_name}: {member.name}")
        if member.name in seen:
            raise SystemExit(f"duplicate archive member in {archive_name}: {member.name}")
        seen.add(member.name)
        if member.issym() or member.islnk():
            raise SystemExit(f"links are not allowed in {archive_name}: {member.name}")
        if path.name == "forge3":
            if not member.isfile():
                raise SystemExit(f"forge3 member is not a regular file in {archive_name}: {member.name}")
            forge_members.append(member.name)
if len(forge_members) != 1:
    raise SystemExit(
        f"{archive_name} must contain exactly one regular-file member whose basename is forge3; "
        f"found {len(forge_members)}"
    )
PY
  tar -xJf "$archive_path" -C "$extract_dir" --no-same-owner --no-same-permissions
  binary=$(find "$extract_dir" -type f -name forge3 -print)
  [ "$(printf '%s\n' "$binary" | awk 'NF {count++} END {print count+0}')" = "1" ] \
    || fail "extraction did not produce exactly one regular forge3 file"

  cp "$binary" "$destination/$output_name"
  chmod 0755 "$destination/$output_name"
  actual_arch=$(lipo -archs "$destination/$output_name" 2>/dev/null || file "$destination/$output_name")
  case "$arch:$actual_arch" in
    aarch64:arm64|x86_64:x86_64) ;;
    *) fail "unexpected or multi-slice architecture for $destination/$output_name: $actual_arch" ;;
  esac
  validate_macho "$destination/$output_name" "$(printf '%s' "$arch" | sed 's/aarch64/arm64/')"
  expected_version=${FORGE3_VERSION#v}
  actual_version=$("$destination/$output_name" --version 2>/dev/null | awk 'NF {print $NF; exit}')
  [ "$actual_version" = "$expected_version" ] \
    || fail "forge3 version mismatch for $arch: expected $expected_version, got ${actual_version:-none}"
  printf '%s  %s\n' "$expected_sha" "$archive" > "$destination/$archive.sha256"
  printf 'Staged %s\n' "$destination/$output_name"
}

fetch_arch "aarch64" "$FORGE3_AARCH64_ARCHIVE" "$FORGE3_AARCH64_SHA256" "forge3-aarch64"
fetch_arch "x86_64" "$FORGE3_X86_64_ARCHIVE" "$FORGE3_X86_64_SHA256" "forge3-x86_64"
