#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).with_name("verify-profile.py")


class VerificationProfileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("verify_profile", SCRIPT)
        cls.runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.runner)

    def run_fixture(self, *, inventory="FixtureTests/testOne", selected="FixtureTests", exit_code=0, count=1, prerequisites=(), required_targets=()):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        command = [sys.executable, "-c", f"print('Ran {count} tests in 0.001s'); print('OK'); raise SystemExit({exit_code})"]
        profile = {"kind": "swift", "prerequisites": list(prerequisites),
                   "required_targets": list(required_targets),
                   "discovery": [sys.executable, "-c", f"print({inventory!r})"],
                   "selection": selected, "command": command}
        output = Path(directory.name) / "evidence"
        result = self.runner.run_profile("fixture", output, profiles={"fixture": profile})
        return result, output

    def test_zero_selected_tests_fails(self):
        result, output = self.run_fixture(selected="TypoTests")
        self.assertEqual(result["status"], "failed")
        self.assertIn("zero", result["reason"])
        self.assertFalse((output / "execution").exists())

    def test_missing_prerequisite_is_unavailable(self):
        result, output = self.run_fixture(prerequisites=["plainpost-nonexistent-tool-391"])
        self.assertEqual(result["status"], "unavailable")
        self.assertTrue((output / "profile.json").exists())

    def test_command_failure_retains_log(self):
        result, output = self.run_fixture(exit_code=17)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["execution"]["exit_code"], 17)
        self.assertIn("Ran 1 tests", (output / "execution/command.log").read_text())

    def test_nonzero_execution_passes(self):
        result, _ = self.run_fixture()
        self.assertEqual(result["status"], "passed")
        self.assertEqual(len(result["selected_tests"]), 1)

    def test_zero_executed_tests_fails(self):
        result, _ = self.run_fixture(count=0)
        self.assertEqual(result["status"], "failed")

    def test_inventory_requires_test_identifiers(self):
        result, _ = self.run_fixture(inventory="FixtureTests build succeeded")
        self.assertEqual(result["status"], "failed")

    def test_discovery_duplicates_are_not_double_counted(self):
        result, _ = self.run_fixture(inventory="FixtureTests/testOne\nFixtureTests/testOne")
        self.assertEqual(result["selected_tests"], ["FixtureTests/testOne"])

    def test_partial_execution_fails(self):
        result, _ = self.run_fixture(inventory="FixtureTests/testOne\nFixtureTests/testTwo")
        self.assertEqual(result["status"], "failed")

    def test_one_missing_target_in_nonzero_selection_fails(self):
        result, _ = self.run_fixture(inventory="FixtureTests.testOne/testRun", required_targets=["FixtureTests", "TypoTests"])
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["missing_targets"], ["TypoTests"])

    def test_swift_testing_and_xctest_both_appear_in_inventory(self):
        result, _ = self.run_fixture(inventory="FixtureTests.testSuite/testOne\nFixtureTests.swiftCase()", count=2,
                                     required_targets=["FixtureTests"])
        self.assertEqual(result["selected_tests"], ["FixtureTests.swiftCase()", "FixtureTests.testSuite/testOne"])

    def test_xcode_inventory_reads_only_test_case_identifiers(self):
        value = "Target/Suite\n  Target/Suite/testOne()\nTest enumeration succeeded\n"
        self.assertEqual(self.runner.xcode_inventory(value), ["Target/Suite/testOne"])

    def test_xcode_summary_requires_nonzero_unskipped_execution(self):
        summary = {"totalTestCount": 2, "passedTests": 0, "failedTests": 0, "skippedTests": 2, "expectedFailures": 0, "result": "Passed"}
        self.assertEqual(self.runner.xcode_counts(summary)["executed"], 0)

    def test_xcode_summary_rejects_inconsistent_counts(self):
        summary = {"totalTestCount": 2, "passedTests": 1, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0, "result": "Passed"}
        with self.assertRaises(ValueError):
            self.runner.xcode_counts(summary)

    def test_profiles_keep_rendering_in_ui_and_have_integration_tier(self):
        self.assertEqual(set(self.runner.PROFILES), {"calendar", "core", "db", "ui", "service", "ios", "integration"})
        self.assertIn("PlainpostUITests", self.runner.PROFILES["ui"]["selection"])
        self.assertNotIn("PlainpostUITests", self.runner.PROFILES["core"]["selection"])

    def test_migrated_acceptance_cases_keep_exactly_one_profile_owner(self):
        cases = {
            "PlainpostSearchBenchmarkTests.MailSearchBenchmarkSupportTests/testProcessRejectsSourceOutputAliasWithoutChangingSource": "db",
            "PlainpostServiceTests.AccountDeletionAcceptanceTests/testForegroundServiceIPCPurgesCompleteTargetOwnershipWithoutRemoteMutation": "service",
            "PlainpostServiceTests.AccountDeletionAcceptanceTests/testForegroundServiceIPCCleanupPendingRecoversAfterRestartAndRetryIsStateIdempotent": "service",
        }
        for identifier, expected in cases.items():
            with self.subTest(identifier=identifier):
                owners = [name for name, profile in self.runner.PROFILES.items()
                          if profile["kind"] == "swift"
                          and self.runner.swift_inventory(identifier, profile["selection"])]
                self.assertEqual(owners, [expected])
                target = identifier.split(".")[0]
                self.assertIn(target, self.runner.PROFILES[expected]["required_targets"])

    def test_calendar_model_has_one_narrow_build_and_execution_owner(self):
        identifier = "PlainpostCalendarPresentationTests.CalendarWeekLayoutTests/testWeekUsesCalendarArithmeticAcrossDST"
        owners = [name for name, profile in self.runner.PROFILES.items()
                  if profile.get("selection") and isinstance(profile["selection"], str)
                  and self.runner.swift_inventory(identifier, profile["selection"])]
        self.assertEqual(owners, ["calendar"])
        profile = self.runner.PROFILES.get("calendar", {})
        self.assertEqual(profile.get("target"), "PlainpostCalendarPresentationTests")
        self.assertEqual(profile.get("kind"), "swift-target")

    def test_passing_ios_execution_records_its_build_sdk_and_cache(self):
        # Xcode/simulator are an external boundary. Keep the real measurement
        # argv construction so omitted defaults cannot be hidden by a stub.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / ".build/verification-ios-debug"
            xctestrun = cache / "Build/Products/Fixture.xctestrun"
            selected = self.runner.PROFILES["ios"]["selection"]
            summary = {"totalTestCount": len(selected), "passedTests": len(selected),
                       "failedTests": 0, "skippedTests": 0, "expectedFailures": 0, "result": "Passed"}

            def execute_boundary(argv, **kwargs):
                if argv[:3] == ["xcrun", "simctl", "bootstatus"]:
                    return subprocess.CompletedProcess(argv, 0, "ready\n", "")
                if "xcresulttool" in argv:
                    return subprocess.CompletedProcess(argv, 0, json.dumps(summary), "")
                self.assertEqual(argv[1], str(self.runner.MEASURE))
                output = Path(argv[argv.index("--output") + 1])
                output.mkdir(parents=True)
                command = argv[argv.index("--") + 1:]
                if "build-for-testing" in command:
                    xctestrun.parent.mkdir(parents=True)
                    xctestrun.write_text("fixture test build")
                if "-enumerate-tests" in command:
                    inventory = Path(command[command.index("-test-enumeration-output-path") + 1])
                    inventory.write_text("\n".join(test + "()" for test in selected))
                log = output / "command.log"
                log.write_text("fixture Xcode boundary\n")
                metadata = {"exit_code": 0, "test_counts": None, "command": command,
                            "cache": {"path": argv[argv.index("--cache-path") + 1],
                                      "sdk": argv[argv.index("--sdk") + 1]},
                            "artifacts": {"log": str(log)}}
                (output / "result.json").write_text(json.dumps(metadata))
                return subprocess.CompletedProcess(argv, 0)

            with mock.patch.object(self.runner, "ROOT", root), \
                    mock.patch.object(self.runner.shutil, "which", return_value="fixture-tool"), \
                    mock.patch.object(self.runner.shutil, "disk_usage", return_value=mock.Mock(free=20 * 1024 ** 3)), \
                    mock.patch.object(self.runner.subprocess, "run", side_effect=execute_boundary):
                result = self.runner.run_profile("ios", root / "evidence")

            self.assertEqual(result["status"], "passed")
            self.assertEqual(result["selected_tests"], selected)
            self.assertEqual(result["test_counts"], {"executed": len(selected), "failures": 0, "skipped": 0})
            self.assertEqual([(result[phase]["cache"]["sdk"], result[phase]["cache"]["path"])
                              for phase in ("build", "discovery", "execution")],
                             [("iphonesimulator", str(cache))] * 3)
            command = result["execution"]["command"]
            self.assertEqual(command[command.index("-xctestrun") + 1], str(xctestrun))
            self.assertEqual(json.loads((root / "evidence/profile.json").read_text()), result)

    def test_swift_execution_keeps_default_sdk_and_cache(self):
        result, _ = self.run_fixture()
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["execution"]["cache"]["sdk"], "macosx")
        self.assertEqual(result["execution"]["cache"]["path"], str(self.runner.ROOT / ".build"))

    def test_ios_build_failure_retains_raw_scheme_log(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tool = root / "xcodebuild"
            tool.write_text("#!/bin/sh\nif [ \"$1\" = -version ]; then echo 'Xcode fixture'; exit 0; fi\nprintf 'error: synthetic failure\\n'\nexit 17\n")
            tool.chmod(0o700)
            output = root / "logs"
            environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                               PLAINPOST_IOS_BUILD_OUTPUT=str(output), PLAINPOST_IOS_DERIVED_DATA=str(root / "cache"))
            result = subprocess.run(["bash", str(SCRIPT.with_name("test-ios-simulator-build.sh"))],
                                    env=environment, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((output / "PlainpostUI.log").read_text(), "error: synthetic failure\n")


if __name__ == "__main__":
    unittest.main()
