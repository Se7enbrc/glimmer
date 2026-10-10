# Glimmer - Mac-native game-streaming client.
#
# EVERYTHING BUT PUBLISH (the dev tier - notarized Release, installed, NOT
# published). Every build here is byte-for-byte what ships - same Developer-ID
# signing, notarization, and STRICT library validation - so there's no
# adhoc/Debug divergence to chase:
#   make                   Build (Release: Dev-ID + notarized) + install to
#                          /Applications. Requires Developer ID profiles.
#   make dev               Run tests, then build + install + relaunch. Inner loop.
#   make reinstall         Build + install + quit-and-relaunch (no tests).
#   make install           Build + install, no relaunch (same as bare `make`).
#   make open              Build + install + open.
#   make release           Build the notarized Release app only (no install).
#   make app               Quick compile-only check (no signing / notarize).
#   make test              Build + run the GlimmerTests unit-test bundle.
#   make uninstall         Remove Glimmer.app.
#   make clean             Remove build outputs.
#
# RELEASE (one published, auto-updatable build - everything flows here):
#   make release-publish   THE release. dist → ZIP + EdDSA-sign → GitHub release +
#                          appcast; existing installs auto-update (Sparkle).
#   make dist              Build-only checkpoint: Release → Developer ID sign →
#                          notarize → staple → DMG (no publish). This is
#                          release-publish's first step; run it alone only to
#                          inspect a DMG before publishing.
#   make rc                Cut the next candidate for pushed HEAD: wait for checks,
#                          move release-candidate, sign + push the rc tag, dispatch
#                          Release. DRY_RUN=1 prints the steps without changing anything.
#
# ONE-TIME SETUP (signing / notarization / update keys):
#   make creds-init        Write the signing credentials file template.
#   make codesign-setup    Build the signing keychain + import the Developer ID.
#   make setup-notary      Store the notarytool profile.
#   make sparkle-keys      Generate the Sparkle EdDSA update-signing keypair.
#
# PROFILING / TELEMETRY:
#   make profile           Instruments → Time Profiler (CPU).
#   make profile-signposts Instruments → Logging (OSSignposts).
#   make enable-telem      Turn the app's opt-in telemetry exporter on.
#   make disable-telem     Turn the app's opt-in telemetry exporter off.

# Install and packaging stages share outputs; Xcode parallelizes compilation.
.NOTPARALLEL:

GLIMMER_APP_DST ?= /Applications/Glimmer.app
CONFIG          ?= Debug
SWIFTC          ?= xcrun swiftc
TEST_SUITE      ?=
DERIVED         := $(CURDIR)/build
GLIMMER_APP_SRC := $(DERIVED)/Build/Products/$(CONFIG)/Glimmer.app
# macOS keeps every built or test-hosted app registered after its folder is gone.
LSREGISTER      := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
UNREGISTER_BUILDS = find "$(DERIVED)/Build/Products" -name "*.app" -exec $(LSREGISTER) -u {} \; 2>/dev/null || true
STREAM_XCCONFIG := Glimmer/StreamLib.xcconfig
INSTRUMENTS_DIR := $(HOME)/Library/Developer/Xcode/Instruments

# --- Code signing / notarization -------------------------------------------
# DEVELOPER_ID is auto-detected across the keychain search list (including the
# dedicated signing keychain codesign-setup builds) so the Makefile carries no
# per-machine name. Unsigned compile checks and tests need no identity.
DEVELOPER_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | \
                 sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
# notarytool keychain profile name (created by `make setup-notary`).
NOTARY_PROFILE  ?= notary
# Fixed profile locations, overridable for a fork or another signing machine.
PROVISIONING_PROFILE ?= $(HOME)/.config/glimmer/profiles/Glimmer_Developer_ID.provisionprofile
HELPER_PROVISIONING_PROFILE ?= $(HOME)/.config/glimmer/profiles/Glimmer_Network_Helper_Developer_ID.provisionprofile
export GLIMMER_PROVISIONING_PROFILE := $(PROVISIONING_PROFILE)
export GLIMMER_HELPER_PROVISIONING_PROFILE := $(HELPER_PROVISIONING_PROFILE)
# Signing secrets: one KEY=value file, mode 0600, outside the repo, read and
# written only by scripts/signing-creds.sh. Like the keychain below, it belongs
# to your Developer ID rather than to Glimmer, so other projects can share both.
SIGNING_CREDS   ?= $(HOME)/.config/developer-id/signing.env
export GLIMMER_SIGNING_CREDS := $(SIGNING_CREDS)
CREDS           := scripts/signing-creds.sh
# Dedicated keychain for the Developer ID identity and notary profile. Importing
# with `-T /usr/bin/codesign` is the only way codesign runs without prompting,
# which the login keychain can't promise. Created by `make codesign-setup`.
SIGN_KEYCHAIN   ?= $(HOME)/Library/Keychains/developer-id.keychain-db
# Version single source of truth: Glimmer/Version.xcconfig (NOT pbxproj).
MARKETING_VERSION := $(shell sed -n 's/^MARKETING_VERSION = \(.*\)/\1/p' Glimmer/Version.xcconfig | tr -d ' ')
DMG_NAME        := Glimmer-$(MARKETING_VERSION).dmg
DIST_DIR        := $(DERIVED)/dist
# Build number (CFBundleVersion) - the monotonic stamp Sparkle keys updates on.
BUILD_NUMBER    := $(shell sed -n 's/^CURRENT_PROJECT_VERSION = \(.*\)/\1/p' Glimmer/Version.xcconfig | tr -d ' ')
# Repo that hosts the Sparkle appcast (GitHub Pages) + release assets - the
# public source repo itself.
RELEASES_REPO   ?= Se7enbrc/glimmer
# Homebrew tap that carries the cask (`brew install --cask se7enbrc/glimmer/glimmer`).
TAP_REPO        ?= Se7enbrc/homebrew-glimmer
export RELEASES_REPO TAP_REPO
# Which release `make brew-bump` points the cask at - the one being built by default.
VERSION         ?= $(MARKETING_VERSION)
SPARKLE_VERSION ?= 2.10.0
export SPARKLE_VERSION

# --- Privileged AWDL network helper (root LaunchDaemon) ---------------------
# A tiny daemon that parks awdl0 (the AirDrop/Continuity radio) while streaming,
# to kill the multi-second Wi-Fi delivery gaps AWDL contention causes. Built
# with swiftc using system frameworks and the app's shared process runner.
# The daemon has its own app-like bundle and provisioning profile, signed
# before the app's outer seal. SMAppService reads its LaunchDaemons plist.
HELPER_LABEL  := io.ugfugl.glimmer.helper
HELPER_SRCS   := helper/Protocol.swift Glimmer/AWDLProcess.swift helper/AWDLSuppressor.swift helper/HelperService.swift helper/main.swift
HELPER_PLIST  := helper/$(HELPER_LABEL).plist
HELPER_BIN    := $(DERIVED)/$(HELPER_LABEL)
HELPER_SDK    := $(shell xcrun --sdk macosx --show-sdk-path)
HELPER_TARGET := arm64-apple-macos26.0
HELPER_BUNDLE := $(GLIMMER_APP_SRC)/Contents/Library/LaunchServices/Glimmer Network Helper.app

.PHONY: all release install reinstall uninstall clean app sign open \
        helper-build embed-helper \
        profile profile-signposts setup-notary notarize dmg dmg-background sparkle-zip dist preflight \
        codesign-setup codesign-teardown ensure-signing dev test test-asan \
        creds-init enable-telem disable-telem release-publish sparkle-keys \
        guard-clean-tree guard-release-version check verify test-scripts brew-bump rc

# TIER 1 - "everything but publish": the full release pipeline at Release
# (xcodebuild -> inside-out sign -> notarize -> staple),
# stopping just short of cutting/uploading a DMG, then INSTALLED to /Applications.
# EVERY build goes through this, so what you run is byte-for-byte what ships:
# daemon registration, TCC, and STRICT library validation all behave identically
# - none of the adhoc/Debug divergence that used to cause heisenbugs. `make` /
# `make all` installs it (warning if an older copy is still running); `make dev`
# / `make reinstall` additionally quit + relaunch. TIER 2 - "publish" - is
# `make dist`. Quick compile-only check: `make app`.
all: install

# Build the notarized Release app (everything but publish) WITHOUT installing.
# Restricted capabilities require Developer ID profiles, including local installs.
release:
	@test -n "$(strip $(DEVELOPER_ID))" || { echo "ERR: release requires Developer ID signing; use make verify for unsigned checks" >&2; exit 1; }
	@test -f "$(PROVISIONING_PROFILE)" -a -f "$(HELPER_PROVISIONING_PROFILE)" || { echo "ERR: set PROVISIONING_PROFILE and HELPER_PROVISIONING_PROFILE to the approved Developer ID profiles" >&2; exit 1; }
	$(MAKE) CONFIG=Release notarize

# Build and run unsigned tests; TEST_SUITE optionally selects one suite or test.
test:
	@scripts/generate-build-info.sh
	xcodebuild test -project Glimmer.xcodeproj -scheme Glimmer -configuration Debug \
	  -xcconfig $(STREAM_XCCONFIG) \
	  CODE_SIGNING_ALLOWED=NO -derivedDataPath $(DERIVED) -destination 'platform=macOS' \
	  $(if $(strip $(TEST_SUITE)),-only-testing:GlimmerTests/$(TEST_SUITE)); \
	  status=$$?; $(UNREGISTER_BUILDS); exit $$status

# Exercise untrusted protocol input with memory error detection enabled.
test-asan:
	@scripts/generate-build-info.sh
	xcodebuild test -project Glimmer.xcodeproj -scheme Glimmer -configuration Debug \
	  -xcconfig $(STREAM_XCCONFIG) \
	  CODE_SIGNING_ALLOWED=NO -derivedDataPath $(DERIVED) -destination 'platform=macOS' \
	  -enableAddressSanitizer YES -only-testing:GlimmerTests/FuzzTests \
	  -only-testing:GlimmerTests/StreamFuzzTests; \
	  status=$$?; $(UNREGISTER_BUILDS); exit $$status

# appintentsmetadataprocessor writes its JSON in Swift hash order, which is seeded per
# process; pin it so two builds of one commit stay byte-identical (docs/RELEASE.md).
app:
	@echo "▶ Building Glimmer.app ($(CONFIG))..."
	@scripts/generate-build-info.sh
	SWIFT_DETERMINISTIC_HASHING=1 xcodebuild -project Glimmer.xcodeproj -scheme Glimmer -configuration $(CONFIG) \
		-xcconfig $(STREAM_XCCONFIG) \
		CODE_SIGNING_ALLOWED=NO \
		-derivedDataPath $(DERIVED) -destination 'platform=macOS' build
	@$(UNREGISTER_BUILDS)
# CODE_SIGNING_ALLOWED=NO: signing is owned EXCLUSIVELY by the `sign` target
# (keychain-pinned, prompt-free). Xcode's Automatic signing during the build
# resolves identities from the login keychain and produces a password prompt
# per nested bundle - the `sign` target re-signs inside out right after,
# so xcodebuild's own signatures were pure prompt-noise.

# Before every signing: put the signing keychain first in the search list and
# unlock it from the creds file (sleep locks it), re-importing the .p12 if it was
# emptied. Never prompts; a no-op until `make codesign-setup` has run.
ensure-signing:
	@test -n "$(strip $(DEVELOPER_ID))" || exit 0; \
	test -f "$(SIGN_KEYCHAIN)" || exit 0; \
	others=$$(security list-keychains -d user | sed 's/[" ]//g' | grep -vF "$(SIGN_KEYCHAIN)" || true); \
	security list-keychains -d user -s "$(SIGN_KEYCHAIN)" $$others >/dev/null 2>&1 || true; \
	KCPW=$$($(CREDS) get SIGN_KEYCHAIN_PASSWORD --optional 2>/dev/null || true); \
	if [ -n "$$KCPW" ]; then \
		security unlock-keychain -p "$$KCPW" "$(SIGN_KEYCHAIN)" 2>/dev/null || true; \
		if ! security find-identity -p codesigning "$(SIGN_KEYCHAIN)" 2>/dev/null | grep -q "Developer ID"; then \
			P12="$$($(CREDS) get P12_PATH --optional 2>/dev/null || true)"; \
			P12PW="$$($(CREDS) get P12_PASSWORD --optional 2>/dev/null || true)"; \
			if [ -s "$$P12" ] && [ -n "$$P12PW" ]; then \
				security import "$$P12" -k "$(SIGN_KEYCHAIN)" -P "$$P12PW" \
					-T /usr/bin/codesign -T /usr/bin/security 2>/dev/null || true; \
				echo "  ↺ re-imported Developer ID - dedicated keychain had been emptied (auto-heal)"; \
			else \
				echo "  ⚠ Developer ID missing from $(notdir $(SIGN_KEYCHAIN)) and no P12 to auto-heal -" >&2; \
				echo "    codesign will fall back to a non-headless keychain (prompts/errSecInternalComponent)." >&2; \
				echo "    Fix: put P12_PATH+P12_PASSWORD in $$($(CREDS) path 2>/dev/null) (or fill-from-op) and 'make codesign-setup'." >&2; \
			fi; \
		fi; \
		security set-key-partition-list -S apple-tool:,apple:,codesign: \
			-s -k "$$KCPW" "$(SIGN_KEYCHAIN)" >/dev/null 2>&1 || true; \
		echo "  ✓ signing keychain unlocked + authorized + prioritized"; \
	fi

# Inside-out signing (scripts/sign-bundle.sh) - NOT `codesign --deep`. --deep
# clobbers Sparkle's framework/XPC entitlements with Glimmer's (it stamped
# device.usb / moonlight exceptions onto the Sparkle downloader, which breaks the
# sandboxed installer XPC), and Apple deprecated it for distribution. The helper
# signs each nested component preserving its own entitlements, the app last.
# Build the AWDL helper daemon with swiftc (system frameworks only, so it doesn't
# need the StreamLib xcconfig). Output lives under build/.
$(HELPER_BIN): $(HELPER_SRCS)
	@echo "▶ Building AWDL helper (swiftc, $(HELPER_TARGET))..."
	@mkdir -p $(DERIVED)
	$(SWIFTC) -warnings-as-errors -O -target $(HELPER_TARGET) -sdk "$(HELPER_SDK)" -o "$(HELPER_BIN)" $(HELPER_SRCS)

helper-build: $(HELPER_BIN)

# Embed the daemon binary + its launchd plist into the freshly-built app bundle.
# Runs after `app` (which created the bundle) and before `sign` (which signs the
# daemon inside-out). install(1) overwrites cleanly on every rebuild.
embed-helper: app $(HELPER_BIN)
	@echo "▶ Embedding AWDL helper into the app bundle..."
	@mkdir -p "$(HELPER_BUNDLE)/Contents/MacOS"
	@install -m 0755 "$(HELPER_BIN)" "$(HELPER_BUNDLE)/Contents/MacOS/$(HELPER_LABEL)"
	@install -m 0644 helper/Info.plist "$(HELPER_BUNDLE)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(MARKETING_VERSION)" "$(HELPER_BUNDLE)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" "$(HELPER_BUNDLE)/Contents/Info.plist"
	@rm -f "$(GLIMMER_APP_SRC)/Contents/MacOS/$(HELPER_LABEL)"
	@mkdir -p "$(GLIMMER_APP_SRC)/Contents/Library/LaunchDaemons"
	@install -m 0644 "$(HELPER_PLIST)" "$(GLIMMER_APP_SRC)/Contents/Library/LaunchDaemons/$(HELPER_LABEL).plist"
	@echo "  ✓ helper bundle and launchd service embedded"

# Each executable receives only its own profile and entitlements.
sign: app embed-helper ensure-signing
	@test -n "$(strip $(DEVELOPER_ID))" || { echo "ERR: restricted capabilities require Developer ID signing" >&2; exit 1; }
	@echo "▶ Signing bundle inside-out with: $(DEVELOPER_ID)"
	scripts/sign-bundle.sh "$(GLIMMER_APP_SRC)" "$(DEVELOPER_ID)" "$(SIGN_KEYCHAIN)" $(if $(filter Release,$(CONFIG)),Glimmer/Glimmer.entitlements,Glimmer/Glimmer-Debug.entitlements)

# Install the everything-but-publish build (see `release`) to /Applications.
# `reinstall`/`open`/`dev` build on this.
install: release
	@python3 scripts/release_validation.py --config Glimmer/Version.xcconfig --appcast appcast.xml --app "$(DERIVED)/Build/Products/Release/Glimmer.app" --validate-distribution
	@SRC="$(DERIVED)/Build/Products/Release/Glimmer.app"; \
	echo "▶ Installing Glimmer.app to $(GLIMMER_APP_DST)..."; \
	if [ -d "$(GLIMMER_APP_DST)" ]; then echo "  removing existing $(GLIMMER_APP_DST)"; rm -rf "$(GLIMMER_APP_DST)"; fi; \
	cp -R "$$SRC" "$(GLIMMER_APP_DST)"; \
	COMMIT=$$(sed -nE 's/.*static let commit = "([^"]+)".*/\1/p' Glimmer/BuildInfo.generated.swift); \
	echo "  ✓ installed build $$COMMIT"; \
	if pgrep -x Glimmer >/dev/null 2>&1; then \
		echo "  ⚠ Glimmer is RUNNING an older build - it will NOT load $$COMMIT until you"; \
		echo "    fully QUIT (⌘Q) and relaunch. Run 'make reinstall' to do it automatically."; \
	fi

open: install
	open "$(GLIMMER_APP_DST)"

# Build + install + (quit any running instance and) relaunch - guarantees the
# NEW build is the one actually loaded. A running app keeps its old binary in
# memory: installing over the bundle on disk does nothing for the live process,
# and starting a new stream reuses the same instance, so a dev can unknowingly
# test stale code for an hour. Use this when iterating on a dev build. (Builds
# FIRST via the `install` prereq, so a failed build never quits a good session.)
reinstall: install quit-running
	@echo "▶ Relaunching..."; open "$(GLIMMER_APP_DST)"
	@COMMIT=$$(sed -nE 's/.*static let commit = "([^"]+)".*/\1/p' Glimmer/BuildInfo.generated.swift); \
	echo "  ✓ now running build $$COMMIT"

# Quit any running instance so the bundle on disk is the one that loads next.
quit-running:
	@if pgrep -x Glimmer >/dev/null 2>&1; then \
		echo "▶ Quitting the running Glimmer so the new build can load..."; \
		osascript -e 'tell application "Glimmer" to quit' >/dev/null 2>&1 || true; \
		for i in 1 2 3 4 5 6 7 8; do pgrep -x Glimmer >/dev/null 2>&1 || break; sleep 1; done; \
		pkill -x Glimmer >/dev/null 2>&1 || true; \
	fi

# Address-sanitized DEBUG build through the normal pipeline (helper, keychain
# signing, dylibs), installed and relaunched like `reinstall`, never notarized.
# ASan reports land in ~/Library/Logs/Glimmer/asan.log.<pid>; `make reinstall`
# puts the normal build back.
ASAN_XCCONFIG := $(DERIVED)/asan.xcconfig
asan-reinstall:
	@mkdir -p "$(DERIVED)"
	@printf '#include "%s"\nENABLE_ADDRESS_SANITIZER = YES\nOTHER_SWIFT_FLAGS = $$(inherited) -sanitize=address\nOTHER_CFLAGS = $$(inherited) -fsanitize=address\nOTHER_LDFLAGS = $$(inherited) -fsanitize=address\n' "$(CURDIR)/$(STREAM_XCCONFIG)" > "$(ASAN_XCCONFIG)"
	$(MAKE) CONFIG=Debug STREAM_XCCONFIG="$(ASAN_XCCONFIG)" app
	@rm -rf "$(DERIVED)/Build/Products/Debug/Glimmer.app/Contents/PlugIns"/*.xctest
	$(MAKE) CONFIG=Debug STREAM_XCCONFIG="$(ASAN_XCCONFIG)" sign
	$(MAKE) quit-running
	@echo "▶ Installing the ASan Debug build to $(GLIMMER_APP_DST)..."
	@rm -rf "$(GLIMMER_APP_DST)"; cp -R "$(DERIVED)/Build/Products/Debug/Glimmer.app" "$(GLIMMER_APP_DST)"
	@mkdir -p "$$HOME/Library/Logs/Glimmer"
	@echo "▶ Relaunching with ASAN_OPTIONS..."; \
	open --env "ASAN_OPTIONS=log_path=$$HOME/Library/Logs/Glimmer/asan.log:halt_on_error=0" "$(GLIMMER_APP_DST)"
	@echo "  ✓ ASan build running (reports: ~/Library/Logs/Glimmer/asan.log.*)"

# `make dev` is the inner loop: run the unit tests, THEN build + install +
# relaunch the notarized Release build. Tests run first so a failure skips the
# slow notarize. (Pipeline: `all` build/sign/notarize + `install` stage +
# `reinstall` quit/relaunch.)
dev: test reinstall

uninstall:
	@echo "▶ Uninstalling Glimmer..."
	@rm -rf "$(GLIMMER_APP_DST)"
	@echo "  ✓ removed"

clean:
	@$(UNREGISTER_BUILDS)
	rm -rf $(DERIVED)
	@echo "  ✓ cleaned"

# --- Code-signing keychain (CI-grade, non-interactive) ---------------------

# One-time setup: build a DEDICATED signing keychain containing the Developer ID
# identity, imported from the .p12 with `-T /usr/bin/codesign` so codesign gets
# non-interactive access (no "codesign wants to use key" prompt). This is the
# standard CI/CD pattern and is the ONLY reliable fix - the GUI "Allow all" and
# a bare `set-key-partition-list` don't stick on a key that was imported into
# the login keychain without codesign in its ACL.
#
# Non-destructive: creates a separate keychain, never touches the login
# keychain or any existing identity. The .p12 path + passphrase come from the
# credentials file (P12_PATH / P12_PASSWORD - see `make creds-init`). The
# keychain password is read from the credentials file too, or generated in-
# process on first run and stored back there (NEVER the login keychain, which
# is locked in non-GUI sessions), so `make ensure-signing` can re-unlock the
# keychain after a sleep/lock from any session. The keychain is left UNLOCKED
# so codesign can use it immediately; `make codesign-teardown` removes it.
#
# After this, `make sign` / `make dist` find the identity via DEVELOPER_ID
# (auto-detected across all keychains in the search list, including this one).
codesign-setup:
	@echo "▶ Building dedicated signing keychain $(SIGN_KEYCHAIN)..."
	@set -eu; \
	$(CREDS) check >/dev/null; \
	P12="$$($(CREDS) get P12_PATH)"; \
	test -s "$$P12" || { echo "ERR: P12_PATH '$$P12' missing or empty - export the Developer ID cert+key as .p12 first (docs/RELEASE.md)" >&2; exit 1; }; \
	P12PW="$$($(CREDS) get P12_PASSWORD)"; \
	KCPASS="$$($(CREDS) get SIGN_KEYCHAIN_PASSWORD --optional)"; \
	if [ -z "$$KCPASS" ]; then \
		KCPASS="$$(/usr/bin/openssl rand -base64 24)"; \
		$(CREDS) set SIGN_KEYCHAIN_PASSWORD "$$KCPASS"; \
		echo "  ✓ generated keychain password → $$($(CREDS) path)"; \
	fi; \
	if [ ! -f "$(SIGN_KEYCHAIN)" ]; then \
		security create-keychain -p "$$KCPASS" "$(SIGN_KEYCHAIN)"; \
		echo "  ✓ created keychain"; \
	else \
		echo "  • keychain exists - updating in place (preserves the notary profile)"; \
	fi; \
	security set-keychain-settings "$(SIGN_KEYCHAIN)"; \
	security unlock-keychain -p "$$KCPASS" "$(SIGN_KEYCHAIN)"; \
	if ! security find-identity -p codesigning "$(SIGN_KEYCHAIN)" 2>/dev/null | grep -q "Developer ID"; then \
		security import "$$P12" -k "$(SIGN_KEYCHAIN)" -P "$$P12PW" \
			-T /usr/bin/codesign -T /usr/bin/security; \
		echo "  ✓ imported Developer ID"; \
	else \
		echo "  • Developer ID already present - left as is"; \
	fi; \
	security set-key-partition-list -S apple-tool:,apple:,codesign: \
		-s -k "$$KCPASS" "$(SIGN_KEYCHAIN)" >/dev/null; \
	security list-keychains -d user -s "$(SIGN_KEYCHAIN)" \
		$$(security list-keychains -d user | sed 's/[" ]//g'); \
	echo "  ✓ signing keychain ready (codesign authorized, non-interactive)"
	@security find-identity -v -p codesigning "$(SIGN_KEYCHAIN)" | grep "Developer ID" || true

# Remove the dedicated signing keychain (drops it from the search list too).
codesign-teardown:
	@echo "▶ Removing $(SIGN_KEYCHAIN)..."
	@security list-keychains -d user -s \
		$$(security list-keychains -d user | sed 's/[" ]//g' | grep -vF "$(SIGN_KEYCHAIN)") 2>/dev/null || true
	@security delete-keychain "$(SIGN_KEYCHAIN)" 2>/dev/null || true
	@echo "  ✓ removed"

# --- Notarization / distribution -------------------------------------------

# Store the App Store Connect API key as the notary profile, in the signing
# keychain so any session can read it. Unlike an app-specific password, the key
# survives Apple ID password changes. Re-run after replacing it; validates online.
setup-notary:
	@echo "▶ Storing notary profile '$(NOTARY_PROFILE)' in the signing keychain..."
	@set -eu; \
	test -f "$(SIGN_KEYCHAIN)" || { echo "ERR: no signing keychain - run 'make codesign-setup' first (the profile lives there)" >&2; exit 1; }; \
	$(CREDS) missing NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER_ID SIGN_KEYCHAIN_PASSWORD \
		|| { echo "  fill those in ($$($(CREDS) path)), then re-run - 'make dist' runs this automatically" >&2; exit 1; }; \
	KEY="$$($(CREDS) get NOTARY_KEY_PATH)"; \
	test -s "$$KEY" || { echo "ERR: NOTARY_KEY_PATH '$$KEY' missing or empty" >&2; exit 1; }; \
	KEY_ID="$$($(CREDS) get NOTARY_KEY_ID)"; \
	ISSUER="$$($(CREDS) get NOTARY_ISSUER_ID)"; \
	security unlock-keychain -p "$$($(CREDS) get SIGN_KEYCHAIN_PASSWORD)" "$(SIGN_KEYCHAIN)"; \
	xcrun notarytool store-credentials "$(NOTARY_PROFILE)" \
		--key "$$KEY" --key-id "$$KEY_ID" --issuer "$$ISSUER" \
		--keychain "$(SIGN_KEYCHAIN)"; \
	echo "  ✓ notary profile stored (dedicated keychain - readable from any session)"

# Notarize the signed bundle: zip, submit and wait, then staple. Re-runs
# ensure-signing first: the Release build before it is long enough for a sleep
# to re-lock the keychain holding the notary profile.
notarize: sign
	@test -n "$(strip $(DEVELOPER_ID))" || { echo "ERR: no Developer ID cert - can't notarize" >&2; exit 1; }
	@$(MAKE) --no-print-directory ensure-signing
	@echo "▶ Notarizing $(GLIMMER_APP_SRC)..."
	@rm -f "$(DERIVED)/Glimmer-notarize.zip"
	ditto -c -k --sequesterRsrc --keepParent "$(GLIMMER_APP_SRC)" "$(DERIVED)/Glimmer-notarize.zip"
	xcrun notarytool submit "$(DERIVED)/Glimmer-notarize.zip" \
		--keychain-profile "$(NOTARY_PROFILE)" --keychain "$(SIGN_KEYCHAIN)" --wait
	xcrun stapler staple "$(GLIMMER_APP_SRC)"
	@rm -f "$(DERIVED)/Glimmer-notarize.zip"
	@echo "  ✓ notarized + stapled"
	@spctl --assess --type execute --verbose=2 "$(GLIMMER_APP_SRC)"
	@python3 scripts/release_validation.py --config Glimmer/Version.xcconfig --appcast appcast.xml --app "$(GLIMMER_APP_SRC)" --validate-distribution

# Build a distributable DMG from the signed (and ideally notarized) bundle.
# scripts/make-dmg.sh does the hdiutil + Finder-AppleScript dance (background
# art, window bounds, icon positions, baked .DS_Store) with no Homebrew
# dependency; it degrades to a plain-but-installable DMG if Finder scripting is
# unavailable, so a release never fails over cosmetics. Same output path/name as
# before, so `dist`, `release-publish`, and the Homebrew bump are unaffected.
dmg:
	@test -d "$(GLIMMER_APP_SRC)" || { echo "ERR: build first (make release)" >&2; exit 1; }
	@echo "▶ Building $(DMG_NAME)..."
	@rm -rf "$(DIST_DIR)" && mkdir -p "$(DIST_DIR)"
	@scripts/make-dmg.sh "$(GLIMMER_APP_SRC)" "$(DIST_DIR)/$(DMG_NAME)" "Glimmer $(MARKETING_VERSION)"
	@echo "  ✓ $(DIST_DIR)/$(DMG_NAME)"
	@shasum -a 256 "$(DIST_DIR)/$(DMG_NAME)"

# Package the final stapled app before attestation or publication.
sparkle-zip:
	@test -d "$(GLIMMER_APP_SRC)" || { echo "ERR: build first (make release)" >&2; exit 1; }
	@mkdir -p "$(DIST_DIR)"
	@rm -f "$(DIST_DIR)/Glimmer-$(MARKETING_VERSION).zip"
	@ditto -c -k --sequesterRsrc --keepParent "$(GLIMMER_APP_SRC)" "$(DIST_DIR)/Glimmer-$(MARKETING_VERSION).zip"

# Regenerate the DMG window background art (scripts/dmg/*.png). Committed, so
# this only needs re-running when the layout or palette changes - keep it in
# step with the geometry in scripts/make-dmg.sh.
dmg-background:
	@scripts/generate-dmg-background.swift

# Fail-fast gate for `make dist`: a missing cert, creds file or notary profile
# surfaces in seconds, not after the Release build. Every probe is a metadata
# lookup that works on a locked keychain, so it never prompts.
preflight:
	@set -eu; \
	echo "▶ Preflight (release signing)..."; \
	test -n "$(strip $(DEVELOPER_ID))" || { echo "ERR: no 'Developer ID Application' identity - run 'make codesign-setup' (docs/RELEASE.md)" >&2; exit 1; }; \
	echo "  ✓ identity: $(DEVELOPER_ID)"; \
	PEM="$$(security find-certificate -c "$(DEVELOPER_ID)" -p "$(SIGN_KEYCHAIN)" 2>/dev/null || true)"; \
	if [ -n "$$PEM" ]; then \
		echo "  ✓ valid until $$(printf '%s\n' "$$PEM" | /usr/bin/openssl x509 -noout -enddate | cut -d= -f2)"; \
		printf '%s\n' "$$PEM" | /usr/bin/openssl x509 -noout -checkend 5184000 >/dev/null \
			|| echo "  ⚠ the Developer ID certificate expires within 60 days - renew it (docs/RELEASE.md)" >&2; \
	fi; \
	if ! $(CREDS) check >/dev/null 2>&1; then \
		$(CREDS) init >/dev/null; \
		echo "ERR: first run - signing credentials needed." >&2; \
		echo "  A template was just written to: $$($(CREDS) path)" >&2; \
		echo "  Fill it in (docs/RELEASE.md), then re-run 'make dist'." >&2; \
		exit 1; \
	fi; \
	echo "  ✓ creds file: $$($(CREDS) path)"; \
	if ! security find-generic-password \
		-a "com.apple.gke.notary.tool.saved-creds.$(NOTARY_PROFILE)" "$(SIGN_KEYCHAIN)" >/dev/null 2>&1; then \
		echo "  ▶ no notary profile yet - storing it now (automatic setup-notary)..."; \
		$(CREDS) missing NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER_ID 2>/dev/null \
			|| $(CREDS) fill-from-op || true; \
		$(MAKE) --no-print-directory setup-notary; \
	fi; \
	echo "  ✓ notary profile present"

# One-time: write the signing credentials file template (mode 0600, outside the
# repo) and print where it landed. Fill in the values, then `make codesign-setup`
# and `make setup-notary`. See docs/RELEASE.md for the full one-time checklist.
creds-init:
	@$(CREDS) init

# Release-integrity gate: refuse to build a release from a dirty worktree. A
# dirty tree means the bundle can contain uncommitted changes the tag won't
# capture, so the GPLv3 source at the tag wouldn't reproduce the binary (the .48
# regression). Catches both unstaged AND staged changes. Reused by dist (and
# thus release-publish). Commit or stash first.
guard-clean-tree:
	@git diff --quiet HEAD || { echo "ERROR: refusing to build a release from a dirty worktree (commit or stash first)"; exit 1; }
	@git diff --cached --quiet || { echo "ERROR: refusing to build a release with staged changes (commit or stash first)"; exit 1; }
	@test -z "$$(git ls-files --others --exclude-standard)" || { echo "ERROR: refusing to build a release with untracked files (commit or remove them first)"; exit 1; }

guard-release-version:
	@python3 scripts/release_validation.py --config Glimmer/Version.xcconfig --appcast appcast.xml

# Full distribution pipeline: clean-tree gate → preflight (fail fast, see above)
# → clean Release → Developer ID sign → notarize + staple → DMG. The
# DMG's app is stapled, so it passes Gatekeeper offline on any Mac.
# Non-interactive from any session once the one-time setup is done (creds file +
# codesign-setup + setup-notary - docs/RELEASE.md).
dist: guard-clean-tree guard-release-version verify
	$(MAKE) CONFIG=Release preflight clean app notarize dmg

# Keep the shipping gate complete even when a local suite filter is supplied.
verify: check
	@$(MAKE) TEST_SUITE= test
	@$(MAKE) test-asan

check:
	@echo "▶ Check (workflows + lint --strict + release-tool tests)..."
	@actionlint
	@swiftlint lint --strict --quiet
	@$(MAKE) test-scripts

# Fixture repositories need git's own discovery; a hook's GIT_DIR would aim them at this one.
test-scripts:
	@env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
		python3 -m unittest discover -s scripts/tests -p 'test_*.py'

rc:
	@python3 scripts/release-candidate.py $(if $(DRY_RUN),--dry-run)

# --- Auto-update publication (Sparkle) -------------------------------------

# One-time: generate the EdDSA (ed25519) update-signing keypair. The PRIVATE key
# is stored in the signing creds file (SPARKLE_ED_PRIVATE_KEY) so publishing is
# prompt-free from any session; the PUBLIC key is printed for Info.plist's
# SUPublicEDKey. Idempotent - re-running just reprints the public key. BACK UP the
# private key: it is the ROOT OF UPDATE TRUST; losing it means no client can
# auto-update past the last signed build, and a leak lets anyone sign a malicious
# update Glimmer will install.
sparkle-keys:
	@set -eu; \
	TOOLS="$$(scripts/sparkle-tools.sh)"; \
	if $(CREDS) get SPARKLE_ED_PRIVATE_KEY --optional | grep -q .; then \
		echo "  • SPARKLE_ED_PRIVATE_KEY already in $$($(CREDS) path)"; \
	else \
		TMP="$$(mktemp)"; trap 'rm -f "$$TMP"' EXIT; \
		"$$TOOLS/generate_keys" >/dev/null 2>&1 || true; \
		"$$TOOLS/generate_keys" -x "$$TMP" >/dev/null 2>&1; \
		$(CREDS) set SPARKLE_ED_PRIVATE_KEY "$$(cat "$$TMP")"; \
		echo "  ✓ private key stored in $$($(CREDS) path) - BACK IT UP"; \
	fi; \
	echo "  SUPublicEDKey for Info.plist:"; \
	"$$TOOLS/generate_keys" -p

# Package before publication so update signing never changes the final assets.
# Commit the version first; the release tag is the GPL corresponding source.
release-publish: dist
	@$(MAKE) CONFIG=Release sparkle-zip
	@scripts/publish-release.sh \
		"$(MARKETING_VERSION)" "$(BUILD_NUMBER)" \
		"$(DERIVED)/Build/Products/Release/Glimmer.app" \
		"$(DIST_DIR)" "$(RELEASES_REPO)"
	@scripts/homebrew-bump.sh "$(MARKETING_VERSION)" || { \
		echo "" >&2; \
		echo "WARNING: Glimmer $(MARKETING_VERSION) IS published (release + appcast) -" >&2; \
		echo "  only the Homebrew cask bump failed. Recover with: make brew-bump" >&2; \
		exit 1; \
	}

# Point the Homebrew cask at the published release: download the DMG, checksum
# it, and push version + sha256 to the tap ($(TAP_REPO)). `release-publish` runs
# this last; run it by hand to recover from a failed bump, or to re-point the
# cask at an older tag with `make brew-bump VERSION=2026.8.13`.
# Idempotent - a cask already matching the published DMG makes no commit.
brew-bump:
	@scripts/homebrew-bump.sh "$(VERSION)"

# Profile under Instruments → Time Profiler. CPU hotspots only - for the
# OSSignpost-driven per-frame timeline, use `make profile-signposts`. Both
# targets depend on `install` so they pick up the freshly-signed bundle from
# /Applications/Glimmer.app. Traces land in ~/Library/Developer/Xcode/Instruments
# with a date-stamped name; double-click in Finder to open in Instruments.
#
# Use the Release configuration for steady-state numbers - Debug builds have
# overflow checks + `-Onone` so they're not representative:
#
#   make release && make profile
#
# Time limit is 60s for Time Profiler (long enough for a full stream startup
# + a minute of gameplay), 120s for the Logging template (signposts need more
# wall-clock to accumulate meaningful per-frame samples at 60Hz).
profile: install
	@echo "▶ Launching Glimmer under Instruments (Time Profiler)..."
	@mkdir -p "$(INSTRUMENTS_DIR)"
	xcrun xctrace record \
	    --template "Time Profiler" \
	    --launch "$(GLIMMER_APP_DST)" \
	    --output "$(INSTRUMENTS_DIR)/$(shell date +%Y%m%d-%H%M%S)-Glimmer.trace" \
	    --time-limit 60s

# Profile under Instruments → Logging template, which surfaces OSSignposts as
# intervals/events on the timeline. This is the right tool for Glimmer's hot
# paths because every interesting boundary (decode submit→complete, network
# handshake, pairing flow) is already wired with OSSignposter calls. After
# the trace opens in Instruments:
#
#   1. Drag the "os_signpost" track into view.
#   2. Filter by subsystem `io.ugfugl.Glimmer`.
#   3. Examine DecodeFrame interval p50/p99 (target: <8ms p99 at 4K60).
#
# See docs/PROFILING.md for the full playbook.
profile-signposts: install
	@echo "▶ Launching Glimmer under Instruments (Logging - OSSignposts)..."
	@mkdir -p "$(INSTRUMENTS_DIR)"
	xcrun xctrace record \
	    --template "Logging" \
	    --launch "$(GLIMMER_APP_DST)" \
	    --output "$(INSTRUMENTS_DIR)/$(shell date +%Y%m%d-%H%M%S)-Glimmer-signposts.trace" \
	    --time-limit 120s

# Toggle the app's opt-in telemetry exporter. The remote-sink setup
# (scripts/telem-client.sh) is a local, gitignored extension point - provide your
# own if you run a Prometheus/Loki rig; these targets no-op it when it's absent.
enable-telem:
	@[ -x scripts/telem-client.sh ] && scripts/telem-client.sh enable || echo "  • no scripts/telem-client.sh (optional local rig setup) - skipping"
	@defaults write io.ugfugl.Glimmer telemetryEnabled -bool YES
	@echo "  ✓ app telemetry exporter ON - relaunch Glimmer to pick it up"

disable-telem:
	@[ -x scripts/telem-client.sh ] && scripts/telem-client.sh disable || true
	@defaults write io.ugfugl.Glimmer telemetryEnabled -bool NO
	@echo "  ✓ app telemetry exporter OFF - relaunch Glimmer to pick it up"
