#!/usr/bin/env python3
"""Behavioral CLI contracts for the opt-in native Gmail package gate."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("validate-ios-gmail-oauth.py")
CLIENT = "123-fixture.apps.googleusercontent.com"
SCHEME = "com.googleusercontent.apps.123-fixture"


class NativeGmailPackageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.app = self.root / "Plainpost.app"
        self.app.mkdir()
        self.registration = self.root / "LocalOAuth.xcconfig"
        self.config = ("PLAINPOST_GOOGLE_IOS_OAUTH_CLIENT_ID = " + CLIENT + "\n"
                       "PLAINPOST_GOOGLE_IOS_OAUTH_CALLBACK_SCHEME = " + SCHEME + "\n")
        self.info = {"CFBundleIdentifier": "com.marynavdovenko.Plainpost.iOS",
                     "PlainpostGoogleIOSOAuthClientID": CLIENT,
                     "CFBundleURLTypes": [{"CFBundleURLSchemes": [SCHEME, "unrelated-callback"]}]}

    def run_gate(self, expected, reason):
        self.registration.write_text(self.config)
        (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info))
        env = {key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR", "LANG", "LC_ALL") if key in os.environ}
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        result = subprocess.run([sys.executable, str(SCRIPT), "--app", str(self.app),
                                 "--registration", str(self.registration)],
                                env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual(value["reason"], reason)
        for sensitive in (CLIENT, SCHEME, "DO_NOT_ECHO_SECRET"):
            self.assertNotIn(sensitive, result.stdout + result.stderr)
        return value

    def test_exact_native_registration_and_packaged_callback_pass(self):
        self.run_gate(0, "native_gmail_registration_matches")

    def test_empty_packaged_id_rejected(self):
        self.info["PlainpostGoogleIOSOAuthClientID"] = ""
        self.run_gate(1, "packaged_native_client_invalid")

    def test_missing_packaged_id_rejected(self):
        del self.info["PlainpostGoogleIOSOAuthClientID"]
        self.run_gate(1, "packaged_native_client_invalid")

    def test_malformed_packaged_id_rejected(self):
        self.info["PlainpostGoogleIOSOAuthClientID"] = "invalid.apps.googleusercontent.com "
        self.run_gate(1, "packaged_native_client_invalid")

    def test_unresolved_packaged_setting_rejected(self):
        self.info["PlainpostGoogleIOSOAuthClientID"] = "$(PLAINPOST_GOOGLE_IOS_OAUTH_CLIENT_ID)"
        self.run_gate(1, "packaged_native_client_invalid")

    def test_different_valid_packaged_id_rejected(self):
        self.info["PlainpostGoogleIOSOAuthClientID"] = "456-other.apps.googleusercontent.com"
        self.run_gate(1, "packaged_native_client_mismatch")

    def test_mismatched_packaged_callback_rejected(self):
        self.info["CFBundleURLTypes"] = [{"CFBundleURLSchemes": ["wrong-callback"]}]
        self.run_gate(1, "packaged_native_callback_missing")

    def test_malformed_callback_container_rejected(self):
        self.info["CFBundleURLTypes"] = "not-an-array"
        self.run_gate(1, "packaged_callback_structure_invalid")

    def test_packaged_client_secret_rejected_without_echo(self):
        self.info["PlainpostGoogleOAuthClientSecret"] = "DO_NOT_ECHO_SECRET"
        self.run_gate(1, "packaged_client_secret_forbidden")

    def test_nested_empty_client_secret_key_rejected(self):
        self.info["extra"] = {"client_secret": ""}
        self.run_gate(1, "packaged_client_secret_forbidden")

    def test_registration_unrelated_assignment_rejected(self):
        self.config += "CLIENT_SECRET = DO_NOT_ECHO_SECRET\n"
        self.run_gate(1, "registration_not_two_public_assignments")

    def test_registration_duplicate_assignment_rejected(self):
        self.config += "PLAINPOST_GOOGLE_IOS_OAUTH_CLIENT_ID = " + CLIENT + "\n"
        self.run_gate(1, "registration_not_two_public_assignments")

    def test_registration_empty_id_rejected(self):
        self.config = self.config.replace(CLIENT, "")
        self.run_gate(1, "registration_native_client_invalid")

    def test_registration_callback_mismatch_rejected(self):
        self.config = self.config.replace(SCHEME, "wrong-callback")
        self.run_gate(1, "registration_native_callback_mismatch")

    def test_wrong_app_identifier_rejected(self):
        self.info["CFBundleIdentifier"] = "com.example.Other"
        self.run_gate(1, "packaged_bundle_identifier_mismatch")

    def test_malformed_plist_is_clean_failure(self):
        self.assert_unreadable_plist(b"DO_NOT_ECHO_SECRET not plist")

    def test_truncated_xml_plist_is_clean_failure(self):
        self.assert_unreadable_plist(b'<?xml version="1.0"?><plist><dict>')

    def assert_unreadable_plist(self, contents):
        self.registration.write_text(self.config)
        (self.app / "Info.plist").write_bytes(contents)
        env = {key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR", "LANG", "LC_ALL") if key in os.environ}
        result = subprocess.run([sys.executable, str(SCRIPT), "--app", str(self.app), "--registration", str(self.registration)], env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)["reason"], "package_input_unreadable")
        self.assertNotIn("DO_NOT_ECHO_SECRET", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
