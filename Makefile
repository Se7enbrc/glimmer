# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

# Git hooks export these; leaked into xcodebuild they redirect SwiftPM clones into this repo.
unexport GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR GIT_QUARANTINE_PATH GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

.DEFAULT_GOAL := help

# Multiple Xcode actions share DerivedData; independent checks still run in parallel.
ifneq ($(word 2,$(filter app test test-build test-run test-asan embed-helper,$(MAKECMDGOALS))),)
.NOTPARALLEL:
endif

GLIMMER_APP_DST ?= /Applications/Glimmer.app
CONFIG          ?= Debug
SWIFTC          ?= xcrun swiftc
TEST_SUITE      ?=
# COVERAGE=1 measures the test and release-tool runs into build/coverage, with no threshold.
COVERAGE        ?=
COVERAGE_PY     ?= coverage
export COVERAGE_PY
DERIVED         ?= $(CURDIR)/build
GLIMMER_APP_SRC := $(DERIVED)/Build/Products/$(CONFIG)/Glimmer.app
# macOS keeps every built or test-hosted app registered after its folder is gone.
LSREGISTER      := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
UNREGISTER_BUILDS = find "$(DERIVED)/Build/Products" -name "*.app" -exec $(LSREGISTER) -u {} \; 2>/dev/null || true
STREAM_XCCONFIG := Glimmer/StreamLib.xcconfig
INSTRUMENTS_DIR := $(HOME)/Library/Developer/Xcode/Instruments

TOOLS := scripts/mise-exec.sh

RELEASE_VERSION_CONFIG ?= Glimmer/Version.xcconfig
MARKETING_VERSION := $(shell sed -n 's/^MARKETING_VERSION = \(.*\)/\1/p' "$(RELEASE_VERSION_CONFIG)" | tr -d ' ')
DMG_NAME        := Glimmer-$(MARKETING_VERSION).dmg
DIST_DIR        := $(DERIVED)/dist
APPCAST_FEED    := $(DERIVED)/appcast.xml
BUILD_NUMBER    := $(shell sed -n 's/^CURRENT_PROJECT_VERSION = \(.*\)/\1/p' "$(RELEASE_VERSION_CONFIG)" | tr -d ' ')
RELEASES_REPO   ?= Se7enbrc/glimmer
TAP_REPO        ?= Se7enbrc/homebrew-glimmer
export RELEASES_REPO TAP_REPO
VERSION         ?= $(MARKETING_VERSION)
SPARKLE_VERSION ?= 2.10.0
export SPARKLE_VERSION

HELPER_LABEL  := io.ugfugl.glimmer.helper
HELPER_SRCS   := helper/Protocol.swift Glimmer/AWDLProcess.swift helper/AWDLSuppressor.swift helper/HelperService.swift helper/main.swift
HELPER_PLIST  := helper/$(HELPER_LABEL).plist
HELPER_BIN    := $(DERIVED)/$(HELPER_LABEL)
HELPER_SDK    = $(shell xcrun --sdk macosx --show-sdk-path)
HELPER_TARGET := arm64-apple-macos15.7
HELPER_BUNDLE := $(GLIMMER_APP_SRC)/Contents/Library/LaunchServices/Glimmer Network Helper.app

.PHONY: help all app test test-asan test-build test-run helper-build embed-helper clean verify preflight rc \
        guard-clean-tree guard-release-version appcast-feed profile profile-signposts

all: help

help:
	@printf '%s\n' 'Develop'
	@printf '%s\n' '  help                 Show everyday commands (the default)'
	@printf '%s\n' '  app                  Compile the unsigned Mac app'
	@printf '%s\n' '  ios-app              Compile the unsigned Simulator app'
	@printf '%s\n' '  ios-device           Compile the unsigned iPhone Release app'
	@printf '%s\n' '  clean                Remove Mac build products'
	@printf '%s\n' 'Test'
	@printf '%s\n' '  test                 Run Mac tests; TEST_SUITE selects one suite'
	@printf '%s\n' '  test-asan            Run protocol fuzz tests under AddressSanitizer'
	@printf '%s\n' '  ios-test             Run iPhone Simulator tests'
	@printf '%s\n' '  ios-touch-journeys    Run iPhone/iPad touch and controller journeys in light and dark'
	@printf '%s\n' '  mac-controller-journeys Run Mac controller journeys in light and dark'
	@printf '%s\n' '  test-scripts         Run release and tooling fixtures'
	@printf '%s\n' 'Check'
	@printf '%s\n' '  check                Run all hooks, boundary audits and tooling tests'
	@printf '%s\n' '  verify               Run checks, Mac tests and AddressSanitizer'
	@printf '%s\n' '  preflight            Run the complete pre-push gate'
	@printf '%s\n' 'CI parity'
	@printf '%s\n' '  ci-parity            Compile Mac and iOS apps/tests with Xcode 26.6'
	@printf '%s\n' '  verify-all           Verify both Apple apps and the shared package'
	@printf '%s\n' 'Profile'
	@printf '%s\n' '  profile              Profile the installed CI build for CPU use'
	@printf '%s\n' '  profile-signposts    Record signposts from the installed CI build'
	@printf '%s\n' 'Release'
	@printf '%s\n' '  rc                   Dispatch a reviewed candidate through CI'
	@printf '%s\n' '  rc DRY_RUN=1         Check candidate source without publishing'

test:
	@scripts/generate-build-info.sh
	$(if $(COVERAGE),@rm -rf $(DERIVED)/coverage/swift $(DERIVED)/Build/ProfileData)
	xcodebuild test -project Glimmer.xcodeproj -scheme Glimmer -configuration Debug \
	  -xcconfig $(STREAM_XCCONFIG) \
	  CODE_SIGNING_ALLOWED=NO -derivedDataPath $(DERIVED) -destination 'platform=macOS' \
	  $(if $(strip $(TEST_SUITE)),-only-testing:GlimmerTests/$(TEST_SUITE)) \
	  $(if $(COVERAGE),-enableCodeCoverage YES -resultBundlePath $(DERIVED)/coverage/swift/glimmer.xcresult); \
	  status=$$?; $(if $(COVERAGE),[ $$status -ne 0 ] || $(TOOLS) python3 scripts/coverage-report.py swift || status=$$?;) \
	  $(UNREGISTER_BUILDS); exit $$status

include scripts/mac-test-products.mk

test-asan:
	@scripts/generate-build-info.sh
	xcodebuild test -project Glimmer.xcodeproj -scheme Glimmer -configuration Debug \
	  -xcconfig $(STREAM_XCCONFIG) \
	  CODE_SIGNING_ALLOWED=NO -derivedDataPath $(DERIVED) -destination 'platform=macOS' \
	  -enableAddressSanitizer YES -only-testing:GlimmerTests/FuzzTests \
	  -only-testing:GlimmerTests/StreamFuzzTests; \
	  status=$$?; $(UNREGISTER_BUILDS); exit $$status

app:
	@echo "▶ Building Glimmer.app ($(CONFIG))..."
	@scripts/generate-build-info.sh
	SWIFT_DETERMINISTIC_HASHING=1 xcodebuild -project Glimmer.xcodeproj -scheme Glimmer -configuration $(CONFIG) \
		-xcconfig $(STREAM_XCCONFIG) \
		CODE_SIGNING_ALLOWED=NO \
		-derivedDataPath $(DERIVED) -destination 'platform=macOS' build
	@$(UNREGISTER_BUILDS)
# Builds stay unsigned; the CI-only release path signs the accepted bundle.

$(HELPER_BIN): $(HELPER_SRCS)
	@echo "▶ Building AWDL helper (swiftc, $(HELPER_TARGET))..."
	@mkdir -p $(DERIVED)
	$(SWIFTC) -warnings-as-errors -O -target $(HELPER_TARGET) -sdk "$(HELPER_SDK)" -o "$(HELPER_BIN)" $(HELPER_SRCS)

helper-build: $(HELPER_BIN)

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

clean:
	@$(UNREGISTER_BUILDS)
	rm -rf $(DERIVED)
	@echo "  ✓ cleaned"

guard-clean-tree:
	@git diff --quiet HEAD || { echo "ERROR: refusing to build a release from a dirty worktree (commit or stash first)"; exit 1; }
	@git diff --cached --quiet || { echo "ERROR: refusing to build a release with staged changes (commit or stash first)"; exit 1; }
	@test -z "$$(git ls-files --others --exclude-standard)" || { echo "ERROR: refusing to build a release with untracked files (commit or remove them first)"; exit 1; }

appcast-feed:
	@mkdir -p "$(DERIVED)"
	@git fetch --quiet origin "+refs/heads/appcast:refs/remotes/origin/appcast" || \
		echo "  ! couldn't fetch the appcast branch; checking the last fetched copy" >&2
	@git show refs/remotes/origin/appcast:appcast.xml >"$(APPCAST_FEED)"

guard-release-version: appcast-feed
	@$(TOOLS) python3 scripts/release_validation.py --config "$(RELEASE_VERSION_CONFIG)" --appcast "$(APPCAST_FEED)"

verify:
	@$(MAKE) check TEST_PLATFORM=all
	@$(MAKE) TEST_SUITE= test
	@$(MAKE) test-asan

preflight: check-hooks check-boundaries
	@$(MAKE) test-scripts TEST_PLATFORM=fast
	@scripts/ci-parity.sh --changed
	@case "$$(git branch --show-current)" in \
		release-candidate|build/[0-9]*|feat/[0-9]*) $(MAKE) rc DRY_RUN=1 SOURCE_ONLY=1 ;; \
		*) echo "Candidate source checks: not a release branch." ;; \
	esac

rc:
	@$(TOOLS) python3 scripts/release-candidate.py $(strip $(if $(filter 1,$(DRY_RUN)),--dry-run) $(if $(filter 1,$(SOURCE_ONLY)),--source-only) $(if $(filter 1,$(DIAGNOSTIC)),--diagnostic))

profile:
	@test -d "$(GLIMMER_APP_DST)" || { echo "Install a published CI candidate first." >&2; exit 1; }
	@echo "▶ Launching Glimmer under Instruments (Time Profiler)..."
	@mkdir -p "$(INSTRUMENTS_DIR)"
	xcrun xctrace record \
	    --template "Time Profiler" \
	    --launch "$(GLIMMER_APP_DST)" \
	    --output "$(INSTRUMENTS_DIR)/$(shell date +%Y%m%d-%H%M%S)-Glimmer.trace" \
	    --time-limit 60s

profile-signposts:
	@test -d "$(GLIMMER_APP_DST)" || { echo "Install a published CI candidate first." >&2; exit 1; }
	@echo "▶ Launching Glimmer under Instruments (Logging - OSSignposts)..."
	@mkdir -p "$(INSTRUMENTS_DIR)"
	xcrun xctrace record \
	    --template "Logging" \
	    --launch "$(GLIMMER_APP_DST)" \
	    --output "$(INSTRUMENTS_DIR)/$(shell date +%Y%m%d-%H%M%S)-Glimmer-signposts.trace" \
	    --time-limit 120s

include scripts/ci-checks.mk
include scripts/apple-apps.mk
