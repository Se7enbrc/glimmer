# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

.DEFAULT_GOAL := app
.NOTPARALLEL:
CONFIG ?= Debug
DESTINATION ?= generic/platform=iOS Simulator
TEST_DESTINATION ?= platform=iOS Simulator,name=iPhone 17 Pro
ENGINE_PATH ?=
DERIVED := $(CURDIR)/build/DerivedData
PROJECT := Glimmer.xcodeproj
ifneq ($(strip $(ENGINE_PATH)),)
PROJECT := build/GlimmerLocal.xcodeproj
endif
XCODE = xcodebuild -project "$(PROJECT)" -scheme Glimmer -configuration "$(CONFIG)" \
	-derivedDataPath "$(DERIVED)" CODE_SIGNING_ALLOWED=NO

.PHONY: app test check prepare
prepare:
ifneq ($(strip $(ENGINE_PATH)),)
	@python3 scripts/local-project.py "$(ENGINE_PATH)"
endif

app: prepare
	$(XCODE) -destination '$(DESTINATION)' build

test: prepare
	$(XCODE) -destination '$(TEST_DESTINATION)' -parallel-testing-enabled NO test

check:
	@actionlint
	@bash scripts/check-spdx.sh
	@swiftlint lint --strict --quiet --no-cache
	@python3 -m unittest discover -s scripts/tests -p 'test_*.py'
