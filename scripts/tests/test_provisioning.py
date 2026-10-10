# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Provisioning preflight regressions using synthetic plists and mocked CMS decoding."""

from contextlib import redirect_stderr, redirect_stdout
from copy import deepcopy
from datetime import datetime, timezone
import io
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from provisioning import (
    APP_IDENTIFIER, AUDIO_ENTITLEMENTS, HARDENED_PROCESS, TEAM_IDENTIFIER, TOPOLOGY_ENTITLEMENT,
    VERSION_ENTITLEMENT_TYPES, decode_profile, main, prepare_app, read_plist, same_entitlement_value, validate_profile,
)

BUNDLE_ID = "io.example.Glimmer"
TEAM = "TEAM123456"
PREFIX = "PREFIX1234"
NOW = datetime(2030, 1, 1, tzinfo=timezone.utc)


def requested_entitlements():
    return {
        "com.apple.security.app-sandbox": False,
        "com.apple.security.cs.allow-jit": False,
        "com.apple.security.cs.disable-library-validation": False,
        **{key: True for key in AUDIO_ENTITLEMENTS},
    }


def approved_profile():
    return {
        "Platform": ["OSX"],
        "ProvisionsAllDevices": True,
        "ExpirationDate": datetime(2100, 1, 1),
        "ApplicationIdentifierPrefix": [PREFIX],
        "TeamIdentifier": [TEAM],
        "Entitlements": {
            APP_IDENTIFIER: f"{PREFIX}.{BUNDLE_ID}",
            TEAM_IDENTIFIER: TEAM,
            **{key: True for key in AUDIO_ENTITLEMENTS},
        },
    }


class ProvisioningValidationTests(unittest.TestCase):
    def validate(self, profile, requested=None):
        return validate_profile(profile, BUNDLE_ID, requested if requested is not None else requested_entitlements(), now=NOW)

    def test_resolves_app_prefix_separately_from_team_and_preserves_hardening(self):
        profile = approved_profile()
        profile["Entitlements"]["com.apple.security.cs.allow-jit"] = True
        profile["Entitlements"]["unrequested.capability"] = True
        requested = requested_entitlements()
        original = deepcopy(requested)
        resolved = self.validate(profile, requested)
        self.assertEqual(requested, original)
        self.assertEqual(resolved[APP_IDENTIFIER], f"{PREFIX}.{BUNDLE_ID}")
        self.assertEqual(resolved[TEAM_IDENTIFIER], TEAM)
        self.assertNotIn("unrequested.capability", resolved)
        for key, value in original.items():
            self.assertIs(resolved[key], value)

    def test_rejects_wrong_or_ambiguous_platform(self):
        for platform in (None, "OSX", ["iOS"], ["OSX", "iOS"]):
            with self.subTest(platform=platform):
                profile = approved_profile()
                profile["Platform"] = platform
                with self.assertRaisesRegex(ValueError, "macOS"):
                    self.validate(profile)

    def test_requires_true_all_devices_without_device_list(self):
        for value in (None, False, 1, "true"):
            with self.subTest(value=value):
                profile = approved_profile()
                profile["ProvisionsAllDevices"] = value
                with self.assertRaisesRegex(ValueError, "all-device"):
                    self.validate(profile)
        profile = approved_profile()
        profile["ProvisionedDevices"] = ["synthetic-device"]
        with self.assertRaisesRegex(ValueError, "all-device"):
            self.validate(profile)

    def test_requires_valid_future_expiration(self):
        for expiration in (None, "2100-01-01", datetime(2029, 1, 1), datetime(2030, 1, 1), NOW):
            with self.subTest(expiration=expiration):
                profile = approved_profile()
                profile["ExpirationDate"] = expiration
                with self.assertRaisesRegex(ValueError, "expiration|expired"):
                    self.validate(profile)

    def test_rejects_debugging_grants_and_requested_debugging(self):
        for key in ("get-task-allow", "com.apple.security.get-task-allow"):
            for value in (True, 1, "false"):
                with self.subTest(key=key, value=value):
                    profile = approved_profile()
                    profile["Entitlements"][key] = value
                    with self.assertRaisesRegex(ValueError, "Debugging"):
                        self.validate(profile)
                    requested = requested_entitlements()
                    requested[key] = value
                    with self.assertRaisesRegex(ValueError, "Debugging"):
                        self.validate(approved_profile(), requested)
            profile = approved_profile()
            profile["Entitlements"][key] = False
            self.validate(profile)

    def test_requires_exact_app_id_with_authorized_prefix(self):
        for identifier in (None, f"{PREFIX}.*", f"{PREFIX}.io.example.Other", f"{TEAM}.{BUNDLE_ID}"):
            with self.subTest(identifier=identifier):
                profile = approved_profile()
                profile["Entitlements"][APP_IDENTIFIER] = identifier
                with self.assertRaisesRegex(ValueError, "App ID"):
                    self.validate(profile)
        for prefixes in (None, [], "PREFIX1234", ["*"]):
            with self.subTest(prefixes=prefixes):
                profile = approved_profile()
                profile["ApplicationIdentifierPrefix"] = prefixes
                with self.assertRaisesRegex(ValueError, "App ID prefix"):
                    self.validate(profile)

    def test_requires_consistent_team_identifiers(self):
        for teams in (None, [], [TEAM, "OTHER12345"], "TEAM123456", [""]):
            with self.subTest(teams=teams):
                profile = approved_profile()
                profile["TeamIdentifier"] = teams
                with self.assertRaisesRegex(ValueError, "TeamIdentifier"):
                    self.validate(profile)
        profile = approved_profile()
        profile["Entitlements"][TEAM_IDENTIFIER] = "OTHER12345"
        with self.assertRaisesRegex(ValueError, "team identifiers disagree"):
            self.validate(profile)

    def test_rejects_conflicting_requested_identifiers(self):
        for key in (APP_IDENTIFIER, TEAM_IDENTIFIER):
            with self.subTest(key=key):
                requested = requested_entitlements()
                requested[key] = "wrong"
                with self.assertRaisesRegex(ValueError, "conflicts"):
                    self.validate(approved_profile(), requested)

    def test_requested_audio_capabilities_require_matching_boolean_grants(self):
        for key in AUDIO_ENTITLEMENTS:
            for value in (None, False, 1, "true"):
                with self.subTest(key=key, value=value):
                    profile = approved_profile()
                    profile["Entitlements"][key] = value
                    with self.assertRaisesRegex(ValueError, "doesn't grant"):
                        self.validate(profile)
                    requested = requested_entitlements()
                    requested[key] = value
                    with self.assertRaisesRegex(ValueError, "must have type|doesn't grant"):
                        self.validate(approved_profile(), requested)

    def test_unrequested_capabilities_are_not_required_or_copied(self):
        resolved = self.validate(approved_profile(), {"com.apple.security.cs.allow-jit": False})
        self.assertNotIn(AUDIO_ENTITLEMENTS[0], resolved)
        self.assertNotIn(AUDIO_ENTITLEMENTS[1], resolved)
        self.assertNotIn(TOPOLOGY_ENTITLEMENT, resolved)
        self.assertIs(resolved["com.apple.security.cs.allow-jit"], False)

    def test_topology_helper_requires_its_own_grant_without_audio(self):
        helper_id = BUNDLE_ID + ".Helper"
        profile = approved_profile()
        grants = profile["Entitlements"]
        for key in AUDIO_ENTITLEMENTS:
            del grants[key]
        grants[APP_IDENTIFIER] = f"{PREFIX}.{helper_id}"
        grants[TOPOLOGY_ENTITLEMENT] = True
        requested = {TOPOLOGY_ENTITLEMENT: True, "com.apple.security.cs.allow-jit": False}
        resolved = validate_profile(profile, helper_id, requested, now=NOW)
        self.assertEqual(resolved[APP_IDENTIFIER], f"{PREFIX}.{helper_id}")
        self.assertIs(resolved[TOPOLOGY_ENTITLEMENT], True)
        self.assertNotIn(AUDIO_ENTITLEMENTS[0], resolved)
        del grants[TOPOLOGY_ENTITLEMENT]
        with self.assertRaisesRegex(ValueError, "doesn't grant.*topology-observation"):
            validate_profile(profile, helper_id, requested, now=NOW)

    def test_enhanced_security_bool_grants_are_strict(self):
        for key in (HARDENED_PROCESS, HARDENED_PROCESS + ".hardened-heap", HARDENED_PROCESS + ".dyld-ro"):
            profile = approved_profile()
            requested = requested_entitlements() | {key: True}
            profile["Entitlements"][key] = True
            self.assertIs(self.validate(profile, requested)[key], True)
            for grant in (None, False, 1, "true", "*"):
                with self.subTest(key=key, grant=grant):
                    profile["Entitlements"][key] = grant
                    with self.assertRaisesRegex(ValueError, "doesn't grant"):
                        self.validate(profile, requested)

    def test_enhanced_security_versions_allow_only_their_narrow_profile_wildcard(self):
        profile = approved_profile()
        requested = requested_entitlements()
        for key, value_type in VERSION_ENTITLEMENT_TYPES.items():
            value = 2 if "platform-restrictions" in key else 1
            requested[key] = str(value) if value_type is str else value
            profile["Entitlements"][key] = "*"
        resolved = self.validate(profile, requested)
        for key, value_type in VERSION_ENTITLEMENT_TYPES.items():
            self.assertIs(type(resolved[key]), value_type)
            self.assertEqual(resolved[key], requested[key])
            profile["Entitlements"][key] = requested[key]
        self.validate(profile, requested)
        for key, value_type in VERSION_ENTITLEMENT_TYPES.items():
            for wrong in (True, "invalid", -1, 1 if value_type is str else "1"):
                with self.subTest(key=key, wrong=wrong):
                    invalid = requested | {key: wrong}
                    with self.assertRaises(ValueError):
                        self.validate(profile, invalid)

    def test_unknown_restricted_claims_need_exact_typed_grants(self):
        profile = approved_profile()
        key = "com.apple.developer.synthetic-capability"
        requested = requested_entitlements() | {key: [True, "scope"]}
        for grant in (None, "*", [1, "scope"], [True, "other"]):
            with self.subTest(grant=grant):
                profile["Entitlements"][key] = grant
                with self.assertRaisesRegex(ValueError, "doesn't grant"):
                    self.validate(profile, requested)
        profile["Entitlements"][key] = [True, "scope"]
        self.assertEqual(self.validate(profile, requested)[key], [True, "scope"])

    def test_topology_claim_requires_boolean_request_and_matching_grant(self):
        for request, grant in ((True, 1), (True, "true"), (1, True), ("true", True)):
            with self.subTest(request=request, grant=grant):
                profile = approved_profile()
                profile["Entitlements"][TOPOLOGY_ENTITLEMENT] = grant
                requested = {TOPOLOGY_ENTITLEMENT: request}
                with self.assertRaises(ValueError):
                    self.validate(profile, requested)


    def test_profile_without_entitlement_grants_is_rejected(self):
        for grants in (None, ["list"]):
            profile = approved_profile()
            profile["Entitlements"] = grants
            with self.subTest(grants=grants), self.assertRaisesRegex(ValueError, "no entitlement grants"):
                self.validate(profile)

    def test_entitlement_values_match_by_type_shape_and_content(self):
        self.assertTrue(same_entitlement_value({"a": [1, "x"]}, {"a": [1, "x"]}))
        for requested, granted in ((1, True), ([1], [1, 2]), ([1, 2], [1, 3]), ({"a": 1}, {"a": 1, "b": 2}),
                                   ({"a": 1}, {"a": 2}), ("x", ["x"])):
            with self.subTest(requested=requested, granted=granted):
                self.assertFalse(same_entitlement_value(requested, granted))


class ProvisioningFileTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.app = root / "Synthetic.app"
        contents = self.app / "Contents"
        contents.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": BUNDLE_ID}))
        self.profile = root / "explicit.provisionprofile"
        self.profile.write_bytes(b"synthetic signed profile, not a credential")
        self.entitlements = root / "source.entitlements"
        self.entitlements.write_bytes(plistlib.dumps(requested_entitlements()))
        self.output = root / "build" / "resolved.entitlements"
        self.embedded = contents / "embedded.provisionprofile"

    def decode_result(self, profile=None):
        return subprocess.CompletedProcess([], 0, stdout=plistlib.dumps(profile or approved_profile()), stderr=b"")

    def test_embeds_exact_input_and_writes_resolved_entitlements_after_validation(self):
        original = self.entitlements.read_bytes()
        with patch("provisioning.subprocess.run", return_value=self.decode_result()) as run:
            prepare_app(self.profile, self.app, self.entitlements, self.output)
        self.assertEqual(self.embedded.read_bytes(), self.profile.read_bytes())
        self.assertEqual(self.entitlements.read_bytes(), original)
        resolved = plistlib.loads(self.output.read_bytes())
        self.assertEqual(resolved[APP_IDENTIFIER], f"{PREFIX}.{BUNDLE_ID}")
        self.assertIs(resolved["com.apple.security.cs.allow-jit"], False)
        run.assert_called_once_with(
            ["/usr/bin/security", "cms", "-D", "-i", str(self.profile)],
            check=True, capture_output=True, timeout=15,
        )

    def test_invalid_profile_leaves_existing_bundle_and_output_untouched(self):
        self.output.parent.mkdir()
        self.output.write_bytes(b"previous resolved entitlements")
        self.embedded.write_bytes(b"previous embedded profile")
        profile = approved_profile()
        profile["Entitlements"][AUDIO_ENTITLEMENTS[1]] = False
        with patch("provisioning.subprocess.run", return_value=self.decode_result(profile)):
            with self.assertRaises(ValueError):
                prepare_app(self.profile, self.app, self.entitlements, self.output)
        self.assertEqual(self.output.read_bytes(), b"previous resolved entitlements")
        self.assertEqual(self.embedded.read_bytes(), b"previous embedded profile")

    def test_prepares_topology_helper_bundle_without_adding_app_audio_capabilities(self):
        helper_id = BUNDLE_ID + ".Helper"
        info_path = self.app / "Contents/Info.plist"
        info_path.write_bytes(plistlib.dumps({"CFBundleIdentifier": helper_id}))
        requested = {TOPOLOGY_ENTITLEMENT: True, "com.apple.security.cs.allow-jit": False}
        self.entitlements.write_bytes(plistlib.dumps(requested))
        profile = approved_profile()
        profile["Entitlements"] = {
            APP_IDENTIFIER: f"{PREFIX}.{helper_id}", TEAM_IDENTIFIER: TEAM, TOPOLOGY_ENTITLEMENT: True,
        }
        with patch("provisioning.subprocess.run", return_value=self.decode_result(profile)):
            prepare_app(self.profile, self.app, self.entitlements, self.output)
        resolved = plistlib.loads(self.output.read_bytes())
        self.assertEqual(resolved, requested | {APP_IDENTIFIER: f"{PREFIX}.{helper_id}", TEAM_IDENTIFIER: TEAM})
        self.assertEqual(self.embedded.read_bytes(), self.profile.read_bytes())

    def test_missing_explicit_profile_does_not_search_or_decode(self):
        self.profile.unlink()
        with patch("provisioning.subprocess.run") as run, self.assertRaisesRegex(ValueError, "--profile"):
            prepare_app(self.profile, self.app, self.entitlements, self.output)
        run.assert_not_called()
        self.assertFalse(self.embedded.exists())
        self.assertFalse(self.output.exists())

    def test_profile_changed_during_decode_is_not_embedded(self):
        def changed(*args, **kwargs):
            self.profile.write_bytes(b"replacement profile")
            return self.decode_result()
        with patch("provisioning.subprocess.run", side_effect=changed), self.assertRaisesRegex(ValueError, "changed"):
            prepare_app(self.profile, self.app, self.entitlements, self.output)
        self.assertFalse(self.embedded.exists())
        self.assertFalse(self.output.exists())

    def test_output_cannot_overwrite_any_input_or_embedded_profile(self):
        for output in (self.profile, self.entitlements, self.app / "Contents/Info.plist", self.embedded):
            with self.subTest(output=output), patch("provisioning.subprocess.run") as run:
                with self.assertRaisesRegex(ValueError, "separate"):
                    prepare_app(self.profile, self.app, self.entitlements, output)
                run.assert_not_called()

    def test_malformed_cms_payload_is_rejected(self):
        for data in (b"not a plist", plistlib.dumps(["not a dictionary"])):
            result = subprocess.CompletedProcess([], 0, stdout=data, stderr=b"")
            with self.subTest(data=data), patch("provisioning.subprocess.run", return_value=result):
                with self.assertRaises(ValueError):
                    decode_profile(self.profile)

    def test_cli_decode_failure_never_prints_captured_profile_contents(self):
        secret = b"DO_NOT_PRINT_PROFILE_CONTENTS"
        failures = (
            subprocess.CalledProcessError(1, "security", output=secret, stderr=secret),
            subprocess.TimeoutExpired("security", 15, output=secret, stderr=secret),
        )
        arguments = ["provisioning.py", "--profile", str(self.profile), "--app", str(self.app),
                     "--entitlements", str(self.entitlements), "--output-entitlements", str(self.output)]
        for failure in failures:
            stdout, stderr = io.StringIO(), io.StringIO()
            with self.subTest(failure=failure), patch("sys.argv", arguments):
                with patch("provisioning.subprocess.run", side_effect=failure):
                    with redirect_stdout(stdout), redirect_stderr(stderr), self.assertRaises(SystemExit) as exit_status:
                        main()
            self.assertEqual(exit_status.exception.code, 1)
            self.assertIn("Apple-issued macOS Developer ID profile", stderr.getvalue())
            self.assertNotIn(secret.decode(), stdout.getvalue() + stderr.getvalue())
            self.assertFalse(self.embedded.exists())
            self.assertFalse(self.output.exists())

    def test_unreadable_or_non_dictionary_plists_are_rejected(self):
        bad = self.entitlements.parent / "bad.plist"
        bad.write_bytes(b"garbage")
        with self.assertRaisesRegex(ValueError, "Couldn't read the thing"):
            read_plist(bad, "the thing")
        with self.assertRaisesRegex(ValueError, "Couldn't read"):
            read_plist(bad.parent / "absent.plist", "the thing")
        bad.write_bytes(plistlib.dumps([1]))
        with self.assertRaisesRegex(ValueError, "must contain a property dictionary"):
            read_plist(bad, "the thing")

    def test_bundle_identifier_must_be_explicit_before_the_profile_is_decoded(self):
        info = self.app / "Contents/Info.plist"
        for bundle_id in (None, "", "io.example.*", "io.example. Glimmer", 7):
            info.write_bytes(plistlib.dumps({} if bundle_id is None else {"CFBundleIdentifier": bundle_id}))
            with self.subTest(bundle_id=bundle_id), patch("provisioning.subprocess.run") as run:
                with self.assertRaisesRegex(ValueError, "no valid bundle identifier"):
                    prepare_app(self.profile, self.app, self.entitlements, self.output)
                run.assert_not_called()

    def test_cli_io_failure_hides_paths_and_success_names_nothing_secret(self):
        arguments = ["provisioning.py", "--profile", str(self.profile), "--app", str(self.app),
                     "--entitlements", str(self.entitlements), "--output-entitlements", str(self.output)]
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch("sys.argv", arguments), patch("provisioning.prepare_app", side_effect=PermissionError(str(self.profile))):
            with redirect_stdout(stdout), redirect_stderr(stderr), self.assertRaises(SystemExit) as status:
                main()
        self.assertEqual(status.exception.code, 1)
        self.assertEqual(stderr.getvalue(), "ERR: Couldn't prepare provisioning files. Check the explicit paths and permissions.\n")
        stdout = io.StringIO()
        with patch("sys.argv", arguments), patch("provisioning.subprocess.run", return_value=self.decode_result()):
            with redirect_stdout(stdout):
                main()
        self.assertEqual(stdout.getvalue(), "Provisioning profile validated and embedded.\n")
        self.assertTrue(self.embedded.exists())


if __name__ == "__main__":
    unittest.main()
