# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Check release versions before signing or publishing any artifacts."""

import argparse
import os
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def validate_feed(channel: ET.Element, short: str, build: str,
                  release_channel: str = "", promote: bool = False) -> ET.Element | None:
    """Allow an exact retry, but never reuse a build or move backwards."""
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", short):
        raise ValueError("release version must be YYYY.M.MICRO")
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("build number must be a positive integer")
    if release_channel not in ("", "rc") or (promote and release_channel):
        raise ValueError("promotion requires the stable channel")
    existing = None
    seen_builds = set()
    for item in channel.findall("item"):
        old_build = item.findtext(f"{{{SPARKLE}}}version", "")
        old_short = item.findtext(f"{{{SPARKLE}}}shortVersionString", "")
        old_channel = item.findtext(f"{{{SPARKLE}}}channel", "")
        if not re.fullmatch(r"[1-9][0-9]*", old_build):
            raise ValueError(f"invalid published build number: {old_build!r}")
        if int(old_build) in seen_builds:
            raise ValueError(f"duplicate published build: {old_build}")
        seen_builds.add(int(old_build))
        if old_build == build:
            if old_short != short:
                raise ValueError(f"build {build} already belongs to {old_short}")
            if old_channel != release_channel and not (promote and old_channel == "rc"):
                raise ValueError("published channel cannot change without explicit promotion")
            existing = item
        else:
            if int(build) <= int(old_build):
                raise ValueError(f"build {build} must exceed published build {old_build} ({old_short})")
            if old_short == short and not (old_channel == "rc" and (release_channel == "rc" or promote)):
                raise ValueError(f"{short} already uses build {old_build}; bump the release version")
    if promote and existing is None:
        raise ValueError("promotion requires an existing published candidate")
    return existing


def validate_bundle(info: dict, short: str, build: str) -> None:
    for key, expected in (("CFBundleShortVersionString", short), ("CFBundleVersion", build)):
        if info.get(key) != expected:
            raise ValueError(f"bundle {key} ({info.get(key)!r}) does not match {expected}; rebuild")


def validate_distribution(app: str) -> None:
    """Check both distribution trust and actual AMFI launch authorization."""
    bundle = Path(app).resolve()
    commands = (
        ("/usr/bin/codesign", "--verify", "--deep", "--strict", app),
        ("/usr/bin/xcrun", "stapler", "validate", app),
        ("/usr/sbin/spctl", "--assess", "--type", "execute", app),
        (str(bundle / "Contents/MacOS/Glimmer"), "help"),
        (str(bundle / "Contents/Library/LaunchServices/Glimmer Network Helper.app/Contents/MacOS/io.ugfugl.glimmer.helper"),
         "--check-launch"),
    )
    for command in commands:
        try:
            subprocess.run(command, check=True, capture_output=True, text=True, timeout=30)
        except subprocess.CalledProcessError as error:
            detail = (error.stderr or error.stdout or "validation failed").strip()
            raise ValueError(f"{Path(command[0]).name} rejected {app}: {detail}") from error
        except subprocess.TimeoutExpired as error:
            raise ValueError(f"{Path(command[0]).name} validation timed out; do not install this build") from error
        except OSError as error:
            raise ValueError(f"Couldn't launch {Path(command[0]).name} for distribution validation") from error


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--short-version")
    parser.add_argument("--build")
    parser.add_argument("--channel", choices=("", "rc"), default=os.environ.get("GLIMMER_RELEASE_CHANNEL", ""))
    parser.add_argument("--app")
    parser.add_argument("--validate-distribution", action="store_true")
    args = parser.parse_args()
    if args.validate_distribution and not args.app:
        parser.error("--validate-distribution requires --app")
    try:
        config = Path(args.config).read_text()
        values = dict(re.findall(r"^(MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=\s*(\S+)\s*$", config, re.M))
        short, build = values["MARKETING_VERSION"], values["CURRENT_PROJECT_VERSION"]
        if args.short_version is not None and args.short_version != short:
            raise ValueError("advertised release version does not match Version.xcconfig")
        if args.build is not None and args.build != build:
            raise ValueError("advertised build number does not match Version.xcconfig")
        channel = ET.parse(args.appcast).getroot().find("channel")
        if channel is None:
            raise ValueError("appcast has no channel")
        validate_feed(channel, short, build, args.channel)
        if args.app:
            with open(Path(args.app) / "Contents/Info.plist", "rb") as source:
                validate_bundle(plistlib.load(source), short, build)
            if args.validate_distribution:
                validate_distribution(args.app)
    except (OSError, ValueError, KeyError, ET.ParseError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"ERR: {error}\n")
    print(f"Release versions verified: {short} ({build})")


if __name__ == "__main__":
    main()
