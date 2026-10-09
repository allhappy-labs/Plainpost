#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
owner="$root/Scripts/test-sync-node-private-transport.sh"
helper="$root/Scripts/lib/acceptance-node-two-schema-checkpoint.sh"

test -x "$helper"
grep -F "27:0027_capture_optional_address_search_path.sql" "$helper" >/dev/null
grep -F "node_schema_migrations" "$helper" >/dev/null
! grep -F "FROM schema_migrations" "$helper" >/dev/null
! grep -F 'schema_checkpoint_database=${node_one_database_name' "$helper" >/dev/null
for cause in container-missing container-not-running psql-connect migration-ledger migration-head node-installation-state node-current-authority-state node-secrets relation-query reset-query reset-probe reset-mismatch unexpected-output; do
  grep -F "$cause" "$helper" >/dev/null
done
for relation in node_installation_state node_current_authority_state node_secrets; do
  grep -F "$relation" "$helper" >/dev/null
done
grep -F "to_regclass('public.\$schema_checkpoint_relation')" "$helper" >/dev/null
grep -F "current_schema() IS DISTINCT FROM 'public'" "$helper" >/dev/null
grep -F "to_regnamespace('public') IS NULL" "$helper" >/dev/null
grep -F "plainpost_restore_admin" "$helper" >/dev/null
grep -F "has_schema_privilege('plainpost_sync_node','public','USAGE,CREATE')" "$helper" >/dev/null
grep -F "has_database_privilege('plainpost_sync_node',current_database(),'CONNECT')" "$helper" >/dev/null
grep -F "aclexplode(COALESCE(d.datacl,acldefault('d',d.datdba)))" "$helper" >/dev/null
grep -F "defaclnamespace=0" "$helper" >/dev/null
grep -F "pg_namespace n CROSS JOIN LATERAL aclexplode" "$helper" >/dev/null
grep -F "CREATE TABLE public.__plainpost_reset_probe" "$helper" >/dev/null
grep -F 'transport_release_images' "$helper" >/dev/null
grep -F 'emit_node_two_schema_failure_summary' "$owner" >/dev/null
grep -F 'node-two-schema-checkpoint phase=' "$root/Scripts/lib/release-image-failure-summary.sh" >/dev/null
private_summary_body=$(sed -n '/^emit_private_database_audit_failure_summary()/,/^emit_node_two_schema_failure_summary()/p' "$owner")
! printf '%s\n' "$private_summary_body" | grep -F 'node-two-schema-checkpoint phase=' >/dev/null
grep -F 'trap cleanup EXIT' "$0" >/dev/null
grep -F "$(printf "trap '%s 129' HUP" contract_signal)" "$0" >/dev/null
grep -F "$(printf "trap '%s 130' INT" contract_signal)" "$0" >/dev/null
grep -F "$(printf "trap '%s 143' TERM" contract_signal)" "$0" >/dev/null
grep -F "$(printf 'signal_pid=%s' '""')" "$0" >/dev/null
grep -F "$(printf 'signal_cleanup_grace_steps=%s' '${')" "$0" >/dev/null
grep -F "$(printf 'kill -KILL %s' '"$cleanup_signal_pid"')" "$0" >/dev/null
grep -F "$(printf 'wait %s' '"$cleanup_signal_pid"')" "$0" >/dev/null
grep -F "trap 'on_signal 129' HUP" "$owner" >/dev/null
grep -F "trap 'on_signal 130' INT" "$owner" >/dev/null
grep -F "trap 'on_signal 143' TERM" "$owner" >/dev/null

# The release-only diagnostic must be present at the three lifecycle seams,
# and the final check must precede the deletion marker and audit launch.
initial_line=$(grep -n -F 'node_two_schema_checkpoint initial-ready' "$owner" | head -1 | cut -d: -f1)
restart_line=$(grep -n -F 'node_two_schema_checkpoint after-restarts' "$owner" | head -1 | cut -d: -f1)
deletion_line=$(grep -n -F 'node_two_schema_checkpoint before-privacy-audit' "$owner" | head -1 | cut -d: -f1)
ready_line=$(grep -n -F 'wait_for_node_two_ready initial-ready' "$owner" | head -1 | cut -d: -f1)
tls_stage_line=$(grep -n -F "printf 'stage=node-tls13-only\\n'" "$owner" | head -1 | cut -d: -f1)
restart_ready_line=$(grep -n -F 'wait_for_node_two_ready after-restart-2' "$owner" | head -1 | cut -d: -f1)
deletion_ready_line=$(grep -n -F 'wait_for_node_two_deleted_503 after-deletion' "$owner" | head -1 | cut -d: -f1)
restart_marker_line=$(grep -n -F 'node-two-restarted' "$owner" | head -1 | cut -d: -f1)
deletion_marker_line=$(grep -n -F 'node-two-deletion-restarted' "$owner" | head -1 | cut -d: -f1)
audit_line=$(grep -n -F 'stage=privacy-audit' "$owner" | tail -1 | cut -d: -f1)
[ -n "$initial_line" ] && [ -n "$restart_line" ] && [ -n "$deletion_line" ]
[ -z "$ready_line" ]
[ -n "$tls_stage_line" ] && [ "$tls_stage_line" -lt "$initial_line" ]
[ -n "$restart_ready_line" ] && [ "$restart_ready_line" -lt "$restart_line" ]
[ -n "$deletion_ready_line" ] && [ "$deletion_ready_line" -lt "$deletion_line" ]
[ -n "$restart_marker_line" ] && [ "$restart_line" -lt "$restart_marker_line" ]
[ -n "$deletion_marker_line" ] && [ "$deletion_line" -lt "$deletion_marker_line" ]
[ -n "$audit_line" ] && [ "$deletion_line" -lt "$audit_line" ]

# Exercise the real helper with a fake Docker executable. Only a closed,
# fixed output may reach the caller; the SQL and database values never print.
contract_root=$(mktemp -d "${TMPDIR:-/tmp}/plainpost-node-two-schema-contract.XXXXXX")
signal_pid=""
signal_cleanup_grace_steps=${NODE_TWO_SCHEMA_CONTRACT_SIGNAL_GRACE_STEPS:-20}
signal_cleanup_grace_delay_seconds=0.05
cleanup() {
  cleanup_signal_pid=$signal_pid
  signal_pid=''
  if [ -n "$cleanup_signal_pid" ]; then
    kill -TERM "$cleanup_signal_pid" 2>/dev/null || true
    signal_cleanup_step=0
    while kill -0 "$cleanup_signal_pid" 2>/dev/null; do
      [ "$signal_cleanup_step" -ge "$signal_cleanup_grace_steps" ] && break
      sleep "$signal_cleanup_grace_delay_seconds"
      signal_cleanup_step=$((signal_cleanup_step + 1))
    done
    if kill -0 "$cleanup_signal_pid" 2>/dev/null; then
      kill -KILL "$cleanup_signal_pid" 2>/dev/null || true
    fi
    wait "$cleanup_signal_pid" 2>/dev/null || true
  fi
  find "$contract_root" -depth -delete >/dev/null 2>&1 || true
}
contract_signal() {
  contract_signal_status=$1
  trap - EXIT HUP INT TERM
  cleanup
  exit "$contract_signal_status"
}
trap cleanup EXIT
trap 'contract_signal 129' HUP
trap 'contract_signal 130' INT
trap 'contract_signal 143' TERM
mkdir -m 0700 "$contract_root/bin"
capture="$contract_root/docker.capture"
cat >"$contract_root/bin/docker" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >"$FAKE_DOCKER_CAPTURE"
case "$FAKE_DOCKER_RESULT" in
  container-missing) [ "$1" = inspect ] && exit 1 ;;
  container-not-running) [ "$1" = inspect ] && printf '%s\n' exited ;;
  psql-connect) [ "$1" = inspect ] && printf '%s\n' running || exit 1 ;;
  migration-ledger) [ "$1" = inspect ] && printf '%s\n' running || { case "$*" in *'SELECT 1'*) printf '%s\n' 1 ;; *) exit 1 ;; esac; } ;;
  migration-head) [ "$1" = inspect ] && printf '%s\n' running || { case "$*" in *'SELECT 1'*) printf '%s\n' 1 ;; *) printf '%s\n' head-mismatch ;; esac; } ;;
  relation-query) [ "$1" = inspect ] && printf '%s\n' running || { case "$*" in *'SELECT 1'*) printf '%s\n' 1 ;; *node_schema_migrations*) printf '%s\n' head-passed ;; *) exit 1 ;; esac; } ;;
  node-installation-state) [ "$1" = inspect ] && printf '%s\n' running || { case "$*" in *'SELECT 1'*) printf '%s\n' 1 ;; *node_schema_migrations*) printf '%s\n' head-passed ;; *node_installation_state*) printf '%s\n' missing ;; *) printf '%s\n' present ;; esac; } ;;
  node-current-authority-state) [ "$1" = inspect ] && printf '%s\n' running || { case "$*" in *'SELECT 1'*) printf '%s\n' 1 ;; *node_schema_migrations*) printf '%s\n' head-passed ;; *node_current_authority_state*) printf '%s\n' missing ;; *) printf '%s\n' present ;; esac; } ;;
  node-secrets) [ "$1" = inspect ] && printf '%s\n' running || { case "$*" in *'SELECT 1'*) printf '%s\n' 1 ;; *node_schema_migrations*) printf '%s\n' head-passed ;; *node_secrets*) printf '%s\n' missing ;; *) printf '%s\n' present ;; esac; } ;;
  reset-query) [ "$1" = inspect ] && printf '%s\n' running || { case "$*" in *pg_class*) exit 1 ;; *'SELECT 1'*) printf '%s\n' 1 ;; *) printf '%s\n' reset-passed ;; esac; } ;;
  reset-mismatch) [ "$1" = inspect ] && printf '%s\n' running || { case "$*" in *pg_class*) printf '%s\n' reset-mismatch ;; *'SELECT 1'*) printf '%s\n' 1 ;; *) printf '%s\n' reset-passed ;; esac; } ;;
  reset-probe) [ "$1" = inspect ] && printf '%s\n' running || { case "$*" in *pg_class*) printf '%s\n' reset-passed ;; *'SELECT 1'*) printf '%s\n' 1 ;; *'CREATE TABLE public.__plainpost_reset_probe'*) exit 1 ;; *) printf '%s\n' reset-passed ;; esac; } ;;
  reset-passed) [ "$1" = inspect ] && printf '%s\n' running || { case "$*" in *pg_class*) printf '%s\n' reset-passed ;; *'SELECT 1'*) printf '%s\n' 1 ;; *) printf '%s\n' reset-passed ;; esac; } ;;
  unexpected-output) [ "$1" = inspect ] && printf '%s\n' running || { case "$*" in *'SELECT 1'*) printf '%s\n' 1 ;; *) printf '%s\nextra\n' passed ;; esac; } ;;
  passed) [ "$1" = inspect ] && printf '%s\n' running || { case "$*" in *'SELECT 1'*) printf '%s\n' 1 ;; *node_installation_state*|*node_current_authority_state*|*node_secrets*) printf '%s\n' present ;; *) printf '%s\n' head-passed ;; esac; } ;;
  *) printf '%s\n' unexpected ;;
esac
SH
chmod 0700 "$contract_root/bin/docker"
runtime_log="$contract_root/runtime.log"
outer_signal_ready="$contract_root/outer-signal-ready"
nested_signal_ready="$contract_root/nested-signal-ready"
nested_signal_pid_file="$contract_root/nested-signal.pid"
signal_status=0
if [ "${NODE_TWO_SCHEMA_CONTRACT_OUTER_SIGNAL_TEST:-}" = enabled ]; then
  : >"${NODE_TWO_SCHEMA_CONTRACT_NESTED_SIGNAL_PID_FILE:?}"
  NODE_TWO_SCHEMA_CONTRACT_OUTER_SIGNAL_TEST= \
    NODE_TWO_SCHEMA_CONTRACT_SIGNAL_TEST=enabled \
    NODE_TWO_SCHEMA_CONTRACT_SIGNAL_READY="$NODE_TWO_SCHEMA_CONTRACT_NESTED_SIGNAL_READY" \
    "$0" >/dev/null 2>&1 &
  signal_pid=$!
  printf '%s\n' "$signal_pid" >"${NODE_TWO_SCHEMA_CONTRACT_NESTED_SIGNAL_PID_FILE:?}"
  for _ in $(seq 1 20); do
    [ -e "$NODE_TWO_SCHEMA_CONTRACT_NESTED_SIGNAL_READY" ] && break
    sleep 0.05
  done
  [ -e "$NODE_TWO_SCHEMA_CONTRACT_NESTED_SIGNAL_READY" ]
  : >"${NODE_TWO_SCHEMA_CONTRACT_OUTER_SIGNAL_READY:?}"
  while :; do sleep 1; done
fi
if [ "${NODE_TWO_SCHEMA_CONTRACT_SIGNAL_TEST:-}" != enabled ] && [ "${NODE_TWO_SCHEMA_CONTRACT_OUTER_SIGNAL_TEST:-}" != enabled ]; then
NODE_TWO_SCHEMA_CONTRACT_OUTER_SIGNAL_TEST=enabled \
  NODE_TWO_SCHEMA_CONTRACT_OUTER_SIGNAL_READY="$outer_signal_ready" \
NODE_TWO_SCHEMA_CONTRACT_NESTED_SIGNAL_READY="$nested_signal_ready" \
  NODE_TWO_SCHEMA_CONTRACT_NESTED_SIGNAL_PID_FILE="$nested_signal_pid_file" \
  TMPDIR="$contract_root" \
  "$0" >/dev/null 2>&1 &
signal_pid=$!
for _ in $(seq 1 20); do
  [ -e "$outer_signal_ready" ] && break
  sleep 0.05
done
[ -e "$outer_signal_ready" ]
kill -TERM "$signal_pid"
wait "$signal_pid" || signal_status=$?
[ "$signal_status" -eq 143 ]
nested_signal_pid=$(cat "$nested_signal_pid_file")
! kill -0 "$nested_signal_pid" 2>/dev/null
! find "$contract_root" -mindepth 1 -maxdepth 1 -type d -name 'plainpost-node-two-schema-contract.*' -print -quit | grep -q .
signal_pid=''
fi
if [ "${NODE_TWO_SCHEMA_CONTRACT_SIGNAL_TEST:-}" = enabled ]; then
  : >"${NODE_TWO_SCHEMA_CONTRACT_SIGNAL_READY:?}"
  while :; do sleep 1; done
fi
signal_ready="$contract_root/signal-ready"
signal_status=0
NODE_TWO_SCHEMA_CONTRACT_SIGNAL_TEST=enabled NODE_TWO_SCHEMA_CONTRACT_SIGNAL_READY="$signal_ready" \
  "$0" >/dev/null 2>&1 &
signal_pid=$!
for _ in $(seq 1 20); do
  [ -e "$signal_ready" ] && break
  sleep 0.05
done
[ -e "$signal_ready" ]
kill -TERM "$signal_pid"
wait "$signal_pid" || signal_status=$?
[ "$signal_status" -eq 143 ]
signal_pid=''
PATH="$contract_root/bin:$PATH" FAKE_DOCKER_CAPTURE="$capture" FAKE_DOCKER_RESULT=passed \
  NODE_TWO_SCHEMA_CHECKPOINT_RELEASE=1 NODE_TWO_SCHEMA_CHECKPOINT_CONTAINER=node-two-db \
  node_one_database_name=restore_0123456789abcdef0123456789abcdef \
  NODE_TWO_SCHEMA_CHECKPOINT_RUNTIME_LOG="$runtime_log" \
  NODE_TWO_SCHEMA_CHECKPOINT=1 "$helper" initial-ready
grep -Fx 'node-two-schema-checkpoint phase=initial-ready status=passed' "$runtime_log" >/dev/null
grep -F -- 'exec node-two-db psql' "$capture" >/dev/null
grep -F -- '-U plainpost_sync_node -d plainpost_sync_node' "$capture" >/dev/null
! grep -F -- 'restore_0123456789abcdef0123456789abcdef' "$capture" >/dev/null
! grep -E 'postgresql://|password|secret|SELECT|node_installation_state' "$runtime_log" >/dev/null

: >"$runtime_log"
PATH="$contract_root/bin:$PATH" FAKE_DOCKER_CAPTURE="$capture" FAKE_DOCKER_RESULT=reset-passed \
  NODE_TWO_SCHEMA_CHECKPOINT_RELEASE=1 NODE_TWO_SCHEMA_CHECKPOINT_CONTAINER=node-two-db \
  NODE_TWO_SCHEMA_CHECKPOINT_RUNTIME_LOG="$runtime_log" NODE_TWO_SCHEMA_CHECKPOINT=1 "$helper" before-privacy-audit
grep -Fx 'node-two-schema-checkpoint phase=before-privacy-audit status=passed state=reset' "$runtime_log" >/dev/null
[ "$(wc -l <"$runtime_log" | tr -d ' ')" -eq 1 ]
! grep -E 'postgresql://|password|secret|SELECT|node_installation_state|node_current_authority_state|node_secrets|node_schema_migrations' "$runtime_log" >/dev/null

owner_summary_output=$(PLAINPOST_SYNC_NODE_NODE_TWO_SCHEMA_SUMMARY_TEST=enabled "$owner" 2>&1 >/dev/null || true)
printf '%s\n' "$owner_summary_output" | grep -Fx 'node_two_schema_failure_summary_begin' >/dev/null
printf '%s\n' "$owner_summary_output" | grep -Fx 'node-two-schema-checkpoint phase=before-privacy-audit status=failed cause=node-installation-state' >/dev/null
printf '%s\n' "$owner_summary_output" | grep -Fx 'node-two-schema-checkpoint phase=before-privacy-audit status=failed cause=reset-probe' >/dev/null
[ "$(printf '%s\n' "$owner_summary_output" | grep -Fc 'node-two-schema-checkpoint phase=before-privacy-audit status=failed cause=reset-probe')" -eq 1 ]
printf '%s\n' "$owner_summary_output" | grep -Fx 'node_two_schema_failure_summary_end' >/dev/null
! printf '%s\n' "$owner_summary_output" | grep -E 'postgresql://|password|secret|SELECT' >/dev/null

for case_spec in \
  'container-missing container-missing' \
  'container-not-running container-not-running' \
  'psql-connect psql-connect' \
  'migration-ledger migration-ledger' \
  'migration-head migration-head' \
  'relation-query relation-query' \
  'node-installation-state node-installation-state' \
  'node-current-authority-state node-current-authority-state' \
  'node-secrets node-secrets' \
  'reset-query reset-query' \
  'reset-probe reset-probe' \
  'reset-mismatch reset-mismatch' \
  'unexpected-output unexpected-output'; do
  fake_case=${case_spec%% *}
  expected_cause=${case_spec#* }
  checkpoint_phase=after-restarts
  case "$fake_case" in
    reset-query|reset-probe|reset-mismatch) checkpoint_phase=before-privacy-audit ;;
  esac
  : >"$runtime_log"
  if PATH="$contract_root/bin:$PATH" FAKE_DOCKER_CAPTURE="$capture" FAKE_DOCKER_RESULT="$fake_case" \
    NODE_TWO_SCHEMA_CHECKPOINT_RELEASE=1 NODE_TWO_SCHEMA_CHECKPOINT_CONTAINER=node-two-db \
    NODE_TWO_SCHEMA_CHECKPOINT_RUNTIME_LOG="$runtime_log" NODE_TWO_SCHEMA_CHECKPOINT=1 "$helper" "$checkpoint_phase"; then
    printf 'schema checkpoint unexpectedly accepted cause=%s\n' "$expected_cause" >&2
    exit 1
  fi
  grep -Fx "node-two-schema-checkpoint phase=$checkpoint_phase status=failed cause=$expected_cause" "$runtime_log" >/dev/null
  [ "$(wc -l <"$runtime_log" | tr -d ' ')" -eq 1 ]
  ! grep -E 'postgresql://|password|secret|SELECT|node_installation_state|node_current_authority_state|node_secrets|node_schema_migrations' "$runtime_log" >/dev/null
done

printf 'sync_node_private_transport_node_schema_contract=passed\n'
