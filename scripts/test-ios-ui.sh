#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# A simulator shares app storage across test processes. Reject overlapping runs.
lock_dir="${TMPDIR:-/tmp}/signalword-ios-ui.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "Another UI run owns $lock_dir. Wait for it; remove a stale lock only after checking the runner has stopped." >&2
  exit 1
fi
trap 'rmdir "$lock_dir"' EXIT

# Pick an installed iPhone simulator instead of hard-coding a developer's device ID.
device_id="${SIGNALWORD_SIMULATOR_ID:-}"
if [ -z "$device_id" ]; then
  device_id="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
for devices in json.load(sys.stdin)["devices"].values():
    for device in devices:
        if device["name"].startswith("iPhone"):
            print(device["udid"])
            sys.exit(0)
sys.exit("No available iPhone simulator. Install an iOS runtime in Xcode.")
')"
fi
results="$(mktemp -d "${TMPDIR:-/tmp}/signalword-ui.XXXXXX")"
printf 'UI test artifacts: %s\n' "$results"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'results=%s\n' "$results" >> "$GITHUB_OUTPUT"
fi
finish() {
  status=$?
  # Quiet xcodebuild output omits assertion details. Preserve the actual failure
  # report and screenshots so CI failures can be diagnosed from the run.
  if [ -d "$results/Journey.xcresult" ]; then
    xcrun xcresulttool get test-results summary --path "$results/Journey.xcresult" \
      > "$results/summary.json" 2>/dev/null || true
    if [ "$status" -ne 0 ] && [ -s "$results/summary.json" ]; then
      cat "$results/summary.json"
    fi
  fi
  rmdir "$lock_dir"
  exit "$status"
}
trap finish EXIT
# UI fixtures do not exempt the app from build configuration validation.
config_args=()
if [ -n "${SIGNALWORD_XCCONFIG:-}" ]; then
  config_args=(-xcconfig "$SIGNALWORD_XCCONFIG")
fi
xcodebuild -quiet "${config_args[@]}" \
  -project apps/ios/SignalWord.xcodeproj -scheme SignalWord \
  -configuration Debug -destination "platform=iOS Simulator,id=$device_id" \
  -derivedDataPath "$results/build" -resultBundlePath "$results/Journey.xcresult" \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 300 -collect-test-diagnostics never CODE_SIGN_IDENTITY=- test "$@"
