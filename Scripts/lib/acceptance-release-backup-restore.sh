#!/bin/sh
set -eu

compose=$1
project=$2
temporary=$3
release_override=$4
node_image=$5
node_uid=$6
node_gid=$7
attachment_storage=$8
attachment_dir=$9
s3_endpoint=${10}
s3_bucket=${11}
s3_region=${12}
s3_addressing=${13}
s3_access_key_file=${14}
s3_secret_key_file=${15}
runtime_log=${16}
root=${17}
. "$root/Scripts/lib/acceptance-active-database-reference.sh"
. "$root/Scripts/lib/acceptance-release-restore-failure-category.sh"

[ -n "$release_override" ] || { printf 'release backup restore requires release override\n' >&2; exit 1; }
[ -f "$release_override" ] || { printf 'release backup restore override unavailable\n' >&2; exit 1; }
[ -d "$temporary/node-one-data/backups" ] || { printf 'release backup root unavailable\n' >&2; exit 1; }

compose_env() {
  PLAINPOST_PRIVATE_ROOT="$temporary" \
  PLAINPOST_PRIVATE_NODE_IMAGE="$node_image" \
  PLAINPOST_ACCEPTANCE_NODE_UID="$node_uid" \
  PLAINPOST_ACCEPTANCE_NODE_GID="$node_gid" \
  PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE="$attachment_storage" \
  PLAINPOST_ACCEPTANCE_ATTACHMENT_DIR="$attachment_dir" \
  PLAINPOST_ACCEPTANCE_S3_ENDPOINT="$s3_endpoint" \
  PLAINPOST_ACCEPTANCE_S3_BUCKET="$s3_bucket" \
  PLAINPOST_ACCEPTANCE_S3_REGION="$s3_region" \
  PLAINPOST_ACCEPTANCE_S3_ADDRESSING="$s3_addressing" \
  PLAINPOST_ACCEPTANCE_S3_ACCESS_KEY_FILE="$s3_access_key_file" \
  PLAINPOST_ACCEPTANCE_S3_SECRET_KEY_FILE="$s3_secret_key_file" \
  PLAINPOST_RELEASE_NODE_IMAGE="$node_image" \
  docker compose -p "$project" -f "$compose" -f "$release_override" "$@"
}

assert_container_absent() {
  container_name=$1
  container_ids=''
  if ! container_ids=$(docker ps -aq --filter "name=^/${container_name}$" 2>>"$runtime_log"); then
    printf 'release backup restore Docker query failed name=%s\n' "$container_name" >&2
    return 1
  fi
  [ -z "$container_ids" ]
}

assert_container_stopped() {
  container_id=$1
  container_state=''
  if ! container_state=$(docker inspect --format '{{.State.Status}}' "$container_id" 2>>"$runtime_log"); then
    printf 'release backup restore Docker inspect failed id=%s\n' "$container_id" >&2
    return 1
  fi
  [ -n "$container_state" ] && [ "$container_state" != running ]
}

mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }

cleanup_helper="$root/Scripts/lib/acceptance-release-backup-restore-cleanup.sh"
release_backup_restore_step=prepare
cleanup_armed=0
cleanup_run_containers() {
  "$cleanup_helper" "$project" >/dev/null 2>&1 || true
}
release_backup_restore_exit() {
  release_backup_restore_exit_status=$?
  trap - EXIT
  if [ "$release_backup_restore_exit_status" -ne 0 ]; then
    printf 'ERROR release-backup-restore step=%s status=failed\n' "$release_backup_restore_step" >>"$runtime_log" || true
  fi
  if [ "$cleanup_armed" -eq 1 ]; then
    cleanup_run_containers
  fi
  exit "$release_backup_restore_exit_status"
}
trap release_backup_restore_exit EXIT

before="$temporary/release-backup-before"
after="$temporary/release-backup-after"
new="$temporary/release-backup-new"
backup_output="$temporary/release-backup-output"
restore_output="$temporary/release-restore-output"
for file in "$before" "$after" "$new" "$backup_output" "$restore_output"; do : >"$file"; chmod 0600 "$file"; done
find "$temporary/node-one-data/backups" -type f -name '*.ppb' -print | sort >"$before"

backup_run_name="${project}-release-backup"
restore_run_name="${project}-release-restore"
for run_name in "$backup_run_name" "$restore_run_name"; do
  release_backup_restore_step=preflight-container-names
  assert_container_absent "$run_name" || {
    printf 'release backup restore run container name is occupied\n' >&2
    exit 1
  }
done
cleanup_armed=1

release_backup_restore_step=stop-node
compose_env stop --timeout 10 node-one >>"$runtime_log" 2>&1
node_container=$(compose_env ps -aq node-one)
[ -n "$node_container" ] || { printf 'release backup restore stopped container is unavailable\n' >&2; exit 1; }
assert_container_stopped "$node_container" || { printf 'release backup restore node did not stop\n' >&2; exit 1; }

release_backup_restore_step=backup-execute
compose_env run --rm --pull never --no-deps \
  --user 65532:65532 \
  --volume "$temporary/node-one-data/backups:/node-data/backups:rw" \
  --name "$backup_run_name" \
  --label com.plainpost.acceptance=release-backup-restore \
  --label com.plainpost.acceptance-action=backup \
  node-one operations backup >"$backup_output" 2>>"$runtime_log"
release_backup_restore_step=backup-verify
assert_container_absent "$backup_run_name" || { printf 'release backup run container was not removed\n' >&2; exit 1; }
grep -Eq '^state=verified([[:space:]]|$)' "$backup_output" || { printf 'release backup did not return verified state\n' >&2; exit 1; }

release_backup_restore_step=backup-publish
find "$temporary/node-one-data/backups" -type f -name '*.ppb' -print | sort >"$after"
comm -13 "$before" "$after" >"$new"
[ "$(wc -l <"$new" | tr -d ' ')" -eq 1 ] || { printf 'release backup did not publish exactly one new container\n' >&2; exit 1; }
backup_path=$(sed -n '1p' "$new")
[ -f "$backup_path" ] && [ ! -L "$backup_path" ] || { printf 'release backup container is not a regular file\n' >&2; exit 1; }
[ "$(mode_of "$backup_path")" = 600 ] || { printf 'release backup container is not mode 0600\n' >&2; exit 1; }
backup_relative_path=${backup_path#"$temporary/node-one-data/backups/"}
printf '%s\n' "$backup_relative_path" | grep -Eq '^[^/[:space:]][^[:space:]]*\.ppb$' || { printf 'release backup path is invalid\n' >&2; exit 1; }
case "/$backup_relative_path" in
  /*/../*|*/../*|*/..|*/./*|*/.) { printf 'release backup path escapes backup root\n' >&2; exit 1; } ;;
esac
digest=$(shasum -a 256 "$backup_path" | awk '{print $1}')
printf '%s\n' "$digest" | grep -Eq '^[0-9a-f]{64}$' || { printf 'release backup digest is invalid\n' >&2; exit 1; }

# Exercise the release image's restore boundary with authenticated fixture
# mutations before the successful restore. The fixture producer is compiled
# from this exact candidate source, while every rejection is produced by the
# manifest-bound image's operations binary.
release_backup_restore_step=negative-fixture-build
negative_root="$temporary/release-restore-negative"
mkdir -m 0700 "$negative_root"
negative_test_binary="$negative_root/restore-negative.test"
(cd "$root/Services/PlainpostGo" && CGO_ENABLED=0 go test -c ./internal/node/backup -o "$negative_test_binary")
chmod 0700 "$negative_test_binary"
negative_source="$negative_root/source.ppb"
negative_source_key="$negative_root/source-key"
cp "$backup_path" "$negative_source"
cp "$temporary/node-one-secrets/backup_key" "$negative_source_key"
chmod 0600 "$negative_source" "$negative_source_key"
negative_cases='wrong-key wrong-account wrong-trust-identity semantic-mismatch unsupported-postgresql-major no-stage no-reference'
for negative_case in $negative_cases; do
  release_backup_restore_step=negative-fixture-build
  if [ "$negative_case" = no-stage ] || [ "$negative_case" = no-reference ]; then
    negative_fixture="$negative_root/$negative_case.ppb"
    cp "$negative_source" "$negative_fixture"
    chmod 0600 "$negative_fixture"
  else
    negative_fixture="$negative_root/$negative_case.ppb"
    PLAINPOST_RESTORE_NEGATIVE_FIXTURE_OUTPUT="$negative_fixture" \
    PLAINPOST_RESTORE_NEGATIVE_SOURCE="$negative_source" \
    PLAINPOST_RESTORE_NEGATIVE_KEY="$negative_source_key" \
    PLAINPOST_RESTORE_NEGATIVE_CASE="$negative_case" \
      "$negative_test_binary" -test.run '^TestWriteReleaseRestoreNegativeFixture$' -test.count=1 >>"$runtime_log" 2>&1
    chmod 0600 "$negative_fixture"
  fi
  release_backup_restore_step=negative-case
  negative_digest=$(shasum -a 256 "$negative_fixture" | awk '{print $1}')
  printf '%s\n' "$negative_digest" | grep -Eq '^[0-9a-f]{64}$' || { printf 'release restore negative digest is invalid: %s\n' "$negative_case" >&2; exit 1; }
  restore_negative_run_name="${project}-restore-negative-${negative_case}"
  restore_negative_output="$negative_root/$negative_case.output"
  : >"$restore_negative_output"
  chmod 0600 "$restore_negative_output"
  restore_negative_status=0
  case "$negative_case" in
    wrong-key)
      wrong_key="$negative_root/wrong-key"
      openssl rand 32 >"$wrong_key"
      chmod 0600 "$wrong_key"
      compose_env run --rm --pull never --no-deps --user 65532:65532 \
        --volume "$negative_fixture:/node-data/backups/restore-input.ppb:ro" \
        --volume "$wrong_key:/run/secrets/backup-key-negative:ro" \
        --env PLAINPOST_NODE_BACKUP_KEY_FILE=/run/secrets/backup-key-negative \
        --name "$restore_negative_run_name" \
        --label com.plainpost.acceptance=release-restore-negative \
        --label com.plainpost.acceptance-case="$negative_case" \
        node-one operations restore --backup /node-data/backups/restore-input.ppb --digest "$negative_digest" \
        >"$restore_negative_output" 2>>"$runtime_log" || restore_negative_status=$?
      ;;
    no-stage)
      compose_env run --rm --pull never --no-deps --user 65532:65532 \
        --volume "$negative_fixture:/node-data/backups/restore-input.ppb:ro" \
        --env PLAINPOST_NODE_RESTORE_ADMIN_DATABASE_URL_FILE=/run/missing/restore-admin \
        --env PLAINPOST_NODE_RESTORE_STAGE_DATABASE_URL_FILE=/run/missing/restore-stage \
        --name "$restore_negative_run_name" \
        --label com.plainpost.acceptance=release-restore-negative \
        --label com.plainpost.acceptance-case="$negative_case" \
        node-one operations restore --backup /node-data/backups/restore-input.ppb --digest "$negative_digest" \
        >"$restore_negative_output" 2>>"$runtime_log" || restore_negative_status=$?
      ;;
    no-reference)
      no_reference_data="$negative_root/no-reference-data"
      mkdir -m 0700 "$no_reference_data"
      compose_env run --rm --pull never --no-deps --user 65532:65532 \
        --volume "$no_reference_data:/node-data-negative:rw" \
        --volume "$negative_fixture:/node-data-negative/backups/restore-input.ppb:ro" \
        --env PLAINPOST_NODE_DATA_DIR=/node-data-negative \
        --env PLAINPOST_NODE_BACKUP_ROOT=/node-data-negative/backups \
        --name "$restore_negative_run_name" \
        --label com.plainpost.acceptance=release-restore-negative \
        --label com.plainpost.acceptance-case="$negative_case" \
        node-one operations restore --backup /node-data-negative/backups/restore-input.ppb --digest "$negative_digest" \
        >"$restore_negative_output" 2>>"$runtime_log" || restore_negative_status=$?
      ;;
    *)
      compose_env run --rm --pull never --no-deps --user 65532:65532 \
        --volume "$negative_fixture:/node-data/backups/restore-input.ppb:ro" \
        --volume "$negative_source_key:/run/secrets/backup-key-negative:ro" \
        --env PLAINPOST_NODE_BACKUP_KEY_FILE=/run/secrets/backup-key-negative \
        --name "$restore_negative_run_name" \
        --label com.plainpost.acceptance=release-restore-negative \
        --label com.plainpost.acceptance-case="$negative_case" \
        node-one operations restore --backup /node-data/backups/restore-input.ppb --digest "$negative_digest" \
        >"$restore_negative_output" 2>>"$runtime_log" || restore_negative_status=$?
      ;;
  esac
  [ "$restore_negative_status" -ne 0 ] || { printf 'release restore negative case accepted: %s\n' "$negative_case" >&2; exit 1; }
  assert_container_absent "$restore_negative_run_name" || { printf 'release restore negative container remained: %s\n' "$negative_case" >&2; exit 1; }
  if grep -Fx 'state=restored' "$restore_negative_output" >/dev/null 2>&1; then
    printf 'release restore negative case reported restored state: %s\n' "$negative_case" >&2
    exit 1
  fi
  printf 'release-backup-restore negative-case=%s status=rejected\n' "$negative_case" >>"$runtime_log"
done
printf 'release-backup-restore negative-cases=7 status=passed\n' >>"$runtime_log"

pty="$root/Scripts/lib/acceptance-operations-restore-pty.py"
release_backup_restore_step=restore-execute
[ -x "$pty" ] || { printf 'restore PTY helper is unavailable\n' >&2; exit 1; }
PLAINPOST_PRIVATE_ROOT="$temporary" \
PLAINPOST_PRIVATE_NODE_IMAGE="$node_image" \
PLAINPOST_ACCEPTANCE_NODE_UID="$node_uid" \
PLAINPOST_ACCEPTANCE_NODE_GID="$node_gid" \
PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE="$attachment_storage" \
PLAINPOST_ACCEPTANCE_ATTACHMENT_DIR="$attachment_dir" \
PLAINPOST_ACCEPTANCE_S3_ENDPOINT="$s3_endpoint" \
PLAINPOST_ACCEPTANCE_S3_BUCKET="$s3_bucket" \
PLAINPOST_ACCEPTANCE_S3_REGION="$s3_region" \
PLAINPOST_ACCEPTANCE_S3_ADDRESSING="$s3_addressing" \
PLAINPOST_ACCEPTANCE_S3_ACCESS_KEY_FILE="$s3_access_key_file" \
PLAINPOST_ACCEPTANCE_S3_SECRET_KEY_FILE="$s3_secret_key_file" \
PLAINPOST_RELEASE_NODE_IMAGE="$node_image" \
python3 "$pty" --digest "$digest" --timeout-seconds 120 -- \
  docker compose -p "$project" -f "$compose" -f "$release_override" run --rm --pull never --no-deps \
  --user 65532:65532 \
  --volume "$backup_path:/node-data/backups/restore-input.ppb:ro" \
  --name "$restore_run_name" \
  --label com.plainpost.acceptance=release-backup-restore \
  --label com.plainpost.acceptance-action=restore \
  node-one operations restore --backup "/node-data/backups/restore-input.ppb" --digest "$digest" \
  >"$restore_output" 2>>"$runtime_log" \
  || restore_pty_status=$?
if [ "${restore_pty_status:-0}" -ne 0 ]; then
  restore_failure_category=$(classify_release_restore_failure "$restore_pty_status" "$restore_output")
  printf 'ERROR release-backup-restore failure category=%s\n' "$restore_failure_category" >>"$runtime_log"
  if [ "$restore_failure_category" = prepare ]; then
    restore_prepare_step=$(classify_release_restore_prepare_step "$restore_output")
    if [ "$restore_prepare_step" != unknown ]; then
      printf 'ERROR release-backup-restore prepare-step=%s\n' "$restore_prepare_step" >>"$runtime_log"
    fi
  fi
  if [ "$restore_failure_category" = commit ]; then
    restore_commit_step=$(classify_release_restore_commit_step "$restore_output")
    if [ "$restore_commit_step" != unknown ]; then
      printf 'ERROR release-backup-restore commit-step=%s\n' "$restore_commit_step" >>"$runtime_log"
    fi
  fi
  printf 'release restore command failed\n' >&2
  exit 1
fi
assert_container_absent "$restore_run_name" || { printf 'release restore run container was not removed\n' >&2; exit 1; }
release_backup_restore_step=restore-verify
tr -d '\r' <"$restore_output" | grep -Fx 'state=restored' >/dev/null || { printf 'release restore did not return restored state\n' >&2; exit 1; }

release_backup_restore_step=database-reference
reference="$temporary/node-one-data/restore-references/database"
restore_database=$(acceptance_active_database_name "$reference" '' "$(dirname "$reference")" required 2>/dev/null || true)
printf '%s\n' "$restore_database" | grep -Eq '^restore_[0-9a-f]{32}$' || { printf 'release restore database reference is invalid\n' >&2; exit 1; }
printf 'release-backup-restore database-reference-validated=1\n' >>"$runtime_log"
