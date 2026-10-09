#!/bin/zsh
set -euo pipefail

script_path="${0:A}"
script_directory="${0:A:h}"
source "$script_directory/lib/ios-pairing-invitation.sh"
source "$script_directory/lib/terminal-cleanup-traps.sh"
source "$script_directory/lib/acceptance-runtime-cleanup-status.sh"
source "$script_directory/lib/ios-e2e-xctestrun.sh"
source "$script_directory/lib/ios-e2e-log-redaction.sh"
source "$script_directory/lib/ios-e2e-simulator-reset.sh"
source "$script_directory/lib/ios-pairing-process-guard.sh"
source "$script_directory/lib/ios-e2e-visual-environment.sh"

assert_process_identity_guard_contract() {
    (
        /bin/sleep 30 &
        local process_id=$!
        trap 'kill "$process_id" 2>/dev/null || true; wait "$process_id" 2>/dev/null || true' EXIT
        acceptance_process_identity_capture() { rtk printf '%s\n' absent }
        acceptance_process_identity_state() { rtk printf '%s\n' absent }
        terminate_acceptance_process "$process_id" /definitely/not/the/process "$(rtk id -u)" "" 1 unused
        rtk kill -0 "$process_id"
        rtk kill "$process_id"
        wait "$process_id" 2>/dev/null || true
        trap - EXIT
    )

    (
        rtk() {
            local command="$1"
            shift
            case "$command" in
                realpath)
                    case "$1" in
                        /symlinked/helper|/mapped/helper)
                            print -r -- /canonical/helper
                            ;;
                        *)
                            return 1
                            ;;
                    esac
                    ;;
                pgrep)
                    print -r -- 4321
                    ;;
                lsof)
                    print -r -- p4321
                    print -r -- n/mapped/helper
                    ;;
                awk)
                    local line=""
                    while IFS= read -r line; do
                        [[ "$line" == n* ]] || continue
                        print -r -- "${line#n}"
                        return 0
                    done
                    return 1
                    ;;
                echo)
                    print -r -- "$1"
                    ;;
                *)
                    return 1
                    ;;
            esac
        }
        [[ "$(acceptance_exact_process_id /symlinked/helper Helper)" == 4321 ]]
        ! acceptance_exact_process_id /missing/helper Helper
    )

    (
        /bin/sleep 30 &
        local process_id=$!
        trap 'rtk kill "$process_id" 2>/dev/null || true; wait "$process_id" 2>/dev/null || true' EXIT
        acceptance_process_identity_capture() { return 1 }
        terminate_acceptance_process "$process_id" /opt/homebrew/bin/rtk \
          "$(rtk id -u)" "" 1 unused absent
        rtk kill -0 "$process_id"
        rtk kill "$process_id"
        wait "$process_id" 2>/dev/null || true
        trap - EXIT
    )

    (
        /bin/sleep 30 &
        local process_id=$!
        local observation_state="$(rtk mktemp -t plainpost-process-identity-transition)"
        trap 'rtk rm -f "$observation_state"; rtk kill "$process_id" 2>/dev/null || true; wait "$process_id" 2>/dev/null || true' EXIT
        acceptance_process_identity_capture() { rtk printf '%s\n' absent }
        acceptance_process_identity_state() {
            if [[ -f "$observation_state" ]]; then
                rtk rm -f "$observation_state"
                rtk printf '%s\n' absent
            else
                rtk printf '%s\n' present
            fi
        }
        terminate_acceptance_process "$process_id" /bin/sleep "$(rtk id -u)" "" 1 unused
        rtk kill -0 "$process_id"
        rtk kill "$process_id"
        wait "$process_id" 2>/dev/null || true
        trap - EXIT
    )

    (
        /bin/sleep 30 &
        local process_id=$!
        trap 'rtk kill "$process_id" 2>/dev/null || true; wait "$process_id" 2>/dev/null || true' EXIT
        acceptance_process_identity_capture() { return 1 }
        acceptance_process_identity_state() {
            [[ "$5" == 1234 && "$6" == 567 ]]
            rtk printf '%s\n' absent
        }
        terminate_acceptance_process "$process_id" /bin/sleep "$(rtk id -u)" "" 1 unused \
          present:1234:567
        rtk kill -0 "$process_id"
        rtk kill "$process_id"
        wait "$process_id" 2>/dev/null || true
        trap - EXIT
    )

    (
        /bin/sleep 30 &
        local process_id=$!
        acceptance_process_identity_capture() { rtk printf '%s\n' present:1234:567 }
        acceptance_process_identity_state() {
            if rtk kill -0 "$1" 2>/dev/null; then
                rtk printf '%s\n' present
            else
                rtk printf '%s\n' absent
            fi
        }
        terminate_acceptance_process "$process_id" /bin/sleep "$(rtk id -u)" "" 10 unused
        ! rtk kill -0 "$process_id" 2>/dev/null
    )
}

if [[ "${1:-}" == "--process-guard-contract" ]]; then
    assert_process_identity_guard_contract
    exit 0
fi

fixture_file="$(rtk mktemp -t plainpost-ios-pairing-invitation)"
trap 'rtk rm -f -- "$fixture_file"' EXIT INT TERM

payload="$(rtk printf %s '{"protocolVersion":1,"endpoint":{"host":{"port":9443}}}' | rtk base64)"
rtk printf %s "$payload" >"$fixture_file"

forwarded="$(read_ios_pairing_invitation "$fixture_file")"
[[ "$forwarded" == "$payload" ]]
[[ "$(rtk printf %s "$forwarded" | rtk shasum -a 256 | rtk awk '{ print $1 }')" == \
   "$(rtk shasum -a 256 "$fixture_file" | rtk awk '{ print $1 }')" ]]

signal_fixture_marker_file=""
signal_fixture_child_pid_file=""
signal_fixture_state_file=""
signal_fixture_cleanup_should_fail=0
signal_fixture_cleanup_blocks=0
signal_fixture_sleep_pid=""
signal_fixture_runs_simulator_reset=0

cleanup_signal_fixture() {
    print -r -- cleanup-started >>"$signal_fixture_marker_file"
    if (( signal_fixture_runs_simulator_reset )); then
        reset_and_uninstall_ios_e2e_app \
          simulator-udid \
          com.marynavdovenko.Plainpost.iOS \
          com.marynavdovenko.Plainpost.MobileClient.E2E.151f5a52-613f-4547-ad7e-985575bae599 \
          151f5a52-613f-4547-ad7e-985575bae599
    fi
    if (( signal_fixture_cleanup_blocks )); then
        print -r -- cleanup-blocked >>"$signal_fixture_marker_file"
        while [[ -z "$terminal_cleanup_signal_status" ]]; do
            /bin/sleep 0.01
        done
        print -r -- cleanup-after-block >>"$signal_fixture_marker_file"
    fi
    if (( signal_fixture_cleanup_should_fail )); then
        false
        print -r -- cleanup-after-failure >>"$signal_fixture_marker_file"
    fi
    if [[ -s "$signal_fixture_child_pid_file" ]]; then
        local child_pid="$(<"$signal_fixture_child_pid_file")"
        kill "$child_pid" 2>/dev/null || true
    fi
    rtk rm -f -- "$signal_fixture_state_file"
    print -r -- cleanup-finished >>"$signal_fixture_marker_file"
    rtk rm -f -- "$fixture_file"
    (( signal_fixture_cleanup_should_fail )) && return 79
}

prepare_signal_fixture() {
    signal_fixture_marker_file="$1"
    signal_fixture_child_pid_file="$2"
    signal_fixture_state_file="$3"
    signal_fixture_cleanup_should_fail="$4"
    signal_fixture_cleanup_blocks="$5"
    trap - INT TERM
    print -r -- owned-state >"$signal_fixture_state_file"
    /bin/sleep 30 &
    signal_fixture_sleep_pid=$!
    print -r -- "$signal_fixture_sleep_pid" >"$signal_fixture_child_pid_file"
}

normal_failure_marker=""

cleanup_normal_failure_fixture() {
    print -r -- normal-cleanup >>"$normal_failure_marker"
    rtk rm -f -- "$fixture_file"
    return 71
}

prepare_normal_failure_fixture() {
    normal_failure_marker="$1"
}

sequential_manual_marker=""

cleanup_sequential_manual_fixture() {
    print -r -- manual-cleanup >>"$sequential_manual_marker"
    rtk rm -f -- "$fixture_file"
}

if [[ "${1:-}" == "--signal-fixture" ]]; then
    prepare_signal_fixture "$2" "$3" "$4" "$5" 0
    eval "$(terminal_cleanup_trap_setup cleanup_signal_fixture)"
    wait "$signal_fixture_sleep_pid"
    print -r -- post-signal >>"$signal_fixture_marker_file"
    exit 0
fi
if [[ "${1:-}" == "--reset-signal-fixture" ]]; then
    prepare_signal_fixture "$2" "$3" "$4" 0 0
    signal_fixture_runs_simulator_reset=1
    reset_and_uninstall_ios_e2e_app() {
        print -r -- reset-launched >>"$signal_fixture_marker_file"
        print -r -- app-uninstalled >>"$signal_fixture_marker_file"
    }
    eval "$(terminal_cleanup_trap_setup cleanup_signal_fixture)"
    wait "$signal_fixture_sleep_pid"
    print -r -- post-signal >>"$signal_fixture_marker_file"
    exit 0
fi
if [[ "${1:-}" == "--cleanup-block-fixture" ]]; then
    prepare_signal_fixture "$2" "$3" "$4" 0 1
    eval "$(terminal_cleanup_trap_setup cleanup_signal_fixture)"
    exit 0
fi
if [[ "${1:-}" == "--manual-cleanup-block-fixture" ]]; then
    prepare_signal_fixture "$2" "$3" "$4" 0 1
    eval "$(terminal_cleanup_trap_setup cleanup_signal_fixture)"
    terminal_cleanup_manually cleanup_signal_fixture
    print -r -- post-signal >>"$signal_fixture_marker_file"
    exit 0
fi
if [[ "${1:-}" == "--two-manual-cleanup-fixture" ]]; then
    sequential_manual_marker="$2"
    eval "$(terminal_cleanup_trap_setup cleanup_sequential_manual_fixture)"
    terminal_cleanup_manually cleanup_sequential_manual_fixture
    terminal_cleanup_manually cleanup_sequential_manual_fixture
    trap - EXIT
    exit 0
fi
if [[ "${1:-}" == "--normal-failure-fixture" ]]; then
    prepare_normal_failure_fixture "$2"
    eval "$(terminal_cleanup_trap_setup cleanup_normal_failure_fixture)"
    exit 0
fi

assert_signal_cleanup() {
    local signal_name="$1"
    local expected_status="$2"
    local fixture_mode="${3:---signal-fixture}"
    local started_at=$SECONDS
    local marker_file="$(rtk mktemp -t plainpost-ios-pairing-signal-marker)"
    local child_pid_file="$(rtk mktemp -t plainpost-ios-pairing-signal-child)"
    local state_file="$(rtk mktemp -t plainpost-ios-pairing-signal-state)"
    rtk rm -f -- "$marker_file" "$child_pid_file" "$state_file"
    /bin/zsh "$script_path" "$fixture_mode" "$marker_file" "$child_pid_file" "$state_file" 1 &
    local fixture_pid=$!
    for _ in {1..100}; do
        [[ -s "$child_pid_file" ]] && break
        /bin/sleep 0.01
    done
    [[ -s "$child_pid_file" ]]
    kill -"$signal_name" "$fixture_pid"
    local fixture_status=0
    wait "$fixture_pid" || fixture_status=$?
    (( SECONDS - started_at < 5 ))
    [[ "$fixture_status" == "$expected_status" ]]
    [[ "$(rtk rg -c '^cleanup-started$' "$marker_file")" == "1" ]]
    if [[ "$fixture_mode" == "--signal-fixture" ]]; then
        [[ "$(rtk rg -c '^cleanup-after-failure$' "$marker_file")" == "1" ]]
    else
        ! rtk rg -q '^cleanup-after-failure$' "$marker_file"
    fi
    [[ "$(rtk rg -c '^cleanup-finished$' "$marker_file")" == "1" ]]
    if [[ "$fixture_mode" == "--reset-signal-fixture" ]]; then
        [[ "$(rtk rg -c '^reset-launched$' "$marker_file")" == "1" ]]
        [[ "$(rtk rg -c '^app-uninstalled$' "$marker_file")" == "1" ]]
    fi
    ! rtk rg -q '^post-signal$' "$marker_file"
    local child_pid="$(<"$child_pid_file")"
    ! kill -0 "$child_pid" 2>/dev/null
    [[ ! -e "$state_file" ]]
    rtk rm -f -- "$marker_file" "$child_pid_file" "$state_file"
}

assert_signal_cleanup INT 130
assert_signal_cleanup TERM 143
assert_signal_cleanup TERM 143 --reset-signal-fixture

assert_signal_during_cleanup() {
    local signal_name="$1"
    local expected_status="$2"
    local fixture_mode="$3"
    local marker_file="$(rtk mktemp -t plainpost-ios-pairing-cleanup-marker)"
    local child_pid_file="$(rtk mktemp -t plainpost-ios-pairing-cleanup-child)"
    local state_file="$(rtk mktemp -t plainpost-ios-pairing-cleanup-state)"
    rtk rm -f -- "$marker_file" "$child_pid_file" "$state_file"
    /bin/zsh "$script_path" "$fixture_mode" "$marker_file" "$child_pid_file" "$state_file" &
    local fixture_pid=$!
    for _ in {1..100}; do
        [[ "$(rtk rg -c '^cleanup-blocked$' "$marker_file" 2>/dev/null || true)" == "1" ]] && break
        /bin/sleep 0.01
    done
    [[ "$(rtk rg -c '^cleanup-blocked$' "$marker_file")" == "1" ]]
    local started_at=$SECONDS
    kill -"$signal_name" "$fixture_pid"
    local fixture_status=0
    wait "$fixture_pid" || fixture_status=$?
    (( SECONDS - started_at < 5 ))
    [[ "$fixture_status" == "$expected_status" ]]
    [[ "$(rtk rg -c '^cleanup-started$' "$marker_file")" == "1" ]]
    [[ "$(rtk rg -c '^cleanup-blocked$' "$marker_file")" == "1" ]]
    [[ "$(rtk rg -c '^cleanup-after-block$' "$marker_file")" == "1" ]]
    [[ "$(rtk rg -c '^cleanup-finished$' "$marker_file")" == "1" ]]
    ! rtk rg -q '^post-signal$' "$marker_file"
    local child_pid="$(<"$child_pid_file")"
    ! kill -0 "$child_pid" 2>/dev/null
    [[ ! -e "$state_file" ]]
    rtk rm -f -- "$marker_file" "$child_pid_file" "$state_file"
}

assert_signal_during_cleanup INT 130 --cleanup-block-fixture
assert_signal_during_cleanup TERM 143 --cleanup-block-fixture
assert_signal_during_cleanup INT 130 --manual-cleanup-block-fixture
assert_signal_during_cleanup TERM 143 --manual-cleanup-block-fixture

assert_two_sequential_manual_cleanups() {
    local marker_file="$(rtk mktemp -t plainpost-ios-pairing-sequential-manual)"
    rtk rm -f -- "$marker_file"
    local fixture_status=0
    /bin/zsh "$script_path" --two-manual-cleanup-fixture "$marker_file" || fixture_status=$?
    [[ "$fixture_status" == "0" ]]
    [[ "$(rtk rg -c '^manual-cleanup$' "$marker_file")" == "2" ]]
    rtk rm -f -- "$marker_file"
}

assert_two_sequential_manual_cleanups

normal_failure_marker="$(rtk mktemp -t plainpost-ios-pairing-normal-cleanup)"
rtk rm -f -- "$normal_failure_marker"

assert_runtime_cleanup_status_waiting() {
    local status_file="$(rtk mktemp -t plainpost-runtime-cleanup-status)"
    rtk rm -f -- "$status_file"

    print -r -- success >"$status_file"
    wait_for_acceptance_runtime_cleanup_status "$status_file" 1

    print -r -- 'failure transport: Keychain status -25244' >"$status_file"
    local failure_status=0
    wait_for_acceptance_runtime_cleanup_status "$status_file" 1 || failure_status=$?
    [[ "$failure_status" == "1" ]]
    [[ "$(<"$status_file")" == 'failure transport: Keychain status -25244' ]]

    rtk rm -f -- "$status_file"
    local started_at=$SECONDS
    local timeout_status=0
    wait_for_acceptance_runtime_cleanup_status "$status_file" 1 || timeout_status=$?
    [[ "$timeout_status" == "2" ]]
    (( SECONDS - started_at < 5 ))
}

assert_runtime_cleanup_status_waiting

assert_simulator_reset_contract() {
    local directory="$(rtk mktemp -d -t plainpost-simulator-reset-contract)"
    local container="$directory/data"
    local evidence="$directory/evidence.status"
    local namespace="151f5a52-613f-4547-ad7e-985575bae599"
    local service="com.marynavdovenko.Plainpost.MobileClient.E2E.$namespace"
    local bundle="com.marynavdovenko.Plainpost.iOS"
    local uninstall_count=0
    local launch_should_fail=0
    local uninstalled=0
    rtk mkdir -p "$container/Library/Application Support"

    ios_e2e_get_data_container() {
        (( uninstalled )) || rtk echo "$container"
    }
    ios_e2e_launch_reset() {
        (( launch_should_fail )) && return 70
        local marker_directory="$container/Library/Application Support/PlainpostE2EReset"
        rtk mkdir -p "$marker_directory"
        rtk printf '%s\n' success >"$marker_directory/${namespace:u}.status"
        rtk chmod 0600 "$marker_directory/${namespace:u}.status"
    }
    ios_e2e_terminate_app() { return 0 }
    ios_e2e_uninstall_app() {
        (( uninstall_count += 1 ))
        uninstalled=1
    }

    reset_and_uninstall_ios_e2e_app simulator-udid "$bundle" "$service" "$namespace" "$evidence"
    [[ "$uninstall_count" == "1" ]]
    [[ "$(<"$evidence")" == "success" ]]
    [[ "$(rtk stat -f '%Lp' "$evidence")" == "600" ]]

    uninstall_count=0
    uninstalled=0
    launch_should_fail=1
    ! reset_and_uninstall_ios_e2e_app simulator-udid "$bundle" "$service" "$namespace" "$evidence"
    [[ "$uninstall_count" == "1" ]]
    rtk rm -rf -- "$directory"
}

assert_simulator_reset_contract

assert_visual_environment_forwarding_contract() {
    local directory="$(rtk mktemp -d -t plainpost-visual-environment-contract)"
    local run="$directory/test.xctestrun"
    rtk /usr/libexec/PlistBuddy -c 'Add :PlainpostUITests dict' "$run"
    rtk /usr/libexec/PlistBuddy -c 'Add :PlainpostUITests:TestingEnvironmentVariables dict' "$run"

    PLAINPOST_VISUAL_DYNAMIC_TYPE=accessibility3 \
      PLAINPOST_VISUAL_DARK_MODE=1 \
      PLAINPOST_VISUAL_REDUCE_TRANSPARENCY=1 \
      ios_e2e_forward_visual_environment "$run"

    [[ "$(rtk /usr/libexec/PlistBuddy -c 'Print :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_VISUAL_DYNAMIC_TYPE' "$run")" == accessibility3 ]]
    [[ "$(rtk /usr/libexec/PlistBuddy -c 'Print :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_VISUAL_DARK_MODE' "$run")" == 1 ]]
    [[ "$(rtk /usr/libexec/PlistBuddy -c 'Print :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_VISUAL_REDUCE_TRANSPARENCY' "$run")" == 1 ]]

    rtk /usr/libexec/PlistBuddy -c 'Delete :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_VISUAL_DYNAMIC_TYPE' "$run"
    rtk /usr/libexec/PlistBuddy -c 'Delete :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_VISUAL_DARK_MODE' "$run"
    PLAINPOST_VISUAL_DYNAMIC_TYPE=unsupported \
      PLAINPOST_VISUAL_DARK_MODE=true \
      ios_e2e_forward_visual_environment "$run"
    ! rtk /usr/libexec/PlistBuddy -c 'Print :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_VISUAL_DYNAMIC_TYPE' "$run"
    ! rtk /usr/libexec/PlistBuddy -c 'Print :PlainpostUITests:TestingEnvironmentVariables:PLAINPOST_VISUAL_DARK_MODE' "$run"
    rtk rm -rf -- "$directory"
}

assert_visual_environment_forwarding_contract

assert_xctestrun_recovery_contract() {
    local directory="$(rtk mktemp -d -t plainpost-xctestrun-contract)"
    local run="$directory/test.xctestrun"
    local backup="$run.plainpost-backup"
    rtk printf '%s\n' clean >"$run"
    rtk printf '%s\n' stale >"$backup"
    ! prepare_xctestrun_backup "$run" "$backup"
    [[ "$(<"$backup")" == stale ]]

    rtk rm -f -- "$backup"
    rtk ln -s "$directory/missing-backup-target" "$backup"
    ! prepare_xctestrun_backup "$run" "$backup"
    [[ -L "$backup" ]]
    rtk rm -f -- "$backup"
    local dangling_run="$directory/dangling.xctestrun"
    rtk ln -s "$directory/missing-run-target" "$dangling_run"
    ! prepare_xctestrun_backup "$dangling_run" "$backup"
    [[ ! -e "$backup" && ! -L "$backup" ]]

    rtk printf '%s\n' PLAINPOST_E2E_CONTROL_TOKEN=secret >"$run"
    ! prepare_xctestrun_backup "$run" "$backup"
    [[ ! -e "$backup" ]]
    rtk printf '%s\n' PLAINPOST_VISUAL_REDUCE_MOTION=1 >"$run"
    ! prepare_xctestrun_backup "$run" "$backup"
    [[ ! -e "$backup" ]]

    rtk printf '%s\n' clean >"$run"
    prepare_xctestrun_backup "$run" "$backup"
    rtk printf '%s\n' corrupted >"$backup"
    rtk printf '%s\n' PLAINPOST_E2E_INVITATION_BASE64=secret >"$run"
    ! restore_xctestrun_backup "$run" "$backup"
    [[ -e "$backup" ]]
    [[ -e "${backup}.sha256" ]]

    rtk rm -f -- "$backup" "${backup}.sha256"
    rtk printf '%s\n' PLAINPOST_E2E_INVITATION_BASE64 >"$run"
    rtk printf '%s\n' clean >"$run"
    prepare_xctestrun_backup "$run" "$backup"
    rtk printf '%s\n' PLAINPOST_E2E_INVITATION_BASE64 >"$run"
    xctestrun_restore_move() { return 73 }
    ! restore_xctestrun_backup "$run" "$backup"
    [[ -e "$backup" ]]

    xctestrun_restore_move() { rtk mv "$1" "$2" }
    xctestrun_unique_suffix() { rtk echo contract-candidate }
    local candidate="$run.plainpost-restore.contract-candidate"
    rtk ln -s "$directory/missing-candidate-target" "$candidate"
    ! restore_xctestrun_backup "$run" "$backup"
    [[ -L "$candidate" ]]
    [[ -e "$backup" ]]
    rtk rm -f -- "$candidate"
    restore_xctestrun_backup "$run" "$backup"
    [[ ! -e "$backup" ]]
    [[ ! -e "${backup}.sha256" ]]
    [[ "$(rtk shasum -a 256 "$run" | rtk awk '{print $1}')" == "$(rtk printf '%s\n' clean | rtk shasum -a 256 | rtk awk '{print $1}')" ]]
    ! xctestrun_contains_plainpost_e2e_values "$run"

    local invitation="$directory/invitation"
    rtk printf '%s' payload >"$invitation"
    remove_injected_invitation_file "$invitation"
    [[ ! -e "$invitation" ]]
    rtk rm -rf -- "$directory"
}

assert_xctestrun_recovery_contract

assert_fixture_log_redaction() {
    local source_log="$(rtk mktemp -t plainpost-fixture-secret-log)"
    local redacted_log="$(rtk mktemp -t plainpost-fixture-redacted-log)"
    rtk printf '%s\n' \
      'ordinary diagnostic' \
      'PLAINPOST_E2E_INVITATION_BASE64=invitation-secret' \
      'PLAINPOST_E2E_CONTROL_TOKEN=control-secret' >"$source_log"
    redact_ios_fixture_log "$source_log" >"$redacted_log"
    rtk rg -q 'ordinary diagnostic' "$redacted_log"
    ! rtk rg -q 'invitation-secret|control-secret' "$redacted_log"
    rtk rg -q '\[REDACTED\]' "$redacted_log"
    rtk rm -f -- "$source_log" "$redacted_log"
}

assert_fixture_log_redaction

assert_functional_parity_acceptance_contract() {
    local wrapper="$script_directory/test-ios-pairing-e2e.sh"
    local ui_test="$PWD/Apps/PlainpostiOS/PlainpostUITests/PlainpostUITests.swift"

    rtk rg -q 'method=compose\.sendDirect outcome=success' "$wrapper"
    ! rtk rg -q 'commit_count=.*compose\.sendCommit' "$wrapper"
    rtk rg -q 'testFunctionalMobileParityWithHostFixture' "$wrapper"
    rtk rg -q 'status-only reconciliation' "$wrapper"
    rtk rg -q 'waitForFixtureCounter\(' "$ui_test"
    ! rtk rg -q 'XCTAssertEqual\(try fixtureCounter\("delayed-body-hold-count"\), 1\)' "$ui_test"
}

assert_functional_parity_acceptance_contract

assert_named_lane_failure_propagation_contract() {
    local wrapper="$script_directory/test-ios-pairing-e2e.sh"
    local -a named_lanes=(
        mac-app-iphone
        mail-iphone
        pairing-iphone
        pairing-ipad
        mail-ipad
        functional-parity-iphone
        functional-parity-ipad
        compose-iphone
        compose-ipad
        accessibility-iphone
        adaptive-phone-375
        adaptive-phone-393
        adaptive-phone-430
        adaptive-split-ipad
        adaptive-stage-ipad
    )

    [[ "${#named_lanes[@]}" == "15" ]]
    local lane
    for lane in "${named_lanes[@]}"; do
        rtk awk -v lane="$lane" '
            $0 ~ "PLAINPOST_E2E_ONLY:-.*" lane {
                in_lane = 1
                next
            }
            in_lane && /\|\| exit 1/ { fail_closed = 1 }
            in_lane && /^fi$/ { found = 1; exit }
            END { exit(found && fail_closed ? 0 : 1) }
        ' "$wrapper"
    done
}

assert_named_lane_failure_propagation_contract
normal_cleanup_status=0
/bin/zsh "$script_path" --normal-failure-fixture "$normal_failure_marker" || normal_cleanup_status=$?
[[ "$normal_cleanup_status" == "71" ]]
[[ "$(rtk rg -c '^normal-cleanup$' "$normal_failure_marker")" == "1" ]]
rtk rm -f -- "$normal_failure_marker"
