#!/bin/sh

# Callers provide temporary, container_children, and container_ids. Only IDs
# captured by create_container are eligible for removal.
# shellcheck disable=SC2154
container_absent() {
  id=$1
  rm_error=$2
  inspect_error="$temporary/docker-inspect-error"
  if docker inspect "$id" >/dev/null 2>"$inspect_error"; then
    return 1
  fi
  # Only Docker's explicit no-such response confirms absence. Daemon,
  # permission, and transport failures remain cleanup failures.
  if grep -Eiq 'no such (object|container)' "$inspect_error" "$rm_error" 2>/dev/null; then
    return 0
  fi
  return 1
}

cleanup_captured_containers() {
  cleanup_status=0
  for child in $container_children; do
    kill -TERM "$child" 2>/dev/null || true
  done
  for child in $container_children; do
    wait "$child" 2>/dev/null || true
  done
  # Do this immediately after successful waits so a later cleanup cannot
  # signal a reused PID.
  container_children=''
  for id in $container_ids; do
    docker_rm_error="$temporary/docker-rm-error"
    if ! docker rm -f "$id" >/dev/null 2>"$docker_rm_error"; then
      if ! container_absent "$id" "$docker_rm_error"; then
        cleanup_status=1
      fi
    elif ! container_absent "$id" "$docker_rm_error"; then
      cleanup_status=1
    fi
  done
  container_ids=''
  return "$cleanup_status"
}
