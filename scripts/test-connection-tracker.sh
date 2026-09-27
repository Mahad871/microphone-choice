#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_binary="$(mktemp /tmp/microphone-choice-tracker.XXXXXX)"
trap 'rm -f "$test_binary"' EXIT
swiftc "$project_dir/Sources/MicrophoneChoice/ConnectionTracker.swift" \
  "$project_dir/Sources/MicrophoneChoice/RememberedChoices.swift" \
  "$project_dir/Sources/MicrophoneChoice/AppSettings.swift" \
  "$project_dir/Sources/MicrophoneChoice/AudioDevices.swift" \
  "$project_dir/Sources/MicrophoneChoice/Diagnostics.swift" \
  "$project_dir/Sources/MicrophoneChoice/SingleInstance.swift" \
  "$project_dir/Sources/MicrophoneChoice/GlobalShortcut.swift" \
  "$project_dir/Sources/MicrophoneChoice/LaunchAgentStatus.swift" \
  "$project_dir/Tests/ConnectionTrackerTests.swift" \
  "$project_dir/Tests/RememberedChoicesTests.swift" \
  "$project_dir/Tests/AppSettingsTests.swift" \
  "$project_dir/Tests/GlobalShortcutTests.swift" -framework Carbon -o "$test_binary"
"$test_binary"
