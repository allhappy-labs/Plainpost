#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
owner="$root/Scripts/test-postgresql-18-live-matrix.sh"
[[ -x $owner ]] || { printf '%s\n' 'PostgreSQL 18 live matrix owner is not executable' >&2; exit 1; }

for required in \
  'postgres:18.6-alpine3.24@sha256:d3e1620b530c944afa6e887d22eb899824da68e19c52024bf98f5220c88a65b2' \
  'PLAINPOST_REQUIRE_LIVE_POSTGRES=1' \
  'PLAINPOST_RUN_SCHEMA_ISOLATION=1' \
  'general repository' \
  'backup/restore' \
  'CREATE DATABASE plainpost_matrix_backup_source OWNER plainpost_restore_admin' \
  'CREATE ROLE plainpost_restore_admin LOGIN NOSUPERUSER CREATEDB NOCREATEROLE NOINHERIT' \
  'REVOKE CONNECT ON DATABASE plainpost_matrix_backup_source FROM PUBLIC' \
  'GRANT CONNECT ON DATABASE plainpost_matrix_backup_source TO plainpost_sync_node' \
  'GRANT USAGE, CREATE ON SCHEMA public TO plainpost_sync_node' \
  'ALTER ROLE plainpost_sync_node IN DATABASE plainpost_matrix_backup_source SET search_path = public' \
  'ALTER DEFAULT PRIVILEGES FOR ROLE plainpost_sync_node REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC' \
  'ALTER DEFAULT PRIVILEGES FOR ROLE plainpost_sync_node IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC' \
  'ALTER DEFAULT PRIVILEGES FOR ROLE plainpost_sync_node IN SCHEMA public GRANT SELECT ON TABLES TO plainpost_backup' \
  'ALTER DEFAULT PRIVILEGES FOR ROLE plainpost_sync_node IN SCHEMA public REVOKE ALL ON SEQUENCES FROM PUBLIC' \
  'ALTER DEFAULT PRIVILEGES FOR ROLE plainpost_sync_node IN SCHEMA public GRANT SELECT ON SEQUENCES TO plainpost_backup' \
  'ALTER DEFAULT PRIVILEGES FOR ROLE plainpost_sync_node REVOKE ALL ON TABLES FROM PUBLIC' \
  'ALTER DEFAULT PRIVILEGES FOR ROLE plainpost_sync_node REVOKE ALL ON SEQUENCES FROM PUBLIC' \
  'ALTER DEFAULT PRIVILEGES FOR ROLE plainpost_sync_node REVOKE ALL ON FUNCTIONS FROM PUBLIC' \
  'backup_source_url="postgres://plainpost_sync_node:${backup_node_password}@' \
  'docker network create --internal' \
  'network inspect' \
  'docker volume rm' \
  'TestPostgresDumpLivePostgres18' \
  'TestPostgresRestoreLivePostgres18' \
  'TestPostgresFixedResetLivePostgres18' \
  'TestLiveClientAttachmentCapabilityIsDurableScopedUniqueAndCascades' \
  "run_node_tests '^TestLive(RuntimeLockSupervisionKeepsAHeldLock|RuntimeLockLossIsReportedWhileTheConnectionIsIdle|RuntimeLockReportsALockNoLongerHeld|RuntimeLockCheckSeesAnEndedSessionBeforeSupervision|FailedTransactionWorkPublishesNoHeadObservations|DatabaseReachabilityProbeSeparatesAnUnreachableServer)\$' TestLiveRuntimeLockSupervisionKeepsAHeldLock TestLiveRuntimeLockLossIsReportedWhileTheConnectionIsIdle TestLiveRuntimeLockReportsALockNoLongerHeld TestLiveRuntimeLockCheckSeesAnEndedSessionBeforeSupervision TestLiveFailedTransactionWorkPublishesNoHeadObservations TestLiveDatabaseReachabilityProbeSeparatesAnUnreachableServer" \
  "run_node_tests '^Test(CalendarLiveDisconnectPreventsLateWrite|CalendarLiveEraseCascades)\$' TestCalendarLiveDisconnectPreventsLateWrite TestCalendarLiveEraseCascades" \
  "run_backup_tests ./internal/node/backup '^TestCalendarLiveBackupRestore\$' TestCalendarLiveBackupRestore" \
  "run_node_tests '^TestMailModeLive' TestMailModeLiveLegacyRoutesProjectPrimaryWhileNewRoutesSeeEveryAccount TestMailModeLivePre0042SingleGmailMigratesAsPrimaryWebWithIdenticalProjection TestMailModeLiveAddingSecondAccountKeepsLegacyProjection TestMailModeLiveReservationLeftBehindNeverBecomesPrimary TestMailModeLivePromotionNeverRewritesMessageIDs TestMailModeLiveWaitingAccountDoesNotBlockAllAccountDeltas TestMailModeLiveReservationIsNeverAWaitingAccount" \
  "run_node_clientapi_tests '^TestMailModeLive' TestMailModeLiveClientRoutesProjectPrimaryAndServeEveryAccount TestMailModeLiveScopedReadsServeOnlyTheScopedProviderAccount TestMailModeLiveWaitingAccountCompletionRecoveryDeliversEveryReadyChange" \
  'focused owner did not execute required test' \
  "run_general_tests 'Test(LiveCurrentMigrationsRemoveLegacyStepUpTargetConstraint|LiveCurrentMigrationsEnforceStepUpTTL|AccountRepositoryLiveGenesisChallengeReplayAndRollback|AccountLifecycleRepositoryLiveDeletesAuthorityAndPersistsCleanupAtomically|DeletionReplayRepairsStaleAccountRestoreFromPhysicallySeparateJournal)\$'" \
  "run_general_tests 'TestSchemaIsolationLive\$'" \
  "run_node_tests 'TestLive(NodeMigrationLedgerDetectsDriftAheadAndNonContiguousHistory|Task6MigrationHeadAndHistory|AttachmentPublicationReceiptMigrationBackfillsLegacyRows|ClientAttachmentCapabilityIsDurableScopedUniqueAndCascades|EnsureAccountAndProviderEpoch|OptionalAddressValidatorWorksWithEmptyCallerSearchPath)\$'" \
  "run_backup_tests ./internal/node/backup 'Test(PostgresDumpLivePostgres18|PostgresRestoreLivePostgres18|PostgresActivationLivePostgres18|PostgresFixedResetLivePostgres18|PurgeDatabaseReplaysAfterEveryStatementBoundary|FormatRoundTripEncryptsManifestAndChunks|RestoreRecoveryIsIdempotentAcrossDurableFailpoints)\$'" \
  "run_backup_tests ./internal/node/backup '(^Test.*Live|^TestPurgeDatabaseReplaysAfterEveryStatementBoundary\$|^TestFormatRoundTripEncryptsManifestAndChunks\$|^TestRestoreRecoveryIsIdempotentAcrossDurableFailpoints\$)'" \
  'run_general_tests' \
  'run_acceptance_tests' \
  'run_node_tests' \
  'run_backup_tests' \
  'unset_matrix_database_environment' \
  '--pass=normal' \
  '--pass=race' \
  'handle_signal 130' \
  'handle_signal 143' \
  '--focused' \
  '--full' \
  'TEST_POSTGRES_URL' \
  'PLAINPOST_RESET_STATE_AUTHORITY_TEST=enabled' \
  'TEST_DELETION_JOURNAL_POSTGRES_URL' \
  'TEST_POSTGRES_ADMIN_URL' \
  'TEST_POSTGRES_STAGE_URL' \
  'TEST_POSTGRES_NODE_URL' \
  'PLAINPOST_TEST_PG_DUMP_PREFIX' \
  'PLAINPOST_TEST_PG_RESTORE_PREFIX' \
  'PostgreSQL init process complete; ready for start up.' \
  'pg_postmaster_start_time' \
  'POSTGRES_PASSWORD_FILE=' \
  'PGPASSFILE=/run/credentials/pgpass' \
  'ssl=on' \
  'ssl_ca_file=' \
  'ssl_cert_file=' \
  'ssl_key_file=' \
  'hba_file=' \
  'hostssl all all' \
  'hostnossl all all' \
  'sslmode=verify-full' \
  'PGSSLROOTCERT=' \
  'chmod 0600' \
  'credential_file' \
  '|| return 1' \
  $'case "\\$binary" in' \
  'pg_dump|pg_restore)' \
  'pg_restore)' \
	$'if [[ "\\$binary" == pg_restore ]]; then' \
	'stdin_flags=(-i)' \
	$'exec docker exec --env PGSSLROOTCERT=/run/postgres-tls/postgres-ca.crt --env PGPASSFILE=/run/credentials/pgpass "\\${stdin_flags[@]}"' \
  'unknown PostgreSQL tool binary' \
  'backup_target' \
  "tool_wrapper \"\$temp_root/pg-tools\" \"\$backup_container\""; do
  grep -Fq -- "$required" "$owner" || { printf 'matrix owner lacks required contract %q\n' "$required" >&2; exit 1; }
done

if grep -Fq 'CREATE ROLE plainpost_restore_admin LOGIN NOSUPERUSER CREATEDB NOCREATEROLE INHERIT' "$owner"; then
  printf '%s\n' 'matrix restore-admin role unexpectedly enables implicit INHERIT' >&2
  exit 1
fi

if grep -Fq 'POSTGRES_HOST_AUTH_METHOD=trust' "$owner" ||
   grep -Fq 'sslmode=disable' "$owner" ||
   grep -Fq 'host all all 0.0.0.0/0 trust' "$owner"; then
  printf '%s\n' 'matrix owner permits plaintext or trust-authenticated PostgreSQL connections' >&2
  exit 1
fi
if grep -Fq 'export PGPASSWORD=' "$owner"; then
  printf '%s\n' 'matrix owner masks runtime URL credentials with PGPASSWORD' >&2
  exit 1
fi
grep -Fq 'unset PGPASSWORD' "$owner" || {
  printf '%s\n' 'matrix owner does not clear inherited PGPASSWORD masking' >&2
  exit 1
}

grep -Fq "find \"\$probe_cache\" -mindepth 1 -depth -delete" "$0" || {
	printf '%s\n' 'contract probe does not use bounded descendant cleanup' >&2
	exit 1
}
grep -Fq "rmdir \"\$probe_cache\"" "$0" || {
	printf '%s\n' 'contract probe does not remove its exact temporary root' >&2
	exit 1
}
grep -Fq 'required-live probe cache remains' "$0" || {
	printf '%s\n' 'contract probe does not assert cleanup absence' >&2
	exit 1
}

if grep -Eq 'docker (run|network connect).*--network[[:space:]]+(bridge|host|none)([[:space:]]|$)' "$owner"; then
  printf '%s\n' 'matrix owner uses a shared or non-isolating network' >&2
  exit 1
fi
if grep -Eq 'docker (rm|volume rm|network rm).*\|\|[[:space:]]*true|docker (rm|volume rm|network rm).*true' "$owner"; then
  printf '%s\n' 'matrix owner suppresses exact cleanup failures' >&2
  exit 1
fi
if grep -Fq 'if "$@"; then' "$owner"; then
  printf '%s\n' 'matrix stage conditionally invokes owners and may swallow nested failures' >&2
  exit 1
fi
if grep -Fq "local wrapper=\"\$1\" general_container=\"\$2\" backup_container=\"\$3\"" "$owner"; then
  printf '%s\n' 'matrix tool wrapper shadows readonly cluster names' >&2
  exit 1
fi
if grep -Fq "tool_wrapper \"\$temp_root/pg-dump\" \"\$backup_container\"" "$owner" || \
   grep -Fq "tool_wrapper \"\$temp_root/pg-restore\" \"\$backup_container\"" "$owner"; then
  printf '%s\n' 'matrix tool wrapper routes all clients to the backup cluster' >&2
  exit 1
fi
if ! grep -Fq 'general_loopback' "$owner" || ! grep -Fq 'backup_loopback' "$owner"; then
  printf '%s\n' 'matrix owner does not declare distinct loopback networks for both clusters' >&2
  exit 1
fi

if grep -Fq 'interactive' "$owner"; then
	printf '%s\n' 'matrix owner uses an ambiguous interactive variable' >&2
	exit 1
fi
if ! grep -Fq "target=\"\$backup_target\"" "$owner" || ! grep -Fq 'pg_dump|pg_restore' "$owner"; then
	printf '%s\n' 'matrix tool wrapper is not bound to the backup cluster for both tools' >&2
	exit 1
fi
if grep -Fq "tool_wrapper \"\$temp_root/pg-tools\" \"\$general_container\"" "$owner"; then
	printf '%s\n' 'general cluster is exposed through the backup tool wrapper' >&2
	exit 1
fi

python3 "$root/Scripts/test-postgresql-18-dispatch.py"

probe_output=""
probe_cache="$(mktemp -d /private/tmp/plainpost-pg18-contract-cache.XXXXXX)"
cleanup_probe_cache() {
	local status="$?"
	trap - EXIT
	if [[ -e "$probe_cache" ]]; then
		if ! find "$probe_cache" -mindepth 1 -depth -delete; then
			status=1
		fi
		if [[ -e "$probe_cache" ]] && ! rmdir "$probe_cache"; then
			status=1
		fi
	fi
	if [[ -e "$probe_cache" ]]; then
		printf '%s\n' "required-live probe cache remains: $probe_cache" >&2
		status=1
	fi
	exit "$status"
}
trap cleanup_probe_cache EXIT
if probe_output="$(
	cd "$root/Services/PlainpostGo"
	env -u TEST_POSTGRES_URL -u TEST_DELETION_JOURNAL_POSTGRES_URL \
		-u TEST_POSTGRES_ADMIN_URL -u TEST_POSTGRES_STAGE_URL -u TEST_POSTGRES_NODE_URL \
		-u TEST_POSTGRES_RESET_ADMIN_URL -u TEST_POSTGRES_RESET_STAGE_URL \
		-u TEST_POSTGRES_RESET_DATABASE -u PLAINPOST_TEST_PG_DUMP_PREFIX \
		-u PLAINPOST_TEST_PG_RESTORE_PREFIX PLAINPOST_REQUIRE_LIVE_POSTGRES=1 \
		GOCACHE="$probe_cache" go test ./internal/node/backup -run '^TestPostgresFixedResetLivePostgres18$' -count=1 2>&1
)"; then
	printf '%s\n' 'required-live negative probe unexpectedly passed' >&2
	exit 1
fi
grep -Fq 'TEST_POSTGRES_RESET_ADMIN_URL, TEST_POSTGRES_RESET_STAGE_URL, and TEST_POSTGRES_RESET_DATABASE are required' <<<"$probe_output" || {
	printf '%s\n' 'required-live negative probe lacked stable required message' >&2
	printf '%s\n' "$probe_output" >&2
	exit 1
}
if grep -Fq -- 'SKIP' <<<"$probe_output"; then
	printf '%s\n' 'required-live negative probe skipped instead of failing' >&2
	exit 1
fi
