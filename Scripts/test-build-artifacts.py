#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

class BuildArtifactTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("build_artifacts", Path(__file__).parent / "lib/build_artifacts.py")
        cls.api = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.api)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        (self.root / "Sources/Fixture").mkdir(parents=True)
        (self.root / "Sources/Fixture/value.swift").write_text("struct Value {}")
        (self.root / "Package.swift").write_text("fixture manifest")
        self.cache = self.root / ".build/cache"
        self.cache.mkdir(parents=True)
        self.product = self.cache / "Products/Fixture"
        self.product.parent.mkdir()
        self.product.write_bytes(b"current executable")
        self.identity = self.api.compatibility(self.root, "macosx", "Debug", "unsigned", "arm64", {"swift": "6", "sdk": "27"})

    def receipt(self):
        return self.api.make_receipt(self.root, self.cache, self.identity, self.api.source_inputs(self.root), {"fixture": self.product})

    def test_each_compatibility_dimension_and_worktree_has_distinct_key(self):
        baseline = self.api.cache_key(self.identity)
        for key in ("owner", "sdk", "configuration", "signing", "architecture", "toolchain"):
            changed = dict(self.identity, **{key: "different"})
            self.assertNotEqual(baseline, self.api.cache_key(changed), key)

    def test_matching_source_and_binary_can_be_verified(self):
        self.assertEqual(self.api.verify_receipt(self.root, self.receipt(), self.identity)["fixture"], self.product)

    def test_source_change_invalidates_reuse(self):
        receipt = self.receipt()
        (self.root / "Sources/Fixture/value.swift").write_text("struct Changed {}")
        with self.assertRaises(ValueError): self.api.verify_receipt(self.root, receipt, self.identity)

    def test_dependency_and_project_inputs_invalidate_reuse(self):
        for path in ["Package.resolved", "Apps/App.xcodeproj/project.pbxproj", "Config/Debug.xcconfig", ".build/checkouts/Dependency/Sources/D/file.swift"]:
            with self.subTest(path=path):
                receipt = self.receipt()
                p = self.root / path; p.parent.mkdir(parents=True, exist_ok=True); p.write_text("changed input")
                with self.assertRaises(ValueError): self.api.verify_receipt(self.root, receipt, self.identity)

    def test_external_cache_dependency_inputs_are_bound(self):
        with tempfile.TemporaryDirectory() as external:
            cache = Path(external).resolve()
            source = cache / "SourcePackages/checkouts/Dependency/Sources/value.swift"
            source.parent.mkdir(parents=True)
            source.write_text("original dependency")
            product = cache / "Fixture"; product.write_bytes(b"product")
            before = self.api.source_inputs(self.root, cache)
            receipt = self.api.make_receipt(self.root, cache, self.identity, before, {"fixture": product})
            self.assertIn("fixture", self.api.verify_receipt(self.root, receipt, self.identity))
            source.write_text("changed dependency")
            with self.assertRaises(ValueError): self.api.verify_receipt(self.root, receipt, self.identity)

    def test_contained_dependency_directory_link_is_hashed_without_following_cycle(self):
        dependency = self.root / ".build/checkouts/Dependency"
        (dependency / "Tests/Fixture").mkdir(parents=True)
        link = dependency / "Tests/Fixture/Dependency"
        link.symlink_to("../..")
        inputs = self.api.source_inputs(self.root, self.cache)
        self.assertIn(".build/checkouts/Dependency/Tests/Fixture/Dependency", inputs)
        link.unlink(); link.symlink_to(self.root.parent)
        with self.assertRaises(ValueError): self.api.source_inputs(self.root, self.cache)

    def test_binary_change_invalidates_reuse(self):
        receipt = self.receipt(); self.product.write_bytes(b"stale executable")
        with self.assertRaises(ValueError): self.api.verify_receipt(self.root, receipt, self.identity)

    def test_configuration_or_signing_mismatch_invalidates_reuse(self):
        receipt = self.receipt()
        for key in ("configuration", "signing", "sdk", "toolchain", "owner"):
            with self.assertRaises(ValueError): self.api.verify_receipt(self.root, receipt, dict(self.identity, **{key: "different"}))

    def test_changed_inputs_during_build_cannot_get_receipt(self):
        before = self.api.source_inputs(self.root)
        (self.root / "Sources/Fixture/value.swift").write_text("raced edit")
        with self.assertRaises(ValueError): self.api.make_receipt(self.root, self.cache, self.identity, before, {"fixture": self.product})

    def test_symlink_product_and_escaping_bundle_link_are_rejected(self):
        link = self.product.parent / "link"; link.symlink_to(self.product)
        with self.assertRaises(ValueError): self.api.make_receipt(self.root, self.cache, self.identity, self.api.source_inputs(self.root), {"fixture": link})
        bundle = self.product.parent / "Fixture.app"; bundle.mkdir()
        (bundle / "outside").symlink_to(self.root / "Package.swift")
        with self.assertRaises(ValueError): self.api.artifact_hash(bundle, self.cache)

    def test_contained_framework_links_are_supported(self):
        bundle = self.product.parent / "Fixture.framework"
        (bundle / "Versions/A").mkdir(parents=True)
        (bundle / "Versions/A/Fixture").write_bytes(b"framework")
        (bundle / "Versions/Current").symlink_to("A")
        (bundle / "Fixture").symlink_to("Versions/Current/Fixture")
        self.assertTrue(self.api.artifact_hash(bundle, self.cache))

    def runner(self, *, filename="Plainpost_iphonesimulator27.0-arm64.xctestrun"):
        products = self.cache / "Build/Products"; products.mkdir(parents=True, exist_ok=True)
        for name in ["PlainpostTests", "PlainpostUITests"]:
            p = products / "Debug-iphonesimulator" / (name + ".xctest"); p.mkdir(parents=True, exist_ok=True); (p / name).write_bytes(b"test binary")
        value = {"TestConfigurations": [{"TestTargets": [{"BlueprintName": name, "TestBundlePath": "__TESTROOT__/Debug-iphonesimulator/" + name + ".xctest"} for name in ["PlainpostTests", "PlainpostUITests"]]}]}
        runner = products / filename; runner.write_bytes(plistlib.dumps(value)); return products, runner

    def test_dynamic_runner_requires_current_sdk_and_expected_targets(self):
        products, runner = self.runner()
        self.assertEqual(self.api.discover_xctestrun(products, "Plainpost", "27.0", "arm64", ["PlainpostTests", "PlainpostUITests"])["xctestrun"], runner)
        with self.assertRaises(ValueError): self.api.discover_xctestrun(products, "Plainpost", "26.5", "arm64", ["PlainpostTests"])
        with self.assertRaises(ValueError): self.api.discover_xctestrun(products, "Plainpost", "27.0", "arm64", ["MissingTests"])

    def test_legacy_runner_layout_retains_current_pairing_target_ownership(self):
        products, runner = self.runner()
        targets = plistlib.loads(runner.read_bytes())["TestConfigurations"][0]["TestTargets"]
        runner.write_bytes(plistlib.dumps({target["BlueprintName"]: target for target in targets}))
        self.assertEqual(self.api.discover_xctestrun(products, "Plainpost", "27.0", "arm64", ["PlainpostTests", "PlainpostUITests"])["xctestrun"], runner)

    def test_injected_or_escaping_runner_is_rejected(self):
        products, runner = self.runner(); value = plistlib.loads(runner.read_bytes()); target = value["TestConfigurations"][0]["TestTargets"][0]
        target["EnvironmentVariables"] = {"PLAINPOST_E2E_FIXTURE": "synthetic"}; runner.write_bytes(plistlib.dumps(value))
        with self.assertRaises(ValueError): self.api.discover_xctestrun(products, "Plainpost", "27.0", "arm64", ["PlainpostTests"])
        del target["EnvironmentVariables"]; target["TestBundlePath"] = str(self.product); runner.write_bytes(plistlib.dumps(value))
        with self.assertRaises(ValueError): self.api.discover_xctestrun(products, "Plainpost", "27.0", "arm64", ["PlainpostTests"])

    def test_injected_runner_requires_exact_backup_and_unchanged_structure(self):
        products, runner = self.runner()
        artifacts = self.api.discover_xctestrun(products, "Plainpost", "27.0", "arm64", ["PlainpostTests"])
        receipt = self.api.make_receipt(self.root, self.cache, self.identity, self.api.source_inputs(self.root), artifacts)
        backup = runner.with_name(runner.name + ".plainpost-backup")
        backup.write_bytes(runner.read_bytes()); backup.chmod(0o600)
        hash_file = Path(str(backup) + ".sha256")
        hash_file.write_text(self.api.digest(backup.read_bytes()) + "\n"); hash_file.chmod(0o600)
        value = plistlib.loads(runner.read_bytes())
        target = value["TestConfigurations"][0]["TestTargets"][0]
        target["EnvironmentVariables"] = {"PLAINPOST_E2E_FIXTURE": "synthetic"}
        runner.write_bytes(plistlib.dumps(value))
        with self.assertRaises(ValueError): self.api.verify_receipt(self.root, receipt, self.identity)
        self.assertIn("xctestrun", self.api.verify_receipt(self.root, receipt, self.identity, runner_backup=backup))
        target["TestBundlePath"] = "__TESTROOT__/different.xctest"; runner.write_bytes(plistlib.dumps(value))
        with self.assertRaises(ValueError): self.api.verify_receipt(self.root, receipt, self.identity, runner_backup=backup)

    def test_cli_success_binds_current_product_and_failed_build_has_no_receipt(self):
        tool = Path(__file__).parent / "lib/build_artifacts.py"
        receipt = self.root / "receipt.json"
        base = [sys.executable, str(tool), "build", "--root", str(self.root), "--cache", str(self.cache),
                "--receipt", str(receipt), "--product", "fixture=Products/Fixture", "--"]
        failed = subprocess.run(base + [sys.executable, "-c", "raise SystemExit(9)"], capture_output=True, env=self.api.safe_environment())
        self.assertEqual(failed.returncode, 9)
        self.assertFalse(receipt.exists())
        success = subprocess.run(base + [sys.executable, "-c", "from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(b'fresh product')", str(self.product)], capture_output=True, env=self.api.safe_environment())
        self.assertEqual(success.returncode, 0, success.stderr.decode())
        verify = [sys.executable, str(tool), "verify", "--root", str(self.root), "--receipt", str(receipt), "--role", "fixture"]
        result = subprocess.run(verify, capture_output=True, text=True, env=self.api.safe_environment())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(self.product))
        self.product.write_bytes(b"changed after successful build")
        self.assertNotEqual(subprocess.run(verify, capture_output=True, env=self.api.safe_environment()).returncode, 0)

    def test_environment_allowlist_never_serializes_unrelated_values(self):
        env = self.api.safe_environment({"PATH": "/usr/bin", "HOME": "/tmp/home", "PRIVATE_TOKEN": "must not pass", "TEST_POSTGRES_URL": "must not pass"})
        self.assertEqual(env, {"PATH": "/usr/bin", "HOME": "/tmp/home"})

if __name__ == "__main__": unittest.main()
