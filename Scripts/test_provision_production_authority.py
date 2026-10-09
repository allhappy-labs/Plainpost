import importlib.util
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path
from subprocess import CompletedProcess


SCRIPT = Path(__file__).with_name("provision-production-authority.py")
SPEC = importlib.util.spec_from_file_location("provision_production_authority", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def metadata():
    public = b"\x04" + b"\x01" * 64
    return {
        "version": 1,
        "rootKeyID": MODULE.ROOT_KEY_ID,
        "applicationTag": MODULE.ROOT_TAG,
        "label": MODULE.ROOT_LABEL,
        "accessGroup": MODULE.ACCESS_GROUP,
        "keychainContext": "data-protection-keychain",
        "keyType": "P-256 Secure Enclave signing key",
        "publicKey": MODULE.base64url(public),
        "publicKeySHA256": MODULE.sha256(public),
    }


class FakeCommands:
    def __init__(self, helper_results, verifier_result=None):
        self.helper_results = list(helper_results)
        self.verifier_result = verifier_result or CompletedProcess([], 0, "PASS production key authority packet\n", "")
        self.calls = []

    def __call__(self, command):
        self.calls.append(command)
        if command[0].endswith("plainpost-root-authority"):
            return self.helper_results.pop(0)
        return self.verifier_result


class ProvisioningRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.records = self.root / "records"
        self.private = self.root / "private"
        self.public = self.root / "public"
        for directory in (self.records, self.private, self.public):
            directory.mkdir(mode=0o700)
        self.helper = self.root / "plainpost-root-authority"
        self.helper.write_bytes(b"reviewed helper")
        self.helper.chmod(0o755)
        self.verifier = self.root / "verify-production-key-authority.sh"
        self.verifier.write_text("#!/bin/sh\n", encoding="utf-8")
        self.verifier.chmod(0o700)
        self.config = MODULE.Config(
            helper=self.helper,
            expected_helper_sha256=MODULE.sha256(b"reviewed helper"),
            records=self.records,
            private=self.private,
            public=self.public,
            verifier=self.verifier,
            verify_install=lambda: None,
        )

    def tearDown(self):
        self.temporary.cleanup()

    def completed(self, code, payload=None, error=""):
        output = "" if payload is None else json.dumps(payload)
        return CompletedProcess([], code, output, error)

    def write_artifacts(self):
        for name in MODULE.PRIVATE_ARTIFACTS:
            path = self.private / name
            path.write_text("private", encoding="utf-8")
            path.chmod(0o600)
        for name in MODULE.PUBLIC_ARTIFACTS:
            path = self.public / name
            path.write_text("public", encoding="utf-8")
            path.chmod(0o644)

    def test_create_failure_recovers_persisted_root_without_retry_then_completes(self):
        root = metadata()
        self_test = {"root": root, "challengeVerified": True}
        verifier = CompletedProcess([], 0, f"ROOT_SHA256 {root['publicKeySHA256']}\nPASS production key authority packet\n", "")
        fake = FakeCommands([
            self.completed(1, error="production root was not found"),
            self.completed(1, error="Keychain operation failed (OSStatus -25308)"),
            self.completed(0, root),
            self.completed(0, self_test),
            self.completed(0, self_test),
            self.completed(0, {
                "kind": "plainpost-root-authority-issuance.v1",
                "root": root,
                "manifestVersion": "1",
                "notBefore": MODULE.NOT_BEFORE,
                "expiresAt": MODULE.EXPIRES_AT,
                "privateArtifactNames": sorted(MODULE.PRIVATE_ARTIFACTS),
                "publicArtifacts": [
                    {"name": name, "sha256": MODULE.sha256(b"public")}
                    for name in MODULE.PUBLIC_ARTIFACTS
                ],
            }),
        ], verifier)

        def create_artifacts(command):
            result = fake(command)
            if len(fake.calls) == 6:
                self.write_artifacts()
            return result

        result = MODULE.Provisioner(self.config, create_artifacts).run()

        self.assertEqual(result, root["publicKeySHA256"])
        helper_commands = [call[1] for call in fake.calls if call[0] == str(self.helper)]
        self.assertEqual(helper_commands.count("create"), 1)
        self.assertEqual(helper_commands.count("inspect"), 2)
        self.assertEqual(helper_commands.count("self-test"), 2)
        self.assertEqual(helper_commands.count("issue"), 1)
        self.assertEqual(MODULE.read_json(self.records / "KEY_LOCATION.json", 0o600), root)
        self.assertEqual(stat.S_IMODE((self.records / "CREATE_FAILURE.json").stat().st_mode), 0o600)

    def test_partial_issuance_refuses_without_generating_new_leaves(self):
        root = metadata()
        MODULE.write_json_exclusive(self.records / "KEY_LOCATION.json", root)
        for number in (1, 2):
            MODULE.write_json_exclusive(self.records / f"SELF_TEST_RECEIPT_{number}.json", {"root": root, "challengeVerified": True})
        partial = self.private / MODULE.PRIVATE_ARTIFACTS[0]
        partial.write_text("private", encoding="utf-8")
        partial.chmod(0o600)
        fake = FakeCommands([self.completed(0, root)])

        with self.assertRaisesRegex(MODULE.ProvisioningError, "partial issuance"):
            MODULE.Provisioner(self.config, fake).run()

        self.assertNotIn("issue", [call[1] for call in fake.calls if call[0] == str(self.helper)])

    def test_recorded_absent_create_failure_blocks_an_automatic_retry(self):
        MODULE.write_json_exclusive(self.records / "CREATE_FAILURE.json", {
            "kind": "plainpost-root-authority-operation-failure.v1",
            "exitCode": 1,
            "postOperationState": "absent",
            "error": "User interaction is not allowed",
        })
        fake = FakeCommands([self.completed(1, error="production root was not found")])

        with self.assertRaisesRegex(MODULE.ProvisioningError, "previous root creation failure"):
            MODULE.Provisioner(self.config, fake).run()

        self.assertNotIn("create", [call[1] for call in fake.calls if call[0] == str(self.helper)])

    def test_interrupted_create_leaves_attempt_record_that_blocks_retry(self):
        first_calls = []

        def interrupted(command):
            first_calls.append(command)
            if command[1] == "inspect":
                return self.completed(1, error="production root was not found")
            raise RuntimeError("interrupted during create")

        with self.assertRaisesRegex(RuntimeError, "interrupted"):
            MODULE.Provisioner(self.config, interrupted).run()

        attempt = MODULE.read_json(self.records / "CREATE_ATTEMPT.json")
        self.assertEqual(attempt, {
            "kind": "plainpost-root-authority-create-attempt.v1",
            "rootKeyID": MODULE.ROOT_KEY_ID,
            "attempted": True,
        })
        self.assertEqual(stat.S_IMODE((self.records / "CREATE_ATTEMPT.json").stat().st_mode), 0o600)
        second = FakeCommands([self.completed(1, error="production root was not found")])
        with self.assertRaisesRegex(MODULE.ProvisioningError, "previous root creation attempt"):
            MODULE.Provisioner(self.config, second).run()
        self.assertNotIn("create", [call[1] for call in second.calls])

    def test_create_and_followup_inspect_failures_are_both_recorded_without_retry(self):
        fake = FakeCommands([
            self.completed(1, error="production root was not found"),
            self.completed(1, error="Keychain operation failed (OSStatus -25308)"),
            self.completed(1, error="Keychain operation failed (OSStatus -34018)"),
        ])

        with self.assertRaisesRegex(MODULE.ProvisioningError, "root creation failed; follow-up inspect failed"):
            MODULE.Provisioner(self.config, fake).run()

        failure = MODULE.read_json(self.records / "CREATE_FAILURE.json", 0o600)
        self.assertEqual(failure["exitCode"], 1)
        self.assertIn("-25308", failure["error"])
        self.assertEqual(failure["postInspectExitCode"], 1)
        self.assertIn("-34018", failure["postInspectError"])
        helper_commands = [call[1] for call in fake.calls if call[0] == str(self.helper)]
        self.assertEqual(helper_commands.count("create"), 1)
        self.assertEqual(helper_commands.count("inspect"), 2)

    def test_successful_create_with_failed_followup_inspect_is_recorded(self):
        root = metadata()
        fake = FakeCommands([
            self.completed(1, error="production root was not found"),
            self.completed(0, root),
            self.completed(1, error="production root metadata does not match the fixed authority identity"),
        ])

        with self.assertRaisesRegex(MODULE.ProvisioningError, "created root failed fresh-process inspection"):
            MODULE.Provisioner(self.config, fake).run()

        failure = MODULE.read_json(self.records / "CREATE_FAILURE.json", 0o600)
        self.assertEqual(failure["exitCode"], 0)
        self.assertEqual(failure["error"], "create returned success with valid public metadata")
        self.assertEqual(failure["postInspectExitCode"], 1)
        self.assertIn("metadata does not match", failure["postInspectError"])
        self.assertFalse((self.records / "KEY_LOCATION.json").exists())

    def test_initial_inspect_failure_reports_bounded_helper_diagnostic(self):
        diagnostic = "Keychain operation failed (OSStatus -34018)" + "x" * 600
        fake = FakeCommands([self.completed(1, error=diagnostic)])

        with self.assertRaises(MODULE.ProvisioningError) as raised:
            MODULE.Provisioner(self.config, fake).run()

        self.assertIn("OSStatus -34018", str(raised.exception))
        self.assertLessEqual(len(str(raised.exception)), len("root inspect failed: ") + 512)
        self.assertEqual(len(fake.calls), 1)

    def test_unsafe_private_directory_is_rejected_before_root_inspection(self):
        self.private.chmod(0o755)
        fake = FakeCommands([])

        with self.assertRaisesRegex(MODULE.ProvisioningError, "unsafe directory"):
            MODULE.Provisioner(self.config, fake).run()

        self.assertEqual(fake.calls, [])

    def test_verifier_checkout_excludes_go_tests_but_protects_production_sources(self):
        verifier_root = self.root / "checkout"
        verifier = verifier_root / "Scripts/verify-production-key-authority.sh"
        verifier.parent.mkdir(parents=True)
        verifier.write_text("#!/bin/sh\n", encoding="utf-8")
        calls = []

        def git(command):
            calls.append(command)
            return CompletedProcess(command, 0, "", "")

        selected = MODULE.find_verifier(command=git, candidates=(verifier_root,))

        self.assertEqual(selected, verifier)
        guarded = [call for call in calls if "diff" in call or "status" in call]
        self.assertEqual(len(guarded), 2)
        for command in guarded:
            self.assertIn("Services/PlainpostGo/internal/central/account", command)
            self.assertIn("Services/PlainpostGo/internal/central/deviceauth", command)
            self.assertEqual(command[-1], ":(exclude)**/*_test.go")

    def test_fully_verified_packet_is_rechecked_and_skips_issue(self):
        root = metadata()
        MODULE.write_json_exclusive(self.records / "KEY_LOCATION.json", root)
        for number in (1, 2):
            MODULE.write_json_exclusive(self.records / f"SELF_TEST_RECEIPT_{number}.json", {"root": root, "challengeVerified": True})
        self.write_artifacts()
        verifier = CompletedProcess([], 0, f"ROOT_SHA256 {root['publicKeySHA256']}\nPASS production key authority packet\n", "")
        fake = FakeCommands([self.completed(0, root)], verifier)

        result = MODULE.Provisioner(self.config, fake).run()

        self.assertEqual(result, root["publicKeySHA256"])
        self.assertNotIn("issue", [call[1] for call in fake.calls if call[0] == str(self.helper)])
        self.assertEqual(sum(call[0] == str(self.verifier) for call in fake.calls), 1)


if __name__ == "__main__":
    unittest.main()
