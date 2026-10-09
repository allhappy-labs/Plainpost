#!/usr/bin/env python3
"""Exercise source-extracted matrix dispatch/cleanup on its actual /bin/bash.

Only external Go is replaced; no Docker, database, credentials or build cache.
Each child gets an explicit safe environment and its own empty cleanup root.
"""
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import unittest

OWNER = Path(__file__).with_name("test-postgresql-18-live-matrix.sh")
SOURCE = OWNER.read_text()
PACKAGE = "example.test/services/ordinary"
SECOND = "example.test/services/later"
NODE = "example.test/services/cmd/plainpost-sync-node"
POSTGRES = "example.test/services/internal/node/postgres"
POSTGRES_OWNERS = ["TestLiveClientAttachmentCapabilityIsDurableScopedUniqueAndCascades",
                   "TestCalendarLiveDisconnectPreventsLateWrite", "TestCalendarLiveEraseCascades"]
NODE_OWNERS = ["TestRestoreReadinessCloseFailurePreservesDependencies",
               "TestRestoreReadinessCloseCanRetryAfterOwnerFailure"]


def function(name):
    match = re.search(r"^" + re.escape(name) + r"\(\) \{\n.*?^\}\n", SOURCE, re.M | re.S)
    if not match:
        raise AssertionError("missing production function: " + name)
    return match.group()


def events(package, names=("TestOrdinary",), skip=(), no_files=False):
    rows = [{"Action": "start", "Package": package}]
    for name in names:
        rows += [{"Action": "run", "Package": package, "Test": name},
                 {"Action": "skip" if name in skip else "pass", "Package": package, "Test": name}]
    if no_files:
        rows.append({"Action": "output", "Package": package, "Output": "?\t" + package + "\t[no test files]\n"})
    rows.append({"Action": "skip" if no_files else "pass", "Package": package})
    return rows


class DispatchTests(unittest.TestCase):
    def run_shell(self, packages=(PACKAGE, SECOND), rows=None, action=None,
                  failure=0, cleanup_failure=False, mode="integration", mutate_dispatch=None):
        with tempfile.TemporaryDirectory(prefix="plainpost-dispatch-") as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            owned = root / "owned"
            owned.mkdir()
            if cleanup_failure:
                (owned / "retained").write_text("owned cleanup failure fixture")
            mapping = rows if rows is not None else {p: events(p) for p in packages}
            data = {"packages": list(packages), "rows": mapping, "failure": failure}
            (root / "fixture.json").write_text(json.dumps(data))
            go = root / "bin/go"
            go.write_text("#!" + sys.executable + "\n" + r'''import json,pathlib,sys
f=json.loads((pathlib.Path(__file__).resolve().parent.parent/"fixture.json").read_text())
a=sys.argv[1:]
if a[0]=="list":
 if a[-1]=="./...": print("\n".join(f["packages"]))
 else: print(next((p for p in f["packages"] if p.endswith(a[-1].removeprefix("./"))), a[-1]))
elif a[0]=="test":
 p=next((p for p in f["packages"] if p.endswith(a[1].removeprefix("./"))), a[1])
 if "-json" in a:
  for row in f["rows"].get(p, []): print(json.dumps(row))
 else:
  for row in f["rows"].get(p, []):
   if row.get("Test") and row["Action"]=="pass": print("--- PASS: %s (0.00s)" % row["Test"])
 sys.exit(f["failure"])
else: sys.exit(99)
''')
            go.chmod(0o700)
            initialization = SOURCE[SOURCE.index("created_containers=()"):SOURCE.index("readonly ownership_label=")]
            functions = "\n".join(function(n) for n in ["cleanup", "handle_signal", "stage", "go_test", "unset_matrix_database_environment", "run_backup_tests"])
            traps = SOURCE[SOURCE.index("trap 'cleanup"):SOURCE.index("\nstage()")]
            dispatch = SOURCE[SOURCE.index('if [[ "$mode" == node-lifecycle ]]; then\n\tunset_matrix'):]
            if mutate_dispatch:
                dispatch = mutate_dispatch(dispatch)
            # For function controls use the real final completion/PASS boundary.
            finish = SOURCE[SOURCE.rindex("\nfi\n") + len("\nfi\n"):]
            script = "set -euo pipefail\n" + initialization + functions + traps
            script += "\ntemp_root=" + shlex.quote(str(owned)) + "\ngo_root=" + shlex.quote(str(root))
            script += "\nmode=" + mode + "\nrace=0\npostgres_image=dummy\n"
            for key in ["general_url", "general_journal_url", "backup_source_url", "backup_admin_url", "backup_stage_url", "backup_node_url"]:
                script += key + "=owned-dummy-" + key + "\n"
            script += (action + "\n" + finish) if action is not None else dispatch
            result = subprocess.run(["/bin/bash", "-c", script], env={
                "PATH": str(root / "bin") + ":" + str(Path(sys.executable).parent) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": str(root), "TMPDIR": str(root), "LANG": "C", "LC_ALL": "C",
                "PYTHONDONTWRITEBYTECODE": "1"}, capture_output=True, text=True, timeout=15)
            self.assertEqual(owned.exists(), cleanup_failure, result.stdout + result.stderr)
            return result

    def success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PostgreSQL 18 live matrix PASS", result.stdout)

    def rejected(self, result, code=None):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        if code is not None:
            self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        self.assertNotIn("PostgreSQL 18 live matrix PASS", result.stdout)

    def test_empty_owners_reach_every_declared_package(self):
        r = self.run_shell()
        self.success(r)
        self.assertEqual(r.stdout.count("matrix stage PASS:"), 2)
        self.assertIn("integration package completion: declared=2 completed=2", r.stdout)

    def test_multiple_required_owners_and_relative_selector(self):
        self.success(self.run_shell(packages=(NODE,), rows={NODE: events(NODE, NODE_OWNERS)},
            action='stage owners go_test ./cmd/plainpost-sync-node . ' + " ".join(NODE_OWNERS), mode="node-lifecycle"))

    def test_declared_postgres_owners_all_required(self):
        self.success(self.run_shell(packages=(POSTGRES,), rows={POSTGRES: events(POSTGRES, POSTGRES_OWNERS)}))

    def test_declared_postgres_owner_omission_rejected(self):
        self.rejected(self.run_shell(packages=(POSTGRES,), rows={POSTGRES: events(POSTGRES, POSTGRES_OWNERS[:2])}))

    def test_declared_postgres_owner_skip_rejected(self):
        self.rejected(self.run_shell(packages=(POSTGRES,), rows={POSTGRES: events(POSTGRES, POSTGRES_OWNERS, skip=POSTGRES_OWNERS[-1:])}))

    def test_missing_required_owner_rejected(self):
        self.rejected(self.run_shell(packages=(NODE,), rows={NODE: events(NODE, NODE_OWNERS[:1])}))

    def test_required_owner_skip_rejected(self):
        self.rejected(self.run_shell(packages=(NODE,), rows={NODE: events(NODE, NODE_OWNERS, skip=NODE_OWNERS[:1])}))

    def test_ordinary_skip_accepted(self):
        self.success(self.run_shell(packages=(PACKAGE,), rows={PACKAGE: events(PACKAGE, skip=("TestOrdinary",))}))

    def test_explicit_no_test_files_accepted(self):
        self.success(self.run_shell(packages=(PACKAGE,), rows={PACKAGE: events(PACKAGE, names=(), no_files=True)}))

    def test_zero_test_events_rejected(self):
        self.rejected(self.run_shell(packages=(PACKAGE,), rows={PACKAGE: events(PACKAGE, names=())}))

    def test_wrong_package_identity_rejected(self):
        self.rejected(self.run_shell(packages=(NODE,), rows={NODE: events(SECOND, NODE_OWNERS)}))

    def test_missing_package_terminal_rejected(self):
        self.rejected(self.run_shell(packages=(NODE,), rows={NODE: events(NODE, NODE_OWNERS)[:-1]}))

    def test_duplicate_package_terminal_rejected(self):
        self.rejected(self.run_shell(packages=(NODE,), rows={NODE: events(NODE, NODE_OWNERS) + [{"Action":"pass", "Package":NODE}]}))

    def test_unsettled_test_event_rejected(self):
        rows = events(NODE, NODE_OWNERS)
        rows.insert(-1, {"Action":"run", "Package":NODE, "Test":"TestUnfinished"})
        self.rejected(self.run_shell(packages=(NODE,), rows={NODE: rows}))

    def test_child_failure_preserves_status(self):
        self.rejected(self.run_shell(failure=23), 23)

    def test_focused_child_failure_preserves_status(self):
        self.rejected(self.run_shell(failure=23, action='stage owner go_test ordinary . TestOrdinary', mode="focused"), 23)

    def test_focused_optional_owners(self):
        self.success(self.run_shell(action='stage owner go_test ordinary .', mode="focused"))

    def test_fatal_nounset_cannot_return_success(self):
        self.rejected(self.run_shell(action='true\nprintf "%s" "$missing_fixture_value"'))

    def test_early_zero_exit_is_incomplete(self):
        self.rejected(self.run_shell(action="exit 0"))

    def test_empty_inventory_rejected(self):
        self.rejected(self.run_shell(packages=()))

    def test_duplicate_inventory_rejected(self):
        self.rejected(self.run_shell(packages=(NODE, NODE), rows={NODE: events(NODE, NODE_OWNERS)}))

    def test_partial_dispatch_rejected(self):
        self.rejected(self.run_shell(mutate_dispatch=lambda s: s.replace('done <<<"$package_inventory"', 'break\n\tdone <<<"$package_inventory"')))

    def test_cleanup_failure_cannot_return_success(self):
        r = self.run_shell(packages=(NODE,), rows={NODE: events(NODE, NODE_OWNERS)}, cleanup_failure=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("matrix cleanup: FAILED", r.stderr)

    def test_cleanup_failure_preserves_child_status(self):
        self.rejected(self.run_shell(failure=23, cleanup_failure=True), 23)


if __name__ == "__main__":
    print("source sha256=" + hashlib.sha256(SOURCE.encode()).hexdigest(), flush=True)
    unittest.main(verbosity=2)
