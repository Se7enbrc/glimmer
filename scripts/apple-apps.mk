# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

.PHONY: ios-app ios-test ios-device verify-all ci-parity
ios-app:
	@$(MAKE) -C iOS app

ios-test:
	@$(MAKE) -C iOS test

ios-device:
	@$(MAKE) -C iOS app CONFIG=Release DESTINATION='generic/platform=iOS'

verify-all: verify
	@if [ -f Package.swift ]; then swift test -Xswiftc -warnings-as-errors; fi
	@if [ -f iOS/Makefile ]; then $(MAKE) ios-test TEST_FLAGS= && $(MAKE) ios-device; fi

ci-parity:
	@scripts/ci-parity.sh

.PHONY: ci-local
ci-local:
	@$(TOOLS) python3 scripts/ci-local.py $(SHARD) $(CI_TEST_FLAGS)
