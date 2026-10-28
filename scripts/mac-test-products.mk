# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

# Share one instrumented test build between the current and oldest supported macOS.
# The older image only runs these products; it cannot compile with the pinned Xcode.
test-build:
	@scripts/generate-build-info.sh
	xcodebuild build-for-testing -showBuildTimingSummary -project Glimmer.xcodeproj -scheme Glimmer -configuration Debug \
	  -xcconfig $(STREAM_XCCONFIG) \
	  CODE_SIGNING_ALLOWED=NO -derivedDataPath $(DERIVED) -destination 'platform=macOS' \
	  $(if $(COVERAGE),-enableCodeCoverage YES)
	@# The tests link this Xcode's Swift Testing; ship it, since the runner's Xcode may be older.
	@platform="$$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"; \
	  ditto "$$platform/Library/Frameworks/Testing.framework" "$(DERIVED)/Build/Products/Debug/Testing.framework" && \
	  ditto "$$platform/usr/lib/lib_TestingInterop.dylib" "$(DERIVED)/Build/Products/Debug/lib_TestingInterop.dylib"
	@$(UNREGISTER_BUILDS)

test-run:
	$(if $(COVERAGE),@rm -rf $(DERIVED)/coverage/swift $(DERIVED)/Build/ProfileData)
	@set -- "$(DERIVED)"/Build/Products/Glimmer_*.xctestrun; test "$$#" -eq 1 && test -f "$$1" || { echo "ERR: run make test-build first" >&2; exit 1; }; \
	  xcodebuild test-without-building -xctestrun "$$1" -destination 'platform=macOS' \
	  -derivedDataPath $(DERIVED) $(TEST_FLAGS) \
	  $(if $(COVERAGE),-enableCodeCoverage YES -resultBundlePath $(DERIVED)/coverage/swift/glimmer.xcresult); \
	  status=$$?; $(if $(COVERAGE),[ $$status -ne 0 ] || $(TOOLS) python3 scripts/coverage-report.py swift || status=$$?;) \
	  $(UNREGISTER_BUILDS); exit $$status
