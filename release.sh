#!/bin/bash
# Usage: ./release.sh 1.2.0 — builds, tags, publishes a GitHub release and bumps the Homebrew cask.
set -euo pipefail
cd "$(dirname "$0")"
V="${1:?version, e.g. 1.2.0}"
echo "$V" > VERSION
./build.sh --zip
SHA=$(shasum -a 256 build/AgentAwake.zip | cut -d' ' -f1)
git add VERSION && git commit -qm "Release v$V" || true
git tag "v$V" && git push -q && git push -q origin "v$V"
gh release create "v$V" build/AgentAwake.zip --title "AgentAwake $V" --generate-notes
TAP=$(mktemp -d)
gh repo clone emretufekci/homebrew-tap "$TAP" -- -q
sed -i '' -e "s/^  version \".*\"/  version \"$V\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/agent-awake.rb"
git -C "$TAP" commit -qam "agent-awake $V" && git -C "$TAP" push -q
rm -rf "$TAP"
echo "Released $V (sha256 $SHA)"
