#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

image='postgres:18.6-alpine3.24@sha256:d3e1620b530c944afa6e887d22eb899824da68e19c52024bf98f5220c88a65b2'
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
guard_asset="$root/Deploy/sync-node/postgres/init/plainpost-postgresql-18-guard"
command -v docker >/dev/null 2>&1 || { printf '%s\n' 'Docker is required for PostgreSQL 18 storage owner' >&2; exit 1; }
[[ -x "$guard_asset" ]] || { printf '%s\n' 'PostgreSQL 18 shared guard is not executable' >&2; exit 1; }
if [[ -n ${PLAINPOST_STORAGE_RUN_ID:-} ]]; then
  [[ ${PLAINPOST_STORAGE_RUN_ID} =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || { printf '%s\n' 'invalid PostgreSQL 18 storage run ID' >&2; exit 1; }
  run_id=$PLAINPOST_STORAGE_RUN_ID
else
  run_id="$$-$(date +%s%N)"
fi
temporary_root=$(mktemp -d "/private/tmp/plainpost-pg18-storage.${run_id}.XXXXXX")
container="plainpost-pg18-storage-${run_id}"
network="plainpost-pg18-storage-network-${run_id}"
volume="plainpost-pg18-storage-volume-${run_id}"
guard_container="plainpost-pg18-storage-guard-${run_id}"
helper_container="plainpost-pg18-storage-helper-${run_id}"
guard_volume="plainpost-pg18-storage-guard-volume-${run_id}"
legacy_volume="plainpost-pg18-storage-legacy-volume-${run_id}"
wrong_version_volume="plainpost-pg18-storage-wrong-version-volume-${run_id}"
unreadable_volume="plainpost-pg18-storage-unreadable-volume-${run_id}"
traversal_volume="plainpost-pg18-storage-traversal-volume-${run_id}"
unanchored_database_volume="plainpost-pg18-storage-unanchored-database-volume-${run_id}"
invalid_database_oid_volume="plainpost-pg18-storage-invalid-database-oid-volume-${run_id}"
wrong_database_version_volume="plainpost-pg18-storage-wrong-database-version-volume-${run_id}"
database='plainpost_storage'
user='plainpost_storage'
password='plainpost-storage-test-only'
marker="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
owner_label="plainpost-storage-$marker"

created_containers=()
created_networks=()
created_volumes=()

is_exact_absent() {
  local kind=$1 name=$2 output=$3 lower
  lower=$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')
  lower=${lower%.}
  case "$kind" in
    container) [[ $lower == *"no such container: $name" || $lower == *"no such object: $name" ]] ;;
    network) [[ $lower == *"network $name not found" ]] ;;
    volume) [[ $lower == *"get $name: no such volume" || $lower == *"no such volume: $name" ]] ;;
    *) return 1 ;;
  esac
}

inspect_absent() {
  local kind=$1 name=$2 output
  if output=$(docker "$kind" inspect "$name" 2>&1); then
    printf 'resource already exists: %s %s\n' "$kind" "$name" >&2
    return 1
  fi
  if ! is_exact_absent "$kind" "$name" "$output"; then
    printf 'resource inspect failed unexpectedly: %s %s: %s\n' "$kind" "$name" "$output" >&2
    return 1
  fi
}

assert_absent_before_create() {
  local kind=$1 name=$2
  inspect_absent "$kind" "$name" || {
    printf 'storage resource already exists or cannot be inspected: %s %s\n' "$kind" "$name" >&2
    return 1
  }
}

remove_owned() {
  local kind=$1 name=$2 output
  case "$kind" in
    container)
      if output=$(docker container inspect --format '{{index .Config.Labels "com.plainpost.storage.owner"}}' "$name" 2>&1); then
        [[ $output == "$owner_label" ]] || {
          printf 'cleanup refused unowned resource: %s %s\n' "$kind" "$name" >&2
          return 1
        }
      elif is_exact_absent "$kind" "$name" "$output"; then
        return 0
      else
        printf 'cleanup inspect failed unexpectedly: %s %s: %s\n' "$kind" "$name" "$output" >&2
        return 1
      fi
      ;;
    network|volume)
      if output=$(docker "$kind" inspect --format '{{index .Labels "com.plainpost.storage.owner"}}' "$name" 2>&1); then
        [[ $output == "$owner_label" ]] || {
          printf 'cleanup refused unowned resource: %s %s\n' "$kind" "$name" >&2
          return 1
        }
      elif is_exact_absent "$kind" "$name" "$output"; then
        return 0
      else
        printf 'cleanup inspect failed unexpectedly: %s %s: %s\n' "$kind" "$name" "$output" >&2
        return 1
      fi
      ;;
    *)
      printf 'cleanup failed: unsupported resource kind %s\n' "$kind" >&2
      return 1
      ;;
  esac
  case "$kind" in
    container) output=$(docker container rm --force "$name" 2>&1) || {
      if ! is_exact_absent "$kind" "$name" "$output"; then
        printf 'cleanup failed: %s %s: %s\n' "$kind" "$name" "$output" >&2
        return 1
      fi
    } ;;
    network|volume) output=$(docker "$kind" rm "$name" 2>&1) || {
      if ! is_exact_absent "$kind" "$name" "$output"; then
        printf 'cleanup failed: %s %s: %s\n' "$kind" "$name" "$output" >&2
        return 1
      fi
    } ;;
  esac
  inspect_absent "$kind" "$name"
}

track_partial_owned() {
  local kind=$1 name=$2 owner
  case "$kind" in
    container) owner=$(docker container inspect --format '{{index .Config.Labels "com.plainpost.storage.owner"}}' "$name" 2>/dev/null || true) ;;
    network|volume) owner=$(docker "$kind" inspect --format '{{index .Labels "com.plainpost.storage.owner"}}' "$name" 2>/dev/null || true) ;;
    *) return 0 ;;
  esac
  [[ $owner == "$owner_label" ]] || return 0
  case "$kind" in
    container) created_containers+=("$name") ;;
    network) created_networks+=("$name") ;;
    volume) created_volumes+=("$name") ;;
  esac
}

assert_exact_refusal() {
  local case_name=$1
  local actual=$2
  local expected=$3
  [[ $actual == "$expected" ]] || {
    printf 'unexpected %s guard refusal: expected=%q actual=%q\n' "$case_name" "$expected" "$actual" >&2
    exit 1
  }
}

cleanup() {
  local status=0
  local index
  for ((index=${#created_containers[@]}-1; index>=0; index--)); do
    remove_owned container "${created_containers[index]}" || status=1
  done
  for ((index=${#created_networks[@]}-1; index>=0; index--)); do
    remove_owned network "${created_networks[index]}" || status=1
  done
  for ((index=${#created_volumes[@]}-1; index>=0; index--)); do
    remove_owned volume "${created_volumes[index]}" || status=1
  done
  rm -rf -- "$temporary_root" || { printf 'cleanup failed: temporary root %s\n' "$temporary_root" >&2; status=1; }
  [[ ! -e "$temporary_root" ]] || { printf 'cleanup failed: temporary root remains %s\n' "$temporary_root" >&2; status=1; }
  return "$status"
}
on_exit() {
  local exit_status=$?
  cleanup || exit_status=1
  exit "$exit_status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

assert_absent_before_create volume "$guard_volume"
if docker volume create --label "com.plainpost.storage.owner=$owner_label" "$guard_volume" >/dev/null; then
  created_volumes+=("$guard_volume")
else
  track_partial_owned volume "$guard_volume"
  exit 1
fi
assert_absent_before_create container "$guard_container"
if docker run --detach --name "$guard_container" --label "com.plainpost.storage.owner=$owner_label" --network none --entrypoint sh \
  --mount "type=volume,src=$guard_volume,dst=/var/lib/postgresql" \
  --env "POSTGRES_PASSWORD=$password" \
  --mount "type=bind,src=$guard_asset,dst=/usr/local/bin/plainpost-postgresql-18-guard,readonly" \
  "$image" -ceu 'exec /usr/local/bin/plainpost-postgresql-18-guard "$@"' sh postgres >/dev/null; then
  created_containers+=("$guard_container")
else
  track_partial_owned container "$guard_container"
  exit 1
fi
ready=0
for _ in $(seq 1 45); do
  if docker exec "$guard_container" psql -U postgres -d postgres -Atqc 'SELECT 1' >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[[ $ready == 1 ]] || { printf '%s\n' 'fresh parent root did not initialize through the guard' >&2; exit 1; }
docker exec "$guard_container" sh -ceu 'test "$(cat /var/lib/postgresql/18/docker/PG_VERSION)" = 18'
printf '%s\n' 'fresh parent root initialized PostgreSQL 18 through the guard'
if [[ ${PLAINPOST_STORAGE_FORCE_GUARD_FAILURE:-0} == 1 ]]; then
  printf 'guard-failure resources guard-container=%s guard-volume=%s temporary-root=%s\n' "$guard_container" "$guard_volume" "$temporary_root" >&2
  printf '%s\n' 'intentional guard-container-active failure-path probe' >&2
  exit 42
fi
remove_owned container "$guard_container"

# A normal PostgreSQL 18 restart sees both the cluster marker and PostgreSQL's
# per-database marker below base/<numeric OID>. The guard must accept that
# layout without weakening its rejection of alternate clusters or majors.
mkdir -p "$temporary_root/restart-bin"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" normal-postgresql-18-restart-accepted' >"$temporary_root/restart-bin/docker-entrypoint.sh"
chmod 0755 "$temporary_root/restart-bin/docker-entrypoint.sh"
assert_absent_before_create container "$helper_container"
if ! restart_output=$(docker run --rm --name "$helper_container" --network none --entrypoint /usr/local/bin/plainpost-postgresql-18-guard \
  --mount "type=volume,src=$guard_volume,dst=/var/lib/postgresql" \
  --mount "type=bind,src=$guard_asset,dst=/usr/local/bin/plainpost-postgresql-18-guard,readonly" \
  --mount "type=bind,src=$temporary_root/restart-bin,dst=/test-bin,readonly" \
  --env PATH=/test-bin:/usr/local/bin:/usr/bin:/bin "$image" postgres 2>&1); then
  printf 'normal PostgreSQL 18 restart markers were rejected: %s\n' "$restart_output" >&2
  exit 1
fi
[[ $restart_output == normal-postgresql-18-restart-accepted ]] || {
  printf 'normal PostgreSQL 18 restart did not reach the entrypoint: %s\n' "$restart_output" >&2
  exit 1
}
printf '%s\n' 'normal PostgreSQL 18 per-database markers accepted on restart'

assert_absent_before_create volume "$unanchored_database_volume"
if docker volume create --label "com.plainpost.storage.owner=$owner_label" "$unanchored_database_volume" >/dev/null; then
  created_volumes+=("$unanchored_database_volume")
else
  track_partial_owned volume "$unanchored_database_volume"
  exit 1
fi
assert_absent_before_create container "$helper_container"
docker run --rm --name "$helper_container" --network none --entrypoint sh --mount "type=volume,src=$unanchored_database_volume,dst=/var/lib/postgresql" \
  "$image" -ceu 'mkdir -p /var/lib/postgresql/18/docker/base/1 && printf 18 > /var/lib/postgresql/18/docker/base/1/PG_VERSION'
assert_absent_before_create container "$helper_container"
if unanchored_output=$(docker run --rm --name "$helper_container" --network none --entrypoint /usr/local/bin/plainpost-postgresql-18-guard \
  --mount "type=volume,src=$unanchored_database_volume,dst=/var/lib/postgresql" \
  --mount "type=bind,src=$guard_asset,dst=/usr/local/bin/plainpost-postgresql-18-guard,readonly" \
  --mount "type=bind,src=$temporary_root/restart-bin,dst=/test-bin,readonly" \
  --env PATH=/test-bin:/usr/local/bin:/usr/bin:/bin "$image" postgres 2>&1); then
  printf '%s\n' 'unanchored per-database PG_VERSION was not rejected' >&2
  exit 1
fi
assert_exact_refusal unanchored-database "$unanchored_output" 'refusing PostgreSQL data root with unanchored per-database PG_VERSION path=/var/lib/postgresql/18/docker/base/1/PG_VERSION'
printf '%s\n' 'unanchored per-database PG_VERSION refused before initialization'

assert_absent_before_create volume "$invalid_database_oid_volume"
if docker volume create --label "com.plainpost.storage.owner=$owner_label" "$invalid_database_oid_volume" >/dev/null; then
  created_volumes+=("$invalid_database_oid_volume")
else
  track_partial_owned volume "$invalid_database_oid_volume"
  exit 1
fi
assert_absent_before_create container "$helper_container"
docker run --rm --name "$helper_container" --network none --entrypoint sh --mount "type=volume,src=$invalid_database_oid_volume,dst=/var/lib/postgresql" \
  "$image" -ceu 'mkdir -p /var/lib/postgresql/18/docker/base/not-an-oid && printf 18 > /var/lib/postgresql/18/docker/PG_VERSION && printf 18 > /var/lib/postgresql/18/docker/base/not-an-oid/PG_VERSION'
assert_absent_before_create container "$helper_container"
if invalid_oid_output=$(docker run --rm --name "$helper_container" --network none --entrypoint /usr/local/bin/plainpost-postgresql-18-guard \
  --mount "type=volume,src=$invalid_database_oid_volume,dst=/var/lib/postgresql" \
  --mount "type=bind,src=$guard_asset,dst=/usr/local/bin/plainpost-postgresql-18-guard,readonly" \
  --mount "type=bind,src=$temporary_root/restart-bin,dst=/test-bin,readonly" \
  --env PATH=/test-bin:/usr/local/bin:/usr/bin:/bin "$image" postgres 2>&1); then
  printf '%s\n' 'non-numeric per-database PG_VERSION path was not rejected' >&2
  exit 1
fi
assert_exact_refusal invalid-database-oid "$invalid_oid_output" 'refusing PostgreSQL data root with unexpected PG_VERSION path=/var/lib/postgresql/18/docker/base/not-an-oid/PG_VERSION'
printf '%s\n' 'non-numeric per-database PG_VERSION path refused before initialization'

assert_absent_before_create volume "$wrong_database_version_volume"
if docker volume create --label "com.plainpost.storage.owner=$owner_label" "$wrong_database_version_volume" >/dev/null; then
  created_volumes+=("$wrong_database_version_volume")
else
  track_partial_owned volume "$wrong_database_version_volume"
  exit 1
fi
assert_absent_before_create container "$helper_container"
docker run --rm --name "$helper_container" --network none --entrypoint sh --mount "type=volume,src=$wrong_database_version_volume,dst=/var/lib/postgresql" \
  "$image" -ceu 'mkdir -p /var/lib/postgresql/18/docker/base/12345 && printf 18 > /var/lib/postgresql/18/docker/PG_VERSION && printf 17 > /var/lib/postgresql/18/docker/base/12345/PG_VERSION'
assert_absent_before_create container "$helper_container"
if wrong_database_version_output=$(docker run --rm --name "$helper_container" --network none --entrypoint /usr/local/bin/plainpost-postgresql-18-guard \
  --mount "type=volume,src=$wrong_database_version_volume,dst=/var/lib/postgresql" \
  --mount "type=bind,src=$guard_asset,dst=/usr/local/bin/plainpost-postgresql-18-guard,readonly" \
  --mount "type=bind,src=$temporary_root/restart-bin,dst=/test-bin,readonly" \
  --env PATH=/test-bin:/usr/local/bin:/usr/bin:/bin "$image" postgres 2>&1); then
  printf '%s\n' 'wrong-major per-database PG_VERSION was not rejected' >&2
  exit 1
fi
assert_exact_refusal wrong-database-version "$wrong_database_version_output" 'refusing PostgreSQL data root with unexpected PG_VERSION=17'
printf '%s\n' 'wrong-major per-database PG_VERSION refused before initialization'

assert_absent_before_create volume "$legacy_volume"
if docker volume create --label "com.plainpost.storage.owner=$owner_label" "$legacy_volume" >/dev/null; then
  created_volumes+=("$legacy_volume")
else
  track_partial_owned volume "$legacy_volume"
  exit 1
fi
assert_absent_before_create container "$helper_container"
docker run --rm --name "$helper_container" --network none --entrypoint sh --mount "type=volume,src=$legacy_volume,dst=/var/lib/postgresql" \
  "$image" -ceu 'mkdir -p /var/lib/postgresql/17/docker && printf 17 > /var/lib/postgresql/17/docker/PG_VERSION'
assert_absent_before_create container "$helper_container"
if legacy_output=$(docker run --rm --name "$helper_container" --network none --entrypoint /usr/local/bin/plainpost-postgresql-18-guard \
  --mount "type=volume,src=$legacy_volume,dst=/var/lib/postgresql" \
  --mount "type=bind,src=$guard_asset,dst=/usr/local/bin/plainpost-postgresql-18-guard,readonly" \
  --env "POSTGRES_PASSWORD=$password" "$image" postgres 2>&1); then
  printf '%s\n' 'legacy PostgreSQL data root was not rejected before initialization' >&2
  exit 1
fi
assert_exact_refusal legacy "$legacy_output" 'refusing PostgreSQL data root with unexpected PG_VERSION path=/var/lib/postgresql/17/docker/PG_VERSION'
assert_absent_before_create container "$helper_container"
docker run --rm --name "$helper_container" --network none --entrypoint sh --mount "type=volume,src=$legacy_volume,dst=/var/lib/postgresql" \
  "$image" -ceu 'test ! -e /var/lib/postgresql/18/docker/PG_VERSION'
printf '%s\n' 'legacy PG_VERSION=17 parent root refused before nested PostgreSQL 18 initialization'

assert_absent_before_create volume "$wrong_version_volume"
if docker volume create --label "com.plainpost.storage.owner=$owner_label" "$wrong_version_volume" >/dev/null; then
  created_volumes+=("$wrong_version_volume")
else
  track_partial_owned volume "$wrong_version_volume"
  exit 1
fi
assert_absent_before_create container "$helper_container"
docker run --rm --name "$helper_container" --network none --entrypoint sh --mount "type=volume,src=$wrong_version_volume,dst=/var/lib/postgresql" \
  "$image" -ceu 'mkdir -p /var/lib/postgresql/18/docker && printf 17 > /var/lib/postgresql/18/docker/PG_VERSION'
assert_absent_before_create container "$helper_container"
if wrong_version_output=$(docker run --rm --name "$helper_container" --network none --entrypoint /usr/local/bin/plainpost-postgresql-18-guard \
  --mount "type=volume,src=$wrong_version_volume,dst=/var/lib/postgresql" \
  --mount "type=bind,src=$guard_asset,dst=/usr/local/bin/plainpost-postgresql-18-guard,readonly" \
  --env "POSTGRES_PASSWORD=$password" "$image" postgres 2>&1); then
  printf '%s\n' 'wrong-major PG_VERSION at expected path was not rejected' >&2
  exit 1
fi
assert_exact_refusal expected-path-wrong-major "$wrong_version_output" 'refusing PostgreSQL data root with unexpected PG_VERSION=17'
assert_absent_before_create container "$helper_container"
docker run --rm --name "$helper_container" --network none --entrypoint sh --mount "type=volume,src=$wrong_version_volume,dst=/var/lib/postgresql" \
  "$image" -ceu 'test "$(cat /var/lib/postgresql/18/docker/PG_VERSION)" = 17 && test ! -e /var/lib/postgresql/17/docker/PG_VERSION'
printf '%s\n' 'expected PG_VERSION path with wrong major refused before initialization'

assert_absent_before_create volume "$unreadable_volume"
if docker volume create --label "com.plainpost.storage.owner=$owner_label" "$unreadable_volume" >/dev/null; then
  created_volumes+=("$unreadable_volume")
else
  track_partial_owned volume "$unreadable_volume"
  exit 1
fi
assert_absent_before_create container "$helper_container"
docker run --rm --name "$helper_container" --network none --entrypoint sh --mount "type=volume,src=$unreadable_volume,dst=/var/lib/postgresql" \
  "$image" -ceu 'mkdir -p /var/lib/postgresql/18/docker && printf 18 > /var/lib/postgresql/18/docker/PG_VERSION && chmod 000 /var/lib/postgresql/18/docker/PG_VERSION'
assert_absent_before_create container "$helper_container"
if docker run --rm --name "$helper_container" --network none --user 70:70 --entrypoint /usr/local/bin/plainpost-postgresql-18-guard \
  --mount "type=volume,src=$unreadable_volume,dst=/var/lib/postgresql" \
  --mount "type=bind,src=$guard_asset,dst=/usr/local/bin/plainpost-postgresql-18-guard,readonly" \
  --env "POSTGRES_PASSWORD=$password" "$image" postgres >"$temporary_root/unreadable-output" 2>&1; then
  printf '%s\n' 'unreadable PG_VERSION was not rejected before initialization' >&2
  exit 1
fi
unreadable_output=$(<"$temporary_root/unreadable-output")
assert_exact_refusal unreadable "$unreadable_output" 'refusing PostgreSQL data root because PG_VERSION is unreadable'
assert_absent_before_create container "$helper_container"
docker run --rm --name "$helper_container" --network none --entrypoint sh --mount "type=volume,src=$unreadable_volume,dst=/var/lib/postgresql" \
  "$image" -ceu 'test -e /var/lib/postgresql/18/docker/PG_VERSION && test "$(cat /var/lib/postgresql/18/docker/PG_VERSION)" = 18 && test ! -e /var/lib/postgresql/17/docker/PG_VERSION'
printf '%s\n' 'unreadable PG_VERSION refused before initialization'

assert_absent_before_create volume "$traversal_volume"
if docker volume create --label "com.plainpost.storage.owner=$owner_label" "$traversal_volume" >/dev/null; then
  created_volumes+=("$traversal_volume")
else
  track_partial_owned volume "$traversal_volume"
  exit 1
fi
assert_absent_before_create container "$helper_container"
docker run --rm --name "$helper_container" --network none --entrypoint sh --mount "type=volume,src=$traversal_volume,dst=/var/lib/postgresql" \
  "$image" -ceu 'chmod 0755 /var/lib/postgresql'
mkdir -p "$temporary_root/traversal-bin"
printf '%s\n' '#!/bin/sh' 'exit 1' >"$temporary_root/traversal-bin/find"
chmod 0755 "$temporary_root/traversal-bin/find"
assert_absent_before_create container "$helper_container"
if docker run --rm --name "$helper_container" --network none --user 70:70 --entrypoint /usr/local/bin/plainpost-postgresql-18-guard \
  --mount "type=volume,src=$traversal_volume,dst=/var/lib/postgresql" \
  --mount "type=bind,src=$guard_asset,dst=/usr/local/bin/plainpost-postgresql-18-guard,readonly" \
  --mount "type=bind,src=$temporary_root/traversal-bin,dst=/test-bin,readonly" \
  --env PATH=/test-bin:/usr/local/bin:/usr/bin:/bin \
  --env "POSTGRES_PASSWORD=$password" "$image" postgres >"$temporary_root/traversal-output" 2>&1; then
  printf '%s\n' 'PG_VERSION traversal failure was not rejected before initialization' >&2
  exit 1
fi
traversal_output=$(<"$temporary_root/traversal-output")
assert_exact_refusal traversal "$traversal_output" 'refusing PostgreSQL data root because PG_VERSION traversal failed'
assert_absent_before_create container "$helper_container"
docker run --rm --name "$helper_container" --network none --entrypoint sh --mount "type=volume,src=$traversal_volume,dst=/var/lib/postgresql" \
  "$image" -ceu 'test ! -e /var/lib/postgresql/18/docker/PG_VERSION && test ! -e /var/lib/postgresql/17/docker/PG_VERSION'
printf '%s\n' 'PG_VERSION traversal failure refused before initialization'

mkdir -p "$temporary_root/fake-bin"
printf '%s\n' '#!/bin/sh' 'printf "argc=%s first=%s second=%s third=%s fourth=%s\\n" "$#" "$1" "$2" "$3" "$4"' >"$temporary_root/fake-bin/docker-entrypoint.sh"
chmod 0755 "$temporary_root/fake-bin/docker-entrypoint.sh"
assert_absent_before_create container "$helper_container"
argv_output=$(docker run --rm --name "$helper_container" --network none --tmpfs /var/lib/postgresql --entrypoint /usr/local/bin/plainpost-postgresql-18-guard \
  --mount "type=bind,src=$guard_asset,dst=/usr/local/bin/plainpost-postgresql-18-guard,readonly" \
  --mount "type=bind,src=$temporary_root/fake-bin,dst=/test-bin,readonly" \
  --env PATH=/test-bin:/usr/local/bin:/usr/bin:/bin "$image" postgres -c argv-zero argv-one)
[[ $argv_output == 'argc=4 first=postgres second=-c third=argv-zero fourth=argv-one' ]] || { printf 'guard did not preserve complete argv: %s\n' "$argv_output" >&2; exit 1; }
printf '%s\n' 'guard preserved complete multi-argument argv'

assert_absent_before_create network "$network"
if docker network create --internal --label "com.plainpost.storage.owner=$owner_label" "$network" >/dev/null; then
  created_networks+=("$network")
else
  track_partial_owned network "$network"
  exit 1
fi
assert_absent_before_create volume "$volume"
if docker volume create --label "com.plainpost.storage.owner=$owner_label" "$volume" >/dev/null; then
  created_volumes+=("$volume")
else
  track_partial_owned volume "$volume"
  exit 1
fi
assert_absent_before_create container "$container"
if docker run --detach --name "$container" --label "com.plainpost.storage.owner=$owner_label" --network "$network" \
  --mount "type=volume,src=$volume,dst=/var/lib/postgresql" \
  --env "POSTGRES_DB=$database" --env "POSTGRES_USER=$user" \
  --env "POSTGRES_PASSWORD=$password" "$image" >/dev/null; then
  created_containers+=("$container")
else
  track_partial_owned container "$container"
  exit 1
fi

ready=0
for _ in $(seq 1 45); do
  if docker exec "$container" psql -U "$user" -d "$database" -Atqc 'SELECT 1' >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[[ $ready == 1 ]] || { printf '%s\n' 'PostgreSQL 18 owner did not become ready' >&2; exit 1; }

mount_count=$(docker inspect --format '{{len .Mounts}}' "$container")
mount_name=$(docker inspect --format '{{(index .Mounts 0).Name}}' "$container")
mount_target=$(docker inspect --format '{{(index .Mounts 0).Destination}}' "$container")
[[ $mount_count == 1 && $mount_name == "$volume" && $mount_target == /var/lib/postgresql ]] || {
  printf '%s\n' 'PostgreSQL owner has an anonymous or unintended database volume' >&2
  exit 1
}
network_names=$(docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{"\n"}}{{end}}' "$container")
[[ $network_names == "$network" ]] || { printf '%s\n' 'PostgreSQL owner joined an unintended network' >&2; exit 1; }

docker exec "$container" psql -v ON_ERROR_STOP=1 -U "$user" -d "$database" \
  -c 'CREATE TABLE storage_marker (value text NOT NULL);' \
  -c "INSERT INTO storage_marker(value) VALUES ('$marker');" >/dev/null
docker exec "$container" sh -ceu '
  data_directory=$(psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atqc "SHOW data_directory")
  case "$data_directory" in
    /var/lib/postgresql/*) ;;
    *) printf "data directory escaped persistent root: %s\n" "$data_directory" >&2; exit 1 ;;
  esac
  test "$(psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atqc "SHOW server_version_num")" = 180006
  test "$(psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atqc "SHOW data_checksums")" = on
  test "$(cat "$data_directory/PG_VERSION")" = 18
  printf "server_version_num=%s\ndata_directory=%s\ndata_checksums=%s\nPG_VERSION=%s\n" \
    "$(psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atqc "SHOW server_version_num")" \
    "$data_directory" \
    "$(psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atqc "SHOW data_checksums")" \
    "$(cat "$data_directory/PG_VERSION")"
'

remove_owned container "$container"
if docker inspect "$container" >/dev/null 2>&1; then
  printf '%s\n' 'PostgreSQL container removal did not remove the exact owner' >&2
  exit 1
fi

assert_absent_before_create container "$container"
if docker run --detach --name "$container" --label "com.plainpost.storage.owner=$owner_label" --network "$network" \
  --mount "type=volume,src=$volume,dst=/var/lib/postgresql" \
  --env "POSTGRES_DB=$database" --env "POSTGRES_USER=$user" \
  --env "POSTGRES_PASSWORD=$password" "$image" >/dev/null; then
  created_containers+=("$container")
else
  track_partial_owned container "$container"
  exit 1
fi
ready=0
for _ in $(seq 1 45); do
  if docker exec "$container" psql -U "$user" -d "$database" -Atqc 'SELECT 1' >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[[ $ready == 1 ]] || { printf '%s\n' 'Recreated PostgreSQL 18 owner did not become ready' >&2; exit 1; }
recreated_marker=$(docker exec "$container" psql -U "$user" -d "$database" -Atqc 'SELECT value FROM storage_marker')
[[ $recreated_marker == "$marker" ]] || { printf '%s\n' 'storage marker did not survive exact container recreation' >&2; exit 1; }

if [[ ${PLAINPOST_STORAGE_FORCE_FAILURE:-0} == 1 ]]; then
  printf 'failure-path resources container=%s network=%s volume=%s guard-volume=%s legacy-volume=%s unreadable-volume=%s traversal-volume=%s temporary-root=%s\n' \
    "$container" "$network" "$volume" "$guard_volume" "$legacy_volume" "$unreadable_volume" "$traversal_volume" "$temporary_root" >&2
  printf '%s\n' 'intentional failure-path probe' >&2
  exit 42
fi

cleanup
trap - EXIT INT TERM
printf '%s\n' 'PostgreSQL 18 storage persistence owner passed'
