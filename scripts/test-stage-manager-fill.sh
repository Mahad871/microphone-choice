#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_binary="$(mktemp /tmp/stage-fill-tests.XXXXXX)"
trap 'rm -f "$test_binary"' EXIT
swiftc "$project_dir/Sources/MicrophoneChoice/StageManagerFill/StageFillGeometry.swift" \
  "$project_dir/Sources/MicrophoneChoice/StageManagerFill/StageFillPreferences.swift" \
  "$project_dir/Tests/StageFillTests.swift" \
  -framework AppKit -framework ColorSync -o "$test_binary"
"$test_binary"
