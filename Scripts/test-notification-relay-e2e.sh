#!/usr/bin/env bash
set -euo pipefail

# Local notification acceptance owner. This owns one short-lived PostgreSQL
# 18 cluster and runs the real Node -> HTTPS Central -> HTTPS APNs acceptance
# seam together with the PostgreSQL relay metadata tests. The fake APNs server
# is created by Go's TLS test server; no Apple service is contacted.
readonly postgres_image='postgres:18.6-alpine3.24@sha256:d3e1620b530c944afa6e887d22eb899824da68e19c52024bf98f5220c88a65b2'
repo_root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly go_root="$repo_root/Services/PlainpostGo"

if [[ "${1:-}" == --help ]]; then
	cat <<'EOF'
Usage: test-notification-relay-e2e.sh

Runs the local notification relay acceptance owner against a pinned,
TLS-enabled PostgreSQL 18 container. Docker/PostgreSQL unavailability is a
failure, never a skipped test.
EOF
	exit 0
fi
if (($# != 0)); then
	echo "usage: $0" >&2
	exit 2
fi

run_direct_policy_stage() {
	local scenario="$1" selector="$2" output
	output="$direct_policy_tmp/$scenario.log"
	if "$repo_root/Scripts/swift-test-isolated.sh" --package-path "$repo_root" --filter "$selector" >"$output" 2>&1; then
		printf 'stage=notification-direct-policy scenario=%s outcome=pass\n' "$scenario"
		return 0
	fi
	printf 'stage=notification-direct-policy scenario=%s outcome=fail category=swift-test\n' "$scenario" >&2
	return 1
}

run_direct_policy_contract() {
	command -v swift >/dev/null 2>&1 || {
		printf '%s\n' 'Swift is required for Direct policy acceptance' >&2
		return 1
	}
	umask 077
	direct_policy_tmp="$(mktemp -d "${TMPDIR:-/tmp}/plainpost-notification-direct-policy.XXXXXX")"
	trap 'find "$direct_policy_tmp" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
	run_direct_policy_stage default-materialization \
		NotificationRegistrationTests/testDirectRegistrationMaterializesAbsentRichDefaultBeforeClaimingRegistered
	run_direct_policy_stage direct-policy-snapshot-read \
		NotificationRuntimeTests/testDirectPolicyClientReadsVersionZeroRichDefaultAndOpaqueMailboxSnapshot
	run_direct_policy_stage mailbox-override-clear-tombstone \
		NotificationRuntimeTests/testDirectMailboxReadPreservesAbsentTombstoneAndActiveScopePredecessors
	run_direct_policy_stage mailbox-override-update-clear \
		PlainpostServiceOperationsTests/testDirectPolicySequencePreservesEffectiveVersionAndIndependentScopeHighWater
	run_direct_policy_stage off-fail-closed-stale-rich \
		NotificationOutboxTests/testOffDurableConfigurationSuppressesPublicationAndStaleCannotRestore
	run_direct_policy_stage mac-owner-scoped-read-contract-rejection \
		NotificationRuntimeTests/testAssignmentPolicyRemoteDirectDefaultRequiresCurrentMacAuthority
	run_direct_policy_stage restart-off-stale-rich \
		PlainpostServiceOperationsTests/testProductionCompositionReopensDirectPolicyAndPreservesOffEligibility
	run_direct_policy_stage mode-switch-authoritative-reload \
		NotificationRuntimeTests/testProductionAuthenticatedProducerSelectorSwitchesMacSyncNodeMacWithAuthoritativeReload
}

if [[ "${PLAINPOST_NOTIFICATION_DIRECT_POLICY_CONTRACT_TEST:-}" == enabled ]]; then
	run_direct_policy_contract
	exit $?
fi

if [[ "${PLAINPOST_NOTIFICATION_CLEANUP_CONTRACT_TEST:-}" != enabled ]]; then
	command -v docker >/dev/null 2>&1 || { echo 'Docker is required for notification relay acceptance' >&2; exit 1; }
	command -v openssl >/dev/null 2>&1 || { echo 'openssl is required for notification relay acceptance' >&2; exit 1; }
	command -v go >/dev/null 2>&1 || { echo 'Go is required for notification relay acceptance' >&2; exit 1; }
	if ! docker info >/dev/null 2>&1; then
		echo 'Docker daemon is unavailable for notification relay acceptance' >&2
		exit 1
	fi
fi

if [[ -n "${PLAINPOST_NOTIFICATION_E2E_RUN_ID:-}" ]]; then
	run_id="$PLAINPOST_NOTIFICATION_E2E_RUN_ID"
else
	run_id="$(printf '%s-%s' "$$" "$(date +%s)")"
fi
if [[ ! "$run_id" =~ ^[a-z0-9][a-z0-9-]{0,54}$ ]]; then
	echo 'PLAINPOST_NOTIFICATION_E2E_RUN_ID must match [a-z0-9][a-z0-9-]{0,54}' >&2
	exit 2
fi

readonly container="plainpost-notification-pg18-$run_id"
readonly network="plainpost-notification-network-$run_id"
readonly loopback_network="plainpost-notification-loopback-$run_id"
readonly volume="plainpost-notification-volume-$run_id"
readonly tls_volume="plainpost-notification-tls-$run_id"
readonly credentials_volume="plainpost-notification-credentials-$run_id"
readonly temp_root="/private/tmp/plainpost-notification-e2e.$run_id"
readonly ownership_label='com.plainpost.notification-e2e.run'

[[ ! -e "$temp_root" ]] || { echo "task-owned temp root already exists: $temp_root" >&2; exit 2; }
umask 077
mkdir -m 0700 "$temp_root"

created_containers=()
created_networks=()
created_volumes=()
created_files=()
cleanup_failed=0

resource_absent() {
	local kind="$1" name="$2" output
	case "$kind" in
		container)
			if output="$(docker container inspect "$name" 2>&1)"; then return 1; fi
			[[ "$output" == *"No such container: $name"* || "$output" == *"No such object: $name"* ]] || return 1
			;;
		network)
			if output="$(docker network inspect "$name" 2>&1)"; then return 1; fi
			[[ "$output" == *"network $name not found"* ]] || return 1
			;;
		volume)
			if output="$(docker volume inspect "$name" 2>&1)"; then return 1; fi
			[[ "$output" == *"no such volume: $name"* || "$output" == *"get $name: no such volume"* ]] || return 1
			;;
		*) return 1 ;;
	esac
}

assert_absent_before_create() {
	local kind="$1" name="$2"
	if ! resource_absent "$kind" "$name"; then
		echo "task-owned resource already exists or cannot be inspected: $kind $name" >&2
		return 1
	fi
}

owned_label() {
	local kind="$1" name="$2" value
	case "$kind" in
		container) if ! value="$(docker container inspect --format "{{index .Config.Labels \"$ownership_label\"}}" "$name" 2>/dev/null)"; then return 1; fi ;;
		network) if ! value="$(docker network inspect --format "{{index .Labels \"$ownership_label\"}}" "$name" 2>/dev/null)"; then return 1; fi ;;
		volume) if ! value="$(docker volume inspect --format "{{index .Labels \"$ownership_label\"}}" "$name" 2>/dev/null)"; then return 1; fi ;;
		*) return 1 ;;
	esac
	[[ "$value" == "$run_id" ]]
}

remove_owned() {
	local kind="$1" name="$2"
	if resource_absent "$kind" "$name"; then
		return 0
	fi
	if ! owned_label "$kind" "$name"; then
		echo "cleanup: refusing unowned $kind $name" >&2
		return 1
	fi
	case "$kind" in
		container) docker container rm --force "$name" >/dev/null 2>&1 || resource_absent container "$name" || return 1 ;;
		network) docker network rm "$name" >/dev/null 2>&1 || resource_absent network "$name" || return 1 ;;
		volume) docker volume rm "$name" >/dev/null 2>&1 || resource_absent volume "$name" || return 1 ;;
	esac
	resource_absent "$kind" "$name"
}

remove_file() {
	local path="$1"
	if [[ -e "$path" ]]; then
		rm -f -- "$path" || return 1
	fi
	[[ ! -e "$path" ]]
}

cleanup() {
	local exit_code="${1:-$?}" index
	trap - EXIT INT TERM
	for ((index=${#created_containers[@]}-1; index>=0; index--)); do
		remove_owned container "${created_containers[index]}" || cleanup_failed=1
	done
	for ((index=${#created_networks[@]}-1; index>=0; index--)); do
		remove_owned network "${created_networks[index]}" || cleanup_failed=1
	done
	for ((index=${#created_volumes[@]}-1; index>=0; index--)); do
		remove_owned volume "${created_volumes[index]}" || cleanup_failed=1
	done
	for ((index=${#created_files[@]}-1; index>=0; index--)); do
		remove_file "${created_files[index]}" || cleanup_failed=1
	done
	if [[ -e "$temp_root" ]]; then
		rmdir "$temp_root" || cleanup_failed=1
	fi
	if ((cleanup_failed)); then
		echo 'notification relay acceptance cleanup FAILED' >&2
		exit_code=1
	else
		echo 'notification relay acceptance cleanup: exact resources absent'
	fi
	exit "$exit_code"
}
trap 'cleanup "$?"' EXIT
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

if [[ "${PLAINPOST_NOTIFICATION_CLEANUP_CONTRACT_TEST:-}" == enabled ]]; then
	direct_mode_switch_log="$temp_root/direct-mode-switch.log"
	: >"$direct_mode_switch_log"
	created_files+=("$direct_mode_switch_log")
	[[ -e "$direct_mode_switch_log" ]] || { echo 'cleanup contract log was not created' >&2; exit 1; }
	exit 0
fi

credential_file() {
	local path="$1"
	[[ -f "$path" ]] && [[ "$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path")" == 600 ]]
}

create_tls_assets() {
	local ca_key="$temp_root/postgres-ca.key" ca_cert="$temp_root/postgres-ca.crt"
	local server_key="$temp_root/postgres-server.key" server_csr="$temp_root/postgres-server.csr"
	local server_cert="$temp_root/postgres-server.crt" server_ext="$temp_root/postgres-server.ext"
	local hba="$temp_root/pg_hba.conf" password="$temp_root/postgres.password"
	created_files+=("$ca_key" "$ca_cert" "$server_key" "$server_csr" "$server_cert" "$server_ext" "$hba" "$password")
	openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=Plainpost notification PG18 CA' -keyout "$ca_key" -out "$ca_cert" >/dev/null 2>&1
	openssl req -new -newkey rsa:2048 -nodes -subj '/CN=127.0.0.1' -keyout "$server_key" -out "$server_csr" >/dev/null 2>&1
	printf '%s\n' 'subjectAltName=IP:127.0.0.1' >"$server_ext"
	openssl x509 -req -days 1 -set_serial 1 -in "$server_csr" -CA "$ca_cert" -CAkey "$ca_key" -extfile "$server_ext" -out "$server_cert" >/dev/null 2>&1
	printf '%s\n' 'local all all trust' 'hostssl all all 0.0.0.0/0 scram-sha-256' 'hostssl all all ::/0 scram-sha-256' 'hostnossl all all 0.0.0.0/0 reject' 'hostnossl all all ::/0 reject' >"$hba"
	(umask 077; openssl rand -hex 32 >"$password")
	chmod 0600 "$ca_key" "$server_key" "$server_csr" "$server_ext" "$password"
	chmod 0644 "$ca_cert" "$server_cert" "$hba"
	credential_file "$password" || { echo 'notification acceptance secret is not mode=0600' >&2; return 1; }
	echo 'notification acceptance secrets: mode=0600'
}

wait_for_postgres() {
	local attempt state logs
	for attempt in $(seq 1 60); do
		state="$(docker container inspect --format '{{.State.Status}}' "$container" 2>/dev/null || true)"
		logs="$(docker container logs --tail 80 "$container" 2>&1 || true)"
		if [[ "$state" == running && "$logs" == *'PostgreSQL init process complete; ready for start up.'* ]] && docker exec "$container" pg_isready -U postgres -d plainpost_notification >/dev/null 2>&1; then
			return 0
		fi
		((attempt < 60)) && sleep 1
	done
	echo 'PostgreSQL did not reach stable readiness' >&2
	docker container logs --tail 80 "$container" >&2 || true
	return 1
}

create_tls_assets
assert_absent_before_create network "$network"
assert_absent_before_create network "$loopback_network"
assert_absent_before_create volume "$volume"
assert_absent_before_create volume "$tls_volume"
assert_absent_before_create volume "$credentials_volume"
assert_absent_before_create container "$container"
docker network create --internal --label "$ownership_label=$run_id" "$network" >/dev/null
created_networks+=("$network")
docker network create --label "$ownership_label=$run_id" "$loopback_network" >/dev/null
created_networks+=("$loopback_network")
docker volume create --label "$ownership_label=$run_id" "$volume" >/dev/null
created_volumes+=("$volume")
docker volume create --label "$ownership_label=$run_id" "$tls_volume" >/dev/null
created_volumes+=("$tls_volume")
docker volume create --label "$ownership_label=$run_id" "$credentials_volume" >/dev/null
created_volumes+=("$credentials_volume")

docker run --rm --entrypoint sh --mount "type=volume,source=$tls_volume,destination=/run/postgres-tls" --mount "type=bind,source=$temp_root,destination=/source,readonly" "$postgres_image" -ceu 'cp /source/postgres-ca.crt /source/postgres-server.crt /source/postgres-server.key /source/pg_hba.conf /run/postgres-tls/ && chmod 0644 /run/postgres-tls/postgres-ca.crt /run/postgres-tls/postgres-server.crt /run/postgres-tls/pg_hba.conf && chmod 0600 /run/postgres-tls/postgres-server.key && chown "$(id -u postgres):$(id -g postgres)" /run/postgres-tls/postgres-server.key'
docker run --rm --entrypoint sh --mount "type=volume,source=$credentials_volume,destination=/run/credentials" --mount "type=bind,source=$temp_root,destination=/source,readonly" "$postgres_image" -ceu 'cp /source/postgres.password /run/credentials/postgres-password && chmod 0600 /run/credentials/postgres-password && chown "$(id -u postgres):$(id -g postgres)" /run/credentials/postgres-password'
docker run --detach --name "$container" --label "$ownership_label=$run_id" --network "$loopback_network" --publish 127.0.0.1::5432 --mount "type=volume,source=$volume,destination=/var/lib/postgresql" --mount "type=volume,source=$tls_volume,destination=/run/postgres-tls,readonly" --mount "type=volume,source=$credentials_volume,destination=/run/credentials,readonly" --env POSTGRES_DB=plainpost_notification --env POSTGRES_USER=postgres --env POSTGRES_PASSWORD_FILE=/run/credentials/postgres-password "$postgres_image" postgres -c ssl=on -c ssl_ca_file=/run/postgres-tls/postgres-ca.crt -c ssl_cert_file=/run/postgres-tls/postgres-server.crt -c ssl_key_file=/run/postgres-tls/postgres-server.key -c hba_file=/run/postgres-tls/pg_hba.conf >/dev/null || { owned_label container "$container" && created_containers+=("$container"); exit 1; }
created_containers+=("$container")
docker network connect "$network" "$container"
wait_for_postgres

if ! postgres_port="$(docker container inspect --format '{{(index (index .NetworkSettings.Ports "5432/tcp") 0).HostPort}}' "$container" 2>/dev/null)"; then
	echo 'PostgreSQL container port inspection failed' >&2
	exit 1
fi
[[ -n "$postgres_port" ]] || { echo 'PostgreSQL published port is unavailable' >&2; exit 1; }
export PGPASSFILE="$temp_root/postgres.pgpass"
export PGSSLROOTCERT="$temp_root/postgres-ca.crt"
(umask 077; printf '127.0.0.1:%s:plainpost_notification:postgres:%s\n' "$postgres_port" "$(<"$temp_root/postgres.password")" >"$PGPASSFILE")
created_files+=("$PGPASSFILE")
credential_file "$PGPASSFILE" || { echo 'notification acceptance PGPASSFILE is not mode=0600' >&2; exit 1; }
export PLAINPOST_REQUIRE_LIVE_POSTGRES=1
export TEST_POSTGRES_URL="postgres://postgres@127.0.0.1:${postgres_port}/plainpost_notification?sslmode=verify-full"

echo "notification relay acceptance: image=$postgres_image"
echo 'notification relay acceptance: central/node/HTTPS fake APNs pipeline'
(cd "$go_root" && go test ./internal/central/notificationrelay -run '^(TestAcceptanceNotificationPipelineUsesProductionBoundaries|TestNotificationRelayPostSendPersistenceLossUsesStableCollapseCoordinate)$' -count=1)
echo 'notification relay acceptance: authenticated registration atomic boundary'
(cd "$go_root" && go test ./internal/central/notificationrelay -run '^(TestAuthenticatedRegistrationUsesAtomicPostgresBoundaryWhenAvailable|TestAuthenticatedRegistrationUsesAtomicAssertionBoundaryWhenAvailable|TestAuthenticatedRegistrationAtomicAssertionFailureDoesNotConsumeLegacyState|TestRegistrationClientDataBindsCompleteAPNsRequest)$' -count=1)
echo 'notification relay acceptance: App Attest parser strictness'
(cd "$go_root" && go test ./internal/central/notificationrelay -run '^TestAppleAttestationValidatesCertificateNonceAndCredentialKey$' -count=1)
echo 'notification relay acceptance: PostgreSQL 18 metadata/rate/cleanup durability'
(cd "$go_root" && go test ./internal/central/postgres -run '^(TestLiveNotificationRelayQueueClaimsAndFencesMetadata|TestLiveNotificationRelayRateBoundary|TestLiveNotificationRelayCleanupControllerRemovesExpiredRowsAndStops|TestLiveNotificationEntitlementRenewalRotatesOnlyActiveUnexpiredNearExpiryRows|TestLiveProducerAssignmentTransactionalMatrix|TestLiveDirectProducerModeSwitchMacSyncNodeMacAuthoritativeReload|TestLiveDirectNotificationPolicyTransactionalMatrix|TestDirectNotificationPolicyMigrationIsEmbeddedAtCurrentHead|TestProducerAssignmentLockKeyLiveAcceptsOpaqueBytes|TestAppleAttestKeyIDMustBeCanonicalCredentialID|TestNotificationAppAttestMigrationPersistsOnlyBoundedVerifierState|TestAccountLifecycleRepositoryLiveDeletesAuthorityAndPersistsCleanupAtomically)$' -count=1)
(cd "$go_root" && go test ./internal/central/postgres -run '^TestLiveDirectNotificationPolicyTransactionalMatrix$' -count=1)
printf 'stage=notification-direct-policy scenario=mac-owner-scoped-read outcome=pass\n'
command -v swift >/dev/null 2>&1 || { echo 'Swift is required for notification Direct selector acceptance' >&2; exit 1; }
direct_mode_switch_log="$temp_root/direct-mode-switch.log"
: >"$direct_mode_switch_log"
created_files+=("$direct_mode_switch_log")
if ! "$repo_root/Scripts/swift-test-isolated.sh" --package-path "$repo_root" \
  --filter NotificationRuntimeTests/testProductionAuthenticatedProducerSelectorSwitchesMacSyncNodeMacWithAuthoritativeReload \
  >"$direct_mode_switch_log" 2>&1; then
  echo 'notification Direct mode-switch selector failed' >&2
  exit 1
fi
printf 'stage=notification-direct-policy scenario=mode-switch-authoritative-reload outcome=pass\n'
echo 'notification relay acceptance: PostgreSQL 18 revoked-recipient fencing'
(cd "$go_root" && go test ./internal/node/postgres -run '^TestLiveNotificationRecipientsFilterRevokedDoesNotBlockCurrent$' -count=1)
echo 'notification relay acceptance: PostgreSQL 18 persisted Node/Central/APNs restart fence'
(cd "$go_root" && go test ./internal/node/postgres -run '^TestLivePostgreSQLNotificationPipelineSurvivesNodeReopen$' -count=1)
echo 'notification relay acceptance: Central runtime handler assembly'
(cd "$go_root" && go test ./cmd/plainpost-api -run '^TestNotificationRuntimeRequiresAuthenticatedRelayAccess$' -count=1)
echo 'notification relay acceptance PASS'
