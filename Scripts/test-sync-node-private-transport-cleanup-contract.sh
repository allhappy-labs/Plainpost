#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
target="$root/Scripts/test-sync-node-private-transport.sh"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/plainpost-private-transport-cleanup-owner.XXXXXX")
state="$fixture/state"
bin="$fixture/bin"
output="$fixture/output"
private_marker='cleanup-owner-private-marker-must-not-echo'

cleanup_fixture() {
  if [ "${PLAINPOST_CLEANUP_OWNER_KEEP_FIXTURE:-0}" = 1 ]; then
    printf 'cleanup owner fixture retained at %s\n' "$fixture" >&2
    return
  fi
  rm -rf "$fixture"
}
trap cleanup_fixture EXIT HUP INT TERM
mkdir -m 0700 "$state" "$bin"

cat >"$bin/go" <<'EOF'
#!/bin/sh
set -eu
output=''
make_output=false
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    output=$2
    make_output=true
    shift 2
    continue
  fi
  if [ "$1" = -output ]; then
    output=$2
    shift 2
    continue
  fi
  shift
done
if [ "$make_output" = true ] && [ -n "$output" ]; then
  mkdir -p "$(dirname -- "$output")"
  : >"$output"
fi
EOF
chmod 0755 "$bin/go"

cat >"$bin/docker" <<'EOF'
#!/bin/sh
set -eu

state=$PLAINPOST_CLEANUP_OWNER_STATE
marker=$PLAINPOST_CLEANUP_OWNER_PRIVATE_MARKER

project_from_compose() {
  while [ "$#" -gt 0 ]; do
    if [ "$1" = -p ]; then
      printf '%s\n' "$2"
      return 0
    fi
    shift
  done
  return 1
}

case "$1" in
  version)
    printf 'arm64\n'
    ;;
  build)
    : >"$state/image"
    ;;
  compose)
    shift
    project=$(project_from_compose "$@")
    command=''
    for argument in "$@"; do
      case "$argument" in up|down) command=$argument;; esac
    done
    case "$command" in
      up)
        printf '%s\n' "$PLAINPOST_PRIVATE_ROOT" >"$state/temporary"
        printf '%s\n' "$project" >"$state/project"
        : >"$state/container"
        : >"$state/volume"
        : >"$state/network"
        : >"$state/unrelated"
        exit 1
        ;;
      down)
        : >"$state/compose-down-attempted"
        printf '%s\n' "$marker" >&2
        exit 1
        ;;
    esac
    ;;
  image)
    case "$2" in
      inspect)
        [ -e "$state/image" ]
        ;;
      rm)
        : >"$state/image-rm-attempted"
        printf '%s\n' "$marker" >&2
        exit 1
        ;;
    esac
    ;;
  ps)
    [ -e "$state/container" ] && printf 'run-container\n'
    exit 0
    ;;
  volume)
    case "$2" in
      ls)
        [ -e "$state/volume" ] && printf 'run-volume\n'
        exit 0
        ;;
      rm)
        [ "$3" = run-volume ]
        rm -f "$state/volume"
        ;;
    esac
    ;;
  network)
    case "$2" in
      ls)
        [ -e "$state/network" ] && printf 'run-network\n'
        exit 0
        ;;
      rm)
        [ "$3" = run-network ]
        rm -f "$state/network"
        ;;
    esac
    ;;
  rm)
    [ "$2" = -f ] && [ "$3" = run-container ]
    rm -f "$state/container"
    ;;
  *)
    printf 'unexpected fake Docker command: %s\n' "$1" >&2
    exit 99
    ;;
esac
EOF
chmod 0755 "$bin/docker"

status=0
PATH="$bin:$PATH" \
PLAINPOST_CLEANUP_OWNER_STATE="$state" \
PLAINPOST_CLEANUP_OWNER_PRIVATE_MARKER="$private_marker" \
"$target" >"$output" 2>&1 || status=$?

[ "$status" -ne 0 ]
[ -s "$state/temporary" ]
[ -e "$state/compose-down-attempted" ]
[ -e "$state/image-rm-attempted" ]
[ ! -e "$(cat "$state/temporary")" ]
[ ! -e "$state/container" ]
[ ! -e "$state/volume" ]
[ ! -e "$state/network" ]
[ -e "$state/unrelated" ]
grep -F 'private acceptance cleanup failed category=compose-down' "$output" >/dev/null
grep -F 'private acceptance cleanup failed category=runtime-image' "$output" >/dev/null
if grep -F "$private_marker" "$output" >/dev/null; then
  printf 'cleanup owner leaked its private marker\n' >&2
  exit 1
fi
printf 'sync_node_private_transport_cleanup_owner=passed\n'
