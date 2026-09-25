#!/bin/bash
# Cuts a release so the app, the tag and the GitHub release all say the same
# version: sets MARKETING_VERSION, commits, builds the disk image from that
# commit, tags it v<version> and publishes it on GitHub.
#
#   ./scripts/release.sh 0.1.2          tag v0.1.2
#   ./scripts/release.sh 0.1.2-beta     tag v0.1.2-beta (the app shows 0.1.2)
#
# Needs a clean tree on main, and `gh` signed in. Asks before pushing.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG_VERSION="${1:-}"
[[ "$TAG_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] \
    || { echo "Usage: $0 <major.minor.patch[-suffix]>"; exit 1; }
VERSION="${TAG_VERSION%%-*}"   # CFBundleShortVersionString takes numbers only
TAG="v$TAG_VERSION"

[[ "$(git branch --show-current)" == "main" ]] || { echo "Release from main."; exit 1; }
git diff --quiet HEAD -- || { echo "Commit or stash your changes first."; exit 1; }
git fetch --tags --quiet origin
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "$TAG already exists."; exit 1; }

echo "→ Setting version $VERSION"
sed -i '' -E "s/^( *MARKETING_VERSION: *)\"[^\"]*\"/\1\"$VERSION\"/" project.yml
grep -q "MARKETING_VERSION: \"$VERSION\"" project.yml || { echo "Couldn't set MARKETING_VERSION."; exit 1; }
xcodegen generate >/dev/null
git add project.yml FourNotes.xcodeproj/project.pbxproj
git diff --cached --quiet || git commit -m "Release $TAG" --quiet

# Built after the commit, so the app's stamped commit is the tagged one.
./scripts/make-dmg.sh --label "$TAG_VERSION"
DMG="build/FourNotes-$TAG_VERSION.dmg"
[[ -f "$DMG" ]] || { echo "No disk image at $DMG"; exit 1; }

read -r -p "Push $TAG and publish $DMG on GitHub? [y/N] " answer
[[ "$answer" == [yY] ]] || { echo "Stopped. The release commit is local; nothing was pushed."; exit 0; }

git tag -a "$TAG" -m "Four Notes $TAG_VERSION"
git push origin HEAD "$TAG"
gh release create "$TAG" "$DMG" --title "Four Notes $TAG_VERSION" --generate-notes
echo "✓ Released $TAG"
