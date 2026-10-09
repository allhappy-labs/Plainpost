#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
compose="$root/Deploy/acceptance/compose.release-images.yaml"
owner="$root/Scripts/test-sync-node-release-images.sh"
failure_summary_helper="$root/Scripts/lib/release-image-failure-summary.sh"
release_override_writer="$root/Scripts/lib/write-release-private-transport-override.sh"
secret_ownership_helper="$root/Scripts/lib/prepare-container-secret-ownership.sh"
native_owner="$root/Scripts/test-sync-node-native-tls-release.sh"
private_owner="$root/Scripts/test-sync-node-private-transport.sh"
private_compose="$root/Deploy/acceptance/compose.private-transport.yaml"
swift_live="$root/Tests/PlainpostAccountRuntimeTests/SyncNodePrivateTransportLiveTests.swift"
backup_restore_contract="$root/Scripts/test-sync-node-private-transport-backup-restore-contract.sh"
restore_negatives_contract="$root/Scripts/test-sync-node-release-image-restore-negatives-contract.sh"
failure_summary_contract="$root/Scripts/test-release-image-failure-summary-contract.sh"

fail() { printf 'release-image contract: %s\n' "$*" >&2; exit 1; }
[[ -f "$compose" ]] || fail 'release-image Compose owner is missing'
[[ -x "$owner" ]] || fail 'release-image functional owner is missing or not executable'
[[ -x "$failure_summary_helper" ]] || fail 'release-image failure summary helper is missing or not executable'
[[ -x "$release_override_writer" ]] || fail 'release override writer is missing or not executable'
[[ -x "$secret_ownership_helper" ]] || fail 'container secret ownership helper is missing or not executable'
[[ -x "$native_owner" ]] || fail 'native TLS release owner is missing or not executable'
[[ -x "$private_owner" ]] || fail 'private-transport behavioral owner is missing or not executable'
[[ -x "$backup_restore_contract" ]] || fail 'backup/restore contract is missing or not executable'
[[ -f "$private_compose" ]] || fail 'private-transport Compose owner is missing'
[[ -x "$failure_summary_contract" ]] || fail 'release-image failure summary contract is missing or not executable'
command -v go >/dev/null || fail 'Go runtime loader test requires go'

bash "$backup_restore_contract" || fail 'backup/restore contract failed'
bash "$restore_negatives_contract" || fail 'release-image restore-negatives contract failed'
bash "$failure_summary_contract" || fail 'release-image failure summary contract failed'

# Exercise the same runtime loader seams used by Central, not only the
# rendered environment contract. The test creates its own bounded private
# files and proves acceptance selects them at point of use.
runtime_go_cache=$(mktemp -d /private/tmp/plainpost-release-contract-go-cache.XXXXXX)
if ! runtime_go_output_api=$(cd "$root/Services/PlainpostGo" && GOCACHE="$runtime_go_cache" \
  go test -json ./cmd/plainpost-api \
  -run '^(TestOpenConfiguredDatabasePinsProductionSchema|TestAcceptanceFileAuthoritySelectsMountedDatabaseURLAtRuntime|TestAcceptanceFileAuthorityOpensMountedDatabaseAtRuntime|TestAcceptanceFileAuthorityLoadsMountedRateLimitPepperAtRuntime)$' -count=1); then
  find "$runtime_go_cache" -depth -delete
  fail 'Central acceptance file-authority runtime tests failed'
fi
if ! runtime_go_output_config=$(cd "$root/Services/PlainpostGo" && GOCACHE="$runtime_go_cache" \
  go test -json ./internal/central/config \
  -run '^(TestLoadAcceptanceFileSecretAuthorityUsesPrivateFilesWithoutRetainingValues|TestLoadAcceptanceFileSecretAuthorityRejectsDirectValues|TestLoadAcceptanceFileSecretAuthorityIsRestrictedToAcceptance|TestLoadAcceptanceFileSecretAuthorityRejectsUnsafeFiles)$' -count=1); then
  find "$runtime_go_cache" -depth -delete
  fail 'Central acceptance file-authority config tests failed'
fi
for runtime_test in \
  TestOpenConfiguredDatabasePinsProductionSchema \
  TestAcceptanceFileAuthoritySelectsMountedDatabaseURLAtRuntime \
  TestAcceptanceFileAuthorityOpensMountedDatabaseAtRuntime \
  TestAcceptanceFileAuthorityLoadsMountedRateLimitPepperAtRuntime; do
  printf '%s\n' "$runtime_go_output_api" | jq -e --arg test "$runtime_test" \
    'select(.Action == "pass" and .Test == $test)' >/dev/null || {
    find "$runtime_go_cache" -depth -delete
    fail "Central runtime contract did not pass $runtime_test"
  }
done
for runtime_test in \
  TestLoadAcceptanceFileSecretAuthorityUsesPrivateFilesWithoutRetainingValues \
  TestLoadAcceptanceFileSecretAuthorityRejectsDirectValues \
  TestLoadAcceptanceFileSecretAuthorityIsRestrictedToAcceptance \
  TestLoadAcceptanceFileSecretAuthorityRejectsUnsafeFiles; do
  printf '%s\n' "$runtime_go_output_config" | jq -e --arg test "$runtime_test" \
    'select(.Action == "pass" and .Test == $test)' >/dev/null || {
    find "$runtime_go_cache" -depth -delete
    fail "Central runtime config contract did not pass $runtime_test"
  }
done
find "$runtime_go_cache" -depth -delete
[[ ! -e "$runtime_go_cache" ]] || fail 'runtime loader test cache was retained'

for required in \
  'PLAINPOST_RELEASE_DIR' 'verify-release.sh' '--pull never' \
  'load-oci-archive-to-local-registry.sh' \
  'release-manifest.json' 'runnable_manifest_sha256' 'postgres:18' \
  'pg_dump --version' 'pg_restore --version' 'server_version_num' \
  'plainpost_central' 'plainpost_sync_node' 'backup-restore' \
  'test-sync-node-private-transport.sh' 'PLAINPOST_SYNC_NODE_PRIVATE_TRANSPORT_RELEASE' \
  'PLAINPOST_SYNC_NODE_RELEASE_CENTRAL_IMAGE' 'PLAINPOST_SYNC_NODE_RELEASE_NODE_IMAGE' \
  'PLAINPOST_SYNC_NODE_RELEASE_COMPOSE_OVERRIDE' 'private-transport.release.override.yaml' \
  'write-release-private-transport-override.sh' \
  'replacement-fence' 'notification' 'erase' 'privacy-network' 'stage=cleanup'; do
  grep -F -- "$required" "$owner" >/dev/null || fail "owner lacks executable contract $required"
done
for required in \
  'attachment_mount_test_binary=' \
  'release_source_commit=' \
  'release_source_tree_sha256=' \
  'git -C "$root" status --porcelain=v1 --untracked-files=all' \
  'git -C "$root" rev-parse HEAD' \
  'git -C "$root" archive --format=tar' \
  '.source.commit' \
  '.source.tree_sha256' \
  'CGO_ENABLED=0 GOOS=linux GOARCH=amd64' \
  'go test -c -trimpath -o' \
  'TEST_ATTACHMENT_FILESYSTEM_ROOT=/node-data' \
  'PLAINPOST_PREPARE_ATTACHMENT_FILESYSTEM_ROOT=65532:65532' \
  'TestFilesystemPrepareMountedRootOwnership' \
  '--user 65532:65532' \
  '--entrypoint /plainpost-attachment-filesystem-test' \
  'attachment-mount-root' 'stage=attachment-mount'; do
  grep -F -- "$required" "$owner" >/dev/null || fail "release owner lacks exact packaged attachment mount probe $required"
done
grep -F -- "grep -F 'release-backup-restore status=passed'" "$owner" >/dev/null || fail 'release wrapper lacks backup/restore runtime assertion'
grep -F -- "grep -Fx 'ERROR swift-stage stage=backup-restore-end' \"\$swift_stage_log\"" "$private_owner" >/dev/null || fail 'release owner lacks backup/restore runtime assertion'
grep -F -- "release-backup-restore status=passed" "$owner" >/dev/null || fail 'release owner lacks fixed backup/restore success marker'
for required in 'secret_ownership_helper=' 'postgres_ownership_image=' \
  'private-release' 'chown 65532:65532' 'chown 70:70'; do
  grep -F -- "$required" "$owner" "$private_owner" "$secret_ownership_helper" >/dev/null || fail "release owner lacks exact secret ownership seam $required"
done
grep -F -- 'central-secrets/node-bootstrap-password' "$secret_ownership_helper" >/dev/null || fail 'secret ownership helper omits postgres-node-two bootstrap password'
for required in central-database-url central-deletion-journal-database-url rate-limit-pepper \
  postgres-superuser-password node-bootstrap-password central-db-password node-db-password \
  restore-admin-db-password restore-stage-db-password; do
  grep -F -- "central-secrets/$required" "$secret_ownership_helper" >/dev/null || fail "secret ownership helper omits central secret $required"
done
for node_name in node-one node-two; do
  for required in database_url restore_admin_database_url restore_stage_database_url \
    master_key backup_key client_tls_cert client_tls_key provider_password s3_access s3_secret; do
    grep -F -- "$node_name-secrets/$required" "$secret_ownership_helper" >/dev/null || fail "secret ownership helper omits $node_name secret $required"
  done
  if [[ $node_name == node-one ]]; then
    grep -F -- 'node-one-secrets/audit_database_url' "$secret_ownership_helper" >/dev/null || fail 'secret ownership helper omits node-one audit database URL'
  fi
done
for required in 'secret_ownership_container=' '--name "$secret_ownership_container"' \
  '--label com.plainpost.secret-ownership=1' \
  '--label com.plainpost.secret-ownership-token="$secret_ownership_token"' \
  'cleanup_secret_ownership_container'; do
  grep -F -- "$required" "$secret_ownership_helper" >/dev/null || fail "secret ownership helper lacks exact cleanup seam $required"
done
collision_fixture=$(mktemp -d /private/tmp/plainpost-secret-ownership-collision.XXXXXX)
collision_bin="$collision_fixture/bin"
mkdir -m 0700 "$collision_bin"
collision_log="$collision_fixture/docker.log"
collision_docker="$collision_bin/docker"
cat >"$collision_docker" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$PLAINPOST_COLLISION_DOCKER_LOG"
case "${1:-}" in
  ps)
    printf '%s\n' foreign-container-id
    exit 0
    ;;
  inspect)
    if [ "${2:-}" = --format ]; then printf '%s\n' foreign; fi
    exit 0
    ;;
  run) exit 0 ;;
  rm) exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod 0700 "$collision_docker"
set +e
PATH="$collision_bin:$PATH" PLAINPOST_COLLISION_DOCKER_LOG="$collision_log" \
  PLAINPOST_SECRET_OWNERSHIP_TOKEN=collision bash "$secret_ownership_helper" \
  "$collision_fixture" 'postgres:18.6-alpine3.24@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' private-release
collision_status=$?
set -e
[ "$collision_status" -ne 0 ] || fail 'secret ownership collision was accepted'
if grep -F 'rm -f' "$collision_log" >/dev/null 2>&1; then
  fail 'secret ownership collision cleanup removed a foreign container'
fi
find "$collision_fixture" -depth -delete
grep -F -- 'cp "$temporary/node-one-secrets/provider_password" "$temporary/control/smtp-probe-password"' "$private_owner" >/dev/null || fail 'private owner lacks host-owned SMTP probe copy before secret ownership'
grep -F -- 'fixture_probe_password_file="$temporary/control/smtp-probe-password"' "$private_owner" >/dev/null || fail 'fixture restart probe does not use host-owned password copy'

# Render the same override consumed by the behavioral owner against the real
# private-transport Compose. This catches merge semantics that source grep
# cannot see, including inherited raw acceptance secrets and audit argv.
render_root=$(mktemp -d /private/tmp/plainpost-release-merged-compose.XXXXXX)
render_override="$render_root/private-transport.release.override.yaml"
PLAINPOST_PRIVATE_ROOT="$render_root" bash "$release_override_writer" "$render_override"
rendered_compose=$(PLAINPOST_PRIVATE_ROOT="$render_root" \
  PLAINPOST_RELEASE_CENTRAL_IMAGE='registry.local/plainpost-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  PLAINPOST_RELEASE_NODE_IMAGE='registry.local/plainpost-node@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  PLAINPOST_PRIVATE_NODE_IMAGE='registry.local/plainpost-node@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  docker compose --profile privacy -f "$private_compose" -f "$render_override" config --format json) || {
  find "$render_root" -depth -delete
  fail 'active private-transport release Compose does not render'
}
find "$render_root" -depth -delete
central_environment=$(printf '%s\n' "$rendered_compose" | jq -e '.services.central.environment') || fail 'merged Central environment is unavailable'
printf '%s\n' "$central_environment" | jq -e '
  .PLAINPOST_ENV == "acceptance" and
  .PLAINPOST_ACCEPTANCE_FILE_SECRET_AUTHORITY == "enabled" and
  .PLAINPOST_DATABASE_URL == "" and
  .PLAINPOST_DELETION_JOURNAL_DATABASE_URL == "" and
  .PLAINPOST_RATE_LIMIT_PEPPER == "" and
  .PLAINPOST_DATABASE_URL_FILE == "/run/secrets/central-database-url" and
  .PLAINPOST_DELETION_JOURNAL_DATABASE_URL_FILE == "/run/secrets/central-deletion-journal-database-url" and
  .PLAINPOST_RATE_LIMIT_PEPPER_FILE == "/run/secrets/rate-limit-pepper"
' >/dev/null || fail 'merged Central retains raw secrets or lacks file authority'
printf '%s\n' "$rendered_compose" | jq -e '
  .services.postgres.environment.POSTGRES_HOST_AUTH_METHOD == "scram-sha-256" and
  .services["postgres-node-two"].environment.POSTGRES_HOST_AUTH_METHOD == "scram-sha-256" and
  ([.services["privacy-audit"].command[]] | index("-account-database-file") != null) and
  ([.services["privacy-audit"].command[]] | index("-node-one-database-file") != null) and
  ([.services["privacy-audit"].command[]] | index("-node-two-database-file") != null) and
  (([.services["privacy-audit"].command[]] | any(test("^postgres://"))) | not)
' >/dev/null || fail 'merged privacy audit still carries database URLs in argv'
printf '%s\n' "$rendered_compose" | jq -e '
  ([.services["privacy-audit"].volumes[].target] | index("/run/central-secrets") != null) and
  ([.services["privacy-audit"].volumes[].target] | index("/run/node-one-secrets") != null) and
  ([.services["privacy-audit"].volumes[].target] | index("/run/node-two-secrets") != null) and
  ([.services["privacy-audit"].volumes[].target] | index("/run/plainpost-public/postgres-ca.pem") != null)
' >/dev/null || fail 'merged privacy audit lacks private credential and CA mounts'

# The direct release command must reuse the repository-owned behavioral owner
# for fixture preparation and execution. A second standalone fixture tree or
# a config-only Compose pass would make the release gate source-only.
if grep -F 'prepare-release-image-fixture.sh' "$owner" >/dev/null || grep -F 'compose_run config' "$owner" >/dev/null; then
  fail 'release owner prepares or renders an unused standalone fixture tree'
fi
delegation_block=$(sed -n '/^PLAINPOST_SYNC_NODE_PRIVATE_TRANSPORT_RELEASE=1/,/^bash .*private-transport\.sh/p' "$owner")
[[ -n "$delegation_block" ]] || fail 'release owner lacks private-transport delegation block'
for required in 'PLAINPOST_SYNC_NODE_PRIVATE_TRANSPORT_RELEASE=1' \
  'PLAINPOST_SYNC_NODE_RELEASE_CENTRAL_IMAGE=' \
  'PLAINPOST_SYNC_NODE_RELEASE_NODE_IMAGE=' \
  'PLAINPOST_SYNC_NODE_RELEASE_COMPOSE_OVERRIDE=' \
  'PLAINPOST_SYNC_NODE_BOOTSTRAP_PROVISIONER="$release_dir/provision-owner-bootstrap.py"' \
  'PLAINPOST_SYNC_NODE_ACCEPTANCE_DROP_RESPONSES=status' \
  'bash "$root/Scripts/test-sync-node-private-transport.sh"'; do
  printf '%s\n' "$delegation_block" | grep -F -- "$required" >/dev/null || fail "release owner delegation lacks $required"
done
for required in \
  'bootstrap_provisioner=${PLAINPOST_SYNC_NODE_BOOTSTRAP_PROVISIONER:-$root/Deploy/sync-node/scripts/provision-owner-bootstrap.py}' \
  'installation-identity' \
  'node-bootstrap-verifier.json' \
  'PLAINPOST_SYNC_NODE_BOOTSTRAP_PROFILE_ONE=' \
  'PLAINPOST_SYNC_NODE_BOOTSTRAP_PROFILE_TWO=' \
  'node-one-hot-ready' \
  'node-two-hot-ready' \
  'capture_node_process_identity' \
  'assert_node_process_identity' \
  'phase=bootstrap' \
  'arm_initial_response_drops' \
  'generator_verifier="$bootstrap_output/node-bootstrap-verifier.json"' \
  'cmp -s "$generator_verifier" "$installed_verifier"'; do
  grep -F -- "$required" "$private_owner" >/dev/null || fail "private owner lacks protected bootstrap/hot-activation contract $required"
done
for required in \
  'CurlAcceptanceRequestHeaderFile' \
  'O_WRONLY | O_CREAT | O_EXCL' \
  '"--config", headerFile.url.path' \
  'requestHeaderFile: headerFile'; do
  grep -F -- "$required" "$swift_live" >/dev/null || fail "Swift private transport lacks protected curl header-file contract $required"
done
[ "$(grep -Fc 'headerFile.appendArguments(to: &arguments)' "$swift_live")" -eq 3 ] || fail 'both curl send paths and the regression must use the protected header file'
if grep -F 'arguments += ["--header", "\(name): \(value)"]' "$swift_live" >/dev/null; then
  fail 'Swift private transport still puts sensitive headers in process arguments'
fi
if grep -F '/plainpost-sync-node enrollment-presentation' "$private_owner" >/dev/null; then
  fail 'private owner still invokes the manual enrollment-presentation CLI'
fi
grep -F -- 'PLAINPOST_NODE_BOOTSTRAP_VERIFIER_FILE: ${PLAINPOST_ACCEPTANCE_NODE_BOOTSTRAP_VERIFIER_FILE:-}' "$private_compose" >/dev/null || fail 'private Compose lacks optional verifier path for two-phase initialization'
grep -F 'summarize_private_owner_failure' "$owner" >/dev/null || fail 'release owner lacks live failure summary seam'
if grep -F 'PLAINPOST_RELEASE_FIXTURE_TEMPLATE' "$owner" >/dev/null; then
  fail 'release owner still requires a caller-prepared fixture template'
fi
if grep -F 'cat "$private_owner_log"' "$owner" >/dev/null; then
  fail 'release owner exposes the raw private-owner log'
fi
for required in 'ERROR acceptance-fixture-restart' 'ERROR controller-' \
  'stage=privacy-audit' 'release-traffic=swift-client status=passed'; do
  grep -F -- "$required" "$owner" "$failure_summary_helper" >/dev/null || fail "release failure summary lacks fixed allowlist $required"
done
for required in 'operations_backup_failure_summary_begin' \
  'emit_operations_backup_failure_summary' 'operations_backup_failure_summary_end' \
  'release_backup_restore_failure_summary_begin' \
  'emit_release_backup_restore_failure_summary' 'release_backup_restore_failure_summary_end' \
  '| tail -80 >&2 || true'; do
  grep -F -- "$required" "$private_owner" >/dev/null || fail "private owner lacks bounded operations failure forwarding: $required"
done
grep -F 'step=(prepare|preflight-container-names|stop-node|backup-execute|backup-verify|backup-publish|negative-fixture-build|negative-case|restore-execute|restore-verify|database-reference) status=failed$' "$private_owner" >/dev/null || fail 'private owner release backup/restore forwarding lacks its fixed step vocabulary'
grep -F 'failure category=(config|lock|source|assembly|prepare|digest|commit|teardown|pty|unknown)$' "$private_owner" >/dev/null || fail 'private owner release backup/restore forwarding lacks its fixed failure vocabulary'
grep -F 'prepare-step=(context|journal-load|key|reader-open|manifest|deletion-before|references|manifest-digest|plan|journal-staging|database-create|attachments-create|payload|payload-context|payload-database-restore|payload-database-client|payload-database-connection|payload-database-archive-input|payload-database-sql-execution|payload-database-process|payload-database-context|payload-attachment-write|payload-integrity|database-validate|attachments-seal|payload-eof|reader-close|deletion-after|journal-prepared)$' "$private_owner" "$failure_summary_helper" >/dev/null || fail 'release failure summary lacks fixed restore prepare-step vocabulary'
grep -F 'commit-step=(journal-intent|verify-current|database-check|database-switch|attachment-check|attachment-switch|activation|active-verification|retirement|committed-journal)$' "$private_owner" "$failure_summary_helper" >/dev/null || fail 'release failure summary lacks fixed restore commit-step vocabulary'
grep -F 'post-child-step=(reference-validation|quarantine|attachment-quarantine|audit-secret-promotion|node-start|readiness|marker-publish) status=(begin|passed|failed)$' "$private_owner" "$failure_summary_helper" >/dev/null || fail 'release failure summary lacks fixed post-child-step vocabulary'
operations_summary_line=$(grep -n -m1 'operations_backup_failure_summary_begin' "$private_owner" | cut -d: -f1)
release_backup_restore_summary_line=$(grep -n -m1 '^    emit_release_backup_restore_failure_summary$' "$private_owner" | cut -d: -f1)
compose_capture_line=$(grep -n -m1 'compose_run logs --no-color --no-log-prefix --tail 1000' "$private_owner" | cut -d: -f1)
generic_summary_line=$(grep -n -m1 'grep -Ei.*runtime_log.*filter_summary_patterns.*tail -80' "$private_owner" | cut -d: -f1)
[[ -n "$operations_summary_line" && -n "$generic_summary_line" && "$operations_summary_line" -lt "$generic_summary_line" ]] || fail 'operations failure forwarding is not before the bounded generic tail'
[[ -n "$compose_capture_line" && -n "$release_backup_restore_summary_line" && "$release_backup_restore_summary_line" -gt "$compose_capture_line" && "$release_backup_restore_summary_line" -lt "$generic_summary_line" ]] || fail 'release backup/restore failure forwarding is not after Compose capture and before the generic tail'
summary_fixture=$(mktemp -d /private/tmp/plainpost-release-summary-contract.XXXXXX)
summary_log="$summary_fixture/private-owner.log"
summary_secret='release-summary-secret-never-render'
filesystem_summary_secret='filesystem-private-detail-never-render'
printf '%s\n' \
  'ERROR acceptance-fixture-restart fixture=smtp-fixture event=probe attempt=1 outcome=unavailable class=protocol-timeout exit=76 state=running health=starting restart_count=0' \
  'ERROR acceptance-fixture-restart fixture=smtp-fixture event=crash-classification exit_code=1 oom=false cause=sqlite-operational sqlite_subcategory=locked sqlite_operation=transaction' \
  'ERROR acceptance-fixture-restart fixture=smtp-fixture event=crash-classification exit_code=1 oom=false cause=private-class' \
  'ERROR swift-stage stage=backup-restore-end' \
  'ERROR controller-child-timeout action=release-backup-restore-run timeout_seconds=240' \
  'ERROR controller-child-timeout action=release-backup-restore-cleanup timeout_seconds=10' \
  'ERROR controller-child-timeout action=release-backup-restore-database-quarantine timeout_seconds=12' \
  'ERROR controller-child-reaped action=release-backup-restore-node-start status=124' \
  'ERROR release-backup-restore action-deadline-exceeded step=cleanup' \
  'ERROR release-backup-restore action-deadline-exceeded step=database-quarantine' \
  'ERROR release-backup-restore action-deadline-exceeded step=node-start' \
  'ERROR release-backup-restore action-deadline-exceeded step=readiness' \
  'ERROR release-backup-restore active-database-reference-invalid' \
  'ERROR release-backup-restore runtime evidence unavailable' \
  'ERROR release-backup-restore step=prepare status=failed' \
  'ERROR release-backup-restore prepare-step=payload-database-restore' \
  'ERROR release-backup-restore prepare-step=payload-database-client' \
  'ERROR release-backup-restore prepare-step=payload-database-connection' \
  'ERROR release-backup-restore prepare-step=payload-database-archive-input' \
  'ERROR release-backup-restore prepare-step=payload-database-sql-execution' \
  'ERROR release-backup-restore prepare-step=payload-database-process' \
  'ERROR release-backup-restore prepare-step=payload-database-context' \
  'ERROR release-backup-restore prepare-step=payload-attachment-write' \
  'ERROR release-backup-restore prepare-step=payload-integrity' \
  'ERROR release-backup-restore prepare-step=payload-context' \
  "ERROR release-backup-restore step=prepare-extra status=failed private-detail=$summary_secret" \
  '{"msg":"[DEBUG-sync-node-startup] filesystem attachment backend failed","component":"unavailable","stage":"root-open","errno_class":"permission","absolute":true,"exists":true,"directory":true,"mode":"0700"}' \
  "hostile private-detail=$filesystem_summary_secret [DEBUG-sync-node-startup] filesystem attachment backend failed stage=root-open errno_class=permission" \
  'hostile suffix [DEBUG-sync-node-startup] filesystem attachment backend failed stage=root-open-extra errno_class=permission' \
  'hostile embedded [DEBUG-sync-node-startup] filesystem attachment backend failed stage=root-open errno_class=permission-denied' \
  'ERROR operations-backup-failure category=backup-execute stage=postgres-dump pg_dump_url=postgres://user:secret@example.test/db path=/private/secrets/db' \
  'ERROR operations-backup-failure category=backup-execute stage=postgres-dump-extra private=must-not-render' \
  'ERROR release-backup-restore step=backup-execute status=failed' \
  'ERROR release-backup-restore step=restore-execute status=failed' \
  'ERROR release-backup-restore failure category=restore-execute' \
  'ERROR release-backup-restore failure category=prepare' \
  'ERROR release-backup-restore commit-step=retirement' \
  'ERROR release-backup-restore post-child-step=reference-validation status=failed' \
  'ERROR release-backup-restore post-child-step=quarantine status=failed' \
  'ERROR release-backup-restore post-child-step=attachment-quarantine status=failed' \
  'ERROR release-backup-restore post-child-step=audit-secret-promotion status=failed' \
  'ERROR release-backup-restore post-child-step=node-start status=failed' \
  'ERROR release-backup-restore post-child-step=readiness status=failed' \
  'ERROR release-backup-restore post-child-step=marker-publish status=failed' \
  "ERROR release-backup-restore failure category=prepare private-detail=$summary_secret" \
  'active release database reference is unavailable; values suppressed' \
  'active release database reference is not a restore database; values suppressed' \
  'private acceptance cleanup failed category=compose-down' \
  'private acceptance cleanup failed category=volumes-retained' \
  "fatal private detail=$summary_secret" \
  'private acceptance cleanup failed category=private-custom' \
  'release-traffic=swift-client status=passed' >"$summary_log"
summary_output=$(bash "$failure_summary_helper" "$summary_log")
find "$summary_fixture" -depth -delete
[[ ! -e "$summary_fixture" ]] || fail 'failure summary contract fixture was not removed'
printf '%s\n' "$summary_output" | grep -F 'event=probe attempt=1 outcome=unavailable' >/dev/null || fail 'failure summary omitted an allowlisted diagnostic'
printf '%s\n' "$summary_output" | grep -F 'ERROR swift-stage stage=backup-restore-end' >/dev/null || fail 'failure summary omitted backup/restore stage evidence'
printf '%s\n' "$summary_output" | grep -F 'ERROR controller-child-timeout action=release-backup-restore-run' >/dev/null || fail 'failure summary omitted backup/restore timeout evidence'
printf '%s\n' "$summary_output" | grep -F 'ERROR controller-child-timeout action=release-backup-restore-cleanup' >/dev/null || fail 'failure summary omitted backup/restore cleanup timeout evidence'
printf '%s\n' "$summary_output" | grep -F 'ERROR controller-child-timeout action=release-backup-restore-database-quarantine' >/dev/null || fail 'failure summary omitted database quarantine timeout evidence'
printf '%s\n' "$summary_output" | grep -F 'ERROR controller-child-reaped action=release-backup-restore-node-start' >/dev/null || fail 'failure summary omitted node start reap evidence'
for deadline_step in cleanup database-quarantine node-start readiness; do
  printf '%s\n' "$summary_output" | grep -F "ERROR release-backup-restore action-deadline-exceeded step=$deadline_step" >/dev/null || fail "failure summary omitted $deadline_step deadline evidence"
done
printf '%s\n' "$summary_output" | grep -F 'ERROR release-backup-restore active-database-reference-invalid' >/dev/null || fail 'failure summary omitted reference validation failure'
printf '%s\n' "$summary_output" | grep -F 'ERROR release-backup-restore runtime evidence unavailable' >/dev/null || fail 'failure summary omitted runtime evidence failure'
printf '%s\n' "$summary_output" | grep -Fx 'ERROR release-backup-restore step=prepare status=failed' >/dev/null || fail 'failure summary omitted prepare step evidence'
for payload_step in payload-database-restore payload-database-client payload-database-connection payload-database-archive-input payload-database-sql-execution payload-database-process payload-database-context payload-attachment-write payload-integrity payload-context; do
  printf '%s\n' "$summary_output" | grep -Fx "ERROR release-backup-restore prepare-step=$payload_step" >/dev/null || fail "failure summary omitted $payload_step evidence"
done
if printf '%s\n' "$summary_output" | grep -F 'ERROR release-backup-restore step=prepare-extra' >/dev/null; then
  fail 'failure summary emitted suffixed prepare step evidence'
fi
printf '%s\n' "$summary_output" | grep -Fx 'ERROR release-backup-restore step=backup-execute status=failed' >/dev/null || fail 'failure summary omitted backup/restore step evidence'
printf '%s\n' "$summary_output" | grep -Fx 'ERROR release-backup-restore step=restore-execute status=failed' >/dev/null || fail 'failure summary omitted restore step evidence'
printf '%s\n' "$summary_output" | grep -Fx 'ERROR release-backup-restore failure category=prepare' >/dev/null || fail 'failure summary omitted restore category evidence'
printf '%s\n' "$summary_output" | grep -Fx 'ERROR release-backup-restore commit-step=retirement' >/dev/null || fail 'failure summary omitted restore commit step evidence'
for post_child_step in reference-validation quarantine attachment-quarantine audit-secret-promotion node-start readiness marker-publish; do
  printf '%s\n' "$summary_output" | grep -Fx "ERROR release-backup-restore post-child-step=$post_child_step status=failed" >/dev/null || fail "failure summary omitted $post_child_step evidence"
done
if printf '%s\n' "$summary_output" | grep -F 'ERROR release-backup-restore failure category=restore-execute' >/dev/null; then
  fail 'failure summary emitted an unallowlisted restore category'
fi
filesystem_summary_count=$(printf '%s\n' "$summary_output" | grep -F -c 'filesystem attachment backend failed stage=root-open errno_class=permission' || true)
[[ "$filesystem_summary_count" -eq 2 ]] || fail 'failure summary omitted canonical filesystem failure evidence'
printf '%s\n' "$summary_output" | grep -F 'active release database reference is unavailable; values suppressed' >/dev/null || fail 'failure summary omitted unavailable reference failure'
printf '%s\n' "$summary_output" | grep -F 'active release database reference is not a restore database; values suppressed' >/dev/null || fail 'failure summary omitted non-restore reference failure'
printf '%s\n' "$summary_output" | grep -F 'private acceptance cleanup failed category=compose-down' >/dev/null || fail 'failure summary omitted allowlisted cleanup category'
printf '%s\n' "$summary_output" | grep -F 'private acceptance cleanup failed category=volumes-retained' >/dev/null || fail 'failure summary omitted retained volumes cleanup category'
printf '%s\n' "$summary_output" | grep -F 'cause=sqlite-operational sqlite_subcategory=locked sqlite_operation=transaction' >/dev/null || fail 'failure summary omitted an allowlisted SQLite diagnostic'
if printf '%s\n' "$summary_output" | grep -E 'cause=private-class|private acceptance cleanup failed category=private-custom' >/dev/null; then
  fail 'failure summary emitted an unallowlisted diagnostic'
fi
if printf '%s\n' "$summary_output" | grep -F "$summary_secret" >/dev/null; then
  fail 'failure summary emitted an unallowlisted private detail'
fi
if printf '%s\n' "$summary_output" | grep -F "$filesystem_summary_secret" >/dev/null; then
  fail 'failure summary emitted a filesystem private detail'
fi
backup_summary_count=$(printf '%s\n' "$summary_output" | grep -F -c 'ERROR operations-backup-failure category=backup-execute stage=postgres-dump' || true)
[[ "$backup_summary_count" -eq 1 ]] || fail 'failure summary did not retain exactly one canonical backup category'
if printf '%s\n' "$summary_output" | grep -E 'postgres://|/private/secrets/|pg_dump_url|postgres-dump-extra|must-not-render' >/dev/null; then
  fail 'failure summary emitted private or non-canonical backup diagnostic detail'
fi

# These are executable REDs for the production bug this contract catches:
# stage claims must not be synthesized after one unrelated Swift command.
if grep -F 'for stage in' "$owner" >/dev/null && grep -F "printf 'stage=%s" "$owner" >/dev/null; then
  fail 'owner blindly emits release stages without per-stage adapter evidence'
fi
if grep -F 'swift test --filter SyncNodePrivateTransportLiveTests' "$owner" >/dev/null; then
  fail 'owner directly runs Swift instead of the existing private-transport behavioral owner'
fi

for required in 'services:' 'postgres:' 'central:' 'sync-node:' 'PLAINPOST_CENTRAL_IMAGE' \
  'PLAINPOST_NODE_IMAGE' 'postgres:18' 'internal: true' 'pull_policy: never' \
  'imap-fixture:' 'smtp-fixture:' 'plainpost_acceptance_mail_fixture'; do
  grep -F -- "$required" "$compose" >/dev/null || fail "Compose lacks release invariant $required"
done
for required in 'postgres://plainpost_central:' 'postgres://plainpost_sync_node:' \
  'database_host="postgres-$node_name"' 'sslmode=verify-full&sslrootcert='; do
  grep -F -- "$required" "$private_owner" >/dev/null || fail "release owner lacks authenticated database target $required"
done
if grep -F 'sslmode=disable' "$compose" >/dev/null; then
  fail 'release Compose retains cleartext PostgreSQL dependency URLs'
fi
for required in \
  'sslmode=verify-full' \
  'sslrootcert=/run/plainpost-public/postgres-ca.pem' \
  'PLAINPOST_DATABASE_URL_FILE: /run/secrets/central-database-url' \
  'PLAINPOST_DELETION_JOURNAL_DATABASE_URL_FILE: /run/secrets/central-deletion-journal-database-url'; do
  grep -F -- "$required" "$compose" "$private_owner" "$release_override_writer" >/dev/null || fail "release Compose/owner lacks verified PostgreSQL TLS wiring $required"
done
if grep -F 'sslmode=disable' "$owner" >/dev/null; then
  fail 'release owner generated override retains cleartext PostgreSQL dependency URLs'
fi
if grep -Eq 'sslmode=(require|prefer)([&"[:space:]]|$)' "$compose" "$owner" >/dev/null; then
  fail 'release owner permits PostgreSQL TLS without certificate verification'
fi
for required in \
  'PLAINPOST_DATABASE_URL_FILE: /run/secrets/central-database-url' \
  'PLAINPOST_DELETION_JOURNAL_DATABASE_URL_FILE: /run/secrets/central-deletion-journal-database-url' \
  'PLAINPOST_NODE_DATABASE_URL_FILE: /run/secrets/database_url' \
  'sslmode=verify-full&sslrootcert=/run/plainpost-public/postgres-ca.pem'; do
  grep -F -- "$required" "$owner" "$private_owner" "$private_compose" "$release_override_writer" "$compose" >/dev/null || fail "release owner lacks private verified PostgreSQL TLS wiring $required"
done
for required in \
  'central-secrets' 'central-db-password' 'node-db-password' 'restore-admin-db-password' 'restore-stage-db-password' 'PASSWORD' \
  'central-database-url' 'central-deletion-journal-database-url' \
  'ca.crt:/run/plainpost-public/postgres-ca.pem:ro'; do
  grep -F -- "$required" "$owner" "$private_owner" "$release_override_writer" >/dev/null || fail "release owner lacks private Central credential/CA wiring $required"
done
for required in \
  'POSTGRES_HOST_AUTH_METHOD: scram-sha-256' \
  'POSTGRES_PASSWORD_FILE: /run/secrets/postgres-superuser-password' \
  'POSTGRES_PASSWORD_FILE: /run/secrets/node-bootstrap-password' \
  'postgres-node-one:' 'postgres-node-two:'; do
  grep -F -- "$required" "$owner" "$release_override_writer" >/dev/null || fail "release override lacks authenticated PostgreSQL bootstrap $required"
done
for required in \
  'postgres-superuser-password' 'node-bootstrap-password' \
  'chmod 0600' 'plainpost_node_bootstrap'; do
  grep -F -- "$required" "$private_owner" >/dev/null || fail "release owner lacks private PostgreSQL bootstrap credential $required"
done
for required in \
  '-account-database-file' '/run/central-secrets/central-database-url' \
  '-node-one-database-file' '/run/node-one-secrets/audit_database_url' \
  '-node-two-database-file' '/run/node-two-secrets/database_url'; do
  grep -F -- "$required" "$release_override_writer" >/dev/null || fail "release privacy audit lacks file-based URL wiring $required"
done
if grep -Eq 'PLAINPOST_RELEASE_(CENTRAL|NODE)_DB_PASSWORD=' "$owner" "$private_owner"; then
  fail 'release owner passes database passwords through parent Compose environment'
fi
for required in \
  'postgres://plainpost_sync_node:%s@%s:5432/plainpost_sync_node?sslmode=verify-full' \
  'postgres://plainpost_restore_admin:%s@%s:5432/postgres?sslmode=verify-full' \
  'postgres://plainpost_restore_stage:%s@%s:5432/plainpost_sync_node?sslmode=verify-full'; do
  grep -F -- "$required" "$private_owner" >/dev/null || fail "release owner lacks credentialed verified Node URL $required"
done
if grep -F 'postgres-node-one:5432' "$compose" >/dev/null; then
  fail 'release privacy stage retains source-only postgres-node-one target'
fi
if grep -F 'time.sleep(2147483647)' "$compose" >/dev/null; then
  fail 'release Compose uses a sleeping placeholder instead of deterministic adapters'
fi

# Only the two source-built application artifacts may be bypassed in release
# mode. The ordinary owner retains its source-build path and validates both
# immutable release selectors before selecting them.
for required in 'release_mode=' 'PLAINPOST_SYNC_NODE_RELEASE_CENTRAL_IMAGE' \
  'PLAINPOST_SYNC_NODE_RELEASE_NODE_IMAGE' 'docker build --no-cache' \
  'transport_release_images=0' 'node_image=$release_node_image'; do
  grep -F -- "$required" "$private_owner" >/dev/null || fail "private owner lacks release/source boundary $required"
done

# Release mode must select the one-primary/two-database topology and the
# separately isolated disposable replacement.  This RED catches the old
# three-PostgreSQL startup before the implementation introduces service
# selectors, and requires evidence that the behavioral owner observed actual
# Swift traffic rather than merely printing a stage label.
if grep -F 'compose_run up -d postgres postgres-node-one postgres-node-two' "$private_owner" >/dev/null; then
  fail 'release mode starts the source three-PostgreSQL topology'
fi
for required in 'release_primary_database_service' 'release_replacement_database_service' \
  'release_database_services' 'release-traffic=swift-client status=passed'; do
  grep -F -- "$required" "$private_owner" >/dev/null || fail "private owner lacks release topology/traffic contract $required"
done
for required in 'release-traffic=swift-client status=passed' 'swift-client' 'backup-restore' 'privacy-network'; do
  grep -F -- "$required" "$owner" >/dev/null || fail "release owner lacks functional evidence $required"
done
grep -F -- 'docker compose' "$private_owner" >/dev/null || fail 'private owner lacks Compose execution seam'
grep -F -- 'down --volumes --remove-orphans' "$private_owner" >/dev/null || fail 'private owner lacks exact Compose cleanup seam'
for required in 'release-postgres-client-versions=' 'release-migration-heads=' 'compose_run --profile privacy run --name "$privacy_audit_container" privacy-audit'; do
  grep -F -- "$required" "$private_owner" >/dev/null || fail "private owner lacks executable PostgreSQL/privacy evidence $required"
done
grep -F -- 'scan_privacy_file "$privacy_audit_output" container-log' "$private_owner" >/dev/null || fail 'private owner does not scan ephemeral privacy-audit output'
for required in 'privacy_audit_container=' \
  'run --name "$privacy_audit_container" privacy-audit' \
  'docker inspect "$privacy_audit_container"' \
  'privacy-audit-container-inspect.json' \
  'docker rm "$privacy_audit_container"'; do
  grep -F -- "$required" "$private_owner" >/dev/null || fail "privacy audit lacks ephemeral container inspection/cleanup $required"
done
if grep -F -- 'run --rm privacy-audit' "$private_owner" >/dev/null; then
  fail 'privacy audit removes its container before inspecting the runtime surface'
fi
for required in 'com.plainpost.release.topology: primary' 'com.plainpost.release.topology: replacement-isolated' \
  'profiles: [release-unused]' 'depends_on: !override' 'release-postgres-server-version='; do
  grep -F -- "$required" "$owner" "$private_owner" "$release_override_writer" >/dev/null || fail "release owner lacks topology seam $required"
done
for required in 'PLAINPOST_DATABASE_URL_FILE: /run/secrets/central-database-url' \
  'PLAINPOST_DELETION_JOURNAL_DATABASE_URL_FILE: /run/secrets/central-deletion-journal-database-url' \
  'search_path=account' 'search_path=deletion_journal' 'plainpost_central' 'NOT datistemplate' \
  'IS NOT NULL'; do
  grep -F -- "$required" "$owner" "$private_owner" "$release_override_writer" >/dev/null || fail "release owner lacks single-Central production authority $required"
done
grep -F 'release_journal_probe="select (to_regclass' "$private_owner" >/dev/null || fail 'release journal readiness probe does not use a boolean relation check'
for required in 'release_journal_database=journal' 'release_journal_role=plainpost' \
  'release_journal_database=plainpost_central' 'release_journal_role=plainpost_central' \
  '-d "$release_journal_database"' '-U "$release_journal_role"'; do
  grep -F -- "$required" "$private_owner" >/dev/null || fail "release/source journal authority is not mode-selected $required"
done
if ! awk '
  /if \[ -n "\$release_source_journal_sql" \]/ { guarded=1 }
  guarded && /printf.*release_source_journal_sql/ { found=1 }
  END { exit !found }
' "$private_owner"; then
  fail 'release init does not guard the source-only journal database'
fi
if grep -F "IN ('central','plainpost_sync_node')" "$private_owner" >/dev/null; then
  fail 'release database probe counts a selected subset instead of the complete logical set'
fi

if grep -Eq 'postgres:(17|19)([^0-9]|$)' "$compose" "$owner"; then
  fail 'release owner retains a PostgreSQL major other than 18'
fi
if grep -Eq 'image:[[:space:]]+[^$[:space:]].*:[0-9]+([[:space:]]|$)' "$compose"; then
  fail 'release Compose permits a mutable image tag'
fi
if grep -Eq 'PLAINPOST_(CENTRAL|NODE)_IMAGE=.*:[^@[:space:]]+([[:space:]]|$)' "$owner"; then
  fail 'release owner derives mutable application image references'
fi

printf 'sync_node_release_images_contract=passed\n'
