#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

require_command swift
require_command iconutil

output="$ARTIFACTS_DIR/assets"
iconset="$output/AppIcon.iconset"
safe_remove "$output"
mkdir -p "$iconset"

master="$output/AppIcon-1024.png"
background="$output/dmg-background.png"
swift "$PROJECT_ROOT/resources/generate-assets.swift" "$master" "$background"

require_command sips
for spec in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"
do
  set -- $spec
  sips -z "$1" "$1" "$master" --out "$iconset/$2" >/dev/null
 done

iconutil -c icns "$iconset" -o "$output/AppIcon.icns"
printf '%s\n' "$output"
