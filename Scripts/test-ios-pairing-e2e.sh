#!/bin/zsh
set -euo pipefail

# XCUITest runs inside the Simulator. This wrapper owns a fresh real pinned-TLS
# host fixture per named test and forwards only its one-time invitation through
# the generated test-run environment.
script_directory="${0:A:h}"
source "$script_directory/lib/ios-pairing-invitation.sh"
source "$script_directory/lib/terminal-cleanup-traps.sh"
source "$script_directory/lib/acceptance-runtime-cleanup-status.sh"
source "$script_directory/lib/ios-e2e-xctestrun.sh"
source "$script_directory/lib/ios-e2e-log-redaction.sh"
source "$script_directory/lib/ios-e2e-simulator-reset.sh"
source "$script_directory/lib/ios-pairing-process-guard.sh"
source "$script_directory/lib/ios-e2e-visual-environment.sh"

build_artifacts="$script_directory/lib/build_artifacts.py"
swift_products="$(rtk proxy python3 "$build_artifacts" swift-products --root "$PWD" --cache "$PWD/.build" --signing adhoc)"
test_run=""
test_run_backup=""
iphone_udid="${PLAINPOST_E2E_IPHONE_UDID:-D17101C9-01EB-488D-AFE1-58E6C089B853}"
ipad_udid="${PLAINPOST_E2E_IPAD_UDID:-92FF38DE-7FEA-4C39-87B8-E0ECE9B4F464}"
iphone_destination="platform=iOS Simulator,id=$iphone_udid"
ipad_destination="platform=iOS Simulator,id=$ipad_udid"
fixture_host="${PLAINPOST_E2E_HOST:-$(rtk ipconfig getifaddr en0 2>/dev/null || true)}"
current_fixture_pid=""
current_fixture_log=""
current_result_dir=""
acceptance_root=""
acceptance_pid=""
acceptance_launcher_pid=""
acceptance_control_pid=""
acceptance_control_launcher_pid=""
acceptance_process_capture=""
acceptance_launcher_process_capture=""
acceptance_control_process_capture=""
acceptance_control_launcher_process_capture=""
acceptance_control_log=""
acceptance_log=""
acceptance_executable=""
acceptance_launcher_executable="$(rtk which rtk)"
acceptance_user_id="$(rtk id -u)"
acceptance_process_inspector="$swift_products/PlainpostIOSPairingFixture"
acceptance_service_name=""
acceptance_cleanup_log=""
acceptance_keychain_service=""
acceptance_transport_service=""
acceptance_tls_service=""
acceptance_seeded=0
selected_simulator_udid=""
ios_app_bundle_id=""
mobile_pairing_service=""
mobile_cache_namespace=""
acceptance_manifest_snapshot=""
acceptance_database_snapshot=""
acceptance_site_icon_snapshot=""
protected_manifest_paths=()
protected_database_paths=()
protected_site_icon_directory=""
cleanup_in_progress=0
checkpoint_file=".build/MacSyncAcceptance/packaged-mac-checkpoint.log"
simulator_reset_evidence=".build/MacSyncAcceptance/ios-e2e-reset.status"
rtk mkdir -p ".build/MacSyncAcceptance"
rtk rm -f "$checkpoint_file" "$simulator_reset_evidence"

checkpoint() {
    rtk date -u '+%Y-%m-%dT%H:%M:%SZ' | \
      rtk awk -v stage="$1" '{ print $0 " " stage }' >>"$checkpoint_file" || true
}

preserve_result_bundle() {
    local result_bundle="$1"
    local result_name="$2"
    [[ "${PLAINPOST_E2E_KEEP_RESULTS:-0}" == "1" ]] || return 0
    local destination="output/ios26-mail-redesign-2026-07-17/xcresults"
    local suffix="${PLAINPOST_E2E_RESULT_SUFFIX:-}"
    if [[ -n "$suffix" ]]; then
        if ! rtk echo "$suffix" | rtk rg -q '^[a-z0-9-]+$'; then
            rtk echo "PLAINPOST_E2E_RESULT_SUFFIX contains unsupported characters." >&2
            return 1
        fi
        result_name="$result_name-$suffix"
    fi
    rtk mkdir -p "$destination"
    rtk rm -rf "$destination/$result_name.xcresult"
    rtk cp -R "$result_bundle" "$destination/$result_name.xcresult"
}

if [[ -z "$fixture_host" ]]; then
    rtk echo "Set PLAINPOST_E2E_HOST to this Mac's simulator-reachable LAN address." >&2
    exit 1
fi
if ! rtk echo "$fixture_host" | rtk rg -q '^[A-Za-z0-9.-]+$'; then
    rtk echo "PLAINPOST_E2E_HOST contains unsupported characters." >&2
    exit 1
fi

record_cleanup_failure() {
    rtk echo "Plainpost E2E cleanup failed: $1." >&2
}

cleanup_current() {
    (( cleanup_in_progress )) && return 0
    cleanup_in_progress=1
    emulate -L zsh
    setopt localoptions noerrexit
    local cleanup_status=0
    checkpoint "cleanup-entry" || {
        record_cleanup_failure checkpoint-entry
        cleanup_status=1
    }
    if [[ -e "$test_run_backup" || -L "$test_run_backup" ]]; then
        restore_xctestrun_backup "$test_run" "$test_run_backup" || {
            record_cleanup_failure xctestrun-restore
            cleanup_status=1
        }
    fi
    if [[ ! -e "$test_run_backup" && ! -L "$test_run_backup" &&
          ( -e "${test_run_backup}.sha256" || -L "${test_run_backup}.sha256" ) ]]; then
        record_cleanup_failure xctestrun-orphaned-recovery-hash
        cleanup_status=1
    fi
    if [[ -n "$acceptance_pid" ]]; then
        terminate_acceptance_process "$acceptance_pid" "$acceptance_executable" "$acceptance_user_id" "$acceptance_root/runtime-credential-cleanup.status" 600 \
          "$acceptance_process_inspector" "$acceptance_process_capture" || {
            record_cleanup_failure acceptance-process-termination
            cleanup_status=1
        }
    fi
    if [[ -n "$acceptance_launcher_pid" && "$acceptance_launcher_pid" != "$acceptance_pid" ]]; then
        terminate_acceptance_process "$acceptance_launcher_pid" "$acceptance_launcher_executable" \
          "$acceptance_user_id" "" 50 "$acceptance_process_inspector" \
          "$acceptance_launcher_process_capture" || {
            record_cleanup_failure acceptance-launcher-termination
            cleanup_status=1
        }
    fi
    if [[ -n "$acceptance_control_pid" ]]; then
        terminate_acceptance_process "$acceptance_control_pid" "$acceptance_process_inspector" \
          "$acceptance_user_id" "" 50 "$acceptance_process_inspector" \
          "$acceptance_control_process_capture" || {
            record_cleanup_failure acceptance-control-termination
            cleanup_status=1
        }
    fi
    if [[ -n "$acceptance_control_launcher_pid" &&
          "$acceptance_control_launcher_pid" != "$acceptance_control_pid" ]]; then
        terminate_acceptance_process "$acceptance_control_launcher_pid" "$acceptance_launcher_executable" \
          "$acceptance_user_id" "" 50 \
          "$acceptance_process_inspector" "$acceptance_control_launcher_process_capture" || {
            record_cleanup_failure acceptance-control-launcher-termination
            cleanup_status=1
        }
    fi
    if [[ -n "$acceptance_root" && ( -n "$acceptance_pid" || -n "$acceptance_launcher_pid" ) ]]; then
        local runtime_cleanup_status="$acceptance_root/runtime-credential-cleanup.status"
        acceptance_cleanup_log=".build/MacSyncAcceptance/runtime-credential-cleanup.status"
        local runtime_cleanup_wait_status=0
        wait_for_acceptance_runtime_cleanup_status "$runtime_cleanup_status" 50 || \
          runtime_cleanup_wait_status=$?
        if [[ "$runtime_cleanup_wait_status" == "0" ]]; then
            rtk cp "$runtime_cleanup_status" "$acceptance_cleanup_log" || {
                record_cleanup_failure acceptance-runtime-cleanup-status-copy
                cleanup_status=1
            }
        elif [[ "$runtime_cleanup_wait_status" == "1" ]]; then
            rtk cp "$runtime_cleanup_status" "$acceptance_cleanup_log" || {
                record_cleanup_failure acceptance-runtime-cleanup-status-copy
            }
            record_cleanup_failure acceptance-runtime-credential-cleanup
            rtk tail -n 40 "$acceptance_cleanup_log" >&2 || true
            cleanup_status=1
        else
            rtk printf '%s\n' 'timeout waiting for runtime credential cleanup status' >"$acceptance_cleanup_log"
            record_cleanup_failure acceptance-runtime-credential-cleanup-timeout
            cleanup_status=1
        fi
    fi
    if (( acceptance_seeded )); then
        acceptance_cleanup_log=".build/MacSyncAcceptance/seed-credential-cleanup.log"
        if [[ ! -x "$swift_products/PlainpostMacSyncAcceptanceSeed" ]]; then
            record_cleanup_failure acceptance-seeder-missing-after-seed
            cleanup_status=1
        elif ! rtk "$swift_products/PlainpostMacSyncAcceptanceSeed" cleanup \
          --root "$acceptance_root" \
          --database-path "$acceptance_root/Plainpost.sqlite" \
          --keychain-service "$acceptance_keychain_service" \
          --transport-service "$acceptance_transport_service" \
          --tls-service "$acceptance_tls_service" >"$acceptance_cleanup_log" 2>&1; then
            record_cleanup_failure acceptance-credential-cleanup
            rtk tail -n 40 "$acceptance_cleanup_log" >&2 || true
            cleanup_status=1
        fi
    fi
    if [[ -n "$acceptance_manifest_snapshot" && -f "$acceptance_manifest_snapshot" ]]; then
        assert_file_snapshots_unchanged "$acceptance_manifest_snapshot" "${protected_manifest_paths[@]}" || {
            record_cleanup_failure production-manifest-snapshot
            cleanup_status=1
        }
    fi
    if [[ -n "$acceptance_database_snapshot" && -f "$acceptance_database_snapshot" && "${#protected_database_paths[@]}" -gt 0 ]]; then
        assert_file_snapshots_unchanged "$acceptance_database_snapshot" "${protected_database_paths[@]}" || {
            record_cleanup_failure production-database-snapshot
            cleanup_status=1
        }
    fi
    if [[ -n "$acceptance_site_icon_snapshot" && -f "$acceptance_site_icon_snapshot" && -n "$protected_site_icon_directory" ]]; then
        assert_directory_tree_snapshot_unchanged "$acceptance_site_icon_snapshot" "$protected_site_icon_directory" || {
            record_cleanup_failure production-site-icon-snapshot
            cleanup_status=1
        }
    fi
    if [[ -n "$acceptance_root" ]]; then
        if [[ "$acceptance_root" == /tmp/plainpost-acceptance.* && -d "$acceptance_root" && ! -L "$acceptance_root" ]]; then
            rtk rm -rf -- "$acceptance_root" || {
                record_cleanup_failure acceptance-root-removal
                cleanup_status=1
            }
        else
            rtk echo "Refusing to remove an unsafe acceptance root." >&2
            record_cleanup_failure acceptance-root-validation
            cleanup_status=1
        fi
    fi
    if [[ -n "$current_fixture_pid" ]]; then
        rtk pkill -TERM -P "$current_fixture_pid" 2>/dev/null || true
        rtk kill "$current_fixture_pid" 2>/dev/null || true
        wait "$current_fixture_pid" 2>/dev/null || true
    fi
    if [[ -n "$selected_simulator_udid" && -n "$ios_app_bundle_id" ]]; then
        reset_and_uninstall_ios_e2e_app \
          "$selected_simulator_udid" \
          "$ios_app_bundle_id" \
          "$mobile_pairing_service" \
          "$mobile_cache_namespace" \
          "$simulator_reset_evidence" || {
            record_cleanup_failure simulator-app-reset-and-uninstall
            cleanup_status=1
        }
    fi
    [[ -z "$current_fixture_log" ]] || rtk rm -f "$current_fixture_log" || {
        record_cleanup_failure fixture-log-removal
        cleanup_status=1
    }
    [[ -z "$current_result_dir" ]] || rtk rm -rf "$current_result_dir" || {
        record_cleanup_failure fixture-result-removal
        cleanup_status=1
    }
    current_fixture_pid=""
    current_fixture_log=""
    current_result_dir=""
    acceptance_root=""
    acceptance_pid=""
    acceptance_launcher_pid=""
    acceptance_control_pid=""
    acceptance_control_launcher_pid=""
    acceptance_process_capture=""
    acceptance_launcher_process_capture=""
    acceptance_control_process_capture=""
    acceptance_control_launcher_process_capture=""
    acceptance_control_log=""
    acceptance_log=""
    acceptance_executable=""
    acceptance_service_name=""
    acceptance_cleanup_log=""
    acceptance_keychain_service=""
    acceptance_transport_service=""
    acceptance_tls_service=""
    acceptance_seeded=0
    selected_simulator_udid=""
    ios_app_bundle_id=""
    mobile_pairing_service=""
    mobile_cache_namespace=""
    acceptance_manifest_snapshot=""
    acceptance_database_snapshot=""
    acceptance_site_icon_snapshot=""
    protected_manifest_paths=()
    protected_database_paths=()
    protected_site_icon_directory=""
    checkpoint "cleanup-exit" || {
        record_cleanup_failure checkpoint-exit
        cleanup_status=1
    }
    cleanup_in_progress=0
    return "$cleanup_status"
}
eval "$(terminal_cleanup_trap_setup cleanup_current)"

acceptance_app_process_id() {
    acceptance_exact_process_id "$1" Plainpost
}

prepare_simulator() {
    local udid="$1"
    rtk xcrun simctl boot "$udid" 2>/dev/null || true
    rtk xcrun simctl bootstatus "$udid" -b
}

reset_simulator() {
    local udid="$1"
    rtk xcrun simctl shutdown "$udid" 2>/dev/null || true
    prepare_simulator "$udid"
}

case "${PLAINPOST_E2E_ONLY:-}" in
    *-ipad)
        reset_simulator "$ipad_udid"
        ;;
    *-iphone)
        prepare_simulator "$iphone_udid"
        ;;
    *)
        prepare_simulator "$iphone_udid"
        prepare_simulator "$ipad_udid"
        ;;
esac

ios_derived="$(rtk proxy python3 "$build_artifacts" cache --root "$PWD" --purpose ios-pairing --sdk iphonesimulator --signing automatic)"
runner_receipt="$ios_derived/plainpost-runner-receipt.json"
rtk proxy python3 "$build_artifacts" build --root "$PWD" --cache "$ios_derived" \
  --sdk iphonesimulator --signing automatic --receipt "$runner_receipt" \
  --scheme Plainpost --expected-target PlainpostTests --expected-target PlainpostUITests -- \
  rtk xcodebuild -project Apps/PlainpostiOS/Plainpost.xcodeproj -scheme Plainpost \
  -configuration Debug -sdk iphonesimulator -destination "$iphone_destination" \
  -derivedDataPath "$ios_derived" build-for-testing
test_run="$(rtk proxy python3 "$build_artifacts" verify --root "$PWD" --sdk iphonesimulator --signing automatic --receipt "$runner_receipt" --role xctestrun)"
test_run_backup="${test_run}.plainpost-backup"
verify_pairing_products() {
    local backup_arguments=()
    [[ ! -f "$test_run_backup" ]] || backup_arguments=(--runner-backup "$test_run_backup")
    rtk proxy python3 "$build_artifacts" verify --root "$PWD" --sdk iphonesimulator \
      --signing automatic --receipt "$runner_receipt" "${backup_arguments[@]}"
}

ios_app_bundle_id="$(rtk /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$ios_derived/Build/Products/Debug-iphonesimulator/Plainpost.app/Info.plist")"
if [[ "$ios_app_bundle_id" != "com.marynavdovenko.Plainpost.iOS" ]]; then
    rtk echo "The built production iOS bundle identifier was unexpected." >&2
    exit 1
fi

run_signed_native_tests() {
    local destination="$1"
    local result_label="$2"
    local result_name="$3"
    current_result_dir="$(rtk mktemp -d -t plainpost-ios-native-result)"
    local result_bundle="$current_result_dir/Plainpost.xcresult"

    verify_pairing_products || return 1
    if ! rtk xcodebuild test-without-building -xctestrun "$test_run" \
      -destination "$destination" \
      -only-testing:PlainpostTests \
      -resultBundlePath "$result_bundle"; then
        rtk echo "$result_label did not complete successfully."
        return 1
    fi
    if rtk xcrun xcresulttool get test-results tests --path "$result_bundle" | rtk rg -q '"result" : "(Failed|Skipped)"'; then
        rtk echo "$result_label included a failed or skipped native test."
        return 1
    fi
    if ! rtk xcrun xcresulttool get test-results tests --path "$result_bundle" | \
      TEST_NAME='testWorkspaceFetchesSafeBodyAndExposesOnlyConfirmedHTTPLinks' rtk awk '
        $0 ~ "\\\"name\\\" : \\\"" ENVIRON["TEST_NAME"] "\\(\\)\\\"" { candidate = 1; next }
        candidate && /"result"/ {
            passed = $0 ~ /"result" : "Passed"/
            exit
        }
        END { exit(passed ? 0 : 1) }
    '; then
        rtk echo "$result_label was missing the named mail-workspace test or it did not report Passed."
        return 1
    fi
    rtk echo "$result_label passed."
    preserve_result_bundle "$result_bundle" "$result_name"
    terminal_cleanup_manually cleanup_current
}

run_host_fixture_test() {
    local test_name="$1"
    local result_label="$2"
    local destination="$3"
    local result_name="$4"
    local adaptive_viewport_width="${5:-}"
    local invitation_line=""
    local control_port_line=""
    local control_token_line=""
    local invitation=""
    local control_port=""
    local control_token=""
    local store_service="com.marynavdovenko.Plainpost.MobileClient.E2E.$(rtk uuidgen)"

    current_fixture_log="$(rtk mktemp -t plainpost-ios-pairing-fixture)"
    current_result_dir="$(rtk mktemp -d -t plainpost-ios-pairing-result)"
    local result_bundle="$current_result_dir/Plainpost.xcresult"

    PLAINPOST_E2E_HOST="$fixture_host" rtk swift run PlainpostIOSPairingFixture >"$current_fixture_log" 2>&1 &
    current_fixture_pid=$!
    for _ in {1..100}; do
        invitation_line="$(rtk rg -m1 '^PLAINPOST_E2E_INVITATION_BASE64=' "$current_fixture_log" || true)"
        control_port_line="$(rtk rg -m1 '^PLAINPOST_E2E_CONTROL_PORT=' "$current_fixture_log" || true)"
        control_token_line="$(rtk rg -m1 '^PLAINPOST_E2E_CONTROL_TOKEN=' "$current_fixture_log" || true)"
        [[ -n "$invitation_line" && -n "$control_port_line" && -n "$control_token_line" ]] && break
        rtk sleep 0.1
    done
    if [[ -z "$invitation_line" || -z "$control_port_line" || -z "$control_token_line" ]]; then
        redact_ios_fixture_log "$current_fixture_log" | rtk sed -n '1,160p' >&2
        return 1
    fi
    invitation="${invitation_line#PLAINPOST_E2E_INVITATION_BASE64=}"
    control_port="${control_port_line#PLAINPOST_E2E_CONTROL_PORT=}"
    control_token="${control_token_line#PLAINPOST_E2E_CONTROL_TOKEN=}"
    if [[ "$control_port" != <1-65535> ]] ||
       ! rtk echo "$control_token" | rtk rg -q '^[A-Za-z0-9+/]{43}=$'; then
        rtk echo "The host fixture returned invalid control configuration." >&2
        return 1
    fi

    if ! prepare_xctestrun_backup "$test_run" "$test_run_backup"; then
        return 1
    fi
    rtk /usr/libexec/PlistBuddy -c "Add :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_E2E_INVITATION_BASE64 string $invitation" "$test_run"
    rtk /usr/libexec/PlistBuddy -c "Add :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_E2E_PAIRING_STORE_SERVICE string $store_service" "$test_run"
    rtk /usr/libexec/PlistBuddy -c "Add :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_E2E_CONTROL_HOST string $fixture_host" "$test_run"
    rtk /usr/libexec/PlistBuddy -c "Add :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_E2E_CONTROL_PORT string $control_port" "$test_run"
    rtk /usr/libexec/PlistBuddy -c "Add :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_E2E_CONTROL_TOKEN string $control_token" "$test_run"
    ios_e2e_forward_visual_environment "$test_run"
    if [[ "$destination" == "$ipad_destination" ]]; then
        rtk /usr/libexec/PlistBuddy -c \
          "Add :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_E2E_DEVICE_CLASS string ipad" \
          "$test_run"
    else
        rtk /usr/libexec/PlistBuddy -c \
          "Add :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_E2E_DEVICE_CLASS string iphone" \
          "$test_run"
    fi
    if [[ "$destination" == "$ipad_destination" &&
          "$test_name" == "testMailReadingOfflineSearchAndMutationReconciliationWithHostFixture" ]]; then
        rtk /usr/libexec/PlistBuddy -c "Add :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_E2E_REQUIRE_IPAD_COLUMNS string 1" "$test_run"
    fi
    if [[ "$test_name" == "testComposeDraftConflictAttachmentUndoAndUncertainLifecycleWithHostFixture" ]]; then
        local attachment_base64="$(rtk echo -n 'fixture attachment' | rtk base64)"
        rtk /usr/libexec/PlistBuddy -c "Add :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_E2E_COMPOSE_AUTH string success" "$test_run"
        rtk /usr/libexec/PlistBuddy -c "Add :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_E2E_COMPOSE_ATTACHMENT_BASE64 string $attachment_base64" "$test_run"
    fi
    if [[ -n "$adaptive_viewport_width" ]]; then
        if [[ "$adaptive_viewport_width" != "375" &&
              "$adaptive_viewport_width" != "393" &&
              "$adaptive_viewport_width" != "430" &&
              "$adaptive_viewport_width" != "520" &&
              "$adaptive_viewport_width" != "760" ]]; then
            rtk echo "The adaptive accessibility lane requested an unsupported viewport width." >&2
            return 1
        fi
        rtk /usr/libexec/PlistBuddy -c \
          "Add :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_E2E_ADAPTIVE_VIEWPORT_WIDTH string $adaptive_viewport_width" \
          "$test_run"
    fi

    verify_pairing_products || return 1
    if ! rtk xcodebuild test-without-building -xctestrun "$test_run" \
      -destination "$destination" \
      -only-testing:"PlainpostUITests/PlainpostUITests/$test_name" \
      -resultBundlePath "$result_bundle"; then
        rtk echo "$result_label did not complete successfully."
        rtk rg '^FIXTURE_REQUEST ' "$current_fixture_log" || true
        preserve_result_bundle "$result_bundle" "$result_name-failed" || true
        return 1
    fi

    if ! rtk xcrun xcresulttool get test-results tests --path "$result_bundle" | TEST_NAME="$test_name" rtk awk '
        $0 ~ "\\\"name\\\" : \\\"" ENVIRON["TEST_NAME"] "\\(\\)\\\"" { candidate = 1; next }
        candidate && /"result"/ {
            passed = $0 ~ /"result" : "Passed"/
            exit
        }
        END { exit(passed ? 0 : 1) }
    '; then
        rtk echo "$result_label was missing or did not report Passed."
        return 1
    fi
    if [[ "$test_name" == "testMailReadingOfflineSearchAndMutationReconciliationWithHostFixture" ]]; then
        local stop_count="$(rtk rg -c '^FIXTURE_CONTROL stop$' "$current_fixture_log" || true)"
        local restart_count="$(rtk rg -c '^FIXTURE_CONTROL restart$' "$current_fixture_log" || true)"
        if (( ${stop_count:-0} < 2 || ${restart_count:-0} < 2 )); then
            rtk echo "$result_label did not prove both real listener outage/restart cycles."
            return 1
        fi
        if ! rtk rg -q '^FIXTURE_MUTATION_AUTHORITATIVE revision=3 seen=true$' "$current_fixture_log"; then
            rtk echo "$result_label did not prove an authoritative host mutation at revision 3."
            return 1
        fi
        if ! rtk rg -q '^FIXTURE_BODY_AUTHORITATIVE revision=3 seen=true$' "$current_fixture_log"; then
            rtk echo "$result_label did not refetch the authoritative revision-3 body state."
            return 1
        fi
    fi
    if [[ "$test_name" == "testComposeDraftConflictAttachmentUndoAndUncertainLifecycleWithHostFixture" ]]; then
        local direct_send_count="$(rtk rg -c '^FIXTURE_REQUEST method=compose.sendDirect outcome=success$' "$current_fixture_log" || true)"
        local status_count="$(rtk rg -c '^FIXTURE_REQUEST method=compose.sendStatus outcome=success$' "$current_fixture_log" || true)"
        if (( ${direct_send_count:-0} != 3 || ${status_count:-0} < 2 )); then
            rtk echo "$result_label did not prove exactly three direct sends and status-only reconciliation."
            rtk rg '^FIXTURE_REQUEST method=compose\\.send(Direct|Status)' "$current_fixture_log" || true
            return 1
        fi
    fi
    if [[ "$test_name" == "testFunctionalMobileParityWithHostFixture" ]]; then
        local direct_send_count="$(rtk rg -c '^FIXTURE_REQUEST method=compose.sendDirect outcome=success$' "$current_fixture_log" || true)"
        local status_count="$(rtk rg -c '^FIXTURE_REQUEST method=compose.sendStatus outcome=success$' "$current_fixture_log" || true)"
        if (( ${direct_send_count:-0} != 1 || ${status_count:-0} < 1 )); then
            rtk echo "$result_label did not prove one direct send and status-only reconciliation after the dropped response."
            rtk rg '^FIXTURE_REQUEST method=compose\\.send(Direct|Status)' "$current_fixture_log" || true
            return 1
        fi
    fi
    rtk echo "$result_label passed."
    preserve_result_bundle "$result_bundle" "$result_name"
    terminal_cleanup_manually cleanup_current
}

default_packaged_app_processes() {
    rtk ps -axo pid=,command= | rtk awk 'index($0, ".build/Plainpost.app/Contents/MacOS/Plainpost") { print $1 }'
}

capture_file_snapshots() {
    local output="$1"
    shift
    : >"$output"
    local snapshot_path
    for snapshot_path in "$@"; do
        if [[ -L "$snapshot_path" ]]; then
            rtk printf 'symlink\t%s\n' "$snapshot_path" >>"$output"
        elif [[ -f "$snapshot_path" ]]; then
            local metadata="$(rtk stat -f '%u:%Lp:%z:%m' "$snapshot_path")"
            local digest="$(rtk shasum -a 256 "$snapshot_path" | rtk awk '{print $1}')"
            rtk printf 'file\t%s\t%s\t%s\n' "$snapshot_path" "$metadata" "$digest" >>"$output"
        elif [[ -e "$snapshot_path" ]]; then
            rtk printf 'other\t%s\n' "$snapshot_path" >>"$output"
        else
            rtk printf 'missing\t%s\n' "$snapshot_path" >>"$output"
        fi
    done
    rtk chmod 0600 "$output"
}

assert_file_snapshots_unchanged() {
    local expected="$1"
    shift
    local actual="${expected}.actual"
    capture_file_snapshots "$actual" "$@"
    if ! rtk cmp -s "$expected" "$actual"; then
        rtk echo "A protected production file snapshot changed during acceptance." >&2
        return 1
    fi
    rtk rm -f -- "$actual"
}

capture_directory_tree_snapshot() {
    local output="$1"
    local root="$2"
    : >"$output"
    if [[ -L "$root" ]]; then
        rtk printf 'symlink-root\t%s\t%s\n' "$root" "$(rtk readlink "$root")" >>"$output"
    elif [[ ! -e "$root" ]]; then
        rtk printf 'missing-root\t%s\n' "$root" >>"$output"
    elif [[ ! -d "$root" ]]; then
        rtk printf 'non-directory-root\t%s\n' "$root" >>"$output"
    else
        rtk printf 'directory\t.\t%s\n' "$(rtk stat -f '%u:%Lp:%z:%m' "$root")" >>"$output"
        local entry
        local entries=("$root"/**/*(DN))
        for entry in "${entries[@]}"; do
            local relative="${entry#$root/}"
            local metadata="$(rtk stat -f '%u:%Lp:%z:%m' "$entry")"
            if [[ -L "$entry" ]]; then
                rtk printf 'symlink\t%s\t%s\t%s\n' "$relative" "$metadata" "$(rtk readlink "$entry")" >>"$output"
            elif [[ -f "$entry" ]]; then
                rtk printf 'file\t%s\t%s\t%s\n' "$relative" "$metadata" "$(rtk shasum -a 256 "$entry" | rtk awk '{print $1}')" >>"$output"
            elif [[ -d "$entry" ]]; then
                rtk printf 'directory\t%s\t%s\n' "$relative" "$metadata" >>"$output"
            else
                rtk printf 'other\t%s\t%s\n' "$relative" "$metadata" >>"$output"
            fi
        done
    fi
    rtk chmod 0600 "$output"
}

assert_directory_tree_snapshot_unchanged() {
    local expected="$1"
    local root="$2"
    local actual="${expected}.actual"
    capture_directory_tree_snapshot "$actual" "$root"
    if ! rtk cmp -s "$expected" "$actual"; then
        rtk echo "The protected production directory snapshot changed during acceptance." >&2
        return 1
    fi
    rtk rm -f -- "$actual"
}

preflight_acceptance_root() {
    local root="$1"
    local expected_owner="$(rtk id -u)"
    local root_metadata="$(rtk stat -f '%u:%Lp' "$root")"
    [[ "$root" == /tmp/plainpost-acceptance.* && -d "$root" && ! -L "$root" ]] || return 1
    [[ "$root_metadata" == "$expected_owner:700" ]]
}

print_packaged_mac_failure() {
    if [[ -n "$acceptance_log" && -f "$acceptance_log" ]]; then
        rtk echo "Last 120 sanitized packaged-Mac log lines:" >&2
        rtk tail -n 120 "$acceptance_log" | rtk sed -E \
          -e 's/(PLAINPOST_E2E_INVITATION_BASE64=)[^[:space:]]+/\\1[REDACTED]/g' \
          -e 's/[A-Za-z0-9+\\/]{43}=/[REDACTED]/g' >&2
    fi
    if [[ -n "$acceptance_control_log" && -f "$acceptance_control_log" ]]; then
        rtk echo "Sanitized packaged control state:" >&2
        rtk rg '^Plainpost acceptance control:' "$acceptance_control_log" | \
          rtk tail -n 120 >&2 || true
    fi
    local result_bundle="$acceptance_root/Plainpost.xcresult"
    if [[ -d "$result_bundle" ]]; then
        rtk echo "Xcode result summary:" >&2
        rtk xcrun xcresulttool get test-results tests --path "$result_bundle" 2>/dev/null | \
          rtk tail -n 120 >&2 || true
    fi
}

fail_packaged_mac_app() {
    print_packaged_mac_failure
    if [[ -n "$acceptance_root" && -d "$acceptance_root/Plainpost.xcresult" ]]; then
        preserve_result_bundle "$acceptance_root/Plainpost.xcresult" "mac-app-iphone-failed" || true
    fi
    terminal_cleanup_manually cleanup_current
    return 1
}

build_packaged_mac_helpers() {
    if ! rtk swift build --product PlainpostMacSyncAcceptanceSeed --configuration debug ||
       ! rtk swift build --product PlainpostBackgroundAgent --configuration debug ||
       ! rtk swift build --product PlainpostBrowserBridge --configuration debug ||
       ! rtk swift build --product PlainpostIOSPairingFixture --configuration debug; then
        rtk echo "The packaged Mac acceptance helper build failed." >&2
        return 1
    fi
    if [[ ! -x "$swift_products/PlainpostMacSyncAcceptanceSeed" ||
          ! -x "$swift_products/PlainpostBackgroundAgent" ||
          ! -x "$swift_products/PlainpostBrowserBridge" ||
          ! -x "$swift_products/PlainpostIOSPairingFixture" ]]; then
        rtk echo "The packaged Mac acceptance helper build did not produce every required executable." >&2
        return 1
    fi
}

run_packaged_mac_app_test() {
    checkpoint "packaged-lane-entry"
    if ! build_packaged_mac_helpers; then
        fail_packaged_mac_app
        return 1
    fi
    local suffix="$(rtk uuidgen | rtk tr '[:upper:]' '[:lower:]')"
    local bundle="$PWD/.build/MacSyncAcceptance/Plainpost.app"
    local invitation_file=""
    local invitation=""
    local mobile_store_service="com.marynavdovenko.Plainpost.MobileClient.E2E.$suffix"
    local mobile_cache_namespace="$suffix"
    local listener_count="0"
    local default_processes_before="$(default_packaged_app_processes)"
    local default_processes_after=""
    local result_bundle=""
    local user_home="${PLAINPOST_E2E_USER_HOME:-$HOME}"
    local manifest_paths=(
      "$user_home/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.marynavdovenko.plainpost.browser.json"
      "$user_home/Library/Application Support/Chromium/NativeMessagingHosts/com.marynavdovenko.plainpost.browser.json"
      "$user_home/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.marynavdovenko.plainpost.browser.json"
      "$user_home/Library/Application Support/Microsoft Edge/NativeMessagingHosts/com.marynavdovenko.plainpost.browser.json"
      "$user_home/Library/Application Support/Vivaldi/NativeMessagingHosts/com.marynavdovenko.plainpost.browser.json"
      "$user_home/Library/Application Support/Mozilla/NativeMessagingHosts/com.marynavdovenko.plainpost.browser.json"
      "$user_home/Library/Application Support/zen/NativeMessagingHosts/com.marynavdovenko.plainpost.browser.json"
    )
    local default_database="$user_home/Library/Application Support/Plainpost/Plainpost.sqlite"
    local database_paths=("$default_database" "${default_database}-wal" "${default_database}-shm")
    local default_site_icon_directory="$user_home/Library/Application Support/Plainpost/SiteIcons"
    protected_manifest_paths=("${manifest_paths[@]}")
    protected_database_paths=("${database_paths[@]}")
    protected_site_icon_directory="$default_site_icon_directory"

    acceptance_root="$(rtk mktemp -d /tmp/plainpost-acceptance.XXXXXX)"
    acceptance_root="${acceptance_root%/}"
    rtk chmod 0700 "$acceptance_root"
    if ! preflight_acceptance_root "$acceptance_root"; then
        rtk echo "The acceptance root failed its owned-0700 preflight." >&2
        fail_packaged_mac_app
        return 1
    fi
    invitation_file="$acceptance_root/invitation.base64"
    acceptance_manifest_snapshot="$acceptance_root/production-manifests.snapshot"
    acceptance_database_snapshot="$acceptance_root/production-database.snapshot"
    acceptance_site_icon_snapshot="$acceptance_root/production-site-icons.snapshot"
    capture_file_snapshots "$acceptance_manifest_snapshot" "${manifest_paths[@]}"
    capture_file_snapshots "$acceptance_database_snapshot" "${database_paths[@]}"
    capture_directory_tree_snapshot "$acceptance_site_icon_snapshot" "$default_site_icon_directory"
    acceptance_log="$acceptance_root/packaged-mac.log"
    acceptance_keychain_service="com.marynavdovenko.Plainpost.Acceptance.$suffix.keychain"
    acceptance_transport_service="com.marynavdovenko.Plainpost.Acceptance.$suffix.transport"
    acceptance_tls_service="com.marynavdovenko.Plainpost.Acceptance.$suffix.tls"
    local acceptance_service_instance_name="plainpost-acceptance-$suffix"
    acceptance_executable="$bundle/Contents/MacOS/Plainpost"
    acceptance_service_name="$acceptance_service_instance_name"

    if ! rtk "$swift_products/PlainpostMacSyncAcceptanceSeed" seed \
      --root "$acceptance_root" \
      --database-path "$acceptance_root/Plainpost.sqlite" \
      --keychain-service "$acceptance_keychain_service" \
      --transport-service "$acceptance_transport_service" \
      --tls-service "$acceptance_tls_service"; then
        fail_packaged_mac_app
        return 1
    fi
    acceptance_seeded=1
    checkpoint "intermediate-cleanup-entry"
    if ! rtk "$swift_products/PlainpostMacSyncAcceptanceSeed" cleanup \
      --root "$acceptance_root" \
      --database-path "$acceptance_root/Plainpost.sqlite" \
      --keychain-service "$acceptance_keychain_service" \
      --transport-service "$acceptance_transport_service" \
      --tls-service "$acceptance_tls_service"; then
        fail_packaged_mac_app
        return 1
    fi
    checkpoint "intermediate-cleanup-exit"
    checkpoint "db-assertion-entry"
    local seeded_projection="$(rtk sqlite3 "$acceptance_root/Plainpost.sqlite" \
      "SELECT (SELECT COUNT(*) FROM messages), (SELECT COUNT(*) FROM messages WHERE id = 'mac-app-acceptance-message-00'), (SELECT COUNT(*) FROM messages WHERE id = 'mac-app-acceptance-message-25');" || true)"
    if [[ "$seeded_projection" != "50|1|1" ]]; then
        rtk echo "The acceptance credential cleanup changed the seeded mailbox projection." >&2
        fail_packaged_mac_app
        return 1
    fi
    checkpoint "db-assertion-exit"
    checkpoint "package-entry"
    if ! rtk env PLAINPOST_APP_BUNDLE_OUTPUT="$bundle" \
      bash Scripts/package-app-bundle.sh >"$acceptance_root/package.log" 2>&1; then
        fail_packaged_mac_app
        return 1
    fi
    checkpoint "package-exit"
    if [[ ! -x "$bundle/Contents/MacOS/Plainpost" ]]; then
        rtk echo "The scoped packaged Mac app was not produced." >&2
        fail_packaged_mac_app
        return 1
    fi

    checkpoint "app-launch-entry"
    rtk /usr/bin/env \
      PLAINPOST_ACCEPTANCE_ROOT="$acceptance_root" \
      PLAINPOST_ACCEPTANCE_DATABASE_PATH="$acceptance_root/Plainpost.sqlite" \
      PLAINPOST_ACCEPTANCE_KEYCHAIN_SERVICE="$acceptance_keychain_service" \
      PLAINPOST_ACCEPTANCE_TRANSPORT_SERVICE="$acceptance_transport_service" \
      PLAINPOST_ACCEPTANCE_TLS_SERVICE="$acceptance_tls_service" \
      PLAINPOST_ACCEPTANCE_SERVICE_NAME="$acceptance_service_name" \
      PLAINPOST_ACCEPTANCE_HOST="$fixture_host" \
      PLAINPOST_ACCEPTANCE_INVITATION_FILE="$invitation_file" \
      "$acceptance_executable" >"$acceptance_log" 2>&1 &
    acceptance_launcher_pid=$!
    acceptance_launcher_process_capture="$(acceptance_process_identity_capture \
      "$acceptance_launcher_pid" "$acceptance_launcher_executable" "$acceptance_user_id" \
      "$acceptance_process_inspector")"
    if [[ "$acceptance_launcher_process_capture" != present:<0->:<0-> &&
          "$acceptance_launcher_process_capture" != absent ]]; then
        rtk echo "The packaged Mac rtk launcher identity could not be pinned at launch." >&2
        fail_packaged_mac_app
        return 1
    fi
    checkpoint "app-launch-exit"
    for _ in {1..50}; do
        acceptance_pid="$(acceptance_app_process_id "$acceptance_executable" || true)"
        [[ -n "$acceptance_pid" ]] && break
        rtk sleep 0.1
    done
    if rtk kill -0 "$acceptance_pid" 2>/dev/null; then
        checkpoint "pid-alive"
    else
        checkpoint "pid-not-alive"
    fi
    acceptance_process_capture="$(acceptance_process_identity_capture \
      "$acceptance_pid" "$acceptance_executable" "$acceptance_user_id" \
      "$acceptance_process_inspector")"
    if [[ "$acceptance_process_capture" != present:<0->:<0-> ]]; then
        rtk echo "The exact packaged Mac process identity could not be pinned at launch." >&2
        fail_packaged_mac_app
        return 1
    fi

    local invitation_deadline=$((SECONDS + 300))
    while (( SECONDS < invitation_deadline )); do
        checkpoint "poll-entry"
        if [[ -s "$invitation_file" ]]; then
            listener_count="$( { rtk lsof -nP -a -p "$acceptance_pid" -iTCP -sTCP:LISTEN 2>/dev/null || true; } | \
              rtk awk 'NR > 1 { count += 1 } END { print count + 0 }')" || listener_count="0"
            local invitation_mode="$(rtk stat -f '%Lp' "$invitation_file" 2>/dev/null || true)"
            if [[ "$listener_count" == "1" && "$invitation_mode" == "600" ]]; then
                break
            fi
        fi
        rtk sleep 0.1
        checkpoint "poll-exit"
    done
    checkpoint "invitation-validation-entry"
    if [[ ! -s "$invitation_file" || "$(rtk stat -f '%Lp' "$invitation_file" 2>/dev/null || true)" != "600" || "$listener_count" != "1" ]]; then
        rtk echo "The packaged Mac app did not export an owner-only invitation from exactly one listener." >&2
        fail_packaged_mac_app
        return 1
    fi
    checkpoint "invitation-validation-exit"
    local windowless_status="$acceptance_root/windowless.status"
    local windowless_deadline=$((SECONDS + 30))
    while (( SECONDS < windowless_deadline )); do
        [[ -f "$windowless_status" && "$(rtk stat -f '%Lp' "$windowless_status" 2>/dev/null || true)" == "600" && "$(<"$windowless_status")" == "windowless" ]] && break
        rtk sleep 0.1
    done
    listener_count="$( { rtk lsof -nP -a -p "$acceptance_pid" -iTCP -sTCP:LISTEN 2>/dev/null || true; } | rtk awk 'NR > 1 { count += 1 } END { print count + 0 }')"
    if [[ ! -f "$windowless_status" || "$(rtk stat -f '%Lp' "$windowless_status" 2>/dev/null || true)" != "600" || "$(<"$windowless_status")" != "windowless" || "$listener_count" != "1" ]] || ! rtk kill -0 "$acceptance_pid" 2>/dev/null; then
        rtk echo "The exact packaged Mac process did not remain alive with one listener after becoming windowless." >&2
        fail_packaged_mac_app
        return 1
    fi
    if rtk ps -axo ppid=,comm= | rtk awk -v parent="$acceptance_pid" '$1 == parent && $2 ~ /PlainpostBackgroundAgent$/ { found=1 } END { exit(found ? 0 : 1) }'; then
        rtk echo "The acceptance app started a forbidden background-agent child." >&2
        fail_packaged_mac_app
        return 1
    fi
    checkpoint "windowless-listener-verified"
    if ! invitation="$(read_ios_pairing_invitation "$invitation_file")"; then
        rtk echo "The packaged Mac invitation did not contain a valid base64 protocol payload." >&2
        fail_packaged_mac_app
        return 1
    fi
    local acceptance_listener_port="$(rtk printf '%s' "$invitation" | rtk base64 -D | rtk jq -er '.endpoint.host.port' 2>/dev/null || true)"
    if [[ "$acceptance_listener_port" != <1-65535> ]]; then
        rtk echo "The packaged Mac invitation did not contain a valid listener port." >&2
        fail_packaged_mac_app
        return 1
    fi

    acceptance_control_log="$acceptance_root/packaged-control.log"
    rtk /usr/bin/env \
      PLAINPOST_E2E_HOST="$fixture_host" \
      PLAINPOST_E2E_PACKAGED_CONTROL_ROOT="$acceptance_root" \
      PLAINPOST_E2E_PACKAGED_CONTROL_PID="$acceptance_pid" \
      PLAINPOST_E2E_PACKAGED_CONTROL_EXECUTABLE="$acceptance_executable" \
      PLAINPOST_E2E_PACKAGED_CONTROL_LISTENER_PORT="$acceptance_listener_port" \
      "$swift_products/PlainpostIOSPairingFixture" >"$acceptance_control_log" 2>&1 &
    acceptance_control_launcher_pid=$!
    acceptance_control_launcher_process_capture="$(acceptance_process_identity_capture \
      "$acceptance_control_launcher_pid" "$acceptance_launcher_executable" \
      "$acceptance_user_id" "$acceptance_process_inspector")"
    if [[ "$acceptance_control_launcher_process_capture" != present:<0->:<0-> &&
          "$acceptance_control_launcher_process_capture" != absent ]]; then
        rtk echo "The packaged control rtk launcher identity could not be pinned." >&2
        fail_packaged_mac_app
        return 1
    fi
    local control_port_line=""
    local control_token_line=""
    local control_port=""
    local control_token=""
    for _ in {1..100}; do
        acceptance_control_pid="$(acceptance_exact_process_id "$acceptance_process_inspector" PlainpostIOSPairingFixture || true)"
        control_port_line="$(rtk rg -m1 '^PLAINPOST_E2E_CONTROL_PORT=' "$acceptance_control_log" || true)"
        control_token_line="$(rtk rg -m1 '^PLAINPOST_E2E_CONTROL_TOKEN=' "$acceptance_control_log" || true)"
        [[ -n "$acceptance_control_pid" && -n "$control_port_line" &&
           -n "$control_token_line" ]] && break
        rtk sleep 0.1
    done
    control_port="${control_port_line#PLAINPOST_E2E_CONTROL_PORT=}"
    control_token="${control_token_line#PLAINPOST_E2E_CONTROL_TOKEN=}"
    local control_pid_found=false
    local control_port_valid=false
    local control_token_shape_valid=false
    if [[ -n "$acceptance_control_pid" ]] &&
       rtk kill -0 "$acceptance_control_pid" 2>/dev/null; then
        control_pid_found=true
    fi
    [[ "$control_port" == <1-65535> ]] && control_port_valid=true
    if rtk printf '%s\n' "$control_token" | rtk rg -q '^[A-Za-z0-9+/]{43}=$'; then
        control_token_shape_valid=true
    fi
    if [[ "$control_pid_found" != true || "$control_port_valid" != true ||
          "$control_token_shape_valid" != true ]]; then
        rtk echo "The packaged Mac control helper did not publish valid scoped configuration (pid-found=$control_pid_found port-valid=$control_port_valid token-shape-valid=$control_token_shape_valid)." >&2
        fail_packaged_mac_app
        return 1
    fi
    acceptance_control_process_capture="$(acceptance_process_identity_capture \
      "$acceptance_control_pid" "$acceptance_process_inspector" "$acceptance_user_id" \
      "$acceptance_process_inspector")"
    if [[ "$acceptance_control_process_capture" != present:<0->:<0-> ]]; then
        rtk echo "The packaged Mac control-helper identity could not be pinned at launch." >&2
        fail_packaged_mac_app
        return 1
    fi

    result_bundle="$acceptance_root/Plainpost.xcresult"
    checkpoint "xctestrun-copy-entry"
    if ! prepare_xctestrun_backup "$test_run" "$test_run_backup"; then
        fail_packaged_mac_app
        return 1
    fi
    rtk /usr/libexec/PlistBuddy -c "Add :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_E2E_INVITATION_BASE64 string $invitation" "$test_run"
    rtk /usr/libexec/PlistBuddy -c "Add :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_E2E_PAIRING_STORE_SERVICE string $mobile_store_service" "$test_run"
    rtk /usr/libexec/PlistBuddy -c "Add :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_E2E_CACHE_NAMESPACE string $mobile_cache_namespace" "$test_run"
    rtk /usr/libexec/PlistBuddy -c "Add :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_E2E_CONTROL_HOST string $fixture_host" "$test_run"
    rtk /usr/libexec/PlistBuddy -c "Add :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_E2E_CONTROL_PORT string $control_port" "$test_run"
    rtk /usr/libexec/PlistBuddy -c "Add :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_E2E_CONTROL_TOKEN string $control_token" "$test_run"
    unset invitation
    unset control_token
    if ! remove_injected_invitation_file "$invitation_file"; then
        rtk echo "The single-use invitation file could not be removed after injection." >&2
        fail_packaged_mac_app
        return 1
    fi
    [[ ! -e "$invitation_file" ]] || return 1
    checkpoint "xctestrun-injection-exit"

    selected_simulator_udid="$iphone_udid"
    mobile_pairing_service="$mobile_store_service"
    mobile_cache_namespace="$suffix"

    checkpoint "xcodebuild-test-entry"
    verify_pairing_products || return 1
    if ! rtk xcodebuild test-without-building -xctestrun "$test_run" \
      -destination "$iphone_destination" \
      -only-testing:PlainpostUITests/PlainpostUITests/testPairsAndSyncsWithPackagedMacApp \
      -resultBundlePath "$result_bundle"; then
        rtk echo "Packaged Mac to iPhone Simulator UI test did not complete successfully." >&2
        fail_packaged_mac_app
        return 1
    fi
    checkpoint "xcodebuild-test-exit"
    checkpoint "result-parse-entry"
    if ! rtk xcrun xcresulttool get test-results tests --path "$result_bundle" | \
      TEST_NAME='testPairsAndSyncsWithPackagedMacApp' rtk awk '
        $0 ~ "\\\"name\\\" : \\\"" ENVIRON["TEST_NAME"] "\\(\\)\\\"" { candidate = 1; next }
        candidate && /"result"/ {
            passed = $0 ~ /"result" : "Passed"/
            exit
        }
        END { exit(passed ? 0 : 1) }
    '; then
        rtk echo "Packaged Mac to iPhone Simulator UI test was missing, skipped, or did not report Passed." >&2
        fail_packaged_mac_app
        return 1
    fi
    checkpoint "result-parse-exit"
    preserve_result_bundle "$result_bundle" "mac-app-iphone"
    default_processes_after="$(default_packaged_app_processes)"
    if [[ "$default_processes_before" != "$default_processes_after" ]]; then
        rtk echo "The default packaged app process changed during the acceptance lane." >&2
        fail_packaged_mac_app
        return 1
    fi
    if ! assert_file_snapshots_unchanged "$acceptance_manifest_snapshot" "${manifest_paths[@]}" ||
       ! assert_file_snapshots_unchanged "$acceptance_database_snapshot" "${database_paths[@]}" ||
       ! assert_directory_tree_snapshot_unchanged "$acceptance_site_icon_snapshot" "$default_site_icon_directory"; then
        fail_packaged_mac_app
        return 1
    fi
    rtk echo "Packaged Mac acceptance PID $acceptance_pid owned exactly one TCP listener; default bundle process snapshot was unchanged."
    terminal_cleanup_manually cleanup_current
}

if [[ "${PLAINPOST_E2E_ONLY:-}" == "mac-app-iphone" ]]; then
    run_packaged_mac_app_test || exit 1
    exit 0
fi

if [[ "${PLAINPOST_E2E_ONLY:-}" == "mail-iphone" ]]; then
    run_host_fixture_test \
      testMailReadingOfflineSearchAndMutationReconciliationWithHostFixture \
      "Signed iPhone mail-reading/offline/search/mutation UI test" \
      "$iphone_destination" \
      "mail-iphone" || exit 1
    exit 0
fi

if [[ "${PLAINPOST_E2E_ONLY:-}" == "compact-rows-iphone" ]]; then
    PLAINPOST_E2E_COMPACT_ROWS=1 run_host_fixture_test \
      testCompactThreadRowsKeepLongContentToOneLine \
      "iPhone compact thread-row UI test" \
      "$iphone_destination" \
      "compact-rows-iphone" || exit 1
    exit 0
fi

if [[ "${PLAINPOST_E2E_ONLY:-}" == "search-route-iphone" ]]; then
    run_host_fixture_test \
      testLiveSearchResultOpensAuthoritativeReaderWithHostFixture \
      "Signed iPhone live-search reader-navigation UI test" \
      "$iphone_destination" \
      "search-route-iphone" || exit 1
    exit 0
fi

if [[ "${PLAINPOST_E2E_ONLY:-}" == "pairing-iphone" ]]; then
    run_host_fixture_test \
      testPairsWithHostFixtureWhenInvitationIsProvided \
      "Signed iPhone host-fixture pairing UI test" \
      "$iphone_destination" \
      "pairing-iphone" || exit 1
    exit 0
fi

if [[ "${PLAINPOST_E2E_ONLY:-}" == "pairing-ipad" ]]; then
    run_host_fixture_test \
      testPairsWithHostFixtureWhenInvitationIsProvided \
      "Signed iPad host-fixture pairing UI test" \
      "$ipad_destination" \
      "pairing-ipad" || exit 1
    exit 0
fi

if [[ "${PLAINPOST_E2E_ONLY:-}" == "mail-ipad" ]]; then
    run_host_fixture_test \
      testMailReadingOfflineSearchAndMutationReconciliationWithHostFixture \
      "Signed iPad two-column mail-reading/offline/search/mutation UI test" \
      "$ipad_destination" \
      "mail-ipad" || exit 1
    exit 0
fi

if [[ "${PLAINPOST_E2E_ONLY:-}" == "functional-parity-iphone" ]]; then
    run_host_fixture_test \
      testFunctionalMobileParityWithHostFixture \
      "Signed iPhone functional mobile parity UI test" \
      "$iphone_destination" \
      "functional-parity-iphone" || exit 1
    exit 0
fi

if [[ "${PLAINPOST_E2E_ONLY:-}" == "functional-parity-ipad" ]]; then
    run_host_fixture_test \
      testFunctionalMobileParityWithHostFixture \
      "Signed iPad functional mobile parity UI test" \
      "$ipad_destination" \
      "functional-parity-ipad" || exit 1
    exit 0
fi

if [[ "${PLAINPOST_E2E_ONLY:-}" == "compose-iphone" ]]; then
    run_host_fixture_test \
      testComposeDraftConflictAttachmentUndoAndUncertainLifecycleWithHostFixture \
      "Signed iPhone compose/draft/attachment/send UI test" \
      "$iphone_destination" \
      "compose-iphone" || exit 1
    exit 0
fi

if [[ "${PLAINPOST_E2E_ONLY:-}" == "compose-ipad" ]]; then
    run_host_fixture_test \
      testComposeDraftConflictAttachmentUndoAndUncertainLifecycleWithHostFixture \
      "Signed iPad compose/draft/attachment/send UI test" \
      "$ipad_destination" \
      "compose-ipad" || exit 1
    exit 0
fi

if [[ "${PLAINPOST_E2E_ONLY:-}" == "accessibility-iphone" ]]; then
    run_host_fixture_test \
      testAdaptiveAccessibilityAndKeyboardFocusWithHostFixture \
      "Signed iPhone accessibility, landscape, Return, and focus UI test" \
      "$iphone_destination" \
      "accessibility-iphone" || exit 1
    exit 0
fi

if [[ "${PLAINPOST_E2E_ONLY:-}" == "adaptive-phone-375" ]]; then
    run_host_fixture_test \
      testNarrowPhoneAcceptanceMatrixWithHostFixture \
      "Signed 375-point iPhone portrait acceptance UI test" \
      "$iphone_destination" \
      "adaptive-phone-375" \
      "375" || exit 1
    exit 0
fi

if [[ "${PLAINPOST_E2E_ONLY:-}" == "adaptive-phone-393" ]]; then
    run_host_fixture_test \
      testNarrowPhoneAcceptanceMatrixWithHostFixture \
      "Signed 393-point iPhone portrait acceptance UI test" \
      "$iphone_destination" \
      "adaptive-phone-393" \
      "393" || exit 1
    exit 0
fi

if [[ "${PLAINPOST_E2E_ONLY:-}" == "adaptive-phone-430" ]]; then
    run_host_fixture_test \
      testNarrowPhoneAcceptanceMatrixWithHostFixture \
      "Signed 430-point iPhone portrait acceptance UI test" \
      "$iphone_destination" \
      "adaptive-phone-430" \
      "430" || exit 1
    exit 0
fi

if [[ "${PLAINPOST_E2E_ONLY:-}" == "adaptive-split-ipad" ]]; then
    run_host_fixture_test \
      testAdaptiveAccessibilityAndKeyboardFocusWithHostFixture \
      "Signed iPad representative Split View-width UI test" \
      "$ipad_destination" \
      "adaptive-split-ipad" \
      "520" || exit 1
    exit 0
fi

if [[ "${PLAINPOST_E2E_ONLY:-}" == "adaptive-stage-ipad" ]]; then
    run_host_fixture_test \
      testAdaptiveAccessibilityAndKeyboardFocusWithHostFixture \
      "Signed iPad representative Stage Manager-width UI test" \
      "$ipad_destination" \
      "adaptive-stage-ipad" \
      "760" || exit 1
    exit 0
fi

run_signed_native_tests "$iphone_destination" "Signed iPhone native tests" "native-iphone"
run_signed_native_tests "$ipad_destination" "Signed iPad native tests" "native-ipad"
run_host_fixture_test \
  testPairsWithHostFixtureWhenInvitationIsProvided \
  "Signed iPhone host-fixture pairing UI test" \
  "$iphone_destination" \
  "pairing-iphone"
run_host_fixture_test \
  testMailReadingOfflineSearchAndMutationReconciliationWithHostFixture \
  "Signed iPhone mail-reading/offline/search/mutation UI test" \
  "$iphone_destination" \
  "mail-iphone"
reset_simulator "$ipad_udid"
run_host_fixture_test \
  testPairsWithHostFixtureWhenInvitationIsProvided \
  "Signed iPad host-fixture pairing UI test" \
  "$ipad_destination" \
  "pairing-ipad"
reset_simulator "$ipad_udid"
run_host_fixture_test \
  testMailReadingOfflineSearchAndMutationReconciliationWithHostFixture \
  "Signed iPad two-column mail-reading/offline/search/mutation UI test" \
  "$ipad_destination" \
  "mail-ipad"
run_host_fixture_test \
  testFunctionalMobileParityWithHostFixture \
  "Signed iPhone functional mobile parity UI test" \
  "$iphone_destination" \
  "functional-parity-iphone"
reset_simulator "$ipad_udid"
run_host_fixture_test \
  testFunctionalMobileParityWithHostFixture \
  "Signed iPad functional mobile parity UI test" \
  "$ipad_destination" \
  "functional-parity-ipad"
run_host_fixture_test \
  testComposeDraftConflictAttachmentUndoAndUncertainLifecycleWithHostFixture \
  "Signed iPhone compose/draft/attachment/send UI test" \
  "$iphone_destination" \
  "compose-iphone"
reset_simulator "$ipad_udid"
run_host_fixture_test \
  testComposeDraftConflictAttachmentUndoAndUncertainLifecycleWithHostFixture \
  "Signed iPad compose/draft/attachment/send UI test" \
  "$ipad_destination" \
  "compose-ipad"
run_host_fixture_test \
  testAdaptiveAccessibilityAndKeyboardFocusWithHostFixture \
  "Signed iPhone accessibility, landscape, Return, and focus UI test" \
  "$iphone_destination" \
  "accessibility-iphone"
run_host_fixture_test \
  testNarrowPhoneAcceptanceMatrixWithHostFixture \
  "Signed 375-point iPhone portrait acceptance UI test" \
  "$iphone_destination" \
  "adaptive-phone-375" \
  "375"
run_host_fixture_test \
  testNarrowPhoneAcceptanceMatrixWithHostFixture \
  "Signed 393-point iPhone portrait acceptance UI test" \
  "$iphone_destination" \
  "adaptive-phone-393" \
  "393"
run_host_fixture_test \
  testNarrowPhoneAcceptanceMatrixWithHostFixture \
  "Signed 430-point iPhone portrait acceptance UI test" \
  "$iphone_destination" \
  "adaptive-phone-430" \
  "430"
reset_simulator "$ipad_udid"
run_host_fixture_test \
  testAdaptiveAccessibilityAndKeyboardFocusWithHostFixture \
  "Signed iPad representative Split View-width UI test" \
  "$ipad_destination" \
  "adaptive-split-ipad" \
  "520"
reset_simulator "$ipad_udid"
run_host_fixture_test \
  testAdaptiveAccessibilityAndKeyboardFocusWithHostFixture \
  "Signed iPad representative Stage Manager-width UI test" \
  "$ipad_destination" \
  "adaptive-stage-ipad" \
  "760"
