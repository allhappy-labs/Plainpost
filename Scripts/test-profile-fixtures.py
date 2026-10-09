#!/usr/bin/env python3
"""Fixture plumbing contracts; synthetic child success is not product acceptance."""
import hashlib
import importlib.util
import inspect
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Scripts/lib"))
KEYS = ("PLAINPOST_RECOVERY_PREPARATION_FIXTURE", "PLAINPOST_SYNC_NODE_STREAM_DIAGNOSTIC_LOG", "PLAINPOST_BROWSER_SMOKE_ROOT")
SECRET_KEYS = ("TEST_POSTGRES_URL", "T3_MCP_BEARER_TOKEN", "SSH_AUTH_SOCK", "PLAINPOST_SYNC_NODE_LIVE_TEST")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FixtureBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.runner = load("fixture_profile_runner", ROOT / "Scripts/verify-profile.py")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.root.chmod(0o700)

    def descriptor(self, slot):
        if slot == "recoveryPreparation":
            path = self.root / "recovery.json"
            path.write_bytes(b'{"synthetic":true}')
            path.chmod(0o600)
            value = {"file": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            profile = "service"
        elif slot == "streamDiagnostics":
            value = {"output": "stream.log"}
            profile = "service"
        else:
            (self.root / "browser").mkdir(mode=0o700)
            value = {"coordinationRoot": "browser"}
            profile = "integration"
        descriptor = self.root / "fixtures.json"
        descriptor.write_text(json.dumps({"version": 1, "profile": profile, "root": str(self.root), "fixtures": {slot: value}}))
        descriptor.chmod(0o600)
        return descriptor, profile

    def execute(self, slot=None, *, mutate_input=False, mutate_discovery=False):
        options = {}
        name = "service"
        if slot:
            descriptor, name = self.descriptor(slot)
            self.assertIn("fixture_inputs", inspect.signature(self.runner.run_profile).parameters,
                          "named profiles must accept explicit fixture admission")
            options["fixture_inputs"] = descriptor
        keys = repr(KEYS + SECRET_KEYS)
        discovery = [sys.executable, "-c", "import os; assert not any(k in os.environ for k in " + keys + "); print('FixtureTests/testBoundary')"]
        expected = {"recoveryPreparation": KEYS[0], "streamDiagnostics": KEYS[1], "browserSmoke": KEYS[2]}.get(slot)
        child = "import os; from pathlib import Path; "
        child += "assert not any(k in os.environ for k in " + repr(SECRET_KEYS) + "); "
        child += "assert set(k for k in " + repr(KEYS) + " if k in os.environ) == " + repr({expected} if expected else set()) + "; "
        if slot == "recoveryPreparation":
            child += "assert Path(os.environ[" + repr(expected) + "]).read_bytes() == b'{\"synthetic\":true}'; "
        elif slot == "streamDiagnostics":
            child += "p=Path(os.environ[" + repr(expected) + "]); assert p.exists() and p.stat().st_mode & 0o777 == 0o600; p.write_text('synthetic diagnostic'); "
        elif slot == "browserSmoke":
            # This only proves post-execution identity permits legitimate output.
            # It is not a browser completion marker or browser smoke substitute.
            child += "p=Path(os.environ[" + repr(expected) + "]); assert not list(p.iterdir()); (p/'child-output').write_text('synthetic child'); "
        if mutate_input:
            child += "Path(os.environ[" + repr(expected) + "]).write_text('changed after read'); "
        child += "print('Ran 1 test in 0.001s'); print('OK')"
        if mutate_discovery:
            discovery[2] = "from pathlib import Path; Path(" + repr(str(self.root / "recovery.json")) + ").write_text('changed during discovery'); " + discovery[2]
        profile = {"kind": "swift", "prerequisites": [], "selection": "FixtureTests", "discovery": discovery,
                   "command": [sys.executable, "-c", child]}
        sentinels = {key: "synthetic-rejected-sentinel" for key in KEYS + SECRET_KEYS}
        with mock.patch.dict(os.environ, sentinels):
            result = self.runner.run_profile(name, self.root / "evidence", profiles={name: profile}, **options)
        self.assertEqual(result["status"], "failed" if mutate_input or mutate_discovery else "passed", result.get("reason"))
        if not mutate_discovery:
            self.assertEqual(result["test_counts"], {"executed": 1, "failures": 0, "skipped": 0})
        self.assertFalse((self.root / ".plainpost-fixture-use").exists())
        return result

    def test_recovery_only_reaches_execution(self):
        self.execute("recoveryPreparation")

    def test_diagnostics_reserves_fresh_private_output(self):
        self.execute("streamDiagnostics")

    def test_browser_allows_child_output_after_initial_freshness(self):
        self.execute("browserSmoke")

    def test_ambient_credentials_and_fixture_selectors_are_rejected(self):
        self.execute()

    def test_child_zero_exit_does_not_hide_post_execution_input_mutation(self):
        result = self.execute("recoveryPreparation", mutate_input=True)
        self.assertEqual(result["execution"]["child_exit_code"], 0)
        self.assertEqual(result["execution"]["exit_code"], 126)
        self.assertEqual(result["execution"]["fixture_inputs"]["status"], "failed")

    def test_discovery_cannot_change_admitted_input_before_execution(self):
        result = self.execute("recoveryPreparation", mutate_discovery=True)
        self.assertIsNone(result["execution"]["child_exit_code"])
        self.assertIsNone(result["test_counts"])



class FixtureGuardTests(unittest.TestCase):
    setUp = FixtureBoundaryTests.setUp
    descriptor = FixtureBoundaryTests.descriptor

    def prepare(self, slot="recoveryPreparation"):
        import profile_fixtures
        self.helper = profile_fixtures
        self.path, self.profile = self.descriptor(slot)
        self.record = self.root / "admission.json"
        return self.path

    def rewrite(self, edit):
        document = json.loads(self.path.read_text())
        edit(document)
        self.path.write_text(json.dumps(document))

    def rejected(self):
        with self.assertRaises((ValueError, OSError)):
            self.helper.admit(self.path, self.profile, self.record)
        self.assertFalse(self.record.exists())

    def start(self):
        self.helper.admit(self.path, self.profile, self.record)
        execution = self.helper.Execution(self.path, self.record)
        execution.start()
        return execution

    def test_rejects_unknown_duplicate_fields_at_every_level(self):
        self.prepare()
        original = self.path.read_text()
        for fragment in ('"version": 1', '"recoveryPreparation":', '"file": "recovery.json"'):
            with self.subTest(fragment=fragment):
                if fragment.endswith(":"):
                    changed = original.replace(fragment, '"recoveryPreparation": {}, ' + fragment)
                else:
                    changed = original.replace(fragment, fragment + ', ' + fragment)
                self.path.write_text(changed)
                self.rejected()
        for level in ("root", "fixtures", "slot"):
            with self.subTest(level=level):
                self.path.write_text(original)
                self.rewrite(lambda d: (d if level == "root" else d["fixtures"] if level == "fixtures" else d["fixtures"]["recoveryPreparation"]).update(environment={"KEY": "forbidden"}))
                self.rejected()

    def test_rejects_wrong_versions_types_empty_slots_and_profiles(self):
        self.prepare()
        original = self.path.read_text()
        changes = [("version", True), ("version", 2), ("version", "1"), ("fixtures", {}),
                   ("fixtures", []), ("root", 4), ("profile", "integration")]
        for key, value in changes:
            with self.subTest(key=key, value=value):
                self.path.write_text(original)
                self.rewrite(lambda d: d.update({key: value}))
                self.rejected()
        self.path.write_text(original)
        for name in ("core", "calendar", "db", "ui", "ios"):
            self.profile = name
            self.rejected()

    def test_slot_paths_are_unique_relative_leaves(self):
        self.prepare()
        for name in ("../recovery.json", "/recovery.json", "a/b", "a\\b", ".", "..", "", "a\n", "fixtures.json", ".plainpost-fixture-use"):
            with self.subTest(name=name):
                self.rewrite(lambda d: d["fixtures"]["recoveryPreparation"].update(file=name))
                self.rejected()

    def test_profile_slot_mismatch_and_output_alias_rejected(self):
        self.prepare()
        self.rewrite(lambda d: d["fixtures"].update(browserSmoke={"coordinationRoot": "browser"}))
        self.rejected()
        self.rewrite(lambda d: d["fixtures"].pop("browserSmoke"))
        self.rewrite(lambda d: d["fixtures"].update(streamDiagnostics={"output": "recovery.json"}))
        self.rejected()

    def test_private_modes_and_current_owner_required(self):
        self.prepare()
        for path, original in ((self.path, 0o600), (self.root / "recovery.json", 0o600), (self.root, 0o700)):
            path.chmod(0o755)
            self.rejected()
            path.chmod(original)
        with mock.patch.object(self.helper.os, "getuid", return_value=os.getuid() + 1):
            self.rejected()

    def test_descriptor_input_and_root_symlinks_rejected(self):
        self.prepare()
        original_path = self.path
        alias = self.root / "descriptor-link"
        alias.symlink_to(self.path)
        self.path = alias
        self.rejected()
        self.path = original_path
        data = self.root / "recovery.json"
        data.rename(self.root / "real-input")
        data.symlink_to(self.root / "real-input")
        self.rejected()
        root_alias = self.root / "root-link"
        root_alias.symlink_to(self.root, target_is_directory=True)
        self.path = root_alias / "fixtures.json"
        self.rejected()

    def test_descriptor_and_input_hardlinks_rejected(self):
        self.prepare()
        for path in (self.path, self.root / "recovery.json"):
            alias = self.root / "hardlink"
            os.link(path, alias)
            self.rejected()
            alias.unlink()

    def test_malformed_non_utf8_oversized_descriptor_rejected(self):
        self.prepare()
        for data in (b"{", b"\xff", b" " * 65537):
            self.path.write_bytes(data)
            self.rejected()

    def test_missing_empty_and_hash_mismatch_inputs_rejected(self):
        self.prepare()
        data = self.root / "recovery.json"
        data.write_bytes(b"")
        self.rejected()
        data.write_bytes(b"different")
        self.rejected()
        data.unlink()
        self.rejected()

    def test_existing_diagnostic_file_and_dangling_symlink_rejected(self):
        self.prepare("streamDiagnostics")
        path = self.root / "stream.log"
        path.write_text("must remain")
        path.chmod(0o600)
        self.rejected()
        self.assertEqual(path.read_text(), "must remain")
        path.unlink()
        path.symlink_to(self.root / "missing")
        self.rejected()
        self.assertTrue(path.is_symlink())

    def test_browser_existing_ready_or_done_rejected(self):
        self.prepare("browserSmoke")
        for name in ("ready", "done"):
            path = self.root / "browser" / name
            path.write_text("external")
            self.rejected()
            self.assertEqual(path.read_text(), "external")
            path.unlink()

    def test_input_change_after_admission_rejected(self):
        self.prepare()
        self.helper.admit(self.path, self.profile, self.record)
        (self.root / "recovery.json").write_text("changed")
        with self.assertRaises(ValueError):
            self.helper.Execution(self.path, self.record).start()
        self.assertFalse((self.root / self.helper.MARKER).exists())

    def test_descriptor_change_after_admission_rejected(self):
        self.prepare()
        self.helper.admit(self.path, self.profile, self.record)
        self.path.write_text(self.path.read_text() + " ")
        with self.assertRaises(ValueError):
            self.helper.Execution(self.path, self.record).start()

    def test_concurrent_root_use_rejected_without_removing_owner(self):
        self.prepare()
        owner = self.start()
        marker = self.root / self.helper.MARKER
        before = marker.stat().st_ino
        with self.assertRaises(FileExistsError):
            self.helper.Execution(self.path, self.record).start()
        self.assertEqual(marker.stat().st_ino, before)
        owner.finish()
        self.assertFalse(marker.exists())

    def test_replaced_marker_is_retained_and_fails_completion(self):
        self.prepare()
        owner = self.start()
        marker = self.root / self.helper.MARKER
        marker.rename(self.root / "original-marker")
        marker.write_text("another owner")
        marker.chmod(0o600)
        with self.assertRaises(ValueError):
            owner.finish()
        self.assertEqual(marker.read_text(), "another owner")

    def test_post_execution_input_mutation_fails_but_releases_own_marker(self):
        self.prepare()
        owner = self.start()
        (self.root / "recovery.json").write_text("changed")
        with self.assertRaises(ValueError):
            owner.finish()
        self.assertFalse((self.root / self.helper.MARKER).exists())

    def test_replaced_diagnostic_output_fails_completion(self):
        self.prepare("streamDiagnostics")
        owner = self.start()
        path = self.root / "stream.log"
        path.rename(self.root / "original-output")
        path.write_text("replacement")
        path.chmod(0o600)
        with self.assertRaises(ValueError):
            owner.finish()
        self.assertEqual(path.read_text(), "replacement")
        self.assertFalse((self.root / self.helper.MARKER).exists())

    def test_admission_record_change_fails_before_execution(self):
        self.prepare()
        self.helper.admit(self.path, self.profile, self.record)
        owner = self.helper.Execution(self.path, self.record)
        self.record.write_text(self.record.read_text() + " ")
        with self.assertRaises(ValueError):
            owner.start()

    def test_same_bytes_replaced_input_fails_identity(self):
        self.prepare()
        self.helper.admit(self.path, self.profile, self.record)
        path = self.root / "recovery.json"
        data = path.read_bytes()
        path.rename(self.root / "original-input")
        path.write_bytes(data)
        path.chmod(0o600)
        with self.assertRaises(ValueError):
            self.helper.Execution(self.path, self.record).start()

    def test_probes_use_only_tool_safe_environment(self):
        measurement = load("fixture_measurement", ROOT / "Scripts/measure-dev-iteration.py")
        with mock.patch.dict(os.environ, {key: "synthetic-sentinel" for key in KEYS + SECRET_KEYS}), \
                mock.patch.object(measurement.subprocess, "run") as run:
            run.return_value = mock.Mock(returncode=0, stdout="version", stderr="")
            measurement.probe(["swift", "--version"], self.root)
            self.assertFalse(set(KEYS + SECRET_KEYS) & set(run.call_args.kwargs["env"]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
