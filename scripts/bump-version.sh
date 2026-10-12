#!/usr/bin/env bash
# Bumps MARKETING_VERSION (CFBundleShortVersionString) in ios/project.yml.
# Apple's three-section scheme: MAJOR.MINOR.PATCH.
#
#   scripts/bump-version.sh patch   # 0.3.0 -> 0.3.1  fixes only, no new behaviour
#   scripts/bump-version.sh minor   # 0.3.1 -> 0.4.0  new feature the runner can see
#   scripts/bump-version.sh major   # 0.4.0 -> 1.0.0  App Store release / breaking
#
# The build number (CURRENT_PROJECT_VERSION) keeps counting up on its own via
# scripts/bump-build.sh; it never resets. Version says WHAT changed, build
# says WHICH upload. Every TestFlight ship needs a build bump; a version bump
# only when the change is worth a line in release notes.
set -euo pipefail
cd "$(dirname "$0")/.."
YML="ios/project.yml"
part="${1:-}"
cur=$(grep -E '^\s*MARKETING_VERSION:' "$YML" | head -1 | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/')
IFS=. read -r MA MI PA <<<"$cur"
case "$part" in
  major) MA=$((MA+1)); MI=0; PA=0 ;;
  minor) MI=$((MI+1)); PA=0 ;;
  patch) PA=$((PA+1)) ;;
  *) echo "usage: $0 major|minor|patch  (current $cur)"; exit 1 ;;
esac
next="$MA.$MI.$PA"
sed -i '' -E "s/(MARKETING_VERSION:[[:space:]]+)\"$cur\"/\1\"$next\"/" "$YML"
echo "version: $cur → $next"
