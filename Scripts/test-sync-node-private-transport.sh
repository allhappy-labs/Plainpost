#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
stream_summary_helper="$root/Scripts/lib/sync-node-stream-diagnostic-summary.sh"
task7_privacy_audit_category_helper="$root/Scripts/lib/task7-privacy-audit-category.sh"
tls_probe_helper="$root/Scripts/lib/sync-node-tls-probe.sh"
. "$stream_summary_helper"
. "$task7_privacy_audit_category_helper"
. "$tls_probe_helper"
certificate_san_helper="$root/Scripts/lib/verify-certificate-dns-san.sh"
. "$certificate_san_helper"
active_database_reference_helper="$root/Scripts/lib/acceptance-active-database-reference.sh"
. "$active_database_reference_helper"
privacy_scan_helper="$root/Scripts/lib/sync-node-privacy-scan.sh"
. "$privacy_scan_helper"
secret_ownership_helper="$root/Scripts/lib/prepare-container-secret-ownership.sh"
controller_helper="$root/Scripts/lib/acceptance-controller.sh"
provider_transition_helper="$root/Scripts/lib/acceptance-provider-transition.sh"
node_two_schema_checkpoint_helper="$root/Scripts/lib/acceptance-node-two-schema-checkpoint.sh"
process_supervisor="$root/Scripts/lib/acceptance-process-supervisor.py"
release_backup_restore_cleanup="$root/Scripts/lib/acceptance-release-backup-restore-cleanup.sh"
release_backup_restore_marker="$root/Scripts/lib/acceptance-release-backup-restore-terminal-marker.sh"
. "$controller_helper"
. "$node_two_schema_checkpoint_helper"
. "$release_backup_restore_marker"
compose="$root/Deploy/acceptance/compose.private-transport.yaml"
postgres_ownership_image='postgres:18.6-alpine3.24@sha256:d3e1620b530c944afa6e887d22eb899824da68e19c52024bf98f5220c88a65b2'
[ -x "$secret_ownership_helper" ] || { printf 'container secret ownership helper is unavailable\n' >&2; exit 1; }
project="plainpost-private-transport-$$"
node_image="plainpost-task7-node:$project"
release_mode=${PLAINPOST_SYNC_NODE_PRIVATE_TRANSPORT_RELEASE:-0}
secret_ownership_validation_mode=${PLAINPOST_SECRET_OWNERSHIP_VALIDATION_MODE:-exact}
secret_ownership_release_adapter=${PLAINPOST_SECRET_OWNERSHIP_RELEASE_ADAPTER:-}
if [ "$secret_ownership_validation_mode" = local-virtualized ]; then
  [ "$release_mode" = 1 ] || { printf 'local virtualized ownership requires release mode\n' >&2; exit 1; }
  [ "$secret_ownership_release_adapter" = release-images-darwin ] || {
    printf 'local virtualized ownership requires the release-image adapter\n' >&2
    exit 1
  }
fi
release_central_image=${PLAINPOST_SYNC_NODE_RELEASE_CENTRAL_IMAGE:-}
release_node_image=${PLAINPOST_SYNC_NODE_RELEASE_NODE_IMAGE:-}
release_compose_override=${PLAINPOST_SYNC_NODE_RELEASE_COMPOSE_OVERRIDE:-}
bootstrap_provisioner=${PLAINPOST_SYNC_NODE_BOOTSTRAP_PROVISIONER:-$root/Deploy/sync-node/scripts/provision-owner-bootstrap.py}
acceptance_central_audience=acceptance.plainpost.central
[ "$(grep -c "PLAINPOST_NODE_ENROLLMENT_CENTRAL_AUDIENCE: $acceptance_central_audience\$" "$compose")" = 1 ] &&
  [ "$(grep -c "PLAINPOST_NODE_CENTRAL_AUDIENCE: $acceptance_central_audience\$" "$compose")" = 1 ] || {
  printf 'acceptance Central audience drifted from the provisioner input\n' >&2
  exit 1
}
# Keep all source/release differences in this one profile selector. Every
# later stage consumes these resolved properties; it must not reinterpret the
# mode or duplicate its topology switches.
transport_mode=source
transport_release_images=0
transport_release_override=''
release_primary_database_service=postgres-node-one
release_replacement_database_service=postgres-node-two
release_database_services='postgres-node-one postgres-node-two'
release_startup_database_services='postgres postgres-node-one postgres-node-two'
release_node_one_database_service=postgres-node-one
release_central_database=central
release_central_role=plainpost
release_journal_database=journal
release_journal_role=plainpost
release_journal_probe="select (to_regclass('public.deletion_journal_state') IS NOT NULL)"
release_source_journal_sql='CREATE DATABASE journal;'
release_server_version=''
release_dump_client_version=''
release_restore_client_version=''
release_central_account_head=''
release_central_deletion_journal_head=''
release_node_migration_head=''
release_central_db_password=''
release_node_db_password=''
release_restore_admin_db_password=''
release_restore_stage_db_password=''
release_postgres_superuser_password=''
release_node_bootstrap_password=''
node_one_database_name=plainpost_sync_node
node_database_inspection_role=plainpost_node_bootstrap
case "$release_mode" in
  0)
    ;;
  1)
    printf '%s\n' "$release_central_image" | grep -Eq '^[^[:space:]@]+@sha256:[0-9a-f]{64}$' || { printf 'release transport requires an immutable Central image\n' >&2; exit 1; }
    printf '%s\n' "$release_node_image" | grep -Eq '^[^[:space:]@]+@sha256:[0-9a-f]{64}$' || { printf 'release transport requires an immutable Node image\n' >&2; exit 1; }
    [ -f "$release_compose_override" ] || { printf 'release transport requires its Compose override\n' >&2; exit 1; }
    transport_mode=release
    transport_release_images=1
    transport_release_override=$release_compose_override
    node_image=$release_node_image
    # Release mode models production: Central and the primary Sync Node share
    # one PostgreSQL 18 instance, while replacement remains isolated.
    release_primary_database_service=postgres
    release_node_one_database_service=postgres
    release_database_services='postgres postgres-node-two'
    release_startup_database_services="$release_database_services"
    release_central_database=plainpost_central
    release_central_role=plainpost_central
    release_journal_database=plainpost_central
    release_journal_role=plainpost_central
    release_journal_probe="select (to_regclass('deletion_journal.deletion_journal_state') IS NOT NULL)"
    release_source_journal_sql=''
    node_database_inspection_role=plainpost_sync_node
    ;;
  *)
    printf 'private transport release mode must be 0 or 1\n' >&2
    exit 1
    ;;
esac
[ -f "$bootstrap_provisioner" ] && [ ! -L "$bootstrap_provisioner" ] && [ -x "$bootstrap_provisioner" ] || {
  printf 'owner bootstrap provisioner is unavailable\n' >&2
  exit 1
}
temporary=$(mktemp -d "${TMPDIR:-/tmp}/plainpost-private-transport.XXXXXX")
temporary=$(CDPATH= cd -- "$temporary" && pwd -P)
umask 077
runtime_log="$temporary/runtime.log"
swift_stage_log="$temporary/swift-stage.log"
swift_stream_diagnostic_log="$temporary/swift-stream-diagnostic.log"
printf 'transport-mode=%s\n' "$transport_mode" >"$runtime_log"

# Release restore changes the durable database reference from the controller
# loop.  That loop runs in a background subshell, so parent-side diagnostics
# must reload the mode-0600 reference instead of trusting its stale variable.
refresh_active_node_database_name() {
  [ "$transport_release_images" = 1 ] || return 0
  refresh_requirement=${1:-}
  refresh_reference="$temporary/node-one-data/restore-references/database"
  node_one_database_name=$(acceptance_active_database_name "$refresh_reference" "$node_one_database_name" "$(dirname "$refresh_reference")" "$refresh_requirement")
}
patterns="$temporary/privacy-patterns"
privacy_pattern_origins="$temporary/privacy-pattern-origins"
returned_database_patterns="$temporary/returned-database-privacy-patterns"
cleanup_started=0
cleanup_running=0
acceptance_provider_state_captured=0
node_image_built=0
acceptance_filter=${PLAINPOST_SYNC_NODE_ACCEPTANCE_SWIFT_FILTER:-PlainpostAccountRuntimeTests.SyncNodePrivateTransportLiveTests/testRealCentralAndNodeProcessesClosePrivateLifecycle}
acceptance_mail_scenario=${PLAINPOST_SYNC_NODE_ACCEPTANCE_MAIL_SCENARIO:-}
acceptance_smtp_tls_mode=normal
acceptance_imap_tls_mode=normal
acceptance_imap_tls_terminal_mode=normal
acceptance_imap_fetch_phase=''
acceptance_imap_idle=0
acceptance_imap_wait_idle_change=0
acceptance_imap_idle_target=''
acceptance_imap_uidexpunge=0
acceptance_imap_mutation_phase=0
smtp_matrix_fault=none
smtp_matrix_result=none
smtp_matrix_phase=none
smtp_matrix_protocol=smtp
smtp_matrix_fault_occurrence=1
imap_matrix_fault=none
imap_matrix_result=none
imap_matrix_phase=none
imap_matrix_protocol=imap
case "$acceptance_mail_scenario" in
  smtp-untrusted-certificate) acceptance_smtp_tls_mode=untrusted-cert ;;
  smtp-same-ca-wrong-host) acceptance_smtp_tls_mode=wrong-host ;;
  smtp-tls1.1) acceptance_smtp_tls_mode=legacy-tls ;;
  smtp-auth-before-starttls) acceptance_smtp_tls_mode=auth-before-starttls ;;
  imap-untrusted-certificate) acceptance_imap_tls_terminal_mode=untrusted-cert ;;
  imap-same-ca-wrong-host) acceptance_imap_tls_terminal_mode=wrong-host ;;
  imap-tls1.1) acceptance_imap_tls_terminal_mode=legacy-tls ;;
  imap-idle-wakeup) acceptance_imap_idle=1; acceptance_imap_wait_idle_change=1 ;;
  imap-provider-restart-mid-page) acceptance_imap_idle=1; acceptance_imap_wait_idle_change=1; acceptance_imap_idle_target=INBOX ;;
  imap-expunge) acceptance_imap_uidexpunge=1 ;;
  imap-node-restart-before-ack) acceptance_imap_mutation_phase=0 ;;
  *) : ;;
esac
export PLAINPOST_ACCEPTANCE_SMTP_TLS_MODE="$acceptance_smtp_tls_mode"
export PLAINPOST_ACCEPTANCE_IMAP_TLS_MODE="$acceptance_imap_tls_mode"
export PLAINPOST_ACCEPTANCE_IMAP_IDLE="$acceptance_imap_idle"
export PLAINPOST_ACCEPTANCE_IMAP_WAIT_FOR_IDLE_CHANGE="$acceptance_imap_wait_idle_change"
export PLAINPOST_ACCEPTANCE_IMAP_IDLE_TARGET="$acceptance_imap_idle_target"
export PLAINPOST_ACCEPTANCE_IMAP_UIDEXPUNGE="$acceptance_imap_uidexpunge"
export PLAINPOST_ACCEPTANCE_IMAP_MUTATION_PHASE="$acceptance_imap_mutation_phase"
client_control_pid=''
controller_child_pid=''
controller_child_pgid=''
controller_child_signal_root=''
controller_child_signal_action=''
swift_pid=''
swift_pgid=''
swift_stop_complete=0
acceptance_node_uid=$(id -u)
acceptance_node_gid=$(id -g)
acceptance_node_bootstrap_verifier_file=''
if [ "$transport_release_images" = 1 ]; then
  acceptance_node_uid=65532
  acceptance_node_gid=65532
fi
mail_authority_phase=prestart
client_scenario_started_at=0
swift_log_bytes=0
swift_log_captured=0
swift_stage_log_bytes=0
swift_shutdown_poll_attempts=20
swift_shutdown_poll_delay_seconds=0.25
controller_shutdown_poll_attempts=20
controller_shutdown_poll_delay_seconds=0.25
swift_last_progress_at=0

# The production sync runtime uses its default one-minute poll deadline. The
# generic fixture polls six mailboxes with one shared provider session. Client-
# API control signals therefore need to remain live for one complete provider
# cycle plus a bounded scheduling margin, while the normal harness keeps its
# shorter signal budget.
default_signal_wait_seconds=120
provider_poll_interval_seconds=60
provider_mailbox_count=6
provider_transition_scheduling_margin_seconds=15
provider_cycle_seconds=$((provider_poll_interval_seconds * provider_mailbox_count + provider_transition_scheduling_margin_seconds))
provider_transition_attempts=6
provider_transition_retry_delay_seconds=0.5
client_provider_bounded_phase_count=4
client_signal_idle_timeout_seconds=$((provider_cycle_seconds + 30))
client_scenario_cap_seconds=$((provider_cycle_seconds * client_provider_bounded_phase_count + 60))
default_node_readiness_wait_seconds=120
client_node_readiness_wait_seconds=$((provider_cycle_seconds + 60))
controller_child_timeout_seconds=20
# The default node-restart helper includes its explicit ten-second Compose
# stop grace and ten five-second readiness probes with one-second delays.
node_restart_timeout_seconds=75
# Backup/restore includes a bounded 120-second PTY operation plus Docker and
# PostgreSQL restore work. Keep the child and post-start readiness budgets
# inside Swift's 375-second control wait as one bounded action.
release_backup_restore_timeout_seconds=240
release_backup_restore_readiness_timeout_seconds=120
release_backup_restore_node_start_timeout_seconds=30
# Keep the complete action below Swift's 375-second control wait while still
# allowing the bounded restore operation and post-restore startup to finish.
release_backup_restore_total_timeout_seconds=370
fixture_restart_timeout_seconds=20

requested_attachment_storage=${PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE-}
if [ -n "$requested_attachment_storage" ]; then
  case "$requested_attachment_storage" in
    filesystem|s3) acceptance_attachment_storage=$requested_attachment_storage ;;
    *)
      printf 'unsupported attachment storage: %s\n' "$requested_attachment_storage" >&2
      find "$temporary" -depth -delete >/dev/null 2>&1 || true
      exit 1
      ;;
  esac
else
  acceptance_attachment_storage=s3
fi
acceptance_attachment_dir=''
acceptance_response_drops=${PLAINPOST_SYNC_NODE_ACCEPTANCE_DROP_RESPONSES:-}
if [ "$acceptance_mail_scenario" = imap-node-restart-before-ack ]; then
  case ",$acceptance_response_drops," in
    *,mutation,*) ;;
    *) acceptance_response_drops="${acceptance_response_drops:+$acceptance_response_drops,}mutation" ;;
  esac
fi
acceptance_response_drop_phase_file=''
acceptance_response_drop_dropped_count=0
acceptance_response_drop_exact_replay_count=0
acceptance_response_drop_fresh_committed_count=0
acceptance_response_drop_expected_dropped_count=0
acceptance_response_drop_expected_exact_replay_count=0
acceptance_response_drop_expected_fresh_committed_count=0
imap_authentication_projection_baseline=''
imap_authentication_count_baseline=''
imap_authentication_expected_after=''
imap_tls_projection_baseline=''
imap_tls_authentication_count_baseline=''
imap_tls_handshake_count_baseline=''
provider_restart_header_occurrence=1
acceptance_s3_endpoint=https://minio:9000
acceptance_s3_bucket=plainpost-private
acceptance_s3_region=us-east-1
acceptance_s3_addressing=path
acceptance_s3_access_key_file=/run/secrets/s3_access
acceptance_s3_secret_key_file=/run/secrets/s3_secret
if [ "${PLAINPOST_SYNC_NODE_CLIENT_API:-}" = enabled ] && [ -z "$requested_attachment_storage" ]; then
  acceptance_attachment_storage=filesystem
fi
if [ "$acceptance_attachment_storage" = filesystem ]; then
  acceptance_attachment_dir=/node-attachments
  acceptance_s3_endpoint=''
  acceptance_s3_bucket=''
  acceptance_s3_region=''
  acceptance_s3_addressing=''
  acceptance_s3_access_key_file=''
  acceptance_s3_secret_key_file=''
fi
if [ "${PLAINPOST_SYNC_NODE_CLIENT_API:-}" = enabled ]; then
  acceptance_response_drop_phase_file="$temporary/node-one-data/response-drop-phase"
  acceptance_response_drop_expected_dropped_count=2
  acceptance_response_drop_expected_exact_replay_count=2
  acceptance_response_drop_expected_fresh_committed_count=2
  acceptance_response_drop_restart_expected=1
  if [ -n "$acceptance_mail_scenario" ]; then
    # SMTP matrix cases return after their typed operation and do not request
    # the later full-lifecycle node restart/status recovery triplet.
    acceptance_response_drop_restart_expected=0
    acceptance_response_drop_expected_dropped_count=1
    acceptance_response_drop_expected_exact_replay_count=1
    acceptance_response_drop_expected_fresh_committed_count=1
  fi
  if [ "$acceptance_mail_scenario" = imap-node-restart-before-ack ]; then
    acceptance_response_drop_expected_dropped_count=2
    acceptance_response_drop_expected_exact_replay_count=2
    acceptance_response_drop_expected_fresh_committed_count=2
  fi
fi

if [ "${PLAINPOST_SYNC_NODE_ATTACHMENT_STORAGE_SELECTION_TEST:-}" = enabled ]; then
  if [ "$acceptance_attachment_storage" = s3 ]; then
    printf 'attachment-storage-selection storage=s3 dir=%s s3=enabled\n' "$acceptance_attachment_dir"
  else
    printf 'attachment-storage-selection storage=filesystem dir=%s s3=disabled\n' "$acceptance_attachment_dir"
  fi
  find "$temporary" -depth -delete >/dev/null 2>&1 || true
  exit 0
fi

compose_run() {
  if [ -n "$transport_release_override" ]; then
    PLAINPOST_PRIVATE_ROOT="$temporary" \
    PLAINPOST_PRIVATE_NODE_IMAGE="$node_image" \
    PLAINPOST_ACCEPTANCE_NODE_UID="$acceptance_node_uid" \
    PLAINPOST_ACCEPTANCE_NODE_GID="$acceptance_node_gid" \
    PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE="$acceptance_attachment_storage" \
    PLAINPOST_ACCEPTANCE_ATTACHMENT_DIR="$acceptance_attachment_dir" \
    PLAINPOST_ACCEPTANCE_DROP_RESPONSES="$acceptance_response_drops" \
    PLAINPOST_ACCEPTANCE_S3_ENDPOINT="$acceptance_s3_endpoint" \
    PLAINPOST_ACCEPTANCE_S3_BUCKET="$acceptance_s3_bucket" \
    PLAINPOST_ACCEPTANCE_S3_REGION="$acceptance_s3_region" \
    PLAINPOST_ACCEPTANCE_S3_ADDRESSING="$acceptance_s3_addressing" \
    PLAINPOST_ACCEPTANCE_S3_ACCESS_KEY_FILE="$acceptance_s3_access_key_file" \
    PLAINPOST_ACCEPTANCE_S3_SECRET_KEY_FILE="$acceptance_s3_secret_key_file" \
    PLAINPOST_ACCEPTANCE_NODE_BOOTSTRAP_VERIFIER_FILE="$acceptance_node_bootstrap_verifier_file" \
    PLAINPOST_RELEASE_CENTRAL_IMAGE="$release_central_image" \
    PLAINPOST_RELEASE_NODE_IMAGE="$release_node_image" \
    docker compose -p "$project" -f "$compose" -f "$release_compose_override" "$@"
  else
    PLAINPOST_PRIVATE_ROOT="$temporary" \
    PLAINPOST_PRIVATE_NODE_IMAGE="$node_image" \
    PLAINPOST_ACCEPTANCE_NODE_UID="$acceptance_node_uid" \
    PLAINPOST_ACCEPTANCE_NODE_GID="$acceptance_node_gid" \
    PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE="$acceptance_attachment_storage" \
    PLAINPOST_ACCEPTANCE_ATTACHMENT_DIR="$acceptance_attachment_dir" \
    PLAINPOST_ACCEPTANCE_DROP_RESPONSES="$acceptance_response_drops" \
    PLAINPOST_ACCEPTANCE_S3_ENDPOINT="$acceptance_s3_endpoint" \
    PLAINPOST_ACCEPTANCE_S3_BUCKET="$acceptance_s3_bucket" \
    PLAINPOST_ACCEPTANCE_S3_REGION="$acceptance_s3_region" \
    PLAINPOST_ACCEPTANCE_S3_ADDRESSING="$acceptance_s3_addressing" \
    PLAINPOST_ACCEPTANCE_S3_ACCESS_KEY_FILE="$acceptance_s3_access_key_file" \
    PLAINPOST_ACCEPTANCE_S3_SECRET_KEY_FILE="$acceptance_s3_secret_key_file" \
    PLAINPOST_ACCEPTANCE_NODE_BOOTSTRAP_VERIFIER_FILE="$acceptance_node_bootstrap_verifier_file" \
    docker compose -p "$project" -f "$compose" "$@"
  fi
}

# SQLite WAL shared through an OrbStack bind mount cannot safely be opened by
# a host Python process while a fixture container has the same database open:
# the host and VM do not share SQLite's WAL shared-memory locking domain. Once
# a fixture exists, keep every authority/control read and write in that same
# container namespace. The host fallback is limited to pre-start setup, when
# no fixture can access the state yet.
mail_fixture_running() {
  mail_fixture_container=$(compose_run ps -q imap-fixture 2>/dev/null || true)
  [ -n "$mail_fixture_container" ] || return 1
  [ "$(docker inspect --format '{{.State.Status}}' "$mail_fixture_container" 2>/dev/null || true)" = running ]
}

mail_control() {
  if [ "$mail_authority_phase" = prestart ]; then
    python3 "$temporary/mail-fixture/plainpost_acceptance_mail_control.py" --root "$temporary/mail-state" "$@"
  elif mail_fixture_running; then
    compose_run exec -T imap-fixture python3 /opt/plainpost/plainpost_acceptance_mail_control.py --root /var/lib/plainpost "$@"
  else
    printf 'mail_control post-start authority requires a live fixture container\n' >&2
    return 1
  fi
}

mail_python() {
  if [ "$mail_authority_phase" = prestart ]; then
    PYTHONPATH="$temporary/mail-fixture" PLAINPOST_ACCEPTANCE_MAIL_ROOT="$temporary/mail-state" python3 "$@"
  elif mail_fixture_running; then
    compose_run exec -T imap-fixture python3 "$@"
  else
    printf 'mail_python post-start authority requires a live fixture container\n' >&2
    return 1
  fi
}

run_controller_child() {
  controller_action=$1
  controller_timeout=$2
  shift 2
  acceptance_controller_run "$temporary/control" "$controller_action" "$controller_timeout" "$@" >>"$runtime_log" 2>&1
}

signal_once() {
  acceptance_controller_signal_once "$@"
}

control_marker() {
  case "$1" in
    authority-outage-*|authority-recover-*|node-one-restart-*|node-one-readiness-*|node-one-checkpoint-*|node-one-hot-ready-*|node-one-publish-*|node-two-*) ;;
    *)
      printf 'ERROR acceptance-control stage=invalid\n' >>"$runtime_log"
      return 1
      ;;
  esac
  printf 'ERROR acceptance-control stage=%s\n' "$1" >>"$runtime_log"
}

restart_node_bounded() {
  restart_service=$1
  restart_hostname=$2
  restart_port=$3
  restart_action=$4
  restart_mode=${5:-readiness}
  rm -f "$temporary/$restart_action.applied" "$temporary/$restart_action.failed"
  if ! acceptance_controller_run "$temporary" "$restart_action" "$node_restart_timeout_seconds" env \
    "$root/Scripts/lib/acceptance-node-restart.sh" \
    "$compose" "$project" "$temporary" "$restart_service" "$node_image" \
    "$acceptance_node_uid" "$acceptance_node_gid" "$acceptance_attachment_storage" \
    "$acceptance_attachment_dir" "$acceptance_response_drops" "$acceptance_s3_endpoint" \
    "$acceptance_s3_bucket" "$acceptance_s3_region" "$acceptance_s3_addressing" \
    "$acceptance_s3_access_key_file" "$acceptance_s3_secret_key_file" \
    "$restart_hostname" "$restart_port" "$restart_mode" >>"$runtime_log" 2>&1; then
    rm -f "$temporary/$restart_action.applied" "$temporary/$restart_action.failed"
    return 1
  fi
  rm -f "$temporary/$restart_action.applied" "$temporary/$restart_action.failed"
}

run_release_backup_restore() {
  [ "$transport_release_images" = 1 ] || {
    printf 'release backup restore requires release images\n' >&2
    return 1
  }
  [ "$acceptance_attachment_storage" = filesystem ] || {
    printf 'release backup restore requires filesystem attachment storage\n' >&2
    return 1
  }
  release_backup_restore_deadline_ms=$(( $(acceptance_controller_monotonic_ms) + release_backup_restore_total_timeout_seconds * 1000 ))
  release_backup_restore_remaining_seconds() {
    release_backup_restore_remaining_ms=$((release_backup_restore_deadline_ms - $(acceptance_controller_monotonic_ms)))
    release_backup_restore_remaining=$(( (release_backup_restore_remaining_ms + 999) / 1000 ))
    [ "$release_backup_restore_remaining" -gt 0 ]
  }
  release_backup_restore_remaining_seconds || return 1
  rm -f "$temporary/control/release-backup-restore-run.applied" "$temporary/control/release-backup-restore-run.failed"
  release_backup_restore_child_status=0
  release_backup_restore_child_timeout=$release_backup_restore_remaining
  [ "$release_backup_restore_child_timeout" -le "$release_backup_restore_timeout_seconds" ] || release_backup_restore_child_timeout=$release_backup_restore_timeout_seconds
  run_controller_child release-backup-restore-run "$release_backup_restore_child_timeout" env \
    PLAINPOST_RELEASE_CENTRAL_IMAGE="$release_central_image" \
    "$root/Scripts/lib/acceptance-release-backup-restore.sh" \
    "$compose" "$project" "$temporary" "$transport_release_override" "$node_image" \
    "$acceptance_node_uid" "$acceptance_node_gid" "$acceptance_attachment_storage" \
    "$acceptance_attachment_dir" "$acceptance_s3_endpoint" "$acceptance_s3_bucket" \
    "$acceptance_s3_region" "$acceptance_s3_addressing" "$acceptance_s3_access_key_file" \
    "$acceptance_s3_secret_key_file" "$runtime_log" "$root" || release_backup_restore_child_status=$?
  if release_backup_restore_remaining_seconds; then
    release_backup_restore_cleanup_timeout=$release_backup_restore_remaining
    if ! acceptance_controller_run "$temporary/control" release-backup-restore-cleanup "$release_backup_restore_cleanup_timeout" \
      "$release_backup_restore_cleanup" "$project" >>"$runtime_log" 2>&1; then
      release_backup_restore_child_status=1
    fi
  else
    printf 'ERROR release-backup-restore action-deadline-exceeded step=cleanup\n' >>"$runtime_log"
    release_backup_restore_child_status=1
  fi
  return "$release_backup_restore_child_status"
}

release_backup_restore_post_child_step() {
  case "$1" in
    reference-validation|quarantine|attachment-quarantine|audit-secret-promotion|node-start|readiness|marker-publish) ;;
    *) return 1 ;;
  esac
  case "$2" in
    begin|passed|failed) ;;
    *) return 1 ;;
  esac
  printf 'ERROR release-backup-restore post-child-step=%s status=%s\n' "$1" "$2" >>"$runtime_log"
}

is_nonnegative_integer() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

assert_expected_imap_blocked_checkpoint() {
  expected_blocked_tag=$1
  case "$expected_blocked_tag" in
    authentication|tls) ;;
    *) return 1 ;;
  esac
  blocked_checkpoint_state=$(docker exec "$node_one_database_container" psql -U "$node_database_inspection_role" -d "$node_one_database_name" -Atc \
    "SELECT count(*) FILTER (WHERE blocked_error_tag='$expected_blocked_tag' AND baseline_state='complete' AND cursor IS NOT NULL AND cursor<>'' AND projection_revision IS NOT NULL AND projection_revision>0)::text || ':' || count(*) FILTER (WHERE blocked_error_tag IS DISTINCT FROM '$expected_blocked_tag' OR baseline_state IS DISTINCT FROM 'complete' OR cursor IS NULL OR cursor='' OR projection_revision IS NULL OR projection_revision<=0)::text FROM node_provider_mailboxes WHERE active AND blocked_error_tag IS NOT NULL" 2>>"$runtime_log" || true)
  blocked_checkpoint_count=${blocked_checkpoint_state%%:*}
  blocked_checkpoint_invalid_count=${blocked_checkpoint_state#*:}
  if ! is_nonnegative_integer "$blocked_checkpoint_count" ||
     ! is_nonnegative_integer "$blocked_checkpoint_invalid_count" ||
     [ "$blocked_checkpoint_count" -lt 1 ] ||
     [ "$blocked_checkpoint_invalid_count" -ne 0 ]; then
    printf 'ERROR acceptance-imap-%s-durable-block outcome=checkpoint-invalid\n' "$expected_blocked_tag" >>"$runtime_log"
    return 1
  fi
}

assert_expected_imap_authentication_startup_fault() {
  if ! docker logs --tail 200 "$node_one_container" 2>&1 | grep -E '"stage":"runtime-provider-failure".*"provider_tag":"authentication".*"retry_disposition":"never"' >/dev/null; then
    printf 'ERROR acceptance-imap-authentication-startup-fault outcome=missing-provider\n' >>"$runtime_log"
    return 1
  fi
  imap_authentication_count=$(mail_python -c 'from plainpost_acceptance_mail_state import read; print(next((item["count"] for item in read()["phase_counters"] if item["protocol"] == "imap" and item["phase"] == "authentication"), 0))')
  if ! is_nonnegative_integer "$imap_authentication_count_baseline" ||
     ! is_nonnegative_integer "$imap_authentication_expected_after" ||
     ! is_nonnegative_integer "$imap_authentication_count" ||
     [ "$imap_authentication_count" != "$imap_authentication_expected_after" ]; then
    printf 'ERROR acceptance-imap-authentication-startup-fault outcome=authentication-changed\n' >>"$runtime_log"
    return 1
  fi
  if ! assert_expected_imap_blocked_checkpoint authentication; then
    return 1
  fi
  projection_after_authentication=$(docker exec "$node_one_database_container" psql -U "$node_database_inspection_role" -d "$node_one_database_name" -Atc \
    "SELECT COALESCE(string_agg(revision::text,',' ORDER BY revision),'none') || ':' || count(*)::text || ':' || count(DISTINCT message_id)::text FROM node_projection_changes" 2>>"$runtime_log" || true)
  if [ -z "$imap_authentication_projection_baseline" ] || [ "$projection_after_authentication" != "$imap_authentication_projection_baseline" ]; then
    printf 'ERROR acceptance-imap-authentication-durable-block outcome=projection-changed\n' >>"$runtime_log"
    return 1
  fi
  printf 'ERROR acceptance-imap-authentication-startup-fault outcome=expected\n' >>"$runtime_log"
  printf 'ERROR acceptance-imap-authentication-durable-block outcome=expected\n' >>"$runtime_log"
}

assert_expected_imap_tls_startup_fault() {
  if ! docker logs --tail 200 "$node_one_container" 2>&1 | grep -E '"stage":"runtime-provider-failure".*"provider_tag":"tls".*"retry_disposition":"never"' >/dev/null; then
    printf 'ERROR acceptance-imap-tls-startup-fault outcome=missing-provider\n' >>"$runtime_log"
    return 1
  fi
  imap_tls_authentication_count=$(mail_python -c 'from plainpost_acceptance_mail_state import read; print(next((item["count"] for item in read()["phase_counters"] if item["protocol"] == "imap" and item["phase"] == "authentication"), 0))')
  imap_tls_handshake_count=$(mail_python -c 'from plainpost_acceptance_mail_state import read; print(sum(1 for item in read()["observations"] if item["kind"] == "test-observation" and item["protocol"] == "imap" and item["phase"] == "tls-handshake"))')
  if ! is_nonnegative_integer "$imap_tls_authentication_count_baseline" ||
     ! is_nonnegative_integer "$imap_tls_authentication_count" ||
     [ "$imap_tls_authentication_count" != "$imap_tls_authentication_count_baseline" ]; then
    printf 'ERROR acceptance-imap-tls-startup-fault outcome=authentication-changed\n' >>"$runtime_log"
    return 1
  fi
  imap_tls_handshake_proof=''
  if ! is_nonnegative_integer "$imap_tls_handshake_count_baseline" ||
     ! is_nonnegative_integer "$imap_tls_handshake_count"; then
    printf 'ERROR acceptance-imap-tls-startup-fault outcome=handshake-missing\n' >>"$runtime_log"
    return 1
  elif [ "$imap_tls_handshake_count" -gt "$imap_tls_handshake_count_baseline" ]; then
    imap_tls_handshake_proof=observed
  elif [ "$acceptance_mail_scenario" = imap-tls1.1 ] &&
       [ "$acceptance_imap_tls_terminal_mode" = legacy-tls ] &&
       [ "$imap_tls_handshake_count" = "$imap_tls_handshake_count_baseline" ]; then
    imap_tls_handshake_proof=pre-sni-rejected
  else
    printf 'ERROR acceptance-imap-tls-startup-fault outcome=handshake-missing\n' >>"$runtime_log"
    return 1
  fi
  if ! assert_expected_imap_blocked_checkpoint tls; then
    return 1
  fi
  projection_after_tls=$(docker exec "$node_one_database_container" psql -U "$node_database_inspection_role" -d "$node_one_database_name" -Atc \
    "SELECT COALESCE(string_agg(revision::text,',' ORDER BY revision),'none') || ':' || count(*)::text || ':' || count(DISTINCT message_id)::text FROM node_projection_changes" 2>>"$runtime_log" || true)
  if [ -z "$imap_tls_projection_baseline" ] || [ "$projection_after_tls" != "$imap_tls_projection_baseline" ]; then
    printf 'ERROR acceptance-imap-tls-durable-block outcome=projection-changed\n' >>"$runtime_log"
    return 1
  fi
  printf 'ERROR acceptance-imap-tls-startup-fault outcome=expected handshake=%s\n' "$imap_tls_handshake_proof" >>"$runtime_log"
  printf 'ERROR acceptance-imap-tls-durable-block outcome=expected\n' >>"$runtime_log"
}

cleanup_failure() {
  case " $cleanup_categories " in
    *" $1 "*) ;;
    *)
      cleanup_categories="$cleanup_categories $1"
      printf 'private acceptance cleanup failed category=%s\n' "$1" >&2
      ;;
  esac
  cleanup_status=1
}

capture_acceptance_provider_state() {
  [ "$acceptance_provider_state_captured" -eq 0 ] || return 0
  acceptance_provider_state_captured=1

  diagnostic_database_container="${node_one_database_container:-}"
  if [ -z "$diagnostic_database_container" ]; then
    diagnostic_database_container=$(compose_run ps -q "$release_node_one_database_service" 2>>"$runtime_log" || true)
  fi
  [ -n "$diagnostic_database_container" ] || return 0

  if ! refresh_active_node_database_name; then
    printf 'ERROR acceptance-provider-state database=unknown outcome=reference-unavailable\n' >>"$runtime_log"
    return 0
  fi

  printf 'ERROR acceptance-provider-state node=node-one\n' >>"$runtime_log"
  docker exec "$diagnostic_database_container" psql -U "$node_database_inspection_role" -d "$node_one_database_name" -Atc \
    "SELECT 'ERROR acceptance-provider-state mailbox=' || provider_mailbox_id || E' active=' || active::text || E' baseline=' || baseline_state || E' failures=' || failure_count::text || E' blocked=' || COALESCE(blocked_error_tag, '') FROM node_provider_mailboxes ORDER BY provider_mailbox_id; SELECT 'ERROR acceptance-provider-state projection_head=' || COALESCE(string_agg(revision::text, ',' ORDER BY account_id), 'none') FROM node_projection_heads; SELECT 'ERROR acceptance-provider-state projection_change_count=' || count(*)::text FROM node_projection_changes; SELECT 'ERROR acceptance-provider-state projection_message_count=' || count(DISTINCT message_id)::text FROM node_projection_changes WHERE message_id IS NOT NULL; SELECT 'ERROR acceptance-provider-state projection_membership_count=' || count(*)::text FROM node_memberships; SELECT 'ERROR acceptance-provider-state generic_sync_mailboxes=' || COALESCE(string_agg(COALESCE(generic_profile->'SyncMailboxIDs', 'null'::jsonb)::text, ',' ORDER BY account_id, logical_mailbox), 'none') FROM node_provider_session_configs WHERE provider_kind='generic';" \
    >>"$runtime_log" 2>&1 || true
}

cleanup() {
  cleanup_status=0
  cleanup_categories=''
  if [ "$cleanup_running" -eq 1 ]; then
    cleanup_failure cleanup-reentry
  else
    cleanup_running=1
    cleanup_started=1
    printf 'stage=cleanup\n'

    if ! compose_run down --volumes --remove-orphans >>"$runtime_log" 2>&1; then
      cleanup_failure compose-down
    fi

    if ! retained_containers=$(docker ps -aq --filter "label=com.docker.compose.project=$project" 2>>"$runtime_log"); then
      retained_containers=''
      cleanup_failure containers-query
    fi
    for container in $retained_containers; do
      if ! docker rm -f "$container" >>"$runtime_log" 2>&1; then
        cleanup_failure containers-remove
      fi
    done
    if ! retained_containers=$(docker ps -aq --filter "label=com.docker.compose.project=$project" 2>>"$runtime_log"); then
      retained_containers=''
      cleanup_failure containers-query
    fi
    if [ -n "$retained_containers" ]; then
      cleanup_failure containers-retained
    fi

    # Compose down is best effort during failure handling. Force-remove the
    # exact project containers before attempting image removal; otherwise a
    # stopped container can retain the release-shaped image and make a false
    # cleanup pass possible.
    if [ "$node_image_built" -eq 1 ]; then
      if docker image inspect "$node_image" >>"$runtime_log" 2>&1; then
        if ! docker image rm "$node_image" >>"$runtime_log" 2>&1; then
          cleanup_failure runtime-image
        fi
      fi
      if docker image inspect "$node_image" >>"$runtime_log" 2>&1; then
        cleanup_failure runtime-image
      fi
    fi

    if ! retained_volumes=$(docker volume ls -q --filter "label=com.docker.compose.project=$project" 2>>"$runtime_log"); then
      retained_volumes=''
      cleanup_failure volumes-query
    fi
    for volume in $retained_volumes; do
      if ! docker volume rm "$volume" >>"$runtime_log" 2>&1; then
        cleanup_failure volumes-remove
      fi
    done
    if ! retained_volumes=$(docker volume ls -q --filter "label=com.docker.compose.project=$project" 2>>"$runtime_log"); then
      retained_volumes=''
      cleanup_failure volumes-query
    fi
    if [ -n "$retained_volumes" ]; then
      cleanup_failure volumes-retained
    fi

    if ! retained_networks=$(docker network ls -q --filter "label=com.docker.compose.project=$project" 2>>"$runtime_log"); then
      retained_networks=''
      cleanup_failure networks-query
    fi
    for network in $retained_networks; do
      if ! docker network rm "$network" >>"$runtime_log" 2>&1; then
        cleanup_failure networks-remove
      fi
    done
    if ! retained_networks=$(docker network ls -q --filter "label=com.docker.compose.project=$project" 2>>"$runtime_log"); then
      retained_networks=''
      cleanup_failure networks-query
    fi
    if [ -n "$retained_networks" ]; then
      cleanup_failure networks-retained
    fi

    if [ -e "$temporary/go-cache" ]; then
      if ! find "$temporary/go-cache" -depth -delete >>"$runtime_log" 2>&1; then
        cleanup_failure generated-cache
      fi
    fi
    if [ -e "$temporary/go-cache" ]; then
      cleanup_failure generated-cache
    fi
    if [ -e "$temporary" ]; then
      if ! find "$temporary" -depth -delete >>"$runtime_log" 2>&1; then
        cleanup_failure private-temp
      fi
    fi
    if [ -e "$temporary" ]; then
      cleanup_failure private-temp
    fi
    cleanup_running=0
  fi
  return "$cleanup_status"
}
run_in_owned_session() {
  exec python3 "$process_supervisor" -- "$@"
}
capture_owned_process_group() {
  [ -n "$swift_pid" ] || return 1
  harness_pgid=$(python3 -c 'import os; print(os.getpgrp())' 2>/dev/null | tr -d '[:space:]' || true)
  case "$swift_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$harness_pgid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ "$swift_pid" -le 1 ] || [ "$swift_pid" = "$harness_pgid" ]; then
    return 1
  fi
  swift_pgid=''
  return 0
}
process_is_live_non_zombie() {
  process_pid=$1
  case "$process_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$process_pid" 2>/dev/null || return 1
  process_state=$(ps -p "$process_pid" -o stat= 2>/dev/null | tr -d '[:space:]' || true)
  case "$process_state" in
    Z*) return 1 ;;
    '') return 0 ;;
    *) return 0 ;;
  esac
}
process_stopped() {
  process_pid=$1
  for _ in $(seq 1 40); do
    process_is_live_non_zombie "$process_pid" || return 0
    sleep 0.05
  done
  return 1
}
swift_process_alive() {
  if [ -n "$swift_pid" ] && process_is_live_non_zombie "$swift_pid"; then
    return 0
  fi
  return 1
}
signal_swift_process() {
  signal=$1
  if [ -n "$swift_pid" ]; then
    kill "-$signal" "$swift_pid" 2>/dev/null || true
  fi
}
stop_swift_process() {
  [ "$swift_stop_complete" -eq 0 ] || return 0
  swift_stop_complete=1
  [ -n "$swift_pid" ] || return 0

  swift_was_alive=0
  if swift_process_alive; then
    swift_was_alive=1
    signal_swift_process TERM
    for _ in $(seq 1 "$swift_shutdown_poll_attempts"); do
      swift_process_alive || break
      sleep "$swift_shutdown_poll_delay_seconds"
    done
    if swift_process_alive; then
      signal_swift_process KILL
    fi
  fi
  wait "$swift_pid" 2>/dev/null || true
  if [ "$swift_was_alive" -eq 1 ]; then
    printf 'ERROR swift-process-termination outcome=forced\n' >>"$runtime_log"
  fi
  swift_pid=''
  swift_pgid=''
}
capture_swift_log() {
  [ "$swift_log_captured" -eq 0 ] || return 0
  swift_log_captured=1
  if [ -s "$temporary/swift.log" ]; then
    cat "$temporary/swift.log" >>"$runtime_log" 2>&1 || true
  fi
}
stop_controller_child() {
  acceptance_controller_stop_child
}
controller_interrupted() {
  stop_controller_child
  exit "${1:-143}"
}
stop_client_control_loop() {
  for loop_pid in "$client_control_pid"; do
    [ -n "$loop_pid" ] || continue
    kill -TERM "$loop_pid" 2>/dev/null || true
    for _ in $(seq 1 "$controller_shutdown_poll_attempts"); do
      kill -0 "$loop_pid" 2>/dev/null || break
      sleep "$controller_shutdown_poll_delay_seconds"
    done
    if kill -0 "$loop_pid" 2>/dev/null; then
      kill -KILL "$loop_pid" 2>/dev/null || true
    fi
    wait "$loop_pid" 2>/dev/null || true
  done
  client_control_pid=''
}
run_process_cleanup_test() {
  process_cleanup_child_file="$temporary/process-cleanup-child.pid"
  run_in_owned_session sh -c 'sleep 120 & child=$!; printf "%s\n" "$child" >"$1"; wait "$child"' sh "$process_cleanup_child_file" &
  swift_pid=$!
  if ! capture_owned_process_group; then
    printf 'process-cleanup-test=failed reason=owned-pgid-not-captured\n' >&2
    stop_swift_process
    return 1
  fi
  process_cleanup_parent_pid=$swift_pid
  for _ in $(seq 1 20); do
    [ -s "$process_cleanup_child_file" ] && break
    sleep 0.05
  done
  [ -s "$process_cleanup_child_file" ] || {
    printf 'process-cleanup-test=failed reason=child-not-started\n' >&2
    stop_swift_process
    return 1
  }
  process_cleanup_child_pid=$(tr -d '[:space:]' <"$process_cleanup_child_file")
  stop_swift_process
  if ! process_stopped "$process_cleanup_parent_pid" || ! process_stopped "$process_cleanup_child_pid"; then
    printf 'process-cleanup-test=failed reason=owned-process-remains\n' >&2
    return 1
  fi
  [ -z "$swift_pid" ] || {
    printf 'process-cleanup-test=failed reason=swift-pid-not-cleared\n' >&2
    return 1
  }
  swift_stop_complete=0
  process_cleanup_unrelated_sentinel_pid=''
  sleep 120 &
  process_cleanup_unrelated_sentinel_pid=$!
  process_cleanup_detached_child_file="$temporary/process-cleanup-detached-child.pid"
  run_in_owned_session python3 -c 'import os,sys,time; (os.setsid(), open(sys.argv[1],"w").write(str(os.getpid())), time.sleep(30)) if os.fork() == 0 else os.wait()' "$process_cleanup_detached_child_file" &
  swift_pid=$!
  if ! capture_owned_process_group; then
    printf 'process-cleanup-detached-test=failed reason=owned-pgid-not-captured\n' >&2
    stop_swift_process
    kill -KILL "$process_cleanup_unrelated_sentinel_pid" 2>/dev/null || true
    wait "$process_cleanup_unrelated_sentinel_pid" 2>/dev/null || true
    return 1
  fi
  for _ in $(seq 1 20); do
    [ -s "$process_cleanup_detached_child_file" ] && break
    sleep 0.05
  done
  [ -s "$process_cleanup_detached_child_file" ] || {
    printf 'process-cleanup-detached-test=failed reason=child-not-started\n' >&2
    stop_swift_process
    kill -KILL "$process_cleanup_unrelated_sentinel_pid" 2>/dev/null || true
    wait "$process_cleanup_unrelated_sentinel_pid" 2>/dev/null || true
    return 1
  }
  process_cleanup_detached_child_pid=$(tr -d '[:space:]' <"$process_cleanup_detached_child_file")
  stop_swift_process
  if ! process_is_live_non_zombie "$process_cleanup_unrelated_sentinel_pid"; then
    printf 'process-cleanup-detached-test=failed reason=unrelated-sentinel-was-touched\n' >&2
    return 1
  fi
  if ! process_stopped "$process_cleanup_detached_child_pid"; then
    kill -KILL "$process_cleanup_detached_child_pid" 2>/dev/null || true
    kill -KILL "$process_cleanup_unrelated_sentinel_pid" 2>/dev/null || true
    wait "$process_cleanup_unrelated_sentinel_pid" 2>/dev/null || true
    printf 'process-cleanup-detached-test=failed reason=detached-child-survived-group-stop\n' >&2
    return 1
  fi
  kill -TERM "$process_cleanup_unrelated_sentinel_pid" 2>/dev/null || true
  wait "$process_cleanup_unrelated_sentinel_pid" 2>/dev/null || true
  swift_stop_complete=0
  process_cleanup_child_file="$temporary/process-cleanup-leader-exited-child.pid"
  run_in_owned_session sh -c 'sleep 120 & child=$!; printf "%s\n" "$child" >"$1"; sleep 0.2; exit 0' sh "$process_cleanup_child_file" &
  swift_pid=$!
  if ! capture_owned_process_group; then
    printf 'process-cleanup-leader-exit-test=failed reason=owned-pgid-not-captured\n' >&2
    stop_swift_process
    return 1
  fi
  sleep 0.1
  if ! process_is_live_non_zombie "$swift_pid"; then
    printf 'process-cleanup-leader-exit-test=failed reason=supervisor-did-not-remain\n' >&2
    stop_swift_process
    return 1
  fi
  process_cleanup_child_pid=$(tr -d '[:space:]' <"$process_cleanup_child_file")
  if ! process_is_live_non_zombie "$process_cleanup_child_pid"; then
    printf 'process-cleanup-leader-exit-test=failed reason=child-did-not-survive-target\n' >&2
    return 1
  fi
  stop_swift_process
  if ! process_stopped "$process_cleanup_child_pid"; then
    printf 'process-cleanup-leader-exit-test=failed reason=child-survived-group-stop\n' >&2
    return 1
  fi
  printf 'process-cleanup-success-path-test=passed\n'
  printf 'process-cleanup-leader-exit-child-survived=passed\n'
  printf 'process-cleanup-leader-exit-test=passed\n'
  printf 'process-cleanup-test=passed\n'
  find "$temporary" -depth -delete >/dev/null 2>&1 || true
  [ ! -e "$temporary" ]
}
run_privacy_failure_test() {
  : >"$patterns"
  chmod 0600 "$patterns"
  privacy_test_secret='plainpost-privacy-forced-failure-secret-20260828'
  privacy_test_base64=$(printf '%s' "$privacy_test_secret" | base64 | tr -d '\n')
  privacy_test_hex=$(printf '%s' "$privacy_test_secret" | xxd -p | tr -d '\n')
  printf '%s\n%s\n%s\n' "$privacy_test_secret" "$privacy_test_base64" "$privacy_test_hex" >>"$patterns"
  privacy_test_log="$temporary/privacy-failure.log"
  printf 'ERROR forced-failure secret=%s base64=%s hex=%s\n' "$privacy_test_secret" "$privacy_test_base64" "$privacy_test_hex" >"$privacy_test_log"
  privacy_test_filtered=$(grep -F -v -f "$patterns" "$privacy_test_log" || true)
  case "$privacy_test_filtered" in
    *"$privacy_test_secret"*|*"$privacy_test_base64"*|*"$privacy_test_hex"*)
      printf 'privacy-failure-test=failed\n' >&2
      return 1
      ;;
  esac
  printf 'privacy-failure-test=passed\n'
  find "$temporary" -depth -delete >/dev/null 2>&1 || true
  [ ! -e "$temporary" ]
}
emit_node_two_presentation_failure_summary() {
  node_two_summary_log=${PLAINPOST_SYNC_NODE_NODE_TWO_PRESENTATION_SUMMARY_LOG:-$runtime_log}
  node_two_summary_patterns=${PLAINPOST_SYNC_NODE_NODE_TWO_PRESENTATION_SUMMARY_PATTERNS:-$patterns}
  printf 'node_two_presentation_failure_summary_begin\n' >&2
  grep -E '^(ERROR acceptance-node-two-presentation outcome=(ready|failed) restart_status=[0-9]+ command_status=[0-9]+ attempts=[0-9]+ elapsed_seconds=[0-9]+ timeout_seconds=[0-9]+|ERROR node-two-presentation unavailable|stage=node-two-presentation|ERROR controller-(child-timeout|descendant-survived|child-reaped) action=node-two-presentation-(restart|probe-[0-9]+)( |$))' "$node_two_summary_log" | filter_summary_patterns "$node_two_summary_patterns" | tail -40 >&2 || true
  printf 'node_two_presentation_failure_summary_end\n' >&2
}
emit_attachment_diagnostic_summary() {
  attachment_summary_log=${PLAINPOST_SYNC_NODE_ATTACHMENT_DIAGNOSTIC_SUMMARY_LOG:-$runtime_log}
  attachment_summary_patterns=${PLAINPOST_SYNC_NODE_ATTACHMENT_DIAGNOSTIC_SUMMARY_PATTERNS:-$patterns}
  printf 'attachment_diagnostic_summary_begin\n' >&2
  sed -E 's/"//g; s/:/=/g' "$attachment_summary_log" | grep -E '\[DEBUG-sync-node-attachment\].*(category(=|":")(hydrate|open)).*(stage(=|":")(ref-validate|work-admission|quota-config|claim|claim-status|claim-wait|claim-config|provider-fetch|encrypt-read|descriptor-match|digest|canonical-identity|seal|available-adoption|publish|commit|record|check|open|capability-resolve|capability-validate|capability-ref|capability-hydrate-handoff|capability-hydrate-result|capability-refresh|capability-open-handoff|capability-reader-size)).*(outcome(=|":")failed).*(ok(=|":")(true|false)).*(count_class(=|":")(zero|one|many)).*(error_class(=|":")(none|invalid|not_found|not_hydrated|quota_exceeded|conflict|corrupt|unavailable|cleanup_required|closed|canceled|deadline|unknown))' | filter_summary_patterns "$attachment_summary_patterns" | tail -80 >&2 || true
  printf 'attachment_diagnostic_summary_end\n' >&2
}
emit_attachment_stream_summary() {
  attachment_stream_summary_log=${PLAINPOST_SYNC_NODE_ATTACHMENT_STREAM_SUMMARY_LOG:-$runtime_log}
  attachment_stream_summary_patterns=${PLAINPOST_SYNC_NODE_ATTACHMENT_STREAM_SUMMARY_PATTERNS:-$patterns}
  printf 'attachment_stream_summary_begin\n' >&2
  sed -E 's/"//g; s/:/=/g' "$attachment_stream_summary_log" | grep -E '\[DEBUG-sync-node-attachment\].*category(=|":")stream.*route(=|":")attachment.*phase(=|":")(copy|trailing-probe).*(outcome(=|":")(completed|failed)).*(error_class(=|":")(none|canceled|deadline|stream|trailing-data))$' | filter_summary_patterns "$attachment_stream_summary_patterns" | tail -80 >&2 || true
  printf 'attachment_stream_summary_end\n' >&2
}
emit_imap_terminal_failure_summary() {
  imap_terminal_summary_log=${PLAINPOST_SYNC_NODE_IMAP_TERMINAL_FAILURE_SUMMARY_LOG:-$runtime_log}
  imap_terminal_summary_patterns=${PLAINPOST_SYNC_NODE_IMAP_TERMINAL_FAILURE_SUMMARY_PATTERNS:-$patterns}
  printf 'imap_terminal_failure_summary_begin\n' >&2
  grep -E '^ERROR acceptance-imap-(authentication|tls)-(startup-fault|durable-block) outcome=(authentication-changed|handshake-missing|checkpoint-invalid|projection-changed)$' "$imap_terminal_summary_log" | filter_summary_patterns "$imap_terminal_summary_patterns" | tail -80 >&2 || true
  printf 'imap_terminal_failure_summary_end\n' >&2
}
emit_imap_catalog_probe_failure_summary() {
  catalog_probe_summary_log=${PLAINPOST_SYNC_NODE_IMAP_CATALOG_PROBE_SUMMARY_LOG:-$runtime_log}
  catalog_probe_summary_patterns=${PLAINPOST_SYNC_NODE_IMAP_CATALOG_PROBE_SUMMARY_PATTERNS:-$patterns}
  printf 'imap_catalog_probe_failure_summary_begin\n' >&2
  grep -E '^ERROR acceptance-imap-catalog-probe outcome=failed step=(arm|expected-unavailable|recovery|projection)$' "$catalog_probe_summary_log" | filter_summary_patterns "$catalog_probe_summary_patterns" | tail -80 >&2 || true
  printf 'imap_catalog_probe_failure_summary_end\n' >&2
}
emit_imap_delayed_literal_probe_failure_summary() {
  delayed_literal_summary_log=${PLAINPOST_SYNC_NODE_IMAP_DELAYED_LITERAL_PROBE_SUMMARY_LOG:-$runtime_log}
  delayed_literal_summary_patterns=${PLAINPOST_SYNC_NODE_IMAP_DELAYED_LITERAL_PROBE_SUMMARY_PATTERNS:-$patterns}
  printf 'imap_delayed_literal_probe_failure_summary_begin\n' >&2
  grep -E '^ERROR acceptance-imap-delayed-literal-probe outcome=failed step=(arm|probe|phase|projection)$' "$delayed_literal_summary_log" | filter_summary_patterns "$delayed_literal_summary_patterns" | tail -80 >&2 || true
  printf 'imap_delayed_literal_probe_failure_summary_end\n' >&2
}
emit_mail_postcondition_failure_summary() {
  mail_postcondition_summary_log=${PLAINPOST_SYNC_NODE_MAIL_POSTCONDITION_SUMMARY_LOG:-$runtime_log}
  mail_postcondition_summary_patterns=${PLAINPOST_SYNC_NODE_MAIL_POSTCONDITION_SUMMARY_PATTERNS:-$patterns}
  printf 'mail_postcondition_failure_summary_begin\n' >&2
  # Only the fixed mismatch vocabulary is retained. This explicit bounded
  # section keeps the classification visible even when later Compose output
  # evicts it from the generic runtime tail.
  grep -E '^ERROR acceptance-mail-postcondition outcome=mismatch category=(delivery-count|delivery-identity|delivery-security|draft-state|sent-state|envelope|content-security|correlation)$' "$mail_postcondition_summary_log" | filter_summary_patterns "$mail_postcondition_summary_patterns" | tail -40 >&2 || true
  printf 'mail_postcondition_failure_summary_end\n' >&2
}
emit_central_admission_failure_summary() {
  central_admission_summary_log=${PLAINPOST_SYNC_NODE_CENTRAL_ADMISSION_FAILURE_SUMMARY_LOG:-$runtime_log}
  central_admission_summary_patterns=${PLAINPOST_SYNC_NODE_CENTRAL_ADMISSION_FAILURE_SUMMARY_PATTERNS:-$patterns}
  printf 'central_admission_failure_summary_begin\n' >&2
  # Keep only complete records from the closed cause vocabulary. Central's
  # default slog handler is logfmt without a msg= key, while acceptance test
  # handlers and newer builds may emit TextHandler or JSON; all three forms
  # are anchored so appended fields, IDs, and error details are rejected.
  grep -E '^(time=[^[:space:]]+ level=ERROR msg="\[DEBUG-central-admission\] offer failure" cause=(offer-decode|principal-or-target|offer-binding|offer-liveness|owner-pending-state-or-bundle|nonce-replay-or-decode|active-offer-conflict|capacity|insert|serialization|transaction)|\{"time":"[^"]+","level":"ERROR","msg":"\[DEBUG-central-admission\] offer failure","cause":"(offer-decode|principal-or-target|offer-binding|offer-liveness|owner-pending-state-or-bundle|nonce-replay-or-decode|active-offer-conflict|capacity|insert|serialization|transaction)"\}|[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} ERROR \[DEBUG-central-admission\] offer failure cause=(offer-decode|principal-or-target|offer-binding|offer-liveness|owner-pending-state-or-bundle|nonce-replay-or-decode|active-offer-conflict|capacity|insert|serialization|transaction))$' "$central_admission_summary_log" | filter_summary_patterns "$central_admission_summary_patterns" | tail -80 >&2 || true
  printf 'central_admission_failure_summary_end\n' >&2
}
emit_release_backup_restore_failure_summary() {
  release_backup_restore_summary_log=${PLAINPOST_SYNC_NODE_RELEASE_BACKUP_RESTORE_FAILURE_SUMMARY_LOG:-$runtime_log}
  release_backup_restore_summary_patterns=${PLAINPOST_SYNC_NODE_RELEASE_BACKUP_RESTORE_FAILURE_SUMMARY_PATTERNS:-$patterns}
  printf 'release_backup_restore_failure_summary_begin\n' >&2
  {
    grep -E '^ERROR release-backup-restore step=(prepare|preflight-container-names|stop-node|backup-execute|backup-verify|backup-publish|negative-fixture-build|negative-case|restore-execute|restore-verify|database-reference) status=failed$' "$release_backup_restore_summary_log"
    grep -E '^ERROR release-backup-restore prepare-step=(context|journal-load|key|reader-open|manifest|deletion-before|references|manifest-digest|plan|journal-staging|database-create|attachments-create|payload|payload-context|payload-database-restore|payload-database-client|payload-database-connection|payload-database-archive-input|payload-database-sql-execution|payload-database-process|payload-database-context|payload-attachment-write|payload-integrity|database-validate|attachments-seal|payload-eof|reader-close|deletion-after|journal-prepared)$' "$release_backup_restore_summary_log"
    grep -E '^ERROR release-backup-restore commit-step=(journal-intent|verify-current|database-check|database-switch|attachment-check|attachment-switch|activation|active-verification|retirement|committed-journal)$' "$release_backup_restore_summary_log"
    grep -E '^ERROR release-backup-restore post-child-step=(reference-validation|quarantine|attachment-quarantine|audit-secret-promotion|node-start|readiness|marker-publish) status=(begin|passed|failed)$' "$release_backup_restore_summary_log"
    grep -E '^ERROR release-backup-restore failure category=(config|lock|source|assembly|prepare|digest|commit|teardown|pty|unknown)$' "$release_backup_restore_summary_log"
  } | filter_summary_patterns "$release_backup_restore_summary_patterns" | tail -80 >&2 || true
  printf 'release_backup_restore_failure_summary_end\n' >&2
}
emit_private_database_audit_failure_summary() {
  private_database_audit_summary_log=${PLAINPOST_SYNC_NODE_PRIVATE_DATABASE_AUDIT_FAILURE_SUMMARY_LOG:-$runtime_log}
  private_database_audit_summary_patterns=${PLAINPOST_SYNC_NODE_PRIVATE_DATABASE_AUDIT_FAILURE_SUMMARY_PATTERNS:-$patterns}
  printf 'private_database_audit_failure_summary_begin\n' >&2
  grep -E '^ERROR private database audit failed category=unknown$|^ERROR private database audit failed category=inputs( subcategory=(central-database-file|node-one-database-file|node-two-database-file|actual-patterns|database-argument-mode|unknown)( reason=(missing-open|stat-type|mode|owner|link-count|empty-size|changed-during-read|url-invalid|tls-mode|unknown))?)?$|^ERROR private database audit failed category=(returned-inputs|central-connect|central-marker-query|central-marker-count|central-contamination-guard|central-returned-contamination-guard|central-returned-counts-query|central-returned-counts|node-one-marker-count|node-two-marker-count)( cell=[^[:space:]]+)?$|^ERROR private database audit failed category=(node-one-connect|node-one-marker-query|node-two-connect|node-two-marker-query)( reason=(relation-missing|missing-node-installation-state|missing-node-current-authority-state|missing-node-secrets|permission|canceled-deadline|connection|container-missing|container-not-running|psql-connect|migration-ledger|migration-head|relation-query|unexpected-output|unknown))?$' "$private_database_audit_summary_log" |
  awk '
    /^ERROR private database audit failed category=/ {
      cell_start = index($0, " cell=")
      if (cell_start == 0) {
        print
        next
      }
      cell = substr($0, cell_start + 6)
      if (cell == "node_enrollment_claims.endpoint_ciphertext" ||
          cell == "node_enrollment_claims.setup_verifier" ||
          cell == "node_enrollment_claims.signing_public_key" ||
          cell == "node_enrollment_claims.agreement_public_key" ||
          cell == "node_enrollment_claims.noise_static_public_key" ||
          cell == "node_enrollment_results.credential_result_ciphertext" ||
          cell == "node_enrollment_results.replacement_evidence_wire" ||
          cell == "encrypted_account_records.record_wire" ||
          cell == "encrypted_account_records.envelope") print
      else print substr($0, 1, cell_start - 1)
      next
    }
  ' | filter_summary_patterns "$private_database_audit_summary_patterns" | tail -80 >&2 || true
  printf 'private_database_audit_failure_summary_end\n' >&2
}
emit_node_two_schema_failure_summary() {
  node_two_schema_summary_log=${PLAINPOST_SYNC_NODE_NODE_TWO_SCHEMA_SUMMARY_LOG:-$runtime_log}
  printf 'node_two_schema_failure_summary_begin\n' >&2
  grep -E '^node-two-schema-checkpoint phase=(initial-ready|after-restarts|before-privacy-audit) status=(passed state=reset|failed cause=(container-missing|container-not-running|psql-connect|migration-ledger|migration-head|node-installation-state|node-current-authority-state|node-secrets|relation-query|reset-query|reset-probe|reset-mismatch|unexpected-output|query))$' "$node_two_schema_summary_log" | tail -40 >&2 || true
  printf 'node_two_schema_failure_summary_end\n' >&2
}
emit_operations_backup_failure_summary() {
  # Keep the operations command's closed diagnostic vocabulary ahead of the
  # bounded generic tail. Reconstruct every emitted line so raw errors,
  # credentials, URLs, paths, and child stderr can never cross this boundary.
  awk '
    /^ERROR operations-backup-failure category=auth-config([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=auth-config"
    }
    /^ERROR operations-backup-failure category=runtime-start([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=runtime-start"
    }
    /^ERROR operations-backup-failure category=backup-execute$/ {
      print "ERROR operations-backup-failure category=backup-execute"
    }
    /^ERROR operations-backup-failure category=runtime-stop\/output([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=runtime-stop/output"
    }
    /^ERROR operations-backup-failure category=unknown([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=unknown"
    }
    /^ERROR operations-backup-failure category=backup-execute stage=obligation-reserve([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=backup-execute stage=obligation-reserve"
    }
    /^ERROR operations-backup-failure category=backup-execute stage=quiesce([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=backup-execute stage=quiesce"
    }
    /^ERROR operations-backup-failure category=backup-execute stage=key([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=backup-execute stage=key"
    }
    /^ERROR operations-backup-failure category=backup-execute stage=staging-cleanup\/container-create([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=backup-execute stage=staging-cleanup/container-create"
    }
    /^ERROR operations-backup-failure category=backup-execute stage=postgres-dump([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=backup-execute stage=postgres-dump"
    }
    /^ERROR operations-backup-failure category=backup-execute stage=attachments([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=backup-execute stage=attachments"
    }
    /^ERROR operations-backup-failure category=backup-execute stage=manifest\/finalize([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=backup-execute stage=manifest/finalize"
    }
    /^ERROR operations-backup-failure category=backup-execute stage=publication([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=backup-execute stage=publication"
    }
    /^ERROR operations-backup-failure category=backup-execute stage=obligation-complete([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=backup-execute stage=obligation-complete"
    }
  ' "$runtime_log" | tail -80 >&2 || true
}
filter_summary_patterns() {
  filter_summary_pattern_file=$1
  if [ ! -f "$filter_summary_pattern_file" ]; then
    return 0
  fi
  grep -F -v -f "$filter_summary_pattern_file"
}
prepare_uid_gap_fixture() {
  uid_gap_mailbox_path=$1
  python3 - "$uid_gap_mailbox_path" <<'PY'
import json
import sys
from email import policy
from email.parser import BytesParser

path = sys.argv[1]
state = json.load(open(path, encoding="utf-8"))
def raw(message_id, subject, body):
    return f"Message-ID: <{message_id}@example.test>\r\nSubject: {subject}\r\n\r\n{body}\r\n"
state["uidValidity"] = 11
state["nextUID"] = 10
state["messages"] = [
    dict(state["messages"][0], uid=1, raw=raw("uid-gap-one", "UID gap one", "one")),
    dict(state["messages"][1], uid=4, raw=raw("uid-gap-four", "UID gap four", "four")),
    dict(state["messages"][0], uid=9, raw=raw("uid-gap-nine", "UID gap nine", "nine")),
]
with open(path, "w", encoding="utf-8") as output:
    json.dump(state, output, ensure_ascii=False)

expected = [
    (1, "<uid-gap-one@example.test>", "UID gap one", "one\r\n"),
    (4, "<uid-gap-four@example.test>", "UID gap four", "four\r\n"),
    (9, "<uid-gap-nine@example.test>", "UID gap nine", "nine\r\n"),
]
actual = []
for item in state.get("messages", []):
    message = BytesParser(policy=policy.default).parsebytes(item["raw"].encode())
    actual.append((int(item["uid"]), message["Message-ID"], message["Subject"], message.get_payload()))
if state.get("uidValidity") != 11 or state.get("nextUID") != 10 or actual != expected:
    raise SystemExit("UID-gap fixture seed did not match its exact fixture fields")
PY
}
if [ "${PLAINPOST_SYNC_NODE_UID_GAP_PREFLIGHT_TEST:-}" = enabled ]; then
  uid_gap_preflight_root=$(mktemp -d "${TMPDIR:-/tmp}/plainpost-uid-gap-preflight.XXXXXX")
  uid_gap_preflight_path="$uid_gap_preflight_root/mailbox.json"
  printf '%s\n' '{"uidValidity":1,"nextUID":3,"messages":[{"uid":1,"flags":[],"labels":["INBOX"],"raw":"Message-ID: <acceptance-one@example.test>\r\nSubject: Initial\r\n\r\none\r\n"},{"uid":2,"flags":[],"labels":["INBOX"],"raw":"Message-ID: <acceptance-two@example.test>\r\nSubject: Continuation\r\n\r\nfour\r\n"}]}' >"$uid_gap_preflight_path"
  if prepare_uid_gap_fixture "$uid_gap_preflight_path"; then
    uid_gap_preflight_status=0
    printf 'uid-gap-preflight-test=passed\n'
  else
    uid_gap_preflight_status=$?
    printf 'uid-gap-preflight-test=failed\n' >&2
  fi
  find "$uid_gap_preflight_root" -depth -delete >/dev/null 2>&1 || true
  exit "$uid_gap_preflight_status"
fi
if [ "${PLAINPOST_SYNC_NODE_PROCESS_CLEANUP_TEST:-}" = enabled ]; then
  run_process_cleanup_test
  exit "$?"
fi
if [ "${PLAINPOST_SYNC_NODE_PRIVACY_FAILURE_TEST:-}" = enabled ]; then
  run_privacy_failure_test
  exit "$?"
fi
if [ "${PLAINPOST_SYNC_NODE_RELEASE_BACKUP_RESTORE_FAILURE_SUMMARY_TEST:-}" = enabled ]; then
  emit_release_backup_restore_failure_summary
  find "$temporary" -depth -delete >/dev/null 2>&1 || true
  [ ! -e "$temporary" ]
  exit "$?"
fi
if [ "${PLAINPOST_SYNC_NODE_PRIVATE_DATABASE_AUDIT_FAILURE_SUMMARY_TEST:-}" = enabled ]; then
  printf 'summary-contract-private-value-not-present\n' >"$patterns"
  chmod 0600 "$patterns"
  : >"$runtime_log"
  printf 'ERROR private database audit failed category=central-marker-count cell=node_enrollment_results.replacement_evidence_wire\n' >>"$runtime_log"
  printf 'ERROR private database audit failed category=central-marker-count cell=unclassified\n' >>"$runtime_log"
  printf 'ERROR private database audit failed category=central-marker-count cell=unknown\n' >>"$runtime_log"
  printf 'ERROR private database audit failed category=central-connect\n' >>"$runtime_log"
  printf 'ERROR private database audit failed category=node-two-marker-query reason=missing-node-current-authority-state\n' >>"$runtime_log"
  printf 'ERROR private database audit failed category=node-two-connect reason=private-secret\n' >>"$runtime_log"
  printf 'ERROR private database audit failed category=inputs subcategory=actual-patterns\n' >>"$runtime_log"
  printf 'ERROR private database audit failed category=inputs subcategory=private-secret-must-not-render\n' >>"$runtime_log"
  printf 'ERROR private database audit failed category=unknown\n' >>"$runtime_log"
  printf 'ERROR private database audit failed category=unknown cell=unclassified\n' >>"$runtime_log"
  printf 'ERROR private database audit failed category=unknown raw=secret-value\n' >>"$runtime_log"
  printf 'ERROR private database audit failed category=custom-injected cell=secret-value\n' >>"$runtime_log"
  printf 'ERROR private database audit failed category=central-marker-count cell=secret-value raw=secret-value\n' >>"$runtime_log"
  printf 'ERROR private database audit failed category=central-marker-count cell=node_enrollment_claimsXendpoint_ciphertext\n' >>"$runtime_log"
  emit_private_database_audit_failure_summary
  find "$temporary" -depth -delete >/dev/null 2>&1 || true
  if [ -e "$temporary" ]; then
    printf 'private-database-audit-summary-temp-leaked=1\n' >&2
    exit 1
  fi
  exit 1
fi
if [ "${PLAINPOST_SYNC_NODE_PRIVATE_DATABASE_AUDIT_REASON_SUMMARY_TEST:-}" = enabled ]; then
  printf 'summary-contract-private-value-not-present\n' >"$patterns"
  chmod 0600 "$patterns"
  : >"$runtime_log"
  reason_summary_index=1
  while [ "$reason_summary_index" -le 100 ]; do
    printf 'ERROR private database audit failed category=inputs subcategory=node-one-database-file reason=mode\n' >>"$runtime_log"
    reason_summary_index=$((reason_summary_index + 1))
  done
  printf 'ERROR private database audit failed category=inputs subcategory=node-one-database-file reason=mode marker=reason-hostile\n' >>"$runtime_log"
  emit_private_database_audit_failure_summary
  if [ "${PLAINPOST_SYNC_NODE_PRIVATE_DATABASE_AUDIT_REASON_SUMMARY_TEMP_LEAK_TEST:-}" != enabled ]; then
    find "$temporary" -depth -delete >/dev/null 2>&1 || true
  fi
  if [ -e "$temporary" ]; then
    printf 'private-database-audit-reason-summary-temp-leaked=1\n' >&2
    find "$temporary" -depth -delete >/dev/null 2>&1 || true
  fi
  exit 1
fi
if [ "${PLAINPOST_SYNC_NODE_NODE_TWO_SCHEMA_SUMMARY_TEST:-}" = enabled ]; then
  printf 'node-two-schema-checkpoint phase=before-privacy-audit status=failed cause=node-installation-state\n' >"$runtime_log"
  printf 'node-two-schema-checkpoint phase=before-privacy-audit status=failed cause=reset-probe\n' >>"$runtime_log"
  chmod 0600 "$runtime_log"
  emit_node_two_schema_failure_summary
  find "$temporary" -depth -delete >/dev/null 2>&1 || true
  exit 1
fi
if [ "${PLAINPOST_SYNC_NODE_NODE_TWO_PRESENTATION_SUMMARY_TEST:-}" = enabled ]; then
  emit_node_two_presentation_failure_summary
  find "$temporary" -depth -delete >/dev/null 2>&1 || true
  [ ! -e "$temporary" ]
  exit "$?"
fi
if [ "${PLAINPOST_SYNC_NODE_ATTACHMENT_DIAGNOSTIC_SUMMARY_TEST:-}" = enabled ]; then
  emit_attachment_diagnostic_summary
  find "$temporary" -depth -delete >/dev/null 2>&1 || true
  [ ! -e "$temporary" ]
  exit "$?"
fi
if [ "${PLAINPOST_SYNC_NODE_ATTACHMENT_STREAM_SUMMARY_TEST:-}" = enabled ]; then
  emit_attachment_stream_summary
  find "$temporary" -depth -delete >/dev/null 2>&1 || true
  [ ! -e "$temporary" ]
  exit "$?"
fi
if [ "${PLAINPOST_SYNC_NODE_IMAP_TERMINAL_FAILURE_SUMMARY_TEST:-}" = enabled ]; then
  emit_imap_terminal_failure_summary
  find "$temporary" -depth -delete >/dev/null 2>&1 || true
  [ ! -e "$temporary" ]
  exit "$?"
fi
if [ "${PLAINPOST_SYNC_NODE_IMAP_CATALOG_PROBE_SUMMARY_TEST:-}" = enabled ]; then
  emit_imap_catalog_probe_failure_summary
  find "$temporary" -depth -delete >/dev/null 2>&1 || true
  [ ! -e "$temporary" ]
  exit "$?"
fi
if [ "${PLAINPOST_SYNC_NODE_IMAP_DELAYED_LITERAL_PROBE_SUMMARY_TEST:-}" = enabled ]; then
  emit_imap_delayed_literal_probe_failure_summary
  find "$temporary" -depth -delete >/dev/null 2>&1 || true
  [ ! -e "$temporary" ]
  exit "$?"
fi
if [ "${PLAINPOST_SYNC_NODE_MAIL_POSTCONDITION_SUMMARY_TEST:-}" = enabled ]; then
  mail_postcondition_test_secret='postcondition-summary-secret-never-render'
  : >"$runtime_log"
  for _ in $(seq 1 50); do
    printf 'ERROR acceptance-mail-postcondition outcome=mismatch category=sent-state\n' >>"$runtime_log"
  done
  # This malformed extension must not cross the fixed-field allowlist.
  printf 'ERROR acceptance-mail-postcondition outcome=mismatch category=sent-state secret=%s\n' "$mail_postcondition_test_secret" >>"$runtime_log"
  printf '%s\n' "$mail_postcondition_test_secret" >"$patterns"
  chmod 0600 "$runtime_log" "$patterns"
  emit_mail_postcondition_failure_summary
  find "$temporary" -depth -delete >/dev/null 2>&1 || true
  [ ! -e "$temporary" ]
  exit "$?"
fi
if [ "${PLAINPOST_SYNC_NODE_CENTRAL_ADMISSION_FAILURE_SUMMARY_TEST:-}" = enabled ]; then
  emit_central_admission_failure_summary
  find "$temporary" -depth -delete >/dev/null 2>&1 || true
  [ ! -e "$temporary" ]
  exit "$?"
fi
if [ "${PLAINPOST_SYNC_NODE_SWIFT_LOG_CAPTURE_TEST:-}" = enabled ]; then
  swift_capture_secret='swift-capture-private-secret'
  printf 'ERROR synthetic-swift-failure detail=%s\n' "$swift_capture_secret" >"$temporary/swift.log"
  printf '%s\n' "$swift_capture_secret" >"$patterns"
  chmod 0600 "$temporary/swift.log" "$patterns"
  capture_swift_log
  capture_swift_log
  swift_capture_count=$(grep -c 'synthetic-swift-failure' "$runtime_log" || true)
  swift_capture_filtered=$(grep -F 'synthetic-swift-failure' "$runtime_log" | filter_summary_patterns "$patterns" || true)
  if [ "$swift_capture_count" -ne 1 ] || printf '%s\n' "$swift_capture_filtered" | grep -F "$swift_capture_secret" >/dev/null; then
    printf 'swift-log-capture-test=failed count=%s\n' "$swift_capture_count" >&2
    find "$temporary" -depth -delete >/dev/null 2>&1 || true
    exit 1
  fi
  printf 'swift-log-capture-test=passed count=%s\n' "$swift_capture_count"
  find "$temporary" -depth -delete >/dev/null 2>&1 || true
  [ ! -e "$temporary" ]
  exit "$?"
fi
finish() {
  if [ "$#" -gt 0 ]; then
    status=$1
  else
    status=$?
  fi
  capture_swift_log
  stop_swift_process
  stop_client_control_loop
  trap - EXIT
  trap '' HUP INT TERM
  if [ "$status" -ne 0 ]; then
    if [ -s "$temporary/swift.log" ]; then
      printf 'swift_failure_summary_begin\n' >&2
      grep -Ei '(^|[^[:alpha:]])(error:|failed|FAIL|ERROR|XCTAssert|Test Case|Test Suite|No tests found|unexpected signal|Exited|Fatal error|precondition|Assertion|NodeMailAuthorityLiveTests)' "$temporary/swift.log" | filter_summary_patterns "$patterns" | tail -80 >&2 || true
      printf 'swift_failure_summary_end\n' >&2
    fi
    if [ -s "$swift_stage_log" ]; then
      printf 'swift_stage_failure_summary_begin\n' >&2
      cat "$swift_stage_log" >&2 || true
      printf 'swift_stage_failure_summary_end\n' >&2
    fi
    if [ -s "$swift_stream_diagnostic_log" ]; then
      cat "$swift_stream_diagnostic_log" >>"$runtime_log" 2>&1 || true
    fi
    compose_run logs --no-color --no-log-prefix --tail 1000 central central-tls central-node-one-tls central-node-two-tls node-one node-two minio postgres >>"$runtime_log" 2>&1 || status=1
    capture_acceptance_provider_state
    emit_release_backup_restore_failure_summary
    emit_private_database_audit_failure_summary
    emit_node_two_schema_failure_summary
    # Central keeps the HTTP 409 generic; retain only the fixed admission
    # failure cause after Compose capture for bounded, privacy-safe diagnosis.
    emit_central_admission_failure_summary
    # Provider recovery diagnostics are fixed-field records emitted at the
    # worker boundary. Keep the newest bounded tail after Compose capture so a
    # passive IMAP restart failure remains visible without retaining errors,
    # mailbox/account identities, secrets, paths, or provider values.
    printf 'provider_failure_summary_begin\n' >&2
    grep -E 'msg="\[DEBUG-sync-node-runtime\] provider failure" stage=runtime-provider-failure worker_stage=(synchronize|wait-for-change) mailbox_stage=provider-recovery provider_tag=[a-z_]+ retry_disposition=(never|safe|reconcile_first) failure_count=[0-9]+$' "$runtime_log" | filter_summary_patterns "$patterns" | tail -80 >&2 || true
    printf 'provider_failure_summary_end\n' >&2
    # Fixture restart diagnostics are emitted by the bounded controller child
    # and kept after Compose capture so its terminal class cannot be evicted.
    # Select only fixed-vocabulary markers and restart controller outcomes;
    # apply the same privacy filter before writing the bounded tail.
    printf 'fixture_restart_failure_summary_begin\n' >&2
    grep -E '^(ERROR acceptance-fixture-restart fixture=(imap-fixture|smtp-fixture) event=(container-resolve|compose-restart|probe|status-capture)( |$)|ERROR acceptance-fixture-restart fixture=(imap-fixture|smtp-fixture) event=crash-classification exit_code=[0-9]+ oom=(true|false) (cause=(sqlite-busy-locked|sqlite-schema|bind-address|signal|python-runtime-error|python-value-error|python-os-error|python-ssl-error|python-exception|unknown)( |$)|cause=sqlite-operational sqlite_subcategory=(locked|open|disk-io|schema|readonly|corrupt|other|none) sqlite_operation=(wal-open|transaction|schema-migration|schema-create|projection-repair|read|other|none)( |$))|ERROR controller-(child-timeout|descendant-survived|child-reaped) action=(restart-(imap-fixture|smtp-fixture)|release-backup-restore-(run|cleanup|database-quarantine|node-start))( |$))' "$runtime_log" | filter_summary_patterns "$patterns" | tail -80 >&2 || true
    printf 'fixture_restart_failure_summary_end\n' >&2
    printf 'operations_backup_failure_summary_begin\n' >&2
    emit_operations_backup_failure_summary
    printf 'operations_backup_failure_summary_end\n' >&2
    # Node-two presentation is driven by a bounded controller child. Keep its
    # terminal outcome and controller timeout class visible after the Compose
    # log capture, while selecting only fixed-vocabulary, privacy-safe fields.
    emit_node_two_presentation_failure_summary
    printf 'attachment_diagnostic_failure_summary_begin\n' >&2
    emit_attachment_diagnostic_summary
    printf 'attachment_diagnostic_failure_summary_end\n' >&2
    emit_attachment_stream_summary
    emit_imap_terminal_failure_summary
    emit_imap_catalog_probe_failure_summary
    emit_imap_delayed_literal_probe_failure_summary
    emit_mail_postcondition_failure_summary
    printf 'acceptance_control_summary_begin\n' >&2
    grep -E '^ERROR acceptance-control stage=((authority-outage|authority-recover|node-one)-(wait|pause|restart|readiness|publish|unpause|checkpoint)|(node-two)-(activation-wait|hot-ready-wait|process-identity|restart|readiness|schema-checkpoint|publish))(-[a-z0-9-]+)?$' "$runtime_log" | tail -80 >&2 || true
    printf 'acceptance_control_summary_end\n' >&2
  fi
  if [ "$status" -ne 0 ] && [ -s "$runtime_log" ]; then
    printf 'failure_summary_begin\n' >&2
    printf 'acceptance_stream_lifecycle_summary_begin\n' >&2
    # Stream telemetry records only lifecycle state (never payloads, paths, or
    # credentials). Retain it separately from the generic tail after compose
    # capture so cancellation ownership failures remain diagnosable.
    grep -F '[DEBUG-sync-node-stream]' "$runtime_log" | filter_summary_patterns "$patterns" | tail -120 >&2 || true
    printf 'acceptance_stream_lifecycle_summary_end\n' >&2
    printf 'acceptance_stream_terminal_summary_begin\n' >&2
    # Keep one bounded, state-only terminal record per stream. This shared
    # helper uses the complete redacted stream log, so a long compose capture
    # or a noisy earlier stream cannot evict the final lifecycle transition.
    sync_node_stream_terminal_summary "$runtime_log" "$patterns" >&2 || true
    printf 'acceptance_stream_terminal_summary_end\n' >&2
    printf 'runtime_admission_summary_begin\n' >&2
    # Runtime/base admission is evaluated before a request reaches any HTTP
    # route. Keep this bounded state transition summary separate from the
    # generic tail so a pre-mutation rejection remains visible after compose
    # capture; base records carry only fixed dependency, failure, and context
    # classes, with the existing privacy filter applied before stderr.
    grep -F '[DEBUG-sync-node-runtime] client admission' "$runtime_log" | filter_summary_patterns "$patterns" | tail -80 >&2 || true
    printf 'runtime_admission_summary_end\n' >&2
    printf 'swift_lifecycle_failure_summary_begin\n' >&2
    # Keep timeout and forced-termination evidence separate from the bounded
    # general tail; compose output must not evict the stage's final boundary.
    grep -E '^ERROR (acceptance-signal-timeout|swift-process-termination)' "$runtime_log" | filter_summary_patterns "$patterns" | tail -80 >&2 || true
    printf 'swift_lifecycle_failure_summary_end\n' >&2
    printf 'acceptance_provider_transition_summary_begin\n' >&2
    grep -E 'ERROR acceptance-provider-transition' "$runtime_log" | filter_summary_patterns "$patterns" | tail -40 >&2 || true
    printf 'acceptance_provider_transition_summary_end\n' >&2
    printf 'response_drop_summary_begin\n' >&2
    # The response-drop injector logs only closed vocabulary (route, cycle,
    # outcome, route state, in-flight ownership, phase read error and response
    # class). Keep it out of reach of the generic tail so a missed drop stays
    # classifiable.
    grep -F '"msg":"acceptance-response-drop' "$runtime_log" | filter_summary_patterns "$patterns" | tail -40 >&2 || true
    printf 'response_drop_summary_end\n' >&2
    printf 'mutation_boundary_summary_begin\n' >&2
    # slog emits the fixed mutation-boundary message at WARN/DEBUG levels,
    # neither of which the general error grep is intended to retain. Keep
    # this explicit allowlisted diagnostic in the redacted failure summary;
    # apply the same privacy filter before it reaches stderr.
    grep -F 'sync node mutation boundary' "$runtime_log" | filter_summary_patterns "$patterns" | tail -80 >&2 || true
    printf 'mutation_boundary_summary_end\n' >&2
    grep -Ei '(^|[^[:alpha:]])(error:|failed|FAIL|ERROR|STATEMENT:|XCTAssert|Test Case|Test Suite|No tests found|unexpected signal|Exited|Fatal error|precondition|Assertion|NodeMailAuthorityLiveTests)' "$runtime_log" | filter_summary_patterns "$patterns" | tail -80 >&2 || true
    printf 'failure_summary_end\n' >&2
  fi
  cleanup || status=1
  exit "$status"
}
trap 'finish "$?"' EXIT
on_signal() {
  trap '' HUP INT TERM
  finish "$1"
}
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

mkdir -m 0700 "$temporary/artifacts" "$temporary/bin" "$temporary/go-cache" "$temporary/central-tls" "$temporary/node-one-central-tls" "$temporary/node-two-central-tls" "$temporary/postgres-central-tls" "$temporary/postgres-node-one-tls" "$temporary/postgres-node-two-tls" "$temporary/minio-tls" "$temporary/mail-tls" "$temporary/mail-wrong-host-tls" "$temporary/mail-untrusted-tls" "$temporary/mail-fixture" "$temporary/mail-state" "$temporary/node-one" "$temporary/node-two" "$temporary/node-one-data" "$temporary/node-two-data" "$temporary/node-one-secrets" "$temporary/node-two-secrets" "$temporary/central-secrets" "$temporary/shared-secrets" "$temporary/error-surfaces" "$temporary/control"
if [ "$transport_release_images" = 1 ]; then
  openssl rand -hex 24 >"$temporary/central-secrets/central-db-password"
  openssl rand -hex 24 >"$temporary/central-secrets/node-db-password"
  openssl rand -hex 24 >"$temporary/central-secrets/restore-admin-db-password"
  openssl rand -hex 24 >"$temporary/central-secrets/restore-stage-db-password"
  openssl rand -hex 24 >"$temporary/central-secrets/postgres-superuser-password"
  openssl rand -hex 24 >"$temporary/central-secrets/node-bootstrap-password"
  openssl rand -hex 32 >"$temporary/central-secrets/rate-limit-pepper"
  chmod 0600 "$temporary/central-secrets/central-db-password"
  chmod 0600 "$temporary/central-secrets/node-db-password" "$temporary/central-secrets/restore-admin-db-password" "$temporary/central-secrets/restore-stage-db-password"
  chmod 0600 "$temporary/central-secrets/postgres-superuser-password" "$temporary/central-secrets/node-bootstrap-password"
  chmod 0600 "$temporary/central-secrets/rate-limit-pepper"
  release_central_db_password=$(tr -d '\n' <"$temporary/central-secrets/central-db-password")
  release_node_db_password=$(tr -d '\n' <"$temporary/central-secrets/node-db-password")
  release_restore_admin_db_password=$(tr -d '\n' <"$temporary/central-secrets/restore-admin-db-password")
  release_restore_stage_db_password=$(tr -d '\n' <"$temporary/central-secrets/restore-stage-db-password")
  release_postgres_superuser_password=$(tr -d '\n' <"$temporary/central-secrets/postgres-superuser-password")
  release_node_bootstrap_password=$(tr -d '\n' <"$temporary/central-secrets/node-bootstrap-password")
fi
if [ "${PLAINPOST_SYNC_NODE_CLIENT_API:-}" = enabled ]; then
  # Activation performs one signed status read before provider seeding. Keep
  # the dropper disarmed until that hot-readiness proof has completed so it
  # cannot consume the later initial-cycle response-drop assertion.
  printf '%s\n' 'phase=bootstrap' 'GET /v1/status=done' >"$acceptance_response_drop_phase_file"
  chmod 0600 "$acceptance_response_drop_phase_file"
fi
if [ "${PLAINPOST_SYNC_NODE_ATTACHMENT_STORAGE_INITIALIZATION_TEST:-}" = enabled ]; then
  initialization_phase_mode=$(stat -f '%Lp' "$acceptance_response_drop_phase_file" 2>/dev/null || stat -c '%a' "$acceptance_response_drop_phase_file")
  initialization_s3_credentials=absent
  if [ -n "$acceptance_s3_access_key_file" ] && [ -n "$acceptance_s3_secret_key_file" ]; then
    initialization_s3_credentials=present
  fi
  if [ ! -f "$acceptance_response_drop_phase_file" ] || [ -L "$acceptance_response_drop_phase_file" ]; then
    printf 'attachment storage initialization did not create a regular phase file\n' >&2
    trap - EXIT HUP INT TERM
    find "$temporary" -depth -delete >/dev/null 2>&1 || true
    exit 1
  fi
  printf 'attachment-storage-initialization storage=%s phase-file=present mode=%s s3-credentials=%s\n' \
    "$acceptance_attachment_storage" "$initialization_phase_mode" "$initialization_s3_credentials"
  trap - EXIT HUP INT TERM
  find "$temporary" -depth -delete >/dev/null 2>&1 || true
  exit 0
fi
: >"$temporary/init.sql"
if [ -n "$release_source_journal_sql" ]; then
  printf '%s\n' "$release_source_journal_sql" >>"$temporary/init.sql"
else
  # Production keeps Central account and deletion-journal state in separate
  # schemas of plainpost_central; journal is not a third logical database.
  {
    if [ "$transport_release_images" = 1 ]; then
      printf 'CREATE ROLE plainpost_central LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD '\''%s'\'';\n' "$release_central_db_password"
    else
      printf '%s\n' 'CREATE ROLE plainpost_central LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;'
    fi
    printf '%s\n' 'ALTER DATABASE plainpost_central OWNER TO plainpost_central;'
    printf '%s\n' 'REVOKE ALL ON DATABASE plainpost_central FROM PUBLIC;'
    printf '%s\n' '\connect plainpost_central'
    printf '%s\n' 'CREATE SCHEMA account AUTHORIZATION plainpost_central;'
    printf '%s\n' 'CREATE SCHEMA deletion_journal AUTHORIZATION plainpost_central;'
    printf '%s\n' 'GRANT CONNECT ON DATABASE plainpost_central TO plainpost_central;'
    printf '%s\n' 'ALTER ROLE plainpost_central IN DATABASE plainpost_central SET search_path = account;'
  } >>"$temporary/init.sql"
fi
chmod 0600 "$temporary/init.sql"
{
  if [ "$transport_release_images" = 1 ]; then
    printf 'CREATE ROLE plainpost_restore_admin LOGIN NOSUPERUSER CREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD '\''%s'\'';\n' "$release_restore_admin_db_password"
    printf 'CREATE ROLE plainpost_restore_stage LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD '\''%s'\'';\n' "$release_restore_stage_db_password"
    printf 'CREATE ROLE plainpost_sync_node LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD '\''%s'\'';\n' "$release_node_db_password"
  else
    printf '%s\n' 'CREATE ROLE plainpost_restore_admin LOGIN NOSUPERUSER CREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;'
    printf '%s\n' 'CREATE ROLE plainpost_restore_stage LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;'
    printf '%s\n' 'CREATE ROLE plainpost_sync_node LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;'
  fi
  printf '%s\n' 'CREATE DATABASE plainpost_sync_node OWNER plainpost_restore_admin;'
  printf '%s\n' 'REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;'
  printf '%s\n' 'REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;'
  printf '%s\n' 'REVOKE CONNECT ON DATABASE plainpost_sync_node FROM PUBLIC;'
  printf '%s\n' 'GRANT CONNECT ON DATABASE plainpost_sync_node TO plainpost_sync_node;'
  printf '%s\n' 'GRANT CONNECT ON DATABASE postgres TO plainpost_restore_admin;'
  printf '%s\n' 'GRANT CONNECT ON DATABASE plainpost_sync_node TO plainpost_restore_admin;'
  printf '%s\n' 'GRANT plainpost_restore_stage TO plainpost_restore_admin WITH INHERIT TRUE, SET TRUE;'
  printf '%s\n' 'GRANT plainpost_sync_node TO plainpost_restore_admin WITH INHERIT TRUE, SET TRUE;'
  printf '%s\n' '\connect plainpost_sync_node'
  printf '%s\n' 'REVOKE ALL ON SCHEMA public FROM PUBLIC;'
  printf '%s\n' 'GRANT USAGE, CREATE ON SCHEMA public TO plainpost_sync_node;'
  printf '%s\n' 'ALTER DEFAULT PRIVILEGES FOR ROLE plainpost_restore_admin IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC;'
  printf '%s\n' 'ALTER DEFAULT PRIVILEGES FOR ROLE plainpost_restore_admin IN SCHEMA public REVOKE ALL ON SEQUENCES FROM PUBLIC;'
  printf '%s\n' 'ALTER DEFAULT PRIVILEGES FOR ROLE plainpost_restore_admin IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;'
} >"$temporary/node-postgres-init.sql"
chmod 0600 "$temporary/node-postgres-init.sql"
if [ "$transport_release_images" = 1 ]; then
  # The primary release server owns both production databases.  Keep the
  # source topology's node authority SQL, but execute it in the primary
  # server's init transaction rather than starting postgres-node-one.
  {
    printf 'CREATE ROLE plainpost_node_bootstrap LOGIN NOSUPERUSER CREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS PASSWORD '\''%s'\'';\n' "$release_node_bootstrap_password"
    cat "$temporary/node-postgres-init.sql"
    printf '%s\n' 'GRANT CONNECT ON DATABASE postgres TO plainpost_node_bootstrap;'
    printf '%s\n' 'GRANT CONNECT ON DATABASE plainpost_sync_node TO plainpost_node_bootstrap;'
  } >>"$temporary/init.sql"
fi

docker_arch=$(docker version --format '{{.Server.Arch}}')
case "$docker_arch" in arm64|amd64) ;; *) printf 'unsupported Docker server architecture\n' >&2; exit 1;; esac
for binary in plainpost-api plainpost-sync-node plainpost-acceptance-tls-proxy plainpost-acceptance-tcp-relay plainpost-sync-node-acceptance-seed; do
  if [ "$transport_release_images" = 1 ] && { [ "$binary" = plainpost-api ] || [ "$binary" = plainpost-sync-node ]; }; then
    continue
  fi
  (cd "$root/Services/PlainpostGo" && GOCACHE="$temporary/go-cache" CGO_ENABLED=0 GOOS=linux GOARCH="$docker_arch" go build -trimpath -ldflags='-s -w' -o "$temporary/bin/$binary" "./cmd/$binary") >>"$runtime_log" 2>&1
done
chmod 0755 "$temporary/bin"/*
if [ "$transport_release_images" = 0 ]; then
  mkdir -m 0700 "$temporary/node-image" "$temporary/node-image/node-data" "$temporary/node-image/node-data/attachment-staging"
  cp "$temporary/bin/plainpost-sync-node" "$temporary/node-image/plainpost-sync-node"
  cp "$root/Deploy/acceptance/Dockerfile.sync-node-runtime" "$temporary/node-image/Dockerfile"
  chmod 0755 "$temporary/node-image/plainpost-sync-node"
  if ! docker build --no-cache --tag "$node_image" "$temporary/node-image" >>"$runtime_log" 2>&1; then
    printf 'private acceptance runtime image build failed\n' >&2
    exit 1
  fi
else
  printf 'release acceptance using immutable Central and Node images\n' >>"$runtime_log"
fi
if [ "$transport_release_images" = 0 ]; then node_image_built=1; fi

clock=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
(cd "$root/Services/PlainpostGo" && go run ./cmd/plainpost-acceptance-artifacts -output "$temporary/artifacts" -fixtures "$root/Protocol/account-v1/fixtures" -clock "$clock") >>"$runtime_log" 2>&1

openssl req -x509 -sha256 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -pkeyopt ec_param_enc:named_curve -nodes -days 1 -subj '/CN=Plainpost Private Acceptance CA' -keyout "$temporary/ca.key" -out "$temporary/ca.crt" >>"$runtime_log" 2>&1
openssl req -x509 -sha256 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -pkeyopt ec_param_enc:named_curve -nodes -days 1 -subj '/CN=Plainpost Untrusted Acceptance CA' -keyout "$temporary/untrusted-ca.key" -out "$temporary/untrusted-ca.crt" >>"$runtime_log" 2>&1
make_certificate() {
  name=$1
  hostname=$2
  directory=$3
  shift 3
  aliases=''
  for alias in "$@"; do aliases="$aliases,DNS:$alias"; done
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -pkeyopt ec_param_enc:named_curve -nodes -subj "/CN=$hostname" -keyout "$directory/server.key" -out "$directory/server.csr" >>"$runtime_log" 2>&1
  printf 'subjectAltName=DNS:%s%s\nextendedKeyUsage=serverAuth\n' "$hostname" "$aliases" >"$directory/extensions"
  openssl x509 -req -sha256 -days 1 -in "$directory/server.csr" -CA "$temporary/ca.crt" -CAkey "$temporary/ca.key" -CAcreateserial -extfile "$directory/extensions" -out "$directory/server.crt" >>"$runtime_log" 2>&1
  chmod 0600 "$directory/server.key" "$directory/server.crt"
}
make_certificate central plainpost-api.olhapi.com "$temporary/central-tls"
make_certificate central-node-one node-one.private-beta.ts.net "$temporary/node-one-central-tls"
make_certificate central-node-two node-two.private-beta.ts.net "$temporary/node-two-central-tls"
for node_name in node-one node-two; do
  verify_certificate_dns_san "$temporary/$node_name-central-tls/server.crt" "$node_name.private-beta.ts.net"
done
make_certificate postgres postgres "$temporary/postgres-central-tls"
make_certificate postgres-node-one postgres-node-one "$temporary/postgres-node-one-tls"
make_certificate postgres-node-two postgres-node-two "$temporary/postgres-node-two-tls"
chmod 0644 "$temporary/postgres-central-tls/server.crt" "$temporary/postgres-central-tls/server.key" "$temporary/postgres-node-one-tls/server.crt" "$temporary/postgres-node-one-tls/server.key" "$temporary/postgres-node-two-tls/server.crt" "$temporary/postgres-node-two-tls/server.key"
make_certificate minio minio "$temporary/minio-tls"
make_certificate mail mail.private-beta.ts.net "$temporary/mail-tls" imap-fixture smtp-fixture
make_certificate smtp-wrong-host wrong-host.example.test "$temporary/mail-wrong-host-tls"
openssl verify -CAfile "$temporary/ca.crt" "$temporary/mail-wrong-host-tls/server.crt" >>"$runtime_log" 2>&1
make_untrusted_certificate() {
  name=$1
  hostname=$2
  directory=$3
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -pkeyopt ec_param_enc:named_curve -nodes -subj "/CN=$hostname" -keyout "$directory/server.key" -out "$directory/server.csr" >>"$runtime_log" 2>&1
  printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$hostname" >"$directory/extensions"
  openssl x509 -req -sha256 -days 1 -in "$directory/server.csr" -CA "$temporary/untrusted-ca.crt" -CAkey "$temporary/untrusted-ca.key" -CAcreateserial -extfile "$directory/extensions" -out "$directory/server.crt" >>"$runtime_log" 2>&1
  chmod 0600 "$directory/server.key" "$directory/server.crt"
}
make_untrusted_certificate smtp-untrusted smtp-fixture "$temporary/mail-untrusted-tls"
openssl verify -CAfile "$temporary/untrusted-ca.crt" "$temporary/mail-untrusted-tls/server.crt" >>"$runtime_log" 2>&1
cp "$root/Scripts/lib/plainpost_acceptance_mail_fixture.py" "$temporary/mail-fixture/plainpost_acceptance_mail_fixture.py"
cp "$root/Scripts/lib/plainpost_acceptance_mail_state.py" "$temporary/mail-fixture/plainpost_acceptance_mail_state.py"
cp "$root/Scripts/lib/plainpost_acceptance_mail_control.py" "$temporary/mail-fixture/plainpost_acceptance_mail_control.py"
chmod 0700 "$temporary/mail-fixture/plainpost_acceptance_mail_fixture.py" "$temporary/mail-fixture/plainpost_acceptance_mail_state.py" "$temporary/mail-fixture/plainpost_acceptance_mail_control.py"
cp "$root/Scripts/lib/postgres-tls-entrypoint.sh" "$temporary/postgres-tls-entrypoint.sh"
chmod 0700 "$temporary/postgres-tls-entrypoint.sh"
fixture_attachment_base64=$(dd if=/dev/zero bs=1024 count=256 2>/dev/null | base64 | tr -d '\n')
printf '%s\n' "{\"uidValidity\":1,\"nextUID\":3,\"messages\":[{\"uid\":1,\"flags\":[],\"labels\":[\"INBOX\"],\"raw\":\"Message-ID: <acceptance-one@example.test>\\r\\nFrom: acceptance@example.test\\r\\nTo: recipient@example.test\\r\\nSubject: Plainpost acceptance é\\r\\nMIME-Version: 1.0\\r\\nContent-Type: multipart/mixed; boundary=\\\"plainpost-attachment-boundary\\\"\\r\\n\\r\\n--plainpost-attachment-boundary\\r\\nContent-Type: multipart/alternative; boundary=\\\"plainpost-alternative-boundary\\\"\\r\\n\\r\\n--plainpost-alternative-boundary\\r\\nContent-Type: text/plain; charset=utf-8\\r\\nContent-Transfer-Encoding: 8bit\\r\\n\\r\\nUnicode acceptance body\\r\\n--plainpost-alternative-boundary\\r\\nContent-Type: text/html; charset=utf-8\\r\\nContent-Transfer-Encoding: 8bit\\r\\n\\r\\n<p>Unicode <strong>acceptance</strong> body</p>\\r\\n--plainpost-alternative-boundary--\\r\\n--plainpost-attachment-boundary\\r\\nContent-Type: application/octet-stream; name=\\\"fixture.bin\\\"\\r\\nContent-Transfer-Encoding: base64\\r\\nContent-Disposition: attachment; filename=\\\"fixture.bin\\\"\\r\\n\\r\\n$fixture_attachment_base64\\r\\n--plainpost-attachment-boundary--\\r\\n\"},{\"uid\":2,\"flags\":[],\"labels\":[\"INBOX\"],\"raw\":\"Message-ID: <acceptance-two@example.test>\\r\\nFrom: acceptance@example.test\\r\\nTo: recipient@example.test\\r\\nSubject: Plainpost continuation\\r\\nContent-Type: text/plain; charset=utf-8\\r\\n\\r\\nContinuation body\\r\\n\"}]}" >"$temporary/mail-state/mailbox.json"
chmod 0600 "$temporary/mail-state/mailbox.json"
if [ "$acceptance_mail_scenario" = imap-uid-gaps ]; then
  if ! prepare_uid_gap_fixture "$temporary/mail-state/mailbox.json"; then
    printf 'UID-gap fixture seed validation failed\n' >&2
    exit 1
  fi
  chmod 0600 "$temporary/mail-state/mailbox.json"
fi
if [ "$acceptance_mail_scenario" = imap-mime-boundaries ]; then
  PLAINPOST_ACCEPTANCE_MAIL_ROOT="$temporary/mail-state" python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["PLAINPOST_ACCEPTANCE_MAIL_ROOT"]) / "mailbox.json"
mailbox = json.loads(path.read_text(encoding="utf-8"))
message = mailbox["messages"][0]
marker = "--plainpost-attachment-boundary\r\nContent-Type: application/octet-stream; name=\"fixture.bin\""
message["raw"] = message["raw"].replace(
    "To: recipient@example.test\r\n",
    "To: recipient@example.test\r\nReply-To: <broken\r\n",
    1,
)
corpus = (
    "--plainpost-attachment-boundary\r\n"
    "Content-Type: multipart/related; boundary=\"plainpost-related-boundary\"\r\n\r\n"
    "--plainpost-related-boundary\r\n"
    "Content-Type: text/html; charset=utf-8\r\n"
    "Content-Transfer-Encoding: base64\r\n\r\n"
    "PHA+UmVsYXRlZCBIVE1MPC9wPg==\r\n"
    "--plainpost-related-boundary\r\n"
    "Content-Type: image/png; name*=utf-8''logo.png\r\n"
    "Content-ID: <logo@example.test>\r\n"
    "Content-Disposition: inline\r\n"
    "Content-Transfer-Encoding: base64\r\n\r\n"
    "iVBORw==\r\n"
    "--plainpost-related-boundary--\r\n"
    "--plainpost-attachment-boundary\r\n"
    "Content-Type: text/plain; charset=iso-8859-1\r\n"
    "Content-Transfer-Encoding: quoted-printable\r\n"
    "Content-Disposition: attachment; filename*=utf-8''caf%C3%A9.txt\r\n\r\n"
    "caf=E9\r\n"
    "--plainpost-attachment-boundary\r\n"
    "Content-Type: application/octet-stream\r\n"
    "Content-Disposition: attachment; filename=empty.bin\r\n\r\n"
    "--plainpost-attachment-boundary\r\n"
    "Content-Type: application/octet-stream\r\n"
    "Content-Disposition: attachment; filename=\"../../secret.txt\"\r\n\r\n"
    "evil\r\n"
)
if marker not in message["raw"]:
    raise SystemExit("MIME corpus insertion marker missing")
message["raw"] = message["raw"].replace(marker, corpus + marker, 1)
path.write_text(json.dumps(mailbox, ensure_ascii=False), encoding="utf-8")
PY
  chmod 0600 "$temporary/mail-state/mailbox.json"
fi
cp "$temporary/minio-tls/server.crt" "$temporary/minio-tls/public.crt"
cp "$temporary/minio-tls/server.key" "$temporary/minio-tls/private.key"
openssl rand -hex 16 | tr -d '\n' >"$temporary/shared-secrets/s3_access"
openssl rand -hex 32 | tr -d '\n' >"$temporary/shared-secrets/s3_secret"
chmod 0600 "$temporary/shared-secrets"/*
: >"$patterns"
chmod 0600 "$patterns"
: >"$privacy_pattern_origins"
chmod 0600 "$privacy_pattern_origins"
for secret_file in "$temporary/shared-secrets/s3_access" "$temporary/shared-secrets/s3_secret"; do
  case "$secret_file" in
    */s3_access) privacy_pattern_origin=s3-access ;;
    */s3_secret) privacy_pattern_origin=s3-secret ;;
    *) printf 'unknown privacy secret family\n' >&2; exit 1 ;;
  esac
  privacy_pattern_value=$(tr -d '\n' <"$secret_file")
  acceptance_privacy_pattern_append "$patterns" "$privacy_pattern_origins" "$privacy_pattern_origin" "$privacy_pattern_value"
  privacy_pattern_value=$(base64 <"$secret_file" | tr -d '\n')
  acceptance_privacy_pattern_append "$patterns" "$privacy_pattern_origins" "$privacy_pattern_origin" "$privacy_pattern_value"
  privacy_pattern_value=$(xxd -p "$secret_file" | tr -d '\n')
  acceptance_privacy_pattern_append "$patterns" "$privacy_pattern_origins" "$privacy_pattern_origin" "$privacy_pattern_value"
done
if [ "$transport_release_images" = 1 ]; then
  printf 'postgres://plainpost_central:%s@postgres:5432/plainpost_central?sslmode=verify-full&sslrootcert=/run/plainpost-public/postgres-ca.pem&search_path=account\n' \
    "$release_central_db_password" >"$temporary/central-secrets/central-database-url"
  printf 'postgres://plainpost_central:%s@postgres:5432/plainpost_central?sslmode=verify-full&sslrootcert=/run/plainpost-public/postgres-ca.pem&search_path=deletion_journal\n' \
    "$release_central_db_password" >"$temporary/central-secrets/central-deletion-journal-database-url"
  chmod 0600 "$temporary/central-secrets/central-database-url" "$temporary/central-secrets/central-deletion-journal-database-url"
fi
for node_name in node-one node-two; do
  make_certificate "$node_name" "$node_name.private-beta.ts.net" "$temporary/$node_name-secrets"
  mv "$temporary/$node_name-secrets/server.crt" "$temporary/$node_name-secrets/client_tls_cert"
  mv "$temporary/$node_name-secrets/server.key" "$temporary/$node_name-secrets/client_tls_key"
  database=$(printf '%s' "$node_name" | tr '-' '_')
  database_host="postgres-$node_name"
  if [ "$release_node_one_database_service" = postgres ] && [ "$node_name" = node-one ]; then
    database_host=postgres
  fi
  if [ "$transport_release_images" = 1 ]; then
    printf 'postgres://plainpost_sync_node:%s@%s:5432/plainpost_sync_node?sslmode=verify-full&sslrootcert=/run/plainpost-public/postgres-ca.pem' "$release_node_db_password" "$database_host" >"$temporary/$node_name-secrets/database_url"
    printf 'postgres://plainpost_restore_admin:%s@%s:5432/postgres?sslmode=verify-full&sslrootcert=/run/plainpost-public/postgres-ca.pem' "$release_restore_admin_db_password" "$database_host" >"$temporary/$node_name-secrets/restore_admin_database_url"
    printf 'postgres://plainpost_restore_stage:%s@%s:5432/plainpost_sync_node?sslmode=verify-full&sslrootcert=/run/plainpost-public/postgres-ca.pem' "$release_restore_stage_db_password" "$database_host" >"$temporary/$node_name-secrets/restore_stage_database_url"
    if [ "$node_name" = node-one ]; then
      : >"$temporary/$node_name-secrets/audit_database_url"
    fi
  else
    printf 'postgres://plainpost_sync_node@%s:5432/plainpost_sync_node?sslmode=verify-full&sslrootcert=/run/plainpost-public/postgres-ca.pem' "$database_host" >"$temporary/$node_name-secrets/database_url"
    printf 'postgres://plainpost_restore_admin@%s:5432/postgres?sslmode=verify-full&sslrootcert=/run/plainpost-public/postgres-ca.pem' "$database_host" >"$temporary/$node_name-secrets/restore_admin_database_url"
    printf 'postgres://plainpost_restore_stage@%s:5432/plainpost_sync_node?sslmode=verify-full&sslrootcert=/run/plainpost-public/postgres-ca.pem' "$database_host" >"$temporary/$node_name-secrets/restore_stage_database_url"
  fi
  openssl rand 32 >"$temporary/$node_name-secrets/backup_key"
  mkdir -m 0700 "$temporary/$node_name-data/attachments" "$temporary/$node_name-data/backups" "$temporary/$node_name-data/attachment-staging"
  chmod 0700 "$temporary/$node_name-data/attachments" "$temporary/$node_name-data/backups" "$temporary/$node_name-data/attachment-staging"
  [ -d "$temporary/$node_name-data/attachments" ] && [ -w "$temporary/$node_name-data/attachments" ] || { printf 'Node fixed attachment root is not host-writable\n' >&2; exit 1; }
  [ -d "$temporary/$node_name-data/backups" ] && [ -w "$temporary/$node_name-data/backups" ] || { printf 'Node backup root is not host-writable\n' >&2; exit 1; }
  for authority_file in database_url restore_admin_database_url restore_stage_database_url backup_key; do
    [ "$(stat -f '%Lp' "$temporary/$node_name-secrets/$authority_file" 2>/dev/null || stat -c '%a' "$temporary/$node_name-secrets/$authority_file")" = 600 ] || { printf 'Node secret file is not mode 0600\n' >&2; exit 1; }
  done
  if [ "$node_name" = node-one ] && [ "$transport_release_images" = 1 ]; then
    [ "$(stat -f '%Lp' "$temporary/$node_name-secrets/audit_database_url" 2>/dev/null || stat -c '%a' "$temporary/$node_name-secrets/audit_database_url")" = 600 ] || { printf 'Node audit database authority file is not mode 0600\n' >&2; exit 1; }
  fi
  [ "$(stat -f '%Lp' "$temporary/$node_name-secrets/database_url" 2>/dev/null || stat -c '%a' "$temporary/$node_name-secrets/database_url")" = 600 ] || { printf 'Node database authority file is not mode 0600\n' >&2; exit 1; }
  openssl rand 32 >"$temporary/$node_name-secrets/master_key"
  printf '%s' 'acceptance-password' >"$temporary/$node_name-secrets/provider_password"
  cp "$temporary/shared-secrets/s3_access" "$temporary/$node_name-secrets/s3_access"
  cp "$temporary/shared-secrets/s3_secret" "$temporary/$node_name-secrets/s3_secret"
  chmod 0600 "$temporary/$node_name-secrets"/*
done
cp "$temporary/node-one-secrets/provider_password" "$temporary/control/smtp-probe-password"
chmod 0600 "$temporary/control/smtp-probe-password"
if [ "$transport_release_images" = 1 ]; then
  bash "$secret_ownership_helper" "$temporary" "$postgres_ownership_image" private-release "$secret_ownership_validation_mode"
fi
for secret_file in "$temporary/node-one-secrets/provider_password"; do
  privacy_pattern_origin=provider-password
  privacy_pattern_value=$(tr -d '\n' <"$secret_file")
  acceptance_privacy_pattern_append "$patterns" "$privacy_pattern_origins" "$privacy_pattern_origin" "$privacy_pattern_value"
  privacy_pattern_value=$(base64 <"$secret_file" | tr -d '\n')
  acceptance_privacy_pattern_append "$patterns" "$privacy_pattern_origins" "$privacy_pattern_origin" "$privacy_pattern_value"
  privacy_pattern_value=$(xxd -p "$secret_file" | tr -d '\n')
  acceptance_privacy_pattern_append "$patterns" "$privacy_pattern_origins" "$privacy_pattern_origin" "$privacy_pattern_value"
done
privacy_pattern_initial_line_count=$(wc -l <"$patterns" | tr -d '[:space:]')

for node_name in node-one node-two; do
  (cd "$root/Services/PlainpostGo" && GOCACHE="$temporary/go-cache" go run ./cmd/plainpost-sync-node-acceptance-preflight \
    -database-url "$temporary/$node_name-secrets/database_url" \
    -restore-admin-url "$temporary/$node_name-secrets/restore_admin_database_url" \
    -restore-stage-url "$temporary/$node_name-secrets/restore_stage_database_url" \
    -attachments "$temporary/$node_name-data/attachments" \
    -backup-root "$temporary/$node_name-data/backups" \
    -backup-key "$temporary/$node_name-secrets/backup_key") >>"$runtime_log" 2>&1
done

printf 'stage=postgres-private\n'
if ! compose_run up -d $release_startup_database_services minio minio-init central central-tls imap-fixture smtp-fixture >>"$runtime_log" 2>&1; then
  printf 'central acceptance stack startup failed\n' >&2
  exit 1
fi
mail_authority_phase=poststart
if [ "$transport_release_images" = 1 ]; then
  release_primary_container=$(compose_run ps -q "$release_primary_database_service")
  release_replacement_container=$(compose_run ps -q "$release_replacement_database_service")
  [ -n "$release_primary_container" ] && [ -n "$release_replacement_container" ] || {
    printf 'release PostgreSQL topology containers are incomplete\n' >&2
    exit 1
  }
  [ -z "$(compose_run ps -q postgres-node-one)" ] || {
    printf 'release mode started the forbidden postgres-node-one service\n' >&2
    exit 1
  }
  primary_label=$(docker inspect --format '{{index .Config.Labels "com.plainpost.release.topology"}}' "$release_primary_container")
  replacement_label=$(docker inspect --format '{{index .Config.Labels "com.plainpost.release.topology"}}' "$release_replacement_container")
  [ "$primary_label" = primary ] && [ "$replacement_label" = replacement-isolated ] || {
    printf 'release PostgreSQL services are missing primary/replacement labels\n' >&2
    exit 1
  }
  release_server_version=$(docker exec "$release_primary_container" psql -U "$release_central_role" -d "$release_central_database" -Atc 'SHOW server_version_num')
  release_replacement_version=$(docker exec "$release_replacement_container" psql -U "$node_database_inspection_role" -d "$node_one_database_name" -Atc 'SHOW server_version_num')
  case "$release_server_version:$release_replacement_version" in
    18*:18*) ;;
    *) printf 'release PostgreSQL services are not major 18\n' >&2; exit 1 ;;
  esac
  release_production_database_names=$(docker exec "$release_primary_container" psql -U "$release_central_role" -d "$release_central_database" -Atc "SELECT string_agg(datname, ',' ORDER BY datname) FROM pg_database WHERE NOT datistemplate AND datname NOT IN ('postgres')")
  [ "$release_production_database_names" = 'plainpost_central,plainpost_sync_node' ] || {
    printf 'release primary PostgreSQL logical database set is not exactly Central and Sync Node\n' >&2
    exit 1
  }
  # Task 10 release evidence is bounded to major/version and migration-head
  # facts. Never retain URLs, credentials, account identifiers, or SQL data.
  release_dump_client_version=$(docker run --rm --pull never --entrypoint /usr/bin/pg_dump "$release_node_image" --version)
  release_restore_client_version=$(docker run --rm --pull never --entrypoint /usr/bin/pg_restore "$release_node_image" --version)
  case "$release_dump_client_version:$release_restore_client_version" in
    'pg_dump (PostgreSQL) 18.'*:'pg_restore (PostgreSQL) 18.'*) ;;
    *) printf 'release PostgreSQL packaged clients are not major 18\n' >&2; exit 1 ;;
  esac
  release_central_account_head=$(docker exec "$release_primary_container" psql -U "$release_central_role" -d "$release_central_database" -Atc "SELECT version::text || ':' || name FROM account.schema_migrations ORDER BY version DESC LIMIT 1")
  release_central_deletion_journal_head=$(docker exec "$release_primary_container" psql -U "$release_journal_role" -d "$release_journal_database" -Atc "SELECT version::text || ':' || name FROM deletion_journal.schema_migrations ORDER BY version DESC LIMIT 1")
  [ "$release_central_account_head" = '31:0031_direct_notification_policies.sql' ] || { printf 'release Central account migrations are not current\n' >&2; exit 1; }
  [ "$release_central_deletion_journal_head" = '4:0004_opaque_account_handles.sql' ] || { printf 'release Central deletion-journal migrations are not current\n' >&2; exit 1; }
  printf 'release-postgres-server-version=%s replacement=%s production-databases=%s\n' \
    "$release_server_version" "$release_replacement_version" "$release_production_database_names"
  printf 'release-postgres-client-versions=%s,%s\n' \
    "$release_dump_client_version" "$release_restore_client_version"
  printf 'stage=release-topology primary=%s replacement=%s\n' "$release_primary_database_service" "$release_replacement_database_service"
fi
if [ "$acceptance_smtp_tls_mode" != normal ]; then
  PLAINPOST_ACCEPTANCE_SMTP_TLS_MODE="$acceptance_smtp_tls_mode" export PLAINPOST_ACCEPTANCE_SMTP_TLS_MODE
  if ! compose_run up -d --no-deps --force-recreate smtp-fixture >>"$runtime_log" 2>&1; then
    printf 'SMTP TLS mode restart failed\n' >&2
    exit 1
  fi
  smtp_mode_container=$(compose_run ps -q smtp-fixture)
  smtp_mode_health=starting
  for _ in $(seq 1 60); do
    smtp_mode_health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}starting{{end}}' "$smtp_mode_container" 2>/dev/null || true)
    [ "$smtp_mode_health" = healthy ] && break
    sleep 1
  done
  [ "$smtp_mode_health" = healthy ] || { printf 'SMTP TLS mode restart did not become healthy\n' >&2; exit 1; }
fi
if [ "$acceptance_imap_tls_mode" != normal ]; then
  PLAINPOST_ACCEPTANCE_IMAP_TLS_MODE="$acceptance_imap_tls_mode" export PLAINPOST_ACCEPTANCE_IMAP_TLS_MODE
  if ! compose_run up -d --no-deps --force-recreate imap-fixture >>"$runtime_log" 2>&1; then
    printf 'IMAP TLS mode restart failed\n' >&2
    exit 1
  fi
  imap_mode_container=$(compose_run ps -q imap-fixture)
  imap_mode_health=starting
  for _ in $(seq 1 60); do
    imap_mode_health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}starting{{end}}' "$imap_mode_container" 2>/dev/null || true)
    [ "$imap_mode_health" = healthy ] && break
    sleep 1
  done
  [ "$imap_mode_health" = healthy ] || { printf 'IMAP TLS mode restart did not become healthy\n' >&2; exit 1; }
fi
if [ -n "$acceptance_mail_scenario" ]; then
  case "$acceptance_mail_scenario" in
    smtp-authentication) smtp_matrix_fault=smtp-authentication; smtp_matrix_result=rejected; smtp_matrix_phase=none ;;
    smtp-recipient-451) smtp_matrix_fault=smtp-recipient-451; smtp_matrix_result=temporary; smtp_matrix_phase=none ;;
    smtp-recipient-550) smtp_matrix_fault=smtp-recipient-550; smtp_matrix_result=rejected; smtp_matrix_phase=none ;;
    smtp-after-354) smtp_matrix_fault=smtp-after-354; smtp_matrix_result=disconnect; smtp_matrix_phase=none ;;
    smtp-mid-data) smtp_matrix_fault=smtp-mid-data; smtp_matrix_result=disconnect; smtp_matrix_phase=none ;;
    smtp-final-reply) smtp_matrix_fault=smtp-final-reply; smtp_matrix_result=disconnect; smtp_matrix_phase=none ;;
    smtp-quit-loss) smtp_matrix_fault=smtp-quit-loss; smtp_matrix_result=disconnect; smtp_matrix_phase=none ;;
    smtp-cancel-before-data) smtp_matrix_fault=none; smtp_matrix_result=none; smtp_matrix_phase=before-data ;;
    smtp-cancel-after-data) smtp_matrix_fault=smtp-final-reply; smtp_matrix_result=disconnect; smtp_matrix_phase=acceptance-before-append ;;
    smtp-sent-append-failure) smtp_matrix_fault=none; smtp_matrix_result=temporary; smtp_matrix_phase=sent-append; smtp_matrix_protocol=imap ;;
    smtp-provider-restart-after-acceptance) smtp_matrix_fault=none; smtp_matrix_result=none; smtp_matrix_phase=sent-append; smtp_matrix_protocol=imap; smtp_matrix_fault_occurrence=1 ;;
    smtp-untrusted-certificate|smtp-same-ca-wrong-host|smtp-tls1.1|smtp-auth-before-starttls) smtp_matrix_fault=none; smtp_matrix_result=rejected; smtp_matrix_phase=none ;;
    smtp-concurrent-sends) smtp_matrix_fault=none; smtp_matrix_result=none; smtp_matrix_phase=none ;;
    smtp-ambiguous-replay) smtp_matrix_fault=smtp-final-reply; smtp_matrix_result=disconnect; smtp_matrix_phase=none ;;
    imap-truncated-literal) imap_matrix_fault=imap-truncated-literal; imap_matrix_result=truncated; imap_matrix_phase=attachment-fetch; imap_matrix_protocol=imap ;;
    imap-authentication) imap_matrix_fault=none; imap_matrix_result=none; imap_matrix_phase=none; imap_matrix_protocol=imap ;;
    imap-untrusted-certificate|imap-same-ca-wrong-host|imap-tls1.1) imap_matrix_result=rejected; imap_matrix_phase=none; imap_matrix_protocol=imap ;;
    imap-catalog) imap_matrix_fault=none; imap_matrix_result=none; imap_matrix_phase=none; imap_matrix_protocol=imap ;;
    imap-header-fetch) imap_matrix_fault=none; imap_matrix_result=none; imap_matrix_phase=none; imap_matrix_protocol=imap; acceptance_imap_fetch_phase=header-fetch ;;
    imap-body-fetch) imap_matrix_fault=none; imap_matrix_result=none; imap_matrix_phase=none; imap_matrix_protocol=imap; acceptance_imap_fetch_phase=body-fetch ;;
    imap-attachment-fetch) imap_matrix_fault=imap-attachment-fetch; imap_matrix_result=disconnect; imap_matrix_phase=attachment-fetch; imap_matrix_protocol=imap ;;
    imap-delayed-literal) imap_matrix_fault=none; imap_matrix_result=none; imap_matrix_phase=none; imap_matrix_protocol=imap; acceptance_imap_fetch_phase=header-fetch ;;
    imap-uid-gaps|imap-expunge|imap-uidvalidity-reset|imap-idle-wakeup|imap-poll-fallback|imap-provider-restart-after-commit|imap-node-restart-after-ack|imap-concurrent-mutations|imap-stale-authority|imap-mime-boundaries) imap_matrix_fault=none; imap_matrix_result=none; imap_matrix_phase=none; imap_matrix_protocol=imap ;;
    imap-provider-restart-mid-page) imap_matrix_fault=none; imap_matrix_result=disconnect; imap_matrix_phase=none; imap_matrix_protocol=imap ;;
    imap-node-restart-before-ack) imap_matrix_fault=none; imap_matrix_result=disconnect; imap_matrix_phase=mutation; imap_matrix_protocol=imap ;;
    *) printf 'SMTP matrix scenario is outside the closed shell allowlist\n' >&2; exit 1 ;;
  esac
  if [ "$smtp_matrix_fault" != none ]; then
    mail_control arm-fault "$smtp_matrix_fault" "${smtp_matrix_fault_occurrence:-1}" "$smtp_matrix_result" >>"$runtime_log" 2>&1
  fi
  if [ "$imap_matrix_fault" != none ]; then
    mail_control arm-fault "$imap_matrix_fault" 1 "$imap_matrix_result" >>"$runtime_log" 2>&1
  fi
  if [ "$smtp_matrix_phase" != none ]; then
    mail_control phase "${smtp_matrix_protocol:-smtp}" "$smtp_matrix_phase" 1 pause >>"$runtime_log" 2>&1
  fi
  if [ "$imap_matrix_phase" != none ]; then
    mail_control phase "$imap_matrix_protocol" "$imap_matrix_phase" 1 pause >>"$runtime_log" 2>&1
  fi
fi
for database_service in $release_database_services; do
  case "$database_service" in
    postgres) database_node=node-one ;;
    postgres-node-one) database_node=node-one ;;
    postgres-node-two) database_node=node-two ;;
    *) printf '%s PostgreSQL service is outside the release topology\n' "$database_service" >&2; exit 1 ;;
  esac
  database_container=$(compose_run ps -q "$database_service")
  [ -n "$database_container" ] || { printf '%s PostgreSQL container missing\n' "$database_service" >&2; exit 1; }
  database_ready=''
  for _ in $(seq 1 90); do
    database_ready=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}starting{{end}}' "$database_container" 2>/dev/null || true)
    [ "$database_ready" = healthy ] && break
    sleep 1
  done
  [ "$(stat -f '%Lp' "$temporary/$database_node-secrets/provider_password" 2>/dev/null || stat -c '%a' "$temporary/$database_node-secrets/provider_password")" = 600 ] || { printf 'Node provider credential file is not mode 0600\n' >&2; exit 1; }
  [ "$database_ready" = healthy ] || { printf '%s PostgreSQL did not become healthy\n' "$database_service" >&2; exit 1; }
  # The official image can report healthy while its initdb hooks are still
  # finishing. Wait for the exact runtime authority rather than treating
  # health as proof that the isolated role/database exists.
  database_authority_expected=$(printf 'plainpost_sync_node\tplainpost_sync_node')
  database_authority=''
  for _ in $(seq 1 90); do
    database_authority=$(docker exec "$database_container" psql -U plainpost_sync_node -d "$node_one_database_name" -Atc 'select current_user || chr(9) || current_database()' 2>/dev/null || true)
    [ "$database_authority" = "$database_authority_expected" ] && break
    sleep 1
  done
  [ "$database_authority" = "$database_authority_expected" ] || {
    printf '%s PostgreSQL init did not create its isolated authority\n' "$database_service" >&2
    exit 1
  }
  [ "$(docker exec "$database_container" psql -U plainpost_sync_node -d "$node_one_database_name" -Atc 'select current_user || chr(9) || current_database()' 2>/dev/null)" = 'plainpost_sync_node	plainpost_sync_node' ] || {
    printf '%s PostgreSQL init did not create its isolated authority\n' "$database_service" >&2
    exit 1
  }
  role_flags=$(docker exec "$database_container" psql -U plainpost_node_bootstrap -d postgres -Atc "select rolcanlogin::text || chr(9) || rolsuper::text || chr(9) || rolcreatedb::text || chr(9) || rolcreaterole::text || chr(9) || rolinherit::text || chr(9) || rolreplication::text || chr(9) || rolbypassrls::text from pg_roles where rolname='plainpost_sync_node'")
  [ "$role_flags" = 'true	false	false	false	false	false	false' ] || {
    printf '%s PostgreSQL runtime role flags are unsafe\n' "$database_service" >&2
    exit 1
  }
  restore_admin_flags=$(docker exec "$database_container" psql -U plainpost_node_bootstrap -d postgres -Atc "select rolcanlogin::text || chr(9) || rolsuper::text || chr(9) || rolcreatedb::text || chr(9) || rolcreaterole::text || chr(9) || rolinherit::text || chr(9) || rolreplication::text || chr(9) || rolbypassrls::text from pg_roles where rolname='plainpost_restore_admin'")
  [ "$restore_admin_flags" = 'true	false	true	false	false	false	false' ] || {
    printf '%s PostgreSQL restore admin role flags are unsafe\n' "$database_service" >&2
    exit 1
  }
  restore_stage_flags=$(docker exec "$database_container" psql -U plainpost_node_bootstrap -d postgres -Atc "select rolcanlogin::text || chr(9) || rolsuper::text || chr(9) || rolcreatedb::text || chr(9) || rolcreaterole::text || chr(9) || rolinherit::text || chr(9) || rolreplication::text || chr(9) || rolbypassrls::text from pg_roles where rolname='plainpost_restore_stage'")
  [ "$restore_stage_flags" = 'true	false	false	false	false	false	false' ] || {
    printf '%s PostgreSQL restore stage role flags are unsafe\n' "$database_service" >&2
    exit 1
  }
  database_owner=$(docker exec "$database_container" psql -U plainpost_node_bootstrap -d postgres -Atc "select pg_get_userbyid(datdba) from pg_database where datname='plainpost_sync_node'")
  [ "$database_owner" = plainpost_restore_admin ] || {
    printf '%s PostgreSQL fixed database owner is not restore admin\n' "$database_service" >&2
    exit 1
  }
  restore_admin_membership_roles=$(docker exec "$database_container" psql -U plainpost_node_bootstrap -d postgres -Atc "select coalesce(string_agg(pg_get_userbyid(roleid), ',' order by pg_get_userbyid(roleid)), '') from pg_auth_members where member=(select oid from pg_roles where rolname='plainpost_restore_admin')")
  restore_stage_memberships=$(docker exec "$database_container" psql -U plainpost_node_bootstrap -d postgres -Atc "select count(*) from pg_auth_members where member=(select oid from pg_roles where rolname='plainpost_restore_stage')")
  [ "$restore_admin_membership_roles" = 'plainpost_restore_stage,plainpost_sync_node' ] && [ "$restore_stage_memberships" = 0 ] || {
    printf '%s PostgreSQL restore role memberships are not canonical\n' "$database_service" >&2
    exit 1
  }
  owned_database_count=$(docker exec "$database_container" psql -U plainpost_node_bootstrap -d postgres -Atc "select count(*) from pg_database where datdba=(select oid from pg_roles where rolname='plainpost_sync_node')")
  [ "$owned_database_count" = 0 ] || {
    printf '%s PostgreSQL runtime role owns a database\n' "$database_service" >&2
    exit 1
  }
  membership_count=$(docker exec "$database_container" psql -U plainpost_node_bootstrap -d postgres -Atc "select count(*) from pg_auth_members where member=(select oid from pg_roles where rolname='plainpost_sync_node')")
  [ "$membership_count" = 0 ] || {
    printf '%s PostgreSQL runtime role has role membership\n' "$database_service" >&2
    exit 1
  }
  connected_database_count=$(docker exec "$database_container" psql -U plainpost_node_bootstrap -d postgres -Atc "select count(*) from pg_database as candidate where candidate.datallowconn and not candidate.datistemplate and candidate.datname <> 'plainpost_sync_node' and has_database_privilege('plainpost_sync_node',candidate.oid,'CONNECT')")
  own_connected_database_count=$(docker exec "$database_container" psql -U plainpost_node_bootstrap -d postgres -Atc "select count(*) from pg_database where datname='plainpost_sync_node' and has_database_privilege('plainpost_sync_node',datname,'CONNECT')")
  [ "$connected_database_count" = 0 ] && [ "$own_connected_database_count" = 1 ] || {
    printf '%s PostgreSQL runtime role has an unexpected database CONNECT grant\n' "$database_service" >&2
    exit 1
  }
  schema_privileges=$(docker exec "$database_container" psql -U plainpost_node_bootstrap -d "$node_one_database_name" -Atc "select has_schema_privilege('plainpost_sync_node','public','USAGE')::text || chr(9) || has_schema_privilege('plainpost_sync_node','public','CREATE')::text")
  [ "$schema_privileges" = 'true	true' ] || {
    printf '%s PostgreSQL runtime role lacks exact public schema grants\n' "$database_service" >&2
    exit 1
  }
done
printf 'stage=central-containers-started\n'
central_container=$(compose_run ps -q central-tls)
private_central_port=$(docker port "$central_container" 443/tcp | sed -n 's/^127\.0\.0\.1://p')
[ -n "$private_central_port" ]
for _ in $(seq 1 90); do
  if curl --silent --fail --noproxy '*' --cacert "$temporary/ca.crt" --connect-to "plainpost-api.olhapi.com:443:127.0.0.1:$private_central_port" https://plainpost-api.olhapi.com/readyz >/dev/null 2>&1; then break; fi
  sleep 1
done
curl --silent --fail --noproxy '*' --cacert "$temporary/ca.crt" --connect-to "plainpost-api.olhapi.com:443:127.0.0.1:$private_central_port" https://plainpost-api.olhapi.com/readyz >/dev/null
printf 'stage=central-ready\n'
postgres_container=$(compose_run ps -q postgres)
for _ in $(seq 1 90); do
  [ "$(docker exec "$postgres_container" psql -U "$release_journal_role" -d "$release_journal_database" -Atc "$release_journal_probe" 2>/dev/null)" = t ] && break
  sleep 1
done
[ "$(docker exec "$postgres_container" psql -U "$release_journal_role" -d "$release_journal_database" -Atc "$release_journal_probe")" = t ]
printf 'stage=journal-ready\n'

export_node_installation_identity() {
  identity_service=$1
  identity_output=$2
  : >"$identity_output"
  chmod 0600 "$identity_output"
  for identity_attempt in $(seq 1 30); do
    identity_container=$(compose_run ps -q "$identity_service")
    if [ -n "$identity_container" ] && docker exec "$identity_container" /plainpost-sync-node installation-identity >"$identity_output" 2>>"$runtime_log" && [ -s "$identity_output" ]; then
      return 0
    fi
    : >"$identity_output"
    sleep 1
  done
  printf '%s installation identity is unavailable\n' "$identity_service" >&2
  return 1
}

append_bootstrap_privacy_patterns() {
  profile_path=$1
  verifier_path=$2
  PYTHONDONTWRITEBYTECODE=1 python3 - "$profile_path" "$verifier_path" >>"$patterns" <<'PY'
import base64
import json
import pathlib
import sys

values = []
for path, fields in ((sys.argv[1], ("capability", "capabilityID")), (sys.argv[2], ("capabilityID", "capabilityVerifier"))):
    document = json.loads(pathlib.Path(path).read_text(encoding="ascii"))
    values.extend(document[field].encode("ascii") for field in fields)
for value in values:
    if len(value) >= 12:
        print(value.decode("ascii"))
        print(base64.b64encode(value).decode("ascii"))
        print(value.hex())
PY
}

provision_node_bootstrap() {
  bootstrap_node=$1
  bootstrap_origin=$2
  bootstrap_identity="$temporary/$bootstrap_node/installation-identity.json"
  bootstrap_output="$temporary/$bootstrap_node/owner-bootstrap"
  bootstrap_receipt="$temporary/$bootstrap_node/bootstrap-receipt.json"
  : >"$bootstrap_receipt"
  chmod 0600 "$bootstrap_receipt"
  PYTHONDONTWRITEBYTECODE=1 "$bootstrap_provisioner" "$bootstrap_identity" "$bootstrap_origin" "$acceptance_central_audience" "$bootstrap_output" >"$bootstrap_receipt" 2>>"$runtime_log"
  bootstrap_profile=$(find "$bootstrap_output" -type f -name '*.plainpostserver' -print)
  [ -n "$bootstrap_profile" ] && [ "$(printf '%s\n' "$bootstrap_profile" | wc -l | tr -d '[:space:]')" = 1 ] || {
    printf '%s protected bootstrap profile is unavailable\n' "$bootstrap_node" >&2
    return 1
  }
  [ "$(stat -f '%Lp' "$bootstrap_profile" 2>/dev/null || stat -c '%a' "$bootstrap_profile")" = 600 ] || return 1
  generator_verifier="$bootstrap_output/node-bootstrap-verifier.json"
  installed_verifier="$temporary/$bootstrap_node-secrets/node-bootstrap-verifier.json"
  cp "$generator_verifier" "$installed_verifier"
  chmod 0600 "$installed_verifier"
  cmp -s "$generator_verifier" "$installed_verifier" || {
    printf '%s installed bootstrap verifier differs from provisioner output\n' "$bootstrap_node" >&2
    return 1
  }
  grep -Fq '"kind":"sync-node.bootstrap-verifier.v2"' "$installed_verifier" || {
    printf '%s installed bootstrap verifier is not v2\n' "$bootstrap_node" >&2
    return 1
  }
  # Read privacy patterns from the host-owned descriptor while it is still
  # accessible. Release mode changes only the installed copy to the Node UID.
  append_bootstrap_privacy_patterns "$bootstrap_profile" "$generator_verifier"
  if [ "$transport_release_images" = 1 ]; then
    docker run --rm --pull never --user 0:0 --entrypoint /bin/sh \
      -v "$temporary/$bootstrap_node-secrets:/fixture:rw" "$postgres_ownership_image" \
      -ec 'chown 65532:65532 /fixture/node-bootstrap-verifier.json && chmod 0600 /fixture/node-bootstrap-verifier.json'
  fi
  case "$bootstrap_node" in
    node-one) node_one_bootstrap_profile=$bootstrap_profile ;;
    node-two) node_two_bootstrap_profile=$bootstrap_profile ;;
    *) return 1 ;;
  esac
}

capture_node_process_identity() {
  process_service=$1
  process_output="$temporary/control/$process_service-activation-process"
  process_container=$(compose_run ps -q "$process_service")
  [ -n "$process_container" ] || return 1
  docker inspect --format '{{.Id}} {{.State.Pid}} {{.State.StartedAt}}' "$process_container" >"$process_output"
  chmod 0600 "$process_output"
}

assert_node_process_identity() {
  process_service=$1
  process_expected="$temporary/control/$process_service-activation-process"
  process_actual="$temporary/control/$process_service-hot-process"
  process_container=$(compose_run ps -q "$process_service")
  [ -n "$process_container" ] || return 1
  docker inspect --format '{{.Id}} {{.State.Pid}} {{.State.StartedAt}}' "$process_container" >"$process_actual"
  chmod 0600 "$process_actual"
  cmp -s "$process_expected" "$process_actual" || {
    printf '%s process changed between protected presentation and hot readiness\n' "$process_service" >&2
    return 1
  }
}

# Initialize each durable identity with no bootstrap verifier, export only its
# public document, then stop both nodes before creating the protected pair.
acceptance_node_bootstrap_verifier_file=''
if ! compose_run up -d node-one node-two >>"$runtime_log" 2>&1; then
  printf 'bootstrap identity initialization failed\n' >&2
  exit 1
fi
export_node_installation_identity node-one "$temporary/node-one/installation-identity.json"
export_node_installation_identity node-two "$temporary/node-two/installation-identity.json"
compose_run stop --timeout 10 node-one node-two >>"$runtime_log" 2>&1
provision_node_bootstrap node-one https://node-one.private-beta.ts.net:18443
provision_node_bootstrap node-two https://node-two.private-beta.ts.net:18443
acceptance_node_bootstrap_verifier_file=/run/secrets/node-bootstrap-verifier.json
export PLAINPOST_ACCEPTANCE_NODE_BOOTSTRAP_VERIFIER_FILE="$acceptance_node_bootstrap_verifier_file"

if ! compose_run up -d --force-recreate node-one node-one-relay >>"$runtime_log" 2>&1; then
  printf 'node-one acceptance stack startup failed\n' >&2
  grep -Ei 'error|failed|denied|cannot|unable|not found|conflict|already in use' "$runtime_log" | filter_summary_patterns "$patterns" | tail -20 >&2 || true
  exit 1
fi
node_one_container=$(compose_run ps -q node-one)
export_node_installation_identity node-one "$temporary/node-one/installation-identity-after-provisioning.json"
cmp -s "$temporary/node-one/installation-identity.json" "$temporary/node-one/installation-identity-after-provisioning.json" || {
  printf 'node-one installation identity changed during provisioning\n' >&2
  exit 1
}
if [ "$transport_release_images" = 1 ]; then
  for node_migration_attempt in $(seq 1 90); do
    release_node_migration_head=$(docker exec "$release_primary_container" psql -U plainpost_sync_node -d "$node_one_database_name" -Atc "SELECT version::text || ':' || name FROM node_schema_migrations ORDER BY version DESC LIMIT 1" 2>>"$runtime_log" || true)
    [ "$release_node_migration_head" = '27:0027_capture_optional_address_search_path.sql' ] && break
    sleep 1
  done
  [ "$release_node_migration_head" = '27:0027_capture_optional_address_search_path.sql' ] || { printf 'release Node migrations are not current\n' >&2; exit 1; }
  printf 'release-migration-heads=central-account:%s central-deletion-journal:%s node:%s\n' \
    "$release_central_account_head" "$release_central_deletion_journal_head" "$release_node_migration_head"
fi
compose_run up -d --force-recreate node-two node-two-relay >>"$runtime_log" 2>&1
node_two_container=$(compose_run ps -q node-two)
export_node_installation_identity node-two "$temporary/node-two/installation-identity-after-provisioning.json"
cmp -s "$temporary/node-two/installation-identity.json" "$temporary/node-two/installation-identity-after-provisioning.json" || {
  printf 'node-two installation identity changed during provisioning\n' >&2
  exit 1
}
node_two_relay=$(compose_run ps -q node-two-relay)
central_node_one_container=$(compose_run ps -q central-node-one-tls)
central_node_two_container=$(compose_run ps -q central-node-two-tls)
[ -n "$node_two_container" ] && [ -n "$node_two_relay" ] && [ -n "$central_node_one_container" ] && [ -n "$central_node_two_container" ]
capture_node_process_identity node-one
capture_node_process_identity node-two

assert_node_attachment_mode() {
  container=$1
  expected_source=$2
  node_environment=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container")
  if [ "$acceptance_attachment_storage" = filesystem ]; then
    printf '%s\n' "$node_environment" | grep -Fx 'PLAINPOST_NODE_ATTACHMENT_STORAGE=filesystem' >/dev/null
    printf '%s\n' "$node_environment" | grep -Fx 'PLAINPOST_NODE_ATTACHMENT_DIR=/node-attachments' >/dev/null
  else
    printf '%s\n' "$node_environment" | grep -Fx 'PLAINPOST_NODE_ATTACHMENT_STORAGE=s3' >/dev/null
    if [ ! -d "$expected_source/attachment-staging" ] || [ -L "$expected_source/attachment-staging" ]; then
      printf 'S3 attachment staging root is not mounted as a pre-created directory\n' >&2
      exit 1
    fi
  fi
  node_data_mount=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/node-data"}}{{printf "%s %t" .Source .RW}}{{end}}{{end}}' "$container")
  [ "$node_data_mount" = "$expected_source true" ] || {
    printf 'attachment backend is not mounted read-write at /node-data\n' >&2
    exit 1
  }
  if [ "$acceptance_attachment_storage" = filesystem ]; then
    attachment_mount=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/node-attachments"}}{{printf "%s %t" .Source .RW}}{{end}}{{end}}' "$container")
    [ "$attachment_mount" = "$expected_source/attachments true" ] || {
      printf 'filesystem attachment root is not mounted at its final path\n' >&2
      exit 1
    }
  fi
}
assert_node_attachment_mode "$node_one_container" "$temporary/node-one-data"
assert_node_attachment_mode "$node_two_container" "$temporary/node-two-data"
if [ "${PLAINPOST_SYNC_NODE_CLIENT_API:-}" = enabled ]; then
  node_one_environment=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$node_one_container")
  printf '%s\n' "$node_one_environment" | grep -Fx 'PLAINPOST_ACCEPTANCE_DROP_PHASE_FILE=/node-data/response-drop-phase' >/dev/null || {
    printf 'node-one response-drop phase environment is not the mounted container path\n' >&2
    exit 1
  }
  response_drop_phase_copy="$temporary/response-drop-phase-container-copy"
  docker cp "$node_one_container:/node-data/response-drop-phase" "$response_drop_phase_copy" >/dev/null 2>>"$runtime_log" || {
    printf 'node-one response-drop phase file is not present in its /node-data mount\n' >&2
    exit 1
  }
  chmod 0600 "$response_drop_phase_copy"
  cmp -s "$acceptance_response_drop_phase_file" "$response_drop_phase_copy" || {
    printf 'node-one response-drop phase contents differ from the host control file\n' >&2
    exit 1
  }
  rm -f "$response_drop_phase_copy"
fi
printf 'stage=node-attachment-backend-ready\n'

node_one_database_container=$(compose_run ps -q "$release_node_one_database_service")
# The fixture begins with identity revision 1, binds the bootstrap descriptor
# at revision 2, creates the protected pending claim at revision 3, and commits
# active V3 plus bootstrap consumption atomically at revision 4. The first
# signed status proof then exchanges the one-time refresh credential and
# persists the replacement refresh credential/lease at revision 5. Exact
# activation replay and later reads reuse that state; they do not increment it.
expected_node_one_activation_revision=5
assert_node_one_installation_checkpoint() {
  checkpoint_stage=$1
  checkpoint_revision=$(docker exec "$node_one_database_container" psql -U "$node_database_inspection_role" -d "$node_one_database_name" -Atc "select coalesce(state_revision::text, 'missing') from node_installation_state where singleton=true" 2>>"$runtime_log")
  printf 'ERROR acceptance-checkpoint node=node-one stage=%s revision=%s\n' "$checkpoint_stage" "$checkpoint_revision" >>"$runtime_log"
  [ "$checkpoint_revision" = "$expected_node_one_activation_revision" ] || {
    printf 'node-one installation checkpoint stage=%s revision=%s, want %s\n' "$checkpoint_stage" "$checkpoint_revision" "$expected_node_one_activation_revision" >&2
    exit 1
  }
}

node_one_relay=$(compose_run ps -q node-one-relay)
central_process=$(compose_run ps -q central)
central_entrypoint=$(docker inspect --format '{{join .Config.Entrypoint " "}}' "$central_process")
node_entrypoint=$(docker inspect --format '{{join .Config.Entrypoint " "}}' "$node_one_container")
[ "$central_entrypoint" = /plainpost-api ] && [ "$node_entrypoint" = /plainpost-sync-node ]
central_port=$(docker port "$central_container" 443/tcp | sed -n 's/^127\.0\.0\.1://p')
node_one_port=$(docker port "$node_one_relay" 18443/tcp | sed -n 's/^127\.0\.0\.1://p')
node_two_port=$(docker port "$node_two_relay" 18443/tcp | sed -n 's/^127\.0\.0\.1://p')
[ -n "$central_port" ] && [ -n "$node_one_port" ] && [ -n "$node_two_port" ]
wait_for_node_ready() {
  readiness_hostname=$1
  readiness_port=$2
  readiness_stage=$3
  readiness_path=${4:-readyz}
  readiness_wait_seconds=${5:-}
  if [ -z "$readiness_wait_seconds" ]; then
    readiness_wait_seconds=$default_node_readiness_wait_seconds
    if [ "${PLAINPOST_SYNC_NODE_CLIENT_API:-}" = enabled ]; then
      readiness_wait_seconds=$client_node_readiness_wait_seconds
    fi
  fi
  readiness_started_at=$(date +%s)
  readiness_attempts=0
  for _ in $(seq 1 "$readiness_wait_seconds"); do
    readiness_attempts=$((readiness_attempts + 1))
    if curl --silent --fail --connect-timeout 1 --max-time 2 --noproxy '*' --cacert "$temporary/ca.crt" --connect-to "$readiness_hostname:18443:127.0.0.1:$readiness_port" "https://$readiness_hostname:18443/$readiness_path" >/dev/null 2>>"$runtime_log"; then
      readiness_elapsed_seconds=$(( $(date +%s) - readiness_started_at ))
      printf 'ERROR acceptance-checkpoint node=%s stage=%s readiness=ready readiness_attempts=%s readiness_elapsed_seconds=%s\n' "$readiness_hostname" "$readiness_stage" "$readiness_attempts" "$readiness_elapsed_seconds" >>"$runtime_log"
      return 0
    fi
    sleep 1
  done
  readiness_service='node-one'
  case "$readiness_hostname" in
    node-two.private-beta.ts.net) readiness_service='node-two' ;;
  esac
  readiness_container=$(compose_run ps -q "$readiness_service" 2>>"$runtime_log" || true)
  if [ -n "$readiness_container" ]; then
    printf 'ERROR acceptance-node-state node=%s stage=%s ' "$readiness_hostname" "$readiness_stage" >>"$runtime_log"
    docker inspect --format 'status={{.State.Status}} exit={{.State.ExitCode}} restart={{.RestartCount}}' "$readiness_container" >>"$runtime_log" 2>&1 || true
    printf 'ERROR acceptance-node-log node=%s stage=%s\n' "$readiness_hostname" "$readiness_stage" >>"$runtime_log"
    docker logs --tail 200 "$readiness_container" >>"$runtime_log" 2>&1 || true
  fi
  readiness_response=$(curl --silent --show-error --connect-timeout 1 --max-time 2 --noproxy '*' --cacert "$temporary/ca.crt" --connect-to "$readiness_hostname:18443:127.0.0.1:$readiness_port" --write-out '\nhttp_status=%{http_code}' "https://$readiness_hostname:18443/$readiness_path" 2>>"$runtime_log" || true)
  readiness_response=$(printf '%s' "$readiness_response" | tr '\n' ' ')
  readiness_elapsed_seconds=$(( $(date +%s) - readiness_started_at ))
  readiness_summary=$(printf 'ERROR acceptance-readiness node=%s stage=%s readiness_attempts=%s readiness_elapsed_seconds=%s response=%s' "$readiness_hostname" "$readiness_stage" "$readiness_attempts" "$readiness_elapsed_seconds" "$readiness_response")
  printf '%s\n' "$readiness_summary" >>"$runtime_log"
  printf '%s\n' "$readiness_summary" >&2
  printf '%s readiness timeout stage=%s\n' "$readiness_hostname" "$readiness_stage" >&2
  return 1
}
wait_for_node_one_ready() {
  readiness_stage=$1
  readiness_timeout=${2:-}
  if [ -n "$readiness_timeout" ]; then
    wait_for_node_ready node-one.private-beta.ts.net "$node_one_port" "$readiness_stage" readyz "$readiness_timeout"
  else
    wait_for_node_ready node-one.private-beta.ts.net "$node_one_port" "$readiness_stage"
  fi
}
wait_for_node_one_ready_until_deadline() {
  readiness_stage=$1
  readiness_timeout_seconds=$2
  readiness_started_at_ms=$(acceptance_controller_monotonic_ms)
  readiness_deadline_ms=$((readiness_started_at_ms + readiness_timeout_seconds * 1000))
  readiness_attempts=0
  while [ "$(acceptance_controller_monotonic_ms)" -lt "$readiness_deadline_ms" ]; do
    readiness_attempts=$((readiness_attempts + 1))
    if curl --silent --fail --connect-timeout 1 --max-time 1 --noproxy '*' --cacert "$temporary/ca.crt" --connect-to "node-one.private-beta.ts.net:18443:127.0.0.1:$node_one_port" "https://node-one.private-beta.ts.net:18443/readyz" >/dev/null 2>>"$runtime_log"; then
      printf 'ERROR acceptance-checkpoint node=node-one stage=%s readiness=ready readiness_attempts=%s\n' "$readiness_stage" "$readiness_attempts" >>"$runtime_log"
      return 0
    fi
    remaining_ms=$((readiness_deadline_ms - $(acceptance_controller_monotonic_ms)))
    [ "$remaining_ms" -gt 0 ] || break
    sleep 0.1
  done
  printf 'ERROR acceptance-readiness node=node-one stage=%s readiness_attempts=%s monotonic_deadline=expired\n' "$readiness_stage" "$readiness_attempts" >>"$runtime_log"
  return 1
}
wait_for_node_health() {
  readiness_stage=$1
  wait_for_node_ready node-one.private-beta.ts.net "$node_one_port" "$readiness_stage" healthz
}
wait_for_node_two_ready() {
  readiness_stage=$1
  wait_for_node_ready node-two.private-beta.ts.net "$node_two_port" "$readiness_stage"
}
wait_for_node_two_deleted_503() {
  readiness_stage=$1
  readiness_started_ms=$(acceptance_controller_monotonic_ms)
  readiness_deadline_ms=$((readiness_started_ms + node_two_deletion_readiness_timeout_seconds * 1000))
  readiness_attempts=0
  while [ "$(acceptance_controller_monotonic_ms)" -lt "$readiness_deadline_ms" ]; do
    readiness_attempts=$((readiness_attempts + 1))
    readiness_remaining_ms=$((readiness_deadline_ms - $(acceptance_controller_monotonic_ms)))
    readiness_max_time_seconds=$((readiness_remaining_ms / 1000))
    [ "$readiness_max_time_seconds" -gt 2 ] && readiness_max_time_seconds=2
    [ "$readiness_max_time_seconds" -ge 1 ] || break
    readiness_status=$(curl --silent --show-error --connect-timeout 1 --max-time "$readiness_max_time_seconds" --noproxy '*' \
      --cacert "$temporary/ca.crt" \
      --connect-to "node-two.private-beta.ts.net:18443:127.0.0.1:$node_two_port" \
      --output /dev/null --write-out '%{http_code}' \
      "https://node-two.private-beta.ts.net:18443/readyz" 2>>"$runtime_log" || true)
    if [ "$readiness_status" = 503 ]; then
      readiness_elapsed_seconds=$(( ($(acceptance_controller_monotonic_ms) - readiness_started_ms) / 1000 ))
      printf 'ERROR acceptance-checkpoint node=node-two stage=%s readiness=unavailable http_status=503 readiness_attempts=%s readiness_elapsed_seconds=%s timeout_seconds=%s\n' \
        "$readiness_stage" "$readiness_attempts" "$readiness_elapsed_seconds" "$node_two_deletion_readiness_timeout_seconds" >>"$runtime_log"
      return 0
    fi
    readiness_remaining_ms=$((readiness_deadline_ms - $(acceptance_controller_monotonic_ms)))
    [ "$readiness_remaining_ms" -ge 100 ] || break
    sleep 0.1
  done
  printf 'ERROR acceptance-readiness node=node-two stage=%s readiness=unavailable http_status=%s readiness_attempts=%s timeout_seconds=%s\n' \
    "$readiness_stage" "${readiness_status:-unknown}" "$readiness_attempts" "$node_two_deletion_readiness_timeout_seconds" >>"$runtime_log"
  return 1
}
printf 'stage=private-relays-ready\n'
for endpoint in "node-one.private-beta.ts.net:$node_one_port" "node-two.private-beta.ts.net:$node_two_port"; do
  hostname=${endpoint%:*}
  port=${endpoint##*:}
  for _ in $(seq 1 90); do
    if curl --silent --fail --noproxy '*' --cacert "$temporary/ca.crt" --connect-to "$hostname:18443:127.0.0.1:$port" "https://$hostname:18443/healthz" >/dev/null 2>&1; then break; fi
    sleep 1
  done
  tls13_result="$temporary/${hostname}.tls13"
  tls12_result="$temporary/${hostname}.tls12"
  : >"$tls13_result"; : >"$tls12_result"; chmod 0600 "$tls13_result" "$tls12_result"
  tls13_probe_status=0
  openssl s_client -tls1_3 -verify 5 -verify_return_error -connect "127.0.0.1:$port" -servername "$hostname" -CAfile "$temporary/ca.crt" </dev/null >"$tls13_result" 2>&1 || tls13_probe_status=$?
  if ! sync_node_tls13_probe_succeeded "$tls13_result"; then
    printf 'TLS 1.3 probe did not prove protocol and CA verification for %s (s_client status=%s)\n' "$hostname" "$tls13_probe_status" >&2
    exit 1
  fi
  if openssl s_client -tls1_2 -verify 5 -verify_return_error -connect "127.0.0.1:$port" -servername "$hostname" -CAfile "$temporary/ca.crt" </dev/null >"$tls12_result" 2>&1; then
    if sync_node_tls12_probe_succeeded "$tls12_result"; then
      printf 'Node accepted TLS 1.2\n' >&2
    else
      printf 'TLS 1.2 probe completed without rejection evidence\n' >&2
    fi
    exit 1
  fi
  if sync_node_tls12_probe_succeeded "$tls12_result"; then
    printf 'Node accepted TLS 1.2\n' >&2
    exit 1
  fi
  curl --silent --fail --noproxy '*' --cacert "$temporary/ca.crt" --connect-to "$hostname:18443:127.0.0.1:$port" "https://$hostname:18443/healthz" >/dev/null
done
printf 'stage=node-tls13-only\n'
if [ "$transport_release_images" = 1 ]; then
  # Before activation /readyz is intentionally unavailable. The preceding
  # health and TLS probes prove the started node process; inspect its database
  # schema only after that bounded startup evidence is complete.
  node_two_schema_checkpoint initial-ready || exit 1
fi

printf 'stage=central-admission\n'
printf 'stage=node-activation-session\n'
printf 'stage=swift-client\n'
: >"$temporary/swift.log"
: >"$swift_stage_log"
: >"$swift_stream_diagnostic_log"
chmod 0600 "$temporary/swift.log" "$swift_stage_log" "$swift_stream_diagnostic_log"
test -d "$temporary/control"
node_two_deletion_wait_seconds=150
node_two_deletion_readiness_timeout_seconds=45
if [ "$((node_restart_timeout_seconds + node_two_deletion_readiness_timeout_seconds))" -ge "$node_two_deletion_wait_seconds" ]; then
  printf 'node-two deletion restart and readiness probe exceed Swift deletion waiter\n' >&2
  exit 1
fi
if [ "${PLAINPOST_SYNC_NODE_CLIENT_API:-}" = enabled ]; then
  control_signal_path() {
    case "$2" in
      provider-transition|attachment-release-probe|release-backup-restore|restart-node|restart-imap-fixture|restart-smtp-fixture|mail-postcondition|smtp-matrix-resume|arm-sent-append-failure|smtp-matrix-assert-no-auth|smtp-matrix-assert-authentication-command|restore-smtp-fixture-normal|restore-imap-fixture-normal) ;;
      imap-matrix-resume|imap-matrix-reset-uidvalidity|imap-matrix-assert-authentication|imap-matrix-arm-authentication|imap-matrix-arm-tls-failure|imap-matrix-append-message|imap-matrix-assert-no-idle|imap-matrix-catalog-probe|imap-matrix-fetch-probe|imap-matrix-delayed-literal-probe|imap-matrix-arm-provider-restart) ;;
      *) return 1 ;;
    esac
    case "$3" in
      request|applied|failed) ;;
      *) return 1 ;;
    esac
    printf '%s/%s.%s\n' "$1" "$2" "$3"
  }
  . "$root/Scripts/lib/acceptance-attachment-release-probe.sh"
  . "$root/Scripts/lib/acceptance-mail-postcondition-summary.sh"
  provider_transition_request=$(control_signal_path "$temporary/control" provider-transition request)
  provider_transition_applied=$(control_signal_path "$temporary/control" provider-transition applied)
  provider_transition_failed=$(control_signal_path "$temporary/control" provider-transition failed)
  attachment_release_request=$(control_signal_path "$temporary/control" attachment-release-probe request)
  attachment_release_applied=$(control_signal_path "$temporary/control" attachment-release-probe applied)
  attachment_release_failed=$(control_signal_path "$temporary/control" attachment-release-probe failed)
  release_backup_restore_request=$(control_signal_path "$temporary/control" release-backup-restore request)
  release_backup_restore_applied=$(control_signal_path "$temporary/control" release-backup-restore applied)
  release_backup_restore_failed=$(control_signal_path "$temporary/control" release-backup-restore failed)
  restart_node_request=$(control_signal_path "$temporary/control" restart-node request)
  restart_node_applied=$(control_signal_path "$temporary/control" restart-node applied)
  restart_node_failed=$(control_signal_path "$temporary/control" restart-node failed)
  restart_imap_fixture_request=$(control_signal_path "$temporary/control" restart-imap-fixture request)
  restart_imap_fixture_applied=$(control_signal_path "$temporary/control" restart-imap-fixture applied)
  restart_imap_fixture_failed=$(control_signal_path "$temporary/control" restart-imap-fixture failed)
  restart_smtp_fixture_request=$(control_signal_path "$temporary/control" restart-smtp-fixture request)
  restart_smtp_fixture_applied=$(control_signal_path "$temporary/control" restart-smtp-fixture applied)
  restart_smtp_fixture_failed=$(control_signal_path "$temporary/control" restart-smtp-fixture failed)
  mail_postcondition_request=$(control_signal_path "$temporary/control" mail-postcondition request)
  mail_postcondition_applied=$(control_signal_path "$temporary/control" mail-postcondition applied)
  mail_postcondition_failed=$(control_signal_path "$temporary/control" mail-postcondition failed)
  mail_postcondition_expectation="$temporary/control/mail-postcondition.expectation"
  smtp_matrix_resume_request=$(control_signal_path "$temporary/control" smtp-matrix-resume request)
  smtp_matrix_resume_applied=$(control_signal_path "$temporary/control" smtp-matrix-resume applied)
  smtp_matrix_resume_failed=$(control_signal_path "$temporary/control" smtp-matrix-resume failed)
  imap_matrix_resume_request=$(control_signal_path "$temporary/control" imap-matrix-resume request)
  imap_matrix_resume_applied=$(control_signal_path "$temporary/control" imap-matrix-resume applied)
  imap_matrix_resume_failed=$(control_signal_path "$temporary/control" imap-matrix-resume failed)
  imap_matrix_reset_uidvalidity_request=$(control_signal_path "$temporary/control" imap-matrix-reset-uidvalidity request)
  imap_matrix_reset_uidvalidity_applied=$(control_signal_path "$temporary/control" imap-matrix-reset-uidvalidity applied)
  imap_matrix_reset_uidvalidity_failed=$(control_signal_path "$temporary/control" imap-matrix-reset-uidvalidity failed)
  imap_matrix_assert_authentication_request=$(control_signal_path "$temporary/control" imap-matrix-assert-authentication request)
  imap_matrix_assert_authentication_applied=$(control_signal_path "$temporary/control" imap-matrix-assert-authentication applied)
  imap_matrix_assert_authentication_failed=$(control_signal_path "$temporary/control" imap-matrix-assert-authentication failed)
  imap_matrix_arm_authentication_request=$(control_signal_path "$temporary/control" imap-matrix-arm-authentication request)
  imap_matrix_arm_authentication_applied=$(control_signal_path "$temporary/control" imap-matrix-arm-authentication applied)
  imap_matrix_arm_authentication_failed=$(control_signal_path "$temporary/control" imap-matrix-arm-authentication failed)
  imap_matrix_arm_tls_failure_request=$(control_signal_path "$temporary/control" imap-matrix-arm-tls-failure request)
  imap_matrix_arm_tls_failure_applied=$(control_signal_path "$temporary/control" imap-matrix-arm-tls-failure applied)
  imap_matrix_arm_tls_failure_failed=$(control_signal_path "$temporary/control" imap-matrix-arm-tls-failure failed)
  imap_matrix_append_message_request=$(control_signal_path "$temporary/control" imap-matrix-append-message request)
  imap_matrix_append_message_applied=$(control_signal_path "$temporary/control" imap-matrix-append-message applied)
  imap_matrix_append_message_failed=$(control_signal_path "$temporary/control" imap-matrix-append-message failed)
  imap_matrix_assert_no_idle_request=$(control_signal_path "$temporary/control" imap-matrix-assert-no-idle request)
  imap_matrix_assert_no_idle_applied=$(control_signal_path "$temporary/control" imap-matrix-assert-no-idle applied)
  imap_matrix_assert_no_idle_failed=$(control_signal_path "$temporary/control" imap-matrix-assert-no-idle failed)
  imap_matrix_catalog_probe_request=$(control_signal_path "$temporary/control" imap-matrix-catalog-probe request)
  imap_matrix_catalog_probe_applied=$(control_signal_path "$temporary/control" imap-matrix-catalog-probe applied)
  imap_matrix_catalog_probe_failed=$(control_signal_path "$temporary/control" imap-matrix-catalog-probe failed)
  imap_matrix_fetch_probe_request=$(control_signal_path "$temporary/control" imap-matrix-fetch-probe request)
  imap_matrix_fetch_probe_applied=$(control_signal_path "$temporary/control" imap-matrix-fetch-probe applied)
  imap_matrix_fetch_probe_failed=$(control_signal_path "$temporary/control" imap-matrix-fetch-probe failed)
  imap_matrix_delayed_literal_probe_request=$(control_signal_path "$temporary/control" imap-matrix-delayed-literal-probe request)
  imap_matrix_delayed_literal_probe_applied=$(control_signal_path "$temporary/control" imap-matrix-delayed-literal-probe applied)
  imap_matrix_delayed_literal_probe_failed=$(control_signal_path "$temporary/control" imap-matrix-delayed-literal-probe failed)
  imap_matrix_arm_provider_restart_request=$(control_signal_path "$temporary/control" imap-matrix-arm-provider-restart request)
  imap_matrix_arm_provider_restart_applied=$(control_signal_path "$temporary/control" imap-matrix-arm-provider-restart applied)
  imap_matrix_arm_provider_restart_failed=$(control_signal_path "$temporary/control" imap-matrix-arm-provider-restart failed)
  imap_matrix_arm_provider_restart_result="$temporary/control/imap-matrix-arm-provider-restart.result"
  run_catalog_probe() {
    catalog_probe_expectation=$1
    if [ -n "$transport_release_override" ]; then
      run_controller_child "imap-catalog-probe-$catalog_probe_expectation" "$controller_child_timeout_seconds" env \
        PLAINPOST_PRIVATE_ROOT="$temporary" \
        PLAINPOST_PRIVATE_NODE_IMAGE="$node_image" \
        PLAINPOST_ACCEPTANCE_NODE_UID="$acceptance_node_uid" \
        PLAINPOST_ACCEPTANCE_NODE_GID="$acceptance_node_gid" \
        PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE="$acceptance_attachment_storage" \
        PLAINPOST_ACCEPTANCE_ATTACHMENT_DIR="$acceptance_attachment_dir" \
        PLAINPOST_ACCEPTANCE_DROP_RESPONSES="$acceptance_response_drops" \
        PLAINPOST_ACCEPTANCE_S3_ENDPOINT="$acceptance_s3_endpoint" \
        PLAINPOST_ACCEPTANCE_S3_BUCKET="$acceptance_s3_bucket" \
        PLAINPOST_ACCEPTANCE_S3_REGION="$acceptance_s3_region" \
        PLAINPOST_ACCEPTANCE_S3_ADDRESSING="$acceptance_s3_addressing" \
        PLAINPOST_ACCEPTANCE_S3_ACCESS_KEY_FILE="$acceptance_s3_access_key_file" \
        PLAINPOST_ACCEPTANCE_S3_SECRET_KEY_FILE="$acceptance_s3_secret_key_file" \
        PLAINPOST_RELEASE_CENTRAL_IMAGE="$release_central_image" \
        PLAINPOST_RELEASE_NODE_IMAGE="$release_node_image" \
        docker compose -p "$project" -f "$compose" -f "$transport_release_override" run --rm --no-deps sync-node-acceptance-seed \
        -probe-catalog ${catalog_probe_expectation:+-expect-catalog-error "$catalog_probe_expectation"} \
        -node-database-file /run/secrets/database_url -master-key /run/secrets/master_key
    else
      run_controller_child "imap-catalog-probe-$catalog_probe_expectation" "$controller_child_timeout_seconds" env \
        PLAINPOST_PRIVATE_ROOT="$temporary" \
        PLAINPOST_PRIVATE_NODE_IMAGE="$node_image" \
        PLAINPOST_ACCEPTANCE_NODE_UID="$acceptance_node_uid" \
        PLAINPOST_ACCEPTANCE_NODE_GID="$acceptance_node_gid" \
        PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE="$acceptance_attachment_storage" \
        PLAINPOST_ACCEPTANCE_ATTACHMENT_DIR="$acceptance_attachment_dir" \
        PLAINPOST_ACCEPTANCE_DROP_RESPONSES="$acceptance_response_drops" \
        PLAINPOST_ACCEPTANCE_S3_ENDPOINT="$acceptance_s3_endpoint" \
        PLAINPOST_ACCEPTANCE_S3_BUCKET="$acceptance_s3_bucket" \
        PLAINPOST_ACCEPTANCE_S3_REGION="$acceptance_s3_region" \
        PLAINPOST_ACCEPTANCE_S3_ADDRESSING="$acceptance_s3_addressing" \
        PLAINPOST_ACCEPTANCE_S3_ACCESS_KEY_FILE="$acceptance_s3_access_key_file" \
        PLAINPOST_ACCEPTANCE_S3_SECRET_KEY_FILE="$acceptance_s3_secret_key_file" \
        docker compose -p "$project" -f "$compose" run --rm --no-deps sync-node-acceptance-seed \
        -probe-catalog ${catalog_probe_expectation:+-expect-catalog-error "$catalog_probe_expectation"} \
        -node-database-file /run/secrets/database_url -master-key /run/secrets/master_key
    fi
  }
  run_fetch_probe() {
    fetch_probe_expectation=$1
    if [ -z "$acceptance_imap_fetch_phase" ]; then
      return 1
    fi
    fetch_probe_command='-probe-fetch -fetch-phase '"$acceptance_imap_fetch_phase"
    if [ -n "$fetch_probe_expectation" ]; then
      fetch_probe_command="$fetch_probe_command -expect-fetch-error $fetch_probe_expectation"
    fi
    if [ -n "$transport_release_override" ]; then
      run_controller_child "imap-fetch-probe-$fetch_probe_expectation" "$controller_child_timeout_seconds" env \
        PLAINPOST_PRIVATE_ROOT="$temporary" \
        PLAINPOST_PRIVATE_NODE_IMAGE="$node_image" \
        PLAINPOST_ACCEPTANCE_NODE_UID="$acceptance_node_uid" \
        PLAINPOST_ACCEPTANCE_NODE_GID="$acceptance_node_gid" \
        PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE="$acceptance_attachment_storage" \
        PLAINPOST_ACCEPTANCE_ATTACHMENT_DIR="$acceptance_attachment_dir" \
        PLAINPOST_ACCEPTANCE_DROP_RESPONSES="$acceptance_response_drops" \
        PLAINPOST_ACCEPTANCE_S3_ENDPOINT="$acceptance_s3_endpoint" \
        PLAINPOST_ACCEPTANCE_S3_BUCKET="$acceptance_s3_bucket" \
        PLAINPOST_ACCEPTANCE_S3_REGION="$acceptance_s3_region" \
        PLAINPOST_ACCEPTANCE_S3_ADDRESSING="$acceptance_s3_addressing" \
        PLAINPOST_ACCEPTANCE_S3_ACCESS_KEY_FILE="$acceptance_s3_access_key_file" \
        PLAINPOST_ACCEPTANCE_S3_SECRET_KEY_FILE="$acceptance_s3_secret_key_file" \
        PLAINPOST_RELEASE_CENTRAL_IMAGE="$release_central_image" \
        PLAINPOST_RELEASE_NODE_IMAGE="$release_node_image" \
        docker compose -p "$project" -f "$compose" -f "$transport_release_override" run --rm --no-deps sync-node-acceptance-seed \
        $fetch_probe_command -node-database-file /run/secrets/database_url -master-key /run/secrets/master_key
    else
      run_controller_child "imap-fetch-probe-$fetch_probe_expectation" "$controller_child_timeout_seconds" env \
        PLAINPOST_PRIVATE_ROOT="$temporary" \
        PLAINPOST_PRIVATE_NODE_IMAGE="$node_image" \
        PLAINPOST_ACCEPTANCE_NODE_UID="$acceptance_node_uid" \
        PLAINPOST_ACCEPTANCE_NODE_GID="$acceptance_node_gid" \
        PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE="$acceptance_attachment_storage" \
        PLAINPOST_ACCEPTANCE_ATTACHMENT_DIR="$acceptance_attachment_dir" \
        PLAINPOST_ACCEPTANCE_DROP_RESPONSES="$acceptance_response_drops" \
        PLAINPOST_ACCEPTANCE_S3_ENDPOINT="$acceptance_s3_endpoint" \
        PLAINPOST_ACCEPTANCE_S3_BUCKET="$acceptance_s3_bucket" \
        PLAINPOST_ACCEPTANCE_S3_REGION="$acceptance_s3_region" \
        PLAINPOST_ACCEPTANCE_S3_ADDRESSING="$acceptance_s3_addressing" \
        PLAINPOST_ACCEPTANCE_S3_ACCESS_KEY_FILE="$acceptance_s3_access_key_file" \
        PLAINPOST_ACCEPTANCE_S3_SECRET_KEY_FILE="$acceptance_s3_secret_key_file" \
        docker compose -p "$project" -f "$compose" run --rm --no-deps sync-node-acceptance-seed \
        $fetch_probe_command -node-database-file /run/secrets/database_url -master-key /run/secrets/master_key
    fi
  }
  arm_sent_append_failure_request=$(control_signal_path "$temporary/control" arm-sent-append-failure request)
  arm_sent_append_failure_applied=$(control_signal_path "$temporary/control" arm-sent-append-failure applied)
  arm_sent_append_failure_failed=$(control_signal_path "$temporary/control" arm-sent-append-failure failed)
  smtp_matrix_assert_no_auth_request=$(control_signal_path "$temporary/control" smtp-matrix-assert-no-auth request)
  smtp_matrix_assert_no_auth_applied=$(control_signal_path "$temporary/control" smtp-matrix-assert-no-auth applied)
  smtp_matrix_assert_no_auth_failed=$(control_signal_path "$temporary/control" smtp-matrix-assert-no-auth failed)
  smtp_matrix_assert_authentication_command_request=$(control_signal_path "$temporary/control" smtp-matrix-assert-authentication-command request)
  smtp_matrix_assert_authentication_command_applied=$(control_signal_path "$temporary/control" smtp-matrix-assert-authentication-command applied)
  smtp_matrix_assert_authentication_command_failed=$(control_signal_path "$temporary/control" smtp-matrix-assert-authentication-command failed)
  restore_smtp_fixture_normal_request=$(control_signal_path "$temporary/control" restore-smtp-fixture-normal request)
  restore_smtp_fixture_normal_applied=$(control_signal_path "$temporary/control" restore-smtp-fixture-normal applied)
  restore_smtp_fixture_normal_failed=$(control_signal_path "$temporary/control" restore-smtp-fixture-normal failed)
  restore_imap_fixture_normal_request=$(control_signal_path "$temporary/control" restore-imap-fixture-normal request)
  restore_imap_fixture_normal_applied=$(control_signal_path "$temporary/control" restore-imap-fixture-normal applied)
  restore_imap_fixture_normal_failed=$(control_signal_path "$temporary/control" restore-imap-fixture-normal failed)
  # The phase file is read by node-one through its /node-data bind mount.
  # Replacing it with a host-side rename swaps the directory entry, and the
  # Docker Desktop file sharing layer can keep serving ENOENT for the new name
  # inside the container for seconds (observed: phase_error=missing on the
  # armed status read). Rewrite the existing file in place instead: its inode
  # and directory entry never change, and the small payload is written with a
  # single write while no Node request reads it (arming precedes the client's
  # next request).
  write_response_drop_phase() {
    response_drop_phase_tmp="$temporary/node-one-data/.response-drop-phase.$$"
    printf '%s\n' "$@" >"$response_drop_phase_tmp"
    chmod 0600 "$response_drop_phase_tmp"
    cat "$response_drop_phase_tmp" >"$acceptance_response_drop_phase_file"
    rm -f "$response_drop_phase_tmp"
    chmod 0600 "$acceptance_response_drop_phase_file"
  }
  activate_response_drop_restart_phase() {
    write_response_drop_phase 'phase=restart' 'GET /v1/status=armed'
  }
  arm_initial_response_drops() {
    if [ "$acceptance_mail_scenario" = imap-node-restart-before-ack ]; then
      write_response_drop_phase 'phase=initial' 'GET /v1/status=armed' 'POST /v1/mutations=armed'
    else
      write_response_drop_phase 'phase=initial' 'GET /v1/status=armed'
    fi
  }
  client_control_loop() {
    trap 'controller_interrupted 129' HUP
    trap 'controller_interrupted 130' INT
    trap 'controller_interrupted 143' TERM
    while :; do
      if [ -e "$provider_transition_request" ]; then
        rm -f "$provider_transition_request"
        # Each request gets a fresh terminal signal. Retaining the previous
        # applied marker would let Swift consume stale success before this
        # transition has run.
        rm -f "$provider_transition_applied" "$provider_transition_failed"
        if ! fixture_transition_before=$(mail_control status 2>>"$runtime_log"); then
          printf 'ERROR acceptance-provider-transition outcome=authority-status-unavailable\n' >>"$runtime_log"
          fixture_transition_before='unavailable'
        fi
        printf 'ERROR acceptance-provider-transition authoritative_before=%s\n' "$fixture_transition_before" >>"$runtime_log"
        provider_transition_container=$(compose_run ps -q imap-fixture 2>/dev/null || true)
        provider_transition_container=${provider_transition_container:-unavailable}
        if run_controller_child provider-transition "$controller_child_timeout_seconds" \
          "$provider_transition_helper" "$temporary/mail-fixture/plainpost_acceptance_mail_fixture.py" "$temporary/mail-state" "$provider_transition_attempts" "$provider_transition_retry_delay_seconds" "$provider_transition_container" poststart; then
          if ! fixture_transition_after=$(mail_control status 2>>"$runtime_log"); then
            fixture_transition_after='unavailable'
          fi
          printf 'ERROR acceptance-provider-transition outcome=applied authoritative_after=%s\n' "$fixture_transition_after" >>"$runtime_log"
          docker exec "$node_one_database_container" psql -U "$node_database_inspection_role" -d "$node_one_database_name" -Atc \
            "SELECT 'ERROR acceptance-provider-transition checkpoint mailbox=' || provider_mailbox_id || ' cursor_present=' || (cursor <> '')::text || ' projection_revision=' || projection_revision::text || ' baseline=' || COALESCE(baseline_state, 'unknown') FROM node_provider_mailboxes ORDER BY provider_mailbox_id; SELECT 'ERROR acceptance-provider-transition projection_head=' || COALESCE(string_agg(revision::text, ',' ORDER BY account_id), 'none') FROM node_projection_heads;" \
            >>"$runtime_log" 2>&1 || true
        else
          printf 'ERROR acceptance-provider-transition outcome=failed fixture_transition_after=unavailable fixture_transition_after_size=unavailable\n' >>"$runtime_log"
        fi
      fi
      if [ -e "$attachment_release_request" ]; then
        acceptance_attachment_release_probe "$temporary/control" "$attachment_release_request" "$attachment_release_applied" "$attachment_release_failed" "$runtime_log"
      fi
      if [ -e "$release_backup_restore_request" ]; then
        rm -f "$release_backup_restore_request" "$release_backup_restore_applied" "$release_backup_restore_failed" || release_backup_restore_status=1
        release_backup_restore_status=1
        release_backup_restore_action_status=1
        if run_release_backup_restore; then
          release_backup_restore_post_child_step reference-validation begin || true
          release_restore_reference="$temporary/node-one-data/restore-references/database"
          release_restore_database=''
          release_restore_database=$(acceptance_active_database_name "$release_restore_reference" '' "$(dirname "$release_restore_reference")" required 2>/dev/null || true)
          if printf '%s\n' "$release_restore_database" | grep -Eq '^restore_[0-9a-f]{32}$'; then
            release_backup_restore_post_child_step reference-validation passed || true
            release_original_database_quarantined=0
            release_quarantine_state=''
            release_backup_restore_post_child_step quarantine begin || true
            if release_backup_restore_remaining_seconds; then
              release_quarantine_output="$temporary/release-quarantine-output"
              release_quarantine_status=0
              if ! : >"$release_quarantine_output" || ! chmod 0600 "$release_quarantine_output"; then
                release_quarantine_status=1
              else
                acceptance_controller_run "$temporary/control" release-backup-restore-database-quarantine "$release_backup_restore_remaining" \
                  docker exec "$node_one_database_container" psql -U plainpost_restore_admin -d postgres -Atc \
                  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='plainpost_sync_node' AND pid <> pg_backend_pid(); ALTER DATABASE plainpost_sync_node WITH ALLOW_CONNECTIONS false; SELECT CASE WHEN NOT datallowconn THEN 'quarantine-complete' ELSE 'quarantine-incomplete' END FROM pg_database WHERE datname='plainpost_sync_node'" \
                  >"$release_quarantine_output" 2>>"$runtime_log" || release_quarantine_status=$?
              fi
              # acceptance_controller_run writes its terminal status to the
              # same stdout stream as the child. Select only the exact SQL
              # sentinel so a successful controller status line cannot mask
              # the database quarantine result.
              release_quarantine_state=$(grep -Ex 'quarantine-complete' "$release_quarantine_output" | tail -n 1 2>/dev/null || true)
              [ "$release_quarantine_status" -eq 0 ] || release_quarantine_state=''
            else
              printf 'ERROR release-backup-restore action-deadline-exceeded step=database-quarantine\n' >>"$runtime_log"
            fi
            if [ "$(printf '%s\n' "$release_quarantine_state" | tail -n 1)" = quarantine-complete ]; then
              release_backup_restore_post_child_step quarantine passed || true
              release_original_database_quarantined=1
              node_one_database_name=$release_restore_database
              printf 'release-backup-restore original-database-quarantined=1\n' >>"$runtime_log"
              release_backup_restore_post_child_step attachment-quarantine begin || true
              release_original_attachments="$temporary/node-one-data/attachments-original"
              release_attachments_mode=''
              release_attachments_uid=''
              release_attachments_gid=''
              if ! release_attachments_mode=$(stat -f '%Lp' "$temporary/node-one-data/attachments" 2>/dev/null || stat -c '%a' "$temporary/node-one-data/attachments") ||
                 ! release_attachments_uid=$(stat -f '%u' "$temporary/node-one-data/attachments" 2>/dev/null || stat -c '%u' "$temporary/node-one-data/attachments") ||
                 ! release_attachments_gid=$(stat -f '%g' "$temporary/node-one-data/attachments" 2>/dev/null || stat -c '%g' "$temporary/node-one-data/attachments"); then
                release_original_database_quarantined=0
                release_backup_restore_post_child_step attachment-quarantine failed || true
              elif [ ! -e "$release_original_attachments" ] && mv "$temporary/node-one-data/attachments" "$release_original_attachments" &&
                   mkdir "$temporary/node-one-data/attachments" && chmod "$release_attachments_mode" "$temporary/node-one-data/attachments" &&
                   chown "$release_attachments_uid:$release_attachments_gid" "$temporary/node-one-data/attachments"; then
                printf 'release-backup-restore original-attachments-quarantined=1\n' >>"$runtime_log"
                release_backup_restore_post_child_step attachment-quarantine passed || true
              else
                release_original_database_quarantined=0
                release_backup_restore_post_child_step attachment-quarantine failed || true
              fi
            else
              release_backup_restore_post_child_step quarantine failed || true
            fi
            release_backup_restore_post_child_step audit-secret-promotion begin || true
            release_audit_database_url="$temporary/node-one-secrets/audit_database_url"
            release_audit_database_url_pending="$release_audit_database_url.pending"
            if [ "$release_original_database_quarantined" -eq 1 ] && [ -n "$release_node_db_password" ]; then
              if ! printf 'postgres://plainpost_sync_node:%s@postgres:5432/%s?sslmode=verify-full&sslrootcert=/run/plainpost-public/postgres-ca.pem\n' \
                "$release_node_db_password" "$release_restore_database" >"$release_audit_database_url_pending"; then
                release_original_database_quarantined=0
                release_backup_restore_status=1
              fi
            elif [ "$release_original_database_quarantined" -eq 1 ]; then
              if ! printf 'postgres://plainpost_sync_node@postgres:5432/%s?sslmode=verify-full&sslrootcert=/run/plainpost-public/postgres-ca.pem\n' \
                "$release_restore_database" >"$release_audit_database_url_pending"; then
                release_original_database_quarantined=0
                release_backup_restore_status=1
              fi
            fi
            if [ "$release_original_database_quarantined" -eq 1 ]; then
              if ! chmod 0600 "$release_audit_database_url_pending" ||
                 ! bash "$secret_ownership_helper" "$temporary" "$postgres_ownership_image" private-release-audit "$secret_ownership_validation_mode"; then
                release_original_database_quarantined=0
                release_backup_restore_status=1
              fi
            fi
            if [ "$release_original_database_quarantined" -eq 1 ]; then
              release_backup_restore_post_child_step audit-secret-promotion passed || true
            else
              release_backup_restore_post_child_step audit-secret-promotion failed || true
            fi
            release_backup_restore_wait_seconds=$release_backup_restore_readiness_timeout_seconds
            release_backup_restore_node_start_wait_seconds=$release_backup_restore_node_start_timeout_seconds
            release_backup_restore_budget_available=0
            if release_backup_restore_remaining_seconds; then
              release_backup_restore_budget_available=1
              if [ "$release_backup_restore_remaining" -lt "$release_backup_restore_node_start_wait_seconds" ]; then
                release_backup_restore_node_start_wait_seconds=$release_backup_restore_remaining
              fi
            else
              printf 'ERROR release-backup-restore action-deadline-exceeded step=node-start\n' >>"$runtime_log"
            fi
            release_backup_restore_post_child_step node-start begin || true
            release_backup_restore_node_start_status=failed
            if [ "$release_original_database_quarantined" -eq 1 ] &&
               [ "$release_backup_restore_budget_available" -eq 1 ] &&
               acceptance_controller_run "$temporary/control" release-backup-restore-node-start "$release_backup_restore_node_start_wait_seconds" \
               env PLAINPOST_PRIVATE_ROOT="$temporary" \
               PLAINPOST_PRIVATE_NODE_IMAGE="$node_image" \
               PLAINPOST_ACCEPTANCE_NODE_UID="$acceptance_node_uid" \
               PLAINPOST_ACCEPTANCE_NODE_GID="$acceptance_node_gid" \
               PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE="$acceptance_attachment_storage" \
               PLAINPOST_ACCEPTANCE_ATTACHMENT_DIR="$acceptance_attachment_dir" \
               PLAINPOST_ACCEPTANCE_DROP_RESPONSES="$acceptance_response_drops" \
               PLAINPOST_ACCEPTANCE_S3_ENDPOINT="$acceptance_s3_endpoint" \
               PLAINPOST_ACCEPTANCE_S3_BUCKET="$acceptance_s3_bucket" \
               PLAINPOST_ACCEPTANCE_S3_REGION="$acceptance_s3_region" \
               PLAINPOST_ACCEPTANCE_S3_ADDRESSING="$acceptance_s3_addressing" \
               PLAINPOST_ACCEPTANCE_S3_ACCESS_KEY_FILE="$acceptance_s3_access_key_file" \
               PLAINPOST_ACCEPTANCE_S3_SECRET_KEY_FILE="$acceptance_s3_secret_key_file" \
               PLAINPOST_RELEASE_CENTRAL_IMAGE="$release_central_image" \
               PLAINPOST_RELEASE_NODE_IMAGE="$release_node_image" \
               docker compose -p "$project" -f "$compose" -f "$transport_release_override" start node-one >>"$runtime_log" 2>&1; then
              release_backup_restore_node_start_status=passed
              release_backup_restore_budget_available=0
              if release_backup_restore_remaining_seconds; then
              release_backup_restore_budget_available=1
                release_backup_restore_wait_seconds=$((release_backup_restore_remaining_ms / 1000))
                if [ "$release_backup_restore_wait_seconds" -gt "$release_backup_restore_readiness_timeout_seconds" ]; then
                  release_backup_restore_wait_seconds=$release_backup_restore_readiness_timeout_seconds
                fi
                if [ "$release_backup_restore_wait_seconds" -le 0 ]; then
                  release_backup_restore_budget_available=0
                fi
              else
                printf 'ERROR release-backup-restore action-deadline-exceeded step=readiness\n' >>"$runtime_log"
              fi
            fi
            release_backup_restore_post_child_step node-start "$release_backup_restore_node_start_status" || true
            release_backup_restore_post_child_step readiness begin || true
            release_backup_restore_readiness_status=failed
            if [ "$release_original_database_quarantined" -eq 1 ] &&
               [ "$release_backup_restore_budget_available" -eq 1 ] &&
               wait_for_node_one_ready_until_deadline release-backup-restore "$release_backup_restore_wait_seconds"; then
              release_backup_restore_readiness_status=passed
              release_backup_restore_status=0
              printf 'release-backup-restore database-reference-validated=1\n' >>"$runtime_log"
            fi
            release_backup_restore_post_child_step readiness "$release_backup_restore_readiness_status" || true
          else
            release_backup_restore_post_child_step reference-validation failed || true
          fi
        fi
        release_backup_restore_post_child_step marker-publish begin || true
        if [ "$release_backup_restore_status" -eq 0 ] &&
           publish_release_backup_restore_marker "$release_backup_restore_applied" "$release_backup_restore_failed" applied; then
          release_backup_restore_post_child_step marker-publish passed || true
          release_backup_restore_action_status=0
        else
          release_backup_restore_status=1
          release_backup_restore_action_status=1
          publish_release_backup_restore_marker "$release_backup_restore_failed" "$release_backup_restore_applied" backup-restore || release_backup_restore_action_status=1
          release_backup_restore_post_child_step marker-publish failed || true
        fi
      fi
      if [ -e "$restart_node_request" ]; then
        rm -f "$restart_node_request"
        rm -f "$restart_node_applied" "$restart_node_failed"
        terminal_restart_action=restart-node
        case "$acceptance_mail_scenario" in
          imap-authentication|imap-untrusted-certificate|imap-same-ca-wrong-host|imap-tls1.1)
            terminal_restart_action=imap-terminal-fault-restart-node
            ;;
          *)
            ;;
        esac
        rm -f "$temporary/control/$terminal_restart_action.applied" "$temporary/control/$terminal_restart_action.failed"
        if [ "$acceptance_mail_scenario" != imap-authentication ] &&
           [ "$acceptance_mail_scenario" != imap-untrusted-certificate ] &&
           [ "$acceptance_mail_scenario" != imap-same-ca-wrong-host ] &&
           [ "$acceptance_mail_scenario" != imap-tls1.1 ] &&
           [ "$acceptance_mail_scenario" != imap-node-restart-before-ack ]; then
          activate_response_drop_restart_phase
        fi
        restart_mode=readiness
        restart_node_status=0
        run_controller_child "$terminal_restart_action" "$node_restart_timeout_seconds" env \
          "$root/Scripts/lib/acceptance-node-restart.sh" \
          "$compose" "$project" "$temporary" node-one "$node_image" \
          "$acceptance_node_uid" "$acceptance_node_gid" "$acceptance_attachment_storage" \
          "$acceptance_attachment_dir" "$acceptance_response_drops" "$acceptance_s3_endpoint" \
          "$acceptance_s3_bucket" "$acceptance_s3_region" "$acceptance_s3_addressing" \
          "$acceptance_s3_access_key_file" "$acceptance_s3_secret_key_file" \
          node-one.private-beta.ts.net "$node_one_port" "$restart_mode" || restart_node_status=$?
        if [ "$acceptance_mail_scenario" = imap-authentication ]; then
          if [ "$restart_node_status" -eq 0 ]; then
            printf 'ERROR acceptance-imap-authentication-startup-fault outcome=unexpected-success\n' >>"$runtime_log"
            : >"$restart_node_failed"
            chmod 0600 "$restart_node_failed"
          elif assert_expected_imap_authentication_startup_fault; then
            rm -f "$restart_node_failed"
            : >"$restart_node_applied"
            chmod 0600 "$restart_node_applied"
          else
            rm -f "$restart_node_applied"
            : >"$restart_node_failed"
            chmod 0600 "$restart_node_failed"
          fi
        elif [ "$acceptance_mail_scenario" = imap-untrusted-certificate ] ||
             [ "$acceptance_mail_scenario" = imap-same-ca-wrong-host ] ||
             [ "$acceptance_mail_scenario" = imap-tls1.1 ]; then
          if [ "$restart_node_status" -eq 0 ]; then
            printf 'ERROR acceptance-imap-tls-startup-fault outcome=unexpected-success\n' >>"$runtime_log"
            : >"$restart_node_failed"
            chmod 0600 "$restart_node_failed"
          elif assert_expected_imap_tls_startup_fault; then
            rm -f "$restart_node_failed"
            : >"$restart_node_applied"
            chmod 0600 "$restart_node_applied"
          else
            rm -f "$restart_node_applied"
            : >"$restart_node_failed"
            chmod 0600 "$restart_node_failed"
          fi
        elif [ -e "$restart_node_applied" ]; then
          # The bounded child already probes /readyz; retain the production
          # readiness assertion before the Swift waiter observes completion.
          wait_for_node_one_ready control-restart || true
        fi
        case "$acceptance_mail_scenario" in
          imap-authentication|imap-untrusted-certificate|imap-same-ca-wrong-host|imap-tls1.1)
            rm -f "$temporary/control/$terminal_restart_action.applied" "$temporary/control/$terminal_restart_action.failed"
            ;;
          *)
            ;;
        esac
      fi
      if [ -e "$imap_matrix_arm_authentication_request" ]; then
        rm -f "$imap_matrix_arm_authentication_request" "$imap_matrix_arm_authentication_applied" "$imap_matrix_arm_authentication_failed"
        imap_authentication_expected_after=''
        imap_authentication_count_baseline=$(mail_python -c 'from plainpost_acceptance_mail_state import read; print(next((item["count"] for item in read()["phase_counters"] if item["protocol"] == "imap" and item["phase"] == "authentication"), 0))' 2>>"$runtime_log" || true)
        if is_nonnegative_integer "$imap_authentication_count_baseline"; then
          imap_authentication_expected_after=$((imap_authentication_count_baseline + 1))
        fi
        imap_authentication_projection_baseline=$(docker exec "$node_one_database_container" psql -U "$node_database_inspection_role" -d "$node_one_database_name" -Atc \
          "SELECT COALESCE(string_agg(revision::text,',' ORDER BY revision),'none') || ':' || count(*)::text || ':' || count(DISTINCT message_id)::text FROM node_projection_changes" 2>>"$runtime_log" || true)
        if [ -n "$imap_authentication_projection_baseline" ] &&
           [ -n "$imap_authentication_expected_after" ] &&
           [ "$acceptance_mail_scenario" = imap-authentication ] &&
           mail_control arm-fault imap-authentication 1 rejected >>"$runtime_log" 2>&1; then
          printf 'ERROR acceptance-imap-authentication-projection-baseline outcome=captured\n' >>"$runtime_log"
          printf 'ERROR acceptance-imap-authentication-arm outcome=expected\n' >>"$runtime_log"
          : >"$imap_matrix_arm_authentication_applied"
          chmod 0600 "$imap_matrix_arm_authentication_applied"
        else
          printf 'ERROR acceptance-imap-authentication-arm outcome=failed\n' >>"$runtime_log"
          : >"$imap_matrix_arm_authentication_failed"
          chmod 0600 "$imap_matrix_arm_authentication_failed"
        fi
      fi
      if [ -e "$imap_matrix_arm_tls_failure_request" ]; then
        rm -f "$imap_matrix_arm_tls_failure_request" "$imap_matrix_arm_tls_failure_applied" "$imap_matrix_arm_tls_failure_failed"
        imap_tls_projection_baseline=''
        imap_tls_authentication_count_baseline=''
        imap_tls_handshake_count_baseline=''
        if run_controller_child imap-tls-stop-node-one "$controller_child_timeout_seconds" docker stop -t 1 "$node_one_container" >/dev/null 2>>"$runtime_log"; then
          imap_tls_authentication_count_baseline=$(mail_python -c 'from plainpost_acceptance_mail_state import read; print(next((item["count"] for item in read()["phase_counters"] if item["protocol"] == "imap" and item["phase"] == "authentication"), 0))' 2>>"$runtime_log" || true)
          imap_tls_handshake_count_baseline=$(mail_python -c 'from plainpost_acceptance_mail_state import read; print(sum(1 for item in read()["observations"] if item["kind"] == "test-observation" and item["protocol"] == "imap" and item["phase"] == "tls-handshake"))' 2>>"$runtime_log" || true)
          imap_tls_projection_baseline=$(docker exec "$node_one_database_container" psql -U "$node_database_inspection_role" -d "$node_one_database_name" -Atc \
            "SELECT COALESCE(string_agg(revision::text,',' ORDER BY revision),'none') || ':' || count(*)::text || ':' || count(DISTINCT message_id)::text FROM node_projection_changes" 2>>"$runtime_log" || true)
          if is_nonnegative_integer "$imap_tls_authentication_count_baseline" &&
             is_nonnegative_integer "$imap_tls_handshake_count_baseline" &&
             [ -n "$imap_tls_projection_baseline" ] &&
             PLAINPOST_ACCEPTANCE_IMAP_TLS_MODE="$acceptance_imap_tls_terminal_mode" export PLAINPOST_ACCEPTANCE_IMAP_TLS_MODE &&
             compose_run up -d --no-deps --force-recreate imap-fixture >>"$runtime_log" 2>&1; then
            tls_mode_container=$(compose_run ps -q imap-fixture)
            tls_mode_health=starting
            for _ in $(seq 1 60); do
              tls_mode_health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}starting{{end}}' "$tls_mode_container" 2>/dev/null || true)
              [ "$tls_mode_health" = healthy ] && break
              sleep 1
            done
          fi
        fi
        if [ -n "$imap_tls_projection_baseline" ] &&
           [ -n "$imap_tls_authentication_count_baseline" ]; then
          printf 'ERROR acceptance-imap-tls-arm outcome=expected mode=%s\n' "$acceptance_imap_tls_terminal_mode" >>"$runtime_log"
          : >"$imap_matrix_arm_tls_failure_applied"
          chmod 0600 "$imap_matrix_arm_tls_failure_applied"
        else
          printf 'ERROR acceptance-imap-tls-arm outcome=failed\n' >>"$runtime_log"
          : >"$imap_matrix_arm_tls_failure_failed"
          chmod 0600 "$imap_matrix_arm_tls_failure_failed"
        fi
      fi
      if [ -e "$imap_matrix_arm_provider_restart_request" ]; then
        rm -f "$imap_matrix_arm_provider_restart_request" "$imap_matrix_arm_provider_restart_applied" "$imap_matrix_arm_provider_restart_failed" "$imap_matrix_arm_provider_restart_result"
        provider_restart_arm_status=0
        provider_restart_header_count_before=$(mail_python -c 'from plainpost_acceptance_mail_state import read; print(next((item["count"] for item in read()["phase_counters"] if item["protocol"] == "imap" and item["phase"] == "header-fetch"), 0))' 2>>"$runtime_log" || true)
        if [ "$acceptance_mail_scenario" != imap-provider-restart-mid-page ] || ! is_nonnegative_integer "$provider_restart_header_count_before"; then
          provider_restart_arm_status=1
        else
          provider_restart_header_occurrence=$((provider_restart_header_count_before + 1))
          if ! mail_control phase imap header-fetch "$provider_restart_header_occurrence" pause >>"$runtime_log" 2>&1; then
            provider_restart_arm_status=1
          else
            imap_matrix_phase=header-fetch
            printf '%s\n' "$provider_restart_header_occurrence" >"$imap_matrix_arm_provider_restart_result"
            chmod 0600 "$imap_matrix_arm_provider_restart_result"
          fi
        fi
        if [ "$provider_restart_arm_status" -eq 0 ]; then
          printf 'ERROR acceptance-imap-provider-restart-arm outcome=applied phase=header-fetch\n' >>"$runtime_log"
          : >"$imap_matrix_arm_provider_restart_applied"
          chmod 0600 "$imap_matrix_arm_provider_restart_applied"
        else
          printf 'ERROR acceptance-imap-provider-restart-arm outcome=failed\n' >>"$runtime_log"
          : >"$imap_matrix_arm_provider_restart_failed"
          chmod 0600 "$imap_matrix_arm_provider_restart_failed"
        fi
      fi
      if [ -e "$imap_matrix_catalog_probe_request" ]; then
        rm -f "$imap_matrix_catalog_probe_request" "$imap_matrix_catalog_probe_applied" "$imap_matrix_catalog_probe_failed"
        catalog_projection_before=$(docker exec "$node_one_database_container" psql -U "$node_database_inspection_role" -d "$node_one_database_name" -Atc \
          "SELECT COALESCE(string_agg(revision::text,',' ORDER BY revision),'none') || ':' || count(*)::text || ':' || count(DISTINCT message_id)::text FROM node_projection_changes" 2>>"$runtime_log" || true)
        catalog_probe_status=0
        catalog_probe_failed_step=arm
        if [ "$acceptance_mail_scenario" != imap-catalog ]; then
          catalog_probe_status=1
        elif ! mail_control arm-fault imap-catalog 1 disconnect >>"$runtime_log" 2>&1; then
          catalog_probe_status=1
        else
          catalog_probe_failed_step=expected-unavailable
          if ! run_catalog_probe unavailable; then
            catalog_probe_status=1
          fi
        fi
        if [ "$catalog_probe_status" -eq 0 ]; then
          catalog_probe_failed_step=recovery
          if ! run_catalog_probe ''; then
            catalog_probe_status=1
          fi
        fi
        catalog_projection_after=$(docker exec "$node_one_database_container" psql -U "$node_database_inspection_role" -d "$node_one_database_name" -Atc \
          "SELECT COALESCE(string_agg(revision::text,',' ORDER BY revision),'none') || ':' || count(*)::text || ':' || count(DISTINCT message_id)::text FROM node_projection_changes" 2>>"$runtime_log" || true)
        if [ "$catalog_probe_status" -eq 0 ]; then
          catalog_probe_failed_step=projection
        fi
        if [ "$catalog_probe_status" -eq 0 ] && [ -n "$catalog_projection_before" ] &&
           [ "$catalog_projection_before" = "$catalog_projection_after" ]; then
          printf 'ERROR acceptance-imap-catalog-probe outcome=applied fault=unavailable recovery=six-mailboxes projection=unchanged\n' >>"$runtime_log"
          : >"$imap_matrix_catalog_probe_applied"
          chmod 0600 "$imap_matrix_catalog_probe_applied"
        else
          printf 'ERROR acceptance-imap-catalog-probe outcome=failed step=%s\n' "$catalog_probe_failed_step" >>"$runtime_log"
          : >"$imap_matrix_catalog_probe_failed"
          chmod 0600 "$imap_matrix_catalog_probe_failed"
        fi
      fi
      if [ -e "$imap_matrix_fetch_probe_request" ]; then
        rm -f "$imap_matrix_fetch_probe_request" "$imap_matrix_fetch_probe_applied" "$imap_matrix_fetch_probe_failed"
        imap_fetch_probe_projection_before=$(docker exec "$node_one_database_container" psql -U "$node_database_inspection_role" -d "$node_one_database_name" -Atc \
          "SELECT COALESCE(string_agg(revision::text,',' ORDER BY revision),'none') || ':' || count(*)::text || ':' || count(DISTINCT message_id)::text FROM node_projection_changes" 2>>"$runtime_log" || true)
        fetch_probe_status=0
        fetch_probe_failed_step=arm
        if [ "$acceptance_mail_scenario" != imap-header-fetch ] &&
           [ "$acceptance_mail_scenario" != imap-body-fetch ]; then
          fetch_probe_status=1
        elif ! mail_control arm-fault "imap-$acceptance_imap_fetch_phase" 1 disconnect >>"$runtime_log" 2>&1; then
          fetch_probe_status=1
        else
          fetch_probe_failed_step=expected-unavailable
          if ! run_fetch_probe unavailable; then
            fetch_probe_status=1
          fi
        fi
        if [ "$fetch_probe_status" -eq 0 ]; then
          fetch_probe_failed_step=recovery
          if ! run_fetch_probe ''; then
            fetch_probe_status=1
          fi
        fi
        fetch_probe_projection_after=$(docker exec "$node_one_database_container" psql -U "$node_database_inspection_role" -d "$node_one_database_name" -Atc \
          "SELECT COALESCE(string_agg(revision::text,',' ORDER BY revision),'none') || ':' || count(*)::text || ':' || count(DISTINCT message_id)::text FROM node_projection_changes" 2>>"$runtime_log" || true)
        if [ "$fetch_probe_status" -eq 0 ] && [ -n "$imap_fetch_probe_projection_before" ] &&
           [ "$imap_fetch_probe_projection_before" = "$fetch_probe_projection_after" ]; then
          printf 'ERROR acceptance-imap-fetch-probe outcome=applied fault=disconnect recovery=two-message projection=unchanged\n' >>"$runtime_log"
          : >"$imap_matrix_fetch_probe_applied"
          chmod 0600 "$imap_matrix_fetch_probe_applied"
        else
          printf 'ERROR acceptance-imap-fetch-probe outcome=failed step=%s\n' "$fetch_probe_failed_step" >>"$runtime_log"
          : >"$imap_matrix_fetch_probe_failed"
          chmod 0600 "$imap_matrix_fetch_probe_failed"
        fi
      fi
      if [ -e "$imap_matrix_delayed_literal_probe_request" ]; then
        rm -f "$imap_matrix_delayed_literal_probe_request" "$imap_matrix_delayed_literal_probe_applied" "$imap_matrix_delayed_literal_probe_failed"
        delayed_literal_probe_status=0
        delayed_literal_probe_failed_step=arm
        delayed_literal_projection_before=$(docker exec "$node_one_database_container" psql -U "$node_database_inspection_role" -d "$node_one_database_name" -Atc \
          "SELECT COALESCE(string_agg(revision::text,',' ORDER BY revision),'none') || ':' || count(*)::text || ':' || count(DISTINCT message_id)::text FROM node_projection_changes" 2>>"$runtime_log" || true)
        delayed_literal_header_count_before=$(mail_python -c 'from plainpost_acceptance_mail_state import read; print(next((item["count"] for item in read()["phase_counters"] if item["protocol"] == "imap" and item["phase"] == "header-fetch"), 0))' 2>>"$runtime_log" || true)
        if [ "$acceptance_mail_scenario" != imap-delayed-literal ] || ! is_nonnegative_integer "$delayed_literal_header_count_before"; then
          delayed_literal_probe_status=1
        else
          delayed_literal_header_occurrence=$((delayed_literal_header_count_before + 1))
          if ! mail_control phase imap header-fetch "$delayed_literal_header_occurrence" delay --delay-ms 1000 >>"$runtime_log" 2>&1; then
            delayed_literal_probe_status=1
          else
            delayed_literal_probe_failed_step=probe
            if ! run_fetch_probe ''; then
              delayed_literal_probe_status=1
            else
              delayed_literal_probe_failed_step=phase
            fi
          fi
        fi
        delayed_literal_header_count_after=$(mail_python -c 'from plainpost_acceptance_mail_state import read; print(next((item["count"] for item in read()["phase_counters"] if item["protocol"] == "imap" and item["phase"] == "header-fetch"), 0))' 2>>"$runtime_log" || true)
        delayed_literal_projection_after=$(docker exec "$node_one_database_container" psql -U "$node_database_inspection_role" -d "$node_one_database_name" -Atc \
          "SELECT COALESCE(string_agg(revision::text,',' ORDER BY revision),'none') || ':' || count(*)::text || ':' || count(DISTINCT message_id)::text FROM node_projection_changes" 2>>"$runtime_log" || true)
        if [ "$delayed_literal_probe_status" -eq 0 ] && is_nonnegative_integer "$delayed_literal_header_count_after" &&
           [ "$delayed_literal_header_count_after" -eq $((delayed_literal_header_count_before + 1)) ]; then
          delayed_literal_probe_failed_step=projection
          if [ -n "$delayed_literal_projection_before" ] && [ "$delayed_literal_projection_before" = "$delayed_literal_projection_after" ]; then
            delayed_literal_probe_status=0
          else
            delayed_literal_probe_status=1
          fi
        fi
        if [ "$delayed_literal_probe_status" -eq 0 ]; then
          printf 'ERROR acceptance-imap-delayed-literal-probe outcome=applied phase=header-fetch action=delay recovery=two-message projection=unchanged\n' >>"$runtime_log"
          : >"$imap_matrix_delayed_literal_probe_applied"
          chmod 0600 "$imap_matrix_delayed_literal_probe_applied"
        else
          printf 'ERROR acceptance-imap-delayed-literal-probe outcome=failed step=%s\n' "$delayed_literal_probe_failed_step" >>"$runtime_log"
          : >"$imap_matrix_delayed_literal_probe_failed"
          chmod 0600 "$imap_matrix_delayed_literal_probe_failed"
        fi
      fi
      if [ -e "$smtp_matrix_resume_request" ]; then
        rm -f "$smtp_matrix_resume_request" "$smtp_matrix_resume_applied" "$smtp_matrix_resume_failed"
        smtp_matrix_release_phase=''
        smtp_matrix_release_protocol=smtp
        case "$acceptance_mail_scenario" in
          smtp-cancel-before-data) smtp_matrix_release_phase=before-data ;;
          smtp-cancel-after-data) smtp_matrix_release_phase=acceptance-before-append ;;
          smtp-provider-restart-after-acceptance) smtp_matrix_release_phase=sent-append; smtp_matrix_release_protocol=imap ;;
          smtp-sent-append-failure) smtp_matrix_release_phase=sent-append; smtp_matrix_release_protocol=imap ;;
          *) : ;;
        esac
        if [ -n "$smtp_matrix_release_phase" ] && mail_control phase "$smtp_matrix_release_protocol" "$smtp_matrix_release_phase" 1 resume >>"$runtime_log" 2>&1; then
          : >"$smtp_matrix_resume_applied"
          chmod 0600 "$smtp_matrix_resume_applied"
        else
          : >"$smtp_matrix_resume_failed"
          chmod 0600 "$smtp_matrix_resume_failed"
        fi
      fi
      if [ -e "$imap_matrix_resume_request" ]; then
        rm -f "$imap_matrix_resume_request" "$imap_matrix_resume_applied" "$imap_matrix_resume_failed"
        imap_matrix_resume_occurrence=1
        if [ "$acceptance_mail_scenario" = imap-provider-restart-mid-page ] && is_nonnegative_integer "$provider_restart_header_occurrence"; then
          imap_matrix_resume_occurrence=$provider_restart_header_occurrence
        fi
        if [ "$imap_matrix_phase" != none ] && mail_control phase "$imap_matrix_protocol" "$imap_matrix_phase" "$imap_matrix_resume_occurrence" resume >>"$runtime_log" 2>&1; then
          : >"$imap_matrix_resume_applied"
          chmod 0600 "$imap_matrix_resume_applied"
        else
          : >"$imap_matrix_resume_failed"
          chmod 0600 "$imap_matrix_resume_failed"
        fi
      fi
      if [ -e "$imap_matrix_reset_uidvalidity_request" ]; then
        rm -f "$imap_matrix_reset_uidvalidity_request" "$imap_matrix_reset_uidvalidity_applied" "$imap_matrix_reset_uidvalidity_failed"
        if mail_control reset-uidvalidity >>"$runtime_log" 2>&1; then
          : >"$imap_matrix_reset_uidvalidity_applied"
          chmod 0600 "$imap_matrix_reset_uidvalidity_applied"
        else
          : >"$imap_matrix_reset_uidvalidity_failed"
          chmod 0600 "$imap_matrix_reset_uidvalidity_failed"
        fi
      fi
      if [ -e "$imap_matrix_assert_authentication_request" ]; then
        rm -f "$imap_matrix_assert_authentication_request" "$imap_matrix_assert_authentication_applied" "$imap_matrix_assert_authentication_failed"
        imap_authentication_count=$(mail_python -c 'from plainpost_acceptance_mail_state import read; print(next((item["count"] for item in read()["phase_counters"] if item["protocol"] == "imap" and item["phase"] == "authentication"), 0))' 2>>"$runtime_log" || true)
        if is_nonnegative_integer "$imap_authentication_count" &&
           is_nonnegative_integer "$imap_authentication_expected_after" &&
           [ "$imap_authentication_count" = "$imap_authentication_expected_after" ]; then
          : >"$imap_matrix_assert_authentication_applied"
          chmod 0600 "$imap_matrix_assert_authentication_applied"
        else
          : >"$imap_matrix_assert_authentication_failed"
          chmod 0600 "$imap_matrix_assert_authentication_failed"
        fi
      fi
      if [ -e "$imap_matrix_append_message_request" ]; then
        rm -f "$imap_matrix_append_message_request" "$imap_matrix_append_message_applied" "$imap_matrix_append_message_failed"
        if mail_control append-matrix-message >>"$runtime_log" 2>&1; then
          : >"$imap_matrix_append_message_applied"
          chmod 0600 "$imap_matrix_append_message_applied"
        else
          : >"$imap_matrix_append_message_failed"
          chmod 0600 "$imap_matrix_append_message_failed"
        fi
      fi
      if [ -e "$imap_matrix_assert_no_idle_request" ]; then
        rm -f "$imap_matrix_assert_no_idle_request" "$imap_matrix_assert_no_idle_applied" "$imap_matrix_assert_no_idle_failed"
        imap_idle_count=$(mail_python -c 'from plainpost_acceptance_mail_state import read; print(next((item["count"] for item in read()["phase_counters"] if item["protocol"] == "imap" and item["phase"] == "idle"), 0))' 2>>"$runtime_log" || true)
        if [ "$imap_idle_count" = 0 ]; then
          : >"$imap_matrix_assert_no_idle_applied"
          chmod 0600 "$imap_matrix_assert_no_idle_applied"
        else
          : >"$imap_matrix_assert_no_idle_failed"
          chmod 0600 "$imap_matrix_assert_no_idle_failed"
        fi
      fi
      if [ -e "$mail_postcondition_request" ]; then
        rm -f "$mail_postcondition_request"
        mail_postcondition_state_expectation="$temporary/mail-state/mail-postcondition.expectation"
        rm -f "$mail_postcondition_applied" "$mail_postcondition_failed" "$temporary/control/mail-postcondition.result" "$mail_postcondition_state_expectation"
        if [ -f "$mail_postcondition_expectation" ] && cp "$mail_postcondition_expectation" "$mail_postcondition_state_expectation" && chmod 0600 "$mail_postcondition_state_expectation" && mail_control postcondition --expectation-file /var/lib/plainpost/$(basename "$mail_postcondition_state_expectation") >"$temporary/control/mail-postcondition.result" 2>>"$runtime_log"; then
          chmod 0600 "$temporary/control/mail-postcondition.result"
          : >"$mail_postcondition_applied"
          chmod 0600 "$mail_postcondition_applied"
        else
          acceptance_mail_postcondition_failure_summary "$temporary/control/mail-postcondition.result" "$runtime_log"
          : >"$mail_postcondition_failed"
          chmod 0600 "$mail_postcondition_failed"
        fi
      fi
      if [ -e "$arm_sent_append_failure_request" ]; then
        rm -f "$arm_sent_append_failure_request" "$arm_sent_append_failure_applied" "$arm_sent_append_failure_failed"
        if [ "$acceptance_mail_scenario" = smtp-sent-append-failure ] && mail_control arm-fault imap-sent-append 1 temporary >>"$runtime_log" 2>&1; then
          : >"$arm_sent_append_failure_applied"
          chmod 0600 "$arm_sent_append_failure_applied"
        else
          : >"$arm_sent_append_failure_failed"
          chmod 0600 "$arm_sent_append_failure_failed"
        fi
      fi
      if [ -e "$smtp_matrix_assert_no_auth_request" ]; then
        rm -f "$smtp_matrix_assert_no_auth_request" "$smtp_matrix_assert_no_auth_applied" "$smtp_matrix_assert_no_auth_failed"
        smtp_authentication_count=$(mail_python -c 'from plainpost_acceptance_mail_state import read; print(next((item["count"] for item in read()["phase_counters"] if item["protocol"] == "smtp" and item["phase"] == "authentication"), 0))' 2>>"$runtime_log" || true)
        if [ "$smtp_authentication_count" = 0 ]; then
          : >"$smtp_matrix_assert_no_auth_applied"
          chmod 0600 "$smtp_matrix_assert_no_auth_applied"
        else
          : >"$smtp_matrix_assert_no_auth_failed"
          chmod 0600 "$smtp_matrix_assert_no_auth_failed"
        fi
      fi
      if [ -e "$smtp_matrix_assert_authentication_command_request" ]; then
        rm -f "$smtp_matrix_assert_authentication_command_request" "$smtp_matrix_assert_authentication_command_applied" "$smtp_matrix_assert_authentication_command_failed"
        smtp_authentication_command_expected=0
        if [ "$acceptance_mail_scenario" = smtp-auth-before-starttls ]; then
          # The production STARTTLS client correctly refuses a peer that does
          # not advertise STARTTLS. Exercise the distinct protocol rejection
          # seam with a bounded fixture-local probe that sends AUTH without
          # credentials, so the fixture records the command but no payload.
          if ! compose_run exec -T smtp-fixture python -c 'import socket; s=socket.create_connection(("127.0.0.1", 587), 2); s.recv(256); s.sendall(b"EHLO probe\r\n"); s.recv(512); s.sendall(b"AUTH PLAIN\r\n"); s.recv(256); s.close()' >>"$runtime_log" 2>&1; then
            : >"$smtp_matrix_assert_authentication_command_failed"
            chmod 0600 "$smtp_matrix_assert_authentication_command_failed"
            continue
          fi
          smtp_authentication_command_expected=1
        fi
        smtp_authentication_command_count=$(mail_python -c 'from plainpost_acceptance_mail_state import read; print(next((item["count"] for item in read()["phase_counters"] if item["protocol"] == "smtp" and item["phase"] == "authentication-command"), 0))' 2>>"$runtime_log" || true)
        if [ "$smtp_authentication_command_count" = "$smtp_authentication_command_expected" ]; then
          : >"$smtp_matrix_assert_authentication_command_applied"
          chmod 0600 "$smtp_matrix_assert_authentication_command_applied"
        else
          : >"$smtp_matrix_assert_authentication_command_failed"
          chmod 0600 "$smtp_matrix_assert_authentication_command_failed"
        fi
      fi
      if [ -e "$restore_smtp_fixture_normal_request" ]; then
        rm -f "$restore_smtp_fixture_normal_request" "$restore_smtp_fixture_normal_applied" "$restore_smtp_fixture_normal_failed"
        PLAINPOST_ACCEPTANCE_SMTP_TLS_MODE=normal export PLAINPOST_ACCEPTANCE_SMTP_TLS_MODE
        if compose_run up -d --no-deps --force-recreate smtp-fixture >>"$runtime_log" 2>&1; then
          restore_smtp_container=$(compose_run ps -q smtp-fixture)
          restore_smtp_health=starting
          for _ in $(seq 1 60); do
            restore_smtp_health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}starting{{end}}' "$restore_smtp_container" 2>/dev/null || true)
            [ "$restore_smtp_health" = healthy ] && break
            sleep 1
          done
          if [ "$restore_smtp_health" = healthy ]; then
            : >"$restore_smtp_fixture_normal_applied"
            chmod 0600 "$restore_smtp_fixture_normal_applied"
          else
            : >"$restore_smtp_fixture_normal_failed"
            chmod 0600 "$restore_smtp_fixture_normal_failed"
          fi
        else
          : >"$restore_smtp_fixture_normal_failed"
          chmod 0600 "$restore_smtp_fixture_normal_failed"
        fi
      fi
      if [ -e "$restore_imap_fixture_normal_request" ]; then
        rm -f "$restore_imap_fixture_normal_request" "$restore_imap_fixture_normal_applied" "$restore_imap_fixture_normal_failed"
        PLAINPOST_ACCEPTANCE_IMAP_TLS_MODE=normal export PLAINPOST_ACCEPTANCE_IMAP_TLS_MODE
        if compose_run up -d --no-deps --force-recreate imap-fixture >>"$runtime_log" 2>&1; then
          restore_imap_container=$(compose_run ps -q imap-fixture)
          restore_imap_health=starting
          for _ in $(seq 1 60); do
            restore_imap_health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}starting{{end}}' "$restore_imap_container" 2>/dev/null || true)
            [ "$restore_imap_health" = healthy ] && break
            sleep 1
          done
          if [ "$restore_imap_health" = healthy ]; then
            : >"$restore_imap_fixture_normal_applied"
            chmod 0600 "$restore_imap_fixture_normal_applied"
          else
            : >"$restore_imap_fixture_normal_failed"
            chmod 0600 "$restore_imap_fixture_normal_failed"
          fi
        else
          : >"$restore_imap_fixture_normal_failed"
          chmod 0600 "$restore_imap_fixture_normal_failed"
        fi
      fi
      restart_fixture() {
        fixture_service=$1
        fixture_request=$2
        fixture_applied=$3
        fixture_failed=$4
        rm -f "$fixture_request" "$fixture_applied" "$fixture_failed" "$temporary/control/$fixture_service.status"
        fixture_probe_password_file="$temporary/control/smtp-probe-password"
        if run_controller_child "restart-$fixture_service" "$fixture_restart_timeout_seconds" env \
          "$root/Scripts/lib/acceptance-fixture-restart.sh" \
          "$compose" "$project" "$temporary" "$fixture_service" "$node_image" \
          "$acceptance_node_uid" "$acceptance_node_gid" "$acceptance_attachment_storage" \
          "$acceptance_attachment_dir" "$acceptance_response_drops" "$acceptance_s3_endpoint" \
          "$acceptance_s3_bucket" "$acceptance_s3_region" "$acceptance_s3_addressing" \
          "$acceptance_s3_access_key_file" "$acceptance_s3_secret_key_file" \
          "$fixture_probe_password_file"; then
          :
        fi
      }
      if [ -e "$restart_imap_fixture_request" ]; then
        restart_fixture imap-fixture "$restart_imap_fixture_request" "$restart_imap_fixture_applied" "$restart_imap_fixture_failed"
      fi
      if [ -e "$restart_smtp_fixture_request" ]; then
        restart_fixture smtp-fixture "$restart_smtp_fixture_request" "$restart_smtp_fixture_applied" "$restart_smtp_fixture_failed"
      fi
      sleep 0.25
    done
  }
  client_control_loop &
  client_control_pid=$!
fi
PLAINPOST_SYNC_NODE_PRIVATE_ACCEPTANCE=enabled \
PLAINPOST_SYNC_NODE_ACCEPTANCE=enabled \
PLAINPOST_SYNC_NODE_ACCEPTANCE_BASE_URL="https://plainpost-api.olhapi.com" \
PLAINPOST_SYNC_NODE_ACCEPTANCE_CA_FILE="$temporary/ca.crt" \
PLAINPOST_SYNC_NODE_ACCEPTANCE_ARTIFACT_ROOT="$temporary/artifacts" \
PLAINPOST_SYNC_NODE_ACCEPTANCE_CENTRAL_RESOLVE="plainpost-api.olhapi.com:443:127.0.0.1:$central_port" \
PLAINPOST_SYNC_NODE_ACCEPTANCE_NODE_ONE_RESOLVE="node-one.private-beta.ts.net:18443:127.0.0.1:$node_one_port" \
PLAINPOST_SYNC_NODE_ACCEPTANCE_NODE_TWO_RESOLVE="node-two.private-beta.ts.net:18443:127.0.0.1:$node_two_port" \
PLAINPOST_SYNC_NODE_BOOTSTRAP_PROFILE_ONE="$node_one_bootstrap_profile" \
PLAINPOST_SYNC_NODE_BOOTSTRAP_PROFILE_TWO="$node_two_bootstrap_profile" \
PLAINPOST_SYNC_NODE_CONTROL_ROOT="$temporary/control" \
PLAINPOST_SYNC_NODE_ACCEPTANCE_MAIL_SCENARIO="$acceptance_mail_scenario" \
PLAINPOST_SYNC_NODE_PRIVATE_TRANSPORT_RELEASE="$release_mode" \
PLAINPOST_SYNC_NODE_ACCEPTANCE_MAIL_STATE_ROOT="$temporary/mail-state" \
PLAINPOST_SYNC_NODE_ERROR_SURFACE_ROOT="$temporary/error-surfaces" \
PLAINPOST_SYNC_NODE_RETURNED_PRIVACY_PATTERNS="$patterns" \
PLAINPOST_SYNC_NODE_RETURNED_DATABASE_PRIVACY_PATTERNS="$returned_database_patterns" \
PLAINPOST_SYNC_NODE_STAGE_LOG="$swift_stage_log" \
PLAINPOST_SYNC_NODE_STREAM_DIAGNOSTIC_LOG="$swift_stream_diagnostic_log" \
PLAINPOST_SYNC_NODE_ACCEPTANCE_DROP_RESPONSES="$acceptance_response_drops" \
run_in_owned_session "$root/Scripts/swift-test-isolated.sh" --filter "$acceptance_filter" >>"$temporary/swift.log" 2>&1 &
swift_pid=$!
if ! capture_owned_process_group; then
  printf 'Swift process group capture failed\n' >&2
  exit 1
fi
client_scenario_started_at=$(date +%s)
swift_last_progress_at=$client_scenario_started_at
swift_log_bytes=0
record_signal_timeout() {
  requested_signal=$1
  timeout_now=$2
  swift_alive=0
  kill -0 "$swift_pid" 2>/dev/null && swift_alive=1 || true
  idle_seconds=$((timeout_now - swift_last_progress_at))
  total_seconds=$((timeout_now - client_scenario_started_at))
  printf 'ERROR acceptance-signal-timeout signal=%s swift_alive=%s idle_seconds=%s total_seconds=%s\n' \
    "$requested_signal" "$swift_alive" "$idle_seconds" "$total_seconds" >>"$runtime_log"
  printf 'ERROR swift-progress-begin signal=%s\n' "$requested_signal" >>"$runtime_log"
  cat "$swift_stage_log" >>"$runtime_log" 2>&1 || true
  capture_swift_log
  printf 'ERROR swift-progress-end signal=%s\n' "$requested_signal" >>"$runtime_log"
}
wait_for_signal() {
  requested_signal=$1
  signal_wait_seconds=$default_signal_wait_seconds
  if [ "${PLAINPOST_SYNC_NODE_CLIENT_API:-}" = enabled ]; then
    signal_wait_seconds=$client_signal_idle_timeout_seconds
  fi
  signal_started_at=$(date +%s)
  while :; do
    [ -f "$temporary/control/$requested_signal" ] && return 0
    now=$(date +%s)
    current_swift_log_bytes=$(wc -c <"$temporary/swift.log" | tr -d '[:space:]')
    if [ "$current_swift_log_bytes" -gt "$swift_log_bytes" ]; then
      swift_log_bytes=$current_swift_log_bytes
      swift_last_progress_at=$now
    fi
    current_swift_stage_log_bytes=$(wc -c <"$swift_stage_log" | tr -d '[:space:]')
    if [ "$current_swift_stage_log_bytes" -gt "$swift_stage_log_bytes" ]; then
      swift_stage_log_bytes=$current_swift_stage_log_bytes
      swift_last_progress_at=$now
    fi
    if ! kill -0 "$swift_pid" 2>/dev/null; then
      record_signal_timeout "$requested_signal" "$now"
      return 1
    fi
    if [ "${PLAINPOST_SYNC_NODE_CLIENT_API:-}" = enabled ]; then
      idle_seconds=$((now - swift_last_progress_at))
      total_seconds=$((now - client_scenario_started_at))
      if [ "$idle_seconds" -ge "$client_signal_idle_timeout_seconds" ] || [ "$total_seconds" -ge "$client_scenario_cap_seconds" ]; then
        record_signal_timeout "$requested_signal" "$now"
        return 1
      fi
    elif [ "$((now - signal_started_at))" -ge "$signal_wait_seconds" ]; then
      record_signal_timeout "$requested_signal" "$now"
      return 1
    fi
    sleep 1
  done
}
seed_node_two_acceptance_provider() {
  printf 'ERROR acceptance-provider-seed-node-two-start\n' >>"$runtime_log"
  if compose_run run --rm --no-deps sync-node-acceptance-seed-node-two \
    -seed-provider \
    -node-database-file /run/secrets/database_url \
    -master-key /run/secrets/master_key \
    -provider-password /run/secrets/provider_password >>"$runtime_log" 2>&1; then
    printf 'ERROR acceptance-provider-seed-node-two-success\n' >>"$runtime_log"
    printf 'ERROR acceptance-provider-seed-node-two-checkpoint\n' >>"$runtime_log"
  else
    printf 'ERROR acceptance-provider-seed-node-two-failed\n' >>"$runtime_log"
    return 1
  fi
}
run_node_two_activation_sequence() {
  control_marker node-two-activation-wait-begin
  if wait_for_signal node-two-activated; then
    control_marker node-two-activation-wait-end
  else
    control_marker node-two-activation-wait-failed
    return 1
  fi
  control_marker node-two-hot-ready-wait-begin
  if wait_for_signal node-two-hot-ready; then
    control_marker node-two-hot-ready-wait-end
  else
    control_marker node-two-hot-ready-wait-failed
    return 1
  fi
  control_marker node-two-process-identity-begin
  if assert_node_process_identity node-two; then
    control_marker node-two-process-identity-end
  else
    control_marker node-two-process-identity-failed
    return 1
  fi
  if [ "${PLAINPOST_SYNC_NODE_CLIENT_API:-}" = enabled ]; then
    seed_node_two_acceptance_provider || exit 1
  fi
  control_marker node-two-restart-begin
  if restart_node_bounded node-two node-two.private-beta.ts.net "$node_two_port" startup-node-two-2
  then
    control_marker node-two-restart-end
  else
    control_marker node-two-restart-failed
    return 1
  fi
  control_marker node-two-readiness-begin
  if wait_for_node_two_ready after-restart-2
  then
    control_marker node-two-readiness-end
  else
    control_marker node-two-readiness-failed
    return 1
  fi
  control_marker node-two-schema-checkpoint-begin
  if node_two_schema_checkpoint after-restarts; then
    control_marker node-two-schema-checkpoint-end
  else
    control_marker node-two-schema-checkpoint-failed
    return 1
  fi
  : >"$temporary/control/node-two-restarted"
  control_marker node-two-publish-restarted
}
control_marker node-one-restart-wait-begin
if wait_for_signal node-one-activated; then
  control_marker node-one-restart-wait-end
else
  control_marker node-one-restart-wait-failed
  exit 1
fi
control_marker node-one-hot-ready-wait-begin
if wait_for_signal node-one-hot-ready; then
  control_marker node-one-hot-ready-wait-end
else
  control_marker node-one-hot-ready-wait-failed
  exit 1
fi
assert_node_process_identity node-one
if [ "${PLAINPOST_SYNC_NODE_CLIENT_API:-}" = enabled ]; then
  arm_initial_response_drops
fi
control_marker node-one-checkpoint-before-begin
assert_node_one_installation_checkpoint before-restart
control_marker node-one-checkpoint-before-end
if [ "${PLAINPOST_SYNC_NODE_CLIENT_API:-}" = enabled ]; then
  printf 'ERROR acceptance-provider-seed-start\n' >>"$runtime_log"
  if ! compose_run run --rm --no-deps sync-node-acceptance-seed \
    -seed-provider \
    -node-database-file /run/secrets/database_url \
    -master-key /run/secrets/master_key \
    -provider-password /run/secrets/provider_password >>"$runtime_log" 2>&1; then
    printf 'ERROR acceptance-provider-seed-failed\n' >>"$runtime_log"
    exit 1
  fi
  printf 'ERROR acceptance-provider-seed-success\n' >>"$runtime_log"
  printf 'ERROR acceptance-provider-seed-checkpoint\n' >>"$runtime_log"
  refresh_active_node_database_name || {
    printf 'ERROR release-backup-restore active-database-reference-invalid\n' >>"$runtime_log"
    exit 1
  }
  docker exec "$node_one_database_container" psql -U "$node_database_inspection_role" -d "$node_one_database_name" -Atc \
    "SELECT provider_mailbox_id || E'\\t' || node_provider_mailboxes.active::text || E'\\t' || baseline_state || E'\\t' || COALESCE(node_provider_session_configs.generic_profile->'SyncMailboxIDs','null'::jsonb)::text FROM node_provider_mailboxes LEFT JOIN node_provider_session_configs USING (account_id,logical_mailbox) ORDER BY provider_mailbox_id" \
    >>"$runtime_log" 2>&1 || true
fi
control_marker node-one-restart-2-begin
if restart_node_bounded node-one node-one.private-beta.ts.net "$node_one_port" startup-node-one-2; then
  control_marker node-one-restart-2-end
else
  control_marker node-one-restart-2-failed
  exit 1
fi
control_marker node-one-readiness-2-begin
if wait_for_node_one_ready after-restart-2; then
  control_marker node-one-readiness-2-end
else
  control_marker node-one-readiness-2-failed
  exit 1
fi
control_marker node-one-checkpoint-2-begin
assert_node_one_installation_checkpoint after-restart-2
control_marker node-one-checkpoint-2-end
: >"$temporary/control/node-one-restarted"
control_marker node-one-publish-restarted
case "$acceptance_mail_scenario" in
  imap-*)
    run_node_two_activation_sequence
    ;;
  *)
    control_marker authority-outage-wait-begin
    if wait_for_signal authority-outage; then
      control_marker authority-outage-wait-end
    else
      control_marker authority-outage-wait-failed
      exit 1
    fi
    control_marker authority-outage-pause-begin
    if compose_run pause central-tls >>"$runtime_log" 2>&1; then
      control_marker authority-outage-pause-end
    else
      control_marker authority-outage-pause-failed
      exit 1
    fi
    control_marker authority-outage-restart-begin
    if restart_node_bounded node-one node-one.private-beta.ts.net "$node_one_port" startup-node-one-authority-outage health; then
      control_marker authority-outage-restart-end
    else
      control_marker authority-outage-restart-failed
      exit 1
    fi
    control_marker authority-outage-readiness-begin
    if wait_for_node_health authority-outage-restart; then
      control_marker authority-outage-readiness-end
    else
      control_marker authority-outage-readiness-failed
      exit 1
    fi
    : >"$temporary/control/authority-unavailable"
    control_marker authority-outage-publish-unavailable
    control_marker authority-recover-wait-begin
    if wait_for_signal authority-recover; then
      control_marker authority-recover-wait-end
    else
      control_marker authority-recover-wait-failed
      exit 1
    fi
    control_marker authority-outage-unpause-begin
    if compose_run unpause central-tls >>"$runtime_log" 2>&1; then
      control_marker authority-outage-unpause-end
    else
      control_marker authority-outage-unpause-failed
      exit 1
    fi
    : >"$temporary/control/authority-restored"
    control_marker authority-outage-publish-restored
    run_node_two_activation_sequence
    ;;
esac
wait_for_signal account-deleted
restart_node_bounded node-two node-two.private-beta.ts.net "$node_two_port" startup-node-two-deletion health
wait_for_node_two_deleted_503 after-deletion
node_two_schema_checkpoint before-privacy-audit || exit 1
: >"$temporary/control/node-two-deletion-restarted"
swift_exit_status=0
wait "$swift_pid" || swift_exit_status=$?
capture_swift_log
stop_swift_process
printf 'ERROR swift-exit status=%s\n' "$swift_exit_status" >>"$runtime_log"
if [ "$swift_exit_status" -ne 0 ]; then
  printf 'ERROR swift-exit status=%s\n' "$swift_exit_status" >&2
  exit "$swift_exit_status"
fi
if [ "$transport_release_images" = 1 ]; then
  grep -Fx 'ERROR swift-stage stage=backup-restore-end' "$swift_stage_log" >/dev/null || {
    printf 'ERROR release-backup-restore runtime evidence unavailable\n' >>"$runtime_log"
    printf 'release backup restore runtime evidence unavailable; values suppressed\n' >&2
    exit 1
  }
  refresh_active_node_database_name required || {
    printf 'active release database reference is unavailable; values suppressed\n' >&2
    exit 1
  }
  printf '%s\n' "$node_one_database_name" | grep -Eq '^restore_[0-9a-f]{32}$' || {
      printf 'active release database reference is not a restore database; values suppressed\n' >&2
      exit 1
  }
  printf 'release-backup-restore status=passed\n'
fi
if [ "$transport_release_images" = 1 ]; then
  # This marker is emitted only after the real Swift client process exits
  # successfully; a preceding stage label is not acceptance evidence.
  printf 'release-traffic=swift-client status=passed\n'
fi
if [ "$acceptance_mail_scenario" = smtp-concurrent-sends ]; then
  if ! mail_python -c 'import sys; from plainpost_acceptance_mail_state import read; value=read(); sent=sum(1 for item in value["messages"] if "Sent" in item.get("labels", [])); raise SystemExit(0 if len(value["deliveries"]) == 2 and sent == 2 else 1)' ; then
    printf 'ERROR acceptance-smtp-matrix outcome=postcondition-mismatch\n' >&2
    exit 1
  fi
fi

printf 'stage=privacy-audit\n'
privacy_container_log_max_bytes=67108864
# With no service arguments Compose returns every service in this exact
# project, including both Node databases and the IMAP/SMTP fixtures. The scan
# must see the complete stream; a size violation is an audited failure, never
# permission to inspect only a tail.
if ! compose_run logs --no-color --no-log-prefix >"$temporary/container.log" 2>&1; then
  printf 'runtime log collection failed\n' >&2; exit 1
fi
container_log_bytes=$(wc -c <"$temporary/container.log" | tr -d ' ')
case "$container_log_bytes" in
  ''|*[!0-9]*) printf 'private runtime log audit size failed; values suppressed\n' >&2; exit 1 ;;
esac
[ "$container_log_bytes" -le "$privacy_container_log_max_bytes" ] || {
  printf 'private runtime log audit exceeded bound; values suppressed\n' >&2
  exit 1
}
if [ "${PLAINPOST_SYNC_NODE_CLIENT_API:-}" = enabled ]; then
  require_response_drop_evidence() {
    response_drop_route=$1
    response_drop_outcome=$2
    response_drop_label=$3
    response_drop_cycle=$4
    response_drop_marker="$temporary/response-drop-$response_drop_label"
    if ! grep -F '"msg":"acceptance-response-drop"' "$temporary/container.log" | grep -F "\"route\":\"$response_drop_route\"" | grep -F "\"cycle\":\"$response_drop_cycle\"" | grep -F "\"outcome\":\"$response_drop_outcome\"" >"$response_drop_marker"; then
      printf 'acceptance response-drop evidence missing route=%s cycle=%s outcome=%s\n' "$response_drop_route" "$response_drop_cycle" "$response_drop_outcome" >&2
      exit 1
    fi
    response_drop_count=$(wc -l <"$response_drop_marker" | tr -d ' ')
    [ "$response_drop_count" -eq 1 ] || {
      printf 'acceptance response-drop evidence duplicated route=%s cycle=%s outcome=%s count=%s\n' "$response_drop_route" "$response_drop_cycle" "$response_drop_outcome" "$response_drop_count" >&2
      exit 1
    }
    case "$response_drop_outcome" in
      dropped) acceptance_response_drop_dropped_count=$((acceptance_response_drop_dropped_count + 1)) ;;
      exact-replay) acceptance_response_drop_exact_replay_count=$((acceptance_response_drop_exact_replay_count + 1)) ;;
      replay-accepted) acceptance_response_drop_fresh_committed_count=$((acceptance_response_drop_fresh_committed_count + 1)) ;;
      *) printf 'unknown acceptance response-drop outcome=%s\n' "$response_drop_outcome" >&2; exit 1 ;;
    esac
  }
  require_response_drop_evidence 'GET /v1/status' dropped status-initial-dropped initial
  require_response_drop_evidence 'GET /v1/status' exact-replay status-initial-exact-replay initial
  require_response_drop_evidence 'GET /v1/status' replay-accepted status-initial-committed initial
  check_status_response_drop_correlation() {
    response_drop_cycle=$1
    response_drop_dropped=$(sed -n 's/.*"sequence":"\([^"]*\)".*"body_sha256":"\([^"]*\)".*/\1 \2/p' "$temporary/response-drop-status-$response_drop_cycle-dropped")
    response_drop_exact=$(sed -n 's/.*"sequence":"\([^"]*\)".*"body_sha256":"\([^"]*\)".*/\1 \2/p' "$temporary/response-drop-status-$response_drop_cycle-exact-replay")
    response_drop_committed=$(sed -n 's/.*"sequence":"\([^"]*\)".*"body_sha256":"\([^"]*\)".*/\1 \2/p' "$temporary/response-drop-status-$response_drop_cycle-committed")
    response_drop_dropped_sequence=${response_drop_dropped%% *}
    response_drop_dropped_digest=${response_drop_dropped#* }
    response_drop_exact_sequence=${response_drop_exact%% *}
    response_drop_exact_digest=${response_drop_exact#* }
    response_drop_committed_sequence=${response_drop_committed%% *}
    response_drop_committed_digest=${response_drop_committed#* }
    if [ -z "$response_drop_dropped_sequence" ] || [ "$response_drop_dropped_sequence" = unavailable ] || [ "$response_drop_dropped_digest" = unavailable ] || [ "$response_drop_dropped_sequence" != "$response_drop_exact_sequence" ] || [ "$response_drop_dropped_digest" != "$response_drop_exact_digest" ] || [ "$response_drop_committed_sequence" = "$response_drop_dropped_sequence" ] || [ "$response_drop_committed_digest" != "$response_drop_dropped_digest" ]; then
      printf 'acceptance response-drop correlation failed route=GET /v1/status cycle=%s\n' "$response_drop_cycle" >&2
      exit 1
    fi
    printf 'acceptance response-drop correlation route=GET /v1/status cycle=%s sequence=%s fresh_sequence=%s body_sha256=%s\n' "$response_drop_cycle" "$response_drop_dropped_sequence" "$response_drop_committed_sequence" "$response_drop_dropped_digest" >>"$runtime_log"
  }
  check_status_response_drop_correlation initial
  check_mutation_response_drop_correlation() {
    response_drop_cycle=$1
    response_drop_dropped=$(sed -n 's/.*"sequence":"\([^" ]*\)".*"body_sha256":"\([^" ]*\)".*/\1 \2/p' "$temporary/response-drop-mutation-$response_drop_cycle-dropped")
    response_drop_exact=$(sed -n 's/.*"sequence":"\([^" ]*\)".*"body_sha256":"\([^" ]*\)".*/\1 \2/p' "$temporary/response-drop-mutation-$response_drop_cycle-exact-replay")
    response_drop_committed=$(sed -n 's/.*"sequence":"\([^" ]*\)".*"body_sha256":"\([^" ]*\)".*/\1 \2/p' "$temporary/response-drop-mutation-$response_drop_cycle-committed")
    response_drop_dropped_sequence=${response_drop_dropped%% *}
    response_drop_dropped_digest=${response_drop_dropped#* }
    response_drop_exact_sequence=${response_drop_exact%% *}
    response_drop_exact_digest=${response_drop_exact#* }
    response_drop_committed_sequence=${response_drop_committed%% *}
    response_drop_committed_digest=${response_drop_committed#* }
    if [ -z "$response_drop_dropped_sequence" ] || [ "$response_drop_dropped_sequence" = unavailable ] || [ "$response_drop_dropped_digest" = unavailable ] || [ "$response_drop_dropped_sequence" != "$response_drop_exact_sequence" ] || [ "$response_drop_dropped_digest" != "$response_drop_exact_digest" ] || [ "$response_drop_committed_sequence" = "$response_drop_dropped_sequence" ] || [ "$response_drop_committed_digest" != "$response_drop_dropped_digest" ]; then
      printf 'acceptance response-drop correlation failed route=POST /v1/mutations cycle=%s\n' "$response_drop_cycle" >&2
      exit 1
    fi
    printf 'acceptance response-drop correlation route=POST /v1/mutations cycle=%s sequence=%s fresh_sequence=%s body_sha256=%s\n' "$response_drop_cycle" "$response_drop_dropped_sequence" "$response_drop_committed_sequence" "$response_drop_dropped_digest" >>"$runtime_log"
  }
  if [ "$acceptance_mail_scenario" = imap-node-restart-before-ack ]; then
    require_response_drop_evidence 'POST /v1/mutations' dropped mutation-initial-dropped initial
    require_response_drop_evidence 'POST /v1/mutations' exact-replay mutation-initial-exact-replay initial
    require_response_drop_evidence 'POST /v1/mutations' replay-accepted mutation-initial-committed initial
    check_mutation_response_drop_correlation initial
  fi
  if [ "$acceptance_response_drop_restart_expected" -eq 1 ]; then
    require_response_drop_evidence 'GET /v1/status' dropped status-restart-dropped restart
    require_response_drop_evidence 'GET /v1/status' exact-replay status-restart-exact-replay restart
    require_response_drop_evidence 'GET /v1/status' replay-accepted status-restart-committed restart
    check_status_response_drop_correlation restart
  fi
  acceptance_response_drop_total_count=$((acceptance_response_drop_dropped_count + acceptance_response_drop_exact_replay_count + acceptance_response_drop_fresh_committed_count))
  [ "$acceptance_response_drop_dropped_count" -eq "$acceptance_response_drop_expected_dropped_count" ] || { printf 'acceptance response-drop dropped count mismatch\n' >&2; exit 1; }
  [ "$acceptance_response_drop_exact_replay_count" -eq "$acceptance_response_drop_expected_exact_replay_count" ] || { printf 'acceptance response-drop exact replay count mismatch\n' >&2; exit 1; }
  [ "$acceptance_response_drop_fresh_committed_count" -eq "$acceptance_response_drop_expected_fresh_committed_count" ] || { printf 'acceptance response-drop fresh commit count mismatch\n' >&2; exit 1; }
  acceptance_response_drop_expected_total_count=$((acceptance_response_drop_expected_dropped_count + acceptance_response_drop_expected_exact_replay_count + acceptance_response_drop_expected_fresh_committed_count))
  [ "$acceptance_response_drop_total_count" -eq "$acceptance_response_drop_expected_total_count" ] || { printf 'acceptance response-drop total count mismatch\n' >&2; exit 1; }
  printf 'acceptance_response_drop_proof dropped=%s exact_replay=%s fresh_committed=%s total=%s\n' "$acceptance_response_drop_dropped_count" "$acceptance_response_drop_exact_replay_count" "$acceptance_response_drop_fresh_committed_count" "$acceptance_response_drop_total_count"
fi
if ! docker inspect "$central_process" "$central_node_one_container" "$central_node_two_container" "$node_one_container" "$node_two_container" >"$temporary/runtime-config.json" 2>>"$runtime_log"; then
  printf 'runtime config collection failed\n' >&2; exit 1
fi
# Each Node necessarily owns its canonical public endpoint. Remove only those
# exact allowed config values before scanning every other generated marker.
sed -e 's#https://node-one\.private-beta\.ts\.net:18081#[allowed-central-endpoint]#g' \
    -e 's#https://node-two\.private-beta\.ts\.net:18081#[allowed-central-endpoint]#g' \
    -e 's#https://node-one\.private-beta\.ts\.net:18443#[allowed-node-endpoint]#g' \
    -e 's#node-one\.private-beta\.ts\.net:18443#[allowed-node-listener]#g' \
    -e 's#https://node-two\.private-beta\.ts\.net:18443#[allowed-node-endpoint]#g' \
    -e 's#node-two\.private-beta\.ts\.net:18443#[allowed-node-listener]#g' \
    "$temporary/runtime-config.json" >"$temporary/runtime-config-audited.json"
scan_privacy_file() {
  privacy_scan_file=$1
  privacy_scan_source=${2:-error-surface}
  if acceptance_scan_privacy_file "$privacy_scan_file" "$privacy_scan_source" "$patterns" "$privacy_pattern_origins" "$runtime_log"; then
    return 0
  elif [ "$?" -eq 1 ]; then
    # Source and origin are closed vocabulary; the matched value never is.
    printf 'private marker contamination detected source=%s origin=%s; values suppressed\n' "$privacy_scan_source" "${acceptance_privacy_match_origin:-unknown}" >&2
    exit 1
  else
    printf 'private marker scan failed; values suppressed\n' >&2
    exit 1
  fi
}
acceptance_privacy_record_pattern_file_tail "$patterns" "$privacy_pattern_origins" returned-client "$privacy_pattern_initial_line_count"
acceptance_privacy_import_tab_patterns "$returned_database_patterns" "$patterns" "$privacy_pattern_origins" returned-client
scan_privacy_file "$runtime_log" runtime-log
scan_privacy_file "$temporary/container.log" container-log
scan_privacy_file "$temporary/runtime-config-audited.json" runtime-config
for error_surface in "$temporary/error-surfaces"/*; do
  if [ ! -e "$error_surface" ] && [ ! -L "$error_surface" ]; then
    continue
  fi
  scan_privacy_file "$error_surface" error-surface
done
contamination_proof="$temporary/error-surface-contamination-proof"
sed -n '1p' "$patterns" >"$contamination_proof"
chmod 0600 "$contamination_proof"
contamination_count=$(grep -F -f "$patterns" "$contamination_proof" | wc -l | tr -d ' ')
[ "$contamination_count" -eq 1 ] || { printf 'error surface contamination owner failed category=representation count=%s\n' "$contamination_count" >&2; exit 1; }
rm "$contamination_proof"
printf 'error_surface_contamination_detected=1\n'
privacy_audit_output="$temporary/privacy-audit-output"
privacy_audit_status=0
privacy_audit_container="$project-privacy-audit"
compose_run --profile privacy run --name "$privacy_audit_container" privacy-audit >"$privacy_audit_output" 2>&1 || privacy_audit_status=$?
if [ "$privacy_audit_status" -ne 0 ]; then
  privacy_audit_category=$(task7_privacy_audit_category_from_output "$privacy_audit_output")
  if [ "$privacy_audit_category" = inputs ]; then
    privacy_audit_input_failure=$(task7_privacy_audit_input_failure_from_output "$privacy_audit_output")
    privacy_audit_subcategory=${privacy_audit_input_failure%% *}
    privacy_audit_reason=${privacy_audit_input_failure#* }
    if [ "$privacy_audit_reason" = unknown ] || [ "$privacy_audit_subcategory" = database-argument-mode ]; then
      printf 'ERROR private database audit failed category=inputs subcategory=%s\n' "$privacy_audit_subcategory" >>"$runtime_log"
      printf 'private database audit failed category=inputs subcategory=%s; values suppressed\n' "$privacy_audit_subcategory" >&2
    else
      printf 'ERROR private database audit failed category=inputs subcategory=%s reason=%s\n' "$privacy_audit_subcategory" "$privacy_audit_reason" >>"$runtime_log"
      printf 'private database audit failed category=inputs subcategory=%s reason=%s; values suppressed\n' "$privacy_audit_subcategory" "$privacy_audit_reason" >&2
    fi
  elif [ "$privacy_audit_category" = central-marker-count ]; then
    privacy_audit_cell=$(task7_privacy_audit_cell_from_output "$privacy_audit_output")
    printf 'ERROR private database audit failed category=%s cell=%s\n' "$privacy_audit_category" "$privacy_audit_cell" >>"$runtime_log"
    printf 'private database audit failed category=%s cell=%s; values suppressed\n' "$privacy_audit_category" "$privacy_audit_cell" >&2
  elif [ "$privacy_audit_category" = node-one-connect ] || [ "$privacy_audit_category" = node-one-marker-query ] || [ "$privacy_audit_category" = node-two-connect ] || [ "$privacy_audit_category" = node-two-marker-query ]; then
    privacy_audit_node_failure=$(task7_privacy_audit_node_failure_from_output "$privacy_audit_output")
    privacy_audit_node_category=${privacy_audit_node_failure%% *}
    privacy_audit_reason=${privacy_audit_node_failure#* }
    if [ "$privacy_audit_node_category" != unknown ]; then
      privacy_audit_category=$privacy_audit_node_category
    fi
    printf 'ERROR private database audit failed category=%s reason=%s\n' "$privacy_audit_category" "$privacy_audit_reason" >>"$runtime_log"
    printf 'private database audit failed category=%s reason=%s; values suppressed\n' "$privacy_audit_category" "$privacy_audit_reason" >&2
  else
    printf 'ERROR private database audit failed category=%s\n' "$privacy_audit_category" >>"$runtime_log"
    printf 'private database audit failed category=%s; values suppressed\n' "$privacy_audit_category" >&2
  fi
  exit 1
fi
scan_privacy_file "$privacy_audit_output" container-log
if ! docker inspect "$privacy_audit_container" >"$temporary/privacy-audit-container-inspect.json" 2>>"$runtime_log"; then
  printf 'private database audit container inspection failed; values suppressed\n' >&2
  exit 1
fi
privacy_audit_container_status=$(docker inspect --format '{{.State.Status}}' "$privacy_audit_container" 2>>"$runtime_log" || true)
if [ "$privacy_audit_container_status" != exited ]; then
  printf 'private database audit container did not exit cleanly; values suppressed\n' >&2
  exit 1
fi
scan_privacy_file "$temporary/privacy-audit-container-inspect.json" container-log
if ! docker rm "$privacy_audit_container" >>"$runtime_log" 2>&1; then
  printf 'private database audit container cleanup failed; values suppressed\n' >&2
  exit 1
fi
if docker inspect "$privacy_audit_container" >>"$runtime_log" 2>&1; then
  printf 'private database audit container was retained; values suppressed\n' >&2
  exit 1
fi
for container in "$node_one_container" "$node_two_container"; do
  published=$(docker inspect --format '{{range $p, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{printf "%s %s" .HostIp .HostPort}}{{end}}{{end}}' "$container")
  [ -z "$published" ] || { printf 'Node unexpectedly has a host publication\n' >&2; exit 1; }
done
for relay in "$node_one_relay" "$node_two_relay"; do
  published=$(docker inspect --format '{{range $p, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{printf "%s %s" .HostIp .HostPort}}{{end}}{{end}}' "$relay")
  case "$published" in 127.0.0.1\ *) ;; *) printf 'acceptance relay has a non-loopback or missing publication\n' >&2; exit 1;; esac
done
if [ -n "$(docker port "$postgres_container" 2>/dev/null)" ]; then printf 'PostgreSQL unexpectedly published a host port\n' >&2; exit 1; fi
printf 'privacy_markers_found=0\npostgres_published_ports=0\npublic_node_binds=0\n'
# Both Nodes were force-recreated with v2 audience leaves after provisioning.
# Any activation-bootstrap-* diagnostic (verifier, origin, audience or bind)
# means a Node refused its leaf, so a passing run must have none.
for bootstrap_container in "$node_one_container" "$node_two_container"; do
  bootstrap_log=$(docker logs "$bootstrap_container" 2>&1) || {
    printf 'Node log capture failed\n' >&2
    exit 1
  }
  bootstrap_diagnostics=$(printf '%s\n' "$bootstrap_log" | grep -c 'activation-bootstrap-' || true)
  [ "$bootstrap_diagnostics" = 0 ] || {
    printf 'Node logged an activation-bootstrap diagnostic after v2 leaf installation\n' >&2
    exit 1
  }
done
printf 'activation_bootstrap_diagnostics=0\n'

stop_client_control_loop
trap - EXIT
trap '' HUP INT TERM
cleanup
[ ! -e "$temporary" ]
acceptance_response_drop_total_count=$((acceptance_response_drop_dropped_count + acceptance_response_drop_exact_replay_count + acceptance_response_drop_fresh_committed_count))
printf 'acceptance_response_drop_proof dropped=%s exact_replay=%s fresh_committed=%s total=%s\n' "$acceptance_response_drop_dropped_count" "$acceptance_response_drop_exact_replay_count" "$acceptance_response_drop_fresh_committed_count" "$acceptance_response_drop_total_count"
printf 'retained_containers=0\nretained_volumes=0\nretained_networks=0\nprivate_temp_paths=0\nstatus=passed\n'
