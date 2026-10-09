#!/usr/bin/env bash
# Verifies the effective Keychain access groups of a signed, packaged
# PlainpostService helper.
#
# The service reads the account session, device identity, trust state and
# Sync Node endpoint records from the AccountShared group the app writes, and
# its group-less MacVaultKeyProvider query must still find the vault key in
# the SERVICE_VAULT_GROUP recorded by the Task 1 signing spike. Both groups
# must be in the helper's signed entitlements.
#
# Usage: Scripts/test-service-keychain-group-contract.sh [path/to/Plainpost.app]
# The bundle defaults to $PLAINPOST_APP_BUNDLE_OUTPUT.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
account_shared_group="9XN7WN8JN2.com.marynavdovenko.Plainpost.AccountShared"
spike_record="${PLAINPOST_SERVICE_KEYCHAIN_SPIKE_RECORD:-$root_dir/docs/verification/2026-09-14-service-keychain-signing-spike.md}"
codesign_command="${PLAINPOST_SERVICE_KEYCHAIN_CONTRACT_CODESIGN_COMMAND:-/usr/bin/codesign}"
bundle="${1:-${PLAINPOST_APP_BUNDLE_OUTPUT:-}}"

if [[ -z "$bundle" ]]; then
    echo "usage: $0 <signed Plainpost.app> (or set PLAINPOST_APP_BUNDLE_OUTPUT)" >&2
    exit 64
fi
helper="$bundle/Contents/Library/Helpers/PlainpostService.app"
if [[ ! -d "$helper" ]]; then
    echo "Missing packaged service helper: $helper" >&2
    exit 66
fi

vault_group=""
if [[ -f "$spike_record" ]]; then
    vault_group="$(/usr/bin/sed -n 's/^SERVICE_VAULT_GROUP=\([^[:space:]]*\)[[:space:]]*$/\1/p' "$spike_record" | /usr/bin/head -n 1)"
fi

temporary_directory="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/plainpost-service-keychain-contract.XXXXXX")"
trap '/bin/rm -rf "$temporary_directory"' EXIT
entitlements="$temporary_directory/entitlements.plist"
groups="$temporary_directory/groups.json"

status=0
if ! "$codesign_command" -d --entitlements :- "$helper" >"$entitlements" 2>/dev/null ||
    ! /usr/bin/plutil -extract keychain-access-groups json -o "$groups" "$entitlements" >/dev/null 2>&1; then
    echo "check=account_shared outcome=unreadable_entitlements"
    echo "check=service_vault_group outcome=unreadable_entitlements"
    exit 1
fi

contains_group() {
    /usr/bin/grep -Fq "\"$1\"" "$groups"
}

if contains_group "$account_shared_group"; then
    echo "check=account_shared outcome=pass group=$account_shared_group"
else
    echo "check=account_shared outcome=missing group=$account_shared_group"
    status=1
fi

if [[ -z "$vault_group" ]]; then
    echo "check=service_vault_group outcome=missing_record record=$spike_record"
    status=1
elif [[ "${vault_group%%.*}" != "${account_shared_group%%.*}" ]]; then
    # The recorded group belongs to another signing team: the spike must be
    # re-run under the current team before this check can pass.
    echo "check=service_vault_group outcome=stale_record group=$vault_group team=${account_shared_group%%.*}"
    status=1
elif contains_group "$vault_group"; then
    echo "check=service_vault_group outcome=pass group=$vault_group"
else
    echo "check=service_vault_group outcome=missing group=$vault_group"
    status=1
fi

exit "$status"
