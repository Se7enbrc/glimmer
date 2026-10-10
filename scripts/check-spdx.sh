#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

# Fails if a tracked source file lacks its SPDX license tag. The generated
# controller database is exempt.
set -u
cd "$(dirname "$0")/.." || exit 1
bad=0
while IFS= read -r f; do
    [ "$f" = Glimmer/Stream/HIDGamepad/GameControllerDB+Data.swift ] && continue
    head -n 3 "$f" | grep -q 'SPDX-License-Identifier: ' || { echo "missing SPDX header: $f" >&2; bad=1; }
done < <(git ls-files '*.swift' '*.h' '*.sh' '*.py' '*.js' Makefile '.github/workflows/*.yml')
exit "$bad"
