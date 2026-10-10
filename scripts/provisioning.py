# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Validate an explicitly supplied macOS profile before embedding it for signing."""

import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

APP_IDENTIFIER = "com.apple.application-identifier"
TEAM_IDENTIFIER = "com.apple.developer.team-identifier"
AUDIO_ENTITLEMENTS = (
    "com.apple.developer.coremotion.head-pose",
    "com.apple.developer.spatial-audio.profile-access",
)
TOPOLOGY_ENTITLEMENT = "com.apple.developer.networking.topology-observation"
HARDENED_PROCESS = "com.apple.security.hardened-process"
VERSION_ENTITLEMENT_TYPES = {
    f"{HARDENED_PROCESS}.enhanced-security-version": int,
    f"{HARDENED_PROCESS}.enhanced-security-version-string": str,
    f"{HARDENED_PROCESS}.platform-restrictions": int,
    f"{HARDENED_PROCESS}.platform-restrictions-string": str,
}
BOOLEAN_ENTITLEMENTS = (*AUDIO_ENTITLEMENTS, TOPOLOGY_ENTITLEMENT, HARDENED_PROCESS,
                        f"{HARDENED_PROCESS}.hardened-heap", f"{HARDENED_PROCESS}.dyld-ro")
DEBUG_ENTITLEMENTS = ("get-task-allow", "com.apple.security.get-task-allow")


def decode_profile(path: Path) -> dict:
    try:
        result = subprocess.run(
            ["/usr/bin/security", "cms", "-D", "-i", str(path)],
            check=True, capture_output=True, timeout=15,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError("Couldn't decode the profile. Supply an Apple-issued macOS Developer ID profile.") from error
    try:
        profile = plistlib.loads(result.stdout)
    except (ValueError, plistlib.InvalidFileException) as error:
        raise ValueError("The decoded profile isn't a valid property list. Download a fresh profile.") from error
    if not isinstance(profile, dict):
        raise ValueError("The decoded profile has no property dictionary. Download a fresh profile.")
    return profile


def same_entitlement_value(requested, granted) -> bool:
    if type(requested) is not type(granted):
        return False
    if isinstance(requested, dict):
        return requested.keys() == granted.keys() and all(
            same_entitlement_value(value, granted[key]) for key, value in requested.items()
        )
    if isinstance(requested, list):
        return len(requested) == len(granted) and all(
            same_entitlement_value(value, grant) for value, grant in zip(requested, granted)
        )
    return requested == granted


def validate_requested_grants(requested: dict, grants: dict) -> None:
    for key, value in requested.items():
        if key == TEAM_IDENTIFIER or not (
            key.startswith("com.apple.developer.") or key == HARDENED_PROCESS
            or key.startswith(f"{HARDENED_PROCESS}.")
        ):
            continue
        expected_type = bool if key in BOOLEAN_ENTITLEMENTS else VERSION_ENTITLEMENT_TYPES.get(key)
        if expected_type is not None and type(value) is not expected_type:
            raise ValueError(f"The requested {key} must have type {expected_type.__name__}. Correct the entitlements.")
        if key in VERSION_ENTITLEMENT_TYPES:
            if (type(value) is int and value < 0) or (type(value) is str and value != "*" and not value.isdecimal()):
                raise ValueError(f"The requested {key} has an invalid version. Correct the entitlements.")
            # Xcode's profile allowlist uses '*' for both legacy integer and current string versions.
            if grants.get(key) == "*":
                continue
        if key not in grants or not same_entitlement_value(value, grants[key]):
            raise ValueError(f"The profile doesn't grant the requested {key}. Download a profile with that capability.")


def validate_profile(profile: dict, bundle_id: str, requested: dict, now: datetime | None = None) -> dict:
    if profile.get("Platform") != ["OSX"]:
        raise ValueError("The profile isn't for macOS. Supply a macOS Developer ID profile.")
    if profile.get("ProvisionsAllDevices") is not True or "ProvisionedDevices" in profile:
        raise ValueError("The profile isn't for all-device distribution. Supply a Developer ID profile.")
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime):
        raise ValueError("The profile has no valid expiration date. Download a fresh profile.")
    expiration = expiration.replace(tzinfo=timezone.utc) if expiration.tzinfo is None else expiration
    now = now or datetime.now(timezone.utc)
    now = now.replace(tzinfo=timezone.utc) if now.tzinfo is None else now
    if expiration <= now:
        raise ValueError("The profile has expired. Download a renewed Developer ID profile.")
    grants = profile.get("Entitlements")
    if not isinstance(grants, dict):
        raise ValueError("The profile has no entitlement grants. Download the approved profile.")
    for key in DEBUG_ENTITLEMENTS:
        if (key in grants and grants[key] is not False) or (key in requested and requested[key] is not False):
            raise ValueError("Debugging is enabled. Use distribution entitlements and a Developer ID profile.")
    teams = profile.get("TeamIdentifier")
    if not isinstance(teams, list) or len(teams) != 1 or not isinstance(teams[0], str) or not teams[0]:
        raise ValueError("The profile has no unambiguous TeamIdentifier. Download the correct team's profile.")
    team = teams[0]
    if grants.get(TEAM_IDENTIFIER) != team:
        raise ValueError("The profile's team identifiers disagree. Download the correct team's profile.")
    prefixes = profile.get("ApplicationIdentifierPrefix")
    if not isinstance(prefixes, list) or not prefixes or any(
        not isinstance(prefix, str) or not prefix or "*" in prefix for prefix in prefixes
    ):
        raise ValueError("The profile has no valid App ID prefix. Download an explicit App ID profile.")
    app_id = grants.get(APP_IDENTIFIER)
    if not isinstance(app_id, str) or "*" in app_id or app_id not in {
        f"{prefix}.{bundle_id}" for prefix in prefixes
    }:
        raise ValueError("The profile's App ID doesn't exactly match this app. Download its explicit App ID profile.")
    for key, value in ((APP_IDENTIFIER, app_id), (TEAM_IDENTIFIER, team)):
        if key in requested and requested[key] != value:
            raise ValueError("The requested app or team identifier conflicts with the profile. Correct the entitlements.")
    validate_requested_grants(requested, grants)
    resolved = dict(requested)
    resolved[APP_IDENTIFIER] = app_id
    resolved[TEAM_IDENTIFIER] = team
    return resolved


def read_plist(path: Path, label: str) -> dict:
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise ValueError(f"Couldn't read {label}. Check the explicit input path and property list.") from error
    if not isinstance(value, dict):
        raise ValueError(f"{label} must contain a property dictionary.")
    return value


def atomic_write(path: Path, data: bytes, mode: int) -> None:
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.", delete=False) as output:
            temporary = Path(output.name)
            output.write(data)
            os.fchmod(output.fileno(), mode)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def prepare_app(profile_path: Path, app: Path, entitlements: Path, output: Path) -> None:
    if not profile_path.is_file():
        raise ValueError("Provisioning profile missing. Pass --profile with an approved macOS Developer ID profile.")
    info_path = app / "Contents" / "Info.plist"
    embedded = app / "Contents" / "embedded.provisionprofile"
    if output.resolve() in {path.resolve() for path in (profile_path, entitlements, info_path, embedded)}:
        raise ValueError("Choose a separate --output-entitlements path under the build directory.")
    info = read_plist(info_path, "the app's Info.plist")
    bundle_id = info.get("CFBundleIdentifier")
    if not isinstance(bundle_id, str) or not bundle_id or "*" in bundle_id or any(c.isspace() for c in bundle_id):
        raise ValueError("The app has no valid bundle identifier. Rebuild the app before provisioning it.")
    requested = read_plist(entitlements, "the app entitlements")
    profile_data = profile_path.read_bytes()
    profile = decode_profile(profile_path)
    if profile_path.read_bytes() != profile_data:
        raise ValueError("The profile changed during validation. Retry with an unchanged profile file.")
    resolved = validate_profile(profile, bundle_id, requested)
    resolved_data = plistlib.dumps(resolved, fmt=plistlib.FMT_XML, sort_keys=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    atomic_write(output, resolved_data, 0o600)
    atomic_write(embedded, profile_data, 0o644)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--app", required=True)
    parser.add_argument("--entitlements", required=True)
    parser.add_argument("--output-entitlements", required=True)
    args = parser.parse_args()
    try:
        prepare_app(Path(args.profile), Path(args.app), Path(args.entitlements), Path(args.output_entitlements))
    except ValueError as error:
        parser.exit(1, f"ERR: {error}\n")
    except OSError:
        parser.exit(1, "ERR: Couldn't prepare provisioning files. Check the explicit paths and permissions.\n")
    print("Provisioning profile validated and embedded.")


if __name__ == "__main__":
    main()
