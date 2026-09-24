#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:-$project_dir/build}"
"$project_dir/scripts/build-app.sh" "$output_dir"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$output_dir/Microphone Choice.app/Contents/Info.plist")"
archive="$output_dir/Microphone-Choice-$version-macos-universal.zip"
ditto -c -k --sequesterRsrc --keepParent \
  "$output_dir/Microphone Choice.app" "$archive"
shasum -a 256 "$archive"
printf 'Packaged %s\n' "$archive"
