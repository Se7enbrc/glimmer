#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

set -euo pipefail
cd "$(dirname "$0")/.."
# Explicit configurations keep path scopes separate while sharing one rule set.
swiftlint "$@" --config .swiftlint.yml
(cd iOS && swiftlint "$@" --config .swiftlint.yml)
