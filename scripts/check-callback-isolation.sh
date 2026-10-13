#!/usr/bin/env bash
# Fails the build when a closure literal is handed straight to a framework
# callback that fires OFF the main queue from inside a @MainActor type.
# Such a closure inherits @MainActor and traps (_dispatch_assert_queue_fail)
# the first time the framework calls it: field crashes 2026-06-11 (WC),
# 2026-09 (AVAudioEngine tap), 2026-10-12 (CMPedometer), 2026-10-13 x2 (WC).
# The fix is always the same: bind the closure to an explicit
# `@Sendable (...) -> Void` constant and hop to the main actor inside.
set -euo pipefail
cd "$(dirname "$0")/.."
PAT='errorHandler: \{|replyHandler: \{|withHandler: \{|queryPedometerData\([^)]*\) \{|startUpdates\([^)]*\) \{|requestRecordPermission \{|requestRecordPermission\(\) \{|installTap\([^)]*block: \{|enableBackgroundDelivery\([^)]*\) \{|requestAuthorization\(toShare[^)]*\) \{|pathUpdateHandler = \{|initialResultsHandler = \{|statisticsUpdateHandler = \{|HKWorkoutRouteQuery\([^)]*\) \{|HKSampleQuery\([^)]*\) \{|HKAnchoredObjectQuery\([^)]*\) \{|HKObserverQuery\([^)]*\) \{'
bad=0
while IFS= read -r f; do
  grep -q "^@MainActor" "$f" || continue
  hits=$(grep -nE "$PAT" "$f" | grep -vE '^\s*[0-9]+:\s*//' || true)
  if [ -n "$hits" ]; then
    echo "$f:"; echo "$hits" | sed 's/^/    /'; bad=1
  fi
done < <(find ios/AARC ios/AARCWatch ios/AARCKit -name '*.swift' -not -path '*/Preview*')
if [ "$bad" = 1 ]; then
  echo "callback-isolation: inline closure handed to an off-main framework callback inside a @MainActor type. Bind it as 'let h: @Sendable (...) -> Void' first."
  exit 1
fi
echo "callback-isolation: clean"
