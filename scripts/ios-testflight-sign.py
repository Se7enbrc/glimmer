#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Export an inspected iOS archive without executing candidate code."""

import base64
from datetime import datetime, timezone
import importlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import ssl
import subprocess

artifact = importlib.import_module('ios-testflight-artifact')


def run(arguments, **kwargs):
    return subprocess.run(arguments, check=True, capture_output=True, timeout=300, **kwargs)


def private_root():
    return Path(os.environ['RUNNER_TEMP']) / 'ios-testflight-private'


def secret_file(name, destination):
    value = os.environ.get(name, '')
    if not value or len(value) > 8 * 1024**2:
        raise ValueError(f'missing or oversized {name}')
    data = base64.b64decode(value, validate=True)
    with destination.open('xb') as stream:
        stream.write(data)
    destination.chmod(0o600)


def validate_profile(profile, team):
    expiry = profile.get('ExpirationDate')
    entitlements = profile.get('Entitlements', {})
    if (not isinstance(expiry, datetime) or expiry.replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc)
            or profile.get('TeamIdentifier') != [team] or profile.get('ProvisionedDevices') is not None
            or profile.get('ProvisionsAllDevices') is True or entitlements.get('get-task-allow') is not False
            or entitlements.get('application-identifier') != f'{team}.{artifact.BUNDLE}'
            or entitlements.get('com.apple.developer.team-identifier') != team
            or entitlements.get('beta-reports-active') is not True
            or not re.fullmatch(r'[A-Fa-f0-9-]{36}', profile.get('UUID', ''))
            or not profile.get('DeveloperCertificates')):
        raise ValueError('profile must be an unexpired App Store distribution profile for this app and team')


def export_options(team, fingerprint, profile_id):
    return {'method': 'app-store-connect', 'destination': 'export', 'signingStyle': 'manual',
            'teamID': team, 'signingCertificate': fingerprint,
            'provisioningProfiles': {artifact.BUNDLE: profile_id},
            'testFlightInternalTestingOnly': True, 'manageAppVersionAndBuildNumber': False,
            'stripSwiftSymbols': True, 'uploadSymbols': True}


def signing_identity(identities, certificate_pems, profile):
    matches = re.findall(r'\b([A-F0-9]{40}) "Apple Distribution:[^"\n]+"', identities)
    certificates = re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',
                              certificate_pems, re.S)
    if len(matches) != 1 or len(certificates) != 1:
        raise ValueError('exactly one Apple Distribution identity and certificate are required')
    certificate = ssl.PEM_cert_to_DER_cert(certificates[0])
    if certificate not in profile['DeveloperCertificates']:
        raise ValueError('Apple Distribution certificate does not exactly match the profile')
    # The system fingerprint selects the sole verified identity in Xcode; DER bytes establish membership.
    return matches[0]


def credentials(team):
    root = private_root()
    root.mkdir(mode=0o700)
    secret_file('IOS_DISTRIBUTION_P12_BASE64', root / 'distribution.p12')
    secret_file('IOS_APP_STORE_PROFILE_BASE64', root / 'profile.mobileprovision')
    raw = run(['security', 'cms', '-D', '-i', str(root / 'profile.mobileprovision')]).stdout
    profile = plistlib.loads(raw)
    validate_profile(profile, team)
    keychain = root / 'signing.keychain-db'
    password = secrets.token_hex(32)
    run(['security', 'create-keychain', '-p', password, str(keychain)])
    run(['security', 'set-keychain-settings', '-lut', '3600', str(keychain)])
    run(['security', 'unlock-keychain', '-p', password, str(keychain)])
    run(['security', 'import', str(root / 'distribution.p12'), '-k', str(keychain),
         '-P', os.environ['IOS_DISTRIBUTION_P12_PASSWORD'], '-T', '/usr/bin/codesign', '-T', '/usr/bin/security'])
    run(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s',
         '-k', password, str(keychain)])
    identities = run(['security', 'find-identity', '-v', '-p', 'codesigning', str(keychain)]).stdout.decode()
    certificates = run(['security', 'find-certificate', '-a', '-c', 'Apple Distribution:',
                        '-p', str(keychain)]).stdout.decode()
    fingerprint = signing_identity(identities, certificates, profile)
    previous = run(['security', 'list-keychains', '-d', 'user']).stdout.decode()
    previous = re.findall(r'"([^"\n]+)"', previous)
    (root / 'keychains.json').write_text(json.dumps(previous))
    run(['security', 'list-keychains', '-d', 'user', '-s', str(keychain), *previous])
    profiles = Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles'
    profiles.mkdir(parents=True, exist_ok=True)
    installed = profiles / f"{profile['UUID']}.mobileprovision"
    with installed.open('xb') as output:
        output.write((root / 'profile.mobileprovision').read_bytes())
    installed.chmod(0o600)
    (root / 'installed-profile.txt').write_text(installed.name)
    return export_options(team, fingerprint, profile['UUID'])


def cleanup():
    root = private_root()
    if not root.exists():
        return
    failures = []
    def attempt(arguments):
        try:
            result = subprocess.run(arguments, capture_output=True, timeout=30)
            if result.returncode == 0:
                return True
        except (OSError, subprocess.SubprocessError):
            pass
        failures.append('security cleanup')
        return False

    saved = root / 'keychains.json'
    if saved.exists():
        try:
            if attempt(['security', 'list-keychains', '-d', 'user', '-s', *json.loads(saved.read_text())]):
                saved.unlink()
        except (OSError, ValueError):
            failures.append('keychain search list restoration')
    keychain = root / 'signing.keychain-db'
    if keychain.exists():
        attempt(['security', 'delete-keychain', str(keychain)])
    installed = root / 'installed-profile.txt'
    if installed.exists():
        try:
            name = installed.read_text()
            if not re.fullmatch(r'[A-Fa-f0-9-]{36}\.mobileprovision', name):
                raise ValueError('invalid temporary profile cleanup record')
            (Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles' / name).unlink(missing_ok=True)
            installed.unlink()
        except (OSError, ValueError):
            failures.append('temporary profile removal')
    for path in [root / 'distribution.p12', root / 'profile.mobileprovision', *root.glob('AuthKey_*.p8')]:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            failures.append('temporary credential removal')
    if failures:
        raise ValueError('temporary credential cleanup failed')
    shutil.rmtree(root)


def verify_signed_app(app, expected, team):
    artifact.regular_files(app)
    artifact.validate_app(app, expected)
    run(['codesign', '--verify', '--deep', '--strict', str(app)])
    details = run(['codesign', '-d', '--entitlements', ':-', str(app)])
    entitlements = plistlib.loads(details.stdout)
    if (entitlements.get('get-task-allow') not in (None, False)
            or entitlements.get('application-identifier') != f'{team}.{artifact.BUNDLE}'
            or entitlements.get('com.apple.developer.team-identifier') != team):
        raise ValueError('exported application has unexpected signing entitlements')
    profile = run(['security', 'cms', '-D', '-i', str(app / 'embedded.mobileprovision')])
    validate_profile(plistlib.loads(profile.stdout), team)


def verify_exported_symbols(inspected, app_uuids):
    # uploadSymbols adds Symbols/<UUID>.symbols per binary; accept exactly the app's, flat.
    symbols = inspected / 'Symbols'
    if not symbols.exists() and not symbols.is_symlink():
        return
    entries = [] if symbols.is_symlink() or not symbols.is_dir() else list(symbols.iterdir())
    expected = {f'{uuid}.symbols' for uuid, _ in app_uuids}
    if (not entries or any(p.is_symlink() or not p.is_file() for p in entries)
            or {p.name for p in entries} != expected):
        raise ValueError('exported symbols must be exactly the app binary UUIDs')


def export(archive, output, expected):
    artifact.require_dispatch()
    artifact.validate_archive(archive, expected)
    team = os.environ.get('IOS_TEAM_ID', '')
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise ValueError('IOS_TEAM_ID must identify the approved Apple team')
    if output.exists():
        raise ValueError('export output already exists')
    try:
        options = credentials(team)
        options_path = private_root() / 'ExportOptions.plist'
        options_path.write_bytes(plistlib.dumps(options))
        run(['xcodebuild', '-exportArchive', '-archivePath', str(archive),
             '-exportPath', str(output), '-exportOptionsPlist', str(options_path)])
        ipas = list(output.glob('*.ipa'))
        if len(ipas) != 1 or ipas[0].name != 'Glimmer.ipa':
            raise ValueError('export must produce exactly Glimmer.ipa')
        inspected = private_root() / 'inspected'
        artifact.unpack(ipas[0], inspected, ('Payload', 'SwiftSupport', 'Symbols'))
        if {p.name for p in (inspected / 'Payload').iterdir()} != {'Glimmer.app'}:
            raise ValueError('export contains an unexpected application')
        verify_signed_app(inspected / 'Payload/Glimmer.app', expected, team)
        receipt = {'schema': 1, 'identity': expected, 'internal_only': True, 'team': team,
                   'trusted_tooling_sha': os.environ['TRUSTED_TOOLING_SHA'],
                   'signing_run_id': os.environ['GITHUB_RUN_ID'],
                   'signing_run_attempt': os.environ['GITHUB_RUN_ATTEMPT'],
                   'ipa_sha256': artifact.digest(ipas[0]), 'export_options': options,
                   'app_uuids': artifact.uuids(inspected / 'Payload/Glimmer.app/Glimmer')}
        if receipt['app_uuids'] != artifact.uuids(archive / artifact.APP / 'Glimmer'):
            raise ValueError('export changed app binary identity')
        verify_exported_symbols(inspected, receipt['app_uuids'])
        (output / 'receipt.json').write_text(json.dumps(receipt, sort_keys=True) + '\n')
    finally:
        cleanup()


def upload(output, expected):
    artifact.require_dispatch()
    receipt = json.loads((output / 'receipt.json').read_text())
    ipa = output / 'Glimmer.ipa'
    if (receipt.get('identity') != expected or receipt.get('internal_only') is not True
            or receipt.get('ipa_sha256') != artifact.digest(ipa)):
        raise ValueError('signed artifact identity mismatch')
    key = os.environ.get('ASC_KEY_ID', '')
    issuer = os.environ.get('ASC_ISSUER_ID', '')
    if not re.fullmatch(r'[A-Z0-9]{10}', key) or not re.fullmatch(r'[a-fA-F0-9-]{36}', issuer):
        raise ValueError('invalid App Store Connect key identifiers')
    help_result = run(['xcrun', 'altool', '--help'])
    help_text = (help_result.stdout + help_result.stderr).decode(errors='replace')
    if not all(option in help_text for option in ('--upload-package', '--api-key', '--api-issuer', '--wait')):
        raise ValueError('installed altool does not support the reviewed upload interface')
    root = private_root()
    root.mkdir(mode=0o700)
    try:
        secret_file('ASC_KEY_BASE64', root / f'AuthKey_{key}.p8')
        env = dict(os.environ, API_PRIVATE_KEYS_DIR=str(root))
        env.pop('ASC_KEY_BASE64', None)
        result = subprocess.run(['xcrun', 'altool', '--upload-package', str(ipa), '--wait',
                                 '--api-key', key, '--api-issuer', issuer, '--output-format', 'json'],
                                env=env, capture_output=True, timeout=1200)
        outcome = delivery_outcome(result.returncode, result.stdout)
        (output / 'upload.json').write_text(json.dumps({'identity': expected, **outcome}, sort_keys=True) + '\n')
        if outcome['status'] != 'upload_and_processing_command_succeeded':
            raise ValueError('Apple delivery was not confirmed; inspect upload.json and App Store Connect before retrying')
    except subprocess.TimeoutExpired:
        (output / 'upload.json').write_text(json.dumps({
            'identity': expected, 'status': 'timed_out_delivery_unknown', 'retry_safe': False}) + '\n')
        raise ValueError('Apple delivery timed out; check App Store Connect before retrying') from None
    finally:
        cleanup()


def delivery_outcome(returncode, output):
    result = {'returncode': returncode, 'status': 'delivery_unconfirmed', 'retry_safe': False}
    if len(output) > 8 * 1024**2:
        return result
    try:
        data = json.loads(output)
    except (ValueError, UnicodeError):
        return result
    if not isinstance(data, dict):
        return result
    errors = data.get('errors') or data.get('product-errors') or data.get('error')
    if returncode == 0 and not errors:
        result['status'] = 'upload_and_processing_command_succeeded'
    if isinstance(errors, list):
        result['error_codes'] = [str(error['code'])[:32] for error in errors
                                 if isinstance(error, dict) and isinstance(error.get('code'), (str, int))]
    delivery = data.get('delivery-id')
    if isinstance(delivery, str) and re.fullmatch(r'[A-Fa-f0-9-]{36}', delivery):
        result['delivery_id'] = delivery
    return result
