#!/bin/bash
# Publish the prepared notarized DMG and Sparkle ZIP without changing their bytes.
# Update signing uses signing-creds.sh; GitHub authentication uses gh.
# Args: <short-version> <build-number> <app-path> <dist-dir> <releases-repo> [rc-tag]
set -euo pipefail

SHORT="$1"; BUILD="$2"; APP="$3"; DIST="$4"; REPO="$5"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CREDS="$HERE/scripts/signing-creds.sh"
ZIP="$DIST/Glimmer-$SHORT.zip"
DMG="$DIST/Glimmer-$SHORT.dmg"
PROVENANCE="$DIST/Glimmer-$SHORT.intoto.jsonl"
TAG="${6:-$SHORT}"
CHANNEL=""
TITLE="Glimmer $SHORT"
if [ "$#" -ge 6 ]; then
	RC_NUMBER="${TAG#"$SHORT"-rc.}"
	[[ "$TAG" = "$SHORT-rc.$RC_NUMBER" && "$RC_NUMBER" =~ ^[1-9][0-9]*$ ]] || {
		echo "ERR: candidate tag must be $SHORT-rc.N" >&2; exit 1; }
	[ "${GITHUB_ACTIONS:-}" = true ] || { echo "ERR: candidates require the hosted release workflow" >&2; exit 1; }
	CHANNEL=rc
	TITLE="Glimmer $SHORT (RC $RC_NUMBER)"
fi
ASSET_URL="https://github.com/$REPO/releases/download/$TAG/Glimmer-$SHORT.zip"
APPCAST="appcast.xml"

[ -d "$APP" ] || { echo "ERR: app bundle not found at $APP - run via 'make release-publish'" >&2; exit 1; }
make -C "$HERE" --no-print-directory guard-clean-tree
[ -f "$DMG" ] || { echo "ERR: DMG not found at $DMG - run 'make dist'" >&2; exit 1; }
[ -s "$ZIP" ] || { echo "ERR: prepared Sparkle ZIP missing - run 'make CONFIG=Release sparkle-zip'" >&2; exit 1; }

# The release tag must identify the exact source used to build the bundle.
git -C "$HERE" fetch --quiet origin main
HEAD_SHA="$(git -C "$HERE" rev-parse HEAD)"
MAIN_SHA="$(git -C "$HERE" rev-parse origin/main)"
if [ "$CHANNEL" = rc ]; then
	[ "$HEAD_SHA" = "${GITHUB_SHA:-}" ] && [ "$HEAD_SHA" = "${EXPECTED_SHA:-}" ] || {
		echo "ERR: candidate source does not match the reviewed workflow SHA" >&2; exit 1; }
	TAG_SHA="$(gh api "repos/$REPO/commits/$TAG" --jq .sha)"
	[ "$TAG_SHA" = "$HEAD_SHA" ] || { echo "ERR: candidate tag must already identify the reviewed source" >&2; exit 1; }
elif [ "$HEAD_SHA" != "$MAIN_SHA" ]; then
	echo "ERR: local HEAD ($HEAD_SHA) != origin/main ($MAIN_SHA)." >&2
	echo "  Bump Version.xcconfig, commit, merge to main, then 'git pull --ff-only' before publishing -" >&2
	echo "  the release tag is the GPLv3 source and must match the built commit." >&2
	exit 1
fi

WORK="$(mktemp -d -t glimmer-publication)"
trap 'rm -rf "$WORK"' EXIT
FEED="$HERE/$APPCAST"
if [ "${GITHUB_ACTIONS:-}" = true ]; then
	FEED="$WORK/$APPCAST"
	git -C "$HERE" show "$MAIN_SHA:$APPCAST" >"$FEED"
fi
python3 "$HERE/scripts/release_validation.py" \
	--config "$HERE/Glimmer/Version.xcconfig" --appcast "$FEED" --channel "$CHANNEL" \
	--short-version "$SHORT" --build "$BUILD" --app "$APP" --validate-distribution

# Version assertion: the committed version at the tag, the built bundle, and the
# advertised version ($SHORT) must all agree. A dirty .48 shipped with a bundle
# version that the committed source didn't carry; assert all three match so the
# tag's GPLv3 source always reproduces the binary. Fail loud on any mismatch.
COMMITTED_VERSION="$(git -C "$HERE" show "HEAD:Glimmer/Version.xcconfig" \
	| sed -n 's/^MARKETING_VERSION = \(.*\)/\1/p' | tr -d ' ')"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
	"$APP/Contents/Info.plist" 2>/dev/null || true)"
[ "$COMMITTED_VERSION" = "$SHORT" ] || {
	echo "ERR: committed MARKETING_VERSION ($COMMITTED_VERSION) at HEAD != advertised version ($SHORT)." >&2
	echo "  Bump + commit Version.xcconfig so the tag's source matches what you're publishing." >&2
	exit 1
}
[ "$BUNDLE_VERSION" = "$SHORT" ] || {
	echo "ERR: built bundle CFBundleShortVersionString ($BUNDLE_VERSION) != advertised version ($SHORT)." >&2
	echo "  Rebuild ('make dist') from the committed version - the bundle is stale." >&2
	exit 1
}
echo "  ✓ version $SHORT matches committed source AND the built bundle"

TOOLS="$("$HERE/scripts/sparkle-tools.sh")"
"$CREDS" get SPARKLE_ED_PRIVATE_KEY >/dev/null || {
	echo "ERR: SPARKLE_ED_PRIVATE_KEY missing from $($CREDS path) - run 'make sparkle-keys' once" >&2; exit 1; }

echo "▶ EdDSA-signing the update (prompt-free, key from creds file)..."
if ! SIG_LINE="$("$CREDS" get SPARKLE_ED_PRIVATE_KEY | "$TOOLS/sign_update" --ed-key-file - "$ZIP" 2>/dev/null)"; then
	echo "ERR: update signing failed; check the Sparkle key and signing tool. Nothing published." >&2
	exit 1
fi
ED_SIG="$(printf '%s' "$SIG_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LENGTH="$(printf '%s' "$SIG_LINE" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
[ -n "$ED_SIG" ] && [ -n "$LENGTH" ] || { echo "ERR: sign_update produced no signature" >&2; exit 1; }
APP_ED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null || true)"
"$HERE/scripts/verify-update-signature.swift" "$APP_ED_KEY" "$ED_SIG" "$ZIP" || {
	echo "ERR: the update signature doesn't match the app's SUPublicEDKey; installed copies would reject it." >&2
	exit 1
}
echo "  ✓ signed ($LENGTH bytes)"

# Release notes: this version's CHANGELOG.md section verbatim, which is also
# what the appcast <description> carries - one source of truth, so the GitHub
# release and Sparkle's "what's new" can never disagree. A version with no
# section falls back to the old one-line boilerplate rather than shipping empty.
NOTES="$WORK/notes.md"
if "$HERE/scripts/changelog.py" --version "$SHORT" --changelog "$HERE/CHANGELOG.md" >"$NOTES" 2>/dev/null \
	&& [ -s "$NOTES" ]; then
	echo "  ✓ release notes from CHANGELOG.md ($(wc -l <"$NOTES" | tr -d ' ') lines)"
else
	echo "  ! no '## $SHORT' section in CHANGELOG.md - using boilerplate release notes" >&2
	printf 'Glimmer %s. Auto-updates via Sparkle; the notarized DMG is attached.\n' "$SHORT" >"$NOTES"
fi
printf '\nSource: this repo at tag %s (GPLv3).\n' "$TAG" >>"$NOTES"

echo "Publishing GitHub release ${TAG} to ${REPO}"
ASSETS=("$ZIP")
[ -f "$DMG" ] && ASSETS+=("$DMG")
# The by-tag API returns 404 for a draft, so address the release by its id.
release_api() {
	local id
	id="$(gh release view "$TAG" -R "$REPO" --json databaseId -q .databaseId)"
	gh api "repos/$REPO/releases/$id" "$@"
}
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
	# A published version is immutable: Sparkle signatures and the Homebrew
	# cask checksum already point at these bytes. A retry may only add a
	# missing asset or confirm an identical one; anything else is a new version.
	TAG_SHA="$(gh api "repos/$REPO/commits/$TAG" --jq .sha 2>/dev/null || true)"
	[ "$TAG_SHA" = "$HEAD_SHA" ] || {
		echo "ERR: tag $TAG is at ${TAG_SHA:-unknown}, not HEAD ($HEAD_SHA). Published versions are immutable - bump the version." >&2
		exit 1
	}
	if [ "$CHANNEL" = rc ]; then
		[ "$(release_api --jq .prerelease)" = true ] || {
			echo "ERR: candidate tag is already a stable release" >&2; exit 1; }
	fi
	for asset in "${ASSETS[@]}"; do
		name="$(basename "$asset")"
		remote="$(release_api \
			--jq ".assets[] | select(.name==\"$name\") | .digest // \"unknown\"" 2>/dev/null || true)"
		local_digest="sha256:$(shasum -a 256 "$asset" | cut -d' ' -f1)"
		if [ -z "$remote" ]; then
			gh release upload "$TAG" "$asset" -R "$REPO"
			echo "  ✓ $name added to the existing release"
		elif [ "$remote" = "$local_digest" ]; then
			echo "  = $name already published with these bytes"
		else
			echo "ERR: $name is already published with different bytes ($remote). Published versions are immutable - bump the version." >&2
			exit 1
		fi
	done
else
	CREATE_ARGS=(--draft)
	if [ "$CHANNEL" = rc ]; then
		CREATE_ARGS+=(--prerelease --latest=false --verify-tag)
	else
		CREATE_ARGS+=(--target "$HEAD_SHA")
	fi
	gh release create "$TAG" "${ASSETS[@]}" -R "$REPO" --title "$TITLE" \
		--notes-file "$NOTES" "${CREATE_ARGS[@]}"
fi
if [ "$(release_api --jq .draft)" = true ]; then
	EDIT_ARGS=(--draft=false)
	if [ "$CHANNEL" = rc ]; then
		EDIT_ARGS+=(--prerelease --latest=false)
	else
		EDIT_ARGS+=(--prerelease=false --latest)
	fi
	gh release edit "$TAG" -R "$REPO" "${EDIT_ARGS[@]}"
fi
[ "$(release_api --jq .draft)" = false ] || { echo "ERR: release $TAG is still a draft" >&2; exit 1; }
echo "  ✓ release published"
# The attestation bundle rides along for offline verification; a retry keeps the first one.
if [ -f "$PROVENANCE" ]; then
	if [ -z "$(release_api --jq ".assets[] | select(.name==\"$(basename "$PROVENANCE")\") | .id")" ]; then
		gh release upload "$TAG" "$PROVENANCE" -R "$REPO"
	fi
	echo "  ✓ provenance attached"
fi

# Commit the appcast after pinning the release tag. Hosted releases use GitHub's
# signing key; local releases retain the maintainer's configured Git signing.
echo "▶ Updating the committed appcast (main:/$APPCAST is what Pages serves)..."
cp "$FEED" "$WORK/original-appcast.xml"
FEED_ARGS=(--changelog "$HERE/CHANGELOG.md")
if [ "$CHANNEL" = rc ]; then
	FEED_ARGS+=(--channel rc --title "$SHORT (RC $RC_NUMBER)")
fi
"$HERE/scripts/update-appcast.py" "$FEED" \
	--short-version "$SHORT" --version "$BUILD" \
	--url "$ASSET_URL" --ed-signature "$ED_SIG" --length "$LENGTH" --min-system 26.0 \
	"${FEED_ARGS[@]}"
if cmp -s "$FEED" "$WORK/original-appcast.xml"; then
	echo "  ✓ appcast already current (no change to publish)"
elif [ "${GITHUB_ACTIONS:-}" = true ]; then
	APPCAST_SHA="$(python3 "$HERE/scripts/github_signed_commit.py" "$REPO" "$MAIN_SHA" \
		"$APPCAST" "$FEED" "appcast: $TITLE")"
	echo "  ✓ verified appcast commit published → $APPCAST_SHA"
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

echo "✅ Published $TITLE - Sparkle offers it to the ${CHANNEL:-stable} channel."
