#!/bin/zsh

ios_e2e_get_data_container() {
    rtk xcrun simctl get_app_container "$1" "$2" data 2>/dev/null
}

ios_e2e_launch_reset() {
    local udid="$1"
    local bundle_id="$2"
    local pairing_service="$3"
    local cache_namespace="$4"
    rtk env \
      SIMCTL_CHILD_PLAINPOST_E2E_RESET_ON_LAUNCH=1 \
      SIMCTL_CHILD_PLAINPOST_E2E_PAIRING_STORE_SERVICE="$pairing_service" \
      SIMCTL_CHILD_PLAINPOST_E2E_CACHE_NAMESPACE="$cache_namespace" \
      xcrun simctl launch --terminate-running-process "$udid" "$bundle_id" >/dev/null
}

ios_e2e_terminate_app() {
    rtk xcrun simctl terminate "$1" "$2" >/dev/null 2>&1 || true
}

ios_e2e_uninstall_app() {
    rtk xcrun simctl uninstall "$1" "$2" >/dev/null 2>&1
}

reset_and_uninstall_ios_e2e_app() {
    local udid="$1"
    local bundle_id="$2"
    local pairing_service="$3"
    local cache_namespace="$4"
    local evidence_path="${5:-}"
    local cleanup_status=0
    local expected_bundle_id="com.marynavdovenko.Plainpost.iOS"
    local expected_service_prefix="com.marynavdovenko.Plainpost.MobileClient.E2E."

    if [[ -z "$udid" || "$bundle_id" != "$expected_bundle_id" ]]; then
        rtk echo "Refusing simulator cleanup with an unexpected device or bundle identifier." >&2
        return 1
    fi

    local normalized_namespace="${cache_namespace:l}"
    local normalized_service_suffix="${pairing_service#$expected_service_prefix}"
    normalized_service_suffix="${normalized_service_suffix:l}"
    if [[ "$pairing_service" != ${expected_service_prefix}* ]] ||
       ! rtk echo "$cache_namespace" | rtk rg -q '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' ||
       [[ "$normalized_service_suffix" != "$normalized_namespace" ]]; then
        rtk echo "Refusing app-driven cleanup with an invalid E2E service or namespace." >&2
        ios_e2e_uninstall_app "$udid" "$bundle_id" || true
        return 1
    fi

    local container="$(ios_e2e_get_data_container "$udid" "$bundle_id" || true)"
    if [[ -n "$container" ]]; then
        if [[ "$container" != /* || ! -d "$container" || -L "$container" ]]; then
            rtk echo "The Simulator returned an unsafe app data container." >&2
            cleanup_status=1
        else
            local marker_namespace="${cache_namespace:u}"
            local support="$container/Library/Application Support"
            local marker="$support/PlainpostE2EReset/$marker_namespace.status"
            local cache_directory="$support/PlainpostMobileCache/E2E.$marker_namespace"
            local attachment_directory="$support/PlainpostMobileAttachments/E2E.$marker_namespace"
            rtk rm -f -- "$marker" || cleanup_status=1
            if (( cleanup_status == 0 )) && ! ios_e2e_launch_reset "$udid" "$bundle_id" "$pairing_service" "$cache_namespace"; then
                rtk echo "The iOS E2E reset launch failed." >&2
                cleanup_status=1
            fi
            if (( cleanup_status == 0 )); then
                local marker_ready=0
                for _ in {1..100}; do
                    if [[ -f "$marker" && ! -L "$marker" &&
                          "$(rtk stat -f '%Lp' "$marker" 2>/dev/null || true)" == "600" &&
                          "$(<"$marker")" == "success" ]]; then
                        marker_ready=1
                        break
                    fi
                    rtk sleep 0.1
                done
                if (( marker_ready == 0 )); then
                    rtk echo "The iOS E2E reset did not produce its owner-only success marker." >&2
                    cleanup_status=1
                elif [[ -n "$evidence_path" ]]; then
                    if ! rtk cp "$marker" "$evidence_path" || ! rtk chmod 0600 "$evidence_path"; then
                        rtk echo "The iOS E2E reset marker could not be preserved as cleanup evidence." >&2
                        cleanup_status=1
                    fi
                fi
            fi
            if [[ -e "$cache_directory" || -L "$cache_directory" ||
                  -e "$attachment_directory" || -L "$attachment_directory" ]]; then
                rtk echo "The iOS E2E reset left namespace-scoped cache state behind." >&2
                cleanup_status=1
            fi
            ios_e2e_terminate_app "$udid" "$bundle_id"
        fi
    fi

    ios_e2e_uninstall_app "$udid" "$bundle_id" || true
    if [[ -n "$(ios_e2e_get_data_container "$udid" "$bundle_id" || true)" ]]; then
        rtk echo "The iOS E2E app data container remained after uninstall." >&2
        cleanup_status=1
    fi
    return "$cleanup_status"
}
