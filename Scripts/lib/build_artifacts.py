#!/usr/bin/env python3
"""Source-bound local build artifacts; never records ambient environment values."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import platform
import re
import shutil
import subprocess
import sys

ENVIRONMENT_KEYS = ("PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT", "LANG", "LC_ALL", "CLANG_MODULE_CACHE_PATH")
INPUT_DIRECTORIES = ("Sources", "Tests", "Apps", "Config", "Support", "Tools", "Scripts", "Plainpost.xcodeproj")


def safe_environment(environment=None):
    source = os.environ if environment is None else environment
    return {key: source[key] for key in ENVIRONMENT_KEYS if key in source}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def stable_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def tool_output(*command):
    result = subprocess.run(command, capture_output=True, text=True, check=True, env=safe_environment())
    return result.stdout.strip()


def compatibility(root, sdk, configuration, signing, architecture, toolchain=None):
    if toolchain is None:
        toolchain = {"swift": tool_output("xcrun", "swift", "--version"),
                     "xcode": tool_output("xcodebuild", "-version"),
                     "sdk_path": tool_output("xcrun", "--sdk", sdk, "--show-sdk-path"),
                     "sdk_version": tool_output("xcrun", "--sdk", sdk, "--show-sdk-version"),
                     "sdk_build": tool_output("xcrun", "--sdk", sdk, "--show-sdk-build-version")}
    return {"owner": str(Path(root).resolve()), "sdk": sdk, "configuration": configuration,
            "signing": signing, "architecture": architecture, "toolchain": toolchain}


def cache_key(identity):
    return digest(stable_json(identity))[:20]


def source_inputs(root, cache=None):
    root = Path(root).resolve()
    cache = Path(cache).resolve() if cache else root / ".build"
    candidates = [root / "Package.swift", root / "Package.resolved"]
    directories = [root / name for name in INPUT_DIRECTORIES]
    directories += [root / ".build/checkouts", Path(cache) / "checkouts" if cache else root / ".build/checkouts", Path(cache) / "SourcePackages/checkouts" if cache else root / ".build/SourcePackages/checkouts"]
    links = {}
    for base in directories:
        if not base.exists():
            continue
        for directory, children, files in os.walk(base, followlinks=False):
            children[:] = [name for name in children if name not in {".git", ".build", "__pycache__", "xcuserdata"}]
            for name in children:
                link = Path(directory) / name
                if link.is_symlink():
                    if not link.resolve(strict=True).is_relative_to(base.resolve()):
                        raise ValueError("source directory link escapes its input tree")
                    # Its target is independently walked in this input tree; do not follow cycles.
                    links[link] = digest(stable_json({"link": os.readlink(link)}))
            candidates.extend(Path(directory) / name for name in files if name != ".DS_Store")
    result = {}
    def input_key(path):
        return str(path.relative_to(root)) if path.is_relative_to(root) else "@cache/" + str(path.relative_to(cache))
    for path, value in links.items():
        result[input_key(path)] = value
    for path in sorted(set(candidates)):
        if path.is_file():
            if path.is_symlink():
                raise ValueError("source input symlink requires explicit ownership")
            result[input_key(path)] = digest(path.read_bytes())
    return result


def artifact_hash(path, allowed_root):
    path, allowed_root = Path(path), Path(allowed_root).resolve()
    if path.is_symlink() or not path.exists() or not path.resolve().is_relative_to(allowed_root):
        raise ValueError("unsafe or missing build product")
    if path.is_file():
        return digest(path.read_bytes())
    entries = {}
    for item in sorted(path.rglob("*")):
        relative = str(item.relative_to(path))
        if item.is_symlink():
            if not item.resolve(strict=True).is_relative_to(path.resolve()):
                raise ValueError("bundle link escapes its product")
            entries[relative] = {"link": os.readlink(item)}
        elif item.is_file():
            entries[relative] = digest(item.read_bytes())
    if not entries:
        raise ValueError("empty build product")
    return digest(stable_json(entries))


def make_receipt(root, cache, identity, before, artifacts):
    if before != source_inputs(root, cache):
        raise ValueError("build inputs changed during compilation")
    if not artifacts:
        raise ValueError("no build products")
    products = {role: {"path": str(Path(path).absolute()), "sha256": artifact_hash(path, cache)} for role, path in artifacts.items()}
    return {"format": 1, "identity": identity, "inputs": before, "cache": str(Path(cache).resolve()), "products": products}


def verify_receipt(root, receipt, identity, runner_backup=None):
    if receipt["identity"] != identity or receipt["identity"]["owner"] != str(Path(root).resolve()):
        raise ValueError("build compatibility or owner changed")
    if receipt["inputs"] != source_inputs(root, receipt["cache"]):
        raise ValueError("build inputs changed; rebuild required")
    products = {}
    for role, item in receipt["products"].items():
        path = Path(item["path"])
        if artifact_hash(path, receipt["cache"]) != item["sha256"]:
            if role != "xctestrun" or runner_backup is None:
                raise ValueError("build product changed; rebuild required")
            backup = Path(runner_backup)
            hash_file = Path(str(backup) + ".sha256")
            if backup != path.with_name(path.name + ".plainpost-backup") or backup.is_symlink() or hash_file.is_symlink():
                raise ValueError("unexpected runner backup")
            if (backup.stat().st_mode & 0o777) != 0o600 or (hash_file.stat().st_mode & 0o777) != 0o600:
                raise ValueError("runner recovery permissions changed")
            if artifact_hash(backup, receipt["cache"]) != item["sha256"] or hash_file.read_text().strip() != item["sha256"]:
                raise ValueError("runner backup does not match the built artifact")
            def without_environment(value):
                if isinstance(value, dict):
                    return {key: without_environment(child) for key, child in value.items()
                            if key not in {"EnvironmentVariables", "TestingEnvironmentVariables"}}
                if isinstance(value, list): return [without_environment(child) for child in value]
                return value
            if without_environment(plistlib.loads(path.read_bytes())) != without_environment(plistlib.loads(backup.read_bytes())):
                raise ValueError("injection changed runner product or test structure")
        products[role] = path
    return products


def discover_xctestrun(products, scheme, sdk_version, architecture, expected_targets):
    products = Path(products).resolve()
    # Xcode's current SDK/architecture runner, never the first or newest glob result.
    expected = products / f"{scheme}_iphonesimulator{sdk_version}-{architecture}.xctestrun"
    candidates = [p for p in products.glob(f"{scheme}_*.xctestrun") if p.name == expected.name]
    if len(candidates) != 1 or candidates[0].is_symlink():
        raise ValueError("one current SDK/architecture test runner is required")
    run = candidates[0]
    value = plistlib.loads(run.read_bytes())
    if re.search(r"PLAINPOST_(E2E|VISUAL)_[A-Z0-9_]+", repr(value)):
        raise ValueError("test runner contains injected environment")
    if "TestConfigurations" in value:
        targets = [target for config in value["TestConfigurations"] for target in config.get("TestTargets", [])]
    else:
        targets = [dict(target, BlueprintName=target.get("BlueprintName", name))
                   for name, target in value.items() if isinstance(target, dict) and "TestBundlePath" in target]
    names = [target.get("BlueprintName") for target in targets]
    if not targets or len(names) != len(set(names)) or not set(expected_targets).issubset(names):
        raise ValueError("test runner target inventory mismatch")
    result = {"xctestrun": run}
    for target in targets:
        host = target.get("TestHostPath", "")
        for field in ("TestBundlePath", "TestHostPath", "UITargetAppPath"):
            if field not in target:
                continue
            raw = target[field].replace("__TESTHOST__", host).replace("__TESTROOT__", str(products))
            if "__" in raw:
                raise ValueError("unresolved test product placeholder")
            path = Path(raw)
            artifact_hash(path, products)
            result[target["BlueprintName"] + ":" + field] = path
    return result


def write_receipt(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ValueError("unsafe receipt path")
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("x") as stream:
        os.chmod(temporary, 0o600)
        json.dump(value, stream, indent=2)
        stream.write("\n")
    temporary.replace(path)


def swift_product_directory(root, cache, configuration):
    directory = Path(tool_output("swift", "build", "--package-path", str(root), "--scratch-path", str(cache),
                                 "--configuration", configuration.lower(), "--show-bin-path"))
    if not directory.resolve().is_relative_to(Path(cache).resolve()):
        raise ValueError("Swift product directory escaped its cache")
    return directory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["cache", "swift-products", "build", "verify"])
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--cache", type=Path)
    parser.add_argument("--purpose", default="build")
    parser.add_argument("--sdk", choices=["macosx", "iphonesimulator"], default="macosx")
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Debug")
    parser.add_argument("--signing", choices=["unsigned", "adhoc", "automatic"], default="unsigned")
    parser.add_argument("--architecture", default=platform.machine())
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--product", action="append", default=[], help="role=path relative to cache")
    parser.add_argument("--scheme")
    parser.add_argument("--expected-target", action="append", default=[])
    parser.add_argument("--role")
    parser.add_argument("--runner-backup", type=Path)
    argv = sys.argv[1:]
    split = argv.index("--") if "--" in argv else len(argv)
    command = argv[split + 1:] if split < len(argv) else []
    args = parser.parse_args(argv[:split])
    root = args.root.resolve()
    identity = compatibility(root, args.sdk, args.configuration, args.signing, args.architecture)
    cache = args.cache or root / ".build/compatible" / (args.purpose + "-" + cache_key(identity))
    if cache.is_symlink():
        raise ValueError("cache root must not be a symlink")
    if args.action == "cache":
        print(cache); return 0
    if args.action == "swift-products":
        print(swift_product_directory(root, cache, args.configuration)); return 0
    if not args.receipt:
        parser.error("--receipt is required")
    if args.action == "verify":
        products = verify_receipt(root, json.loads(args.receipt.read_text()), identity, args.runner_backup)
        if args.role: print(products[args.role])
        return 0
    if shutil.disk_usage(root).free < 15 * 1024 ** 3:
        raise ValueError("less than 15 GiB free; build refused")
    if not command: parser.error("build command is required after --")
    # Dependency resolution must finish before capturing compilation inputs.
    # Otherwise a first build could add uncaptured checkout bytes mid-admission.
    executable_names = [Path(value).name for value in command[:3]]
    if "xcodebuild" in executable_names:
        resolution = [value for value in command if value not in {"build", "build-for-testing"}]
        resolution.append("-resolvePackageDependencies")
        resolved = subprocess.run(resolution, cwd=root, env=safe_environment())
        if resolved.returncode: return resolved.returncode
    elif "swift" in executable_names:
        resolved = subprocess.run(["swift", "package", "--package-path", str(root), "--scratch-path", str(cache), "resolve"],
                                  cwd=root, env=safe_environment())
        if resolved.returncode: return resolved.returncode
    before = source_inputs(root, cache)
    result = subprocess.run(command, cwd=root, env=safe_environment())
    if result.returncode: return result.returncode
    products = {}
    for item in args.product:
        role, relative = item.split("=", 1)
        products[role] = cache / relative
    if args.scheme:
        products.update(discover_xctestrun(cache / "Build/Products", args.scheme,
                        identity["toolchain"]["sdk_version"], args.architecture, args.expected_target))
    write_receipt(args.receipt, make_receipt(root, cache, identity, before, products))
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        # Errors describe the failed contract; never print ambient environment or command output.
        print("Build artifact verification failed: " + type(error).__name__, file=sys.stderr)
        raise SystemExit(1)
