#!/usr/bin/env bash
set -euo pipefail

root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
owner="$root/Scripts/test-notification-relay-e2e.sh"

test -x "$owner"

grep -Eq '^repo_root="\$\(CDPATH='"'"''"'"' cd -- "\$\(dirname -- "\$\{BASH_SOURCE\[0\]\}"\)/\.\." && pwd\)"$' "$owner"
grep -Eq '^readonly repo_root$' "$owner"

grep -Fq 'postgres:18.6-alpine3.24@sha256:d3e1620b530c944afa6e887d22eb899824da68e19c52024bf98f5220c88a65b2' "$owner"
grep -Fq 'docker info' "$owner"
grep -Fq 'sslmode=verify-full' "$owner"
grep -Fq 'export PGPASSFILE=' "$owner"
grep -Fq 'export PGSSLROOTCERT=' "$owner"
grep -Fq 'credential_file "$PGPASSFILE"' "$owner"
grep -Fq 'TestLiveProducerAssignmentTransactionalMatrix' "$owner"
grep -Fq 'TestLiveDirectNotificationPolicyTransactionalMatrix' "$owner"
grep -Fq 'TestLiveDirectProducerModeSwitchMacSyncNodeMacAuthoritativeReload' "$owner"
grep -Fq 'TestDirectNotificationPolicyMigrationIsEmbeddedAtCurrentHead' "$owner"
grep -Fq 'PLAINPOST_NOTIFICATION_DIRECT_POLICY_CONTRACT_TEST' "$owner"
grep -Fq 'testDirectPolicyClientReadsVersionZeroRichDefaultAndOpaqueMailboxSnapshot' "$owner"
grep -Fq 'testDirectMailboxReadPreservesAbsentTombstoneAndActiveScopePredecessors' "$owner"
grep -Fq 'testDirectPolicySequencePreservesEffectiveVersionAndIndependentScopeHighWater' "$owner"
grep -Fq 'testOffDurableConfigurationSuppressesPublicationAndStaleCannotRestore' "$owner"
grep -Fq 'testDirectRegistrationMaterializesAbsentRichDefaultBeforeClaimingRegistered' "$owner"
grep -Fq 'testAssignmentPolicyRemoteDirectDefaultRequiresCurrentMacAuthority' "$owner"
grep -Fq 'testProductionCompositionReopensDirectPolicyAndPreservesOffEligibility' "$owner"
grep -Fq 'testProductionAuthenticatedProducerSelectorSwitchesMacSyncNodeMacWithAuthoritativeReload' "$owner"
grep -Fq 'created_files+=("$direct_mode_switch_log")' "$owner"
if ! awk '/export TEST_POSTGRES_URL=/{normal=1} normal && /direct_mode_switch_log=.*direct-mode-switch\.log/{created=NR} normal && /created_files\+=\("\$direct_mode_switch_log"\)/{registered=NR} normal && /--filter NotificationRuntimeTests\/testProductionAuthenticatedProducerSelectorSwitchesMacSyncNodeMacWithAuthoritativeReload/{tested=NR} END{exit !(created && registered && tested && created < registered && registered < tested)}' "$owner"; then
	printf '%s\n' 'notification relay owner registers the Direct mode-switch log too late for exact cleanup' >&2
	exit 1
fi
grep -Fq 'default-materialization' "$owner"
grep -Fq 'mode-switch-authoritative-reload' "$owner"
grep -Fq "printf 'stage=notification-direct-policy scenario=%s outcome=pass" "$owner"
grep -Fq '0031_direct_notification_policies.sql' "$root/Services/PlainpostGo/internal/central/postgres/migrate_test.go"
grep -Fq '0027_capture_optional_address_search_path.sql' "$root/Services/PlainpostGo/internal/node/config/unraid_release_contract_test.go"
grep -Fq 'PLAINPOST_REQUIRE_LIVE_POSTGRES=1' "$owner"
grep -Fq 'trap' "$owner"
grep -Fq 'docker container rm --force' "$owner"
grep -Fq 'docker volume rm' "$owner"
grep -Fq 'docker network rm' "$owner"
grep -Fq 'loopback_network' "$owner"
grep -Fq 'docker network connect "$network" "$container"' "$owner"
grep -Fq 'mode=0600' "$owner"
grep -Fq 'TestAcceptanceNotificationPipelineUsesProductionBoundaries' "$owner"
grep -Fq 'TestNotificationRelayPostSendPersistenceLossUsesStableCollapseCoordinate' "$owner"
grep -Fq 'TestAuthenticatedRegistrationUsesAtomicPostgresBoundaryWhenAvailable' "$owner"
grep -Fq 'TestAuthenticatedRegistrationUsesAtomicAssertionBoundaryWhenAvailable' "$owner"
grep -Fq 'TestAuthenticatedRegistrationAtomicAssertionFailureDoesNotConsumeLegacyState' "$owner"
grep -Fq 'TestAppleAttestationValidatesCertificateNonceAndCredentialKey' "$owner"
grep -Fq 'TestLiveNotificationRelayQueueClaimsAndFencesMetadata' "$owner"
grep -Fq 'TestLiveNotificationEntitlementRenewalRotatesOnlyActiveUnexpiredNearExpiryRows' "$owner"
grep -Fq 'TestLiveNotificationRecipientsFilterRevokedDoesNotBlockCurrent' "$owner"
grep -Fq 'TestLivePostgreSQLNotificationPipelineSurvivesNodeReopen' "$owner"
grep -Fq "TestNotificationRuntimeRequiresAuthenticatedRelayAccess" "$owner"
grep -Fq "func TestNotificationRuntimeRequiresAuthenticatedRelayAccess" "$root/Services/PlainpostGo/cmd/plainpost-api/notification_runtime_test.go"
grep -Fq 'RegisterAttestedDeviceAndRoute' "$root/Services/PlainpostGo/internal/central/notificationrelay/authenticated_registration.go"
grep -Fq 'VerifyAssertionAndRoute' "$root/Services/PlainpostGo/internal/central/notificationrelay/authenticated_registration.go"
grep -Fq 'RevokeRegistration' "$root/Services/PlainpostGo/internal/central/notificationrelay/authenticated_registration.go"
grep -Fq 'apns-collapse-id' "$root/Services/PlainpostGo/internal/central/notificationrelay/apns.go"
grep -Fq 'BeginDispatch' "$root/Services/PlainpostGo/internal/central/notificationrelay/service.go"
grep -Fq 'dispatch_started_at' "$root/Services/PlainpostGo/internal/central/postgres/migrations/accounts/0026_notification_relay_metadata.sql"

if grep -Eq 'TEST_POSTGRES_URL=.*\$\{?postgres_password|postgres://[^/@:]+:[^/@]+@' "$owner"; then
	printf '%s\n' 'notification relay owner exposes PostgreSQL password in environment' >&2
	exit 1
fi

if grep -Eq 'PlainpostCloudKitContainerIdentifier|com\.apple\.developer\.icloud-(container-identifiers|services)' \
    "$root/Apps/PlainpostiOS/Config/Info.plist" \
    "$root/Apps/PlainpostiOS/Config/Plainpost.entitlements"; then
	printf '%s\n' 'notification relay clean break still ships CloudKit wake configuration' >&2
	exit 1
fi

if grep -RqE 'CloudKitWake|WakeSignal(Publishing|Subscribing)|processPendingWake|wakePublisher|enqueueWakeOutbox' \
    "$root/Sources"; then
	printf '%s\n' 'notification relay clean break still contains dual-path wake production code' >&2
	exit 1
fi

if grep -Eq '(^|[[:space:]])(t\.Skip|Skipf|docker compose run.*--no-)' "$owner"; then
	printf '%s\n' 'notification relay owner contains an unavailable-environment skip' >&2
	exit 1
fi

direct_policy_contract_output="${TMPDIR:-/tmp}/plainpost-notification-direct-policy-contract.$$.log"
trap 'find "$direct_policy_contract_output" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
if ! PLAINPOST_NOTIFICATION_DIRECT_POLICY_CONTRACT_TEST=enabled "$owner" >"$direct_policy_contract_output" 2>&1; then
	printf '%s\n' 'notification relay Direct policy acceptance contract did not execute' >&2
	exit 1
fi

cleanup_contract_run_id="contract-$$"
cleanup_contract_root="/private/tmp/plainpost-notification-e2e.$cleanup_contract_run_id"
cleanup_contract_output="${TMPDIR:-/tmp}/plainpost-notification-cleanup-contract.$$.log"
if ! PLAINPOST_NOTIFICATION_CLEANUP_CONTRACT_TEST=enabled PLAINPOST_NOTIFICATION_E2E_RUN_ID="$cleanup_contract_run_id" "$owner" >"$cleanup_contract_output" 2>&1; then
	printf '%s\n' 'notification relay owner cleanup contract did not execute' >&2
	exit 1
fi
grep -Fxq 'notification relay acceptance cleanup: exact resources absent' "$cleanup_contract_output"
if [[ -e "$cleanup_contract_root" || -e "$cleanup_contract_root/direct-mode-switch.log" ]]; then
	printf '%s\n' 'notification relay owner cleanup leaked the Direct mode-switch log or temp root' >&2
	exit 1
fi
find "$cleanup_contract_output" -depth -delete 2>/dev/null || true
grep -Fxq 'stage=notification-direct-policy scenario=default-materialization outcome=pass' "$direct_policy_contract_output"
grep -Fxq 'stage=notification-direct-policy scenario=mailbox-override-clear-tombstone outcome=pass' "$direct_policy_contract_output"
grep -Fxq 'stage=notification-direct-policy scenario=mailbox-override-update-clear outcome=pass' "$direct_policy_contract_output"
grep -Fxq 'stage=notification-direct-policy scenario=off-fail-closed-stale-rich outcome=pass' "$direct_policy_contract_output"
grep -Fxq 'stage=notification-direct-policy scenario=mac-owner-scoped-read-contract-rejection outcome=pass' "$direct_policy_contract_output"
if grep -Fxq 'stage=notification-direct-policy scenario=mac-owner-scoped-read outcome=pass' "$direct_policy_contract_output"; then
	printf '%s\n' 'contract-only notification owner overclaimed PostgreSQL Mac owner-scoped read' >&2
	exit 1
fi
grep -Fxq 'stage=notification-direct-policy scenario=restart-off-stale-rich outcome=pass' "$direct_policy_contract_output"
grep -Fxq 'stage=notification-direct-policy scenario=mode-switch-authoritative-reload outcome=pass' "$direct_policy_contract_output"
if ! awk '/TestLiveDirectNotificationPolicyTransactionalMatrix/{seen=1} seen && /scenario=mac-owner-scoped-read outcome=pass/{found=1} END{exit(found ? 0 : 1)}' "$owner"; then
	printf '%s\n' 'notification owner emits Mac owner-scoped marker before live PostgreSQL selector' >&2
	exit 1
fi
if grep -Eq '(mailbox|request|digest|token|credential|password|secret|smtp|imap)[=_][^ ]+' "$direct_policy_contract_output"; then
	printf '%s\n' 'notification relay Direct policy contract leaked a private coordinate' >&2
	exit 1
fi

printf '%s\n' 'notification-relay-e2e-owner-contract=passed'
