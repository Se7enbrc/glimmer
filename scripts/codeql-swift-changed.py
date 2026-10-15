#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Print run or skip only after successful classification.
A pull request skips only when it touches nothing the traced build compiles or reads."""

import re
import sys

RELEVANT = re.compile(
    r"^(Glimmer|GlimmerEngine|helper|LoginHelper|Glimmer\.xcodeproj)/"
    r"|^Glimmer-Bridging-Header\.h$|\.(xcconfig|h)$"
    r"|^Makefile$|^scripts/(generate-build-info\.sh|codeql-swiftc\.sh|codeql-coverage\.py"
    r"|codeql-swift-changed\.py|release-bundle\.mk)$|^\.github/workflows/codeql\.yml$"
)


def must_scan(paths):
    # An empty or unreadable list scans: skipping is the only outcome that needs proof.
    paths = [path.strip() for path in paths if path.strip()]
    return not paths or any(RELEVANT.search(path) for path in paths)


if __name__ == "__main__":
    print("run" if must_scan(sys.stdin) else "skip")
