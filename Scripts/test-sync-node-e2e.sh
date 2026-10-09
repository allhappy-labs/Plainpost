#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Local release owner. It validates and executes the repository-owned
# immutable release/TLS owner. The historical health-only blocker remains in
# this wrapper's diagnostic vocabulary for older callers, but cannot turn
# health evidence into acceptance.
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
compose="$root/Deploy/sync-node/compose.unraid.yml"
native_tls_owner="$root/Deploy/sync-node/scripts/exercise-unraid-native-tls.sh"
release_image_owner="$root/Scripts/test-sync-node-release-images.sh"
release_verifier="$root/Deploy/sync-node/scripts/verify-release.sh"
project="plainpost-sync-node-e2e-${PPID:-0}-$$"
temporary=$(mktemp -d "${TMPDIR:-/private/tmp}/plainpost-sync-node-e2e.XXXXXX")
temporary=$(CDPATH= cd -- "$temporary" && pwd -P)
umask 077
mkdir -m 0700 "$temporary/secrets"

status_label=INCOMPLETE
cleanup_running=0
cleanup_status=0
cleanup_categories=''
compose_started=0
stage_log="$temporary/stages.log"

# This vocabulary is intentionally closed. A line is written only by
# record_stage after the corresponding repository-owned operation succeeds.
required_stage_lines=(
  "stage=postgres-isolation"
  "stage=tls-readiness"
  "stage=native-enrollment"
  "stage=gmail-sync"
  "stage=client-api-content"
  "stage=client-api-mutations"
  "stage=restart-recovery"
  "stage=backup-restore"
  "stage=replacement-fence"
  "stage=notification"
  "stage=erase"
  "stage=privacy-network"
  "stage=cleanup"
)

cleanup_failure() {
  case " $cleanup_categories " in
    *" $1 "*) ;;
    *)
      cleanup_categories="$cleanup_categories $1"
      printf 'cleanup failure category=%s\n' "$1" >&2
      ;;
  esac
  cleanup_status=1
}

cleanup() {
  local original_status=$?
  if [ "$cleanup_running" -eq 1 ]; then
    cleanup_failure reentry
    return
  fi
  cleanup_running=1

  if [ "$compose_started" -eq 1 ]; then
    if ! compose_run down --volumes --remove-orphans >/dev/null 2>&1; then
      cleanup_failure compose-down
    fi
    retained_containers=$(docker ps -aq --filter "label=com.docker.compose.project=$project" 2>/dev/null || true)
    [ -z "$retained_containers" ] || cleanup_failure containers-retained
    retained_volumes=$(docker volume ls -q --filter "label=com.docker.compose.project=$project" 2>/dev/null || true)
    [ -z "$retained_volumes" ] || cleanup_failure volumes-retained
    retained_networks=$(docker network ls -q --filter "label=com.docker.compose.project=$project" 2>/dev/null || true)
    [ -z "$retained_networks" ] || cleanup_failure networks-retained
  fi

  if [ -e "$temporary" ]; then
    if ! find "$temporary" -depth -delete >/dev/null 2>&1; then
      cleanup_failure private-temp
    fi
  fi
  [ ! -e "$temporary" ] || cleanup_failure private-temp-retained
  cleanup_running=0

  # Cleanup is an evidence stage only after all exact cleanup checks finish.
  if [ "$cleanup_status" -eq 0 ]; then
    printf 'stage=cleanup\n'
  fi
  if [ "$cleanup_status" -ne 0 ]; then
    original_status=1
  fi
  printf 'status=incomplete reason=%s\n' "${incomplete_reason:-cleanup-finished-without-acceptance}"
  printf 'Sync Node Unraid local acceptance %s\n' "$status_label"
  trap - EXIT
  exit "$original_status"
}
trap cleanup EXIT
# Signals terminate through EXIT so the same project/temp cleanup is applied.
trap 'exit 130' HUP INT TERM

record_stage() {
  local name=$1
  printf 'stage=%s\n' "$name"
  printf 'stage=%s\n' "$name" >>"$stage_log"
}

credential_file_ready() {
  local path=$1 mode
  [ -n "$path" ] && [ "$path" = /* ] && [ -f "$path" ] && [ ! -L "$path" ] || return 1
  mode=$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path" 2>/dev/null || true)
  [ "$mode" = 600 ]
}

incomplete() {
  incomplete_reason=$1
  exit 2
}

# Only the documented non-secret release variables are exported. This parses
# lines as data; it never sources/evaluates the caller-owned env file.
load_release_environment() {
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    [[ "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || return 1
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      PLAINPOST_BUNDLE_ROOT|PLAINPOST_SECRET_ROOT|PLAINPOST_PUBLIC_ROOT|PLAINPOST_POSTGRES_DATA_ROOT|PLAINPOST_NODE_DATA_ROOT|PLAINPOST_NODE_ATTACHMENTS_ROOT|PLAINPOST_BACKUP_ROOT|PLAINPOST_RECEIPTS_ROOT|PLAINPOST_TAILSCALE_IPV4|PLAINPOST_TAILSCALE_HOSTNAME|PLAINPOST_CENTRAL_IMAGE|PLAINPOST_NODE_IMAGE|PLAINPOST_NODE_MASTER_KEY_VERSION|PLAINPOST_NODE_ATTACHMENT_QUOTA_BYTES|PLAINPOST_ACCOUNT_OFFLINE_ROOT_KEY_ID|PLAINPOST_SESSION_OFFLINE_ROOT_KEY_ID|PLAINPOST_NODE_ENROLLMENT_CENTRAL_AUDIENCE|PLAINPOST_ACCOUNT_APPLE_MACOS_AUDIENCE|PLAINPOST_ACCOUNT_APPLE_IOS_AUDIENCE|PLAINPOST_ACCOUNT_APPLE_IPADOS_AUDIENCE)
        export "$key=$value"
        ;;
      *) return 1 ;;
    esac
  done <"$release_env"
}

# Missing or unsafe credentials terminate before any release operation.
if [ "${PLAINPOST_RUN_GMAIL_E2E:-}" != 1 ]; then
  incomplete gmail-e2e-disabled
fi
if ! credential_file_ready "${PLAINPOST_GMAIL_CREDENTIALS_FILE:-}" || ! credential_file_ready "${PLAINPOST_GMAIL_TOKEN_FILE:-}"; then
  incomplete gmail-credentials-missing-or-unsafe
fi
if ! command -v python3 >/dev/null 2>&1; then
  incomplete python3-unavailable-for-credential-parse
fi
if ! python3 -m json.tool "$PLAINPOST_GMAIL_CREDENTIALS_FILE" >/dev/null 2>"$temporary/gmail-credentials-parse.log" || ! python3 -m json.tool "$PLAINPOST_GMAIL_TOKEN_FILE" >/dev/null 2>"$temporary/gmail-token-parse.log"; then
  incomplete gmail-credentials-invalid-json
fi

release_env=${PLAINPOST_SYNC_NODE_RELEASE_ENV_FILE:-}
release_dir=${PLAINPOST_SYNC_NODE_RELEASE_DIR:-}
if [ -z "$release_env" ] || [ "$release_env" != /* ] || [ ! -f "$release_env" ] || [ -L "$release_env" ]; then
  incomplete release-environment-missing
fi
if [ -z "$release_dir" ] || [ "$release_dir" != /* ] || [ "$release_dir" = *'/../'* ] || [ "$release_dir" = */.. ] || [ "$release_dir" = *'/./'* ] || [ ! -d "$release_dir" ] || [ -L "$release_dir" ]; then
  incomplete release-artifacts-missing
fi
if [ ! -f "$compose" ] || [ -L "$compose" ] || [ ! -f "$native_tls_owner" ] || [ -L "$native_tls_owner" ] || [ ! -f "$release_image_owner" ] || [ -L "$release_image_owner" ] || [ ! -f "$release_verifier" ] || [ -L "$release_verifier" ]; then
  incomplete release-owner-assets-missing
fi
database_init="$root/Deploy/sync-node/postgres/init/010-plainpost-databases.sh"
if [ ! -f "$database_init" ] || [ -L "$database_init" ] || ! grep -Fq 'CREATE DATABASE plainpost_central' "$database_init" || ! grep -Fq 'CREATE DATABASE plainpost_sync_node' "$database_init"; then
  incomplete release-postgres-two-database-shape-invalid
fi
if ! load_release_environment; then
  incomplete release-environment-unsafe
fi

# These are the only Compose entry points owned by this wrapper. The first
# operation is offline release verification; no remote command is possible.
compose_run() {
  docker compose --project-name "$project" --env-file "$release_env" -f "$compose" "$@"
}

if ! bash "$release_verifier" "$release_dir" >"$temporary/release-verify.log" 2>&1; then
  incomplete release-artifacts-failed-verification
fi

# Render and inspect the exact production Compose shape before starting it.
if ! command -v jq >/dev/null 2>&1; then
  incomplete jq-unavailable-for-compose-shape
fi
if ! compose_run config --format json >"$temporary/compose.json" 2>"$temporary/compose-error.log"; then
  incomplete release-compose-render-failed
fi
if ! jq -e '
  (.services | keys | sort) == ["central", "postgres", "sync-node"] and
  ([.services | to_entries[] | select(.key == "postgres")] | length) == 1 and
  .services.central.environment.PLAINPOST_DATABASE_URL_FILE == "/run/secrets/central-database-url" and
  .services.sync-node.environment.PLAINPOST_NODE_DATABASE_URL_FILE == "/run/secrets/node-database-url" and
  .services.central.environment.PLAINPOST_DATABASE_URL_FILE != .services.sync-node.environment.PLAINPOST_NODE_DATABASE_URL_FILE and
  (.services.postgres.ports // []) == [] and
  .networks."postgres-internal".internal == true
' "$temporary/compose.json" >/dev/null; then
  incomplete release-compose-shape-invalid
fi

# Task 11 is opt-in because it is the slower exact-OCI path. It receives only
# the prepared fixture tree as data; the release owner verifies artifacts and
# binds both OCI archives to their manifest digests before Compose startup.
if [ "${PLAINPOST_RUN_RELEASE_IMAGE_ACCEPTANCE:-0}" = 1 ]; then
  if ! PLAINPOST_RELEASE_DIR="$release_dir" \
    PLAINPOST_RELEASE_FIXTURE_TEMPLATE="$temporary" \
    bash "$release_image_owner" "$release_dir" >"$temporary/release-images.log" 2>&1; then
    incomplete release-image-owner-blocked
  fi
fi

# This is a real repository-owned release/TLS exercise. Its own trap removes
# its Compose project. Its output stays in the private temporary tree.
if ! bash "$native_tls_owner" "$release_dir" >"$temporary/native-tls.log" 2>&1; then
  incomplete native-tls-owner-blocked
fi
record_stage postgres-isolation
record_stage tls-readiness

# Do not claim native enrollment, Gmail, clients, restart, backup/restore,
# replacement, notification, erase, or privacy acceptance. The production
# code has no repository-owned runner that drives those operations against the
# release Compose project; the existing owner stops at healthz by design.
incomplete 'production release has no repository-owned Gmail/client scenario runner; exercise-unraid-native-tls.sh stops after TLS healthz'
