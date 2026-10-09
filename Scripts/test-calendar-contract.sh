#!/usr/bin/env bash
set -euo pipefail

# Calendar contract runner: deterministic Go, native and protocol gates for the
# node-calendar-v1 contract. Every required owner runs even after an earlier
# failure; each return code is retained and the run fails if any owner fails,
# skips a test, or never executes. There is no option to skip an owner.
#
# Owners:
#   protocol  vectors are current for the schema; the Node's embedded schema copy
#             is exact.
#   go        go test -race ./internal/node/calendar/... ./internal/node/clientapi
#             ./internal/node/provider -count=1 against a task-owned disposable
#             PostgreSQL 18 container (live owners must run, never skip).
#   swift     swift test --filter 'NodeCalendar|CalendarWeek|CalendarEventEditor|
#             ThreadInvitation|CalendarOAuth|CalendarSettings|CalendarAcceptance'
#   parity    the Go and native codecs emit identical accept/reject decisions
#             and canonical-byte digests for every shared vector.
#   assembly  go test -race for the config and Node assembly owners and the live
#             setup/reconnect/reconcile owners outside the go packages.
#   pg18      bash Scripts/test-postgresql-18-live-matrix.sh --focused
#
# Required test owners are listed below; later tasks extend these arrays.

readonly postgres_image="postgres:18.6-alpine3.24@sha256:d3e1620b530c944afa6e887d22eb899824da68e19c52024bf98f5220c88a65b2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly go_root="$repo_root/Services/PlainpostGo"
readonly swift_filter='NodeCalendar|CalendarWeek|CalendarEventEditor|ThreadInvitation|CalendarOAuth|CalendarSettings|CalendarAcceptance'

required_go_tests=(
	TestCalendarContractVectors
	TestCalendarContractRouteBodies
	TestCalendarEmbeddedSchemaMatchesProtocol
	TestCalendarSharedVectors
	TestCalendarCodecRejectsUnsafeCountersAndClosedStates
	TestCalendarHTTPRoutes
	TestCalendarHTTPRejectsWrongMethodDuplicateAndSizeLimits
	TestCalendarCapabilityEnabledExactlyWhenEveryOwnerIsAssembled
	TestCalendarAssembledRuntimeAdmitsCommandsSetupAndInvitations
	TestCalendarUnassembledRuntimeRejectsNewCommandsAndKeepsReceiptReads
	TestCalendarLiveHardWorkerStopKeepsUncertainWorkAndNeverResends
	TestCalendarConnectionsFitClosedCollectionSchema
	TestCalendarInvitationReadAtDisplayBoundsFitsResponseCeiling
	TestCalendarLiveResponseDurableAPIAndRestart
	TestInvitationDetailsSelectOwnOccurrenceAndBoundLinks
	TestCalendarConnectionsOmitTerminalRowsBeyondBound
	TestCalendarSetupOverCalendarBoundFailsWithCalendarLimit
	TestCalendarLiveCatalogStaysWithinBoundsAfterSetupHistory
	TestCalendarSetupBoundsPrecedePreparedJournal
	TestCalendarLiveSetupCatalogLimitsWithRealisticCollections
	TestCalendarAddressSetAcceptsPrincipalURIAndSelectsUsableMailto
	TestHTTPClientWithTLSRootsKeepsAddressPolicyAndVerification
	TestCalendarNetworkZeroValueKeepsPublicOnlyCalDAVPolicy
	TestSMTPSubmissionOutcomeMapsEveryResultAndError
	TestCalendarLiveInvitationStaysActionableAcrossReconcilerLifetime
	TestCalendarLiveUnprojectableResourcesAreIsolated
	TestCalendarEditRefusesTextFittedForDisplay
	TestConsolidateProjectionIsolatesConflictingExceptions
	TestCalendarLiveSeriesInvitationOutsideBrowsedWeeksUpdatesExistingCopy
	TestCalendarLiveOccurrenceInvitationAcrossTimezonesUpdatesExistingSeries
	TestCalendarLiveAmbiguousInvitationNeverCreatesCopy
	TestCalendarLiveUpdatedInvitationRespondsToExistingCopy
	TestCalendarLiveGoogleOccurrenceInvitationRespondsToInstance
	TestCalendarLiveUnseenInvitationRequiresValidTargetCalendar
	TestCalendarLiveInvitationDiscoveryRunsOncePerMessageAndRequiresAssembly
	TestCalendarLiveInvitationReadGroupsSeriesAndBoundsLargeMessages
	TestCalendarLiveFailedSetupErasesJournalAndIsNeverAnIdentity
	TestCalendarLiveSetupDigestIsKeyed
	TestCalendarLiveFailedReconnectKeepsWorkingConnection
	TestCalendarLiveDisconnectKeepsDeliveredResponseAndPreventsResend
	TestCalendarReconcileComparesSemanticIntent
	TestEditRechecksTrustBeforeProviderWrite
	TestExchangeAndRefreshSendNodeHeldClientSecret
	TestLoopbackRedirectURIValidation
	TestOAuthConfigConfiguredRequiresClientAndReadableSecret
	TestExchangeUsesConfiguredClientLoopbackRedirectPKCEAndAuthenticatedPrimary
	TestCalendarCapabilitiesAdvertiseGoogleClientOnlyWhenConfigured
	TestCalendarSetupCommandRequiresLoopbackRedirect
	TestCalendarGoogleSetupAdmissionRequiresConfiguredClient
	TestCalendarLiveWindowKeepsEventSourceTimezone
	TestProjectionKeepsGoogleSourceTimezone
	TestGoogleAllDayRecurrenceIdentityIsCanonical
	TestProjectionAndInvitationKeepFloatingTimesFloating
	TestTimeEditInUnchangedZonePreservesTZIDAndVTimezone
	TestTimeEditChangingZoneEmitsMatchingVTimezone
	TestEditWritesOnlyChangedTextFields
	TestRefreshIfStaleCoalescesRepeatedWindowRefreshes
	TestReadLooksUpHiddenResourcesOncePerCollection
	TestCalendarLiveWindowHonorsRefreshAndCoalesces
	TestCalendarWindowCursorSurvivesMetadataAndRestartsChangedSnapshot
	TestCalendarTimeZoneNamesAreCanonicalCase
	TestCalendarLiveDisconnectSettlesRetainedResponses
	TestCalendarLiveUnknownExistenceNeverCreatesSecondCopy
	TestCalendarLiveIndexReadinessIgnoresUnsyncableCollections
	TestCalendarLiveGoogleFreeBusyCalendarDoesNotBlockResolution
)
# Owners outside the go owner's packages: config and Node assembly, and live
# repository/config owners of the fix round.
required_assembly_tests=(
	TestCalendarConfigIgnoresRetiredSwitchVariable
	TestNodeClientAPIAssemblyAssemblesEveryCalendarOwner
	TestCalendarOAuthClientSecretIsMountedAndPairedWithClient
	TestCalendarConfigIgnoresRetiredRedirectVariable
	TestCalendarLiveReconcileBudgetIndependentOfPendingRetries
	TestCalendarLiveReconnectSettlesOldGenerationWork
	TestRawResourceUIDsReadUndecodableResources
	TestRawResourceUIDsHandleLongLinesAndCap
	TestCalendarLiveUIDIndexCompletenessMigrationResetsCheckpoints
)
required_swift_suites=(
	NodeCalendarContractVectorTests
	NodeCalendarVectorTests
	NodeCalendarClientTests
	NodeCalendarSignedTransportTests
	CalendarWeekViewModelTests
	CalendarWeekLayoutTests
	CalendarEventEditorTests
	ThreadInvitationViewModelTests
	ThreadInvitationPresentationTests
	CalendarOAuthSessionTests
	CalendarSettingsGoogleAvailabilityTests
	CalendarAcceptanceTests
)

run_id="$(printf '%s-%s' "$$" "$(date +%s)")"
readonly run_id
readonly temp_root="/private/tmp/plainpost-calendar-contract.$run_id"
readonly container="plainpost-calendar-contract-pg-$run_id"
mkdir "$temp_root"
chmod 0700 "$temp_root"
container_created=0

cleanup() {
	local status="$?"
	trap - EXIT INT TERM
	if ((container_created)); then
		if ! docker container rm --force "$container" >/dev/null 2>&1; then
			echo "cleanup: could not remove contract PostgreSQL container $container" >&2
			status=1
		fi
		if docker container inspect "$container" >/dev/null 2>&1; then
			echo "cleanup: contract PostgreSQL container remains: $container" >&2
			status=1
		fi
	fi
	if [[ -e "$temp_root" ]]; then
		if ! rm -rf "$temp_root" || [[ -e "$temp_root" ]]; then
			echo "cleanup: contract temp root remains: $temp_root" >&2
			status=1
		fi
	fi
	exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

declare -a owner_names=()
declare -a owner_codes=()
record() {
	owner_names+=("$1")
	owner_codes+=("$2")
	if (($2 == 0)); then
		echo "calendar contract owner PASS: $1"
	else
		echo "calendar contract owner FAIL($2): $1" >&2
	fi
}

protocol_owner() {
	python3 "$repo_root/Scripts/generate-calendar-contract-vectors.py" --check || return 1
	if ! cmp -s "$repo_root/Protocol/node-calendar-v1/node-calendar.schema.json" "$go_root/internal/node/clientapi/calendar_schema.json"; then
		echo "Go embedded schema differs from Protocol/node-calendar-v1/node-calendar.schema.json" >&2
		return 1
	fi
}

start_postgres() {
	docker image inspect "$postgres_image" >/dev/null || {
		echo "pinned PostgreSQL 18 image is not present locally; this runner never pulls images" >&2
		return 1
	}
	local password attempt port logs
	password="$(openssl rand -hex 24)"
	docker run --detach --name "$container" --publish 127.0.0.1::5432 \
		--env POSTGRES_PASSWORD="$password" --env POSTGRES_DB=calendar_contract \
		"$postgres_image" >/dev/null || return 1
	container_created=1
	for attempt in $(seq 1 60); do
		logs="$(docker container logs --tail 40 "$container" 2>&1)" || logs=""
		if [[ "$logs" == *"PostgreSQL init process complete; ready for start up."* ]] &&
			docker exec "$container" pg_isready -U postgres -d calendar_contract >/dev/null 2>&1; then
			port="$(docker port "$container" 5432/tcp | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | head -n 1)"
			[[ -n "$port" ]] || return 1
			printf 'postgres://postgres:%s@127.0.0.1:%s/calendar_contract?sslmode=disable' "$password" "$port" >"$temp_root/postgres-url"
			return 0
		fi
		sleep 1
	done
	echo "contract PostgreSQL 18 did not become ready" >&2
	return 1
}

go_owner() {
	start_postgres || return 1
	local output="$temp_root/go-test.log" status=0 name
	(
		cd "$go_root"
		env TEST_POSTGRES_URL="$(<"$temp_root/postgres-url")" PLAINPOST_REQUIRE_LIVE_POSTGRES=1 \
			PLAINPOST_CALENDAR_VECTOR_OUTPUT="$temp_root/go-vectors.txt" \
			go test -race ./internal/node/calendar/... ./internal/node/clientapi ./internal/node/provider -count=1 -v
	) >"$output" 2>&1 || status=$?
	sed -nE '/^(ok|FAIL|panic:)/p' "$output"
	if ((status)); then
		sed -nE '/^(---|[[:space:]]+[a-z_]+_test\.go:[0-9]+:)/p' "$output" | grep -v -- '--- PASS' | head -n 80 >&2
		echo "go owner exited $status" >&2
		return "$status"
	fi
	if grep -Eq -- '--- SKIP:|\[no test files\]|no tests to run' "$output"; then
		grep -E -- '--- SKIP:|\[no test files\]|no tests to run' "$output" >&2
		echo "go owner skipped a test or ran a package without tests" >&2
		return 1
	fi
	for name in "${required_go_tests[@]}"; do
		if ! grep -Eq -- "^--- PASS: ${name} \\(" "$output"; then
			echo "required Go test did not execute: $name" >&2
			return 1
		fi
	done
	[[ -s "$temp_root/go-vectors.txt" ]] || { echo "Go vector report was not written" >&2; return 1; }
	assembly_tests || return 1
}

# assembly_tests runs the required owners outside the go packages above against
# the same task-owned PostgreSQL 18.
assembly_tests() {
	local output="$temp_root/go-assembly.log" status=0 name pattern
	pattern="^($(IFS='|'; echo "${required_assembly_tests[*]}"))\$"
	(
		cd "$go_root"
		env TEST_POSTGRES_URL="$(<"$temp_root/postgres-url")" PLAINPOST_REQUIRE_LIVE_POSTGRES=1 \
			go test -race ./internal/node/config ./internal/node/postgres ./cmd/plainpost-sync-node -run "$pattern" -count=1 -v
	) >"$output" 2>&1 || status=$?
	sed -nE '/^(ok|FAIL|panic:)/p' "$output"
	if ((status)); then
		sed -nE '/^(---|[[:space:]]+[a-z_]+_test\.go:[0-9]+:)/p' "$output" | grep -v -- '--- PASS' | head -n 80 >&2
		echo "assembly owners exited $status" >&2
		return "$status"
	fi
	if grep -Eq -- '--- SKIP:|no tests to run' "$output"; then
		grep -E -- '--- SKIP:|no tests to run' "$output" >&2
		echo "assembly owners skipped a test" >&2
		return 1
	fi
	for name in "${required_assembly_tests[@]}"; do
		if ! grep -Eq -- "^--- PASS: ${name} \\(" "$output"; then
			echo "required assembly test did not execute: $name" >&2
			return 1
		fi
	done
}

swift_owner() {
	local output="$temp_root/swift-test.log" status=0 suite
	(
		cd "$repo_root"
		env PLAINPOST_CALENDAR_VECTOR_OUTPUT="$temp_root/swift-vectors.txt" "$repo_root/Scripts/swift-test-isolated.sh" --filter "$swift_filter"
	) >"$output" 2>&1 || status=$?
	sed -nE "/Executed [0-9]+ tests|error: |failed -/p" "$output" | tail -n 20
	if ((status)); then
		echo "swift owner exited $status" >&2
		return "$status"
	fi
	if grep -Eq "' skipped|tests? skipped|\) skipped|skipped\.$" "$output"; then
		grep -E "' skipped|tests? skipped|\) skipped|skipped\.$" "$output" >&2
		echo "swift owner skipped a test" >&2
		return 1
	fi
	local missing=0
	for suite in "${required_swift_suites[@]}"; do
		if ! grep -Fq "Test Suite '${suite}' passed" "$output"; then
			echo "required Swift test suite did not execute: $suite (absent from the package or filtered out)" >&2
			missing=1
		fi
	done
	if ((missing)); then
		return 1
	fi
	[[ -s "$temp_root/swift-vectors.txt" ]] || { echo "native vector report was not written" >&2; return 1; }
}

parity_owner() {
	local expected
	expected="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["cases"]))' "$repo_root/Protocol/node-calendar-v1/fixtures/protocol-v1.json")" || return 1
	local report
	for report in go-vectors.txt swift-vectors.txt; do
		if [[ ! -s "$temp_root/$report" ]]; then
			echo "missing vector report: $report" >&2
			return 1
		fi
		if [[ "$(wc -l <"$temp_root/$report" | tr -d ' ')" != "$expected" ]]; then
			echo "vector report $report does not cover all $expected cases" >&2
			return 1
		fi
	done
	if ! cmp -s "$temp_root/go-vectors.txt" "$temp_root/swift-vectors.txt"; then
		echo "Go and native codecs disagree on accept/reject or canonical bytes:" >&2
		local diff_status=0
		diff "$temp_root/go-vectors.txt" "$temp_root/swift-vectors.txt" >"$temp_root/parity.diff" || diff_status=$?
		head -n 40 "$temp_root/parity.diff" >&2
		echo "diff exited $diff_status" >&2
		return 1
	fi
	echo "Go and native codecs agree on $expected vectors (decisions and canonical digests)"
}

pg18_owner() {
	bash "$repo_root/Scripts/test-postgresql-18-live-matrix.sh" --focused
}

for owner in protocol go swift parity pg18; do
	echo "calendar contract owner: $owner"
	if "${owner}_owner"; then
		record "$owner" 0
	else
		record "$owner" "$?"
	fi
done

failed=0
for index in "${!owner_names[@]}"; do
	printf 'calendar contract summary: %-8s rc=%s\n' "${owner_names[index]}" "${owner_codes[index]}"
	if ((owner_codes[index] != 0)); then
		failed=1
	fi
done
if ((failed)); then
	echo "calendar contract FAILED" >&2
	exit 1
fi
echo "calendar contract PASS"
