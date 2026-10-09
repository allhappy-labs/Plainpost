#!/bin/zsh

acceptance_exact_process_id() {
    local executable="$1"
    local process_name="$2"
    local canonical_executable=""
    if ! canonical_executable="$(rtk realpath "$executable" 2>/dev/null)" ||
       [[ -z "$canonical_executable" ]]; then
        return 1
    fi

    local candidate_processes="$(rtk pgrep -f "$process_name" 2>/dev/null || true)"
    local candidate_process_id
    local matches=()
    for candidate_process_id in ${(f)candidate_processes}; do
        local mapped_executable="$(rtk lsof -a -p "$candidate_process_id" -d txt -Fn 2>/dev/null | \
          rtk awk '/^n/ { sub(/^n/, ""); print; exit }')"
        [[ -n "$mapped_executable" ]] || continue
        local canonical_mapped_executable=""
        if ! canonical_mapped_executable="$(rtk realpath "$mapped_executable" 2>/dev/null)" ||
           [[ -z "$canonical_mapped_executable" ]]; then
            return 1
        fi
        if [[ "$canonical_mapped_executable" == "$canonical_executable" ]]; then
            matches+=("$candidate_process_id")
        fi
    done
    [[ "${#matches}" == "1" ]] || return 1
    rtk echo "$matches[1]"
}

acceptance_process_identity_capture() {
    local process_id="$1"
    local expected_executable="$2"
    local expected_user_id="$3"
    local inspector_executable="$4"
    if [[ "$process_id" != <1-> || "$expected_user_id" != <0-> ||
          -z "$expected_executable" || ! -x "$inspector_executable" ]]; then
        rtk printf '%s\n' unknown
        return 0
    fi

    local capture=""
    if ! capture="$(rtk "$inspector_executable" capture-process \
      "$process_id" "$expected_executable" "$expected_user_id" 2>/dev/null)"; then
        rtk printf '%s\n' unknown
        return 0
    fi
    case "$capture" in
        absent|unknown|present:<0->:<0->)
            rtk printf '%s\n' "$capture"
            ;;
        *)
            rtk printf '%s\n' unknown
            ;;
    esac
}

acceptance_process_identity_state() {
    local process_id="$1"
    local expected_executable="$2"
    local expected_user_id="$3"
    local inspector_executable="$4"
    local expected_start_seconds="$5"
    local expected_start_microseconds="$6"
    if [[ "$process_id" != <1-> || "$expected_user_id" != <0-> ||
          "$expected_start_seconds" != <0-> || "$expected_start_microseconds" != <0-> ||
          -z "$expected_executable" || ! -x "$inspector_executable" ]]; then
        rtk printf '%s\n' unknown
        return 0
    fi

    local observation=""
    if ! observation="$(rtk "$inspector_executable" inspect-process \
      "$process_id" "$expected_executable" "$expected_user_id" \
      "$expected_start_seconds" "$expected_start_microseconds" 2>/dev/null)"; then
        rtk printf '%s\n' unknown
        return 0
    fi
    case "$observation" in
        present|absent|unknown)
            rtk printf '%s\n' "$observation"
            ;;
        *)
            rtk printf '%s\n' unknown
            ;;
    esac
}

terminate_acceptance_process() {
    local process_id="$1"
    local expected_executable="$2"
    local expected_user_id="$3"
    local graceful_status_file="${4:-}"
    local graceful_attempts="${5:-50}"
    local inspector_executable="${6:-.build/debug/PlainpostIOSPairingFixture}"
    local capture="${7:-}"
    local graceful_status_observed=0
    local termination_status=0
    local signaled=0
    if [[ -z "$capture" ]]; then
        capture="$(acceptance_process_identity_capture \
          "$process_id" "$expected_executable" "$expected_user_id" "$inspector_executable")"
    fi
    local expected_start_seconds=""
    local expected_start_microseconds=""
    local observation=unknown

    case "$capture" in
        absent)
            observation=absent
            ;;
        unknown)
            termination_status=1
            ;;
        present:<0->:<0->)
            local capture_fields=( ${(s/:/)capture} )
            expected_start_seconds="${capture_fields[2]}"
            expected_start_microseconds="${capture_fields[3]}"
            observation="$(acceptance_process_identity_state \
              "$process_id" "$expected_executable" "$expected_user_id" "$inspector_executable" \
              "$expected_start_seconds" "$expected_start_microseconds")"
            case "$observation" in
                present)
                    rtk kill -TERM "$process_id" 2>/dev/null || termination_status=1
                    (( termination_status == 0 )) && signaled=1
                    ;;
                absent)
                    ;;
                *)
                    termination_status=1
                    ;;
            esac
            ;;
        *)
            termination_status=1
            ;;
    esac

    local graceful_attempt=0
    while (( termination_status == 0 && signaled && graceful_attempt < graceful_attempts )); do
        observation="$(acceptance_process_identity_state \
          "$process_id" "$expected_executable" "$expected_user_id" "$inspector_executable" \
          "$expected_start_seconds" "$expected_start_microseconds")"
        case "$observation" in
            absent)
                break
                ;;
            unknown)
                termination_status=1
                break
                ;;
            present)
                if [[ -n "$graceful_status_file" && -s "$graceful_status_file" ]]; then
                    graceful_status_observed=1
                fi
                (( graceful_attempt += 1 ))
                rtk sleep 0.1
                ;;
        esac
    done

    if (( termination_status == 0 && signaled )) && [[ "$observation" == present ]]; then
        observation="$(acceptance_process_identity_state \
          "$process_id" "$expected_executable" "$expected_user_id" "$inspector_executable" \
          "$expected_start_seconds" "$expected_start_microseconds")"
        case "$observation" in
            present)
                rtk kill -KILL "$process_id" 2>/dev/null || termination_status=1
                (( termination_status == 0 )) && signaled=1
                rtk sleep 0.1
                observation="$(acceptance_process_identity_state \
                  "$process_id" "$expected_executable" "$expected_user_id" "$inspector_executable" \
                  "$expected_start_seconds" "$expected_start_microseconds")"
                [[ "$observation" == absent ]] || termination_status=1
                ;;
            absent)
                ;;
            *)
                termination_status=1
                ;;
        esac
    fi

    if [[ -n "$graceful_status_file" && "$graceful_status_observed" != "1" &&
          ! -s "$graceful_status_file" ]]; then
        termination_status=1
    fi
    if (( signaled )) && [[ "$observation" == absent ]]; then
        wait "$process_id" 2>/dev/null || true
    fi
    return "$termination_status"
}
