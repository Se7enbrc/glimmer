#!/bin/bash
# Parse private keys offline without printing scanner findings.
set -euo pipefail
exec bash "$(dirname "$0")/check-secrets.sh" private-keys
