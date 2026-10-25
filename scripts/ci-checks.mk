# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

.PHONY: check check-portable check-macos check-hooks check-boundaries test-scripts

check: check-hooks check-boundaries test-scripts

check-hooks:
	@GLIMMER_SECRET_SCAN_ALL_FILES=1 $(TOOLS) hk check --all
	@scripts/check-spdx.sh

check-boundaries:
	@if [ -f Package.swift ] || [ -d GlimmerEngine ]; then $(TOOLS) python3 scripts/check-engine-boundary.py; fi
	@if [ -f Package.swift ] || [ -d GlimmerEngine ]; then $(TOOLS) python3 scripts/check-ios-boundary.py; fi

check-portable:
	@$(TOOLS) actionlint
	@scripts/check-spdx.sh
	@$(MAKE) test-scripts TEST_PLATFORM=portable

check-macos: check-boundaries
	@$(TOOLS) hk check --all --step swiftlint
	@$(MAKE) test-scripts TEST_PLATFORM=macos

TEST_PLATFORM ?= all
test-scripts:
	$(if $(COVERAGE),@rm -rf $(DERIVED)/coverage/python && mkdir -p $(DERIVED)/coverage/python)
	@$(TOOLS) $(if $(COVERAGE),$(COVERAGE_PY) run --rcfile=scripts/tests/coveragerc,python3) scripts/test-scripts.py $(TEST_PLATFORM)
	$(if $(COVERAGE),@$(TOOLS) python3 scripts/coverage-report.py python)
