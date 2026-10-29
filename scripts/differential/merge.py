#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Writes corpus inputs with the baseline's observations, keeping reviewed accepted differences."""

import json
import sys
from pathlib import Path


def write(path, baseline, cases):
    """One case per line keeps review diffs to the cases that changed."""
    lines = [json.dumps(case, sort_keys=True, separators=(",", ":")) for case in cases]
    Path(path).write_text('{"baseline":' + json.dumps(baseline) + ',"cases":[\n' + ",\n".join(lines) + "\n]}\n")

corpus, observed, baseline, dest = sys.argv[1:5]
cases = json.loads(Path(corpus).read_text())
outputs = json.loads(Path(observed).read_text())
previous = {}
if Path(dest).exists():
    previous = {c["name"]: c for c in json.loads(Path(dest).read_text())["cases"]}
merged = []
for case in cases:
    entry = {"name": case["name"], "input": case["input"], "expected": outputs[case["name"]]}
    kept = previous.get(case["name"], {})
    if kept.get("accepted") is not None and kept.get("input") == case["input"]:
        entry["accepted"], entry["reason"] = kept["accepted"], kept["reason"]
    merged.append(entry)
write(dest, baseline, merged)
print(f"{Path(dest).name}: {len(merged)} vectors")
