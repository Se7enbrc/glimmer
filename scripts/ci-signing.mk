# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

ifeq ($(CI):$(GITHUB_ACTIONS),true:true)
ifeq ($(strip $(RUNNER_TEMP)),)
$(error CI signing requires RUNNER_TEMP)
endif
else
$(error Signing runs only in the hosted Release workflow)
endif

include Makefile

SIGNING_CREDS ?=
SIGN_KEYCHAIN ?=
PROVISIONING_PROFILE ?=
HELPER_PROVISIONING_PROFILE ?=
NOTARY_PROFILE ?= notary
CREDS := scripts/signing-creds.sh
export GLIMMER_SIGNING_CREDS := $(SIGNING_CREDS)
export GLIMMER_PROVISIONING_PROFILE := $(PROVISIONING_PROFILE)
export GLIMMER_HELPER_PROVISIONING_PROFILE := $(HELPER_PROVISIONING_PROFILE)
DEVELOPER_ID = $(shell security find-identity -v -p codesigning "$(SIGN_KEYCHAIN)" 2>/dev/null | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)

.PHONY: guard-ci-signing codesign-setup setup-notary ensure-signing signing-preflight

guard-ci-signing:
	@case "$(SIGN_KEYCHAIN)" in "$(RUNNER_TEMP)"/*) ;; *) echo "CI keychain must be temporary" >&2; exit 1 ;; esac
	@case "$(SIGNING_CREDS)" in "$(RUNNER_TEMP)"/*) ;; *) echo "CI credentials must be temporary" >&2; exit 1 ;; esac

ensure-signing: guard-ci-signing
	@set -eu; \
	$(CREDS) check >/dev/null; \
	security unlock-keychain -p "$$($(CREDS) get SIGN_KEYCHAIN_PASSWORD)" "$(SIGN_KEYCHAIN)"

codesign-setup: guard-ci-signing
	@set -eu; \
	$(CREDS) check >/dev/null; \
	KCPASS="$$($(CREDS) get SIGN_KEYCHAIN_PASSWORD)"; \
	P12="$$($(CREDS) get P12_PATH)"; \
	P12PW="$$($(CREDS) get P12_PASSWORD)"; \
	test -s "$$P12"; \
	security create-keychain -p "$$KCPASS" "$(SIGN_KEYCHAIN)"; \
	security set-keychain-settings "$(SIGN_KEYCHAIN)"; \
	security unlock-keychain -p "$$KCPASS" "$(SIGN_KEYCHAIN)"; \
	security import "$$P12" -k "$(SIGN_KEYCHAIN)" -P "$$P12PW" -T /usr/bin/codesign -T /usr/bin/security; \
	security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$$KCPASS" "$(SIGN_KEYCHAIN)" >/dev/null; \
	security list-keychains -d user -s "$(SIGN_KEYCHAIN)" $$(security list-keychains -d user | sed 's/[" ]//g')

setup-notary: codesign-setup
	@set -eu; \
	$(CREDS) missing NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER_ID SIGN_KEYCHAIN_PASSWORD; \
	security unlock-keychain -p "$$($(CREDS) get SIGN_KEYCHAIN_PASSWORD)" "$(SIGN_KEYCHAIN)"; \
	xcrun notarytool store-credentials "$(NOTARY_PROFILE)" \
		--key "$$($(CREDS) get NOTARY_KEY_PATH)" --key-id "$$($(CREDS) get NOTARY_KEY_ID)" \
		--issuer "$$($(CREDS) get NOTARY_ISSUER_ID)" --keychain "$(SIGN_KEYCHAIN)"

signing-preflight: guard-ci-signing
	@$(CREDS) check >/dev/null
	@test -n "$(strip $(DEVELOPER_ID))" || { echo "CI signing identity missing" >&2; exit 1; }
	@security find-generic-password -a "com.apple.gke.notary.tool.saved-creds.$(NOTARY_PROFILE)" "$(SIGN_KEYCHAIN)" >/dev/null

include scripts/release-bundle.mk
