#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
helper="$root/Scripts/lib/prepare-container-secret-ownership.sh"
image='postgres:18.6-alpine3.24@sha256:d3e1620b530c944afa6e887d22eb899824da68e19c52024bf98f5220c88a65b2'
fixture=$(mktemp -d /private/tmp/plainpost-secret-ownership-live.XXXXXX)
project="plainpost-secret-ownership-live-$$"
cleanup() {
  docker compose -p "$project" -f "$fixture/compose.yaml" down --volumes --remove-orphans >/dev/null 2>&1 || true
  find "$fixture" -depth -delete >/dev/null 2>&1 || true
}
on_signal() {
  local status=$1
  trap - EXIT HUP INT TERM
  cleanup
  exit "$status"
}
trap cleanup EXIT
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

fail() {
  printf 'live secret ownership contract: %s\n' "$*" >&2
  exit 1
}

[[ -x "$helper" ]] || fail 'secret ownership helper is unavailable'
command -v docker >/dev/null || fail 'docker is unavailable'
command -v go >/dev/null || fail 'go is unavailable'

mkdir -m 0700 "$fixture/node-one-secrets" "$fixture/control"
mkdir -m 0700 "$fixture/go-cache"
(
  cd "$root/Services/PlainpostGo"
  GOCACHE="$fixture/go-cache" \
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
    go test -c -trimpath -o "$fixture/reader" ./internal/central/config
)
chmod 0755 "$fixture/reader"

cat >"$fixture/compose.yaml" <<YAML
services:
  consumer:
    image: $image
    user: "65532:65532"
    entrypoint: ["/reader"]
    command: ["-test.run", "^TestReadDatabaseURLFileMountedConsumer$", "-test.count=1", "-test.timeout=30s"]
    environment:
      PLAINPOST_DATABASE_URL_FILE_CONSUMER: enabled
      PLAINPOST_DATABASE_URL_FILE: /run/node-one-secrets/audit_database_url
      PLAINPOST_DATABASE_URL_FILE_GATE: /fixture/control/read
    volumes:
      - type: bind
        source: $fixture/reader
        target: /reader
        read_only: true
      - type: bind
        source: $fixture/node-one-secrets
        target: /run/node-one-secrets
        read_only: true
      - type: bind
        source: $fixture/control
        target: /fixture/control
YAML

prepare_files() {
  rm -f -- "$fixture/node-one-secrets/audit_database_url" \
    "$fixture/node-one-secrets/audit_database_url.pending" \
    "$fixture/control/read"
  : >"$fixture/node-one-secrets/audit_database_url"
  printf '%s\n' 'postgres://consumer:password@example.invalid/db?sslmode=verify-full' \
    >"$fixture/node-one-secrets/audit_database_url.pending"
  chmod 0600 "$fixture/node-one-secrets/audit_database_url" \
    "$fixture/node-one-secrets/audit_database_url.pending"
  # Match release setup: the secret directory is private and the node owns its
  # regular leaves after exact ownership preparation.
  docker run --rm --pull never --user 0:0 --entrypoint /bin/sh \
    --mount "type=bind,src=$fixture,dst=/fixture" "$image" -ec '
    chown 65532:65532 /fixture/node-one-secrets/audit_database_url
    chown 65532:65532 /fixture/node-one-secrets/audit_database_url.pending
    chmod 0600 /fixture/node-one-secrets/audit_database_url /fixture/node-one-secrets/audit_database_url.pending
  '
}

wait_running() {
  local container=$1 deadline=$((SECONDS + 20))
  while (( SECONDS < deadline )); do
    if [[ $(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true) == true ]]; then
      return 0
    fi
    sleep 0.1
  done
  docker logs "$container" >&2 || true
  return 1
}

wait_consumer() {
  local container=$1 status
  docker wait "$container" >/dev/null
  status=$(docker inspect --format '{{.State.ExitCode}}' "$container")
  return "$status"
}

file_uid() { stat -f '%u' "$1" 2>/dev/null || stat -c '%u' "$1"; }
file_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
file_links() { stat -f '%l' "$1" 2>/dev/null || stat -c '%h' "$1"; }

# The release override mounts the private parent secret directory read-only.
# Reproduce the historical late rename before the privacy-audit consumer starts;
# record only its bounded availability outcome because host bind semantics vary.
prepare_files
mv "$fixture/node-one-secrets/audit_database_url.pending" \
  "$fixture/node-one-secrets/audit_database_url"
docker compose -p "$project" -f "$fixture/compose.yaml" up -d consumer >/dev/null
rename_container=$(docker compose -p "$project" -f "$fixture/compose.yaml" ps -q consumer)
wait_running "$rename_container" || fail 'parent-directory rename consumer did not start'
: >"$fixture/control/read"
rename_status=0
wait_consumer "$rename_container" || rename_status=$?
if [[ $rename_status == 0 ]]; then
  printf 'late-rename-observation=available\n'
else
  printf 'late-rename-observation=unavailable\n'
fi
docker compose -p "$project" -f "$fixture/compose.yaml" down --volumes --remove-orphans >/dev/null

# The production helper path is also exercised before the consumer is created,
# matching the release privacy-audit lifecycle exactly.
prepare_files
before_inode=$(stat -f '%i' "$fixture/node-one-secrets/audit_database_url" 2>/dev/null || stat -c '%i' "$fixture/node-one-secrets/audit_database_url")
before_uid=$(file_uid "$fixture/node-one-secrets/audit_database_url")
bash "$helper" "$fixture" "$image" private-release-audit local-virtualized
after_inode=$(stat -f '%i' "$fixture/node-one-secrets/audit_database_url" 2>/dev/null || stat -c '%i' "$fixture/node-one-secrets/audit_database_url")
[[ $before_inode == "$after_inode" ]] || fail 'stable promotion changed the precreated final inode'
docker compose -p "$project" -f "$fixture/compose.yaml" up -d consumer >/dev/null
green_container=$(docker compose -p "$project" -f "$fixture/compose.yaml" ps -q consumer)
wait_running "$green_container" || fail 'stable promotion consumer did not start'
final="$fixture/node-one-secrets/audit_database_url"
[[ -f $final && ! -L $final && $(file_mode "$final") == 600 && $(file_links "$final") == 1 ]] ||
  fail 'final audit leaf failed regular/mode/link validation'
[[ $(file_uid "$final") == "$before_uid" ]] || fail 'final audit leaf owner changed'
[[ -s $final ]] || fail 'final audit leaf is empty after promotion'
: >"$fixture/control/read"
wait_consumer "$green_container" || {
  docker logs "$green_container" >&2 || true
  fail 'stable promotion did not pass the mounted ReadDatabaseURLFile consumer'
}

printf 'stable-inode-green=passed\n'
printf 'container_secret_ownership_live_contract=passed\n'
