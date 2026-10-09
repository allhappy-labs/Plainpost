#!/bin/sh
set -eu

script_dir=$(dirname -- "$0")
root_dir=$(cd "$script_dir/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/plainpost-mail-control.XXXXXX")
cleanup_helper="$root_dir/Scripts/lib/plainpost_acceptance_docker_cleanup.sh"
if [ ! -r "$cleanup_helper" ]; then
  echo "missing Docker cleanup helper" >&2
  exit 1
fi
# shellcheck source=Scripts/lib/plainpost_acceptance_docker_cleanup.sh
. "$cleanup_helper"
run_id="$$-$(date +%s)"
container_label="com.plainpost.acceptance.run=$run_id"
container_ids=''
container_children=''
container_image='python:3.13-alpine@sha256:399babc8b49529dabfd9c922f2b5eea81d611e4512e3ed250d75bd2e7683f4b0'
cleanup() {
  status=$?
  trap - EXIT INT TERM
  cleanup_status=0
  cleanup_captured_containers || cleanup_status=1
  if ! find "$temporary" -depth -mindepth 1 -delete; then
    cleanup_status=1
  fi
  if ! rmdir "$temporary"; then
    cleanup_status=1
  fi
  if [ "$status" -ne 0 ]; then
    if [ "$cleanup_status" -ne 0 ]; then
      echo "cleanup failed after status $status" >&2
    fi
    exit "$status"
  fi
  exit "$cleanup_status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export PYTHONPATH="$root_dir/Scripts/lib"
export PLAINPOST_ACCEPTANCE_MAIL_ROOT="$temporary"

mail_tls="$temporary/mail-tls"
mkdir -m 0700 "$mail_tls"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
  -subj '/CN=Plainpost Acceptance Mail' \
  -addext 'subjectAltName=DNS:localhost' \
  -keyout "$mail_tls/server.key" -out "$mail_tls/server.crt" >/dev/null 2>&1
chmod 0600 "$mail_tls/server.key" "$mail_tls/server.crt"

create_container() {
  id=$(docker create --label "$container_label" "$@") || return 1
  case "$id" in
    ''|*[!0-9a-fA-F]*) return 1 ;;
  esac
  container_ids="$container_ids $id"
  created_container_id=$id
}

run_container() {
  id=$1
  shift
  docker start -a "$id" "$@"
}

python3 -c 'import sqlite3; assert sqlite3.sqlite_version_info >= (3, 35), sqlite3.sqlite_version'
state_module="$root_dir/Scripts/lib/plainpost_acceptance_mail_state.py"
grep -F 'FAILPOINTS' "$state_module" >/dev/null
if grep -E 'message_digest[^\n]*UNIQUE' "$state_module" >/dev/null; then
  echo "delivery digest must not be unique" >&2
  exit 1
fi
grep -F "$container_image" "$root_dir/Deploy/acceptance/compose.private-transport.yaml" >/dev/null
create_container --network none -v "$temporary:/var/lib/plainpost:rw" -v "$root_dir/Scripts/lib:/opt/plainpost:ro" -e PLAINPOST_ACCEPTANCE_MAIL_ROOT=/var/lib/plainpost -e PYTHONPATH=/opt/plainpost "$container_image" python -c 'import sqlite3; assert sqlite3.sqlite_version_info >= (3, 35), sqlite3.sqlite_version; import plainpost_acceptance_mail_state as state; state.initialize()'
container_init=$created_container_id
run_container "$container_init"
create_container --network none -v "$temporary:/var/lib/plainpost:rw" -v "$root_dir/Scripts/lib:/opt/plainpost:ro" -e PLAINPOST_ACCEPTANCE_MAIL_ROOT=/var/lib/plainpost -e PYTHONPATH=/opt/plainpost "$container_image" python -c 'import plainpost_acceptance_mail_state as state; state.transaction(lambda current: current.update({"container_probe": "written"}))'
container_first=$created_container_id
create_container --network none -v "$temporary:/var/lib/plainpost:rw" -v "$root_dir/Scripts/lib:/opt/plainpost:ro" -e PLAINPOST_ACCEPTANCE_MAIL_ROOT=/var/lib/plainpost -e PYTHONPATH=/opt/plainpost "$container_image" python -c 'import plainpost_acceptance_mail_state as state; state.transaction(lambda current: current.update({"container_probe_two": "written"}))'
container_second=$created_container_id
run_container "$container_first" & first_container=$!
container_children="$container_children $first_container"
run_container "$container_second" & second_container=$!
container_children="$container_children $second_container"
first_status=0
if wait "$first_container"; then
  :
else
  first_status=$?
fi
container_children=" $second_container"
first_container=''
if [ "$first_status" -ne 0 ]; then
  exit "$first_status"
fi
second_status=0
if wait "$second_container"; then
  :
else
  second_status=$?
fi
container_children=''
second_container=''
if [ "$second_status" -ne 0 ]; then
  exit "$second_status"
fi
create_container --network none -v "$temporary:/var/lib/plainpost:rw" -v "$root_dir/Scripts/lib:/opt/plainpost:ro" -e PLAINPOST_ACCEPTANCE_MAIL_ROOT=/var/lib/plainpost -e PYTHONPATH=/opt/plainpost "$container_image" python -c 'import plainpost_acceptance_mail_state as state; assert state.read()["container_probe"] == "written" and state.read()["container_probe_two"] == "written"'
container_read=$created_container_id
run_container "$container_read"
python3 "$root_dir/Scripts/lib/plainpost_acceptance_mail_control.py" arm-fault smtp-delivery 2 temporary >/dev/null
create_container --network none -v "$temporary:/var/lib/plainpost:rw" -v "$root_dir/Scripts/lib:/opt/plainpost:ro" -v "$mail_tls:/run/tls:ro" -e PLAINPOST_ACCEPTANCE_MAIL_ROOT=/var/lib/plainpost -e PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT=/run/tls/server.crt -e PLAINPOST_ACCEPTANCE_MAIL_TLS_KEY=/run/tls/server.key -e PYTHONPATH=/opt/plainpost "$container_image" python /opt/plainpost/plainpost_acceptance_mail_docker_wire_probe.py
container_wire=$created_container_id
run_container "$container_wire"
python3 - "$temporary" "$root_dir/Scripts/lib/plainpost_acceptance_mail_control.py" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
control = sys.argv[2]
output = subprocess.check_output([
    "python3", control, "--root", str(root), "status",
], text=True)
status = json.loads(output)
faults = status["faults"]
observations = [item for item in status["observations"] if item["kind"] == "fault-fired"]
if len(faults) != 1 or faults[0]["seen"] != 3 or faults[0]["consumed"] != 1 or len(observations) != 1:
    raise SystemExit(f"unexpected mounted SMTP authority: {status}")
if status["delivery_count"] != 2:
    raise SystemExit(f"unexpected mounted SMTP delivery count: {status['delivery_count']}")
PY
python3 "$root_dir/Scripts/lib/plainpost_acceptance_mail_control.py" phase smtp delivery 1 pause >/dev/null
python3 "$root_dir/Scripts/lib/plainpost_acceptance_mail_control.py" phase smtp delivery 1 resume >/dev/null
python3 "$root_dir/Scripts/lib/plainpost_acceptance_mail_control.py" phase smtp delivery 2 delay --delay-ms 1 >/dev/null
if python3 "$root_dir/Scripts/lib/plainpost_acceptance_mail_control.py" wait-phase smtp delivery 99 --timeout-ms 1 >/dev/null 2>&1; then
  echo "unobserved phase unexpectedly succeeded" >&2
  exit 1
fi
if python3 "$root_dir/Scripts/lib/plainpost_acceptance_mail_control.py" arm-fault arbitrary 1 temporary >/dev/null 2>&1; then
  echo "arbitrary fault name accepted" >&2
  exit 1
fi
if python3 "$root_dir/Scripts/lib/plainpost_acceptance_mail_control.py" phase smtp delivery 1001 pause >/dev/null 2>&1; then
  echo "unbounded occurrence accepted" >&2
  exit 1
fi
if python3 "$root_dir/Scripts/lib/plainpost_acceptance_mail_control.py" phase smtp delivery 1 pause --delay-ms 1 >/dev/null 2>&1; then
  echo "delay attached to non-delay action" >&2
  exit 1
fi
python3 - "$temporary" <<'PY'
import stat
import sys
from pathlib import Path
root = Path(sys.argv[1])
required = ["mail-state.sqlite3", "mail-state.lock", "mail-state-transaction.lock", "mail-control.json", "mail-observations.jsonl", "mailbox.json", "smtp-deliveries.jsonl", "mail-tls/server.crt", "mail-tls/server.key"]
for name in required:
    path = root / name
    if not path.exists():
        raise SystemExit(f"missing {name}")
    if stat.S_IMODE(path.stat().st_mode) != 0o600:
        raise SystemExit(f"{name} is not mode 0600")
PY
echo "acceptance-mail-control-contract=passed"
