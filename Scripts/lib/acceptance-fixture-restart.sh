#!/bin/sh
set -eu

helper_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$helper_root/acceptance-controller.sh"
. "$helper_root/acceptance-fixture-crash-category.sh"

compose=$1
project=$2
temporary=$3
fixture_service=$4
node_image=$5
node_uid=$6
node_gid=$7
attachment_storage=$8
attachment_dir=$9
drop_responses=${10}
s3_endpoint=${11}
s3_bucket=${12}
s3_region=${13}
s3_addressing=${14}
s3_access_key_file=${15}
s3_secret_key_file=${16}
smtp_password_file=${17}

case "$fixture_service" in
  imap-fixture|smtp-fixture) ;;
  *) exit 1 ;;
esac

fixture_marker() {
  fixture_marker_event=$1
  fixture_marker_outcome=$2
  fixture_marker_attempt=${3:-}
  fixture_marker_class=${4:-}
  fixture_marker_exit=${5:-}
  fixture_marker_state=${6:-}
  fixture_marker_health=${7:-}
  fixture_marker_restart_count=${8:-}
  if [ -n "$fixture_marker_attempt" ]; then
    if [ -n "$fixture_marker_class" ]; then
      if [ -n "$fixture_marker_exit" ]; then
        if [ -n "$fixture_marker_state" ]; then
          printf 'ERROR acceptance-fixture-restart fixture=%s event=%s attempt=%s outcome=%s class=%s exit=%s state=%s health=%s restart_count=%s\n' \
            "$fixture_service" "$fixture_marker_event" "$fixture_marker_attempt" "$fixture_marker_outcome" "$fixture_marker_class" "$fixture_marker_exit" "$fixture_marker_state" "$fixture_marker_health" "$fixture_marker_restart_count"
        else
          printf 'ERROR acceptance-fixture-restart fixture=%s event=%s attempt=%s outcome=%s class=%s exit=%s\n' \
            "$fixture_service" "$fixture_marker_event" "$fixture_marker_attempt" "$fixture_marker_outcome" "$fixture_marker_class" "$fixture_marker_exit"
        fi
      else
        printf 'ERROR acceptance-fixture-restart fixture=%s event=%s attempt=%s outcome=%s class=%s\n' \
          "$fixture_service" "$fixture_marker_event" "$fixture_marker_attempt" "$fixture_marker_outcome" "$fixture_marker_class"
      fi
    else
      printf 'ERROR acceptance-fixture-restart fixture=%s event=%s attempt=%s outcome=%s\n' \
        "$fixture_service" "$fixture_marker_event" "$fixture_marker_attempt" "$fixture_marker_outcome"
    fi
  else
    printf 'ERROR acceptance-fixture-restart fixture=%s event=%s outcome=%s\n' \
      "$fixture_service" "$fixture_marker_event" "$fixture_marker_outcome"
  fi
}

compose_run() {
  PLAINPOST_PRIVATE_ROOT="$temporary" \
  PLAINPOST_PRIVATE_NODE_IMAGE="$node_image" \
  PLAINPOST_ACCEPTANCE_NODE_UID="$node_uid" \
  PLAINPOST_ACCEPTANCE_NODE_GID="$node_gid" \
  PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE="$attachment_storage" \
  PLAINPOST_ACCEPTANCE_ATTACHMENT_DIR="$attachment_dir" \
  PLAINPOST_ACCEPTANCE_DROP_RESPONSES="$drop_responses" \
  PLAINPOST_ACCEPTANCE_S3_ENDPOINT="$s3_endpoint" \
  PLAINPOST_ACCEPTANCE_S3_BUCKET="$s3_bucket" \
  PLAINPOST_ACCEPTANCE_S3_REGION="$s3_region" \
  PLAINPOST_ACCEPTANCE_S3_ADDRESSING="$s3_addressing" \
  PLAINPOST_ACCEPTANCE_S3_ACCESS_KEY_FILE="$s3_access_key_file" \
  PLAINPOST_ACCEPTANCE_S3_SECRET_KEY_FILE="$s3_secret_key_file" \
  docker compose -p "$project" -f "$compose" "$@"
}

if ! fixture_container=$(compose_run ps -q "$fixture_service"); then
  fixture_marker container-resolve failed
  exit 1
fi
if [ -z "$fixture_container" ]; then
  fixture_marker container-resolve failed
  exit 1
fi
fixture_marker container-resolve ready
fixture_marker compose-restart begin
if ! compose_run restart "$fixture_service"; then
  fixture_marker compose-restart failed
  exit 1
fi
fixture_marker compose-restart end
cleanup_probe_password() {
  docker exec "$fixture_container" rm -f /tmp/plainpost-smtp-probe-password >/dev/null 2>&1 || true
}
trap cleanup_probe_password EXIT

capture_fixture_state() {
  fixture_state_snapshot=$(docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}' "$fixture_container" 2>/dev/null || true)
  fixture_probe_state=${fixture_state_snapshot%%|*}
  fixture_probe_state_remainder=${fixture_state_snapshot#*|}
  fixture_probe_health=${fixture_probe_state_remainder%%|*}
  fixture_probe_restart_count=${fixture_probe_state_remainder#*|}
  case "$fixture_probe_state" in
    created|running|restarting|removing|paused|exited|dead) ;;
    *) fixture_probe_state=unknown ;;
  esac
  case "$fixture_probe_health" in
    none|starting|healthy|unhealthy) ;;
    *) fixture_probe_health=unknown ;;
  esac
  case "$fixture_probe_restart_count" in
    ''|*[!0-9]*) fixture_probe_restart_count=unknown ;;
  esac
}

capture_fixture_crash_classification() {
  [ "$fixture_service" = smtp-fixture ] || return 0
  case "${fixture_probe_state:-unknown}" in
    exited|dead) ;;
    *) return 0 ;;
  esac

  fixture_crash_exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$fixture_container" 2>/dev/null || printf 'unknown')
  case "$fixture_crash_exit_code" in
    ''|*[!0-9]*) fixture_crash_exit_code=unknown ;;
  esac
  fixture_crash_oom=$(docker inspect --format '{{.State.OOMKilled}}' "$fixture_container" 2>/dev/null || printf 'unknown')
  case "$fixture_crash_oom" in
    true|false) ;;
    *) fixture_crash_oom=unknown ;;
  esac

  # Docker logs are retained only in a mode-0600 temporary file while the
  # allowlisted classifier reads them. Never send raw logs to the acceptance
  # stream, and remove the private capture immediately after classification.
  fixture_crash_log="$temporary/control/$fixture_service.crash.log"
  (umask 077; : >"$fixture_crash_log"; chmod 0600 "$fixture_crash_log"; docker logs "$fixture_container" >"$fixture_crash_log" 2>&1 || true)
  fixture_crash_cause=$(acceptance_fixture_crash_category "$fixture_crash_log")
  if [ "$fixture_crash_cause" = sqlite-operational ]; then
    fixture_crash_sqlite_subcategory=$(acceptance_fixture_sqlite_subcategory "$fixture_crash_log")
    fixture_crash_sqlite_operation=$(acceptance_fixture_sqlite_operation "$fixture_crash_log")
    printf 'ERROR acceptance-fixture-restart fixture=%s event=crash-classification exit_code=%s oom=%s cause=%s sqlite_subcategory=%s sqlite_operation=%s\n' \
      "$fixture_service" "$fixture_crash_exit_code" "$fixture_crash_oom" "$fixture_crash_cause" \
      "$fixture_crash_sqlite_subcategory" "$fixture_crash_sqlite_operation"
  else
    printf 'ERROR acceptance-fixture-restart fixture=%s event=crash-classification exit_code=%s oom=%s cause=%s\n' \
      "$fixture_service" "$fixture_crash_exit_code" "$fixture_crash_oom" "$fixture_crash_cause"
  fi
  rm -f "$fixture_crash_log"
}

probe_fixture_protocol() {
fixture_probe_failure_class=probe-command
fixture_probe_failure_exit=''
if [ "$fixture_service" = smtp-fixture ]; then
  [ "$(stat -f '%Lp' "$smtp_password_file" 2>/dev/null || stat -c '%a' "$smtp_password_file")" = 600 ]
  docker cp "$smtp_password_file" "$fixture_container:/tmp/plainpost-smtp-probe-password"
  docker exec "$fixture_container" chmod 0600 /tmp/plainpost-smtp-probe-password
  # The fixture has no host publication. Run the complete protocol probe
  # inside its container so 127.0.0.1 is the fixture network namespace.
  fixture_probe_output=''
  fixture_probe_exit=0
  if fixture_probe_output=$(docker exec -i \
    "$fixture_container" python3 - 2>/dev/null <<'PY'
import base64
import socket
import ssl

CONNECTION_REFUSED = 75
PROTOCOL_TIMEOUT = 76
TLS_FAILURE = 77
PROTOCOL_FAILURE = 78
print("PLAINPOST_SMTP_PROBE_STARTED", flush=True)

def response(stream):
    data = b""
    while True:
        chunk = stream.recv(4096)
        if not chunk:
            raise RuntimeError("SMTP peer closed")
        data += chunk
        if any(line.startswith(b"250 ") for line in data.splitlines()):
            return data

try:
    stream = socket.create_connection(("127.0.0.1", 587), timeout=2)
    stream.settimeout(2)
    password = open("/tmp/plainpost-smtp-probe-password", encoding="utf-8").read().strip()
    if not stream.recv(4096).startswith(b"220 "):
        raise RuntimeError("SMTP greeting failed")
    stream.sendall(b"EHLO plainpost-restart-probe\r\n")
    if b"STARTTLS" not in response(stream):
        raise RuntimeError("SMTP STARTTLS capability missing")
    stream.sendall(b"STARTTLS\r\n")
    if not stream.recv(4096).startswith(b"220 "):
        raise RuntimeError("SMTP STARTTLS command failed")
    stream = ssl._create_unverified_context().wrap_socket(stream, server_hostname="localhost")
    stream.sendall(b"EHLO plainpost-restart-probe\r\n")
    if b"AUTH PLAIN" not in response(stream):
        raise RuntimeError("SMTP AUTH capability missing after TLS")
    payload = base64.b64encode(("\0acceptance@example.test\0" + password).encode())
    stream.sendall(b"AUTH PLAIN " + payload + b"\r\n")
    if not stream.recv(4096).startswith(b"235 "):
        raise RuntimeError("SMTP AUTH failed")
    stream.sendall(b"QUIT\r\n")
    stream.close()
except ConnectionRefusedError:
    raise SystemExit(CONNECTION_REFUSED)
except (TimeoutError, socket.timeout):
    raise SystemExit(PROTOCOL_TIMEOUT)
except ssl.SSLError:
    raise SystemExit(TLS_FAILURE)
except (OSError, RuntimeError, ValueError):
    raise SystemExit(PROTOCOL_FAILURE)
except BaseException:
    raise SystemExit(79)
PY
  )
  then
    return 0
  else
    fixture_probe_exit=$?
    fixture_probe_failure_exit=$fixture_probe_exit
    if printf '%s\n' "$fixture_probe_output" | grep -F -x 'PLAINPOST_SMTP_PROBE_STARTED' >/dev/null 2>&1; then
      case "$fixture_probe_exit" in
        75) fixture_probe_failure_class=connection-refused ;;
        76) fixture_probe_failure_class=protocol-timeout ;;
        77) fixture_probe_failure_class=tls-failure ;;
        78) fixture_probe_failure_class=protocol-failure ;;
        79) fixture_probe_failure_class=unexpected-runtime ;;
        *) fixture_probe_failure_class=python-exit ;;
      esac
    else
      fixture_probe_failure_class=docker-exec
    fi
    return 1
  fi
else
  docker exec -i "$fixture_container" python3 - <<'PY'
import socket
import ssl

context = ssl._create_unverified_context()
stream = context.wrap_socket(socket.create_connection(("127.0.0.1", 993), timeout=2), server_hostname="localhost")
stream.settimeout(2)
if not stream.recv(128).startswith(b"*"):
    raise RuntimeError("IMAP greeting failed")
stream.sendall(b"a001 LOGOUT\r\n")
stream.close()
PY
fi
}

# Compose restart returning only means the container was restarted; its
# protocol listener and TLS/auth stack can become ready slightly later. The
# helper runs inside the controller's 20-second child budget. The controller
# is the sole wall-clock owner; the fixture's one-second Compose stop grace
# preserves that budget, while six is the bounded retry count. SMTP probe
# failures are reduced to fixed classes so a failed gate retains diagnostic
# evidence without copying Python errors, credentials, or container values.
fixture_probe_attempts=${PLAINPOST_ACCEPTANCE_FIXTURE_PROBE_ATTEMPTS:-6}
fixture_probe_delay_seconds=${PLAINPOST_ACCEPTANCE_FIXTURE_PROBE_DELAY_SECONDS:-0.5}
fixture_probe_status=1
fixture_probe_attempt=1
while [ "$fixture_probe_attempt" -le "$fixture_probe_attempts" ]; do
  if probe_fixture_protocol; then
    fixture_marker probe ready "$fixture_probe_attempt"
    fixture_probe_status=0
    break
  fi
  if [ "$fixture_service" = smtp-fixture ]; then
    capture_fixture_state
    fixture_marker probe unavailable "$fixture_probe_attempt" "$fixture_probe_failure_class" "$fixture_probe_failure_exit" \
      "$fixture_probe_state" "$fixture_probe_health" "$fixture_probe_restart_count"
  else
    fixture_marker probe unavailable "$fixture_probe_attempt"
  fi
  if [ "$fixture_probe_attempt" -lt "$fixture_probe_attempts" ]; then
    sleep "$fixture_probe_delay_seconds"
  fi
  fixture_probe_attempt=$((fixture_probe_attempt + 1))
done
if [ "$fixture_probe_status" -ne 0 ]; then
  capture_fixture_crash_classification
  exit 1
fi

fixture_marker status-capture begin
if ! docker exec "$fixture_container" python3 /opt/plainpost/plainpost_acceptance_mail_control.py \
  --root /var/lib/plainpost status >"$temporary/control/$fixture_service.status"; then
  fixture_marker status-capture failed
  exit 1
fi
if ! chmod 0600 "$temporary/control/$fixture_service.status"; then
  fixture_marker status-capture failed
  exit 1
fi
fixture_marker status-capture end
