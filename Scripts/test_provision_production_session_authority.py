import datetime
import hashlib
import importlib.util
import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock
from pathlib import Path
from subprocess import CompletedProcess


SCRIPT = Path(__file__).with_name("provision-production-session-authority.py")
SPEC = importlib.util.spec_from_file_location("provision_production_session_authority", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def metadata(public_byte=2):
    public = b"\x04" + bytes([public_byte]) * 64
    return {
        "version": 1,
        "rootKeyID": MODULE.SESSION_ROOT_KEY_ID,
        "applicationTag": MODULE.SESSION_ROOT_TAG,
        "label": MODULE.SESSION_ROOT_LABEL,
        "accessGroup": MODULE.ACCESS_GROUP,
        "keychainContext": "data-protection-keychain",
        "keyType": "P-256 Secure Enclave signing key",
        "publicKey": MODULE.base64url(public),
        "publicKeySHA256": MODULE.sha256(public),
    }


def entitlements_plist():
    return plistlib.dumps({
        "com.apple.application-identifier": "9XN7WN8JN2.com.marynavdovenko.Plainpost",
        "com.apple.developer.team-identifier": "9XN7WN8JN2",
        "keychain-access-groups": ["9XN7WN8JN2.com.marynavdovenko.Plainpost.RootAuthority"],
    })


def manifest_document(root_key_id, signature):
    return {
        "kind": "account.session-key-manifest-response.v1",
        "current": {
            "kind": "account.session-key-manifest.v1",
            "rootKeyID": root_key_id,
            "manifestVersion": "1",
            "notBefore": "2026-09-06T00:00:00Z",
            "expiresAt": "2027-09-06T00:00:00Z",
            "keys": [
                {
                    "keyID": "plainpost-access-prod-2026-09",
                    "purpose": "access",
                    "publicKey": "BAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                    "notBefore": "2026-09-06T00:00:00Z",
                    "expiresAt": "2027-09-06T00:00:00Z",
                    "status": "active",
                },
                {
                    "keyID": "plainpost-offline-lease-prod-2026-09",
                    "purpose": "offlineLease",
                    "publicKey": "BAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE",
                    "notBefore": "2026-09-06T00:00:00Z",
                    "expiresAt": "2027-09-06T00:00:00Z",
                    "status": "active",
                },
            ],
            "rootSignature": signature,
        },
    }


def provenance(helper_sha256):
    return {
        "kind": "plainpost-root-authority-build-receipt.v1",
        "packagingCommit": "1" * 40,
        "sourceCommit": "1" * 40,
        "profileCertificateSHA1": MODULE.EXPECTED_IDENTITY_SHA1,
        "signingIdentitySHA1": MODULE.EXPECTED_IDENTITY_SHA1,
        "effectiveEntitlementsSHA256": MODULE.sha256(entitlements_plist()),
        "unsignedExecutableSHA256": "2" * 64,
        "executableSHA256": helper_sha256,
        "designatedRequirement": 'identifier "com.marynavdovenko.Plainpost" and anchor apple generic',
        "profileUUID": MODULE.EXPECTED_PROFILE_UUID,
        "profileName": MODULE.EXPECTED_PROFILE_NAME,
        "profileExpiresAt": MODULE.EXPECTED_PROFILE_EXPIRES_AT,
        "signingKeychain": "/Users/test/Library/Keychains/login.keychain-db",
        "displayName": "Plainpost Root Authority",
        "bundleIdentifier": "com.marynavdovenko.Plainpost",
        "accessGroup": MODULE.ACCESS_GROUP,
        "accountRootKeyID": MODULE.ACCOUNT_ROOT_KEY_ID,
        "accountRootApplicationTag": MODULE.ACCOUNT_ROOT_TAG,
        "sessionRootKeyID": MODULE.SESSION_ROOT_KEY_ID,
        "sessionRootApplicationTag": MODULE.SESSION_ROOT_TAG,
    }


class FakeCommands:
    def __init__(self, helper_results, verifier_result=None, on_resign=None):
        self.helper_results = list(helper_results)
        self.verifier_result = verifier_result
        self.on_resign = on_resign
        self.calls = []

    def __call__(self, command):
        self.calls.append(command)
        if command[0].endswith("plainpost-root-authority"):
            if len(command) > 1 and command[1] == "resign-session-manifest" and self.on_resign:
                self.on_resign()
            return self.helper_results.pop(0)
        if self.verifier_result is None:
            raise AssertionError(f"unexpected command: {command}")
        return self.verifier_result


class SessionProvisioningRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.records = self.root / "records"
        self.session_public = self.root / "session-public"
        self.account_public = self.root / "account-public"
        self.private = self.root / "private"
        for directory in (self.records, self.session_public, self.account_public, self.private):
            directory.mkdir(mode=0o700)
        self.account_public_key = b"\x04" + b"\x01" * 64
        self.account_root_sha256 = MODULE.sha256(self.account_public_key)
        for name in MODULE.CURRENT_PUBLIC_ARTIFACTS:
            path = self.account_public / name
            if name.endswith("root.pub"):
                path.write_text(MODULE.base64url(self.account_public_key) + "\n", encoding="utf-8")
            elif name == "session-manifest.json":
                path.write_text(json.dumps(manifest_document(MODULE.ACCOUNT_ROOT_KEY_ID, "old-signature")) + "\n", encoding="utf-8")
            else:
                path.write_text("{}\n", encoding="utf-8")
            path.chmod(0o644)
        for name in MODULE.PRIVATE_ARTIFACTS:
            path = self.private / name
            path.write_text("private", encoding="utf-8")
            path.chmod(0o600)
        self.helper = self.root / "plainpost-root-authority"
        self.helper.write_bytes(b"reviewed session helper")
        self.helper.chmod(0o755)
        self.verifier = self.root / "verify-production-key-authority.sh"
        self.verifier.write_text("#!/bin/sh\n", encoding="utf-8")
        self.verifier.chmod(0o755)
        self.provenance = provenance(MODULE.sha256(b"reviewed session helper"))
        self.config = MODULE.Config(
            helper=self.helper,
            provenance=self.provenance,
            records=self.records,
            session_public=self.session_public,
            account_public=self.account_public,
            private=self.private,
            verifier=self.verifier,
            account_root_sha256=self.account_root_sha256,
            verify_install=lambda _provenance: None,
        )

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def completed(code, payload=None, error=""):
        output = "" if payload is None else json.dumps(payload)
        return CompletedProcess([], code, output, error)

    def self_test(self, root):
        return {"root": root, "challengeVerified": True}

    def session_artifact_bytes(self, root):
        return {
            "session-offline-root.pub": (root["publicKey"] + "\n").encode("utf-8"),
            "session-manifest.json": (json.dumps(manifest_document(MODULE.SESSION_ROOT_KEY_ID, "new-signature")) + "\n").encode("utf-8"),
        }

    def write_session_artifacts(self, root=None):
        root = root or metadata()
        for name, document in self.session_artifact_bytes(root).items():
            path = self.session_public / name
            path.write_bytes(document)
            path.chmod(0o644)

    def resign_receipt(self, root):
        return {
            "kind": "plainpost-root-authority-session-resigning.v1",
            "root": root,
            "publicArtifacts": [
                {"name": name, "sha256": MODULE.sha256(self.session_public / name)}
                for name in sorted(MODULE.SESSION_PUBLIC_ARTIFACTS)
            ],
        }

    def verifier_result(self, root):
        return CompletedProcess([], 0, (
            f"ACCOUNT_ROOT_SHA256 {self.account_root_sha256}\n"
            f"SESSION_ROOT_SHA256 {root['publicKeySHA256']}\n"
            "PASS production key authority packet\n"
        ), "")

    def test_create_failure_recovers_persisted_session_root_without_retry(self):
        root = metadata()

        def finish_resign():
            self.write_session_artifacts(root)

        fake = FakeCommands([
            self.completed(1, error="production root was not found"),
            self.completed(1, error="Keychain operation failed (OSStatus -25308)"),
            self.completed(0, root),
            self.completed(0, self.self_test(root)),
            self.completed(0, self.self_test(root)),
            self.completed(0, None),
        ], self.verifier_result(root), finish_resign)
        fake.helper_results[-1] = self.completed(0, {
            "kind": "plainpost-root-authority-session-resigning.v1",
            "root": root,
            "publicArtifacts": [
                {"name": name, "sha256": MODULE.sha256(self.session_artifact_bytes(root)[name])}
                for name in sorted(MODULE.SESSION_PUBLIC_ARTIFACTS)
            ],
        })

        result = MODULE.Provisioner(self.config, fake).run()

        self.assertEqual(result, (self.account_root_sha256, root["publicKeySHA256"]))
        helper_commands = [call[1] for call in fake.calls if call[0] == str(self.helper)]
        self.assertEqual(helper_commands.count("create-session"), 1)
        self.assertEqual(helper_commands.count("inspect-session"), 2)
        self.assertEqual(helper_commands.count("self-test-session"), 2)
        self.assertEqual(helper_commands.count("resign-session-manifest"), 1)
        self.assertEqual(MODULE.read_json(self.records / "SESSION_KEY_LOCATION.json"), root)

    def test_live_persisted_root_is_recorded_and_create_is_skipped(self):
        root = metadata()

        def finish_resign():
            self.write_session_artifacts(root)

        fake = FakeCommands([
            self.completed(0, root),
            self.completed(0, self.self_test(root)),
            self.completed(0, self.self_test(root)),
            self.completed(0, {
                "kind": "plainpost-root-authority-session-resigning.v1",
                "root": root,
                "publicArtifacts": [
                    {"name": name, "sha256": MODULE.sha256(self.session_artifact_bytes(root)[name])}
                    for name in sorted(MODULE.SESSION_PUBLIC_ARTIFACTS)
                ],
            }),
        ], self.verifier_result(root), finish_resign)

        MODULE.Provisioner(self.config, fake).run()

        helper_commands = [call[1] for call in fake.calls if call[0] == str(self.helper)]
        self.assertNotIn("create-session", helper_commands)
        self.assertEqual(MODULE.read_json(self.records / "SESSION_KEY_LOCATION.json"), root)

    def test_recorded_create_failure_blocks_automatic_retry(self):
        MODULE.write_json_exclusive(self.records / "SESSION_CREATE_FAILURE.json", {
            "kind": "plainpost-root-authority-operation-failure.v1",
            "exitCode": 1,
            "postOperationState": "absent",
            "error": "User interaction is not allowed",
        })
        fake = FakeCommands([self.completed(1, error="production root was not found")])

        with self.assertRaisesRegex(MODULE.ProvisioningError, "previous session root creation failure"):
            MODULE.Provisioner(self.config, fake).run()

        self.assertNotIn("create-session", [call[1] for call in fake.calls])

    def test_interrupted_create_leaves_attempt_record_that_blocks_retry(self):
        first_calls = []

        def interrupted(command):
            first_calls.append(command)
            if command[1] == "inspect-session":
                return self.completed(1, error="production root was not found")
            raise RuntimeError("interrupted during create-session")

        with self.assertRaisesRegex(RuntimeError, "interrupted"):
            MODULE.Provisioner(self.config, interrupted).run()

        attempt = MODULE.read_json(self.records / "SESSION_CREATE_ATTEMPT.json")
        self.assertEqual(attempt, {
            "kind": "plainpost-root-authority-create-attempt.v1",
            "rootKeyID": MODULE.SESSION_ROOT_KEY_ID,
            "attempted": True,
        })
        second = FakeCommands([self.completed(1, error="production root was not found")])
        with self.assertRaisesRegex(MODULE.ProvisioningError, "previous session root creation attempt"):
            MODULE.Provisioner(self.config, second).run()
        self.assertNotIn("create-session", [call[1] for call in second.calls])

    def test_malformed_success_cannot_be_followed_by_second_create_attempt(self):
        first = FakeCommands([
            self.completed(1, error="production root was not found"),
            self.completed(0, {"unexpected": "metadata"}),
            self.completed(1, error="production root was not found"),
        ])
        with self.assertRaises(MODULE.ProvisioningError):
            MODULE.Provisioner(self.config, first).run()

        second = FakeCommands([self.completed(1, error="production root was not found")])
        with self.assertRaisesRegex(MODULE.ProvisioningError, "previous session root creation attempt"):
            MODULE.Provisioner(self.config, second).run()
        self.assertNotIn("create-session", [call[1] for call in second.calls])

    def test_partial_staging_output_is_rejected_before_helper_invocation(self):
        path = self.session_public / "session-offline-root.pub"
        path.write_text("collision", encoding="utf-8")
        path.chmod(0o644)
        fake = FakeCommands([])

        with self.assertRaisesRegex(MODULE.ProvisioningError, "partial or colliding session public output"):
            MODULE.Provisioner(self.config, fake).run()

        self.assertEqual(fake.calls, [])

    def test_account_root_baseline_is_verified_before_helper_invocation(self):
        account_root = self.account_public / "account-offline-root.pub"
        account_root.write_text(MODULE.base64url(b"\x04" + b"\x03" * 64) + "\n", encoding="utf-8")
        fake = FakeCommands([])

        with self.assertRaisesRegex(MODULE.ProvisioningError, "account root fingerprint mismatch"):
            MODULE.Provisioner(self.config, fake).run()

        self.assertEqual(fake.calls, [])

    def test_complete_staging_output_is_reverified_without_resigning(self):
        root = metadata()
        MODULE.write_json_exclusive(self.records / "SESSION_KEY_LOCATION.json", root)
        for number in (1, 2):
            MODULE.write_json_exclusive(self.records / f"SESSION_SELF_TEST_RECEIPT_{number}.json", self.self_test(root))
        self.write_session_artifacts(root)
        MODULE.write_json_exclusive(self.records / "SESSION_RESIGNING_RECEIPT.json", self.resign_receipt(root))
        fake = FakeCommands([self.completed(0, root)], self.verifier_result(root))

        MODULE.Provisioner(self.config, fake).run()

        self.assertNotIn("resign-session-manifest", [call[1] for call in fake.calls])

    def test_complete_output_with_changed_leaf_payload_is_rejected(self):
        root = metadata()
        MODULE.write_json_exclusive(self.records / "SESSION_KEY_LOCATION.json", root)
        for number in (1, 2):
            MODULE.write_json_exclusive(self.records / f"SESSION_SELF_TEST_RECEIPT_{number}.json", self.self_test(root))
        self.write_session_artifacts(root)
        staged_manifest = self.session_public / "session-manifest.json"
        changed = json.loads(staged_manifest.read_text(encoding="utf-8"))
        changed["current"]["keys"][0]["publicKey"] = "changed-public-key"
        staged_manifest.write_text(json.dumps(changed) + "\n", encoding="utf-8")
        staged_manifest.chmod(0o644)
        MODULE.write_json_exclusive(self.records / "SESSION_RESIGNING_RECEIPT.json", self.resign_receipt(root))
        fake = FakeCommands([self.completed(0, root)])

        with self.assertRaisesRegex(MODULE.ProvisioningError, "session manifest payload changed"):
            MODULE.Provisioner(self.config, fake).run()

    def test_session_root_fingerprint_must_differ_from_account_root(self):
        root = metadata(public_byte=1)
        fake = FakeCommands([self.completed(0, root)])

        with self.assertRaisesRegex(MODULE.ProvisioningError, "session root must differ"):
            MODULE.Provisioner(self.config, fake).run()


class InstalledHelperVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.app = self.root / "Plainpost Root Authority.app"
        self.helper = self.app / "Contents/MacOS/plainpost-root-authority"
        self.helper.parent.mkdir(parents=True)
        self.helper.write_bytes(b"reviewed session helper")
        self.helper.chmod(0o755)
        self.profile = self.app / "Contents/embedded.provisionprofile"
        self.profile.write_bytes(b"profile")
        self.profile.chmod(0o600)
        self.receipt = provenance(MODULE.sha256(self.helper))

    def tearDown(self):
        self.temporary.cleanup()

    def test_live_helper_matches_reviewed_hash_requirement_profile_and_entitlements(self):
        entitlements = entitlements_plist()
        profile = plistlib.dumps({
            "UUID": MODULE.EXPECTED_PROFILE_UUID,
            "Name": MODULE.EXPECTED_PROFILE_NAME,
            "ExpirationDate": datetime.datetime(2027, 8, 9, 17, 31, 23),
            "TeamIdentifier": [MODULE.TEAM_ID],
            "Entitlements": {
                "com.apple.application-identifier": MODULE.APP_ID,
                "com.apple.developer.team-identifier": MODULE.TEAM_ID,
                "keychain-access-groups": [f"{MODULE.TEAM_ID}.*"],
            },
            "DeveloperCertificates": [b"certificate"],
        })
        identity = hashlib.sha1(b"certificate").hexdigest().upper()
        reviewed = provenance(MODULE.sha256(self.helper))
        reviewed["profileCertificateSHA1"] = identity
        reviewed["signingIdentitySHA1"] = identity

        def command(arguments):
            if arguments[:3] == ["/usr/bin/codesign", "--verify", "--deep"]:
                return CompletedProcess(arguments, 0, "", "")
            if "--entitlements" in arguments:
                return CompletedProcess(arguments, 0, entitlements.decode("utf-8"), "")
            if "-r-" in arguments:
                return CompletedProcess(arguments, 0, f"designated => {reviewed['designatedRequirement']}\n", "Executable=/reviewed/helper\n")
            if arguments[:3] == ["/usr/bin/security", "cms", "-D"]:
                return CompletedProcess(arguments, 0, profile.decode("utf-8"), "")
            raise AssertionError(arguments)

        with mock.patch.object(MODULE, "EXPECTED_IDENTITY_SHA1", identity):
            MODULE.verify_installed_helper(self.helper, reviewed, command)

    def test_conflicting_designated_requirements_across_streams_are_rejected(self):
        result = CompletedProcess(
            [], 0,
            'designated => identifier "com.marynavdovenko.Plainpost" and anchor apple generic\n',
            'designated => identifier "com.olhapi.Other" and anchor apple generic\n',
        )

        with self.assertRaisesRegex(MODULE.ProvisioningError, "designated requirement mismatch"):
            MODULE.read_designated_requirement(result, 'identifier "com.marynavdovenko.Plainpost" and anchor apple generic')

    def test_extra_effective_entitlement_is_rejected(self):
        value = plistlib.loads(entitlements_plist())
        value["get-task-allow"] = True
        with self.assertRaisesRegex(MODULE.ProvisioningError, "effective helper entitlement mismatch"):
            MODULE.validate_effective_entitlements(plistlib.dumps(value))

    def test_embedded_profile_rejects_group_writable_mode(self):
        self.profile.chmod(0o660)

        with self.assertRaisesRegex(MODULE.ProvisioningError, "unsafe file"):
            MODULE.require_embedded_profile(self.profile)


class VerifyWrapperTests(unittest.TestCase):
    def test_wrapper_maps_composed_packet_inputs_to_dual_root_verifier(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            capture = root / "arguments"
            fake_go = fake_bin / "go"
            fake_go.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$CAPTURE"\n', encoding="utf-8")
            fake_go.chmod(0o755)
            private = root / "private"
            account_public = root / "account-public"
            session_public = root / "session-public"
            key_location = root / "SESSION_KEY_LOCATION.json"
            command = [
                str(Path(__file__).with_name("verify-production-key-authority.sh")),
                str(private), str(account_public), str(session_public),
                MODULE.ACCOUNT_ROOT_SHA256, str(key_location),
            ]
            environment = dict(os.environ, PATH=f"{fake_bin}:{os.environ['PATH']}", CAPTURE=str(capture))

            result = subprocess.run(command, text=True, capture_output=True, check=False, env=environment)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(capture.read_text(encoding="utf-8").splitlines(), [
                "run", "./cmd/plainpost-verify-key-authority",
                "--private-dir", str(private),
                "--account-public-dir", str(account_public),
                "--session-public-dir", str(session_public),
                "--expected-account-root-sha256", MODULE.ACCOUNT_ROOT_SHA256,
                "--session-key-location", str(key_location),
            ])


if __name__ == "__main__":
    unittest.main()
