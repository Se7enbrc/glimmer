# Glimmer - Mac-native game-streaming client.
#
# Common targets:
#   make                   Build Glimmer.app (Debug).
#   make release           Build Release configuration.
#   make install           Copy Glimmer.app to /Applications (Dev ID if present, else adhoc).
#   make uninstall         Remove Glimmer.app.
#   make clean             Remove build outputs.
#   make profile           Launch under Instruments → Time Profiler (CPU).
#   make profile-signposts Launch under Instruments → Logging (OSSignposts).
#   make creds-init        One-time: write the signing credentials file template.
#   make codesign-setup    One-time: signing keychain + Developer ID import (creds file).
#   make setup-notary      One-time: store the notarytool profile (creds file).
#   make dist              Release → Developer ID sign → notarize → staple → DMG.
#   make sparkle-keys      One-time: generate the Sparkle EdDSA update-signing keypair.
#   make release-publish   dist → ZIP + EdDSA-sign → GitHub release + appcast (auto-update).
#   make enable-telem      Turn the app's opt-in telemetry exporter on.
#   make disable-telem     Turn the app's opt-in telemetry exporter off.

GLIMMER_APP_DST ?= /Applications/Glimmer.app
CONFIG          ?= Debug
DERIVED         := $(CURDIR)/build
GLIMMER_APP_SRC := $(DERIVED)/Build/Products/$(CONFIG)/Glimmer.app
OPENSSL_PREFIX  := $(shell brew --prefix openssl@3)
OPUS_PREFIX     := $(shell brew --prefix opus)
STREAM_XCCONFIG := Glimmer/StreamLib.xcconfig
INSTRUMENTS_DIR := $(HOME)/Library/Developer/Xcode/Instruments

# --- Code signing / notarization -------------------------------------------
# DEVELOPER_ID is auto-detected across the keychain search list (including the
# dedicated signing keychain codesign-setup builds) so the Makefile carries no
# per-machine name. Empty on machines without a Developer ID cert → builds
# fall back to adhoc (local dev keeps working). Override on the CLI if needed.
DEVELOPER_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | \
                 sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
# Team ID = the 10-char code in the identity's trailing parens, e.g. 5T7M4RH3F8.
TEAM_ID      := $(shell printf '%s' '$(DEVELOPER_ID)' | sed -n 's/.*(\([A-Z0-9]\{10\}\))$$/\1/p')
# notarytool keychain profile name (created by `make setup-notary`).
NOTARY_PROFILE  ?= glimmer-notary
# Signing credentials file - the ONE secret store the release pipeline reads.
# Plain KEY=value, mode 0600, OUTSIDE the repo (gitleaks never even sees it);
# scripts/signing-creds.sh is the sole reader/writer and refuses loose
# permissions. This replaces the old 1Password-at-build-time flow: `op read`
# needs an interactive signin and the login keychain is locked in SSH/cron/CI
# sessions, so neither can back a non-interactive `make dist`. The owner fills
# the file ONCE (`make creds-init`, see docs/RELEASE.md); everything after that
# is automatic. Override the path per-invocation with
# `make dist SIGNING_CREDS=/path/to/creds` (or GLIMMER_SIGNING_CREDS in env).
SIGNING_CREDS   ?= $(HOME)/.config/glimmer/signing.env
export GLIMMER_SIGNING_CREDS := $(SIGNING_CREDS)
CREDS           := scripts/signing-creds.sh
# Dedicated signing keychain - kept SEPARATE from the login keychain so signing
# setup never touches the user's personal credentials, and so the Developer ID
# key can be imported with `-T /usr/bin/codesign` baked into its ACL (the only
# reliable way to get non-interactive codesign; set-key-partition-list alone
# can't retrofit that onto an already-imported login-keychain key). This is the
# standard CI/CD pattern. Created by `make codesign-setup`.
SIGN_KEYCHAIN   := $(HOME)/Library/Keychains/glimmer-signing.keychain-db
# Self-signed identity for DEV builds - gives a STABLE code signature so the
# Input Monitoring / Local Network TCC grants survive rebuilds (ad-hoc's
# per-build cdhash never matches a prior grant). Created by `make dev-sign-setup`.
DEV_SIGN_KEYCHAIN := $(HOME)/Library/Keychains/glimmer-dev-signing.keychain-db
DEV_SIGN_CN       := Glimmer Dev
# Version single source of truth: Glimmer/Version.xcconfig (NOT pbxproj).
MARKETING_VERSION := $(shell sed -n 's/^MARKETING_VERSION = \(.*\)/\1/p' Glimmer/Version.xcconfig | tr -d ' ')
DMG_NAME        := Glimmer-$(MARKETING_VERSION).dmg
DIST_DIR        := $(DERIVED)/dist
# Build number (CFBundleVersion) - the monotonic stamp Sparkle keys updates on.
BUILD_NUMBER    := $(shell sed -n 's/^CURRENT_PROJECT_VERSION = \(.*\)/\1/p' Glimmer/Version.xcconfig | tr -d ' ')
# Repo that hosts the Sparkle appcast (GitHub Pages) + release assets - the
# public source repo itself.
RELEASES_REPO   ?= Se7enbrc/glimmer
SPARKLE_VERSION ?= 2.9.3
export SPARKLE_VERSION

.PHONY: all release install uninstall clean app sign embed open \
        profile profile-signposts setup-notary notarize dmg dist preflight \
        codesign-setup codesign-teardown ensure-signing dev dev-sign-setup \
        creds-init enable-telem disable-telem release-publish sparkle-keys

all: app sign

release:
	$(MAKE) CONFIG=Release all

app:
	@echo "▶ Building Glimmer.app ($(CONFIG))..."
	@scripts/generate-build-info.sh
	xcodebuild -project Glimmer.xcodeproj -scheme Glimmer -configuration $(CONFIG) \
		-xcconfig $(STREAM_XCCONFIG) \
		OPENSSL_PREFIX=$(OPENSSL_PREFIX) \
		OPUS_PREFIX=$(OPUS_PREFIX) \
		CODE_SIGNING_ALLOWED=NO \
		-derivedDataPath $(DERIVED) -destination 'platform=macOS' build
# CODE_SIGNING_ALLOWED=NO: signing is owned EXCLUSIVELY by the `sign` target
# (keychain-pinned, prompt-free). Xcode's Automatic signing during the build
# resolves identities from the login keychain and produces a password prompt
# per nested bundle - the `sign` target re-signs --force --deep right after,
# so xcodebuild's own signatures were pure prompt-noise.

# Make signing robust without prompts, every build:
#  (a) the dedicated signing keychain can lock after the Mac sleeps - re-unlock
#      it with the password from the credentials file (works from ANY session:
#      SSH, cron, CI). Legacy fallback: the login-keychain stash that the old
#      codesign-setup wrote (GUI sessions only - the login keychain is locked
#      elsewhere), kept so pre-creds-file machines don't regress; and
#  (b) a sibling project's keychain (e.g. mx4-signing) can jump ahead in the
#      search list and shadow our partition-list-authorized cert with an
#      identically-named copy that prompts - re-assert ours first.
# No-op (and no prompt) if the signing keychain isn't set up yet - run
# `make codesign-setup` once to create it.
ensure-signing:
	@test -n "$(strip $(DEVELOPER_ID))" || exit 0; \
	test -f "$(SIGN_KEYCHAIN)" || exit 0; \
	others=$$(security list-keychains -d user | sed 's/[" ]//g' | grep -vF "$(SIGN_KEYCHAIN)" || true); \
	security list-keychains -d user -s "$(SIGN_KEYCHAIN)" $$others >/dev/null 2>&1 || true; \
	KCPW=$$($(CREDS) get SIGN_KEYCHAIN_PASSWORD --optional 2>/dev/null || true); \
	if [ -z "$$KCPW" ]; then \
		KCPW=$$(security find-generic-password -a "$(USER)" -s glimmer-signing-kc-pw -w \
			"$$HOME/Library/Keychains/login.keychain-db" 2>/dev/null || true); \
	fi; \
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
sign: app ensure-signing
ifeq ($(strip $(DEVELOPER_ID)),)
	@echo "▶ Adhoc-signing bundle inside-out (no Developer ID cert found)..."
	scripts/sign-bundle.sh "$(GLIMMER_APP_SRC)" "-" "" Glimmer/Glimmer.entitlements
else
	@echo "▶ Signing bundle inside-out with: $(DEVELOPER_ID)"
	scripts/sign-bundle.sh "$(GLIMMER_APP_SRC)" "$(DEVELOPER_ID)" "$(SIGN_KEYCHAIN)" Glimmer/Glimmer.entitlements
endif

# Embed + re-sign the Homebrew dylibs. Done AFTER `sign` because embedding
# rewrites the bundle (the app must be signed last); embed-dylibs re-signs the
# whole bundle itself with the same identity. Use this for distribution builds.
embed: sign
	scripts/embed-dylibs.sh "$(GLIMMER_APP_SRC)" "$(if $(strip $(DEVELOPER_ID)),$(DEVELOPER_ID),-)" "$(if $(strip $(DEVELOPER_ID)),$(SIGN_KEYCHAIN),)"

install: all
	@echo "▶ Installing Glimmer.app to $(GLIMMER_APP_DST)..."
	@if [ -d "$(GLIMMER_APP_DST)" ]; then \
		echo "  removing existing $(GLIMMER_APP_DST)"; \
		rm -rf "$(GLIMMER_APP_DST)"; \
	fi
	cp -R "$(GLIMMER_APP_SRC)" "$(GLIMMER_APP_DST)"
	@COMMIT=$$(sed -nE 's/.*static let commit = "([^"]+)".*/\1/p' Glimmer/BuildInfo.generated.swift); \
	echo "  ✓ installed build $$COMMIT"; \
	if pgrep -x Glimmer >/dev/null 2>&1; then \
		echo "  ⚠ Glimmer is RUNNING an older build - it will NOT load $$COMMIT until you"; \
		echo "    fully QUIT (⌘Q) and relaunch. Starting a new STREAM does not reload the"; \
		echo "    binary. Run 'make reinstall' to quit + relaunch automatically."; \
	fi

open: install
	open "$(GLIMMER_APP_DST)"

# Build + install + (quit any running instance and) relaunch - guarantees the
# NEW build is the one actually loaded. A running app keeps its old binary in
# memory: installing over the bundle on disk does nothing for the live process,
# and starting a new stream reuses the same instance, so a dev can unknowingly
# test stale code for an hour. Use this when iterating on a dev build. (Builds
# FIRST via the `install` prereq, so a failed build never quits a good session.)
reinstall: install
	@if pgrep -x Glimmer >/dev/null 2>&1; then \
		echo "▶ Quitting the running Glimmer so the new build can load..."; \
		osascript -e 'tell application "Glimmer" to quit' >/dev/null 2>&1 || true; \
		for i in 1 2 3 4 5 6 7 8; do pgrep -x Glimmer >/dev/null 2>&1 || break; sleep 1; done; \
		pkill -x Glimmer >/dev/null 2>&1 || true; \
	fi
	@echo "▶ Relaunching..."; open "$(GLIMMER_APP_DST)"
	@COMMIT=$$(sed -nE 's/.*static let commit = "([^"]+)".*/\1/p' Glimmer/BuildInfo.generated.swift); \
	echo "  ✓ now running build $$COMMIT"

# One-time: create a self-signed code-signing identity in a dedicated keychain
# so `make dev` builds carry a STABLE signature. macOS keys the Input
# Monitoring / Local Network TCC grants on the code signature, so with a stable
# one the grant survives rebuilds - ad-hoc's changing cdhash means macOS never
# recognises a prior grant (the raw-HID feature literally can't be tested in dev
# without this). No Apple cert needed; the cert is self-signed and only used
# for LOCAL running. The keychain password is stored in the credentials file
# (created 0600 automatically if absent - still a zero-prep target) so `make
# dev` can unlock non-interactively from any session; the login keychain is
# never touched.
dev-sign-setup:
	@set -eu; \
	OPENSSL="$$(brew --prefix openssl@3)/bin/openssl"; \
	KCPASS="$$($(CREDS) get DEV_KEYCHAIN_PASSWORD --optional 2>/dev/null || true)"; \
	[ -n "$$KCPASS" ] || KCPASS="$$(/usr/bin/openssl rand -base64 24)"; \
	TMP="$$(mktemp -d)"; trap 'rm -rf "$$TMP"' EXIT; \
	"$$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
		-keyout "$$TMP/key.pem" -out "$$TMP/cert.pem" -subj "/CN=$(DEV_SIGN_CN)" \
		-addext "basicConstraints=critical,CA:FALSE" \
		-addext "keyUsage=critical,digitalSignature" \
		-addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null; \
	"$$OPENSSL" pkcs12 -export -legacy -inkey "$$TMP/key.pem" -in "$$TMP/cert.pem" \
		-out "$$TMP/dev.p12" -passout "pass:$$KCPASS" -name "$(DEV_SIGN_CN)"; \
	security delete-keychain "$(DEV_SIGN_KEYCHAIN)" 2>/dev/null || true; \
	security create-keychain -p "$$KCPASS" "$(DEV_SIGN_KEYCHAIN)"; \
	security set-keychain-settings "$(DEV_SIGN_KEYCHAIN)"; \
	security unlock-keychain -p "$$KCPASS" "$(DEV_SIGN_KEYCHAIN)"; \
	security import "$$TMP/dev.p12" -k "$(DEV_SIGN_KEYCHAIN)" -P "$$KCPASS" -T /usr/bin/codesign; \
	security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$$KCPASS" "$(DEV_SIGN_KEYCHAIN)" >/dev/null; \
	$(CREDS) set DEV_KEYCHAIN_PASSWORD "$$KCPASS"; \
	security list-keychains -d user -s "$(DEV_SIGN_KEYCHAIN)" $$(security list-keychains -d user | sed 's/[" ]//g'); \
	echo "  ✓ dev signing identity '$(DEV_SIGN_CN)' ready - 'make dev' now signs stably"

# Fast dev inner-loop. Signs with the self-signed '$(DEV_SIGN_CN)' identity if
# `make dev-sign-setup` has been run (STABLE signature → TCC grants stick across
# rebuilds); otherwise ad-hoc (no keychain, but TCC re-prompts each build).
# Dylibs embedded, installed, relaunched. Real Developer-ID signing +
# notarization remain a RELEASE step (make dist). Sandbox container is bundle-id
# keyed, so paired hosts + settings survive.
dev:
	@DEVKC="$(DEV_SIGN_KEYCHAIN)"; SIGN_ID=""; \
	if [ -f "$$DEVKC" ]; then \
		others=$$(security list-keychains -d user | sed 's/[" ]//g' | grep -vF "$$DEVKC" || true); \
		security list-keychains -d user -s "$$DEVKC" $$others >/dev/null 2>&1 || true; \
		KCPW=$$($(CREDS) get DEV_KEYCHAIN_PASSWORD --optional 2>/dev/null || true); \
		if [ -z "$$KCPW" ]; then \
			KCPW=$$(security find-generic-password -a "$(USER)" -s glimmer-dev-signing-kc-pw -w \
				"$$HOME/Library/Keychains/login.keychain-db" 2>/dev/null || true); \
		fi; \
		if [ -n "$$KCPW" ]; then \
			security unlock-keychain -p "$$KCPW" "$$DEVKC" 2>/dev/null || true; \
			security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$$KCPW" "$$DEVKC" >/dev/null 2>&1 || true; \
		fi; \
		SIGN_ID="$(DEV_SIGN_CN)"; \
		echo "  ▶ dev build signed with stable identity '$(DEV_SIGN_CN)'"; \
	else \
		echo "  ▶ dev build ad-hoc - run 'make dev-sign-setup' once for stable TCC grants"; \
	fi; \
	$(MAKE) DEVELOPER_ID="$$SIGN_ID" CONFIG=Release app embed; \
	SRC="$(DERIVED)/Build/Products/Release/Glimmer.app"; \
	osascript -e 'tell application "Glimmer" to quit' >/dev/null 2>&1 || true; \
	n=0; while pgrep -x Glimmer >/dev/null && [ $$n -lt 5 ]; do sleep 1; n=$$((n+1)); done; \
	pkill -x Glimmer 2>/dev/null || true; sleep 1; \
	rm -rf "$(GLIMMER_APP_DST)"; cp -R "$$SRC" "$(GLIMMER_APP_DST)"; \
	echo "  ✓ dev build installed to $(GLIMMER_APP_DST)"; \
	open -a "$(GLIMMER_APP_DST)"

uninstall:
	@echo "▶ Uninstalling Glimmer..."
	@rm -rf "$(GLIMMER_APP_DST)"
	@echo "  ✓ removed"

clean:
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
# After this, `make embed` / `make dist` find the identity via DEVELOPER_ID
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
		$$(security list-keychains -d user | sed 's/[" ]//g' | grep -v glimmer-signing) 2>/dev/null || true
	@security delete-keychain "$(SIGN_KEYCHAIN)" 2>/dev/null || true
	@echo "  ✓ removed"

# --- Notarization / distribution -------------------------------------------

# One-time setup: store the Apple ID app-specific password as a notarytool
# credential profile IN THE DEDICATED SIGNING KEYCHAIN (--keychain). The default
# would be the login keychain, which is locked in SSH/cron/CI sessions - the
# dedicated keychain is the one ensure-signing already knows how to unlock from
# the credentials file, so `notarytool submit` works from any session. Reads
# APPLE_ID / APPLE_APP_PASSWORD (+ optional APPLE_TEAM_ID) from the credentials
# file. Re-run only if the app-specific password rotates (edit the creds file
# first). Requires `make codesign-setup` to have created the keychain.
setup-notary:
	@echo "▶ Storing notary profile '$(NOTARY_PROFILE)' in the signing keychain..."
	@set -eu; \
	test -f "$(SIGN_KEYCHAIN)" || { echo "ERR: no signing keychain - run 'make codesign-setup' first (the profile lives there)" >&2; exit 1; }; \
	$(CREDS) missing APPLE_ID APPLE_APP_PASSWORD SIGN_KEYCHAIN_PASSWORD \
		|| { echo "  fill those in ($$($(CREDS) path)), then re-run - 'make dist' runs this automatically" >&2; exit 1; }; \
	APPLE_ID="$$($(CREDS) get APPLE_ID)"; \
	APP_PW="$$($(CREDS) get APPLE_APP_PASSWORD)"; \
	TEAM="$$($(CREDS) get APPLE_TEAM_ID --optional)"; \
	[ -n "$$TEAM" ] || TEAM='$(TEAM_ID)'; \
	[ -n "$$TEAM" ] || { echo "ERR: no team id - set APPLE_TEAM_ID in the creds file (no Developer ID cert to derive it from)" >&2; exit 1; }; \
	KCPW="$$($(CREDS) get SIGN_KEYCHAIN_PASSWORD)"; \
	security unlock-keychain -p "$$KCPW" "$(SIGN_KEYCHAIN)"; \
	xcrun notarytool store-credentials "$(NOTARY_PROFILE)" \
		--apple-id "$$APPLE_ID" --team-id "$$TEAM" --password "$$APP_PW" \
		--keychain "$(SIGN_KEYCHAIN)"; \
	echo "  ✓ notary profile stored (dedicated keychain - readable from any session)"

# Notarize the already-signed bundle: zip → submit (waits) → staple. Requires a
# Developer ID signature (the adhoc fallback can't notarize) and a stored
# notary profile (run `make setup-notary` first). Re-runs ensure-signing right
# before the submit because the Release build that precedes it is long enough
# for a sleep to re-lock the keychain holding the profile. The profile lookup
# probes the dedicated keychain first (where the current setup-notary stores
# it, readable any session) and falls back to notarytool's default search
# (login keychain) for profiles stored by the old setup-notary - a metadata
# probe only, so it never prompts.
notarize: embed
	@test -n "$(strip $(DEVELOPER_ID))" || { echo "ERR: no Developer ID cert - can't notarize" >&2; exit 1; }
	@$(MAKE) --no-print-directory ensure-signing
	@echo "▶ Notarizing $(GLIMMER_APP_SRC)..."
	@rm -f "$(DERIVED)/Glimmer-notarize.zip"
	ditto -c -k --sequesterRsrc --keepParent "$(GLIMMER_APP_SRC)" "$(DERIVED)/Glimmer-notarize.zip"
	@NKC=""; \
	if security find-generic-password -s com.apple.gke.notary.tool "$(SIGN_KEYCHAIN)" >/dev/null 2>&1 \
		|| security dump-keychain "$(SIGN_KEYCHAIN)" 2>/dev/null | grep -q notary; then \
		NKC="--keychain $(SIGN_KEYCHAIN)"; \
		echo "  ▶ notary profile '$(NOTARY_PROFILE)' (dedicated keychain)"; \
	else \
		echo "  ▶ notary profile '$(NOTARY_PROFILE)' (default keychain search - legacy)"; \
	fi; \
	xcrun notarytool submit "$(DERIVED)/Glimmer-notarize.zip" \
		--keychain-profile "$(NOTARY_PROFILE)" $$NKC --wait
	xcrun stapler staple "$(GLIMMER_APP_SRC)"
	@rm -f "$(DERIVED)/Glimmer-notarize.zip"
	@echo "  ✓ notarized + stapled"
	@spctl --assess --type execute --verbose=2 "$(GLIMMER_APP_SRC)" || true

# Build a distributable DMG from the signed (and ideally notarized) bundle.
dmg:
	@test -d "$(GLIMMER_APP_SRC)" || { echo "ERR: build first (make release embed)" >&2; exit 1; }
	@echo "▶ Building $(DMG_NAME)..."
	@rm -rf "$(DIST_DIR)" && mkdir -p "$(DIST_DIR)/stage"
	cp -R "$(GLIMMER_APP_SRC)" "$(DIST_DIR)/stage/"
	ln -s /Applications "$(DIST_DIR)/stage/Applications"
	hdiutil create -volname "Glimmer $(MARKETING_VERSION)" \
		-srcfolder "$(DIST_DIR)/stage" -ov -format UDZO "$(DIST_DIR)/$(DMG_NAME)"
	@rm -rf "$(DIST_DIR)/stage"
	@echo "  ✓ $(DIST_DIR)/$(DMG_NAME)"
	@shasum -a 256 "$(DIST_DIR)/$(DMG_NAME)"

# Fail-fast gate for `make dist`: verify every non-interactive ingredient
# BEFORE the long Release build, so a missing cert/creds/profile surfaces in
# seconds instead of after minutes of compiling. SELF-BOOTSTRAPPING: the first
# run writes the creds template itself and says exactly
# which keys to fill; once the file is complete, the notary profile is stored
# automatically and a legacy login-keychain stash migrates into the file on
# the spot - the whole first-run flow is "make dist, fill 4 values, make dist".
# Human input is required ONLY for the secrets themselves. All probes are
# prompt-free: identity listing and generic-password lookups are metadata
# searches that work on locked keychains.
preflight:
	@set -eu; \
	echo "▶ Preflight (release signing)..."; \
	test -n "$(strip $(DEVELOPER_ID))" || { echo "ERR: no 'Developer ID Application' identity - run 'make codesign-setup' (docs/RELEASE.md)" >&2; exit 1; }; \
	echo "  ✓ identity: $(DEVELOPER_ID)"; \
	if ! $(CREDS) check >/dev/null 2>&1; then \
		$(CREDS) init >/dev/null; \
		echo "ERR: first run - signing credentials needed." >&2; \
		echo "  A template was just written to: $$($(CREDS) path)" >&2; \
		echo "  Fill in: APPLE_ID APPLE_APP_PASSWORD (and P12_PATH P12_PASSWORD if the" >&2; \
		echo "  signing keychain ever needs rebuilding), then re-run 'make dist' -" >&2; \
		echo "  notary setup and keychain migration are automatic from there." >&2; \
		exit 1; \
	fi; \
	echo "  ✓ creds file: $$($(CREDS) path)"; \
	if ! $(CREDS) missing APPLE_ID APPLE_APP_PASSWORD 2>/dev/null; then \
		echo "  ▶ fetching missing keys from 1Password (approve the prompt)..."; \
		$(CREDS) fill-from-op || true; \
		$(CREDS) missing APPLE_ID APPLE_APP_PASSWORD \
			|| { echo "  fill those in (or set OP_SOURCE - see the template), then re-run 'make dist'" >&2; exit 1; }; \
	fi; \
	if ! $(CREDS) get SIGN_KEYCHAIN_PASSWORD --optional | grep -q . ; then \
		if KCPW="$$(security find-generic-password -a "$(USER)" -s glimmer-signing-kc-pw -w \
				"$$HOME/Library/Keychains/login.keychain-db" 2>/dev/null)"; then \
			$(CREDS) set SIGN_KEYCHAIN_PASSWORD "$$KCPW"; \
			echo "  ✓ migrated keychain password from the legacy login-keychain stash"; \
		fi; \
	fi; \
	if ! security find-generic-password -s com.apple.gke.notary.tool >/dev/null 2>&1 \
		&& ! security dump-keychain "$(SIGN_KEYCHAIN)" 2>/dev/null | grep -q notary; then \
		echo "  ▶ no notary profile yet - storing it now (automatic setup-notary)..."; \
		$(MAKE) --no-print-directory setup-notary; \
	fi; \
	echo "  ✓ notary profile present"

# One-time: write the signing credentials file template (mode 0600, outside the
# repo) and print where it landed. Fill in the values, then `make codesign-setup`
# and `make setup-notary`. See docs/RELEASE.md for the full one-time checklist.
creds-init:
	@$(CREDS) init

# Full distribution pipeline: preflight (fail fast, see above) → clean Release
# → Developer ID sign + embed → notarize + staple → DMG. The DMG's app is
# stapled, so it passes Gatekeeper offline on any Mac. Non-interactive from any
# session once the one-time setup is done (creds file + codesign-setup +
# setup-notary - docs/RELEASE.md).
dist:
	$(MAKE) CONFIG=Release preflight clean app notarize dmg

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

# Build + notarize + staple (via `dist`), then publish a Sparkle update: ZIP the
# notarized bundle, EdDSA-sign it (key from the creds file), upload the ZIP + DMG
# to the public glimmer GitHub release, and update the Pages-hosted appcast.xml.
# Prompt-free once the one-time signing / notary / sparkle-keys setup is done.
# Bump Glimmer/Version.xcconfig + commit FIRST - the appcast version comes from
# HEAD; the public repo at the tag is the GPL corresponding source.
release-publish: dist
	@scripts/publish-release.sh \
		"$(MARKETING_VERSION)" "$(BUILD_NUMBER)" \
		"$(DERIVED)/Build/Products/Release/Glimmer.app" \
		"$(DIST_DIR)" "$(RELEASES_REPO)"

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
