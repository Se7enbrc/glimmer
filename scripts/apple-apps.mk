# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

.PHONY: ios-app ios-test ios-device verify-all
ios-app:
	@$(MAKE) -C iOS app

ios-test:
	@$(MAKE) -C iOS test

ios-device:
	@$(MAKE) -C iOS app CONFIG=Release DESTINATION='generic/platform=iOS'

verify-all: verify
	@swift test -Xswiftc -warnings-as-errors
	@$(MAKE) ios-test TEST_FLAGS=
	@$(MAKE) ios-device
