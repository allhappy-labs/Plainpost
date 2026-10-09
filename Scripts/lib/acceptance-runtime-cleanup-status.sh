#!/bin/zsh

# Wait for the acceptance app that owns the isolated Keychain records to report
# its termination cleanup result. A present non-success status is retained for
# diagnostics; a missing file is a bounded timeout.
wait_for_acceptance_runtime_cleanup_status() {
    local status_file="$1"
    local attempts="$2"
    local attempt=0
    while (( attempt < attempts )); do
        if [[ -s "$status_file" ]]; then
            [[ "$(<"$status_file")" == "success" ]] && return 0
            return 1
        fi
        (( attempt += 1 ))
        rtk sleep 0.1
    done
    return 2
}
