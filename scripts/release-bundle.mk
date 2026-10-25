# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

# Each executable receives only its own profile and entitlements.
sign: app embed-helper sign-bundle

# Hosted signing has no compilation prerequisites.
sign-bundle: ensure-signing
	@test -n "$(strip $(DEVELOPER_ID))" || { \
		echo "ERR: restricted capabilities require Developer ID signing" >&2; exit 1; }
	@echo "Signing bundle inside-out with: $(DEVELOPER_ID)"
	scripts/sign-bundle.sh "$(GLIMMER_APP_SRC)" "$(DEVELOPER_ID)" "$(SIGN_KEYCHAIN)" \
		$(if $(filter Release,$(CONFIG)),Glimmer/Glimmer.entitlements,Glimmer/Glimmer-Debug.entitlements)

# Notarize the signed bundle: zip, submit and wait, then staple. Re-runs
# ensure-signing first: the Release build before it is long enough for a sleep
# to re-lock the keychain holding the notary profile.
notarize: app embed-helper notarize-bundle
	@python3 scripts/release_validation.py --config "$(RELEASE_VERSION_CONFIG)" \
		--appcast "$(APPCAST_FEED)" --app "$(GLIMMER_APP_SRC)" --validate-distribution

# Launch probes run on a separate credential-free runner in hosted releases.
notarize-bundle: sign-bundle appcast-feed
	@test -n "$(strip $(DEVELOPER_ID))" || { echo "ERR: no Developer ID cert - can't notarize" >&2; exit 1; }
	@$(MAKE) --no-print-directory ensure-signing
	@echo "Notarizing $(GLIMMER_APP_SRC)..."
	@rm -f "$(DERIVED)/Glimmer-notarize.zip"
	ditto -c -k --sequesterRsrc --keepParent "$(GLIMMER_APP_SRC)" "$(DERIVED)/Glimmer-notarize.zip"
	xcrun notarytool submit "$(DERIVED)/Glimmer-notarize.zip" \
		--keychain-profile "$(NOTARY_PROFILE)" --keychain "$(SIGN_KEYCHAIN)" --wait
	xcrun stapler staple "$(GLIMMER_APP_SRC)"
	@rm -f "$(DERIVED)/Glimmer-notarize.zip"
	@echo "notarized + stapled"
	@spctl --assess --type execute --verbose=2 "$(GLIMMER_APP_SRC)"
	@python3 scripts/release_validation.py --config "$(RELEASE_VERSION_CONFIG)" \
		--appcast "$(APPCAST_FEED)" --app "$(GLIMMER_APP_SRC)"

# Finder scripting supplies the background, icon positions and baked .DS_Store.
# Headless packaging falls back to a plain installable image, never a failed release.
# Keep these output paths shared with distribution, publication and Homebrew.
dmg:
	@test -d "$(GLIMMER_APP_SRC)" || { echo "ERR: build first (make release)" >&2; exit 1; }
	@echo "Building $(DMG_NAME)..."
	@rm -rf "$(DIST_DIR)" && mkdir -p "$(DIST_DIR)"
	@scripts/make-dmg.sh "$(GLIMMER_APP_SRC)" "$(DIST_DIR)/$(DMG_NAME)" "Glimmer $(MARKETING_VERSION)"
	@echo "$(DIST_DIR)/$(DMG_NAME)"
	@shasum -a 256 "$(DIST_DIR)/$(DMG_NAME)"

# Hosted signing finishes the outer container before credentials are removed.
.PHONY: notarize-dmg
notarize-dmg: ensure-signing
	@test -n "$(strip $(DEVELOPER_ID))" && test "$(DEVELOPER_ID)" != "-" || { \
		echo "ERR: DMG requires Developer ID signing" >&2; exit 1; }
	@test -s "$(DIST_DIR)/$(DMG_NAME)" || { echo "ERR: DMG missing" >&2; exit 1; }
	codesign --force --timestamp --sign "$(DEVELOPER_ID)" --keychain "$(SIGN_KEYCHAIN)" \
		--identifier io.ugfugl.Glimmer.dmg "$(DIST_DIR)/$(DMG_NAME)"
	xcrun notarytool submit "$(DIST_DIR)/$(DMG_NAME)" \
		--keychain-profile "$(NOTARY_PROFILE)" --keychain "$(SIGN_KEYCHAIN)" --wait --output-format json \
		> "$(DERIVED)/Glimmer-dmg-notary.json"
	@python3 -c 'import json, sys; result = json.load(open(sys.argv[1])); sys.exit(0 if result.get("status") == "Accepted" else "ERR: DMG notarization not accepted")' \
		"$(DERIVED)/Glimmer-dmg-notary.json"
	xcrun stapler staple "$(DIST_DIR)/$(DMG_NAME)"

# Package the final stapled app before attestation or publication.
sparkle-zip:
	@test -d "$(GLIMMER_APP_SRC)" || { echo "ERR: build first (make release)" >&2; exit 1; }
	@mkdir -p "$(DIST_DIR)"
	@rm -f "$(DIST_DIR)/Glimmer-$(MARKETING_VERSION).zip"
	@ditto -c -k --sequesterRsrc --keepParent "$(GLIMMER_APP_SRC)" "$(DIST_DIR)/Glimmer-$(MARKETING_VERSION).zip"
