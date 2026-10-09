#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_directory/.." && pwd)"
artifact_directory="$root/.build/verification/macos-new-mail-notifications"
mkdir -p "$artifact_directory"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
log_path="$artifact_directory/$timestamp.log"
metadata_path="$artifact_directory/$timestamp.meta.txt"
source_sha="$(git -C "$root" rev-parse HEAD)"
dirty_files="$(git -C "$root" status --short)"

{
    printf 'source_sha=%s\n' "$source_sha"
    printf 'working_directory=%s\n' "$root"
    printf 'dirty_files_begin\n%s\ndirty_files_end\n' "$dirty_files"
    printf 'log_path=%s\n' "$log_path"
} >"$metadata_path"

filter='IMAPHarnessTests.testServiceOwnedIdleSignalImportsAndDeliversNewMailWithoutFallbackDelay|IMAPSyncCacheTests.testIncrementalInboxSyncPersistsMacNotificationEventWithoutRemoteProducerSelection|MailRuleProcessorTests.testPureNotificationPolicyFindsSuppressionWithoutApplyingRuleActions|MacNewMailDeliveryTests|MacNewMailNotificationStoreTests'

set +e
(cd "$root" && "$root/Scripts/swift-test-isolated.sh" --filter "$filter") 2>&1 | tee "$log_path"
test_status=${PIPESTATUS[0]}
set -e

assertions=(
    'testServiceOwnedIdleSignalImportsAndDeliversNewMailWithoutFallbackDelay'
    'testIncrementalInboxSyncPersistsMacNotificationEventWithoutRemoteProducerSelection'
    'testPureNotificationPolicyFindsSuppressionWithoutApplyingRuleActions'
    'testSixMessagesRenderOneSummaryWithOpaqueAccountInboxToken'
    'testTwoDeliveryActorsRaceButOnlyOneAddsTheRequest'
    'testStartupRecoveryTerminalizesAmbiguousSubmissionWithoutCallingSystemCenter'
    'testExpiredAndFailedRuleResolutionFailClosed'
)

assertion_status=0
for assertion in "${assertions[@]}"; do
    if grep -F "$assertion]' passed" "$log_path" >/dev/null; then
        printf 'assertion=%s status=passed\n' "$assertion" | tee -a "$metadata_path"
    else
        printf 'assertion=%s status=missing\n' "$assertion" | tee -a "$metadata_path" >&2
        assertion_status=1
    fi
done

printf 'swift_test_exit_code=%s\n' "$test_status" | tee -a "$metadata_path"
printf 'assertion_exit_code=%s\n' "$assertion_status" | tee -a "$metadata_path"
printf 'log_path=%s\n' "$log_path"
printf 'metadata_path=%s\n' "$metadata_path"

if (( test_status != 0 || assertion_status != 0 )); then
    exit 1
fi
