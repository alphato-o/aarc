#!/usr/bin/env bash
#
# doc-refresh-check — weekly "are the docs drifting?" detector. Pure shell, no
# LLM, no permissions: it counts the meaningful commits since the docs were last
# refreshed and, past a threshold, raises a flag + a desktop notification so the
# docs never silently go stale. The actual refresh stays a quick task (ask the
# agent: "refresh the docs"). Meant to be run by launchd (see the .plist that
# loads it). Safe to run by hand any time.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 0
THRESHOLD="${DOC_DRIFT_THRESHOLD:-4}"     # non-doc commits since last docs: commit
FLAG="$REPO/private/.doc-refresh-due"
LOG="$REPO/private/doc-refresh-check.log"

git pull --ff-only >/dev/null 2>&1 || true

LAST_DOCS="$(git log -1 --format=%H --grep='^docs:' 2>/dev/null || true)"
if [ -z "$LAST_DOCS" ]; then echo "$(date): no docs: commit found — skip" >> "$LOG"; exit 0; fi

# commits since the last docs refresh, excluding doc-only changes
N="$(git log --oneline "$LAST_DOCS"..HEAD -- . ':(exclude)docs' ':(exclude)README.md' 2>/dev/null | wc -l | tr -d ' ')"
SINCE="$(git log -1 --format=%cd --date=short "$LAST_DOCS" 2>/dev/null)"

echo "$(date): $N non-doc commits since last docs refresh ($SINCE), threshold $THRESHOLD" >> "$LOG"

if [ "${N:-0}" -ge "$THRESHOLD" ]; then
  {
    echo "# Docs may be stale"
    echo "$N commits have landed since the last docs refresh ($SINCE)."
    echo "Ask the agent: \"refresh the docs\" — or run a full review. Recent work:"
    echo
    git log --oneline "$LAST_DOCS"..HEAD -- . ':(exclude)docs' ':(exclude)README.md' | head -30
  } > "$FLAG"
  osascript -e "display notification \"$N commits since last docs refresh\" with title \"AARC: docs refresh due\"" >/dev/null 2>&1 || true
else
  rm -f "$FLAG"   # back in sync
fi
