# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

check:
	@echo "▶ Check (workflows + lint --strict + release-tool tests)..."
	@actionlint
	@scripts/check-spdx.sh
	@if [ -f scripts/check-engine-boundary.py ]; then python3 scripts/check-engine-boundary.py; fi
	@if [ -f scripts/check-ios-boundary.py ]; then python3 scripts/check-ios-boundary.py; fi
	@scripts/lint-swift.sh lint --strict --quiet
	@$(MAKE) test-scripts

check-portable:
	@actionlint
	@scripts/check-spdx.sh
	@$(MAKE) test-scripts TEST_PLATFORM=portable

check-macos:
	@if [ -f scripts/check-engine-boundary.py ]; then python3 scripts/check-engine-boundary.py; fi
	@if [ -f scripts/check-ios-boundary.py ]; then python3 scripts/check-ios-boundary.py; fi
	@$(MAKE) test-scripts TEST_PLATFORM=macos

# Fixture repositories need git's own discovery; a hook's GIT_DIR would aim them at this one.
TEST_PLATFORM ?= all
test-scripts:
	$(if $(COVERAGE),@rm -rf $(DERIVED)/coverage/python && mkdir -p $(DERIVED)/coverage/python)
	@env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
		$(if $(COVERAGE),$(COVERAGE_PY) run --rcfile=scripts/tests/coveragerc,python3) scripts/test-scripts.py $(TEST_PLATFORM)
	$(if $(COVERAGE),@python3 scripts/coverage-report.py python)
