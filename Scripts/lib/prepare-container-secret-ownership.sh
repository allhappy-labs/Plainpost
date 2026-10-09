#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

root=${1:-}
postgres_image=${2:-}
mode=${3:-}
ownership_validation_mode=${4:-exact}
[[ $root == /* && $root != *'/../'* && $root != */.. && $root != *'/./'* && -d $root && ! -L $root ]] || {
  printf 'secret ownership root is unavailable\n' >&2
  exit 1
}
[[ $postgres_image =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] || {
  printf 'secret ownership image must be immutable\n' >&2
  exit 1
}
secret_ownership_token=${PLAINPOST_SECRET_OWNERSHIP_TOKEN:-$RANDOM-$RANDOM-$$}
[[ $secret_ownership_token =~ ^[A-Za-z0-9._-]+$ ]] || {
  printf 'secret ownership token is invalid\n' >&2
  exit 1
}
case $ownership_validation_mode in
exact|local-virtualized) ;;
*)
  printf 'secret ownership validation mode is unsupported\n' >&2
  exit 1
  ;;
esac
if [[ $ownership_validation_mode == local-virtualized && $(uname -s) != Darwin ]]; then
  printf 'local virtualized secret ownership mode requires Darwin\n' >&2
  exit 1
fi
secret_ownership_container="plainpost-secret-ownership-$secret_ownership_token"
if ! existing_ownership_containers=$(docker ps -aq --filter "name=^/$secret_ownership_container$"); then
  printf 'secret ownership container query failed\n' >&2
  exit 1
fi
if [[ -n $existing_ownership_containers ]]; then
  if ! existing_ownership_label=$(docker inspect --format '{{index .Config.Labels "com.plainpost.secret-ownership"}}' "$secret_ownership_container" 2>/dev/null); then
    printf 'secret ownership container label query failed\n' >&2
    exit 1
  fi
  printf 'secret ownership container name is already occupied label=%s\n' "${existing_ownership_label:-unknown}" >&2
  exit 1
fi
cleanup_secret_ownership_container() {
  if ! ownership_containers=$(docker ps -aq --filter "name=^/$secret_ownership_container$"); then
    printf 'secret ownership cleanup container query failed\n' >&2
    return 1
  fi
  [[ -n $ownership_containers ]] || return 0
  if ! ownership_label=$(docker inspect --format '{{index .Config.Labels "com.plainpost.secret-ownership"}}' "$secret_ownership_container" 2>/dev/null); then
    printf 'secret ownership cleanup label query failed\n' >&2
    return 1
  fi
  if ! ownership_token_label=$(docker inspect --format '{{index .Config.Labels "com.plainpost.secret-ownership-token"}}' "$secret_ownership_container" 2>/dev/null); then
    printf 'secret ownership cleanup token query failed\n' >&2
    return 1
  fi
  [[ $ownership_label == 1 && $ownership_token_label == "$secret_ownership_token" ]] || return 0
  if ! docker rm -f "$secret_ownership_container" >/dev/null 2>&1; then
    printf 'secret ownership container cleanup failed\n' >&2
    return 1
  fi
  if ! retained_ownership_containers=$(docker ps -aq --filter "name=^/$secret_ownership_container$"); then
    printf 'secret ownership cleanup recheck failed\n' >&2
    return 1
  fi
  if [[ -n $retained_ownership_containers ]]; then
    printf 'secret ownership container cleanup retained the owned container\n' >&2
    return 1
  fi
}
on_secret_ownership_signal() {
  trap - EXIT HUP INT TERM
  cleanup_secret_ownership_container
  exit "$1"
}
trap cleanup_secret_ownership_container EXIT
trap 'on_secret_ownership_signal 129' HUP
trap 'on_secret_ownership_signal 130' INT
trap 'on_secret_ownership_signal 143' TERM

app_paths=''
postgres_paths=''
audit_only=0
case $mode in
private-release)
  app_paths='
central-secrets/central-database-url
central-secrets/central-deletion-journal-database-url
central-secrets/rate-limit-pepper
node-one-secrets/database_url
node-one-secrets/audit_database_url
node-one-secrets/restore_admin_database_url
node-one-secrets/restore_stage_database_url
node-one-secrets/master_key
node-one-secrets/backup_key
node-one-secrets/client_tls_cert
node-one-secrets/client_tls_key
node-one-secrets/provider_password
node-one-secrets/s3_access
node-one-secrets/s3_secret
node-two-secrets/database_url
node-two-secrets/restore_admin_database_url
node-two-secrets/restore_stage_database_url
node-two-secrets/master_key
node-two-secrets/backup_key
node-two-secrets/client_tls_cert
node-two-secrets/client_tls_key
node-two-secrets/provider_password
node-two-secrets/s3_access
node-two-secrets/s3_secret'
  postgres_paths='
central-secrets/postgres-superuser-password
central-secrets/node-bootstrap-password
central-secrets/central-db-password
central-secrets/node-db-password
central-secrets/restore-admin-db-password
central-secrets/restore-stage-db-password'
  ;;
native-release)
  app_paths='
secrets/central-database-url
secrets/central-deletion-journal-database-url
secrets/central-rate-limit-pepper
secrets/central-notification-token-keyring
secrets/central-apns-signing-key.p8
secrets/central-tls.key
secrets/account-identity-pepper
secrets/account-online-keys.json
secrets/account-pagination-keys.json
secrets/account-recovery-keys.json
secrets/session-access-keys.json
secrets/session-offline-keys.json
secrets/node-enrollment-replay-keys.json
secrets/node-database-url
secrets/node-restore-admin-database-url
secrets/node-restore-stage-database-url
secrets/node-master-key
secrets/node-backup-key
secrets/node-google-calendar-oauth-client-secret
secrets/node-tls.key'
  postgres_paths='
secrets/postgres-superuser-password
secrets/postgres-server.key
secrets/central-db-password
secrets/node-db-password
secrets/backup-db-password
secrets/restore-admin-db-password
secrets/restore-stage-db-password'
  ;;
private-release-audit)
  app_paths='
node-one-secrets/audit_database_url.pending'
  audit_only=1
  ;;
*)
  printf 'secret ownership mode is unsupported\n' >&2
  exit 1
  ;;
esac

if [[ $ownership_validation_mode == local-virtualized ]]; then
  local_file_mode() {
    stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
  }

  local_validate_paths() {
    local path file
    for path in $app_paths $postgres_paths; do
      file="$root/$path"
      [[ -f $file && ! -L $file ]] || {
        printf 'local virtualized secret is not a regular non-symlink file\n' >&2
        return 1
      }
      [[ $(local_file_mode "$file") == 600 ]] || {
        printf 'local virtualized secret is not mode 0600\n' >&2
        return 1
      }
    done
  }

  local_probe_readability() {
    local user=$1 paths=$2
    [[ -n $paths ]] || return 0
    docker run --rm --pull never \
      --user "$user:$user" --entrypoint /bin/sh \
      --mount "type=bind,src=$root,dst=/fixture,readonly" "$postgres_image" -ec '
      set -eu
      paths=$1
      for path in $paths; do
        test -f "/fixture/$path"
        test ! -L "/fixture/$path"
        cat "/fixture/$path" >/dev/null
      done
    ' sh "$paths"
  }

  local_validate_paths
  if [[ $audit_only == 1 ]]; then
    audit_pending="$root/node-one-secrets/audit_database_url.pending"
    audit_final="$root/node-one-secrets/audit_database_url"
    [[ -f $audit_final && ! -L $audit_final ]] || {
      printf 'local virtualized audit destination is not a regular non-symlink file\n' >&2
      exit 1
    }
    [[ $(local_file_mode "$audit_final") == 600 ]] || {
      printf 'local virtualized audit destination is not mode 0600\n' >&2
      exit 1
    }
    audit_final_owner=$(stat -f '%u' "$audit_final" 2>/dev/null || stat -c '%u' "$audit_final")
    audit_final_links=$(stat -f '%l' "$audit_final" 2>/dev/null || stat -c '%h' "$audit_final")
    [[ $audit_final_links == 1 ]] || {
      printf 'local virtualized audit destination has unexpected link count\n' >&2
      exit 1
    }
    [[ -s $audit_pending ]] || {
      printf 'local virtualized audit pending file is empty\n' >&2
      exit 1
    }
    if ! local_probe_readability 65532 'node-one-secrets/audit_database_url.pending'; then
      exit 1
    fi
    if ! cat "$audit_pending" >"$audit_final" || ! sync; then
      printf 'local virtualized audit promotion failed\n' >&2
      exit 1
    fi
    [[ -f $audit_final && ! -L $audit_final ]] || {
      printf 'local virtualized audit promotion did not install final file\n' >&2
      exit 1
    }
    [[ $(local_file_mode "$audit_final") == 600 ]] || {
      printf 'local virtualized audit promotion changed final mode\n' >&2
      exit 1
    }
    audit_promoted_owner=$(stat -f '%u' "$audit_final" 2>/dev/null || stat -c '%u' "$audit_final")
    audit_promoted_links=$(stat -f '%l' "$audit_final" 2>/dev/null || stat -c '%h' "$audit_final")
    [[ $audit_promoted_owner == "$audit_final_owner" && $audit_promoted_links == 1 && -s $audit_final ]] || {
      printf 'local virtualized audit promotion changed final ownership or size\n' >&2
      exit 1
    }
    local_probe_readability 65532 'node-one-secrets/audit_database_url' || {
      printf 'local virtualized audit promotion final file is unreadable\n' >&2
      exit 1
    }
    rm -f -- "$audit_pending"
    exit 0
  fi
  local_probe_readability 65532 "$app_paths"
  local_probe_readability 70 "$postgres_paths"
  exit 0
fi

docker run --rm --pull never --name "$secret_ownership_container" \
  --label com.plainpost.secret-ownership=1 \
  --label com.plainpost.secret-ownership-token="$secret_ownership_token" \
  --user 0:0 --entrypoint /bin/sh \
  --mount "type=bind,src=$root,dst=/fixture" "$postgres_image" -ec '
  set -eu
  app_paths=$1
  postgres_paths=$2
  audit_only=$3
  for path in $app_paths; do
    test -f "/fixture/$path"
    test ! -L "/fixture/$path"
    chown 65532:65532 "/fixture/$path"
    test "$(stat -c "%u:%g %a" "/fixture/$path")" = "65532:65532 600"
  done
  if [ "$audit_only" = 1 ]; then
    test -f /fixture/node-one-secrets/audit_database_url.pending
    test ! -L /fixture/node-one-secrets/audit_database_url.pending
    test -s /fixture/node-one-secrets/audit_database_url.pending
    test -f /fixture/node-one-secrets/audit_database_url
    test ! -L /fixture/node-one-secrets/audit_database_url
    chown 65532:65532 /fixture/node-one-secrets/audit_database_url
    chmod 600 /fixture/node-one-secrets/audit_database_url
    test "$(stat -c "%u:%g %a %h" /fixture/node-one-secrets/audit_database_url)" = "65532:65532 600 1"
    chown 65532:65532 /fixture/node-one-secrets/audit_database_url.pending
    chmod 600 /fixture/node-one-secrets/audit_database_url.pending
    test "$(stat -c "%u:%g %a" /fixture/node-one-secrets/audit_database_url.pending)" = "65532:65532 600"
    mv -f /fixture/node-one-secrets/audit_database_url.pending /fixture/node-one-secrets/audit_database_url
    test -f /fixture/node-one-secrets/audit_database_url
    test ! -L /fixture/node-one-secrets/audit_database_url
    test -s /fixture/node-one-secrets/audit_database_url
    test "$(stat -c "%u:%g %a %h" /fixture/node-one-secrets/audit_database_url)" = "65532:65532 600 1"
    cat /fixture/node-one-secrets/audit_database_url >/dev/null
    test ! -e /fixture/node-one-secrets/audit_database_url.pending
  fi
  for path in $postgres_paths; do
    test -f "/fixture/$path"
    test ! -L "/fixture/$path"
    chown 70:70 "/fixture/$path"
    test "$(stat -c "%u:%g %a" "/fixture/$path")" = "70:70 600"
  done
' sh "$app_paths" "$postgres_paths" "$audit_only"
