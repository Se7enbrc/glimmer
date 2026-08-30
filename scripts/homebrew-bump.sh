#!/bin/bash
#
# homebrew-bump.sh - point the Homebrew cask at a published Glimmer release.
# Downloads the release DMG, computes its sha256 from the real bytes, rewrites
# version + sha256 in the tap's Casks/glimmer.rb, then commits and pushes.
#
# Run this AFTER the GitHub release exists (scripts/publish-release.sh uploads
# it); `make release-publish` calls it as the last step. Safe to re-run: if the
# cask already matches the published DMG it reports "already current" and makes
# no commit.
#
# Usage:  scripts/homebrew-bump.sh [version]     # default: Glimmer/Version.xcconfig
# Override the repos with RELEASES_REPO / TAP_REPO; relocate the tap checkout
# with GLIMMER_TAP_CACHE. No secrets: gh for the download, git over SSH to push.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(sed -n 's/^MARKETING_VERSION = \(.*\)/\1/p' "$HERE/Glimmer/Version.xcconfig" | tr -d ' ')}"
RELEASES_REPO="${RELEASES_REPO:-Se7enbrc/glimmer}"
TAP_REPO="${TAP_REPO:-Se7enbrc/homebrew-glimmer}"
TAP_DIR="${GLIMMER_TAP_CACHE:-$HOME/.cache/glimmer/homebrew-glimmer}"
CASK="Casks/glimmer.rb"
DMG="Glimmer-$VERSION.dmg"

[ -n "$VERSION" ] || { echo "ERR: no version given and none found in Glimmer/Version.xcconfig" >&2; exit 1; }

# The cask pins a sha256, so the release asset must already be published.
gh release view "$VERSION" -R "$RELEASES_REPO" >/dev/null 2>&1 || {
	echo "ERR: release $VERSION not found on $RELEASES_REPO - publish it first ('make release-publish')" >&2; exit 1; }

echo "▶ Downloading $DMG to checksum it..."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
gh release download "$VERSION" -R "$RELEASES_REPO" -p "$DMG" -D "$TMP" --clobber
SHA="$(shasum -a 256 "$TMP/$DMG" | cut -d' ' -f1)"
echo "  ✓ sha256 $SHA"

if [ -d "$TAP_DIR/.git" ]; then
	git -C "$TAP_DIR" fetch --quiet origin main
	git -C "$TAP_DIR" reset --quiet --hard origin/main
else
	rm -rf "$TAP_DIR"
	mkdir -p "$(dirname "$TAP_DIR")"
	git clone --quiet "git@github.com:$TAP_REPO.git" "$TAP_DIR"
fi

sed -i '' \
	-e "s|^  version \".*\"$|  version \"$VERSION\"|" \
	-e "s|^  sha256 \".*\"$|  sha256 \"$SHA\"|" \
	"$TAP_DIR/$CASK"

# Fail loud rather than pushing a cask the sed didn't actually touch (a renamed
# stanza or reindent would silently no-op both expressions above).
grep -q "^  version \"$VERSION\"$" "$TAP_DIR/$CASK" && grep -q "^  sha256 \"$SHA\"$" "$TAP_DIR/$CASK" || {
	echo "ERR: $CASK does not carry version $VERSION + that sha256 after the rewrite - check its stanza format" >&2
	exit 1
}

if git -C "$TAP_DIR" diff --quiet -- "$CASK"; then
	echo "✅ Homebrew cask already current at $VERSION - nothing to push."
	exit 0
fi

git -C "$TAP_DIR" add "$CASK"
git -C "$TAP_DIR" commit --quiet -m "glimmer $VERSION"
git -C "$TAP_DIR" push --quiet origin HEAD:main
echo "✅ Homebrew cask bumped to $VERSION - 'brew install --cask se7enbrc/glimmer/glimmer'."
