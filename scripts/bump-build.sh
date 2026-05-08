#!/usr/bin/env bash
# Increments CURRENT_PROJECT_VERSION in ios/project.yml by 1.
# Run once before each push of code changes so the build number visible
# in the watch + iPhone UI advances with every deployment.
#
# Usage:
#   scripts/bump-build.sh
#
# After running:
#   cd ios && xcodegen generate    # picks up the new value
#
# (Marketing version — CFBundleShortVersionString — is bumped manually
#  on milestones; it's MARKETING_VERSION in project.yml.)
set -euo pipefail

cd "$(dirname "$0")/.."

YML="ios/project.yml"
[[ -f "$YML" ]] || { echo "error: $YML not found"; exit 1; }

current=$(grep -E '^\s*CURRENT_PROJECT_VERSION:' "$YML" | head -1 | sed -E 's/.*"([0-9]+)".*/\1/')
[[ -n "$current" ]] || { echo "error: could not read CURRENT_PROJECT_VERSION from $YML"; exit 1; }

next=$((current + 1))

# macOS sed needs the empty -i argument
sed -i '' -E "s/(CURRENT_PROJECT_VERSION:[[:space:]]+)\"$current\"/\1\"$next\"/" "$YML"

echo "build: $current → $next"
