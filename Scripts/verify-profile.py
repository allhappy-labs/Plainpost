#!/usr/bin/env python3
"""Named local verification tiers with retained evidence and fail-closed counts."""
import argparse
import json
from pathlib import Path
import re
import platform
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
MEASURE = ROOT / "Scripts/measure-dev-iteration.py"
sys.path.insert(0, str(ROOT / "Scripts/lib"))
import build_artifacts
import profile_fixtures

SIMULATOR = "255CC905-D572-4265-BC8D-8AA213092084"
SWIFT = ["rtk", "proxy", "swift", "test", "--scratch-path", str(ROOT / ".build")]


def swift_profile(targets):
    selection = "^(?:" + "|".join(targets) + r")\."
    return {"kind": "swift", "prerequisites": ["rtk", "swift", "xcodebuild"],
            "required_targets": targets,
            "selection": selection, "discovery": SWIFT + ["list"],
            "command": SWIFT + ["--filter", selection]}


PROFILES = {
    "calendar": {"kind": "swift-target", "target": "PlainpostCalendarPresentationTests",
                 "prerequisites": ["swift", "xcrun", "xcodebuild"],
                 "selection": r"^PlainpostCalendarPresentationTests\.",
                 "required_targets": ["PlainpostCalendarPresentationTests"]},
    "core": swift_profile(["PlainpostCoreTests", "PlainpostAITests", "PlainpostAccountProtocolTests"]),
    "db": swift_profile(["PlainpostDBTests", "PlainpostSearchBenchmarkTests"]),
    "ui": swift_profile(["PlainpostUITests", "PlainpostAppTests"]),
    "service": swift_profile(["PlainpostServiceTests", "PlainpostServiceIPCTests", "PlainpostOperationsTests", "PlainpostAccountRuntimeTests", "PlainpostNotificationRuntimeTests", "PlainpostNodeTransportTests", "PlainpostNodeMailModeTests", "PlainpostLocalAPITests", "PlainpostBrowserBridgeTests", "PlainpostSecretsTests", "PlainpostRootAuthorityTests"]),
    "integration": swift_profile(["PlainpostIntegrationTests", "PlainpostCLITests"]),
    "ios": {"kind": "xcode", "prerequisites": ["rtk", "xcodebuild", "xcrun"],
            "selection": ["PlainpostUITests/PlainpostUITests/" + name for name in [
                "testDebugMailboxAcceptanceShowsRealMailRootAndAccountSecurity",
                "testMultiAccountHeaderLeavesNavigationBarActionsReachableForEachAccount",
                "testMultiAccountSwitchShowsNewAccountInboxAndRoutesActionsToIt",
                "testNotificationSettingsUseDeviceCopyOnCompactIPhone",
                "testReplyComposerBlankBodyTapAcceptsTyping"]]},
}


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")
    path.chmod(0o600)


def measure(command, output, scenario, selection="unavailable", sdk="macosx", cache=None, fixture_inputs=None, fixture_admission=None):
    argv = [sys.executable, str(MEASURE), "--scenario", scenario, "--output", str(output),
            "--cache-state", "unknown", "--build-mode", "Debug", "--sdk", sdk,
            "--cache-path", str(cache or ROOT / ".build"), "--selected-tests", str(selection)]
    if fixture_inputs is not None:
        argv += ["--fixture-inputs", str(fixture_inputs), "--fixture-admission", str(fixture_admission)]
    argv += ["--"] + command
    subprocess.run(argv, cwd=ROOT, check=False, env=build_artifacts.safe_environment())
    return json.loads((output / "result.json").read_text())


def swift_inventory(log, selection):
    identifiers = {line.strip() for line in log.splitlines()
                   if re.fullmatch(r"(?:[\w.]+/[\w().,:<> ]+|[\w.]+\([^\n]*\))", line.strip())}
    return sorted(identifier for identifier in identifiers if re.search(selection, identifier))


def xcode_counts(summary):
    keys = ["totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures"]
    if any(type(summary.get(key)) is not int or summary[key] < 0 for key in keys):
        raise ValueError("missing or invalid structured Xcode test counts")
    if summary["totalTestCount"] != sum(summary[key] for key in keys[1:]):
        raise ValueError("inconsistent structured Xcode test counts")
    return {"executed": summary["totalTestCount"] - summary["skippedTests"],
            "failures": summary["failedTests"], "skipped": summary["skippedTests"]}


def xcode_inventory(value):
    return sorted({line.strip().removesuffix("()") for line in value.splitlines()
                   if re.fullmatch(r"[\w.]+/[\w.]+/[\w]+\(\)", line.strip())})


def run_target_profile(name, output, profile):
    """Swift 6.4 target builds its own XCTest bundle; no aggregate test build."""
    cache = ROOT / ".build"
    if shutil.disk_usage(ROOT).free < 15 * 1024 ** 3:
        return {"profile": name, "status": "unavailable", "reason": "less than 15 GiB free; build allocation refused"}
    identity = build_artifacts.compatibility(ROOT, "macosx", "Debug", "adhoc", platform.machine())
    inputs = build_artifacts.source_inputs(ROOT, cache)
    build = measure(SWIFT[:3] + ["build", "--scratch-path", str(cache), "--target", profile["target"], "-v"],
                    output / "build", name + "-build")
    if build["exit_code"]:
        return {"profile": name, "status": "failed", "reason": "target build failed", "build": build}
    products = build_artifacts.swift_product_directory(ROOT, cache, "Debug")
    bundle = products / (profile["target"] + ".xctest")
    receipt = build_artifacts.make_receipt(ROOT, cache, identity, inputs, {"tests": bundle})
    build_artifacts.write_receipt(output / "build-receipt.json", receipt)
    developer = Path(build_artifacts.tool_output("xcode-select", "-p"))
    helper = developer / "Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-xctest-helper"
    inventory_path = output / "inventory.json"
    discovery = measure(["rtk", "proxy", "env", "-i", "PATH=/usr/bin:/bin", str(helper), str(bundle), str(inventory_path)],
                        output / "discovery", name + "-discovery")
    result = {"profile": name, "build": build, "discovery": discovery, "status": "failed"}
    if discovery["exit_code"]:
        return dict(result, reason="target bundle discovery failed")
    def identifiers(node, parent=""):
        if "tests" not in node:
            return [parent + "/" + node["name"]]
        return [item for child in node["tests"] for item in identifiers(child, node["name"])]
    selected = sorted(identifiers(json.loads(inventory_path.read_text())))
    expected = swift_inventory("\n".join(selected), profile["selection"])
    if not selected or selected != expected:
        return dict(result, reason="target discovery contains missing or unexpected cases")
    build_artifacts.verify_receipt(ROOT, receipt, identity)
    execution = measure(["rtk", "proxy", "env", "-i", "PATH=/usr/bin:/bin", str(developer / "usr/bin/xctest"), str(bundle)],
                        output / "execution", name + "-execution", selection=selected)
    counts = execution["test_counts"]
    raw = Path(execution["artifacts"]["log"]).read_text()
    passed = re.findall(r"Test Case '-\[([^ ]+) ([^]]+)\]' passed", raw)
    actual = sorted(owner + "/" + method for owner, method in passed)
    result.update(selected_tests=selected, execution=execution, test_counts=counts)
    if execution["exit_code"] or not counts or counts["failures"] or (counts["skipped"] or 0) or actual != selected:
        return dict(result, reason="target execution does not exactly match discovery")
    build_artifacts.verify_receipt(ROOT, receipt, identity)
    return dict(result, status="passed", reason="source-bound target bundle passed exact discovery")


def run_profile(name, output, *, profiles=PROFILES, fixture_inputs=None):
    profile = profiles[name]
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    result = {"profile": name, "contract": profile, "status": "failed", "selected_tests": []}
    def finish(status, reason):
        result.update(status=status, reason=reason)
        save(output / "profile.json", result)
        return result
    fixture_options = {}
    if fixture_inputs is not None:
        record = output / "fixture-admission.json"
        result["fixture_admission"] = profile_fixtures.admit(fixture_inputs, name, record)
        fixture_options = {"fixture_inputs": fixture_inputs, "fixture_admission": record}
    missing = [tool for tool in profile["prerequisites"] if shutil.which(tool) is None]
    if missing:
        return finish("unavailable", "missing prerequisite: " + ", ".join(missing))
    if profile["kind"] == "swift-target":
        result = run_target_profile(name, output, profile)
        save(output / "profile.json", result)
        return result
    if profile["kind"] == "xcode":
        cache = ROOT / ".build/verification-ios-debug"
        readiness_command = ["xcrun", "simctl", "bootstatus", SIMULATOR]
        try:
            readiness = subprocess.run(readiness_command, cwd=ROOT, capture_output=True, text=True, timeout=30)
            (output / "simulator-readiness.log").write_text(readiness.stdout + readiness.stderr)
            result["prerequisite"] = {"command": readiness_command, "exit_code": readiness.returncode}
            if readiness.returncode != 0:
                return finish("unavailable", "QA simulator boot readiness failed")
        except subprocess.TimeoutExpired as error:
            (output / "simulator-readiness.log").write_bytes((error.stdout or b"") + (error.stderr or b"") + b"QA simulator boot readiness timed out after 30 seconds\n")
            result["prerequisite"] = {"command": readiness_command, "timeout_seconds": 30}
            return finish("unavailable", "QA simulator boot readiness timed out; no test execution claimed")
        if shutil.disk_usage(ROOT).free < 15 * 1024 ** 3:
            return finish("unavailable", "less than 15 GiB free; build allocation refused")
        common = ["rtk", "proxy", "xcodebuild", "-project", str(ROOT / "Apps/PlainpostiOS/Plainpost.xcodeproj"),
                  "-scheme", "Plainpost", "-derivedDataPath", str(cache), "-destination", "id=" + SIMULATOR]
        build = measure(common + ["build-for-testing"], output / "build", name + "-build", sdk="iphonesimulator", cache=cache)
        result["build"] = build
        if build["exit_code"] != 0:
            return finish("failed", "build-for-testing failed")
        runs = sorted((cache / "Build/Products").glob("*.xctestrun"))
        if len(runs) != 1:
            return finish("unavailable", "expected one current xctestrun from build-for-testing")
        owner = ["rtk", "proxy", "xcodebuild", "test-without-building", "-xctestrun", str(runs[0]),
                 "-destination", "id=" + SIMULATOR, "-parallel-testing-enabled", "NO"]
        inventory_path = output / "inventory.txt"
        discovery = measure(owner + ["-enumerate-tests", "-test-enumeration-style", "flat", "-test-enumeration-format", "text",
                                     "-test-enumeration-output-path", str(inventory_path)], output / "discovery", name + "-discovery", sdk="iphonesimulator", cache=cache)
        result["discovery"] = discovery
        if discovery["exit_code"] != 0 or not inventory_path.exists():
            return finish("failed", "Xcode test discovery failed")
        inventory = xcode_inventory(inventory_path.read_text())
        selected = profile["selection"]
        if set(selected) - set(inventory):
            result["missing_tests"] = sorted(set(selected) - set(inventory))
            return finish("failed", "selected Xcode tests missing from current inventory")
        command = owner + ["-resultBundlePath", str(output / "tests.xcresult")] + ["-only-testing:" + test for test in selected]
    else:
        discovery = measure(profile["discovery"], output / "discovery", name + "-discovery")
        result["discovery"] = discovery
        if discovery["exit_code"] != 0:
            return finish("failed", "current-build Swift test discovery failed")
        selected = swift_inventory(Path(discovery["artifacts"]["log"]).read_text(), profile["selection"])
        result["missing_targets"] = [target for target in profile.get("required_targets", [])
                                     if not any(test.startswith(target + ".") for test in selected)]
        if result["missing_targets"]:
            return finish("failed", "selected target missing from current-build inventory")
        command = profile["command"]
    result["selected_tests"] = selected
    if not selected:
        return finish("failed", "zero selected tests in current-build inventory")
    if profile["kind"] == "xcode":
        execution = measure(command, output / "execution", name + "-execution", selection=selected,
                            sdk="iphonesimulator", cache=cache)
    else:
        execution = measure(command, output / "execution", name + "-execution", selection=selected, **fixture_options)
    result["execution"] = execution
    counts = execution["test_counts"]
    if profile["kind"] == "xcode":
        summary_command = ["rtk", "proxy", "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(output / "tests.xcresult")]
        summary = subprocess.run(summary_command, cwd=ROOT, capture_output=True, text=True)
        (output / "xcresult-summary.log").write_text(summary.stdout + summary.stderr)
        try:
            if summary.returncode != 0:
                raise ValueError("xcresulttool failed")
            structured = json.loads(summary.stdout)
            save(output / "xcresult-summary.json", structured)
            counts = xcode_counts(structured)
            if structured["result"] != "Passed" or structured["expectedFailures"]:
                return finish("failed", "Xcode outcome includes failure or expected failure")
        except (ValueError, KeyError) as error:
            return finish("failed", str(error))
    result["test_counts"] = counts
    if execution["exit_code"] != 0:
        return finish("failed", "test command failed; raw log retained")
    if counts is None or counts["executed"] <= 0:
        return finish("failed", "zero or unavailable executed-test inventory")
    if counts["executed"] < len(selected):
        return finish("failed", "fewer executed tests than discovered selection")
    if profile["kind"] == "swift":
        log = Path(execution["artifacts"]["log"]).read_text()
        # XCTest's aggregate total includes skips; the measurement count contract
        # deliberately reports unknown skips. Keep individual skipped cases red.
        if re.search(r"Test Case .* skipped|Test .* skipped", log):
            return finish("failed", "skipped tests require investigation")
    if counts["failures"] or (counts["skipped"] or 0):
        return finish("failed", "test failures or skipped tests require investigation")
    return finish("passed", "nonzero selection and execution verified")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True, choices=PROFILES)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--fixture-inputs", type=Path, help="private closed local-fixture descriptor (service/integration only)")
    args = parser.parse_args()
    try:
        result = run_profile(args.profile, args.output, fixture_inputs=args.fixture_inputs)
    except (OSError, ValueError) as error:
        parser.exit(1, str(error) + "\n")
    print(json.dumps({key: result[key] for key in ("profile", "status", "reason")}))
    return {"passed": 0, "failed": 1, "unavailable": 2}[result["status"]]


if __name__ == "__main__":
    sys.exit(main())
