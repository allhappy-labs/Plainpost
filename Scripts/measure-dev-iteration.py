#!/usr/bin/env python3
"""Retain raw command evidence and provenance; never invoke a shell.

Logs and argv are private local artifacts: use synthetic fixtures and never pass
credentials in arguments. This runner does not redact arbitrary child output.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import build_artifacts
import profile_fixtures


def probe(command, cwd):
    try:
        result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=15,
                                env=build_artifacts.safe_environment())
        return {"command": command, "exit_code": result.returncode,
                "output": result.stdout + result.stderr}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"command": command, "exit_code": None, "output": str(error)}


def test_counts(log):
    # XCTest's executed total includes skipped cases. Only complete top-level
    # engine summaries are additive; nested suites repeat those totals.
    summary_pattern = re.compile(
        r"\s*Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?"
        r"(\d+) failures? \(\d+ unexpected\) in \d+(?:\.\d+)?"
        r"(?: \(\d+(?:\.\d+)?\))? seconds[ \t]*"
    )
    lines = log.splitlines()
    summaries = []
    pending = None
    top_level_seen = False
    for index, line in enumerate(lines):
        if not re.match(r"^Test Suite '(?:Selected tests|All tests)'", line):
            continue
        top_level_seen = True
        event = re.fullmatch(r"Test Suite '(Selected tests|All tests)' (started|passed|failed) at .+", line)
        if event is None:
            return None
        suite, state = event.groups()
        if state == "started":
            if pending is not None:
                return None  # An overlapping/nested engine cannot be summed safely.
            pending = suite
            continue
        if pending is not None and pending != suite:
            return None
        summary = summary_pattern.fullmatch(lines[index + 1]) if index + 1 < len(lines) else None
        if summary is None:
            return None
        summaries.append(summary.groups())
        pending = None
    if pending is not None:
        return None
    if not top_level_seen:
        # Legacy logs containing only nested footer rows expose only the last
        # aggregate. Refuse unknown rows instead of retaining a partial total.
        bare = [line for line in lines if re.match(r"^\s*Executed\b", line)]
        parsed = [summary_pattern.fullmatch(line) for line in bare]
        if any(summary is None for summary in parsed):
            return None
        summaries = [parsed[-1].groups()] if parsed else []
    counts = None
    if summaries:
        if any(int(skipped or 0) > int(executed) for executed, skipped, _ in summaries):
            return None
        counts = {"executed": sum(int(executed) for executed, _, _ in summaries),
                  "failures": sum(int(failures) for _, _, failures in summaries),
                  "skipped": sum(int(skipped or 0) for _, skipped, _ in summaries)}

    # Swift Testing runs independently of XCTest. Its suite/case summaries are
    # nested, while each "Test run" footer is one authoritative engine total.
    swift_footers = [line for line in log.splitlines() if re.search(r"\bTest run with\b", line)]
    swift_starts = len(re.findall(r"\bTest run started\b", log))
    swift_skips = re.search(r"^[^\w\n]*(?:Test(?! Case\b| Suite\b)|Suite(?! ')) .+\bskipped\b", log, re.MULTILINE)
    if swift_skips:
        return None  # A passing Swift Testing footer does not inventory skips.
    if swift_footers or swift_starts:
        passed = re.findall(
            r"^[^\w\n]*Test run with (\d+) tests?(?: in \d+ suites?)? passed after \d+(?:\.\d+)? seconds\.[ \t]*$",
            log, re.MULTILINE,
        )
        # A failed footer reports issues, not failed test cases. An incomplete
        # or unknown footer also cannot supply a complete mixed-engine inventory.
        if len(passed) != len(swift_footers) or swift_starts > len(passed):
            return None
        swift_count = sum(int(executed) for executed in passed)
        if counts is None:
            counts = {"executed": swift_count, "failures": 0, "skipped": 0}
        else:
            counts["executed"] += swift_count
    if counts is not None:
        return counts
    python = re.findall(r"^Ran (\d+) tests? in .+$", log, re.MULTILINE)
    outcome = re.findall(r"^(OK|FAILED)(?: \(([^\n]*)\))?$", log, re.MULTILINE)
    if python and outcome:
        state, details = outcome[-1]
        values = dict(re.findall(r"(failures|errors|skipped)=(\d+)", details))
        if state == "FAILED" and not any(key in values for key in ("failures", "errors")):
            return None
        return {"executed": int(python[-1]),
                "failures": int(values.get("failures", 0)) + int(values.get("errors", 0)),
                "skipped": int(values.get("skipped", 0))}
    return None


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--cache-path", type=Path)
    parser.add_argument("--cache-state", choices=("warm", "cold", "unknown"), default="unknown")
    parser.add_argument("--build-mode", default="unavailable")
    parser.add_argument("--sdk", default="macosx" if sys.platform == "darwin" else "unavailable")
    parser.add_argument("--fixture-size", type=int)
    parser.add_argument("--selected-tests", default="unavailable")
    parser.add_argument("--fixture-inputs", type=Path)
    parser.add_argument("--fixture-admission", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    command = arguments.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("a command is required after --")
    if (arguments.fixture_inputs is None) != (arguments.fixture_admission is None):
        parser.error("fixture descriptor and admission must be supplied together")
    cwd = Path.cwd().resolve()
    output = arguments.output.resolve()
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    if any((output / name).exists() for name in ("command.log", "result.json")):
        parser.error("output already contains measurement artifacts; choose a fresh directory")
    source = probe(["git", "rev-parse", "HEAD"], cwd)
    dirty = probe(["git", "status", "--porcelain=v1", "-z"], cwd)
    dirty_paths = []
    entries = dirty["output"].split("\0")
    index = 0
    while index < len(entries):
        entry = entries[index]
        if len(entry) >= 4:
            dirty_paths.append(entry[3:])
            if "R" in entry[:2] or "C" in entry[:2]:
                index += 1
                if index < len(entries) and entries[index]:
                    dirty_paths.append(entries[index])
        index += 1
    toolchain = {"python": sys.version, "swift": probe(["swift", "--version"], cwd),
                 "xcode": probe(["xcodebuild", "-version"], cwd)}
    cache_path = arguments.cache_path
    if cache_path is None:
        for flag in ("--scratch-path", "-derivedDataPath"):
            if flag in command and command.index(flag) + 1 < len(command):
                cache_path = Path(command[command.index(flag) + 1])
                break
    cache_path = (cache_path or cwd / ".build").resolve()
    cache_description = {"path": str(cache_path), "exists_at_start": cache_path.exists(),
                         "toolchain": toolchain, "build_mode": arguments.build_mode,
                         "sdk": arguments.sdk, "architecture": platform.machine(),
                         "signing_arguments": [value for value in command if value.startswith(("CODE_SIGN", "DEVELOPMENT_TEAM=", "PROVISIONING_PROFILE"))]}
    cache_identity = hashlib.sha256(json.dumps(cache_description, sort_keys=True).encode()).hexdigest()
    start = timestamp()
    clock = time.monotonic()
    log_path = output / "command.log"
    fixture = None
    fixture_status = None
    child_exit_code = None
    with log_path.open("xb") as log:
        os.chmod(log_path, 0o600)
        try:
            child_environment = None  # Preserve standalone non-fixture benchmark inputs.
            if arguments.fixture_inputs is not None:
                fixture = profile_fixtures.Execution(arguments.fixture_inputs, arguments.fixture_admission)
                child_environment = build_artifacts.safe_environment()
                child_environment.update(fixture.start())
                fixture_status = {"slots": sorted(fixture.admission["slots"]),
                                  "keys": sorted(fixture.environment), "status": "admitted"}
            process = subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT,
                                     shell=False, env=child_environment)
            exit_code = child_exit_code = process.returncode
        except (OSError, ValueError) as error:
            # Validation messages never include document contents or environment values.
            log.write(f"{type(error).__name__}: {error}\n".encode())
            exit_code = 127 if isinstance(error, FileNotFoundError) else 126
            if arguments.fixture_inputs is not None:
                fixture_status = {"status": "failed"}
        finally:
            if fixture is not None and fixture.marker_identity is not None:
                try:
                    fixture.finish()
                    if fixture_status and fixture_status["status"] == "admitted":
                        fixture_status["status"] = "verified"
                except (OSError, ValueError) as error:
                    log.write(f"Fixture post-execution validation failed: {error}\n".encode())
                    exit_code = 126
                    fixture_status = {"status": "failed"}
    end = timestamp()
    duration = time.monotonic() - clock
    counts = test_counts(log_path.read_text(errors="replace"))
    result = {"format_version": 1, "source_sha": source["output"].strip() if source["exit_code"] == 0 else None,
              "dirty_paths": dirty_paths if dirty["exit_code"] == 0 else None,
              "machine": {"architecture": platform.machine(), "os": platform.platform(), "processor_count": os.cpu_count()},
              "toolchain": toolchain, "scenario": arguments.scenario, "cache_identity": cache_identity,
              "cache": cache_description, "cache_state": arguments.cache_state,
              "build_mode": arguments.build_mode, "fixture_size": arguments.fixture_size,
              "selected_tests": arguments.selected_tests, "command": command, "working_directory": str(cwd),
              "start_time": start, "end_time": end, "duration_seconds": duration, "exit_code": exit_code,
              "child_exit_code": child_exit_code, "fixture_inputs": fixture_status,
              "test_counts": counts, "test_count_status": "recognized" if counts is not None else "unavailable",
              "artifacts": {"log": str(log_path), "result": str(output / "result.json")}}
    result_path = output / "result.json"
    with result_path.open("x") as file:
        os.chmod(result_path, 0o600)
        json.dump(result, file, indent=2)
        file.write("\n")
    print(json.dumps({"scenario": arguments.scenario, "exit_code": exit_code,
                      "duration_seconds": duration, "result": str(result_path)}))
    return 128 - exit_code if exit_code < 0 else exit_code


if __name__ == "__main__":
    sys.exit(main())
