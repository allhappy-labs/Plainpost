#!/bin/zsh

terminal_cleanup_has_run=0
terminal_cleanup_in_progress=0
terminal_cleanup_signal_status=""

terminal_cleanup_callback() {
    (( terminal_cleanup_in_progress )) && return 0
    typeset -g terminal_cleanup_in_progress=1
    local cleanup_function="$1"
    local cleanup_status=0
    emulate -L zsh
    setopt localoptions noerrexit
    "$cleanup_function" || cleanup_status=$?
    typeset -g terminal_cleanup_in_progress=0
    return "$cleanup_status"
}

terminal_cleanup_once() {
    (( terminal_cleanup_has_run )) && return 0
    terminal_cleanup_has_run=1
    terminal_cleanup_callback "$1"
}

terminal_cleanup_on_exit() {
    local original_status=$?
    local cleanup_status=0
    emulate -L zsh
    setopt localoptions noerrexit
    terminal_cleanup_once "$1" || cleanup_status=$?
    if [[ -n "$terminal_cleanup_signal_status" ]]; then
        typeset -g terminal_cleanup_has_run=1
        exit "$terminal_cleanup_signal_status"
    fi
    if (( original_status != 0 )); then
        exit "$original_status"
    fi
    exit "$cleanup_status"
}

terminal_cleanup_manually() {
    local cleanup_status=0
    emulate -L zsh
    setopt localoptions noerrexit
    terminal_cleanup_callback "$1" || cleanup_status=$?
    if [[ -n "$terminal_cleanup_signal_status" ]]; then
        typeset -g terminal_cleanup_has_run=1
        exit "$terminal_cleanup_signal_status"
    fi
    return "$cleanup_status"
}

terminal_cleanup_trap_setup() {
    local cleanup_function="$1"
    if [[ ! "$cleanup_function" =~ '^[A-Za-z_][A-Za-z0-9_]*$' ]]; then
        return 1
    fi
    print -r -- "trap 'terminal_cleanup_on_exit $cleanup_function' EXIT"
    print -r -- 'trap '\''typeset -g terminal_cleanup_signal_status=130; (( terminal_cleanup_in_progress )) || exit 130'\'' INT'
    print -r -- 'trap '\''typeset -g terminal_cleanup_signal_status=143; (( terminal_cleanup_in_progress )) || exit 143'\'' TERM'
}
