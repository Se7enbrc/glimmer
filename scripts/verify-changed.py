#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Print run or skip after classification so errors never authorize a skip.
Documentation and numeric version metadata may skip builds; all static checks still run."""

import os
import re
import subprocess
import sys

DOCS_ONLY = re.compile(
    r"\.md$|^docs/|^website/|^index\.html$|^\.github/ISSUE_TEMPLATE/|^LICENSE$"
)
VERSION = "Glimmer/Version.xcconfig"
VERSION_VALUES = re.compile(
    r"^(MARKETING_VERSION = )[0-9]+\.[0-9]+\.[0-9]+$|^(CURRENT_PROJECT_VERSION = )[1-9][0-9]*$", re.M
)


def version_metadata_only(base):
    if not base or not re.fullmatch(r"[0-9a-f]{40}", base):
        return False
    try:
        configs = [subprocess.check_output(["git", "show", f"{ref}:{VERSION}"],
                                          text=True, stderr=subprocess.DEVNULL, timeout=10)
                   for ref in (base, "HEAD")]
    except (OSError, subprocess.SubprocessError):
        return False
    keys = [[first or second for first, second in VERSION_VALUES.findall(config)] for config in configs]
    expected = ["MARKETING_VERSION = ", "CURRENT_PROJECT_VERSION = "]
    return (all(sorted(found) == sorted(expected) for found in keys)
            and VERSION_VALUES.sub(lambda match: match[1] or match[2], configs[0])
            == VERSION_VALUES.sub(lambda match: match[1] or match[2], configs[1]))


def must_build(paths, base=None):
    # An empty or unreadable list builds: skipping is the only outcome that needs proof.
    paths = [path.strip() for path in paths if path.strip()]
    if not paths:
        return True
    code = [path for path in paths if not DOCS_ONLY.search(path)]
    return bool(code) and (set(code) != {VERSION} or not version_metadata_only(base))


if __name__ == "__main__":
    print("run" if must_build(sys.stdin, base=os.environ.get("PR_BASE_SHA")) else "skip")
