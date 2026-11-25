#!/usr/bin/env bash
# Generates the iOS project and runs its whole test scheme on one simulator.
# The iOS hook set (.ios_dev.md) runs it before each task commit.
#
# Usage: test/ios_test.sh [xcodebuild options...]
#   IOS_TEST_DESTINATION  the xcodebuild destination
#                         (default: an iPhone 17 simulator)
#
# Exits 0 only when xcodebuild passes and at least one test ran. A failure
# prints the lines that name it and the end of the log. If the script is
# killed (a hook deadline), it stops xcodebuild and prints the end of the log.
set -u

destination="${IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
# A hook may start without Homebrew on its PATH.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

cd "$(dirname "$0")/.." || exit 1

for tool in xcodegen xcodebuild; do
  if ! command -v "$tool" > /dev/null; then
    echo "$tool is not installed, so the iOS tests cannot run" >&2
    exit 1
  fi
done

xcodegen generate --quiet --spec mobile/ios/project.yml || exit 1

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

xcodebuild test -project mobile/ios/Stride.xcodeproj -scheme Stride \
  -destination "$destination" "$@" > "$log" 2>&1 &
pid=$!

on_kill() {
  kill "$pid" 2>/dev/null
  echo "== iOS tests killed before they ended; the last 200 lines follow"
  tail -n 200 "$log"
  exit 143
}
trap on_kill TERM INT

if ! wait "$pid"; then
  echo "== iOS tests FAILED on $destination"
  grep -E 'error:|✘|\*\* TEST' "$log" | sort -u | head -n 60
  echo "== the last 100 lines follow"
  tail -n 100 "$log"
  exit 1
fi

if ! grep -qE 'Test run with [1-9][0-9]* tests?' "$log"; then
  echo "== xcodebuild passed but ran no Swift Testing tests on $destination"
  exit 1
fi

echo "== iOS tests passed on $destination"
grep -E 'Test run with|Executed [1-9]' "$log" | sort -u
