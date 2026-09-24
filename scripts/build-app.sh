#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:-$project_dir/build}"
app_dir="$output_dir/Microphone Choice.app"
resource_dir="$app_dir/Contents/Resources"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$resource_dir" "$app_dir/Contents/MacOS" "$work_dir/MicChoice.iconset"
cp "$project_dir/Assets/Info.plist" "$app_dir/Contents/Info.plist"

source_file="$project_dir/Sources/MicrophoneChoice/main.swift"
sdk_dir="$(xcrun --sdk macosx --show-sdk-path)"
for architecture in arm64 x86_64; do
  swiftc -O -target "${architecture}-apple-macos13.0" -sdk "$sdk_dir" \
    "$source_file" -o "$work_dir/MicChoice-$architecture"
done
lipo -create "$work_dir/MicChoice-arm64" "$work_dir/MicChoice-x86_64" \
  -output "$app_dir/Contents/MacOS/MicChoice"

icon_source="$project_dir/Assets/MicChoice.png"
iconset_dir="$work_dir/MicChoice.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$icon_source" \
    --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips -z "$double_size" "$double_size" "$icon_source" \
    --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
sips -z 1024 1024 "$icon_source" --out "$resource_dir/MicChoice.png" >/dev/null
iconutil -c icns "$iconset_dir" -o "$resource_dir/MicChoice.icns"

# Developers can supply a Developer ID identity for their own signed builds.
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$app_dir"
codesign --verify --deep --strict "$app_dir"
plutil -lint "$app_dir/Contents/Info.plist"
printf 'Built %s\n' "$app_dir"
