#!/bin/zsh
set -euo pipefail

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
detector="$repo_root/Scripts/plainpost/report-real-keychain-test-uses.sh"

mkdir -p \
  "$fixture/Tests/Ordinary" \
  "$fixture/Tests/PlainpostSecurityAcceptanceTests" \
  "$fixture/Apps/PlainpostiOS/PlainpostTests"

printf '%s\n' 'SecItemAdd([:] as CFDictionary, nil)
SecKeychainCreate("/tmp/example", 0, nil, false, nil, nil)
SecItemAdd
(
    [:] as CFDictionary,
    nil
)
SecKeychainCreate
(
    "/tmp/multiline",
    0,
    nil,
    false,
    nil,
    nil
)
_ = KeychainCredentialStore(service: "test")
_ = DeviceTransportKeychainStore(service: "test")
_ = DeviceTLSCredentialStore(service: "test")
_ = MacVaultKeyProvider()
_ = MobileVaultKeyProvider()
_ = KeychainAccountSecretStore()
_ = KeychainCredentialStore
(
    service: "multiline"
)
_ = DeviceTransportKeychainStore
    .init(service: "explicit-init")
let contextualStore: DeviceTLSCredentialStore =
    .init(service: "contextual-init")
let interpolated = "\(MacVaultKeyProvider()) \(SecItemDelete([:] as CFDictionary))"
_ = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil)
_ = SecItemOperationRecorder()' >"$fixture/Tests/Ordinary/Leak.swift"

printf '%s\n' 'let documentation = "MacVaultKeyProvider()"
// MobileVaultKeyProvider()
/* KeychainCredentialStore.init(service: "comment") */
let directCallDocumentation = "SecItemAdd([:] as CFDictionary, nil)"
// SecKeychainCreate("/tmp/comment", 0, nil, false, nil, nil)
/* SecItemDelete([:] as CFDictionary) */' \
  >"$fixture/Tests/Ordinary/Safe.swift"

printf '%s\n' 'let mac = MacVaultKeyProvider.injecting(macOperations)
let mobile = MobileVaultKeyProvider.injecting(mobileOperations)' \
  >"$fixture/Tests/Ordinary/InjectedAdapters.swift"

printf '%s\n' 'SecItemAdd([:] as CFDictionary, nil)
SecKeychainCreate("/tmp/formerly-allowed", 0, nil, false, nil, nil)
_ = KeychainCredentialStore(service: "formerly-allowed")' \
  >"$fixture/Tests/PlainpostSecurityAcceptanceTests/Allowed.swift"

printf '%s\n' 'SecItemAdd([:] as CFDictionary, nil)' \
  >"$fixture/Apps/PlainpostiOS/PlainpostTests/MobileLeak.swift"

if "$detector" --root "$fixture" --strict; then
  printf '%s\n' "strict detector accepted real-Keychain test uses" >&2
  exit 1
fi

"$detector" --root "$fixture" --report >"$fixture/report.stdout"
report="$fixture/.build/plainpost-migration/keychain-test-use-report.txt"

test -s "$report"
cmp -s "$fixture/report.stdout" "$report"
grep -qx 'finding_count=20' "$report"
grep -qx 'category.direct_secitem=5' "$report"
grep -qx 'category.direct_seckeychain=3' "$report"
grep -qx 'category.direct_secaccesscontrol=1' "$report"
grep -qx 'category.production_store_construction=11' "$report"
grep -q $'\tTests/PlainpostSecurityAcceptanceTests/' "$report"
grep -q $'\tApps/PlainpostiOS/PlainpostTests/MobileLeak.swift:' "$report"
if grep -q '^excluded=' "$report"; then
  printf '%s\n' "detector still reports a privileged excluded path" >&2
  exit 1
fi
if grep -q $'\tTests/Ordinary/InjectedAdapters.swift:' "$report"; then
  printf '%s\n' "detector rejected explicit injected adapter factories" >&2
  exit 1
fi
if grep -q $'\tTests/Ordinary/Safe.swift:' "$report"; then
  printf '%s\n' "detector reported comments or string literals" >&2
  exit 1
fi

failure_root="$fixture/failure-root"
mkdir -p "$failure_root/Tests/Ordinary"
printf '%s\n' 'let safe = true' >"$failure_root/Tests/Ordinary/First.swift"
printf '%s\n' 'let alsoSafe = true' >"$failure_root/Tests/Ordinary/Later.swift"

discovery_failure="$fixture/discovery-failure"
printf '%s\n' '#!/bin/zsh
exit 71' >"$discovery_failure"
chmod +x "$discovery_failure"
if PLAINPOST_KEYCHAIN_TEST_FILE_DISCOVERY_COMMAND="$discovery_failure" \
  "$detector" --root "$failure_root" --strict; then
  printf '%s\n' "strict detector ignored file discovery failure" >&2
  exit 1
fi

if PLAINPOST_KEYCHAIN_TEST_FILE_DISCOVERY_COMMAND="$fixture/missing-discovery-command" \
  "$detector" --root "$failure_root" --strict; then
  printf '%s\n' "strict detector ignored unavailable file discovery command" >&2
  exit 1
fi

ordered_discovery="$fixture/ordered-discovery"
printf '%s\n' '#!/bin/zsh
printf "Tests/Ordinary/First.swift\0Tests/Ordinary/Later.swift\0"' \
  >"$ordered_discovery"
chmod +x "$ordered_discovery"

scanner_failure="$fixture/scanner-failure"
printf '%s\n' '#!/bin/zsh
set -euo pipefail
if [[ "$2" == "Tests/Ordinary/First.swift" ]]; then
  exit 72
fi
touch "$SCANNER_LATER_MARKER"' >"$scanner_failure"
chmod +x "$scanner_failure"

scanner_later_marker="$fixture/scanner-reached-later"
if SCANNER_LATER_MARKER="$scanner_later_marker" \
  PLAINPOST_KEYCHAIN_TEST_FILE_DISCOVERY_COMMAND="$ordered_discovery" \
  PLAINPOST_KEYCHAIN_TEST_SCANNER_COMMAND="$scanner_failure" \
  "$detector" --root "$failure_root" --strict; then
  printf '%s\n' "strict detector ignored per-file scanner failure" >&2
  exit 1
fi
if [[ -e "$scanner_later_marker" ]]; then
  printf '%s\n' "detector continued scanning after a per-file failure" >&2
  exit 1
fi

malformed_root="$fixture/malformed-root"
mkdir -p "$malformed_root/Tests/Ordinary"
print -r -- 'let malformed = "unterminated' \
  >"$malformed_root/Tests/Ordinary/UnterminatedString.swift"
if "$detector" --root "$malformed_root" --strict; then
  print -u2 -- "strict detector accepted malformed Swift source"
  exit 1
fi

acceptance_mutation_root="$fixture/acceptance-mutation-root"
mkdir -p \
  "$acceptance_mutation_root/Tests/PlainpostSecurityAcceptanceTests"
print -r -- 'SecKeychainSetDefault(nil)' \
  >"$acceptance_mutation_root/Tests/PlainpostSecurityAcceptanceTests/Forbidden.swift"
if "$detector" --root "$acceptance_mutation_root" --strict; then
  print -u2 -- "strict detector accepted a default-Keychain mutation"
  exit 1
fi

default_mac_provider_root="$fixture/default-mac-provider-root"
mkdir -p \
  "$default_mac_provider_root/Tests/PlainpostSecurityAcceptanceTests"
print -r -- '_ = MacVaultKeyProvider()' \
  >"$default_mac_provider_root/Tests/PlainpostSecurityAcceptanceTests/MacVaultKeyProviderContractTests.swift"
if "$detector" --root "$default_mac_provider_root" --strict; then
  print -u2 -- \
    "strict detector accepted live Mac provider construction in contract tests"
  exit 1
fi

default_mobile_provider_root="$fixture/default-mobile-provider-root"
mkdir -p \
  "$default_mobile_provider_root/Tests/PlainpostSecurityAcceptanceTests"
print -r -- '_ = MobileVaultKeyProvider()' \
  >"$default_mobile_provider_root/Tests/PlainpostSecurityAcceptanceTests/MobileVaultKeyProviderContractTests.swift"
if "$detector" --root "$default_mobile_provider_root" --strict; then
  print -u2 -- \
    "strict detector accepted live Mobile provider construction in contract tests"
  exit 1
fi

nested_mac_provider_root="$fixture/nested-mac-provider-root"
mkdir -p \
  "$nested_mac_provider_root/Tests/PlainpostSecurityAcceptanceTests"
print -r -- \
  '_ = MacVaultKeyProvider(service: helper(operations: injectedOperations))' \
  >"$nested_mac_provider_root/Tests/PlainpostSecurityAcceptanceTests/MacVaultKeyProviderContractTests.swift"
if "$detector" --root "$nested_mac_provider_root" --strict; then
  print -u2 -- \
    "strict detector accepted nested operations labels in live Mac constructors"
  exit 1
fi

nested_mobile_provider_root="$fixture/nested-mobile-provider-root"
mkdir -p \
  "$nested_mobile_provider_root/Tests/PlainpostSecurityAcceptanceTests"
print -r -- \
  '_ = MobileVaultKeyProvider(service: helper(operations: injectedOperations))' \
  >"$nested_mobile_provider_root/Tests/PlainpostSecurityAcceptanceTests/MobileVaultKeyProviderContractTests.swift"
if "$detector" --root "$nested_mobile_provider_root" --strict; then
  print -u2 -- \
    "strict detector accepted nested operations labels in live Mobile constructors"
  exit 1
fi

unscoped_delete_root="$fixture/unscoped-delete-root"
mkdir -p \
  "$unscoped_delete_root/Tests/PlainpostSecurityAcceptanceTests"
print -r -- 'SecItemDelete([
  kSecClass: kSecClassGenericPassword,
] as CFDictionary)
SecItemDelete([
  kSecValuePersistentRef: persistentReference,
] as CFDictionary)
SecItemUpdate(
  [kSecValuePersistentRef: persistentReference] as CFDictionary,
  [kSecValueData: data] as CFDictionary
)' \
  >"$unscoped_delete_root/Tests/PlainpostSecurityAcceptanceTests/DisposableKeychainTests.swift"
if "$detector" --root "$unscoped_delete_root" --strict; then
  print -u2 -- \
    "strict detector accepted broad or unscoped disposable item mutation"
  exit 1
fi

no_match_root="$fixture/no-match-root"
mkdir -p "$no_match_root/Tests"
"$detector" --root "$no_match_root" --strict

rm \
  "$fixture/Tests/Ordinary/Leak.swift" \
  "$fixture/Tests/PlainpostSecurityAcceptanceTests/Allowed.swift" \
  "$fixture/Apps/PlainpostiOS/PlainpostTests/MobileLeak.swift"
rm -rf \
  "$malformed_root" \
  "$acceptance_mutation_root" \
  "$default_mac_provider_root" \
  "$default_mobile_provider_root" \
  "$nested_mac_provider_root" \
  "$nested_mobile_provider_root" \
  "$unscoped_delete_root"
"$detector" --root "$fixture" --strict
