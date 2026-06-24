#!/bin/bash
#
# publish-release.sh - publish a Sparkle auto-update for the just-built, notarized
# Glimmer bundle. PROMPT-FREE from any session: the EdDSA key comes from the
# signing creds file (scripts/signing-creds.sh), GitHub from the gh token. Called
# by `make release-publish` AFTER `make dist` (so the bundle is Developer-ID
# signed, notarized, stapled, and a DMG already exists in <dist-dir>).
#
# Steps: ZIP the notarized bundle → EdDSA-sign the ZIP → create/upload the GitHub
# release on the public repo → insert the item into the Pages-hosted appcast.xml.
# (The public repo itself is the GPLv3 corresponding source, at the release tag.)
#
# Args: <short-version> <build-number> <app-path> <dist-dir> <releases-repo>
set -euo pipefail

SHORT="$1"; BUILD="$2"; APP="$3"; DIST="$4"; REPO="$5"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CREDS="$HERE/scripts/signing-creds.sh"
TOOLS="$("$HERE/scripts/sparkle-tools.sh")"
ZIP="$DIST/Glimmer-$SHORT.zip"
DMG="$DIST/Glimmer-$SHORT.dmg"
TAG="$SHORT"
ASSET_URL="https://github.com/$REPO/releases/download/$TAG/Glimmer-$SHORT.zip"
APPCAST="appcast.xml"

[ -d "$APP" ] || { echo "ERR: app bundle not found at $APP - run via 'make release-publish'" >&2; exit 1; }
"$CREDS" get SPARKLE_ED_PRIVATE_KEY >/dev/null || {
	echo "ERR: SPARKLE_ED_PRIVATE_KEY missing from $($CREDS path) - run 'make sparkle-keys' once" >&2; exit 1; }

# The release tag is advertised as the GPLv3 source, so it must be the exact commit
# we built: require local HEAD == origin/main before pinning the tag below.
git -C "$HERE" fetch --quiet origin main
HEAD_SHA="$(git -C "$HERE" rev-parse HEAD)"
MAIN_SHA="$(git -C "$HERE" rev-parse origin/main)"
[ "$HEAD_SHA" = "$MAIN_SHA" ] || {
	echo "ERR: local HEAD ($HEAD_SHA) != origin/main ($MAIN_SHA)." >&2
	echo "  Bump Version.xcconfig, commit, merge to main, then 'git pull --ff-only' before publishing -" >&2
	echo "  the release tag is the GPLv3 source and must match the built commit." >&2
	exit 1
}

echo "▶ Zipping notarized bundle for Sparkle..."
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "▶ EdDSA-signing the update (prompt-free, key from creds file)..."
SIG_LINE="$("$CREDS" get SPARKLE_ED_PRIVATE_KEY | "$TOOLS/sign_update" --ed-key-file - "$ZIP")"
ED_SIG="$(printf '%s' "$SIG_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LENGTH="$(printf '%s' "$SIG_LINE" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
[ -n "$ED_SIG" ] && [ -n "$LENGTH" ] || { echo "ERR: sign_update produced no signature" >&2; exit 1; }
echo "  ✓ signed ($LENGTH bytes)"

echo "Publishing GitHub release ${TAG} to ${REPO}"
ASSETS=("$ZIP")
[ -f "$DMG" ] && ASSETS+=("$DMG")
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
	gh release upload "$TAG" "${ASSETS[@]}" -R "$REPO" --clobber
else
	gh release create "$TAG" "${ASSETS[@]}" -R "$REPO" --target "$HEAD_SHA" --title "Glimmer $SHORT" \
		--notes "Glimmer $SHORT. Auto-updates via Sparkle; the notarized DMG is attached. Source: this repo at tag $TAG (GPLv3)."
fi
echo "  ✓ release published"

# Single source of truth: the committed appcast.xml IS what Pages serves
# (main:/appcast.xml). Edit it in the tree and commit + push to main (no `gh api`
# PUT), so the committed copy never drifts. Committed AFTER the tag is pinned.
echo "▶ Updating the committed appcast (main:/$APPCAST is what Pages serves)..."
"$HERE/scripts/update-appcast.py" "$HERE/$APPCAST" \
	--short-version "$SHORT" --version "$BUILD" \
	--url "$ASSET_URL" --ed-signature "$ED_SIG" --length "$LENGTH" --min-system 26.0
if git -C "$HERE" diff --quiet -- "$APPCAST"; then
	echo "  ✓ appcast already current (no change to publish)"
else
	git -C "$HERE" add "$APPCAST"
	# A pre-commit hook may reformat the machine-written appcast and abort the
	# first commit; re-stage the fixed file and retry once.
	if ! git -C "$HERE" commit -m "appcast: Glimmer $SHORT" --quiet; then
		git -C "$HERE" add "$APPCAST"
		git -C "$HERE" commit -m "appcast: Glimmer $SHORT" --quiet
	fi
	git -C "$HERE" push --quiet origin HEAD:main
	echo "  ✓ appcast committed + pushed to main → $(git -C "$HERE" rev-parse --short HEAD)"
fi

echo "✅ Published Glimmer $SHORT - Sparkle clients see it within a day (or now via Check for Updates...)."
