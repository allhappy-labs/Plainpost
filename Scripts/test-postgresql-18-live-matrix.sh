#!/usr/bin/env bash
set -euo pipefail

# Re-exec once with explicit nonsecret identity/toolchain inputs. Owned URLs
# are generated below and live only in this fixture's children, never ambient.
if [[ "${PLAINPOST_PG18_OWNED_ENV:-}" != 1 ]]; then
	exec python3 - "$0" "$@" <<'PYENV'
import os, sys
allowed = ("PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT", "LANG", "LC_ALL",
           "GOPATH", "GOCACHE", "GOMODCACHE", "GOTOOLCHAIN", "PLAINPOST_PG18_MATRIX_RUN_ID")
clean = {key: os.environ[key] for key in allowed if key in os.environ}
clean["PLAINPOST_PG18_OWNED_ENV"] = "1"
os.execve("/bin/bash", ["bash", *sys.argv[1:]], clean)
PYENV
fi

# Task 4 live owner. Keep the two clusters separate: repository tests may leave
# schemas and journals behind, while restore tests deliberately drop databases.
# Required live owners: TestPostgresDumpLivePostgres18,
# TestPostgresRestoreLivePostgres18, TestPostgresFixedResetLivePostgres18,
# TestLiveClientAttachmentCapabilityIsDurableScopedUniqueAndCascades, and the
# calendar lifecycle owners TestCalendarLiveDisconnectPreventsLateWrite,
# TestCalendarLiveEraseCascades, and TestCalendarLiveBackupRestore.
# Never let a caller-provided password mask a missing credential in a pgx URL.
# PostgreSQL CLI wrappers use their per-cluster PGPASSFILE explicitly.
unset PGPASSWORD
readonly postgres_image="postgres:18.6-alpine3.24@sha256:d3e1620b530c944afa6e887d22eb899824da68e19c52024bf98f5220c88a65b2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly go_root="$repo_root/Services/PlainpostGo"

mode="focused"
race=0
pass_mode="both"
for argument in "$@"; do
	case "$argument" in
		--focused) mode="focused" ;;
		--full) mode="full" ;;
		--node-lifecycle) mode="node-lifecycle" ;;
		--integration) mode="integration" ;;
		--race) race=1; pass_mode="single" ;;
		--pass=normal) race=0; pass_mode="single" ;;
		--pass=race) race=1; pass_mode="single" ;;
		'') ;;
		*) echo "usage: $0 [--focused|--full|--node-lifecycle|--integration] [--race]" >&2; exit 2 ;;
	esac
done

if [[ -n "${PLAINPOST_PG18_MATRIX_RUN_ID:-}" ]]; then
	run_id="$PLAINPOST_PG18_MATRIX_RUN_ID"
else
	run_id="$(printf '%s-%s' "$$" "$(date +%s)")"
fi
if [[ ! "$run_id" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; then
	echo "PLAINPOST_PG18_MATRIX_RUN_ID must match [a-z0-9][a-z0-9-]{0,62}" >&2
	exit 2
fi

if [[ "$pass_mode" == both ]]; then
	base_run_id="${run_id:0:45}"
	PLAINPOST_PG18_MATRIX_RUN_ID="${base_run_id}-normal-$$" "$0" "--$mode" --pass=normal
	PLAINPOST_PG18_MATRIX_RUN_ID="${base_run_id}-race-$$" "$0" "--$mode" --pass=race
	exit 0
fi

docker_endpoint="$(docker context inspect --format '{{.Endpoints.docker.Host}}')"
if [[ "$docker_endpoint" != unix:///* ]]; then
	echo "fixture requires a local Unix Docker context" >&2; exit 1
fi
python3 - "$repo_root" <<'PYSPACE'
import shutil,sys
if shutil.disk_usage(sys.argv[1]).free < 15 * 1024**3:
    sys.exit("fixture requires at least 15 GiB free before allocation")
PYSPACE

readonly general_container="plainpost-pg18-matrix-general-$run_id"
readonly general_volume="plainpost-pg18-matrix-general-volume-$run_id"
readonly general_network="plainpost-pg18-matrix-general-network-$run_id"
readonly general_loopback="plainpost-pg18-matrix-general-loopback-$run_id"
readonly general_tls_volume="plainpost-pg18-matrix-general-tls-$run_id"
readonly general_credentials_volume="plainpost-pg18-matrix-general-credentials-$run_id"
readonly backup_container="plainpost-pg18-matrix-backup-$run_id"
readonly backup_volume="plainpost-pg18-matrix-backup-volume-$run_id"
readonly backup_network="plainpost-pg18-matrix-backup-network-$run_id"
readonly backup_loopback="plainpost-pg18-matrix-backup-loopback-$run_id"
readonly backup_tls_volume="plainpost-pg18-matrix-backup-tls-$run_id"
readonly backup_credentials_volume="plainpost-pg18-matrix-backup-credentials-$run_id"
readonly temp_root="/private/tmp/plainpost-pg18-live-matrix.$run_id"

if [[ -e "$temp_root" ]]; then
	echo "task-owned matrix temp root already exists: $temp_root" >&2
	exit 2
fi
mkdir "$temp_root"

created_containers=()
created_networks=()
created_volumes=()
created_temp_files=()
cleanup_failed=0
# Cleanup success alone is not a completed test dispatch.
matrix_complete=0
readonly ownership_label="com.plainpost.pg18.matrix.run"

is_exact_absent() {
	local kind="$1" name="$2" output="$3"
	case "$kind" in
		container)
			[[ "$output" == *"No such container: $name"* || "$output" == *"No such object: $name"* ]]
			;;
		network)
			[[ "$output" == *"network $name not found"* ]]
			;;
		volume)
			[[ "$output" == *"get $name: no such volume"* || "$output" == *"no such volume: $name"* ]]
			;;
		*) return 1 ;;
	esac
}

inspect_absent() {
	local kind="$1" name="$2" output
	if case "$kind" in
		container) output="$(docker container inspect "$name" 2>&1)" ;;
		network) output="$(docker network inspect "$name" 2>&1)" ;;
		volume) output="$(docker volume inspect "$name" 2>&1)" ;;
		*) return 1 ;;
	esac
	then
		echo "cleanup: $kind $name still exists" >&2
		return 1
	fi
	if ! is_exact_absent "$kind" "$name" "$output"; then
		echo "cleanup: $kind $name inspect failed unexpectedly: $output" >&2
		return 1
	fi
}

remove_owned() {
	local kind="$1" name="$2" output
	case "$kind" in
		container) output="$(docker container rm --force "$name" 2>&1)" || {
			if ! is_exact_absent "$kind" "$name" "$output"; then
				echo "cleanup: remove $kind $name failed: $output" >&2
				return 1
			fi
		} ;;
		network) output="$(docker network rm "$name" 2>&1)" || {
			if ! is_exact_absent "$kind" "$name" "$output"; then
				echo "cleanup: remove $kind $name failed: $output" >&2
				return 1
			fi
		} ;;
		volume) output="$(docker volume rm "$name" 2>&1)" || {
			if ! is_exact_absent "$kind" "$name" "$output"; then
				echo "cleanup: remove $kind $name failed: $output" >&2
				return 1
			fi
		} ;;
		*) echo "cleanup: unsupported resource kind $kind" >&2; return 1 ;;
	esac
	inspect_absent "$kind" "$name"
}

assert_absent_before_create() {
	local kind="$1" name="$2"
	if inspect_absent "$kind" "$name"; then
		return 0
	fi
	echo "matrix resource already exists or cannot be inspected: $kind $name" >&2
	return 1
}

resource_owned_by_run() {
	local kind="$1" name="$2" label
	case "$kind" in
		container) label="$(docker container inspect --format "{{index .Config.Labels \"$ownership_label\"}}" "$name" 2>/dev/null || true)" ;;
		network) label="$(docker network inspect --format "{{index .Labels \"$ownership_label\"}}" "$name" 2>/dev/null || true)" ;;
		volume) label="$(docker volume inspect --format "{{index .Labels \"$ownership_label\"}}" "$name" 2>/dev/null || true)" ;;
		*) return 1 ;;
	esac
	[[ "$label" == "$run_id" ]]
}

track_partial_resource() {
	local kind="$1" name="$2" collection="$3"
	if resource_owned_by_run "$kind" "$name"; then
		case "$collection" in
			created_containers) created_containers+=("$name") ;;
			created_networks) created_networks+=("$name") ;;
			created_volumes) created_volumes+=("$name") ;;
			*) echo "cleanup: unsupported resource collection $collection" >&2; return 1 ;;
		esac
	fi
}

credential_file() {
	local path="$1"
	[[ -f "$path" ]] || { echo "credential leaf is missing: $path" >&2; return 1; }
	[[ "$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path")" == 600 ]] || {
		echo "credential leaf is not mode 0600: $path" >&2
		return 1
	}
}

write_credential() {
	local path="$1"
	created_temp_files+=("$path")
	(umask 077; openssl rand -hex 24 >"$path")
	chmod 0600 "$path"
	credential_file "$path"
}

write_pgpass() {
	local path="$1" prefix="$2" role password_path password
	created_temp_files+=("$path")
	{
		for role in postgres plainpost_central plainpost_sync_node plainpost_backup plainpost_restore_admin plainpost_restore_stage; do
			password_path="$prefix-$role.password"
			[[ -f "$password_path" ]] || continue
			password="$(<"$password_path")"
			printf '127.0.0.1:5432:*:%s:%s\n' "$role" "$password"
		done
	} >"$path"
	chmod 0600 "$path"
	credential_file "$path"
}

create_tls_assets() {
	local ca_key="$temp_root/postgres-ca.key" ca_cert="$temp_root/postgres-ca.crt"
	local server_key="$temp_root/postgres-server.key" server_csr="$temp_root/postgres-server.csr"
	local server_cert="$temp_root/postgres-server.crt" server_ext="$temp_root/postgres-server.ext"
	local hba="$temp_root/pg_hba.conf"
	created_temp_files+=("$ca_key" "$ca_cert" "$server_key" "$server_csr" "$server_cert" "$server_ext" "$hba")
	openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=Plainpost PG18 Matrix CA' \
		-keyout "$ca_key" -out "$ca_cert" >/dev/null 2>&1
	openssl req -new -newkey rsa:2048 -nodes -subj '/CN=127.0.0.1' \
		-keyout "$server_key" -out "$server_csr" >/dev/null 2>&1
	printf '%s\n' 'subjectAltName=IP:127.0.0.1' >"$server_ext"
	openssl x509 -req -days 1 -set_serial 1 -in "$server_csr" \
		-CA "$ca_cert" -CAkey "$ca_key" -extfile "$server_ext" -out "$server_cert" >/dev/null 2>&1
	printf '%s\n' \
		'local all all trust' \
		'hostssl all all 0.0.0.0/0 scram-sha-256' \
		'hostssl all all ::/0 scram-sha-256' \
		'hostnossl all all 0.0.0.0/0 reject' \
		'hostnossl all all ::/0 reject' >"$hba"
	chmod 0600 "$ca_key" "$server_key" "$server_csr" "$server_ext"
	chmod 0644 "$ca_cert" "$server_cert" "$hba"
}

remove_temp_file() {
	local path="$1"
	if [[ -e "$path" ]]; then
		if ! rm -f "$path"; then
			echo "cleanup: remove task-owned temp file failed: $path" >&2
			return 1
		fi
	fi
	if [[ -e "$path" ]]; then
		echo "cleanup: task-owned temp file remains: $path" >&2
		return 1
	fi
}

cleanup() {
	local status="${1:-$?}"
	trap - EXIT INT TERM
	local index
	for ((index=${#created_containers[@]}-1; index>=0; index--)); do
		if ! remove_owned container "${created_containers[index]}"; then cleanup_failed=1; fi
	done
	for ((index=${#created_networks[@]}-1; index>=0; index--)); do
		if ! remove_owned network "${created_networks[index]}"; then cleanup_failed=1; fi
	done
	for ((index=${#created_volumes[@]}-1; index>=0; index--)); do
		if ! remove_owned volume "${created_volumes[index]}"; then cleanup_failed=1; fi
	done
	for ((index=${#created_temp_files[@]}-1; index>=0; index--)); do
		if ! remove_temp_file "${created_temp_files[index]}"; then cleanup_failed=1; fi
	done
	if [[ -e "$temp_root" ]]; then
		if ! rmdir "$temp_root"; then
			echo "cleanup: task-owned temp root is not empty: $temp_root" >&2
			cleanup_failed=1
		fi
	fi
	if ((status == 0 && (cleanup_failed || matrix_complete == 0))); then
		status=1
	fi
	if ((cleanup_failed == 0)); then
		echo "matrix cleanup: exact containers, networks, volumes, and temp root absent"
	else
		echo "matrix cleanup: FAILED (resources require bounded manual inspection)" >&2
	fi
	exit "$status"
}
handle_signal() {
	local status="$1"
	cleanup "$status"
}
trap 'cleanup "$?"' EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

stage() {
	local name="$1"; shift
	echo "matrix stage: $name"
	"$@"
	echo "matrix stage PASS: $name"
}

sql() {
	local container="$1" database="$2" statement="$3"
	if ! docker exec "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" -c "$statement" >/dev/null; then
		echo "matrix SQL failed: $container/$database: $statement" >&2
		return 1
	fi
}

wait_for_postgres() {
	local container="$1" database="$2" attempt state logs current previous=""
	for attempt in $(seq 1 60); do
		state="$(docker container inspect --format '{{.State.Status}}' "$container" 2>/dev/null || true)"
		logs="$(docker container logs --tail 80 "$container" 2>&1 || true)"
		# pg_isready also reports the short-lived init server. Require the
		# official entrypoint's final-init marker before accepting readiness.
		if [[ "$state" == running && "$logs" == *"PostgreSQL init process complete; ready for start up."* ]] &&
			docker exec "$container" pg_isready -U postgres -d "$database" >/dev/null 2>&1; then
			current="$(docker exec "$container" psql -Atq -U postgres -d "$database" -c 'SELECT pg_postmaster_start_time()' 2>/dev/null || true)"
			if [[ -n "$current" && "$current" == "$previous" ]]; then
				return 0
			fi
			previous="$current"
		else
			previous=""
		fi
		if ((attempt < 60)); then sleep 1; fi
	done
	echo "PostgreSQL did not reach stable final-entrypoint readiness: $container/$database" >&2
	docker container logs --tail 80 "$container" >&2 || true
	return 1
}

start_cluster() {
	local label="$1" container="$2" volume="$3" network="$4" loopback="$5" tls_volume="$6" credentials_volume="$7" database="$8" bootstrap_password_file="$9" pgpass_file="${10}"
	local bootstrap_name="${bootstrap_password_file##*/}" pgpass_name="${pgpass_file##*/}"
	assert_absent_before_create network "$network"
	assert_absent_before_create network "$loopback"
	assert_absent_before_create volume "$volume"
	assert_absent_before_create volume "$tls_volume"
	assert_absent_before_create volume "$credentials_volume"
	assert_absent_before_create container "$container"
	docker network create --internal --label "$ownership_label=$run_id" "$network" >/dev/null || {
		track_partial_resource network "$network" created_networks
		return 1
	}
	created_networks+=("$network")
	docker network create --label "$ownership_label=$run_id" "$loopback" >/dev/null || {
		track_partial_resource network "$loopback" created_networks
		return 1
	}
	created_networks+=("$loopback")
	docker volume create --label "$ownership_label=$run_id" "$volume" >/dev/null || {
		track_partial_resource volume "$volume" created_volumes
		return 1
	}
	created_volumes+=("$volume")
	docker volume create --label "$ownership_label=$run_id" "$tls_volume" >/dev/null || {
		track_partial_resource volume "$tls_volume" created_volumes
		return 1
	}
	created_volumes+=("$tls_volume")
	docker volume create --label "$ownership_label=$run_id" "$credentials_volume" >/dev/null || {
		track_partial_resource volume "$credentials_volume" created_volumes
		return 1
	}
	created_volumes+=("$credentials_volume")
	docker run --rm --entrypoint sh \
		--mount "type=volume,source=$tls_volume,destination=/run/postgres-tls" \
		--mount "type=bind,source=$temp_root,destination=/source,readonly" \
		"$postgres_image" -ceu \
		'cp /source/postgres-ca.crt /source/postgres-server.crt /source/postgres-server.key /source/pg_hba.conf /run/postgres-tls/ && chmod 0644 /run/postgres-tls/postgres-ca.crt /run/postgres-tls/postgres-server.crt /run/postgres-tls/pg_hba.conf && chmod 0600 /run/postgres-tls/postgres-server.key && chown "$(id -u postgres):$(id -g postgres)" /run/postgres-tls/postgres-server.key' || return 1
	docker run --rm --entrypoint sh \
		--mount "type=volume,source=$credentials_volume,destination=/run/credentials" \
		--mount "type=bind,source=$temp_root,destination=/source,readonly" \
		"$postgres_image" -ceu \
		"cp /source/$bootstrap_name /run/credentials/postgres-password && cp /source/$pgpass_name /run/credentials/pgpass && chmod 0600 /run/credentials/postgres-password /run/credentials/pgpass && chown \"\$(id -u postgres):\$(id -g postgres)\" /run/credentials/postgres-password /run/credentials/pgpass" || return 1
	docker run --detach \
		--name "$container" \
		--label "$ownership_label=$run_id" \
		--network "$loopback" \
		--publish 127.0.0.1::5432 \
		--mount "type=volume,source=$volume,destination=/var/lib/postgresql" \
		--mount "type=volume,source=$tls_volume,destination=/run/postgres-tls,readonly" \
		--mount "type=volume,source=$credentials_volume,destination=/run/credentials,readonly" \
		--env POSTGRES_DB="$database" \
		--env POSTGRES_USER=postgres \
		--env POSTGRES_PASSWORD_FILE=/run/credentials/postgres-password \
		"$postgres_image" postgres \
			-c ssl=on -c ssl_ca_file=/run/postgres-tls/postgres-ca.crt \
			-c ssl_cert_file=/run/postgres-tls/postgres-server.crt \
			-c ssl_key_file=/run/postgres-tls/postgres-server.key \
			-c hba_file=/run/postgres-tls/pg_hba.conf >/dev/null || {
			track_partial_resource container "$container" created_containers
			return 1
		}
	created_containers+=("$container")
	docker network connect "$network" "$container"
	wait_for_postgres "$container" "$database"
	local attached actual expected
	local -a attached_networks=()
	attached="$(docker container inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}' "$container")"
	read -ra attached_networks <<< "$attached"
	actual="$(printf '%s\n' "${attached_networks[@]}" | sort | tr '\n' ' ')"
	expected="$(printf '%s\n' "$network" "$loopback" | sort | tr '\n' ' ')"
	if [[ "$actual" != "$expected" ]]; then
		echo "$label container has unexpected network set: $attached" >&2
		return 1
	fi
}

create_roles_and_databases() {
	local container="$1" database="$2" create_journal="${3:-0}" credential_prefix="${4:-}"
	for statement in \
		"CREATE ROLE plainpost_central LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT" \
		"CREATE ROLE plainpost_sync_node LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT" \
		"CREATE ROLE plainpost_backup LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT" \
		"CREATE ROLE plainpost_restore_admin LOGIN NOSUPERUSER CREATEDB NOCREATEROLE NOINHERIT" \
		"CREATE ROLE plainpost_restore_stage LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT"; do
		sql "$container" postgres "DO \$\$ BEGIN $statement; EXCEPTION WHEN duplicate_object THEN NULL; END \$\$;" || return 1
	done
	sql "$container" postgres "GRANT plainpost_restore_stage TO plainpost_restore_admin WITH INHERIT TRUE, SET TRUE" || return 1
	sql "$container" postgres "GRANT plainpost_sync_node TO plainpost_restore_admin WITH INHERIT TRUE, SET TRUE" || return 1
	sql "$container" postgres "ALTER DATABASE \"$database\" OWNER TO plainpost_restore_admin" || return 1
	if [[ -n "$credential_prefix" ]]; then
		local role password_path password
		for role in postgres plainpost_central plainpost_sync_node plainpost_backup plainpost_restore_admin plainpost_restore_stage; do
			password_path="$credential_prefix-$role.password"
			credential_file "$password_path" || return 1
			password="$(<"$password_path")"
			printf 'ALTER ROLE "%s" PASSWORD '\''%s'\'';\n' "$role" "$password" |
				docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null || return 1
		done
	fi
	if [[ "$create_journal" == 1 ]]; then
		sql "$container" postgres "CREATE DATABASE plainpost_matrix_journal OWNER postgres" || return 1
	fi
}

tool_wrapper() {
	local wrapper="$1" backup_target="$2"
	cat >"$wrapper" <<EOF
#!/usr/bin/env bash
set -euo pipefail
binary="\$1"
shift
stdin_flags=()
case "\$binary" in
  pg_dump|pg_restore) target="$backup_target" ;;
  *) echo "unknown PostgreSQL tool binary: \$binary" >&2; exit 2 ;;
esac
rewritten=()
for argument in "\$@"; do
  if [[ "\$argument" == --dbname=* ]]; then
    value="\${argument#--dbname=}"
    if [[ "\$value" =~ ^(.*@)127\\.0\\.0\\.1:[0-9]+(.*)$ ]]; then
      value="\${BASH_REMATCH[1]}127.0.0.1:5432\${BASH_REMATCH[2]}"
    fi
    argument="--dbname=\$value"
  fi
  rewritten+=("\$argument")
done
if [[ "\$binary" == pg_restore ]]; then
  stdin_flags=(-i)
fi
exec docker exec --env PGSSLROOTCERT=/run/postgres-tls/postgres-ca.crt --env PGPASSFILE=/run/credentials/pgpass "\${stdin_flags[@]}" "\$target" "\$binary" "\${rewritten[@]}"
EOF
	chmod 700 "$wrapper"
}

stage "Docker daemon and PostgreSQL 18 image owner" docker image inspect "$postgres_image" >/dev/null
stage "OpenSSL certificate generator" command -v openssl >/dev/null
general_postgres_credential="$temp_root/general-postgres.password"
backup_postgres_credential="$temp_root/backup-postgres.password"
write_credential "$general_postgres_credential"
write_credential "$temp_root/general-plainpost_central.password"
write_credential "$temp_root/general-plainpost_sync_node.password"
write_credential "$temp_root/general-plainpost_backup.password"
write_credential "$temp_root/general-plainpost_restore_admin.password"
write_credential "$temp_root/general-plainpost_restore_stage.password"
write_credential "$backup_postgres_credential"
write_credential "$temp_root/backup-plainpost_central.password"
write_credential "$temp_root/backup-plainpost_sync_node.password"
write_credential "$temp_root/backup-plainpost_backup.password"
write_credential "$temp_root/backup-plainpost_restore_admin.password"
write_credential "$temp_root/backup-plainpost_restore_stage.password"
general_pgpass="$temp_root/general.pgpass"
backup_pgpass="$temp_root/backup.pgpass"
write_pgpass "$general_pgpass" "$temp_root/general"
write_pgpass "$backup_pgpass" "$temp_root/backup"
stage "TLS certificate and hostssl policy" create_tls_assets

stage "general repository PostgreSQL 18 environment" start_cluster general "$general_container" "$general_volume" "$general_network" "$general_loopback" "$general_tls_volume" "$general_credentials_volume" plainpost_matrix_general "$general_postgres_credential" "$general_pgpass"
stage "general repository role and deletion-journal setup" create_roles_and_databases "$general_container" plainpost_matrix_general 1 "$temp_root/general"
general_port="$(docker port "$general_container" 5432/tcp | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p')"
if [[ -z "$general_port" ]]; then echo "general repository published port is unavailable" >&2; exit 1; fi

stage "backup/restore PostgreSQL 18 environment" start_cluster backup "$backup_container" "$backup_volume" "$backup_network" "$backup_loopback" "$backup_tls_volume" "$backup_credentials_volume" plainpost_matrix_backup "$backup_postgres_credential" "$backup_pgpass"
stage "backup/restore role topology" create_roles_and_databases "$backup_container" plainpost_matrix_backup 0 "$temp_root/backup"
stage "backup/restore distinct restore-admin-owned source database" sql "$backup_container" postgres 'CREATE DATABASE plainpost_matrix_backup_source OWNER plainpost_restore_admin'
stage "backup/restore source database CONNECT authority" sql "$backup_container" postgres 'REVOKE CONNECT ON DATABASE plainpost_matrix_backup_source FROM PUBLIC; GRANT CONNECT ON DATABASE plainpost_matrix_backup_source TO plainpost_sync_node; GRANT CONNECT ON DATABASE plainpost_matrix_backup_source TO plainpost_restore_admin; ALTER ROLE plainpost_sync_node IN DATABASE plainpost_matrix_backup_source SET search_path = public'
stage "backup/restore source schema authority" sql "$backup_container" plainpost_matrix_backup_source 'REVOKE ALL ON SCHEMA public FROM PUBLIC; GRANT USAGE, CREATE ON SCHEMA public TO plainpost_sync_node; GRANT USAGE ON SCHEMA public TO plainpost_backup; GRANT SELECT ON ALL TABLES IN SCHEMA public TO plainpost_backup; GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO plainpost_backup; REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC'
stage "backup/restore source default privilege authority" sql "$backup_container" plainpost_matrix_backup_source 'ALTER DEFAULT PRIVILEGES FOR ROLE plainpost_sync_node REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC; ALTER DEFAULT PRIVILEGES FOR ROLE plainpost_sync_node IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC; ALTER DEFAULT PRIVILEGES FOR ROLE plainpost_sync_node IN SCHEMA public GRANT SELECT ON TABLES TO plainpost_backup; ALTER DEFAULT PRIVILEGES FOR ROLE plainpost_sync_node IN SCHEMA public REVOKE ALL ON SEQUENCES FROM PUBLIC; ALTER DEFAULT PRIVILEGES FOR ROLE plainpost_sync_node IN SCHEMA public GRANT SELECT ON SEQUENCES TO plainpost_backup; ALTER DEFAULT PRIVILEGES FOR ROLE plainpost_sync_node REVOKE ALL ON TABLES FROM PUBLIC; ALTER DEFAULT PRIVILEGES FOR ROLE plainpost_sync_node REVOKE ALL ON SEQUENCES FROM PUBLIC; ALTER DEFAULT PRIVILEGES FOR ROLE plainpost_sync_node REVOKE ALL ON FUNCTIONS FROM PUBLIC'
backup_port="$(docker port "$backup_container" 5432/tcp | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p')"
if [[ -z "$backup_port" ]]; then echo "backup/restore published port is unavailable" >&2; exit 1; fi

created_temp_files+=("$temp_root/pg-tools")
tool_wrapper "$temp_root/pg-tools" "$backup_container"

general_password="$(<"$general_postgres_credential")"
backup_admin_password="$(<"$temp_root/backup-plainpost_restore_admin.password")"
backup_stage_password="$(<"$temp_root/backup-plainpost_restore_stage.password")"
backup_node_password="$(<"$temp_root/backup-plainpost_sync_node.password")"
# Every pgx authority URL carries its own private credential. PostgreSQL client
# subprocesses use the per-cluster PGPASSFILE supplied by their wrapper; do not
# mask missing credentials in a derived runtime-role URL with PGPASSWORD.
export PGSSLROOTCERT="$temp_root/postgres-ca.crt"
general_url="postgres://postgres:${general_password}@127.0.0.1:$general_port/plainpost_matrix_general?sslmode=verify-full"
general_journal_url="postgres://postgres:${general_password}@127.0.0.1:$general_port/plainpost_matrix_journal?sslmode=verify-full"
backup_source_url="postgres://plainpost_sync_node:${backup_node_password}@127.0.0.1:$backup_port/plainpost_matrix_backup_source?sslmode=verify-full"
backup_admin_url="postgres://plainpost_restore_admin:${backup_admin_password}@127.0.0.1:$backup_port/postgres?sslmode=verify-full"
backup_stage_url="postgres://plainpost_restore_stage:${backup_stage_password}@127.0.0.1:$backup_port/postgres?sslmode=verify-full"
backup_node_url="postgres://plainpost_sync_node:${backup_node_password}@127.0.0.1:$backup_port/plainpost_matrix_backup?sslmode=verify-full"

unset_matrix_database_environment() {
	unset PLAINPOST_REQUIRE_LIVE_POSTGRES PLAINPOST_RUN_SCHEMA_ISOLATION \
		PLAINPOST_RESET_STATE_AUTHORITY_TEST \
		TEST_POSTGRES_URL TEST_DELETION_JOURNAL_POSTGRES_URL TEST_POSTGRES_ADMIN_URL \
		TEST_POSTGRES_STAGE_URL TEST_POSTGRES_NODE_URL TEST_POSTGRES_RESET_ADMIN_URL \
		TEST_POSTGRES_RESET_STAGE_URL TEST_POSTGRES_RESET_DATABASE \
		PLAINPOST_TEST_PG_DUMP_PREFIX PLAINPOST_TEST_PG_RESTORE_PREFIX
}

# go_test PACKAGE PATTERN [REQUIRED_TEST...]: in focused mode every named
# required test must report its own PASS line; a selector that silently stops
# matching one owner is a failure, not a smaller green run.
go_test() {
	local package="$1" pattern="$2"
	shift 2
	local -a arguments=(test "$package" -run "$pattern" -count=1)
	if ((race)); then arguments+=( -race ); fi
	if [[ "$mode" == node-lifecycle || "$mode" == integration ]]; then
		local output status=0 expected_package="$package"
		# Relative selectors (node-lifecycle) must match Go JSON import paths.
		if [[ "$package" == ./* ]]; then
			expected_package="$(cd "$go_root" && go list -f '{{.ImportPath}}' "$package")"
		fi
		output="$( cd "$go_root" && go "${arguments[@]}" -json 2>&1 )" || status=$?
		# Test owners report sanitized errors. Redact fixture URLs defensively,
		# including any library error that unexpectedly embeds its connection.
		output="${output//"$general_url"/[owned-general-database]}"
		output="${output//"$general_journal_url"/[owned-journal-database]}"
		output="${output//"$backup_source_url"/[owned-backup-source]}"
		output="${output//"$backup_admin_url"/[owned-backup-admin]}"
		output="${output//"$backup_stage_url"/[owned-backup-stage]}"
		output="${output//"$backup_node_url"/[owned-backup-node]}"
		printf '%s\n' "$output"
		if ((status)); then return "$status"; fi
		python3 -c 'import collections,json,sys
mode,package=sys.argv[1:3]
required=sys.argv[3:]
rows=[]
for line in sys.stdin:
 try: rows.append(json.loads(line))
 except ValueError: pass
if not rows or any(r.get("Package") != package for r in rows): sys.exit("unexpected Go package identity")
runs=collections.Counter(r["Test"] for r in rows if r.get("Action")=="run" and "Test" in r)
passes=collections.Counter(r["Test"] for r in rows if r.get("Action")=="pass" and "Test" in r)
skips=collections.Counter(r["Test"] for r in rows if r.get("Action")=="skip" and "Test" in r)
no_test_files=not runs and any("[no test files]" in r.get("Output", "") for r in rows)
terminal=[r["Action"] for r in rows if "Test" not in r and r.get("Action") in ("pass","fail","skip")]
expected_terminal="skip" if no_test_files else "pass"
if terminal != [expected_terminal] or any(r.get("Action")=="fail" for r in rows): sys.exit("missing or failed package completion")
if runs != passes+skips or any(n != 1 for n in runs.values()): sys.exit("incomplete or duplicate test events")
if (not runs and not (mode=="integration" and no_test_files)) or (mode=="node-lifecycle" and skips) or not set(required).issubset(passes): sys.exit("missing, skipped, or zero test inventory")
print("source-bound test events: package=%s run=%d pass=%d skip=%d" % (package,len(runs),len(passes),len(skips)))' "$mode" "$expected_package" "$@" <<<"$output"
	elif [[ "$mode" == focused ]]; then
		local output status=0 name
		output="$( cd "$go_root" && go "${arguments[@]}" -v 2>&1 )" || status=$?
		if ((status)); then
			printf '%s\n' "$output"
			return "$status"
		fi
		if [[ "$output" == *"--- SKIP:"* || "$output" == *"no tests to run"* ]]; then
			printf '%s\n' "$output"
			echo "focused owner failed or skipped a required test: $package ($pattern)" >&2
			return 1
		fi
		for name in "$@"; do
			if ! grep -Eq -- "^--- PASS: ${name} \(" <<<"$output"; then
				printf '%s\n' "$output"
				echo "focused owner did not execute required test: $package ($name)" >&2
				return 1
			fi
		done
		printf '%s\n' "$output" | tail -n 2
		echo "focused owner: required tests ran without skips"
	else
		( cd "$go_root" && go "${arguments[@]}" )
	fi
}

run_general_tests() {
	local selector="$1"
	unset_matrix_database_environment
	export PLAINPOST_REQUIRE_LIVE_POSTGRES=1
	export PLAINPOST_RUN_SCHEMA_ISOLATION=1
	export TEST_POSTGRES_URL="$general_url"
	export TEST_DELETION_JOURNAL_POSTGRES_URL="$general_journal_url"
	go_test ./internal/central/postgres "$selector"
}

run_acceptance_tests() {
	local selector="$1"
	unset_matrix_database_environment
	export PLAINPOST_REQUIRE_LIVE_POSTGRES=1
	export PLAINPOST_RESET_STATE_AUTHORITY_TEST=enabled
	export TEST_POSTGRES_URL="$general_url"
	go_test ./internal/acceptance "$selector"
}

run_node_tests() {
	local selector="$1"
	shift
	unset_matrix_database_environment
	export PLAINPOST_REQUIRE_LIVE_POSTGRES=1
	export TEST_POSTGRES_URL="$general_url"
	go_test ./internal/node/postgres "$selector" "$@"
}

run_node_clientapi_tests() {
	local selector="$1"
	shift
	unset_matrix_database_environment
	export PLAINPOST_REQUIRE_LIVE_POSTGRES=1
	export TEST_POSTGRES_URL="$general_url"
	go_test ./internal/node/clientapi "$selector" "$@"
}

run_node_mutation_tests() {
	local selector="$1"
	shift
	unset_matrix_database_environment
	export PLAINPOST_REQUIRE_LIVE_POSTGRES=1
	export TEST_POSTGRES_URL="$general_url"
	go_test ./internal/node/mutation "$selector" "$@"
}

run_secret_tests() {
 local selector="$1"
 unset_matrix_database_environment
 export PLAINPOST_REQUIRE_LIVE_POSTGRES=1
 export TEST_POSTGRES_URL="$general_url"
 go_test ./internal/node/secrets "$selector"
}

run_backup_tests() {
	local package="$1" selector="$2"
	shift 2
	unset_matrix_database_environment
	export PLAINPOST_REQUIRE_LIVE_POSTGRES=1
	export TEST_POSTGRES_URL="$backup_source_url"
	export TEST_POSTGRES_ADMIN_URL="$backup_admin_url"
	export TEST_POSTGRES_STAGE_URL="$backup_stage_url"
	export TEST_POSTGRES_NODE_URL="$backup_node_url"
	export TEST_POSTGRES_RESET_ADMIN_URL="$backup_admin_url"
	export TEST_POSTGRES_RESET_STAGE_URL="$backup_stage_url"
	export TEST_POSTGRES_RESET_DATABASE=plainpost_matrix_backup
	export PLAINPOST_TEST_PG_DUMP_PREFIX="$temp_root/pg-tools"
	export PLAINPOST_TEST_PG_RESTORE_PREFIX="$temp_root/pg-tools"
	go_test "$package" "$selector" "$@"
}

if [[ "$mode" == node-lifecycle ]]; then
	unset_matrix_database_environment
	export PLAINPOST_REQUIRE_LIVE_POSTGRES=1
	export TEST_POSTGRES_URL="$general_url"
	stage "node lifecycle concrete assembly" go_test ./cmd/plainpost-sync-node 'Test.*(ShutdownNodeServers|RestoreReadiness|Close|ArchitectureProbe)' TestRestoreReadinessCloseFailurePreservesDependencies TestRestoreReadinessCloseCanRetryAfterOwnerFailure
elif [[ "$mode" == integration ]]; then
	# Every package appears exactly once per normal/race pass. Only the backup
	# package receives the destructive restore authority topology.
	package_inventory="$(cd "$go_root" && go list ./...)"
	if [[ -z "$package_inventory" ]]; then echo "empty Go package inventory" >&2; exit 1; fi
	printf 'integration package inventory (race=%s):\n%s\n' "$race" "$package_inventory"
	completed_packages=""
	while IFS= read -r package; do
		case "$package" in
			*/internal/node/backup)
				stage "integration backup authority: $package" run_backup_tests "$package" '.' TestPostgresDumpLivePostgres18 TestPostgresRestoreLivePostgres18 TestPostgresFixedResetLivePostgres18 TestCalendarLiveBackupRestore
				;;
			*)
				unset_matrix_database_environment
				export PLAINPOST_REQUIRE_LIVE_POSTGRES=1 PLAINPOST_RUN_SCHEMA_ISOLATION=1 PLAINPOST_RESET_STATE_AUTHORITY_TEST=enabled
				export TEST_POSTGRES_URL="$general_url" TEST_DELETION_JOURNAL_POSTGRES_URL="$general_journal_url"
				case "$package" in
					*/cmd/plainpost-sync-node) stage "integration general authority: $package" go_test "$package" '.' TestRestoreReadinessCloseFailurePreservesDependencies TestRestoreReadinessCloseCanRetryAfterOwnerFailure ;;
					*/internal/node/postgres) stage "integration general authority: $package" go_test "$package" '.' TestLiveClientAttachmentCapabilityIsDurableScopedUniqueAndCascades TestCalendarLiveDisconnectPreventsLateWrite TestCalendarLiveEraseCascades ;;
					*/internal/acceptance) stage "integration general authority: $package" go_test "$package" '.' TestTask7NodeDatabaseResetAuthorityLivePostgreSQL18 ;;
					*) stage "integration general authority: $package" go_test "$package" '.' ;;
				esac
				;;
		esac
		completed_packages+="$package"$'\n'
	done <<<"$package_inventory"
	python3 -c 'import sys
declared=sys.argv[1].splitlines()
completed=sys.argv[2].splitlines()
if not declared or any(not p for p in declared) or len(set(declared)) != len(declared) or completed != declared: sys.exit("incomplete or duplicate integration package inventory")
print("integration package completion: declared=%d completed=%d" % (len(declared),len(completed)))' "$package_inventory" "$completed_packages"
elif [[ "$mode" == focused ]]; then
	stage "Task7 reset authority against isolated PostgreSQL 18 database" run_acceptance_tests '^TestTask7NodeDatabaseResetAuthorityLivePostgreSQL18$'
	stage "central account/deletion migrations" run_general_tests 'Test(LiveCurrentMigrationsRemoveLegacyStepUpTargetConstraint|LiveCurrentMigrationsEnforceStepUpTTL|AccountRepositoryLiveGenesisChallengeReplayAndRollback|AccountLifecycleRepositoryLiveDeletesAuthorityAndPersistsCleanupAtomically|DeletionReplayRepairsStaleAccountRestoreFromPhysicallySeparateJournal)$'
	stage "schema isolation and denied privileges" run_general_tests 'TestSchemaIsolationLive$'
	stage "calendar store live owner" run_node_tests 'TestCalendarLive'
	stage "mail mode multi-account Node owner" run_node_tests '^TestMailModeLive' TestMailModeLiveLegacyRoutesProjectPrimaryWhileNewRoutesSeeEveryAccount TestMailModeLivePre0042SingleGmailMigratesAsPrimaryWebWithIdenticalProjection TestMailModeLiveAddingSecondAccountKeepsLegacyProjection TestMailModeLiveReservationLeftBehindNeverBecomesPrimary TestMailModeLivePromotionNeverRewritesMessageIDs TestMailModeLiveWaitingAccountDoesNotBlockAllAccountDeltas TestMailModeLiveReservationIsNeverAWaitingAccount TestMailModeLiveRemoveErasesCredentialsAndOrphanMessages TestMailModeLiveReimportAfterRemoveIsCreated TestMailModeLiveImportCommitListsAssignmentsAndRefusesConflicts TestMailModeLiveReplaceClearsAuthenticationRequired TestMailModeLiveReplaceClearsEveryDurableBlock TestMailModeLiveReplaceUpdatesOptionalRoles TestMailModeLiveUnchangedCredentialAppliesOptionalRoles TestMailModeLiveRemovingPrimaryPromotesOldestRemainingAccount TestMailModeLiveRemoveClearsCalendarSendingMailbox TestMailModeLiveEraseCascadesImports TestMailModeLiveMirrorCoordinatesExposeActiveMembershipsOnly TestMailModeLiveMirrorCoordinatesOmitRetiredEpochsAndUnaddressableRows TestMailModeLiveMembershipMessageIndexServesMessageLookups
	stage "mail mode client routes owner" run_node_clientapi_tests '^TestMailModeLive' TestMailModeLiveClientRoutesProjectPrimaryAndServeEveryAccount TestMailModeLiveScopedReadsServeOnlyTheScopedProviderAccount TestMailModeLiveWaitingAccountCompletionRecoveryDeliversEveryReadyChange TestMailModeLiveRemovingCalendarSenderReportsRemapRequired TestMailModeLiveMirrorCoordinatesRouteOmitsEpochResetMailbox
	stage "mail mode provider removal recovery and mutation service owners" run_node_mutation_tests '^Test(MailModeLive|LiveMutationService)' TestMailModeLiveRemovedAccountOperationsDoNotBlockRecovery TestLiveMutationServiceRetrySafeReissuesIdenticalVerifiedOperation TestLiveMutationServiceParentReceiptSurvivesReplay TestLiveMutationServiceCancelledSendIsDeliveryUncertainAndReleasesMailbox TestLiveMutationServiceCancelledDraftSendFinalizesDraftOnDetachedContext TestLiveMutationServiceUnobservedMembershipResolvesAfterWindow TestLiveMutationServiceClaimResolvesExpiredReconcilingHeads TestLiveMutationServiceRecoveryLeavesLiveProviderCallExecuting TestLiveMutationServiceRecoverySurvivesObserverProviderErrors TestLiveMutationServiceAbandonedPendingHeadResolvesAfterWindow TestLiveMutationServiceClaimResolvesAbandonedPendingDraftSend TestLiveMutationServiceQueuedFlagBehindReconcilingSendAppliesOnceSendResolves TestLiveMutationServiceRecoveryNeverCountsDowntimeAgainstPendingHead TestLiveMutationServiceRowAfterExpiredHeadGetsItsOwnWindow
	stage "calendar disconnect and erase lifecycle owners" run_node_tests '^Test(CalendarLiveDisconnectPreventsLateWrite|CalendarLiveEraseCascades)$' TestCalendarLiveDisconnectPreventsLateWrite TestCalendarLiveEraseCascades
	stage "calendar and existing secret envelopes" run_secret_tests 'Test(CalendarSecret|Live)'
	stage "Sync Node migrations through 0028 and repository" run_node_tests 'TestLive(NodeMigrationLedgerDetectsDriftAheadAndNonContiguousHistory|Task6MigrationHeadAndHistory|AttachmentPublicationReceiptMigrationBackfillsLegacyRows|ClientAttachmentCapabilityIsDurableScopedUniqueAndCascades|EnsureAccountAndProviderEpoch|OptionalAddressValidatorWorksWithEmptyCallerSearchPath)$'
	stage "Sync Node provider-start lease, recovery lease ownership, head observation retry and provider epoch fence owners" run_node_tests '^TestLive(MarkProviderStartedExtendsLeaseForTheProviderCall|DurableOperationFencesProviderEpochAtEveryAdmissionBoundary|RecoveryTreatsForeignProcessLeasesAsDead|SerializationRetryKeepsAbandonedHeadObservation)$' TestLiveMarkProviderStartedExtendsLeaseForTheProviderCall TestLiveDurableOperationFencesProviderEpochAtEveryAdmissionBoundary TestLiveRecoveryTreatsForeignProcessLeasesAsDead TestLiveSerializationRetryKeepsAbandonedHeadObservation
	stage "Sync Node runtime advisory lock supervision, startup database reachability, and failed-work head observation owners" run_node_tests '^TestLive(RuntimeLockSupervisionKeepsAHeldLock|RuntimeLockLossIsReportedWhileTheConnectionIsIdle|RuntimeLockReportsALockNoLongerHeld|RuntimeLockCheckSeesAnEndedSessionBeforeSupervision|FailedTransactionWorkPublishesNoHeadObservations|DatabaseReachabilityProbeSeparatesAnUnreachableServer)$' TestLiveRuntimeLockSupervisionKeepsAHeldLock TestLiveRuntimeLockLossIsReportedWhileTheConnectionIsIdle TestLiveRuntimeLockReportsALockNoLongerHeld TestLiveRuntimeLockCheckSeesAnEndedSessionBeforeSupervision TestLiveFailedTransactionWorkPublishesNoHeadObservations TestLiveDatabaseReachabilityProbeSeparatesAnUnreachableServer
	stage "backup/restore dump, encrypted container, reset, activation, readiness" run_backup_tests ./internal/node/backup 'Test(PostgresDumpLivePostgres18|PostgresRestoreLivePostgres18|PostgresActivationLivePostgres18|PostgresFixedResetLivePostgres18|PurgeDatabaseReplaysAfterEveryStatementBoundary|FormatRoundTripEncryptsManifestAndChunks|RestoreRecoveryIsIdempotentAcrossDurableFailpoints)$'
	stage "calendar backup/restore with pending work" run_backup_tests ./internal/node/backup '^TestCalendarLiveBackupRestore$' TestCalendarLiveBackupRestore
else
	stage "Task7 reset authority against isolated PostgreSQL 18 database" run_acceptance_tests '^TestTask7NodeDatabaseResetAuthorityLivePostgreSQL18$'
	stage "full central live matrix" run_general_tests 'Live'
	stage "full Sync Node live matrix" run_node_tests 'Live'
	stage "full backup/recovery live matrix" run_backup_tests ./internal/node/backup '(^Test.*Live|^TestPurgeDatabaseReplaysAfterEveryStatementBoundary$|^TestFormatRoundTripEncryptsManifestAndChunks$|^TestRestoreRecoveryIsIdempotentAcrossDurableFailpoints$)'
fi

matrix_complete=1
echo "PostgreSQL 18 live matrix PASS: mode=$mode race=$race image=$postgres_image"
