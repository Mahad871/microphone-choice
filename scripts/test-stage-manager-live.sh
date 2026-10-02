#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/stage-fill-live.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
swiftc "$project_dir"/Sources/MicrophoneChoice/StageManagerFill/*.swift \
  "$project_dir/Tests/StageFillLiveTests.swift" \
  -framework AppKit -framework ApplicationServices -framework ColorSync \
  -o "$test_dir/StageFillLiveTests"
"$test_dir/StageFillLiveTests"
