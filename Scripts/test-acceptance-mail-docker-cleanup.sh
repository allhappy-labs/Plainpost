#!/bin/sh
set -eu

script_dir=$(dirname -- "$0")
root_dir=$(cd "$script_dir/.." && pwd)
helper="$root_dir/Scripts/lib/plainpost_acceptance_docker_cleanup.sh"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/plainpost-mail-cleanup.XXXXXX")
fake_bin="$temporary/bin"
mkdir "$fake_bin"
trap 'find "$temporary" -depth -mindepth 1 -delete; rmdir "$temporary"' EXIT

cat >"$fake_bin/docker" <<'FAKE_DOCKER'
#!/bin/sh
if [ -n "${DOCKER_LOG:-}" ]; then
  echo "$1:$2" >>"$DOCKER_LOG"
fi
case "$1:$2" in
  rm:*) exit 0 ;;
  inspect:retained) exit 0 ;;
  inspect:daemon-failure) echo 'permission denied contacting daemon' >&2; exit 1 ;;
  inspect:*) echo 'Error: no such container' >&2; exit 1 ;;
  *) exit 1 ;;
esac
FAKE_DOCKER
chmod 0755 "$fake_bin/docker"

run_case() {
  case_name=$1
  expected=$2
  PATH="$fake_bin:$PATH" CASE="$case_name" TEMPORARY="$temporary" sh -eu -c '
    temporary=$TEMPORARY
    container_children=""
    container_ids="$CASE"
    . "$0"
    set +e
    cleanup_captured_containers
    actual=$?
    set -e
    [ "$actual" -eq "$1" ]
    [ -z "$container_ids" ]
  ' "$helper" "$expected"
}

run_case success-absence 0
run_case retained 1
run_case daemon-failure 1
DOCKER_LOG="$temporary/foreign-log" PATH="$fake_bin:$PATH" TEMPORARY="$temporary" sh -eu -c '
  temporary=$TEMPORARY
  container_children=""
  container_ids=""
  . "$0"
  cleanup_captured_containers
' "$helper"
[ ! -s "$temporary/foreign-log" ]

reap_marker="$temporary/reap-marker"
set +e
PATH="$fake_bin:$PATH" REAP_MARKER="$reap_marker" sh -eu -c '
  (exit 7) & first=$!
  (sleep 30) & second=$!
  first_status=0
  if wait "$first"; then
    :
  else
    first_status=$?
  fi
  container_children=" $second"
  first=""
  touch "$REAP_MARKER"
  kill -TERM "$second" 2>/dev/null || true
  wait "$second" 2>/dev/null || true
  exit "$first_status"
' >/dev/null 2>&1
reap_status=$?
set -e
[ "$reap_status" -eq 7 ]
[ -f "$reap_marker" ]

PATH="$fake_bin:$PATH" TEMPORARY="$temporary" sh -eu -c '
  temporary=$TEMPORARY
  (trap "exit 143" TERM; while :; do sleep 1; done) &
  child=$!
  container_children="$child"
  container_ids=""
  . "$0"
  cleanup_captured_containers
  [ -z "$container_children" ]
  if kill -0 "$child" 2>/dev/null; then
    echo "cleanup left terminated child alive" >&2
    exit 1
  fi
' "$helper"

echo "acceptance-mail-docker-cleanup=passed"
