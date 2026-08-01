#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

command=${1:-}
[ -n "$command" ] || fail "command is required"
shift

case "$command" in
  clean-workspace)
    [ "$#" -gt 0 ] || fail "clean-workspace requires at least one path"
    rm -rf -- "$@"
    ;;

  create-archive)
    [ "$#" -eq 2 ] || fail "create-archive requires ARCHIVE SOURCE_DIR"
    archive=$1
    source_dir=$2
    [ -d "$source_dir" ] || fail "archive source directory does not exist: $source_dir"
    mkdir -p "$(dirname "$archive")"
    rm -f "$archive"
    COPYFILE_DISABLE=1 tar -C "$source_dir" -czf "$archive" .
    ;;

  reject-appledouble)
    [ "$#" -eq 1 ] || fail "reject-appledouble requires EXTRACTED_DIR"
    extracted_dir=$1
    [ -d "$extracted_dir" ] || fail "extracted directory does not exist: $extracted_dir"
    appledouble=$(find "$extracted_dir" -name '._*' -print -quit)
    [ -z "$appledouble" ] || fail "AppleDouble entry found in transfer archive: $appledouble"
    ;;

  stage-final)
    [ "$#" -eq 4 ] || fail "stage-final requires DIST_DIR STAGING_DIR DMG_FILE HAS_APPCAST"
    dist=$1
    staging=$2
    dmg_file=$3
    has_appcast=$4
    [ -f "$dist/$dmg_file" ] || fail "missing final DMG: $dist/$dmg_file"
    rm -rf "$staging"
    mkdir -p "$staging"
    cp "$dist/$dmg_file" "$staging/"
    files=("$dmg_file")
    case "$has_appcast" in
      true)
        [ -f "$dist/appcast.xml" ] || fail "appcast mode is enabled but appcast.xml is missing"
        cp "$dist/appcast.xml" "$staging/"
        files+=(appcast.xml)
        ;;
      false)
        ;;
      *)
        fail "HAS_APPCAST must be true or false, got: $has_appcast"
        ;;
    esac
    (
      cd "$staging"
      if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${files[@]}"
      else
        shasum -a 256 "${files[@]}"
      fi > SHA256SUMS.transfer
    )
    ;;

  verify-transfer)
    [ "$#" -eq 1 ] || fail "verify-transfer requires STAGING_DIR"
    staging=$1
    [ -f "$staging/SHA256SUMS.transfer" ] || fail "missing transfer checksum file"
    (
      cd "$staging"
      if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -c SHA256SUMS.transfer
      else
        shasum -a 256 -c SHA256SUMS.transfer
      fi
    )
    ;;

  obsolete-assets)
    [ "$#" -eq 2 ] || fail "obsolete-assets requires CURRENT_DMG HAS_APPCAST"
    current_dmg=$1
    has_appcast=$2
    case "$has_appcast" in
      true|false)
        ;;
      *)
        fail "HAS_APPCAST must be true or false, got: $has_appcast"
        ;;
    esac
    while IFS= read -r asset; do
      case "$asset" in
        ForgeCode-*.dmg)
          [ "$asset" = "$current_dmg" ] || printf '%s\n' "$asset"
          ;;
        appcast.xml)
          [ "$has_appcast" = true ] || printf '%s\n' "$asset"
          ;;
      esac
    done
    ;;

  *)
    fail "unknown command: $command"
    ;;
esac
