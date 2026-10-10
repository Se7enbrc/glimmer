#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

# Parse private keys offline without printing scanner findings.
set -euo pipefail
exec bash "$(dirname "$0")/check-secrets.sh" private-keys
