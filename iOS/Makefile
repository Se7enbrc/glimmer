# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

.DEFAULT_GOAL := app
.NOTPARALLEL:
CONFIG ?= Debug
DESTINATION ?= generic/platform=iOS Simulator
TEST_DESTINATION ?= platform=iOS Simulator,name=iPhone 17 Pro
TEST_FLAGS ?=
BUILD_FLAGS ?=
DERIVED := $(CURDIR)/build/DerivedData
PROJECT := Glimmer.xcodeproj
XCODE = xcodebuild -project "$(PROJECT)" -scheme Glimmer-iOS -configuration "$(CONFIG)" \
	-derivedDataPath "$(DERIVED)" CODE_SIGNING_ALLOWED=NO \
	SWIFT_SUPPRESS_WARNINGS=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES

.PHONY: app test test-build test-run check
app:
	$(XCODE) -destination '$(DESTINATION)' $(BUILD_FLAGS) build

test:
	$(XCODE) -destination '$(TEST_DESTINATION)' -parallel-testing-enabled NO $(TEST_FLAGS) test

test-build:
	$(XCODE) -destination '$(TEST_DESTINATION)' -showBuildTimingSummary $(TEST_FLAGS) build-for-testing

test-run:
	@set -- "$(DERIVED)"/Build/Products/*.xctestrun; \
	  test "$$#" -eq 1 && test -f "$$1" || { echo "ERR: run make test-build first" >&2; exit 1; }; \
	  xcodebuild test-without-building -xctestrun "$$1" -destination '$(TEST_DESTINATION)' \
	  -parallel-testing-enabled NO $(TEST_FLAGS)

check:
	@$(MAKE) -C .. check
