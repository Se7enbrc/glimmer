#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Inspect the compiled app, including Simulator debug dylibs, without executing it."""

import argparse
from pathlib import Path
import plistlib
import re
import subprocess

COMPONENTS = (
    b'TelemetryExporter', b'FrameTraceWriter', b'SessionLogFileSink',
    b'FrameTimingTracker', b'AudioPipelineTelemetry', b'AudioVideoSkewStore',
    b'DisplayTelemetry', b'RendererTelemetry', b'ReceiveTimingTelemetry',
    b'AudioOutputProbe', b'ColorProbe',
)
SURFACES = (b'Record diagnostics', b'Beta builds turn this on by default.',
            b'controller-capabilities.json', b'glimmer.telemetry')


def contains_component(payload, name):
    # Match Swift type symbols or runtime type names, not empty seam methods or source-map filenames.
    return re.search(re.escape(name) + rb'(?:[CVO]|\x00)', payload) is not None


def inspect_bytes(payload, flavour):
    if flavour not in ('beta', 'production'):
        raise ValueError('flavour must be beta or production')
    found = [name.decode() for name in COMPONENTS if contains_component(payload, name)]
    found += [name.decode() for name in SURFACES if name in payload]
    if found:
        raise ValueError(flavour + ' contains diagnostic components: ' + ', '.join(found))
    return found


def inspect_app(app, flavour):
    app = Path(app)
    with (app / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('GlimmerBuildFlavour') != flavour:
        raise ValueError('bundle flavour differs from requested inspection')
    executable = app / info['CFBundleExecutable']
    binaries = [executable, *app.glob('*.dylib')]
    payload = b''
    for binary in binaries:
        payload += binary.read_bytes()
        symbols = subprocess.run(['xcrun', 'nm', '-U', str(binary)], capture_output=True, check=True, timeout=60)
        payload += symbols.stdout
    for resource in app.rglob('*'):
        if resource.is_file() and resource.suffix in ('.strings', '.stringsdict', '.json', '.plist'):
            payload += resource.read_bytes()
    return inspect_bytes(payload, flavour)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--flavour', required=True, choices=('beta', 'production'))
    args = parser.parse_args()
    found = inspect_app(args.app, args.flavour)
    print(f'{args.flavour}: inspected executable, symbols and resources; {len(found)} diagnostic markers')


if __name__ == '__main__':
    main()
