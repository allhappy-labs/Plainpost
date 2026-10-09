#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
runner="$root/Scripts/lib/acceptance-release-backup-restore.sh"
generator="$root/Services/PlainpostGo/internal/node/backup/restore_container_test.go"

fail() { printf 'release-image restore-negatives contract: %s\n' "$*" >&2; exit 1; }
[[ -x "$runner" ]] || fail 'backup/restore runner is missing or not executable'
[[ -f "$generator" ]] || fail 'release fixture generator test is missing'

for required in \
  'wrong-key' 'wrong-account' 'wrong-trust-identity' 'semantic-mismatch' \
  'unsupported-postgresql-major' 'no-stage' 'no-reference' \
  '--pull never' '--user 65532:65532' \
  'com.plainpost.acceptance=release-restore-negative' \
  'chmod 0600' 'cleanup_run_containers'; do
  grep -F -- "$required" "$runner" >/dev/null || fail "runner lacks $required"
done
for required in \
  'PLAINPOST_RESTORE_NEGATIVE_FIXTURE_OUTPUT' \
  'TestWriteReleaseRestoreNegativeFixture' \
  'PLAINPOST_RESTORE_NEGATIVE_CASE' \
  'PLAINPOST_RESTORE_NEGATIVE_SOURCE' \
  'wrong-trust-identity' 'unsupported-postgresql-major'; do
  grep -F -- "$required" "$generator" >/dev/null || fail "fixture generator lacks $required"
done
grep -F -- '--pull never' "$runner" >/dev/null || fail 'negative image invocations may pull mutable images'
grep -F -- '--name "$restore_negative_run_name"' "$runner" >/dev/null || fail 'negative image invocations lack exact names'
grep -F -- '--label com.plainpost.acceptance-case="$negative_case"' "$runner" >/dev/null || fail 'negative image invocations lack case labels'

printf 'release_image_restore_negatives_contract=passed\n'
