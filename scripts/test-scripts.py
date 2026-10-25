# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Run every script test once across portable and native-tool partitions."""

import argparse
from pathlib import Path
import sys
import unittest

NATIVE = {"test_compare_builds", "test_update_signature", "test_ios_boundary"}


def tests(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from tests(item)
        else:
            yield item


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=("all", "portable", "macos"), default="all", nargs="?")
    platform = parser.parse_args().platform
    root = Path(__file__).resolve().parent / "tests"
    discovered = list(tests(unittest.defaultTestLoader.discover(str(root))))
    selected = [test for test in discovered if platform == "all" or
                (test.__class__.__module__ in NATIVE) == (platform == "macos")]
    if not selected:
        parser.error("the selected test partition is empty")
    result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(selected))
    return not result.wasSuccessful()


if __name__ == "__main__":
    sys.exit(main())
