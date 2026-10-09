#!/usr/bin/env bash
set -euo pipefail

bundle="${1:?Application bundle path is required.}"
launch_agent_label="${2:-com.marynavdovenko.Plainpost.BackgroundAgent}"
mach_service_name="com.marynavdovenko.Plainpost.Service"
script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${PLAINPOST_BUILD_CONFIGURATION:-debug}"
fixture_contract_script="$script_root/Scripts/lib/plainpost-package-fixture-contract.sh"
if [[ ! -f "$fixture_contract_script" || -L "$fixture_contract_script" ]]; then
    echo "Missing Plainpost package fixture contract." >&2
    exit 1
fi
# shellcheck source=Scripts/lib/plainpost-package-fixture-contract.sh
source "$fixture_contract_script"

if [[ "$bundle" == "/" ||
      "$bundle" != /* ||
      "$bundle" != *.app ]]; then
    echo "Refusing to stop processes for unsafe bundle path: $bundle" >&2
    exit 1
fi
if [[ ! "$launch_agent_label" =~ ^[[:alnum:]][[:alnum:]._-]*$ ]]; then
    echo "Refusing unsafe LaunchAgent label: $launch_agent_label" >&2
    exit 1
fi

reject_runtime_stop_fixture_mode() {
    echo "$1" >&2
    exit 1
}

validate_runtime_stop_fixture_overrides() {
    local requested_mode="${PLAINPOST_RUNTIME_STOP_TEST_MODE:-}"
    local requested_root="${PLAINPOST_RUNTIME_STOP_TEST_ROOT:-}"
    local launchctl_override_present=false

    [[ -z "${PLAINPOST_RUNTIME_STOP_TEST_LAUNCHCTL_COMMAND+x}" ]] ||
        launchctl_override_present=true
    if [[ "$requested_mode" != "1" ]]; then
        if [[ -n "$requested_mode" ||
              -n "$requested_root" ||
              "$launchctl_override_present" == "true" ]]; then
            reject_runtime_stop_fixture_mode \
                "Runtime-stop fixture inputs require structural fixture mode."
        fi
    fi
}

validate_runtime_stop_fixture_overrides
plainpost_validate_package_fixture \
    "$script_root" \
    "$configuration" \
    "${PLAINPOST_RUNTIME_STOP_TEST_MODE:-}" \
    "${PLAINPOST_RUNTIME_STOP_TEST_ROOT:-}"
runtime_stop_fixture_mode="$plainpost_package_fixture_mode"

launchctl_command="/bin/launchctl"
if [[ "$runtime_stop_fixture_mode" == "true" ]]; then
    plainpost_validate_fixture_bundle_path \
        "$bundle" \
        "Runtime-stop fixture bundle"
    launchctl_command="$(
        plainpost_fixture_tool_path \
            "${PLAINPOST_RUNTIME_STOP_TEST_LAUNCHCTL_COMMAND:-}" \
            "Fixture launchctl command"
    )"
fi

targets=(
    "$bundle/Contents/MacOS/Plainpost"
    "$bundle/Contents/Library/Helpers/PlainpostBackgroundAgent.app/Contents/MacOS/PlainpostBackgroundAgent"
    "$bundle/Contents/Library/Helpers/PlainpostService.app/Contents/MacOS/PlainpostService"
)

# True when the process maps the executable at this exact path as program
# text, whatever its argv[0] says.
process_runs_executable() {
    local pid="$1"
    local executable="$2"
    local physical="$3"
    local text_paths
    text_paths="$(/usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null)" || return 1
    printf '%s\n' "$text_paths" | /usr/bin/grep -Fxq -- "n$executable" ||
        printf '%s\n' "$text_paths" | /usr/bin/grep -Fxq -- "n$physical"
}

# ps reports argv[0] as the command. launchd starts the login item and the
# service with a bare argv[0] from ProgramArguments ("Plainpost",
# "PlainpostService"), so a full-path match alone misses them and the old
# app would keep running replaced files. A process whose command is the full
# path matches as before; one whose command only has the same file name
# matches when lsof shows it runs this exact executable.
matching_pids() {
    local executable="$1"
    local physical="$executable"
    local parent
    local pid
    local command_path
    if parent="$(cd -P "${executable%/*}" 2>/dev/null && /bin/pwd -P)"; then
        physical="$parent/${executable##*/}"
    fi
    /bin/ps -axo pid=,comm= 2>/dev/null |
        /usr/bin/awk -v expected="$executable" -v name="${executable##*/}" '
            {
                pid = $1
                sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
                base = $0
                sub(/^.*\//, "", base)
                if ($0 == expected) {
                    print pid " exact"
                } else if (base == name) {
                    print pid " name"
                }
            }
        ' |
        while read -r pid command_path; do
            if [[ "$command_path" == "exact" ]] ||
                process_runs_executable "$pid" "$executable" "$physical"; then
                printf '%s\n' "$pid"
            fi
        done
}

launchctl_print_status=0
launchctl_description=""
read_launch_agent() {
    set +e
    launchctl_description="$(
        "$launchctl_command" print "$launch_agent_target" 2>&1
    )"
    launchctl_print_status=$?
    set -e
}

launch_agent_target="gui/$(/usr/bin/id -u)/$launch_agent_label"
service_executable="$bundle/Contents/Library/Helpers/PlainpostService.app/Contents/MacOS/PlainpostService"

launch_agent_job_matches_runtime() {
    printf '%s\n' "$launchctl_description" |
        /usr/bin/awk \
            -v expected_target="$launch_agent_target" \
            -v expected_program="$service_executable" \
            -v expected_mach_service="$mach_service_name" '
                function trim(value) {
                    sub(/^[[:space:]]+/, "", value)
                    sub(/[[:space:]]+$/, "", value)
                    return value
                }

                {
                    line = trim($0)
                    if (!saw_header) {
                        if (line == "") {
                            next
                        }
                        if (line != expected_target " = {") {
                            invalid = 1
                            next
                        }
                        saw_header = 1
                        depth = 1
                        next
                    }
                    if (closed) {
                        if (line != "") {
                            invalid = 1
                        }
                        next
                    }
                    if (line == "}") {
                        if (depth == 3 && in_endpoint_entry) {
                            in_endpoint_entry = 0
                            current_endpoint_matches = 0
                            depth = 2
                            next
                        }
                        if (depth == 2 && in_endpoints) {
                            in_endpoints = 0
                            depth = 1
                            next
                        }
                        if (depth == 2 && in_mach_services) {
                            in_mach_services = 0
                            depth = 1
                            next
                        }
                        if (depth > 1) {
                            depth -= 1
                            next
                        }
                        if (depth == 1) {
                            depth = 0
                            closed = 1
                            next
                        }
                        invalid = 1
                        next
                    }
                    if (depth == 1 && line == "mach services = {") {
                        mach_service_blocks += 1
                        in_mach_services = 1
                        depth = 2
                        next
                    }
                    if (depth == 1 && line == "endpoints = {") {
                        endpoint_blocks += 1
                        in_endpoints = 1
                        depth = 2
                        next
                    }
                    if (depth == 1 && index(line, "program = ") == 1) {
                        program_fields += 1
                        program = substr(line, length("program = ") + 1)
                        if (program == expected_program) {
                            matching_program_fields += 1
                        }
                        next
                    }
                    if (depth == 2 && in_mach_services) {
                        separator = index(line, "=>")
                        if (separator > 0) {
                            key = trim(substr(line, 1, separator - 1))
                            value = trim(substr(line, separator + 2))
                            if (key ~ /^".*"$/) {
                                key = substr(key, 2, length(key) - 2)
                            }
                            if (key == expected_mach_service) {
                                matching_mach_service_keys += 1
                                if (value == "true") {
                                    enabled_mach_service_keys += 1
                                }
                            }
                        }
                        next
                    }
                    if (depth == 2 && in_endpoints &&
                        line ~ / = \{$/) {
                        key = line
                        sub(/[[:space:]]*=[[:space:]]*\{$/, "", key)
                        key = trim(key)
                        if (key ~ /^".*"$/) {
                            key = substr(key, 2, length(key) - 2)
                        }
                        endpoint_entries += 1
                        current_endpoint_matches = (key == expected_mach_service)
                        if (current_endpoint_matches) {
                            matching_endpoint_keys += 1
                        }
                        in_endpoint_entry = 1
                        depth = 3
                        next
                    }
                    if (depth == 3 && in_endpoint_entry &&
                        line == "managed = 1") {
                        if (current_endpoint_matches) {
                            managed_endpoint_keys += 1
                        }
                        next
                    }
                    if (line ~ /\{[[:space:]]*$/) {
                        depth += 1
                    }
                }

                END {
                    valid_mach_services = mach_service_blocks == 1 &&
                        endpoint_blocks == 0 &&
                        matching_mach_service_keys == 1 &&
                        enabled_mach_service_keys == 1
                    valid_endpoints = endpoint_blocks == 1 &&
                        mach_service_blocks == 0 &&
                        matching_endpoint_keys == 1 &&
                        managed_endpoint_keys == 1
                    if (saw_header == 1 &&
                        closed == 1 &&
                        invalid == 0 &&
                        program_fields == 1 &&
                        matching_program_fields == 1 &&
                        (valid_mach_services || valid_endpoints)) {
                        exit 0
                    }
                    exit 1
                }
            '
}

# Prints the job's only top-level program path. Fails for a description that
# is not exactly one well-formed job with one program line.
launch_agent_single_program() {
    printf '%s\n' "$launchctl_description" |
        /usr/bin/awk -v expected_target="$launch_agent_target" '
            function trim(value) {
                sub(/^[[:space:]]+/, "", value)
                sub(/[[:space:]]+$/, "", value)
                return value
            }

            {
                line = trim($0)
                if (!saw_header) {
                    if (line == "") {
                        next
                    }
                    if (line != expected_target " = {") {
                        invalid = 1
                        exit
                    }
                    saw_header = 1
                    depth = 1
                    next
                }
                if (closed) {
                    if (line != "") {
                        invalid = 1
                    }
                    next
                }
                if (line == "}") {
                    depth -= 1
                    if (depth == 0) {
                        closed = 1
                    }
                    next
                }
                if (depth == 1 && index(line, "program = ") == 1) {
                    program_fields += 1
                    program = substr(line, length("program = ") + 1)
                    next
                }
                if (line ~ /\{[[:space:]]*$/) {
                    depth += 1
                }
            }

            END {
                if (saw_header == 1 &&
                    closed == 1 &&
                    invalid == 0 &&
                    program_fields == 1 &&
                    program != "") {
                    print program
                    exit 0
                }
                exit 1
            }
        '
}

bundle_physical="$bundle"
if bundle_parent_physical="$(cd -P "${bundle%/*}" 2>/dev/null && /bin/pwd -P)"; then
    bundle_physical="$bundle_parent_physical/${bundle##*/}"
fi

# A job whose program lies outside the bundle being replaced belongs to
# another Plainpost, such as the user's registered /Applications copy. It
# cannot respawn anything in this bundle, and booting out an SMAppService
# job leaves it unloaded until that app registers it again, so it is left
# alone.
program_is_outside_bundle() {
    local program="$1"
    [[ "$program" != "$bundle/"* && "$program" != "$bundle_physical/"* ]]
}

foreign_launch_agent_program=""
read_launch_agent
if [[ "$launchctl_print_status" -eq 0 ]]; then
    if loaded_program="$(launch_agent_single_program)" &&
        program_is_outside_bundle "$loaded_program"; then
        foreign_launch_agent_program="$loaded_program"
        {
            echo "WARNING: ============================================================"
            echo "WARNING: LaunchAgent $launch_agent_label belongs to another Plainpost:"
            echo "WARNING:   $loaded_program"
            echo "WARNING: It stays loaded. The package being built will not run its own"
            echo "WARNING: service while that one holds the job; its menu bar reports"
            echo "WARNING: \"Another Plainpost installation is running the background service.\""
            echo "WARNING: ============================================================"
        } >&2
    elif ! launch_agent_job_matches_runtime; then
        echo \
            "Loaded LaunchAgent does not match the Plainpost service runtime." \
            >&2
        exit 1
    fi
fi
if [[ "$launchctl_print_status" -eq 0 && -z "$foreign_launch_agent_program" ]]; then
    if ! "$launchctl_command" bootout "$launch_agent_target"; then
        echo "Could not boot out Plainpost LaunchAgent $launch_agent_label." >&2
        exit 1
    fi
    launch_agent_unloaded=false
    for attempt in {1..50}; do
        read_launch_agent
        if [[ "$launchctl_print_status" -eq 113 ]]; then
            launch_agent_unloaded=true
            break
        fi
        if [[ "$launchctl_print_status" -ne 0 ]]; then
            echo \
                "Could not prove Plainpost LaunchAgent unload state." \
                >&2
            exit 1
        fi
        /bin/sleep 0.1
    done
    if [[ "$launch_agent_unloaded" != "true" ]]; then
        echo "Plainpost LaunchAgent remained loaded after bootout." >&2
        exit 1
    fi
    # The job is SMAppService-managed: launchctl bootstrap cannot load it
    # again (error 5). Opening the new Plainpost.app registers it again.
    echo \
        "Stopped LaunchAgent $launch_agent_label. Open the packaged Plainpost to register it again." \
        >&2
elif [[ "$launchctl_print_status" -ne 0 &&
        "$launchctl_print_status" -ne 113 ]]; then
    echo "Could not determine Plainpost LaunchAgent load state." >&2
    exit 1
fi

ensure_launch_agent_unloaded() {
    read_launch_agent
    if [[ "$launchctl_print_status" -eq 113 ]]; then
        return 0
    fi
    # Another Plainpost's job may stay loaded, as long as it still runs
    # that other program and not something in this bundle.
    if [[ "$launchctl_print_status" -eq 0 && -n "$foreign_launch_agent_program" ]] &&
        loaded_program="$(launch_agent_single_program)" &&
        [[ "$loaded_program" == "$foreign_launch_agent_program" ]]; then
        return 0
    fi
    if [[ "$launchctl_print_status" -eq 0 ]]; then
        echo "Plainpost LaunchAgent became loaded during runtime stop." >&2
    else
        echo "Could not prove Plainpost LaunchAgent remained unloaded." >&2
    fi
    return 1
}

# Structural fixture mode never signals a process whose program text lies
# outside the fixture root, whatever matched it. Tests and mutation runs
# must not reach real processes, such as an installed Plainpost.
fixture_allows_signal() {
    local pid="$1"
    local text_paths
    [[ "$runtime_stop_fixture_mode" == "true" ]] || return 0
    text_paths="$(/usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null)" || return 1
    printf '%s\n' "$text_paths" |
        /usr/bin/awk \
            -v canonical="n$plainpost_package_fixture_root/" \
            -v lexical="n$plainpost_package_fixture_lexical_root/" '
                index($0, canonical) == 1 || index($0, lexical) == 1 { found = 1 }
                END { exit found ? 0 : 1 }
            '
}

signal_matching_processes() {
    local signal_name="$1"
    local target
    local pids
    local pid

    for target in "${targets[@]}"; do
        pids="$(matching_pids "$target")"
        for pid in $pids; do
            fixture_allows_signal "$pid" || continue
            /bin/kill "-$signal_name" "$pid" 2>/dev/null || true
        done
    done
}

wait_for_stable_absence() {
    local maximum_attempts="$1"
    local required_stable_scans="$2"
    local stable_scans=0
    local attempt
    local target
    local remaining

    for ((attempt = 0; attempt < maximum_attempts; attempt++)); do
        ensure_launch_agent_unloaded || return 1
        remaining=""
        for target in "${targets[@]}"; do
            remaining="${remaining}$(matching_pids "$target")"
        done
        if [[ -z "$remaining" ]]; then
            stable_scans=$((stable_scans + 1))
            if [[ "$stable_scans" -ge "$required_stable_scans" ]]; then
                return 0
            fi
        else
            stable_scans=0
        fi
        /bin/sleep 0.1
    done
    return 1
}

signal_matching_processes TERM
if wait_for_stable_absence 50 5; then
    exit 0
fi

signal_matching_processes KILL
if wait_for_stable_absence 20 5; then
    exit 0
fi

echo "Unable to prove packaged runtime termination." >&2
exit 1
