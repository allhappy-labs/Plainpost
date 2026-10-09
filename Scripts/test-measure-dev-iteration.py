"""Behavioral contract for the command runner, using real child processes."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

RUNNER = Path(__file__).with_name("measure-dev-iteration.py")


class MeasureDevIterationTests(unittest.TestCase):
    def run_command(self, directory, code, *arguments):
        self.assertTrue(RUNNER.is_file(), "measurement runner must exist")
        output = Path(directory) / "measurement"
        process = subprocess.run(
            [sys.executable, str(RUNNER), "--scenario", "contract",
             "--output", str(output), "--cache-state", "warm", "--",
             sys.executable, "-c", code, *arguments],
            capture_output=True, text=True,
        )
        return process, json.loads((output / "result.json").read_text()), output

    def test_preserves_exit_status_and_log(self):
        # Swallowing the child's failure or dropping stderr must break this test.
        with tempfile.TemporaryDirectory() as directory:
            process, result, output = self.run_command(
                directory, "import sys; print('before failure'); print('failure detail', file=sys.stderr); sys.exit(7)"
            )
            self.assertEqual(process.returncode, 7)
            self.assertEqual(result["exit_code"], 7)
            self.assertIn("before failure", (output / "command.log").read_text())
            self.assertIn("failure detail", (output / "command.log").read_text())
            for field in ("source_sha", "dirty_paths", "toolchain", "scenario", "cache_identity", "command", "start_time", "end_time"):
                self.assertIn(field, result)
            self.assertEqual(result["cache_state"], "warm")

    def test_records_command_as_arguments(self):
        # shell=True would execute the substitution and change the literal argv.
        with tempfile.TemporaryDirectory() as directory:
            sentinel = Path(directory) / "must-not-exist"
            literal = f"$(touch {sentinel})"
            process, result, output = self.run_command(
                directory, "import json, sys; print(json.dumps(sys.argv[1:]))", literal, "two words"
            )
            self.assertEqual(process.returncode, 0)
            self.assertEqual(result["command"][-2:], [literal, "two words"])
            self.assertEqual(json.loads((output / "command.log").read_text()), [literal, "two words"])
            self.assertFalse(sentinel.exists())

    def test_unknown_test_count_is_not_zero(self):
        # A generic success message must never become an empty green test run.
        with tempfile.TemporaryDirectory() as directory:
            _, result, _ = self.run_command(directory, "print('all checks passed')")
            self.assertIsNone(result["test_counts"])
            self.assertEqual(result["test_count_status"], "unavailable")

    def test_recognizes_xctest_summary_without_double_counting_nested_suites(self):
        with tempfile.TemporaryDirectory() as directory:
            _, result, _ = self.run_command(directory, "print('Executed 3 tests, with 1 failure (0 unexpected) in 0.1 seconds\\nExecuted 8 tests, with 1 failure (0 unexpected) in 0.2 seconds')")
            self.assertEqual(result["test_counts"], {"executed": 8, "failures": 1, "skipped": 0})

    def test_combines_empty_xctest_with_passing_swift_testing(self):
        # An empty XCTest process must not erase independent Swift Testing cases.
        with tempfile.TemporaryDirectory() as directory:
            log = "Test Suite 'All tests' passed at now.\n Executed 0 tests, with 0 failures (0 unexpected) in 0.001 seconds\n✔ Test run with 3 tests in 1 suite passed after 0.002 seconds."
            _, result, _ = self.run_command(directory, "print(" + repr(log) + ")")
            self.assertEqual(result["test_counts"], {"executed": 3, "failures": 0, "skipped": 0})

    def test_combines_nonempty_xctest_and_swift_testing_without_nested_duplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            log = "Test Suite 'ExampleTests' failed at now.\n Executed 2 tests, with 1 failure (0 unexpected) in 0.001 seconds\nTest Suite 'All tests' failed at now.\n Executed 2 tests, with 1 failure (0 unexpected) in 0.001 seconds\n✔ Suite ExampleSuite passed after 0.001 seconds.\n✔ Test run with 3 tests in 1 suite passed after 0.002 seconds."
            _, result, _ = self.run_command(directory, "print(" + repr(log) + ")")
            self.assertEqual(result["test_counts"], {"executed": 5, "failures": 1, "skipped": 0})

    def test_empty_xctest_and_failing_swift_testing_inventory_is_unavailable(self):
        # A Swift Testing issue count cannot safely stand for failed test cases.
        with tempfile.TemporaryDirectory() as directory:
            log = "Test Suite 'All tests' passed at now.\n Executed 0 tests, with 0 failures (0 unexpected) in 0.001 seconds\n✘ Test run with 3 tests in 1 suite failed after 0.002 seconds with 2 issues."
            _, result, _ = self.run_command(directory, "print(" + repr(log) + ")")
            self.assertIsNone(result["test_counts"])
            self.assertEqual(result["test_count_status"], "unavailable")

    def test_nonempty_xctest_and_failing_swift_testing_inventory_is_unavailable(self):
        with tempfile.TemporaryDirectory() as directory:
            log = "Test Suite 'Selected tests' passed at now.\n Executed 2 tests, with 0 failures (0 unexpected) in 0.001 seconds\n✘ Test run with 3 tests failed after 0.002 seconds with 1 issue."
            _, result, _ = self.run_command(directory, "print(" + repr(log) + ")")
            self.assertIsNone(result["test_counts"])
            self.assertEqual(result["test_count_status"], "unavailable")

    def test_present_but_incomplete_or_unknown_swift_testing_inventory_is_unavailable(self):
        xctest = "Test Suite 'All tests' passed at now.\n Executed 2 tests, with 0 failures (0 unexpected) in 0.001 seconds\n"
        for swift in ("◇ Test run started.\n✔ Test example() passed after 0.001 seconds.",
                      "✔ Test run with three tests passed after 0.002 seconds.",
                      "◇ Test run started.\n◇ Test run started.\n✔ Test run with 3 tests passed after 0.002 seconds."):
            with self.subTest(swift=swift), tempfile.TemporaryDirectory() as directory:
                _, result, _ = self.run_command(directory, "print(" + repr(xctest + swift) + ")")
                self.assertIsNone(result["test_counts"])
                self.assertEqual(result["test_count_status"], "unavailable")

    def test_combines_independent_swift_testing_runs_without_suite_duplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            log = "◇ Test run started.\n✔ Suite ExampleSuite passed after 0.001 seconds.\n✔ Test run with 3 tests in 1 suite passed after 0.002 seconds.\n◇ Test run started.\n✔ Test run with 2 tests passed after 0.002 seconds."
            _, result, _ = self.run_command(directory, "print(" + repr(log) + ")")
            self.assertEqual(result["test_counts"], {"executed": 5, "failures": 0, "skipped": 0})

    def test_passing_empty_swift_testing_run_preserves_nonzero_xctest_inventory(self):
        with tempfile.TemporaryDirectory() as directory:
            log = "Test Suite 'Selected tests' passed at now.\n Executed 26 tests, with 0 failures (0 unexpected) in 0.001 seconds\n✔ Test run with 0 tests passed after 0.002 seconds."
            _, result, _ = self.run_command(directory, "print(" + repr(log) + ")")
            self.assertEqual(result["test_counts"], {"executed": 26, "failures": 0, "skipped": 0})

    def test_counts_plural_xctest_skips_across_mixed_engines(self):
        # Dropping the skipped engine produces an incomplete, apparently clean total.
        with tempfile.TemporaryDirectory() as directory:
            log = "Test Case 'ExampleTests.optIn' skipped (0.0 seconds).\nTest Suite 'Selected tests' passed at now.\n Executed 589 tests, with 7 tests skipped and 0 failures (0 unexpected) in 0.1 seconds\nTest Suite 'Selected tests' passed at now.\n Executed 38 tests, with 0 failures (0 unexpected) in 0.1 seconds\n✔ Test run with 42 tests in 1 suite passed after 0.002 seconds."
            _, result, _ = self.run_command(directory, "print(" + repr(log) + ")")
            self.assertEqual(result["test_counts"], {"executed": 669, "failures": 0, "skipped": 7})

    def test_counts_singular_xctest_skip_without_nested_duplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            log = "Test Suite 'ExampleTests' passed at now.\n Executed 384 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.1 seconds\nTest Suite 'Selected tests' passed at now.\n Executed 384 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.1 seconds\nTest Suite 'Selected tests' passed at now.\n Executed 38 tests, with 0 failures (0 unexpected) in 0.1 seconds"
            _, result, _ = self.run_command(directory, "print(" + repr(log) + ")")
            self.assertEqual(result["test_counts"], {"executed": 422, "failures": 0, "skipped": 1})

    def test_preserves_xctest_skips_failures_and_child_failure_status(self):
        with tempfile.TemporaryDirectory() as directory:
            log = "Test Suite 'All tests' started at now.\nTest Suite 'All tests' failed at now.\n Executed 9 tests, with 2 tests skipped and 1 failure (0 unexpected) in 0.1 seconds\n✔ Test run with 3 tests passed after 0.002 seconds."
            process, result, _ = self.run_command(directory, "import sys; print(" + repr(log) + "); sys.exit(5)")
            self.assertEqual(result["test_counts"], {"executed": 12, "failures": 1, "skipped": 2})
            self.assertEqual(result["exit_code"], 5)
            self.assertEqual(process.returncode, 5)

    def test_incomplete_or_unknown_xctest_engine_makes_mixed_inventory_unavailable(self):
        complete = "Test Suite 'Selected tests' passed at now.\n Executed 2 tests, with 0 failures (0 unexpected) in 0.1 seconds\n"
        swift = "✔ Test run with 3 tests passed after 0.002 seconds."
        for broken in ("Test Suite 'All tests' started at now.\n",
                       "Test Suite 'All tests' passed at now.\n",
                       "Test Suite 'All tests' passed at now.\n Executed nine tests, with 0 failures (0 unexpected) in 0.1 seconds\n",
                       "Test Suite 'All tests' aborted at now.\n",
                       "Test Suite 'All tests' started at now.\nTest Suite 'Selected tests' started at now.\nTest Suite 'Selected tests' passed at now.\n Executed 1 test, with 0 failures (0 unexpected) in 0.1 seconds\n"):
            with self.subTest(broken=broken), tempfile.TemporaryDirectory() as directory:
                _, result, _ = self.run_command(directory, "print(" + repr(complete + broken + swift) + ")")
                self.assertIsNone(result["test_counts"])
                self.assertEqual(result["test_count_status"], "unavailable")

    def test_unknown_bare_xctest_footer_does_not_keep_prior_total(self):
        with tempfile.TemporaryDirectory() as directory:
            log = "Executed 3 tests, with 0 failures (0 unexpected) in 0.1 seconds\nExecuted 4 tests, with unknown results"
            _, result, _ = self.run_command(directory, "print(" + repr(log) + ")")
            self.assertIsNone(result["test_counts"])

    def test_counts_skips_in_bare_nested_xctest_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            log = "Executed 3 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.1 seconds\nExecuted 8 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.2 seconds"
            _, result, _ = self.run_command(directory, "print(" + repr(log) + ")")
            self.assertEqual(result["test_counts"], {"executed": 8, "failures": 0, "skipped": 1})

    def test_impossible_xctest_skip_total_makes_inventory_unavailable(self):
        with tempfile.TemporaryDirectory() as directory:
            log = "Test Suite 'Selected tests' passed at now.\n Executed 1 test, with 2 tests skipped and 0 failures (0 unexpected) in 0.1 seconds\n✔ Test run with 3 tests passed after 0.002 seconds."
            _, result, _ = self.run_command(directory, "print(" + repr(log) + ")")
            self.assertIsNone(result["test_counts"])

    def test_present_swift_testing_skip_event_is_not_assumed_zero(self):
        # Swift Testing's passing footer alone does not inventory skip events.
        with tempfile.TemporaryDirectory() as directory:
            log = "Test Suite 'Selected tests' passed at now.\n Executed 2 tests, with 0 failures (0 unexpected) in 0.1 seconds\n↷ Test optionalCheck() skipped.\n✔ Test run with 3 tests passed after 0.002 seconds."
            _, result, _ = self.run_command(directory, "print(" + repr(log) + ")")
            self.assertIsNone(result["test_counts"])

    def test_cache_identity_distinguishes_sdk(self):
        self.assertTrue(RUNNER.is_file())
        with tempfile.TemporaryDirectory() as directory:
            identities = []
            for sdk in ('macosx', 'iphonesimulator'):
                output = Path(directory) / sdk
                process = subprocess.run([sys.executable, str(RUNNER), '--scenario', 'sdk', '--sdk', sdk,
                    '--output', str(output), '--', sys.executable, '-c', 'pass'], capture_output=True)
                self.assertEqual(process.returncode, 0, process.stderr)
                result = json.loads((output / 'result.json').read_text())
                self.assertEqual(result['cache']['sdk'], sdk)
                identities.append(result['cache_identity'])
            self.assertNotEqual(identities[0], identities[1])

    def test_counts_separate_xctest_processes_without_losing_selected_tests(self):
        # SwiftPM runs multiple test bundles; later empty bundles cannot erase totals.
        with tempfile.TemporaryDirectory() as directory:
            log = "Test Suite 'Selected tests' passed at now.\n Executed 3 tests, with 1 failure (0 unexpected) in 0.1 seconds\nTest Suite 'Selected tests' passed at now.\n Executed 0 tests, with 0 failures (0 unexpected) in 0.1 seconds\nTest Suite 'Selected tests' passed at now.\n Executed 2 tests, with 0 failures (0 unexpected) in 0.1 seconds"
            _, result, _ = self.run_command(directory, "print(" + repr(log) + ")")
            self.assertEqual(result["test_counts"], {"executed": 5, "failures": 1, "skipped": 0})

    def test_recognizes_python_unittest_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            _, result, _ = self.run_command(directory, "print('Ran 4 tests in 0.2s\\nOK (skipped=1)')")
            self.assertEqual(result["test_counts"], {"executed": 4, "failures": 0, "skipped": 1})

    def test_search_wrapper_builds_release_once_and_records_each_warmup(self):
        # Rebuilding per dataset, dropping warmups, or losing provenance breaks this test.
        with tempfile.TemporaryDirectory() as directory:
            tools = Path(directory) / "bin"
            tools.mkdir()
            records = Path(directory) / "records.jsonl"
            rtk = tools / "rtk"
            rtk.write_text('#!/bin/bash\nif [[ "$1" == proxy ]]; then shift; fi\nexec "$@"\n')
            swift = tools / "swift"
            swift.write_text("#!/usr/bin/env python3\nimport json, os, sys\nfrom pathlib import Path\na=sys.argv[1:]\nif a == ['--version']: print('test Swift')\nelif '--show-bin-path' in a: print(os.environ['FAKE_BIN'])\nelse:\n with open(os.environ['FAKE_RECORDS'], 'a') as f: f.write(json.dumps({'build': a})+'\\n')\n")
            benchmark = tools / "PlainpostSearchBenchmark"
            benchmark.write_text("#!/usr/bin/env python3\nimport json, os, sys\nwith open(os.environ['FAKE_RECORDS'], 'a') as f: f.write(json.dumps({'benchmark': sys.argv[1:], 'sha': os.environ.get('PLAINPOST_BENCH_SOURCE_SHA'), 'toolchain': os.environ.get('PLAINPOST_BENCH_TOOLCHAIN'), 'command': os.environ.get('PLAINPOST_BENCH_COMMAND_ARGUMENTS')})+'\\n')\n")
            for executable in (rtk, swift, benchmark):
                executable.chmod(0o700)
            output_directory = Path(directory) / 'output'
            output_directory.mkdir()
            protected_source = output_directory / 'provenance.json'
            protected_source.write_bytes(b'protected source content')
            environment = dict(os.environ, PLAINPOST_BENCH_SOURCE_DB=str(protected_source), PATH=str(tools) + os.pathsep + os.environ['PATH'], FAKE_BIN=str(tools), FAKE_RECORDS=str(records), PLAINPOST_BENCH_SCRATCH_PATH=str(Path(directory) / 'release-cache'))
            process = subprocess.run(['bash', str(RUNNER.with_name('benchmark-mail-search.sh')), '--synthetic-all', '--output-directory', str(Path(directory) / 'output')], env=environment, capture_output=True, text=True)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(protected_source.read_bytes(), b'protected source content')
            events = [json.loads(line) for line in records.read_text().splitlines()]
            builds = [event for event in events if 'build' in event]
            workloads = [event for event in events if 'benchmark' in event]
            self.assertEqual(len(builds), 1)
            self.assertEqual(builds[0]['build'], ['build', '-c', 'release', '--scratch-path', str(Path(directory) / 'release-cache'), '--product', 'PlainpostSearchBenchmark'])
            self.assertEqual(len(workloads), 3)
            for event, size in zip(workloads, ('10000', '50000', '100000')):
                arguments = event['benchmark']
                self.assertEqual(arguments[arguments.index('--messages') + 1], size)
                self.assertEqual(arguments[arguments.index('--warmups') + 1], '3')
                self.assertEqual(len(event['sha']), 40)
                self.assertIn('test Swift', event['toolchain'])
                self.assertEqual(json.loads(event['command'])[1:], arguments)

    def test_preserves_first_dirty_path_and_source_sha(self):
        # Trimming porcelain's leading status columns would truncate the path.
        self.assertTrue(RUNNER.is_file())
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory) / "repo"
            repository.mkdir()
            subprocess.run(["git", "init", "-q", str(repository)], check=True)
            (repository / "example.txt").write_text("original")
            subprocess.run(["git", "-C", str(repository), "add", "example.txt"], check=True)
            subprocess.run(["git", "-C", str(repository), "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"], check=True)
            (repository / "example.txt").write_text("edited")
            output = Path(directory) / "measurement"
            process = subprocess.run([sys.executable, str(RUNNER.resolve()), "--scenario", "dirty",
                "--output", str(output), "--", sys.executable, "-c", "pass"], cwd=repository, capture_output=True)
            self.assertEqual(process.returncode, 0)
            result = json.loads((output / "result.json").read_text())
            self.assertEqual(result["dirty_paths"], ["example.txt"])
            self.assertEqual(len(result["source_sha"]), 40)

    def test_signal_is_recorded_and_returned_as_shell_status(self):
        with tempfile.TemporaryDirectory() as directory:
            process, result, _ = self.run_command(directory, "import os, signal; os.kill(os.getpid(), signal.SIGTERM)")
            self.assertEqual(result["exit_code"], -15)
            self.assertEqual(process.returncode, 143)

    def test_missing_executable_retains_failure_artifacts(self):
        self.assertTrue(RUNNER.is_file(), "measurement runner must exist")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "measurement"
            process = subprocess.run([sys.executable, str(RUNNER), "--scenario", "missing",
                "--output", str(output), "--", str(Path(directory) / "absent")], capture_output=True)
            self.assertEqual(process.returncode, 127)
            self.assertEqual(json.loads((output / "result.json").read_text())["exit_code"], 127)
            self.assertIn("FileNotFoundError", (output / "command.log").read_text())


if __name__ == "__main__":
    unittest.main()
