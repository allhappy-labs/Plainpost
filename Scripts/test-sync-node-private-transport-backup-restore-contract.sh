#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
owner="$root/Scripts/test-sync-node-private-transport.sh"
scenario="$root/Tests/PlainpostAccountRuntimeTests/NodeMailAuthorityLiveScenario.swift"
pty="$root/Scripts/lib/acceptance-operations-restore-pty.py"
runner="$root/Scripts/lib/acceptance-release-backup-restore.sh"
cleanup_helper="$root/Scripts/lib/acceptance-release-backup-restore-cleanup.sh"
cleanup_contract="$root/Scripts/test-sync-node-private-transport-backup-restore-cleanup-contract.sh"
active_reference_helper="$root/Scripts/lib/acceptance-active-database-reference.sh"
release_override_writer="$root/Scripts/lib/write-release-private-transport-override.sh"
secret_ownership_helper="$root/Scripts/lib/prepare-container-secret-ownership.sh"
terminal_marker_helper="$root/Scripts/lib/acceptance-release-backup-restore-terminal-marker.sh"

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
    printf 'process group %s probe returned %s; only ESRCH proves absence\n' "$group_id" "$group_probe" >&2
    return 1
  }
}

test -x "$cleanup_helper"
test -x "$cleanup_contract"
test -x "$terminal_marker_helper"
sh "$cleanup_contract"

contract_tmp=$(mktemp -d "${TMPDIR:-/tmp}/plainpost-backup-restore-contract.XXXXXX")
contract_background_pty_pid=''
contract_cleanup() {
  contract_rc=$1
  if [ -n "$contract_background_pty_pid" ]; then
    kill -TERM "$contract_background_pty_pid" 2>/dev/null || true
    wait "$contract_background_pty_pid" 2>/dev/null || true
    contract_background_pty_pid=''
  fi
  find "$contract_tmp" -depth -delete 2>/dev/null || true
  trap - EXIT HUP INT TERM
  exit "$contract_rc"
}
trap 'contract_cleanup $?' EXIT
trap 'contract_cleanup 129' HUP
trap 'contract_cleanup 130' INT
trap 'contract_cleanup 143' TERM

# Execute the runner through the foreign-container preflight with a bounded
# fake Docker CLI. This proves the failure trap classifies setup failures but
# does not invoke cleanup against a container that preflight identified as
# foreign. The second invocation makes the marker append fail and verifies the
# original command status survives cleanup.
behavior_root="$contract_tmp/runner-behavior"
mkdir -p "$behavior_root/temporary/node-one-data/backups" "$behavior_root/bin"
: >"$behavior_root/compose.yaml"
: >"$behavior_root/override.yaml"
: >"$behavior_root/runtime.log"
cat >"$behavior_root/bin/docker" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$DOCKER_CALLS"
case "$1 $2" in
  'ps -aq')
    if [ "$DOCKER_MODE" = foreign ]; then
      printf 'foreign-id\n'
    fi
    ;;
  'compose -p')
    if [ "$DOCKER_MODE" = armed ]; then
      compose_calls=$(awk '$1 == "compose" && $2 == "-p" { count++ } END { print count + 0 }' "$DOCKER_CALLS")
      if [ "$compose_calls" -eq 1 ]; then
        rm -f "$RUNTIME_LOG"
        mkdir "$RUNTIME_LOG"
        exit 47
      fi
    fi
    exit 0
    ;;
  *) exit 1 ;;
esac
SH
chmod 0700 "$behavior_root/bin/docker"
behavior_status=0
PATH="$behavior_root/bin:$PATH" DOCKER_CALLS="$behavior_root/docker.calls" \
  DOCKER_MODE=foreign RUNTIME_LOG="$behavior_root/runtime.log" \
  "$runner" "$behavior_root/compose.yaml" contract-project \
  "$behavior_root/temporary" "$behavior_root/override.yaml" image@sha256:0000000000000000000000000000000000000000000000000000000000000000 \
  65532 65532 filesystem /node-data/attachments endpoint bucket region path access secret \
  "$behavior_root/runtime.log" "$root" >/dev/null 2>&1 || behavior_status=$?
[ "$behavior_status" -ne 0 ] || {
  printf 'runner behavior accepted a foreign preflight container\n' >&2
  exit 1
}
grep -Fx 'ERROR release-backup-restore step=preflight-container-names status=failed' "$behavior_root/runtime.log" >/dev/null || {
  printf 'runner behavior omitted preflight failure marker\n' >&2
  exit 1
}
[ "$(wc -l <"$behavior_root/docker.calls" | tr -d ' ')" -eq 1 ] || {
  printf 'runner behavior attempted cleanup after foreign preflight failure\n' >&2
  exit 1
}
behavior_status=0
PATH="$behavior_root/bin:$PATH" DOCKER_CALLS="$behavior_root/docker-armed.calls" \
  DOCKER_MODE=armed RUNTIME_LOG="$behavior_root/runtime.log" \
  "$runner" "$behavior_root/compose.yaml" contract-project \
  "$behavior_root/temporary" "$behavior_root/override.yaml" image@sha256:0000000000000000000000000000000000000000000000000000000000000000 \
  65532 65532 filesystem /node-data/attachments endpoint bucket region path access secret \
  "$behavior_root/runtime.log" "$root" >/dev/null 2>&1 || behavior_status=$?
[ "$behavior_status" -eq 47 ] || {
  printf 'runner behavior did not preserve post-preflight command failure\n' >&2
  exit 1
}
[ "$(wc -l <"$behavior_root/docker-armed.calls" | tr -d ' ')" -gt 1 ] || {
  printf 'runner behavior skipped cleanup after an armed failure\n' >&2
  exit 1
}
active_reference="$contract_tmp/active-reference"
printf 'active\n' >"$active_reference"
chmod 0600 "$active_reference"
. "$active_reference_helper"
[ "$(acceptance_active_database_name "$active_reference" plainpost_sync_node)" = plainpost_sync_node ]
printf 'restore_0123456789abcdef0123456789abcdef\n' >"$active_reference"
[ "$(acceptance_active_database_name "$active_reference" plainpost_sync_node)" = restore_0123456789abcdef0123456789abcdef ]
rm -f "$active_reference"
if acceptance_active_database_name "$active_reference" plainpost_sync_node "$contract_tmp" required >/dev/null 2>&1; then
  printf 'post-restore active database reference contract reused a deleted reference fallback\n' >&2
  exit 1
fi
printf 'active\n' >"$active_reference"
if acceptance_active_database_name "$active_reference" plainpost_sync_node "$contract_tmp" required >/dev/null 2>&1; then
  printf 'post-restore active database reference contract accepted the pre-restore sentinel\n' >&2
  exit 1
fi
printf 'restore_0123456789abcdef0123456789abcdef' >"$active_reference"
if acceptance_active_database_name "$active_reference" plainpost_sync_node >/dev/null 2>&1; then
  printf 'active database reference contract accepted a non-newline-terminated value\n' >&2
  exit 1
fi
printf 'restore_0123456789abcdef0123456789abcdef\nextra\n' >"$active_reference"
if acceptance_active_database_name "$active_reference" plainpost_sync_node >/dev/null 2>&1; then
  printf 'active database reference contract accepted extra lines\n' >&2
  exit 1
fi
printf 'restore_0123456789abcdef0123456789abcdef\0' >"$active_reference"
if acceptance_active_database_name "$active_reference" plainpost_sync_node >/dev/null 2>&1; then
  printf 'active database reference contract accepted trailing bytes\n' >&2
  exit 1
fi
python3 - "$active_reference" <<'PY'
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_bytes(b"restore_" + b"a" * 32 + b"x" * 256 + b"\n")
PY
if acceptance_active_database_name "$active_reference" plainpost_sync_node >/dev/null 2>&1; then
  printf 'active database reference contract accepted an oversized value\n' >&2
  exit 1
fi
printf 'invalid\n' >"$active_reference"
if acceptance_active_database_name "$active_reference" plainpost_sync_node >/dev/null 2>&1; then
  printf 'active database reference contract accepted an invalid value\n' >&2
  exit 1
fi
printf 'restore_0123456789abcdef0123456789abcdef\n' >"$active_reference"
linked_reference="$contract_tmp/linked-reference"
ln -s "$active_reference" "$linked_reference"
if acceptance_active_database_name "$linked_reference" plainpost_sync_node "$contract_tmp" >/dev/null 2>&1; then
  printf 'active database reference contract followed a symlinked reference\n' >&2
  exit 1
fi
linked_root="$contract_tmp/linked-root"
ln -s "$(dirname "$active_reference")" "$linked_root"
if acceptance_active_database_name "$linked_root/active-reference" plainpost_sync_node "$linked_root" >/dev/null 2>&1; then
  printf 'active database reference contract followed a symlinked reference root\n' >&2
  exit 1
fi

# EPERM must remain distinguishable from ESRCH: an inaccessible process group
# is not absent. Exercise the actual PTY helper probe with a deterministic
# PermissionError instead of relying on ambient process ownership.
contract_digest=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
python3 - "$pty" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("restore_pty", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def deny(_pid, _signal):
    raise PermissionError(1, "operation not permitted")

module.os.killpg = deny
if module.group_state(12345) is not None:
    raise SystemExit("PTY group_state treated EPERM as absence")
print("pty-group-probe-eperm=preserved")
PY

# Setup and prompt-write exceptions happen after pty.fork(). The helper must
# tear down the complete owned group before returning a bounded failure.
for pty_failure in setup prompt-write; do
  pty_failure_root="$contract_tmp/pty-$pty_failure"
  mkdir -m 0700 "$pty_failure_root"
  pty_failure_pid_file="$pty_failure_root/child.pid"
  pty_failure_status=0
  PTY_FAILURE="$pty_failure" PTY_FAILURE_PID_FILE="$pty_failure_pid_file" \
    python3 - "$pty" "$contract_digest" <<'PY' || pty_failure_status=$?
import importlib.util
import os
import signal
import sys
import time

helper_path, digest = sys.argv[1:3]
failure = os.environ["PTY_FAILURE"]
pid_file = os.environ["PTY_FAILURE_PID_FILE"]
spec = importlib.util.spec_from_file_location("restore_pty_failure", helper_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

child = (
    "import os, signal, time; "
    "open(os.environ['PTY_FAILURE_PID_FILE'], 'w').write(str(os.getpid()) + ' ' + str(os.getpgrp()) + '\\n'); "
    "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
    "print('Type the exact backup digest to restore:', end='', flush=True); time.sleep(30)"
)
sys.argv = [
    helper_path,
    "--digest",
    digest,
    "--timeout-seconds",
    "2",
    "--",
    "python3",
    "-c",
    child,
]
if failure == "setup":
    def fail_setup(*_args):
        time.sleep(0.2)
        raise OSError("deterministic setup failure")
    module.os.set_blocking = fail_setup
else:
    def fail_prompt_write(*_args):
        raise OSError("deterministic prompt write failure")
    module.os.write = fail_prompt_write

status = module.main()
if status != 1:
    raise SystemExit(f"{failure} failure returned {status}, expected 1")
for _ in range(40):
    if os.path.exists(pid_file):
        break
    time.sleep(0.01)
pid, group = (int(value) for value in open(pid_file, encoding="ascii").read().split())
try:
    os.killpg(group, 0)
except ProcessLookupError:
    pass
except PermissionError as exc:
    raise SystemExit(f"{failure} failure left an unprobeable process group") from exc
else:
    raise SystemExit(f"{failure} failure left process group {group}")
PY
  [ "$pty_failure_status" -eq 0 ] || {
    printf 'PTY %s failure did not fail closed and reap its group\n' "$pty_failure" >&2
    exit 1
  }
done

# A control signal delivered by pty.fork() itself must be queued while the
# parent installs handlers, then tear down the owned group rather than killing
# the parent in the fork window.
signal_window_pid_file="$contract_tmp/pty-signal-window.pid"
signal_window_status=0
PTY_SIGNAL_WINDOW_PID_FILE="$signal_window_pid_file" python3 - "$pty" "$contract_digest" <<'PY' || signal_window_status=$?
import importlib.util
import os
import signal
import sys
import time

helper_path, digest = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("restore_pty_signal_window", helper_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
real_fork = module.pty.fork

def fork_then_signal():
    pid, fd = real_fork()
    if pid == 0:
        with open(os.environ["PTY_SIGNAL_WINDOW_PID_FILE"], "w", encoding="ascii") as record:
            record.write(f"{os.getpid()} {os.getpgrp()}\n")
    else:
        os.kill(os.getpid(), signal.SIGHUP)
    return pid, fd

module.pty.fork = fork_then_signal
sys.argv = [helper_path, "--digest", digest, "--timeout-seconds", "2", "--", "python3", "-c",
            "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"]
raise SystemExit(module.main())
PY
[ "$signal_window_status" -eq 129 ] && [ -s "$signal_window_pid_file" ] || {
  printf 'PTY fork signal window returned %s, expected 129\n' "$signal_window_status" >&2
  exit 1
}
signal_window_group_id=$(awk '{print $2}' "$signal_window_pid_file")
assert_process_group_absent "$signal_window_group_id" || {
  printf 'PTY fork signal window left a descendant\n' >&2
  exit 1
}

# A leader can be reaped by another owner while its descendant remains in the
# process group. The teardown path must treat ChildProcessError as already
# reaped, then continue enforcing group absence.
python3 - "$pty" <<'PY'
import importlib.util
import os
import signal
import sys
import time

spec = importlib.util.spec_from_file_location("restore_pty_reaped_leader", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
leader = os.fork()
if leader == 0:
    os.setpgid(0, 0)
    descendant = os.fork()
    if descendant == 0:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(30)
        os._exit(0)
    os._exit(0)
time.sleep(0.1)
real_waitpid = module.os.waitpid
real_waitpid(leader, 0)
def already_reaped(*_args):
    raise ChildProcessError()
module.os.waitpid = already_reaped
try:
    if not module.terminate_and_reap_group(leader):
        raise SystemExit("already-reaped leader teardown did not prove group absence")
finally:
    module.os.waitpid = real_waitpid
print("pty-reaped-leader=passed")
PY

marker_contract_root="$contract_tmp/terminal-marker"
mkdir -m 0700 "$marker_contract_root" "$marker_contract_root/bin"
marker_applied="$marker_contract_root/release-backup-restore.applied"
marker_failed="$marker_contract_root/release-backup-restore.failed"
. "$terminal_marker_helper"
publish_release_backup_restore_marker "$marker_failed" "$marker_applied" backup-restore
[ ! -e "$marker_applied" ]
[ "$(cat "$marker_failed")" = 'terminal_class=backup-restore' ]
[ "$(stat -f '%Lp' "$marker_failed" 2>/dev/null || stat -c '%a' "$marker_failed")" = 600 ]
cat >"$marker_contract_root/bin/chmod" <<'SH'
#!/bin/sh
exit 97
SH
chmod 0700 "$marker_contract_root/bin/chmod"
marker_write_status=0
PATH="$marker_contract_root/bin:$PATH" publish_release_backup_restore_marker "$marker_applied" "$marker_failed" applied || marker_write_status=$?
[ "$marker_write_status" -ne 0 ]
[ ! -e "$marker_applied" ]

coordinator_probe_root="$contract_tmp/coordinator-query"
mkdir -m 0700 "$coordinator_probe_root"
mkdir -m 0700 "$coordinator_probe_root/bin"
cat >"$coordinator_probe_root/bin/docker" <<'SH'
#!/bin/sh
if [ "${FAKE_DOCKER_QUERY_FAILURE:-0}" = 1 ]; then
  exit 77
fi
case "${1:-}" in
  inspect)
    [ "${FAKE_DOCKER_INSPECT_MODE:-failure}" = empty ] && exit 0
    [ "${FAKE_DOCKER_INSPECT_MODE:-failure}" = running ] && printf 'running\n' && exit 0
    [ "${FAKE_DOCKER_INSPECT_MODE:-failure}" = exited ] && printf 'exited\n' && exit 0
    exit 78
    ;;
esac
exit 0
SH
chmod 0700 "$coordinator_probe_root/bin/docker"
coordinator_probe_harness="$coordinator_probe_root/probe.sh"
{
  printf '%s\n' '#!/bin/sh' 'set -eu' 'runtime_log=$1'
  awk '/^assert_container_absent\(\)/,/^}/' "$runner"
  awk '/^assert_container_stopped\(\)/,/^}/' "$runner"
  cat <<'SH'
if ! assert_container_absent empty-name; then
  printf 'coordinator rejected a successful empty Docker query\n' >&2
  exit 1
fi
if FAKE_DOCKER_QUERY_FAILURE=1 assert_container_absent query-failure; then
  printf 'coordinator treated a failed Docker query as an empty result\n' >&2
  exit 1
fi
unset FAKE_DOCKER_QUERY_FAILURE
if assert_container_stopped inspect-failure; then
  printf 'coordinator treated a failed Docker inspect as stopped\n' >&2
  exit 1
fi
FAKE_DOCKER_INSPECT_MODE=empty
export FAKE_DOCKER_INSPECT_MODE
if assert_container_stopped inspect-empty; then
  printf 'coordinator treated an empty Docker inspect as stopped\n' >&2
  exit 1
fi
FAKE_DOCKER_INSPECT_MODE=running
if assert_container_stopped inspect-running; then
  printf 'coordinator treated a running Docker inspect as stopped\n' >&2
  exit 1
fi
FAKE_DOCKER_INSPECT_MODE=exited
assert_container_stopped inspect-exited
printf 'coordinator-query-probe=passed\n'
SH
} >"$coordinator_probe_harness"
chmod 0700 "$coordinator_probe_harness"
PATH="$coordinator_probe_root/bin:$PATH" "$coordinator_probe_harness" "$coordinator_probe_root/runtime.log"

# Exercise the production restore coordinator's cryptographic and semantic
# rejection paths as part of this executable release contract, not only via
# source-token checks. These cases prove wrong-key and wrong-account inputs do
# not create restore stages before any happy-path Docker operation.
(cd "$root/Services/PlainpostGo" && go test ./internal/node/backup \
  -run '^TestRestoreRejects(AuthenticContainerCryptographicCorruptionBeforeStages|ActualContainerSemanticBoundaryMatrixBeforeStages|PostgreSQL17And19ContainersBeforeStages)$' \
  -count=1) || {
  printf 'backup restore negative production tests failed\n' >&2
  exit 1
}
contract_output="$contract_tmp/pty-output"
EXPECTED_DIGEST="$contract_digest" python3 "$pty" --digest "$contract_digest" --timeout-seconds 5 -- \
  python3 -c 'import os, sys; print("Type the exact backup digest to restore:", end="", flush=True); value=sys.stdin.readline().strip(); print("state=restored" if value == os.environ["EXPECTED_DIGEST"] else "state=failed", flush=True)' \
  >"$contract_output" || {
    printf 'backup restore PTY contract failed\n' >&2
    exit 1
  }
tr -d '\r' <"$contract_output" | grep -Fx 'state=restored' >/dev/null || {
  printf 'backup restore PTY did not complete restored state\n' >&2
  exit 1
}

timeout_started=$(date +%s)
if python3 "$pty" --digest "$contract_digest" --timeout-seconds 0.25 -- \
  python3 -c 'import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)' \
  >"$contract_tmp/pty-timeout-output" 2>/dev/null; then
  timeout_status=0
else
  timeout_status=$?
fi
timeout_elapsed=$(( $(date +%s) - timeout_started ))
[ "$timeout_status" -eq 124 ] && [ "$timeout_elapsed" -lt 5 ] || {
  printf 'backup restore PTY timeout did not terminate and reap promptly\n' >&2
  exit 1
}

leader_child_pid_file="$contract_tmp/leader-child.pid"
leader_timeout_status=0
CHILD_PID_FILE="$leader_child_pid_file" python3 "$pty" --digest "$contract_digest" --timeout-seconds 0.25 -- \
  python3 -c 'import os, signal, time; child=os.fork(); (open(os.environ["CHILD_PID_FILE"], "w").write(str(os.getpid()) + " " + str(os.getpgrp()) + "\n"), signal.signal(signal.SIGTERM, signal.SIG_IGN), time.sleep(30)) if child == 0 else (time.sleep(0.2), signal.signal(signal.SIGTERM, lambda *_: os._exit(0)), time.sleep(30))' \
  >"$contract_tmp/pty-leader-timeout-output" 2>/dev/null || leader_timeout_status=$?
[ "$leader_timeout_status" -eq 124 ] && [ -s "$leader_child_pid_file" ] || {
  printf 'backup restore PTY did not reap a leader-exit descendant\n' >&2
  exit 1
}
leader_child_pid=$(sed 's/[^0-9].*$//' "$leader_child_pid_file")
leader_group_id=$(awk '{print $2}' "$leader_child_pid_file")
if ! assert_process_group_absent "$leader_group_id"; then
  printf 'backup restore PTY left a TERM-ignoring descendant\n' >&2
  python3 -c 'import os, signal, sys; os.killpg(int(sys.argv[1]), signal.SIGKILL)' "$leader_group_id" 2>/dev/null || true
  exit 1
fi

success_child_pid_file="$contract_tmp/success-child.pid"
success_status=0
CHILD_PID_FILE="$success_child_pid_file" python3 "$pty" --digest "$contract_digest" --timeout-seconds 2 -- \
  python3 -c 'import os, signal, time; child=os.fork(); (open(os.environ["CHILD_PID_FILE"], "w").write(str(os.getpid()) + " " + str(os.getpgrp()) + "\n"), signal.signal(signal.SIGTERM, signal.SIG_IGN), time.sleep(30)) if child == 0 else (time.sleep(0.2), os._exit(0))' \
  >"$contract_tmp/pty-success-descendant-output" 2>/dev/null || success_status=$?
[ "$success_status" -eq 1 ] && [ -s "$success_child_pid_file" ] || {
  printf 'backup restore PTY success path did not complete cleanly\n' >&2
  exit 1
}
success_child_pid=$(sed 's/[^0-9].*$//' "$success_child_pid_file")
success_group_id=$(awk '{print $2}' "$success_child_pid_file")
if ! assert_process_group_absent "$success_group_id"; then
  printf 'backup restore PTY success path left a TERM-ignoring descendant\n' >&2
  python3 -c 'import os, signal, sys; os.killpg(int(sys.argv[1]), signal.SIGKILL)' "$success_group_id" 2>/dev/null || true
  exit 1
fi

flood_child_pid_file="$contract_tmp/flood-child.pid"
flood_status=0
FLOOD_CHILD_PID_FILE="$flood_child_pid_file" python3 "$pty" --digest "$contract_digest" --timeout-seconds 5 -- \
  python3 -c 'import os, signal, sys; open(os.environ["FLOOD_CHILD_PID_FILE"], "w").write(str(os.getpid()) + " " + str(os.getpgrp()) + "\n"); signal.signal(signal.SIGTERM, signal.SIG_IGN); sys.stdout.write("F" * (2 * 1024 * 1024)); sys.stdout.flush()' \
  >"$contract_tmp/pty-flood-output" 2>/dev/null || flood_status=$?
[ "$flood_status" -ne 0 ] || {
  printf 'backup restore PTY accepted an output flood\n' >&2
  exit 1
}
[ "$(wc -c <"$contract_tmp/pty-flood-output" | tr -d ' ')" -le 1048576 ] || {
  printf 'backup restore PTY exceeded its bounded output ceiling\n' >&2
  exit 1
}
flood_child_pid=$(sed 's/[^0-9].*$//' "$flood_child_pid_file")
flood_group_id=$(awk '{print $2}' "$flood_child_pid_file")
if ! assert_process_group_absent "$flood_group_id"; then
  printf 'backup restore PTY flood path left a child\n' >&2
  python3 -c 'import os, signal, sys; os.killpg(int(sys.argv[1]), signal.SIGKILL)' "$flood_group_id" 2>/dev/null || true
  exit 1
fi

for signal_name in HUP INT TERM; do
  external_child_pid_file="$contract_tmp/external-$signal_name-child.pid"
  external_status=0
  CHILD_PID_FILE="$external_child_pid_file" python3 "$pty" --digest "$contract_digest" --timeout-seconds 5 -- \
    python3 -c 'import os, signal, time; child=os.fork(); (open(os.environ["CHILD_PID_FILE"], "w").write(str(os.getpid()) + " " + str(os.getpgrp()) + "\n"), signal.signal(signal.SIGTERM, signal.SIG_IGN), time.sleep(30)) if child == 0 else (time.sleep(30))' \
    >"$contract_tmp/pty-external-$signal_name-output" 2>/dev/null &
  external_helper_pid=$!
  contract_background_pty_pid=$external_helper_pid
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$external_child_pid_file" ] && break
    sleep 0.05
  done
  kill -"$signal_name" "$external_helper_pid"
  wait "$external_helper_pid" || external_status=$?
  contract_background_pty_pid=''
  external_expected_status=129
  [ "$signal_name" = INT ] && external_expected_status=130
  [ "$signal_name" = TERM ] && external_expected_status=143
  [ "$external_status" -eq "$external_expected_status" ] && [ -s "$external_child_pid_file" ] || {
    printf 'backup restore PTY external %s did not return signal status %s\n' "$signal_name" "$external_expected_status" >&2
    exit 1
  }
  external_group_id=$(awk '{print $2}' "$external_child_pid_file")
  if ! assert_process_group_absent "$external_group_id"; then
    printf 'backup restore PTY external %s left a descendant\n' "$signal_name" >&2
    python3 -c 'import os, signal, sys; os.killpg(int(sys.argv[1]), signal.SIGKILL)' "$external_group_id" 2>/dev/null || true
    exit 1
  fi
done

for required in \
  'release-backup-restore' \
  'release_backup_restore_step=' \
  'backup-restore-begin' \
  'backup-restore-end' \
  'PLAINPOST_SYNC_NODE_PRIVATE_TRANSPORT_RELEASE' \
  'operations backup' \
  'state=verified' \
  'state=restored' \
  'restore-references/database' \
  'restore_[0-9a-f]{32}' \
  'mode 0600'; do
  grep -F "$required" "$owner" "$scenario" "$pty" "$runner" >/dev/null || {
    printf 'backup restore contract missing %s\n' "$required" >&2
    exit 1
  }
done

if grep -Eq 'python3 - "\$[^" ]+" -c' "$0"; then
  printf 'backup restore contract contains an unreachable python -c cleanup invocation\n' >&2
  exit 1
fi

grep -F 'stop --timeout 10 node-one' "$runner" >/dev/null
# Every Compose image invocation, including each negative restore case, must
# pin both the release image source and the release runtime identity. Parse
# each line-continued invocation as one command so adding a new case cannot
# silently omit either safety boundary.
awk '
  function starts(line) {
    return line ~ /(^|[[:space:]])compose_env run --rm/ || line ~ /(^|[[:space:]])docker compose .* run --rm/
  }
  {
    if (!active && starts($0)) {
      active = 1
      count++
      has_pull = ($0 ~ /--pull never/)
      has_user = ($0 ~ /--user 65532:65532/)
    } else if (active) {
      has_pull = has_pull || ($0 ~ /--pull never/)
      has_user = has_user || ($0 ~ /--user 65532:65532/)
    }
    if (active && $0 !~ /\\[[:space:]]*$/) {
      if (!has_pull || !has_user) {
        printf "backup restore Compose invocation %d lacks --pull never or --user 65532:65532\\n", count > "/dev/stderr"
        exit 1
      }
      active = 0
    }
  }
  END {
    if (active || count == 0) exit 1
  }
' "$runner"
grep -F '/node-data/backups' "$runner" >/dev/null
grep -F '/node-data/backups/restore-input.ppb' "$runner" >/dev/null
grep -F -- '--name "$backup_run_name"' "$runner" >/dev/null
grep -F -- '--name "$restore_run_name"' "$runner" >/dev/null
grep -F -- '--label com.plainpost.acceptance=release-backup-restore' "$runner" >/dev/null
grep -F 'cleanup_run_containers' "$runner" >/dev/null
grep -F 'acceptance-release-backup-restore-cleanup.sh' "$owner" >/dev/null
grep -F 'acceptance-release-backup-restore-terminal-marker.sh' "$owner" >/dev/null
grep -F 'publish_release_backup_restore_marker "$release_backup_restore_applied" "$release_backup_restore_failed" applied' "$owner" >/dev/null
grep -F 'publish_release_backup_restore_marker "$release_backup_restore_failed" "$release_backup_restore_applied" backup-restore' "$owner" >/dev/null
grep -F 'release_backup_restore_action_status=1' "$owner" >/dev/null
grep -F 'terminal_class=%s' "$terminal_marker_helper" >/dev/null
grep -F 'if ! chmod 0600 "$release_audit_database_url_pending"' "$owner" >/dev/null
grep -F 'assert_container_absent()' "$runner" >/dev/null
grep -F 'release backup restore Docker query failed' "$runner" >/dev/null
grep -F 'release_backup_restore_cleanup" "$project"' "$owner" >/dev/null
runner_trap_line=$(grep -n '^trap release_backup_restore_exit EXIT$' "$runner" | cut -d: -f1)
runner_setup_line=$(grep -n '^before="\$temporary/release-backup-before"$' "$runner" | cut -d: -f1)
[ -n "$runner_trap_line" ] && [ -n "$runner_setup_line" ] && [ "$runner_trap_line" -lt "$runner_setup_line" ] || {
  printf 'backup restore failure trap is installed after setup\n' >&2
  exit 1
}
grep -F '>>"$runtime_log" || true' "$runner" >/dev/null || {
  printf 'backup restore failure marker is not best effort\n' >&2
  exit 1
}
negative_step_line=$(grep -n '^release_backup_restore_step=negative-fixture-build$' "$runner" | head -1 | cut -d: -f1)
negative_setup_line=$(grep -n '^negative_root=' "$runner" | cut -d: -f1)
[ -n "$negative_step_line" ] && [ -n "$negative_setup_line" ] && [ "$negative_step_line" -lt "$negative_setup_line" ] || {
  printf 'negative fixture setup is not classified\n' >&2
  exit 1
}
grep -F "trap 'cleanup_contract_signal 129' HUP" "$cleanup_contract" >/dev/null
grep -F "trap 'cleanup_contract_signal 130' INT" "$cleanup_contract" >/dev/null
grep -F "trap 'cleanup_contract_signal 143' TERM" "$cleanup_contract" >/dev/null
grep -F 'MAX_OUTPUT_BYTES = 1024 * 1024' "$pty" >/dev/null
grep -F 'if len(output) + len(chunk) > MAX_OUTPUT_BYTES:' "$pty" >/dev/null
grep -F 'original-attachments-quarantined=1' "$owner" >/dev/null
grep -F 'acceptance-active-database-reference.sh' "$owner" >/dev/null
grep -F 'release_backup_restore_timeout_seconds=240' "$owner" >/dev/null
grep -F 'release_backup_restore_readiness_timeout_seconds=120' "$owner" >/dev/null
grep -F 'release_backup_restore_total_timeout_seconds=370' "$owner" >/dev/null
grep -F 'release_backup_restore_node_start_timeout_seconds=30' "$owner" >/dev/null
release_timeout=$(sed -n 's/^release_backup_restore_timeout_seconds=\([0-9][0-9]*\)$/\1/p' "$owner")
release_readiness_timeout=$(sed -n 's/^release_backup_restore_readiness_timeout_seconds=\([0-9][0-9]*\)$/\1/p' "$owner")
release_total_timeout=$(sed -n 's/^release_backup_restore_total_timeout_seconds=\([0-9][0-9]*\)$/\1/p' "$owner")
[ "$release_timeout" -gt 120 ] && [ "$release_timeout" -lt 375 ]
[ "$release_total_timeout" -gt $((release_timeout + release_readiness_timeout)) ] && [ "$release_total_timeout" -lt 375 ] || {
  printf 'backup restore action budget exceeds Swift control wait\n' >&2
  exit 1
}
grep -F 'release_backup_restore_deadline_ms=$(( $(acceptance_controller_monotonic_ms) + release_backup_restore_total_timeout_seconds * 1000 ))' "$owner" >/dev/null
grep -F 'release_backup_restore_remaining_ms=$((release_backup_restore_deadline_ms - $(acceptance_controller_monotonic_ms)))' "$owner" >/dev/null
grep -F 'acceptance_controller_monotonic_ms()' "$root/Scripts/lib/acceptance-controller.sh" >/dev/null
grep -F 'time.monotonic_ns()' "$root/Scripts/lib/acceptance-controller.sh" >/dev/null
grep -F 'release-backup-restore-database-quarantine' "$owner" >/dev/null
grep -F 'release-backup-restore-node-start' "$owner" >/dev/null
grep -F 'release_backup_restore_child_timeout=$release_backup_restore_remaining' "$owner" >/dev/null
grep -F 'action-deadline-exceeded step=database-quarantine' "$owner" >/dev/null
grep -F 'action-deadline-exceeded step=node-start' "$owner" >/dev/null
grep -F 'action-deadline-exceeded step=cleanup' "$owner" >/dev/null
grep -F 'wait_for_node_one_ready_until_deadline release-backup-restore "$release_backup_restore_wait_seconds"' "$owner" >/dev/null
grep -F 'readiness_deadline_ms=$((readiness_started_at_ms + readiness_timeout_seconds * 1000))' "$owner" >/dev/null
grep -F -- '--max-time 1' "$owner" >/dev/null
grep -F 'operations restore --backup' "$runner" >/dev/null
grep -F 'state=restored' "$runner" >/dev/null
grep -F 'restore digest mismatch' "$root/Services/PlainpostGo/cmd/plainpost-sync-node/operations_cli.go" >/dev/null
grep -F 'offline restore rejected' "$root/Services/PlainpostGo/cmd/plainpost-sync-node/operations_cli.go" >/dev/null
grep -F 'TestRestoreRejectsAuthenticContainerCryptographicCorruptionBeforeStages' "$root/Services/PlainpostGo/internal/node/backup/restore_container_test.go" >/dev/null
grep -F 'TestRestoreRejectsActualContainerSemanticBoundaryMatrixBeforeStages' "$root/Services/PlainpostGo/internal/node/backup/restore_container_test.go" >/dev/null
grep -F '[ "$transport_release_images" = 1 ]' "$owner" >/dev/null
grep -F 'run_controller_child release-backup-restore-run "$release_backup_restore_child_timeout"' "$owner" >/dev/null
grep -F 'release backup restore requires filesystem attachment storage' "$owner" >/dev/null
grep -F "grep -Fx 'ERROR swift-stage stage=backup-restore-end" "$owner" >/dev/null
grep -F 'release-backup-restore status=passed' "$owner" >/dev/null
restore_status_line=$(grep -n "printf 'release-backup-restore status=passed" "$owner" | cut -d: -f1)
restore_reference_line=$(grep -n 'refresh_active_node_database_name required' "$owner" | cut -d: -f1)
[ -n "$restore_status_line" ] && [ -n "$restore_reference_line" ] && [ "$restore_status_line" -gt "$restore_reference_line" ] || {
  printf 'backup restore success marker precedes active-reference validation\n' >&2
  exit 1
}
grep -F 'node-one-secrets/audit_database_url' "$secret_ownership_helper" >/dev/null
grep -F 'private-release-audit' "$secret_ownership_helper" "$owner" >/dev/null
grep -F 'chown 65532:65532 /fixture/node-one-secrets/audit_database_url.pending' "$secret_ownership_helper" >/dev/null
grep -F 'audit_database_url' "$owner" >/dev/null
grep -F 'Node audit database authority file is not mode 0600' "$owner" >/dev/null
operations_cli="$root/Services/PlainpostGo/cmd/plainpost-sync-node/operations_cli.go"
grep -F 'clientAuth := &deferredClientAuth{}' "$operations_cli" >/dev/null
grep -F 'if err := clientAuth.Configure(ctx, resources, cfg); err != nil {' "$operations_cli" >/dev/null
grep -F 'clientAuth.MutationAuthority() == nil' "$operations_cli" >/dev/null
grep -F 'resources.clientAPI.SetMutationAuthority(clientAuth.MutationAuthority())' "$operations_cli" >/dev/null
operations_auth_line=$(grep -n 'clientAuth.Configure(ctx, resources, cfg)' "$operations_cli" | cut -d: -f1)
operations_publish_line=$(grep -n 'return publishLocalOperationsClientAuthority(resources, clientAuth)' "$operations_cli" | cut -d: -f1)
operations_setup_line=$(grep -n 'if err := configureLocalOperationsClientAuth(ctx, resources, cfg); err != nil {' "$operations_cli" | cut -d: -f1)
operations_start_line=$(grep -n 'startLocalOperationsRuntime(ctx, resources)' "$operations_cli" | cut -d: -f1)
[ -n "$operations_auth_line" ] && [ -n "$operations_publish_line" ] && [ -n "$operations_setup_line" ] && [ -n "$operations_start_line" ] && [ "$operations_auth_line" -lt "$operations_publish_line" ] && [ "$operations_setup_line" -lt "$operations_start_line" ] || {
  printf 'backup restore operations path does not publish client authority before runtime start\n' >&2
  exit 1
}
grep -F 'release-backup-restore-(run|cleanup|database-quarantine|node-start)' "$owner" >/dev/null
grep -F 'unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW' "$root/Services/PlainpostGo/cmd/plainpost-sync-node/operations_cli.go" >/dev/null
grep -F 'unix.Openat(parentFD, filepath.Base(path)' "$root/Services/PlainpostGo/cmd/plainpost-sync-node/operations_cli.go" >/dev/null
if grep -F 'docker compose' "$runner" | grep -F ' restart ' >/dev/null; then
  printf 'backup restore contract must not use Compose restart\n' >&2
  exit 1
fi

stop_line=$(grep -n '^compose_env stop --timeout 10 node-one' "$runner" | cut -d: -f1)
backup_line=$(grep -n 'node-one operations backup' "$runner" | cut -d: -f1)
restore_line=$(grep -n 'node-one operations restore --backup "/node-data/backups/restore-input.ppb"' "$runner" | cut -d: -f1)
[ -n "$stop_line" ] && [ -n "$backup_line" ] && [ -n "$restore_line" ] || {
  printf 'backup restore contract missing ordered lifecycle commands\n' >&2
  exit 1
}
[ "$stop_line" -lt "$backup_line" ] && [ "$backup_line" -lt "$restore_line" ] || {
  printf 'backup restore contract lifecycle order is invalid\n' >&2
  exit 1
}

grep -F 'ALLOW_CONNECTIONS false' "$owner" >/dev/null
grep -F 'psql -U plainpost_restore_admin -d postgres' "$owner" >/dev/null
quarantine_output_probe="$contract_tmp/quarantine-output-probe"
printf '%s\n' false quarantine-complete 'ERROR controller-child-reaped action=release-backup-restore-database-quarantine status=0' >"$quarantine_output_probe"
quarantine_state_probe=$(grep -Ex 'quarantine-complete' "$quarantine_output_probe" | tail -n 1)
[ "$quarantine_state_probe" = quarantine-complete ] || {
  printf 'quarantine contract could not isolate the SQL state from controller output\n' >&2
  exit 1
}
printf '%s\n' false quarantine-incomplete 'ERROR controller-child-reaped action=release-backup-restore-database-quarantine status=0' >"$quarantine_output_probe"
if grep -Ex 'quarantine-complete' "$quarantine_output_probe" >/dev/null; then
  printf 'quarantine contract accepted an incomplete terminal database state\n' >&2
  exit 1
fi
grep -F "grep -Ex 'quarantine-complete' \"\$release_quarantine_output\"" "$owner" >/dev/null || {
  printf 'quarantine owner must select the terminal database state, not the controller status line\n' >&2
  exit 1
}
grep -F 'quarantine-complete' "$owner" >/dev/null || {
  printf 'quarantine owner must emit a unique terminal database sentinel\n' >&2
  exit 1
}
grep -F 'original-database-quarantined=1' "$owner" >/dev/null
grep -F 'audit_database_url' "$owner" "$release_override_writer" >/dev/null
grep -F 'chmod 0600 "$release_audit_database_url_pending"' "$owner" >/dev/null
grep -F 'refresh_active_node_database_name' "$owner" >/dev/null
grep -F 'restore-references/database' "$owner" >/dev/null
if grep -F '[ -f "$refresh_reference" ]' "$owner" >/dev/null; then
  printf 'backup restore contract must use descriptor-safe active reference reads\n' >&2
  exit 1
fi
quarantine_line=$(grep -n 'original-database-quarantined=1' "$owner" | cut -d: -f1)
owner_start_line=$(grep -n 'docker compose -p "\$project" -f "\$compose" -f "\$transport_release_override" start node-one' "$owner" | tail -n 1 | cut -d: -f1)
[ -n "$quarantine_line" ] && [ -n "$owner_start_line" ] && [ "$quarantine_line" -lt "$owner_start_line" ] || {
  printf 'backup restore contract must quarantine original database before node start\n' >&2
  exit 1
}
attachments_quarantine_line=$(grep -n 'original-attachments-quarantined=1' "$owner" | cut -d: -f1)
[ -n "$attachments_quarantine_line" ] && [ "$attachments_quarantine_line" -lt "$owner_start_line" ] || {
  printf 'backup restore contract must quarantine original attachments before node start\n' >&2
  exit 1
}
swift_wait_line=$(grep -n '^wait "\$swift_pid"' "$owner" | tail -n 1 | cut -d: -f1)
active_refresh_line=$(grep -n '^  refresh_active_node_database_name required || {' "$owner" | tail -n 1 | cut -d: -f1)
[ -n "$swift_wait_line" ] && [ -n "$active_refresh_line" ] && [ "$swift_wait_line" -lt "$active_refresh_line" ] || {
  printf 'backup restore contract must refresh active database reference after Swift completion\n' >&2
  exit 1
}
if grep -F 'mv -f "$release_database_url_tmp" "$temporary/node-one-secrets/database_url"' "$owner" >/dev/null; then
  printf 'backup restore contract must not rewrite canonical database URL\n' >&2
  exit 1
fi
if grep -F -- '-node-one-database-file /run/node-one-secrets/database_url' "$release_override_writer" >/dev/null; then
  printf 'backup restore contract must audit the restored database reference\n' >&2
  exit 1
fi
if grep -F 'compose_env start node-one' "$runner" >/dev/null; then
  printf 'backup restore runner must return before node start\n' >&2
  exit 1
fi

if grep -F 'notification' "$scenario" | grep -F 'backup-restore' >/dev/null; then
  printf 'backup restore contract must not synthesize notification evidence\n' >&2
  exit 1
fi

printf 'sync_node_private_transport_backup_restore_contract=passed\n'
