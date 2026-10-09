#!/bin/sh
set -eu

# The controller owns these Docker daemon containers. Keep cleanup callable
# after its timed-out child has been reaped by the process supervisor.
project=$1
[ -n "$project" ] || { printf 'release cleanup requires a Compose project\n' >&2; exit 2; }

cleanup_status=0
release_negative_cases='wrong-key wrong-account wrong-trust-identity semantic-mismatch unsupported-postgresql-major no-stage no-reference'
for release_run_name in \
  "${project}-release-backup" \
  "${project}-release-restore" \
  "${project}-restore-negative-wrong-key" \
  "${project}-restore-negative-wrong-account" \
  "${project}-restore-negative-wrong-trust-identity" \
  "${project}-restore-negative-semantic-mismatch" \
  "${project}-restore-negative-unsupported-postgresql-major" \
  "${project}-restore-negative-no-stage" \
  "${project}-restore-negative-no-reference"; do
  release_container_id=''
  if ! release_container_id=$(docker ps -aq --no-trunc --filter "name=^/${release_run_name}$"); then
    cleanup_status=1
    continue
  fi
  [ -z "$release_container_id" ] && continue
  release_action=backup
  release_acceptance=release-backup-restore
  release_case=''
  case "$release_run_name" in
    *-release-restore) release_action=restore ;;
    *-restore-negative-*)
      release_action=restore
      release_acceptance=release-restore-negative
      release_case=${release_run_name#"${project}-restore-negative-"}
      case " $release_negative_cases " in
        *" $release_case "*) ;;
        *) cleanup_status=1; continue ;;
      esac
      ;;
  esac
  release_metadata=''
  if ! release_metadata=$(docker inspect --format '{{.Id}} {{.Name}} {{index .Config.Labels "com.docker.compose.project"}} {{index .Config.Labels "com.plainpost.acceptance"}} {{index .Config.Labels "com.plainpost.acceptance-action"}} {{index .Config.Labels "com.plainpost.acceptance-case"}}' "$release_container_id" 2>/dev/null); then
    cleanup_status=1
    continue
  fi
  if [ -n "$release_case" ]; then
    case "$release_metadata" in
      "$release_container_id /$release_run_name $project $release_acceptance $release_action $release_case") ;;
      *) cleanup_status=1; continue ;;
    esac
  else
    case "$release_metadata" in
      "$release_container_id /$release_run_name $project $release_acceptance $release_action") ;;
      *) cleanup_status=1; continue ;;
    esac
  fi
  if ! docker rm --force "$release_container_id" >/dev/null 2>&1; then
    cleanup_status=1
    continue
  fi
  release_remaining_by_id=''
  if ! release_remaining_by_id=$(docker ps -aq --no-trunc --filter "id=$release_container_id"); then
    cleanup_status=1
  elif [ -n "$release_remaining_by_id" ]; then
    cleanup_status=1
  fi
  release_remaining_by_name=''
  if ! release_remaining_by_name=$(docker ps -aq --no-trunc --filter "name=^/${release_run_name}$"); then
    cleanup_status=1
  elif [ -n "$release_remaining_by_name" ]; then
    cleanup_status=1
  fi
done
exit "$cleanup_status"
