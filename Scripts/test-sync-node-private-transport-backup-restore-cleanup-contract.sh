#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cleanup_helper="$root/Scripts/lib/acceptance-release-backup-restore-cleanup.sh"
owner="$root/Scripts/test-sync-node-private-transport.sh"
test -x "$cleanup_helper"

assert_process_group_absent() {
  group_id=$1
  group_probe=$(python3 - "$group_id" <<'PY'
import os
import sys

try:
    os.killpg(int(sys.argv[1]), 0)
except ProcessLookupError:
    print("ESRCH")
except PermissionError:
    print("EPERM")
else:
    print("PRESENT")
PY
)
  [ "$group_probe" = ESRCH ] || {
    printf 'cleanup process group %s probe returned %s; only ESRCH proves absence\n' "$group_id" "$group_probe" >&2
    return 1
  }
}

contract_tmp=$(mktemp -d "${TMPDIR:-/tmp}/plainpost-backup-restore-cleanup-contract.XXXXXX")
real_owned_backup_id=''
real_owned_restore_id=''
cleanup_contract_objects() {
  rc=$1
  trap - EXIT HUP INT TERM
  [ -z "$real_owned_backup_id" ] || docker rm --force "$real_owned_backup_id" >/dev/null 2>&1 || true
  [ -z "$real_owned_restore_id" ] || docker rm --force "$real_owned_restore_id" >/dev/null 2>&1 || true
  find "$contract_tmp" -depth -delete 2>/dev/null || true
  exit "$rc"
}
cleanup_contract_exit() {
  cleanup_contract_objects "$?"
}
cleanup_contract_signal() {
  cleanup_contract_objects "$1"
}
trap cleanup_contract_exit EXIT
trap 'cleanup_contract_signal 129' HUP
trap 'cleanup_contract_signal 130' INT
trap 'cleanup_contract_signal 143' TERM
mkdir -m 0700 "$contract_tmp/bin"
state="$contract_tmp/containers"
printf '%s\n' \
  contract-project-release-backup \
  contract-project-release-restore \
  contract-project-foreign >"$state"

cat >"$contract_tmp/bin/docker" <<'SH'
#!/bin/sh
set -eu
if [ "$1" = ps ] && [ "${FAKE_DOCKER_FAIL_PS:-0}" = 1 ]; then
  exit 97
fi
case "$1 ${2-} ${3-}" in
  'rm --force '* )
    target=$3
    if [ "${FAKE_DOCKER_FAIL_RM:-0}" = 1 ]; then
      exit 98
    fi
    tmp="$CONTAINER_STATE.tmp"
    case "$target" in
      id-backup) name=contract-project-release-backup ;;
      id-restore) name=contract-project-release-restore ;;
      id-foreign) name=contract-project-foreign ;;
      *) name=$target ;;
    esac
    if [ "${FAKE_DOCKER_RETAIN_AFTER_RM:-0}" != 1 ]; then
      awk -v target="$name" '$0 != target { print }' "$CONTAINER_STATE" >"$tmp"
      mv "$tmp" "$CONTAINER_STATE"
    fi
    ;;
  'ps -aq --no-trunc'|'ps -aq --filter')
    filter=$5
    case "$filter" in
      name=^/*)
        name=${filter#name=^/}
        name=${name%\$}
        case "$name" in
          contract-project-release-backup) grep -Fx "$name" "$CONTAINER_STATE" >/dev/null && printf 'id-backup\n' || true ;;
          contract-project-release-restore) grep -Fx "$name" "$CONTAINER_STATE" >/dev/null && printf 'id-restore\n' || true ;;
          contract-project-foreign) grep -Fx "$name" "$CONTAINER_STATE" >/dev/null && printf 'id-foreign\n' || true ;;
          *) : ;;
        esac
        ;;
      id=*)
        target=${filter#id=}
        case "$target" in
          id-backup) grep -Fx contract-project-release-backup "$CONTAINER_STATE" >/dev/null && printf 'id-backup\n' || true ;;
          id-restore) grep -Fx contract-project-release-restore "$CONTAINER_STATE" >/dev/null && printf 'id-restore\n' || true ;;
          id-foreign) grep -Fx contract-project-foreign "$CONTAINER_STATE" >/dev/null && printf 'id-foreign\n' || true ;;
        esac
        ;;
    esac
    ;;
  inspect*)
    target=$4
    case "$target" in
      id-backup|contract-project-release-backup)
        if [ "${FOREIGN_EXACT:-0}" = 1 ]; then printf 'id-backup /contract-project-release-backup contract-project foreign unrelated\n'; else printf 'id-backup /contract-project-release-backup contract-project release-backup-restore backup\n'; fi
        ;;
      id-restore|contract-project-release-restore) printf 'id-restore /contract-project-release-restore contract-project release-backup-restore restore\n' ;;
      id-foreign|contract-project-foreign) printf 'id-foreign /contract-project-foreign contract-project foreign unrelated\n' ;;
      *) exit 1 ;;
    esac
    ;;
  *)
    printf 'unexpected fake Docker call\n' >&2
    exit 1
    ;;
esac
SH
chmod 0700 "$contract_tmp/bin/docker"

# Keep the signal probe independent of the longer assertion sequence while
# still invoking the production cleanup helper before entering the loop.
if [ "${PLAINPOST_BACKUP_RESTORE_SIGNAL_CHILD:-0}" = 1 ]; then
  : >"$state"
  PATH="$contract_tmp/bin:$PATH" CONTAINER_STATE="$state" \
    "$cleanup_helper" contract-project
  printf 'ready\n' >"$PLAINPOST_BACKUP_RESTORE_SIGNAL_READY"
  while :; do sleep 1; done
fi

PATH="$contract_tmp/bin:$PATH" CONTAINER_STATE="$state" \
  "$cleanup_helper" contract-project

grep -Fx contract-project-foreign "$state" >/dev/null
if grep -E 'contract-project-release-(backup|restore)' "$state" >/dev/null; then
  printf 'release backup restore cleanup retained a daemon-owned container\n' >&2
  exit 1
fi
[ "$(wc -l <"$state" | tr -d ' ')" -eq 1 ]

# Empty output is valid only after a successful Docker query. A query failure
# and a successful rm followed by a retained container must both fail closed.
printf '%s\n' contract-project-release-backup contract-project-foreign >"$state"
query_failure_status=0
PATH="$contract_tmp/bin:$PATH" CONTAINER_STATE="$state" FAKE_DOCKER_FAIL_PS=1 \
  "$cleanup_helper" contract-project || query_failure_status=$?
[ "$query_failure_status" -ne 0 ]
grep -Fx contract-project-release-backup "$state" >/dev/null

retained_after_rm_status=0
PATH="$contract_tmp/bin:$PATH" CONTAINER_STATE="$state" FAKE_DOCKER_RETAIN_AFTER_RM=1 \
  "$cleanup_helper" contract-project || retained_after_rm_status=$?
[ "$retained_after_rm_status" -ne 0 ]
grep -Fx contract-project-release-backup "$state" >/dev/null

rm_failure_status=0
PATH="$contract_tmp/bin:$PATH" CONTAINER_STATE="$state" FAKE_DOCKER_FAIL_RM=1 \
  "$cleanup_helper" contract-project || rm_failure_status=$?
[ "$rm_failure_status" -ne 0 ]
grep -Fx contract-project-release-backup "$state" >/dev/null

printf '%s\n' contract-project-release-backup contract-project-foreign >"$state"
foreign_status=0
PATH="$contract_tmp/bin:$PATH" CONTAINER_STATE="$state" FOREIGN_EXACT=1 \
  "$cleanup_helper" contract-project || foreign_status=$?
[ "$foreign_status" -ne 0 ]
grep -Fx contract-project-release-backup "$state" >/dev/null
grep -Fx contract-project-foreign "$state" >/dev/null

# An interrupted negative restore can leave any of its seven exact Compose
# names behind. Exercise the cleanup helper against all seven and a daemon
# that reports successful rm while retaining them.
negative_cleanup_root="$contract_tmp/negative-containers"
mkdir -m 0700 "$negative_cleanup_root" "$negative_cleanup_root/bin"
negative_state="$negative_cleanup_root/state"
negative_cases='wrong-key wrong-account wrong-trust-identity semantic-mismatch unsupported-postgresql-major no-stage no-reference'
for negative_case in $negative_cases; do
  printf 'contract-project-restore-negative-%s\n' "$negative_case" >>"$negative_state"
done
cat >"$negative_cleanup_root/bin/docker" <<'SH'
#!/bin/sh
set -eu
case "$1" in
  ps)
    filter=''
    for argument in "$@"; do filter=$argument; done
    case "$filter" in
      name=^/*)
        name=${filter#name=^/}
        name=${name%\$}
        if grep -Fx "$name" "$NEGATIVE_CONTAINER_STATE" >/dev/null; then
          printf 'id-%s\n' "${name##*-restore-negative-}"
        fi
        ;;
      id=*)
        id=${filter#id=}
        case "$id" in
          id-*) name="contract-project-restore-negative-${id#id-}"; grep -Fx "$name" "$NEGATIVE_CONTAINER_STATE" >/dev/null && printf '%s\n' "$id" || true ;;
        esac
        ;;
    esac
    ;;
  inspect)
    target=''
    for argument in "$@"; do target=$argument; done
    case "$target" in
      id-*) negative_case=${target#id-}; printf '%s /contract-project-restore-negative-%s contract-project release-restore-negative restore %s\n' "$target" "$negative_case" "$negative_case" ;;
      *) exit 1 ;;
    esac
    ;;
  rm)
    target=$3
    if [ "${FAKE_NEGATIVE_RETAIN:-0}" != 1 ]; then
      negative_case=${target#id-}
      sed "/^contract-project-restore-negative-${negative_case}$/d" "$NEGATIVE_CONTAINER_STATE" >"$NEGATIVE_CONTAINER_STATE.tmp"
      mv "$NEGATIVE_CONTAINER_STATE.tmp" "$NEGATIVE_CONTAINER_STATE"
    fi
    ;;
  *) exit 1 ;;
esac
SH
chmod 0700 "$negative_cleanup_root/bin/docker"
PATH="$negative_cleanup_root/bin:$PATH" NEGATIVE_CONTAINER_STATE="$negative_state" \
  "$cleanup_helper" contract-project
if grep -E '^contract-project-restore-negative-' "$negative_state" >/dev/null; then
  printf 'cleanup retained an exact negative restore container\n' >&2
  exit 1
fi
for negative_case in $negative_cases; do
  printf 'contract-project-restore-negative-%s\n' "$negative_case" >>"$negative_state"
done
negative_retained_status=0
PATH="$negative_cleanup_root/bin:$PATH" NEGATIVE_CONTAINER_STATE="$negative_state" FAKE_NEGATIVE_RETAIN=1 \
  "$cleanup_helper" contract-project || negative_retained_status=$?
[ "$negative_retained_status" -ne 0 ]
for negative_case in $negative_cases; do
  grep -Fx "contract-project-restore-negative-$negative_case" "$negative_state" >/dev/null
done

# Exercise the same cleanup helper against the local Docker daemon only when
# explicitly requested. The deterministic fake boundary above is the default
# contract; this optional probe keeps ambient image availability from deciding
# whether the contract can run on a clean host.
if [ "${PLAINPOST_RUN_REAL_DOCKER_CLEANUP_PROBE:-0}" = 1 ]; then
  real_image=$(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E 'plainpost.*node|sync-node' | head -n 1 || true)
  [ -n "$real_image" ] || {
    printf 'real Docker cleanup probe requires a cached Plainpost node image\n' >&2
    exit 1
  }
  real_project="plainpost-cleanup-contract-$$"
  real_backup_name="$real_project-release-backup"
  real_restore_name="$real_project-release-restore"
  real_owned_backup_id=$(docker create --pull never --name "$real_backup_name" \
    --label "com.docker.compose.project=$real_project" \
    --label com.plainpost.acceptance=release-backup-restore \
    --label com.plainpost.acceptance-action=backup \
    "$real_image")
  real_owned_restore_id=$(docker create --pull never --name "$real_restore_name" \
    --label "com.docker.compose.project=foreign-cleanup-project" \
    --label com.plainpost.acceptance=release-backup-restore \
    --label com.plainpost.acceptance-action=restore \
    "$real_image")
  real_cleanup_status=0
  "$cleanup_helper" "$real_project" || real_cleanup_status=$?
  [ "$real_cleanup_status" -ne 0 ]
  [ -z "$(docker ps -aq --filter "name=^/${real_backup_name}$")" ]
  [ -n "$(docker ps -aq --filter "name=^/${real_restore_name}$")" ]
  docker rm --force "$real_restore_name" >/dev/null 2>&1 || true
  [ -z "$(docker ps -aq --filter "name=^/${real_restore_name}$")" ]
  real_owned_backup_id=''
  real_owned_restore_id=''
fi

grep -F 'acceptance-release-backup-restore-cleanup.sh' "$owner" >/dev/null
grep -F 'release_backup_restore_cleanup" "$project"' "$owner" >/dev/null

# The cleanup contract must preserve conventional shell signal statuses while
# exercising the actual traps above. The child has a bounded single-purpose
# signal loop, and its leader is checked after the trap returns.
for signal_name in HUP INT TERM; do
  signal_ready="$contract_tmp/signal-$signal_name.ready"
  signal_state="$contract_tmp/signal-$signal_name.state"
  printf '%s\n' contract-project-release-backup contract-project-foreign >"$signal_state"
  signal_status=0
  env PLAINPOST_BACKUP_RESTORE_SIGNAL_CHILD=1 \
  PLAINPOST_BACKUP_RESTORE_SIGNAL_READY="$signal_ready" \
  PATH="$contract_tmp/bin:$PATH" CONTAINER_STATE="$signal_state" \
  python3 -c 'import os, signal, sys; os.setsid(); [signal.signal(signum, signal.SIG_DFL) for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)]; os.execv(sys.argv[1], [sys.argv[1]])' "$0" \
    >"$contract_tmp/signal-$signal_name.output" 2>&1 &
  signal_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$signal_ready" ] && break
    sleep 0.05
  done
  [ -s "$signal_ready" ] || {
    printf 'cleanup signal %s did not reach its signal loop\n' "$signal_name" >&2
    sed -n '1,120p' "$contract_tmp/signal-$signal_name.output" >&2 || true
    python3 -c 'import os, signal, sys; os.killpg(int(sys.argv[1]), signal.SIGKILL)' "$signal_pid" 2>/dev/null || true
    wait "$signal_pid" 2>/dev/null || true
    exit 1
  }
  SIGNAL_NAME="$signal_name" python3 -c 'import os, signal, sys; os.killpg(int(sys.argv[1]), getattr(signal, "SIG" + os.environ["SIGNAL_NAME"]))' "$signal_pid"
  wait "$signal_pid" || signal_status=$?
  expected_signal_status=129
  [ "$signal_name" = INT ] && expected_signal_status=130
  [ "$signal_name" = TERM ] && expected_signal_status=143
  [ "$signal_status" -eq "$expected_signal_status" ] || {
    printf 'cleanup signal %s returned %s, expected %s\n' "$signal_name" "$signal_status" "$expected_signal_status" >&2
    exit 1
  }
  if ! assert_process_group_absent "$signal_pid"; then
    printf 'cleanup signal %s left its process alive\n' "$signal_name" >&2
    python3 -c 'import os, signal, sys; os.killpg(int(sys.argv[1]), signal.SIGKILL)' "$signal_pid" 2>/dev/null || true
    wait "$signal_pid" 2>/dev/null || true
    exit 1
  fi
done
if grep -Eq 'python3 - "\$[^" ]+" -c' "$0"; then
  printf 'cleanup contract contains an unreachable python -c cleanup invocation\n' >&2
  exit 1
fi
printf 'sync_node_private_transport_backup_restore_cleanup_contract=passed\n'
