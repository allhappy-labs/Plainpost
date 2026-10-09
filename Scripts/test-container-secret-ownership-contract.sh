#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
helper="$root/Scripts/lib/prepare-container-secret-ownership.sh"
release_owner="$root/Scripts/test-sync-node-release-images.sh"
native_owner="$root/Scripts/test-sync-node-native-tls-release.sh"
private_owner="$root/Scripts/test-sync-node-private-transport.sh"
fixture=$(mktemp -d /private/tmp/plainpost-secret-ownership-contract.XXXXXX)
cleanup() {
  find "$fixture" -depth -delete >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'secret ownership contract: %s\n' "$*" >&2
  exit 1
}

[[ -x "$helper" && -x "$release_owner" && -x "$native_owner" && -x "$private_owner" ]] ||
  fail 'secret ownership assets are unavailable'

fake_bin="$fixture/bin"
mkdir -m 0700 "$fake_bin"
fake_docker="$fake_bin/docker"
docker_log="$fixture/docker.log"
docker_state="$fixture/docker-container.state"
cat >"$fake_docker" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$PLAINPOST_SECRET_OWNERSHIP_TEST_LOG"
state_file=${PLAINPOST_SECRET_OWNERSHIP_TEST_STATE:?}
[ "$#" -gt 0 ] || exit 23
case "$1" in
  inspect)
    [ -e "$state_file" ] || exit 1
    case "$*" in
      *secret-ownership-token*) printf '%s\n' "${PLAINPOST_SECRET_OWNERSHIP_TOKEN:-}" ;;
      *secret-ownership*) printf '1\n' ;;
      *) : ;;
    esac
    exit 0
    ;;
  ps)
    [ "${PLAINPOST_SECRET_OWNERSHIP_TEST_PS_FAIL:-}" = 1 ] && exit 27
    [ -e "$state_file" ] && printf 'ownership-container-id\n'
    exit 0
    ;;
  run)
    user=''
    expect_user=0
    name=''
    expect_name=0
    for argument in "$@"; do
      if [ "$expect_user" -eq 1 ]; then
        user=$argument
        expect_user=0
      elif [ "$expect_name" -eq 1 ]; then
        name=$argument
        expect_name=0
      elif [ "$argument" = --user ]; then
        expect_user=1
      elif [ "$argument" = --name ]; then
        expect_name=1
      fi
    done
    if [ "$PLAINPOST_SECRET_OWNERSHIP_TEST_FAIL_USER" = "$user" ]; then
      exit 19
    fi
    case "$user" in
      65532:65532|70:70)
        case "$*" in
          *'cat "/fixture/'*) exit 0 ;;
          *) exit 21 ;;
        esac
        ;;
      0:0)
        [ -n "$name" ] && : >"$state_file"
        exit 0
        ;;
      *)
        exit 22
        ;;
    esac
    ;;
  rm)
    rm -f "$state_file"
    exit 0
    ;;
  *)
    exit 23
    ;;
esac
SH
chmod 0700 "$fake_docker"
fake_uname="$fake_bin/uname"
cat >"$fake_uname" <<'SH'
#!/bin/sh
printf '%s\n' "${PLAINPOST_SECRET_OWNERSHIP_TEST_UNAME:-Darwin}"
SH
chmod 0700 "$fake_uname"
export PLAINPOST_SECRET_OWNERSHIP_TEST_UNAME=Darwin

image='postgres:18.6-alpine3.24@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
app_paths='
secrets/central-database-url
secrets/central-deletion-journal-database-url
secrets/central-rate-limit-pepper
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
mkdir -m 0700 "$fixture/secrets"
for path in $app_paths $postgres_paths; do
  printf '%s\n' fixture-secret >"$fixture/$path"
  chmod 0600 "$fixture/$path"
done

# The default path must retain exact in-container ownership checks.
: >"$docker_log"
PATH="$fake_bin:$PATH" PLAINPOST_SECRET_OWNERSHIP_TEST_LOG="$docker_log" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_STATE="$docker_state" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_FAIL_USER='' PLAINPOST_SECRET_OWNERSHIP_TOKEN=exact \
  bash "$helper" "$fixture" "$image" native-release
grep -F -- '--user 0:0' "$docker_log" >/dev/null
grep -F -- 'chown 65532:65532' "$docker_log" >/dev/null
grep -F -- '65532:65532 600' "$docker_log" >/dev/null
grep -F -- 'chown 70:70' "$docker_log" >/dev/null
grep -F -- '70:70 600' "$docker_log" >/dev/null
[[ ! -e "$docker_state" ]] || fail 'owned helper container cleanup did not prove absence'

# The explicit virtualized mode must use separate non-root readability probes.
: >"$docker_log"
PATH="$fake_bin:$PATH" PLAINPOST_SECRET_OWNERSHIP_TEST_LOG="$docker_log" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_STATE="$docker_state" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_FAIL_USER='' PLAINPOST_SECRET_OWNERSHIP_TOKEN=local \
  bash "$helper" "$fixture" "$image" native-release local-virtualized
[[ $(grep -c -- '--user 65532:65532' "$docker_log") -eq 1 ]]
[[ $(grep -c -- '--user 70:70' "$docker_log") -eq 1 ]]
if grep -F -- '--user 0:0' "$docker_log" >/dev/null; then
  fail 'local-virtualized mode starts a root ownership probe'
fi
grep -F -- 'cat "/fixture/' "$docker_log" >/dev/null
local_probe_source=$(awk '/^  local_probe_readability\(\)/,/^  \}/' "$helper")
grep -F -- 'docker run --rm --pull never' <<<"$local_probe_source" >/dev/null ||
  fail 'local readability probes are not synchronous --rm containers'
if grep -F -- '--name' <<<"$local_probe_source" >/dev/null; then
  fail 'local readability probes retain named containers'
fi

if PATH="$fake_bin:$PATH" PLAINPOST_SECRET_OWNERSHIP_TEST_LOG="$docker_log" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_STATE="$docker_state" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_UNAME=Linux PLAINPOST_SECRET_OWNERSHIP_TEST_FAIL_USER='' \
  PLAINPOST_SECRET_OWNERSHIP_TOKEN=off-darwin \
  bash "$helper" "$fixture" "$image" native-release local-virtualized; then
  fail 'local-virtualized mode was accepted off Darwin'
fi

# Mode and file-type checks happen before any Docker readability claim.
chmod 0644 "$fixture/secrets/account-identity-pepper"
if PATH="$fake_bin:$PATH" PLAINPOST_SECRET_OWNERSHIP_TEST_LOG="$docker_log" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_STATE="$docker_state" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_FAIL_USER='' PLAINPOST_SECRET_OWNERSHIP_TOKEN=bad-mode \
  bash "$helper" "$fixture" "$image" native-release local-virtualized; then
  fail 'local-virtualized mode accepted a non-0600 file'
fi
chmod 0600 "$fixture/secrets/account-identity-pepper"
mv "$fixture/secrets/node-master-key" "$fixture/secrets/node-master-key.real"
ln -s node-master-key.real "$fixture/secrets/node-master-key"
if PATH="$fake_bin:$PATH" PLAINPOST_SECRET_OWNERSHIP_TEST_LOG="$docker_log" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_STATE="$docker_state" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_FAIL_USER='' PLAINPOST_SECRET_OWNERSHIP_TOKEN=bad-link \
  bash "$helper" "$fixture" "$image" native-release local-virtualized; then
  fail 'local-virtualized mode accepted a symlink'
fi
rm "$fixture/secrets/node-master-key"
mv "$fixture/secrets/node-master-key.real" "$fixture/secrets/node-master-key"

# Separate probe failure must fail the opt-in rather than widening permissions.
if PATH="$fake_bin:$PATH" PLAINPOST_SECRET_OWNERSHIP_TEST_LOG="$docker_log" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_STATE="$docker_state" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_FAIL_USER=65532:65532 PLAINPOST_SECRET_OWNERSHIP_TOKEN=unreadable \
  bash "$helper" "$fixture" "$image" native-release local-virtualized; then
  fail 'local-virtualized mode ignored failed uid-65532 readability'
fi
for path in $app_paths $postgres_paths; do
  [[ $(stat -f '%Lp' "$fixture/$path" 2>/dev/null || stat -c '%a' "$fixture/$path") = 600 ]] ||
    fail "local probe widened mode for $path"
done

# private-release-audit must promote into a validated stable final leaf,
# retain mode 0600, and leave the final path readable after promotion.
audit_fixture="$fixture/audit"
mkdir -p "$audit_fixture/node-one-secrets"
chmod 0700 "$audit_fixture" "$audit_fixture/node-one-secrets"
printf '%s\n' pending-secret >"$audit_fixture/node-one-secrets/audit_database_url.pending"
chmod 0600 "$audit_fixture/node-one-secrets/audit_database_url.pending"
: >"$audit_fixture/node-one-secrets/audit_database_url"
chmod 0600 "$audit_fixture/node-one-secrets/audit_database_url"
: >"$docker_log"
PATH="$fake_bin:$PATH" PLAINPOST_SECRET_OWNERSHIP_TEST_LOG="$docker_log" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_STATE="$docker_state" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_FAIL_USER='' PLAINPOST_SECRET_OWNERSHIP_TOKEN=audit \
  bash "$helper" "$audit_fixture" "$image" private-release-audit local-virtualized
[[ -f "$audit_fixture/node-one-secrets/audit_database_url" ]]
[[ ! -e "$audit_fixture/node-one-secrets/audit_database_url.pending" ]]
[[ ! -L "$audit_fixture/node-one-secrets/audit_database_url" ]]
[[ $(stat -f '%Lp' "$audit_fixture/node-one-secrets/audit_database_url" 2>/dev/null || stat -c '%a' "$audit_fixture/node-one-secrets/audit_database_url") = 600 ]]
cat "$audit_fixture/node-one-secrets/audit_database_url" >/dev/null
grep -F -- '--user 65532:65532' "$docker_log" >/dev/null

audit_existing_fixture="$fixture/audit-existing"
mkdir -p "$audit_existing_fixture/node-one-secrets"
chmod 0700 "$audit_existing_fixture" "$audit_existing_fixture/node-one-secrets"
printf '%s\n' pending-secret >"$audit_existing_fixture/node-one-secrets/audit_database_url.pending"
chmod 0600 "$audit_existing_fixture/node-one-secrets/audit_database_url.pending"
printf '%s\n' existing-secret >"$audit_existing_fixture/node-one-secrets/audit_database_url"
chmod 0600 "$audit_existing_fixture/node-one-secrets/audit_database_url"
PATH="$fake_bin:$PATH" PLAINPOST_SECRET_OWNERSHIP_TEST_LOG="$docker_log" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_STATE="$docker_state" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_FAIL_USER='' PLAINPOST_SECRET_OWNERSHIP_TOKEN=audit-existing \
  bash "$helper" "$audit_existing_fixture" "$image" private-release-audit local-virtualized
grep -Fx 'pending-secret' "$audit_existing_fixture/node-one-secrets/audit_database_url" >/dev/null
cat "$audit_existing_fixture/node-one-secrets/audit_database_url" >/dev/null
[[ ! -e "$audit_existing_fixture/node-one-secrets/audit_database_url.pending" ]] ||
  fail 'safe preexisting audit final was not updated'

audit_existing_failure_fixture="$fixture/audit-existing-failure"
mkdir -p "$audit_existing_failure_fixture/node-one-secrets"
chmod 0700 "$audit_existing_failure_fixture" "$audit_existing_failure_fixture/node-one-secrets"
printf '%s\n' pending-secret >"$audit_existing_failure_fixture/node-one-secrets/audit_database_url.pending"
chmod 0600 "$audit_existing_failure_fixture/node-one-secrets/audit_database_url.pending"
printf '%s\n' existing-secret >"$audit_existing_failure_fixture/node-one-secrets/audit_database_url"
chmod 0600 "$audit_existing_failure_fixture/node-one-secrets/audit_database_url"
if PATH="$fake_bin:$PATH" PLAINPOST_SECRET_OWNERSHIP_TEST_LOG="$docker_log" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_STATE="$docker_state" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_FAIL_USER=65532:65532 PLAINPOST_SECRET_OWNERSHIP_TOKEN=audit-existing-failure \
  bash "$helper" "$audit_existing_failure_fixture" "$image" private-release-audit local-virtualized; then
  fail 'audit accepted a failed probe with a preexisting final'
fi
grep -Fx 'existing-secret' "$audit_existing_failure_fixture/node-one-secrets/audit_database_url" >/dev/null
grep -Fx 'pending-secret' "$audit_existing_failure_fixture/node-one-secrets/audit_database_url.pending" >/dev/null

audit_probe_failure_fixture="$fixture/audit-probe-failure"
mkdir -p "$audit_probe_failure_fixture/node-one-secrets"
chmod 0700 "$audit_probe_failure_fixture" "$audit_probe_failure_fixture/node-one-secrets"
printf '%s\n' pending-secret >"$audit_probe_failure_fixture/node-one-secrets/audit_database_url.pending"
chmod 0600 "$audit_probe_failure_fixture/node-one-secrets/audit_database_url.pending"
if PATH="$fake_bin:$PATH" PLAINPOST_SECRET_OWNERSHIP_TEST_LOG="$docker_log" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_STATE="$docker_state" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_FAIL_USER=65532:65532 PLAINPOST_SECRET_OWNERSHIP_TOKEN=audit-probe-failure \
  bash "$helper" "$audit_probe_failure_fixture" "$image" private-release-audit local-virtualized; then
  fail 'audit accepted a failed temporary-file readability probe'
fi
[[ ! -e "$audit_probe_failure_fixture/node-one-secrets/audit_database_url" &&
   ! -L "$audit_probe_failure_fixture/node-one-secrets/audit_database_url" ]] ||
  fail 'failed audit probe promoted a final path'
grep -Fx 'pending-secret' "$audit_probe_failure_fixture/node-one-secrets/audit_database_url.pending" >/dev/null

# A promotion command that returns success without installing the final leaf
# must still fail closed; otherwise the later privacy audit only reports the
# opaque missing-open category.
audit_noop_fixture="$fixture/audit-noop-promotion"
mkdir -p "$audit_noop_fixture/node-one-secrets"
chmod 0700 "$audit_noop_fixture" "$audit_noop_fixture/node-one-secrets"
printf '%s\n' pending-secret >"$audit_noop_fixture/node-one-secrets/audit_database_url.pending"
chmod 0600 "$audit_noop_fixture/node-one-secrets/audit_database_url.pending"
: >"$audit_noop_fixture/node-one-secrets/audit_database_url"
chmod 0600 "$audit_noop_fixture/node-one-secrets/audit_database_url"
noop_cat="$fake_bin/cat"
cat >"$noop_cat" <<'SH'
#!/bin/sh
case "$*" in
  *audit_database_url.pending*) exit 0 ;;
  *) exec /bin/cat "$@" ;;
esac
SH
chmod 0700 "$noop_cat"
if PATH="$fake_bin:$PATH" PLAINPOST_SECRET_OWNERSHIP_TEST_LOG="$docker_log" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_STATE="$docker_state" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_FAIL_USER='' PLAINPOST_SECRET_OWNERSHIP_TEST_TOKEN=audit-noop \
  bash "$helper" "$audit_noop_fixture" "$image" private-release-audit local-virtualized; then
  fail 'successful no-op audit promotion was accepted'
fi
[[ -f "$audit_noop_fixture/node-one-secrets/audit_database_url" &&
   ! -L "$audit_noop_fixture/node-one-secrets/audit_database_url" ]] ||
  fail 'no-op audit promotion removed the stable final path'
[[ ! -s "$audit_noop_fixture/node-one-secrets/audit_database_url" ]] ||
  fail 'no-op audit promotion unexpectedly wrote final data'
grep -Fx 'pending-secret' "$audit_noop_fixture/node-one-secrets/audit_database_url.pending" >/dev/null
rm -f "$noop_cat"

if PATH="$fake_bin:$PATH" PLAINPOST_SECRET_OWNERSHIP_TEST_LOG="$docker_log" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_STATE="$docker_state" PLAINPOST_SECRET_OWNERSHIP_TEST_PS_FAIL=1 \
  PLAINPOST_SECRET_OWNERSHIP_TEST_FAIL_USER='' PLAINPOST_SECRET_OWNERSHIP_TEST_UNAME=Darwin \
  PLAINPOST_SECRET_OWNERSHIP_TOKEN=query-failure bash "$helper" "$fixture" "$image" native-release; then
  fail 'ownership accepted a failed exact container query'
fi

audit_symlink_fixture="$fixture/audit-symlink"
mkdir -p "$audit_symlink_fixture/node-one-secrets"
chmod 0700 "$audit_symlink_fixture" "$audit_symlink_fixture/node-one-secrets"
printf '%s\n' pending-secret >"$audit_symlink_fixture/node-one-secrets/audit_database_url.pending.real"
chmod 0600 "$audit_symlink_fixture/node-one-secrets/audit_database_url.pending.real"
ln -s audit_database_url.pending.real "$audit_symlink_fixture/node-one-secrets/audit_database_url.pending"
if PATH="$fake_bin:$PATH" PLAINPOST_SECRET_OWNERSHIP_TEST_LOG="$docker_log" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_STATE="$docker_state" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_FAIL_USER='' PLAINPOST_SECRET_OWNERSHIP_TOKEN=audit-pending-link \
  bash "$helper" "$audit_symlink_fixture" "$image" private-release-audit local-virtualized; then
  fail 'local virtualized audit accepted a symlink pending path'
fi
[[ -L "$audit_symlink_fixture/node-one-secrets/audit_database_url.pending" ]] ||
  fail 'audit symlink pending path was modified'

audit_final_link_fixture="$fixture/audit-final-link"
mkdir -p "$audit_final_link_fixture/node-one-secrets"
chmod 0700 "$audit_final_link_fixture" "$audit_final_link_fixture/node-one-secrets"
printf '%s\n' pending-secret >"$audit_final_link_fixture/node-one-secrets/audit_database_url.pending"
chmod 0600 "$audit_final_link_fixture/node-one-secrets/audit_database_url.pending"
printf '%s\n' existing-secret >"$audit_final_link_fixture/node-one-secrets/audit_database_url.real"
chmod 0600 "$audit_final_link_fixture/node-one-secrets/audit_database_url.real"
ln -s audit_database_url.real "$audit_final_link_fixture/node-one-secrets/audit_database_url"
if PATH="$fake_bin:$PATH" PLAINPOST_SECRET_OWNERSHIP_TEST_LOG="$docker_log" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_STATE="$docker_state" \
  PLAINPOST_SECRET_OWNERSHIP_TEST_FAIL_USER='' PLAINPOST_SECRET_OWNERSHIP_TOKEN=audit-final-link \
  bash "$helper" "$audit_final_link_fixture" "$image" private-release-audit local-virtualized; then
  fail 'local virtualized audit accepted a symlink final path'
fi
[[ -L "$audit_final_link_fixture/node-one-secrets/audit_database_url" ]] ||
  fail 'audit symlink final path was modified'

# The exact container path must provide the same audit safety boundary and
# cleanup must verify that an owned helper container is actually absent.
for required in \
  'test ! -L /fixture/node-one-secrets/audit_database_url.pending' \
  'test ! -L /fixture/node-one-secrets/audit_database_url' \
  'chown 65532:65532 /fixture/node-one-secrets/audit_database_url' \
  'test "$(stat -c "%u:%g %a %h" /fixture/node-one-secrets/audit_database_url)" = "65532:65532 600 1"' \
  'test -s /fixture/node-one-secrets/audit_database_url.pending' \
  'mv -f /fixture/node-one-secrets/audit_database_url.pending /fixture/node-one-secrets/audit_database_url' \
  'cat "/fixture/' \
  'chown 65532:65532 /fixture/node-one-secrets/audit_database_url.pending' \
  'docker ps -aq --filter "name=^/$secret_ownership_container$"'; do
  grep -F -- "$required" "$helper" >/dev/null || fail "helper lacks audit safety seam $required"
done
if grep -F -- 'cp /fixture/node-one-secrets/audit_database_url.pending' "$helper" >/dev/null ||
   grep -F -- '.audit_database_url.tmp' "$helper" >/dev/null; then
  fail 'audit transition still uses a copy or temporary path'
fi
postgres_loop_source=$(awk '/for path in \$postgres_paths; do/,/^  done/' "$helper")
grep -F -- 'test ! -L "/fixture/$path"' <<<"$postgres_loop_source" >/dev/null ||
  fail 'exact postgres ownership loop does not reject symlinks'
if grep -F -- 'rm -f "$release_audit_database_url_pending"' "$private_owner" >/dev/null; then
  fail 'private owner still owns audit pending cleanup'
fi

# Only the local release-image/native-TLS owners may select this mode, and
# their selector must be explicit to Darwin rather than a global default.
for owner in "$release_owner" "$native_owner"; do
  grep -F -- 'uname -s' "$owner" >/dev/null || fail "owner lacks OS gate: $owner"
  grep -F -- 'Darwin' "$owner" >/dev/null || fail "owner lacks Darwin gate: $owner"
  grep -F -- 'local-virtualized' "$owner" >/dev/null || fail "owner lacks local mode: $owner"
done
grep -F -- 'PLAINPOST_SECRET_OWNERSHIP_RELEASE_ADAPTER=release-images-darwin' "$release_owner" >/dev/null ||
  fail 'release-image owner lacks its explicit ownership adapter token'
grep -F -- 'secret_ownership_validation_mode=${PLAINPOST_SECRET_OWNERSHIP_VALIDATION_MODE:-exact}' "$private_owner" >/dev/null ||
  fail 'private owner does not default to exact ownership validation'
grep -F -- 'acceptance_node_uid=65532' "$private_owner" >/dev/null ||
  fail 'release mode does not run the node as uid 65532'
grep -F -- 'acceptance_node_gid=65532' "$private_owner" >/dev/null ||
  fail 'release mode does not run the node as gid 65532'
grep -F -- 'secret_ownership_release_adapter' "$private_owner" >/dev/null ||
  fail 'private owner lacks release-adapter validation'
grep -F -- 'release-images-darwin' "$private_owner" >/dev/null ||
  fail 'private owner lacks release-image adapter token'
grep -F -- 'private-release-audit' "$helper" >/dev/null

printf 'container_secret_ownership_contract=passed\n'
