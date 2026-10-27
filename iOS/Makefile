# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

.DEFAULT_GOAL := help

# Multiple Xcode actions share DerivedData; independent checks still run in parallel.
ifneq ($(word 2,$(filter app test test-build test-run,$(MAKECMDGOALS))),)
.NOTPARALLEL:
endif
CONFIG ?= Debug
IOS_FLAVOUR ?= production
ifneq ($(IOS_FLAVOUR),beta)
ifneq ($(IOS_FLAVOUR),production)
$(error IOS_FLAVOUR must be beta or production)
endif
endif
DIAGNOSTIC_CONDITION := $(if $(filter beta,$(IOS_FLAVOUR)),GLIMMER_DIAGNOSTICS,)
SWIFT_CONDITIONS := $(if $(filter Debug,$(CONFIG)),DEBUG,) $(DIAGNOSTIC_CONDITION)
DESTINATION ?= generic/platform=iOS Simulator
TEST_DESTINATION ?= platform=iOS Simulator,name=iPhone 17 Pro
TEST_FLAGS ?=
BUILD_FLAGS ?=
DERIVED ?= $(CURDIR)/build/$(IOS_FLAVOUR)/DerivedData
PROJECT := Glimmer.xcodeproj
SCHEME ?= Glimmer-iOS
XCODE = xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration "$(CONFIG)" \
	-derivedDataPath "$(DERIVED)" CODE_SIGNING_ALLOWED=NO \
	GLIMMER_BUILD_FLAVOUR=$(IOS_FLAVOUR) \
	SWIFT_ACTIVE_COMPILATION_CONDITIONS="$(SWIFT_CONDITIONS)" \
	SWIFT_SUPPRESS_WARNINGS=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES

.PHONY: help app test test-build test-run check ci-parity
help:
	@printf '%s\n' 'Develop' '  app          Compile the unsigned Simulator app' \
	  'Test' '  test         Build and run Simulator tests' \
	  '  test-build   Build reusable Simulator test products' \
	  '  test-run     Run tests without rebuilding' \
	  'Check' '  check        Run the shared repository checks' \
	  'CI parity' '  ci-parity    Compile both apps/tests with Xcode 26.6' \
	  'Profile and release' '  See make help from the repository root; signing stays in CI'

ci-parity:
	@$(MAKE) -C .. ci-parity

app:
	$(XCODE) -destination '$(DESTINATION)' $(BUILD_FLAGS) build

test:
	$(XCODE) -destination '$(TEST_DESTINATION)' -parallel-testing-enabled NO $(TEST_FLAGS) test

test-build:
	$(XCODE) -destination '$(TEST_DESTINATION)' -showBuildTimingSummary $(TEST_FLAGS) build-for-testing

test-run:
	@set -- "$(DERIVED)"/Build/Products/"$(SCHEME)"_*.xctestrun; \
	  test "$$#" -eq 1 && test -f "$$1" || { echo "ERR: run make test-build first" >&2; exit 1; }; \
	  xcodebuild test-without-building -xctestrun "$$1" -destination '$(TEST_DESTINATION)' \
	  -parallel-testing-enabled NO $(TEST_FLAGS)

check:
	@$(MAKE) -C .. check
