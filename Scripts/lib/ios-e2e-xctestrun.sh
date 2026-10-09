#!/bin/zsh

xctestrun_contains_plainpost_e2e_values() {
    local run_file="$1"
    rtk rg -q 'PLAINPOST_(E2E|VISUAL)_[A-Z0-9_]+' "$run_file"
}

xctestrun_sha256() {
    rtk shasum -a 256 "$1" | rtk awk '{print $1}'
}

xctestrun_unique_suffix() {
    rtk uuidgen
}

xctestrun_copy_exclusive() {
    local source="$1"
    local destination="$2"
    [[ -f "$source" && ! -L "$source" ]] || return 1
    [[ ! -e "$destination" && ! -L "$destination" ]] || return 1
    if ! ( set -o noclobber; : >"$destination" ); then
        return 1
    fi
    if ! rtk chmod 0600 "$destination" || ! rtk cp "$source" "$destination" ||
       [[ ! -f "$destination" || -L "$destination" ]]; then
        rtk rm -f -- "$destination"
        return 1
    fi
}

prepare_xctestrun_backup() {
    local run_file="$1"
    local backup="$2"
    local hash_file="${backup}.sha256"
    if [[ -e "$backup" || -L "$backup" || -e "$hash_file" || -L "$hash_file" ]]; then
        rtk echo "Refusing to overwrite stale xctestrun backup: $backup" >&2
        return 1
    fi
    if [[ ! -f "$run_file" || -L "$run_file" ]]; then
        rtk echo "Refusing to back up an unsafe xctestrun source." >&2
        return 1
    fi
    if xctestrun_contains_plainpost_e2e_values "$run_file"; then
        rtk echo "Refusing to back up an xctestrun containing E2E values." >&2
        return 1
    fi
    local expected_hash="$(xctestrun_sha256 "$run_file")"
    if ! xctestrun_copy_exclusive "$run_file" "$backup" ||
       [[ "$(xctestrun_sha256 "$backup")" != "$expected_hash" ]] ||
       ! ( set -o noclobber; rtk printf '%s\n' "$expected_hash" >"$hash_file" ) ||
       ! rtk chmod 0600 "$hash_file"; then
        rtk rm -f -- "$backup" "$hash_file"
        return 1
    fi
}

xctestrun_restore_move() {
    rtk mv "$1" "$2"
}

restore_xctestrun_backup() {
    local run_file="$1"
    local backup="$2"
    [[ -e "$backup" || -L "$backup" ]] || return 0
    local hash_file="${backup}.sha256"
    if [[ ! -f "$backup" || -L "$backup" ||
          ! -f "$hash_file" || -L "$hash_file" ||
          "$(rtk stat -f '%Lp' "$hash_file" 2>/dev/null || true)" != "600" ]]; then
        rtk echo "xctestrun recovery hash is unavailable; recovery preserved at: $backup" >&2
        return 1
    fi
    local expected_hash="$(<"$hash_file")"
    if ! rtk echo "$expected_hash" | rtk rg -q '^[0-9a-f]{64}$' ||
       [[ "$(xctestrun_sha256 "$backup")" != "$expected_hash" ]]; then
        rtk echo "xctestrun recovery bytes do not match their pre-injection hash: $backup" >&2
        return 1
    fi
    local candidate="${run_file}.plainpost-restore.$(xctestrun_unique_suffix)"
    if ! xctestrun_copy_exclusive "$backup" "$candidate"; then
        rtk echo "xctestrun recovery preserved at: $backup" >&2
        return 1
    fi
    if xctestrun_contains_plainpost_e2e_values "$candidate"; then
        rtk rm -f -- "$candidate"
        rtk echo "xctestrun recovery backup still contains injected E2E values: $backup" >&2
        return 1
    fi
    if [[ "$(xctestrun_sha256 "$candidate")" != "$expected_hash" ]]; then
        rtk rm -f -- "$candidate"
        rtk echo "xctestrun recovery candidate changed bytes; recovery preserved at: $backup" >&2
        return 1
    fi
    if ! xctestrun_restore_move "$candidate" "$run_file"; then
        rtk rm -f -- "$candidate"
        rtk echo "xctestrun recovery preserved at: $backup" >&2
        return 1
    fi
    if [[ ! -f "$run_file" || -L "$run_file" ]] ||
       xctestrun_contains_plainpost_e2e_values "$run_file" ||
       [[ "$(xctestrun_sha256 "$run_file")" != "$expected_hash" ]]; then
        rtk echo "Restored xctestrun still contains injected E2E values; recovery preserved at: $backup" >&2
        return 1
    fi
    rtk rm -f -- "$backup" "$hash_file"
}

remove_injected_invitation_file() {
    local invitation_file="$1"
    rtk rm -f -- "$invitation_file" || return 1
    [[ ! -e "$invitation_file" ]]
}
