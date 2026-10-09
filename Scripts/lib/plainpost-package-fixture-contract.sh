#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "plainpost-package-fixture-contract.sh must be sourced." >&2
    exit 64
fi

plainpost_package_fixture_mode=false
plainpost_package_fixture_root=""
plainpost_package_fixture_lexical_root=""
plainpost_package_fixture_build_root=""

plainpost_reject_fixture_root() {
    echo "Structural fixture root must be a canonical physical path." >&2
    exit 1
}

plainpost_path_has_dot_components() {
    local path="$1"

    case "/${path#/}/" in
        *"//"* | *"/./"* | *"/../"*) return 0 ;;
    esac
    return 1
}

plainpost_validate_package_fixture() {
    local script_root="$1"
    local configuration="$2"
    local requested_mode="$3"
    local requested_root="$4"
    local canonical_script_root
    local canonical_requested_root
    local canonical_temporary_root
    local lexical_temporary_root="${TMPDIR:-/tmp}"
    local expected_lexical_root
    local fixture_leaf
    local fixture_marker
    local marker_size

    plainpost_package_fixture_mode=false
    plainpost_package_fixture_root=""
    plainpost_package_fixture_lexical_root=""
    plainpost_package_fixture_build_root=""

    if [[ "$requested_mode" != "1" ]]; then
        if [[ -n "$requested_mode" || -n "$requested_root" ]]; then
            echo "Structural fixture mode and root must be set together." >&2
            exit 1
        fi
        return
    fi

    [[ "$configuration" == "debug" ]] || {
        echo "Structural fixture mode is debug-only." >&2
        exit 1
    }
    [[ "$requested_root" == /* &&
       -d "$requested_root" &&
       ! -L "$requested_root" ]] || plainpost_reject_fixture_root
    plainpost_path_has_dot_components "$requested_root" &&
        plainpost_reject_fixture_root
    plainpost_path_has_dot_components "$script_root" &&
        plainpost_reject_fixture_root

    canonical_script_root="$(
        cd -P "$script_root" 2>/dev/null &&
            /bin/pwd -P
    )" || plainpost_reject_fixture_root
    canonical_requested_root="$(
        cd -P "$requested_root" 2>/dev/null &&
            /bin/pwd -P
    )" || plainpost_reject_fixture_root
    canonical_temporary_root="$(
        cd -P "$lexical_temporary_root" 2>/dev/null &&
            /bin/pwd -P
    )" || plainpost_reject_fixture_root

    [[ "$canonical_requested_root" == "$canonical_script_root" ]] ||
        plainpost_reject_fixture_root
    fixture_leaf="${canonical_script_root##*/}"
    expected_lexical_root="${lexical_temporary_root%/}/$fixture_leaf"
    if [[ "$requested_root" != "$script_root" &&
          "$requested_root" != "$canonical_script_root" &&
          "$requested_root" != "$expected_lexical_root" ]]; then
        plainpost_reject_fixture_root
    fi
    [[ "${canonical_script_root%/*}" == "$canonical_temporary_root" ]] ||
        plainpost_reject_fixture_root
    [[ "$fixture_leaf" =~ ^plainpost-packaging-[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] ||
        plainpost_reject_fixture_root

    fixture_marker="$canonical_script_root/.plainpost-package-test-fixture"
    [[ -f "$fixture_marker" && ! -L "$fixture_marker" ]] ||
        plainpost_reject_fixture_root
    marker_size="$(/usr/bin/stat -f %z "$fixture_marker" 2>/dev/null)" ||
        plainpost_reject_fixture_root
    [[ "$marker_size" == "29" &&
       "$(/bin/cat "$fixture_marker")" == "Plainpost package fixture v1" ]] ||
        plainpost_reject_fixture_root

    plainpost_package_fixture_mode=true
    plainpost_package_fixture_root="$canonical_script_root"
    plainpost_package_fixture_lexical_root="$requested_root"
    plainpost_package_fixture_build_root="$canonical_script_root/.build"
}

plainpost_fixture_relative_path() {
    local path="$1"

    case "$path" in
        "$plainpost_package_fixture_lexical_root/"*)
            printf '%s\n' \
                "${path#"$plainpost_package_fixture_lexical_root/"}"
            ;;
        "$plainpost_package_fixture_root/"*)
            printf '%s\n' \
                "${path#"$plainpost_package_fixture_root/"}"
            ;;
        *)
            return 1
            ;;
    esac
}

plainpost_reject_fixture_path() {
    echo "$1 must be a canonical path inside the fixture root." >&2
    exit 1
}

plainpost_validate_fixture_descendant() {
    local path="$1"
    local description="$2"
    local require_existing_parent="${3:-false}"
    local relative_path
    local current_path
    local component
    local components=()
    local path_parent
    local canonical_parent

    [[ "$plainpost_package_fixture_mode" == "true" &&
       "$path" == /* ]] || plainpost_reject_fixture_path "$description"
    plainpost_path_has_dot_components "$path" &&
        plainpost_reject_fixture_path "$description"
    relative_path="$(plainpost_fixture_relative_path "$path")" ||
        plainpost_reject_fixture_path "$description"
    [[ -n "$relative_path" ]] ||
        plainpost_reject_fixture_path "$description"

    current_path="$plainpost_package_fixture_lexical_root"
    if [[ "$path" == "$plainpost_package_fixture_root/"* ]]; then
        current_path="$plainpost_package_fixture_root"
    fi
    IFS='/' read -r -a components <<< "$relative_path"
    for component in "${components[@]}"; do
        [[ -n "$component" && "$component" != "." && "$component" != ".." ]] ||
            plainpost_reject_fixture_path "$description"
        current_path="$current_path/$component"
        [[ ! -L "$current_path" ]] ||
            plainpost_reject_fixture_path "$description"
    done

    path_parent="${path%/*}"
    if [[ "$require_existing_parent" == "true" ]]; then
        [[ -d "$path_parent" && ! -L "$path_parent" ]] ||
            plainpost_reject_fixture_path "$description"
    fi
    if [[ -d "$path_parent" && ! -L "$path_parent" ]]; then
        canonical_parent="$(
            cd -P "$path_parent" 2>/dev/null &&
                /bin/pwd -P
        )" || plainpost_reject_fixture_path "$description"
        case "$canonical_parent/" in
            "$plainpost_package_fixture_root/"*) ;;
            *) plainpost_reject_fixture_path "$description" ;;
        esac
    fi
}

plainpost_validate_fixture_bundle_path() {
    local path="$1"
    local description="$2"
    local path_parent
    local canonical_parent

    [[ "$path" == *.app ]] || plainpost_reject_fixture_path "$description"
    plainpost_validate_fixture_descendant "$path" "$description" true
    path_parent="${path%/*}"
    canonical_parent="$(
        cd -P "$path_parent" 2>/dev/null &&
            /bin/pwd -P
    )" || plainpost_reject_fixture_path "$description"
    case "$canonical_parent/" in
        "$plainpost_package_fixture_build_root/"*) ;;
        *) plainpost_reject_fixture_path "$description" ;;
    esac
    [[ "${path##*/}" != "Plainpost.app" ]] ||
        plainpost_reject_fixture_path "$description"
}

plainpost_fixture_tool_path() {
    local path="$1"
    local description="$2"
    local canonical_parent
    local canonical_path

    if [[ "$plainpost_package_fixture_mode" != "true" ||
          "$path" != /* ||
          ! -f "$path" ||
          -L "$path" ||
          ! -x "$path" ]]; then
        echo \
            "$description must be a canonical regular executable inside the fixture root." \
            >&2
        return 1
    fi
    if plainpost_path_has_dot_components "$path"; then
        echo \
            "$description must be a canonical regular executable inside the fixture root." \
            >&2
        return 1
    fi
    if ! plainpost_validate_fixture_descendant "$path" "$description" true; then
        return 1
    fi
    canonical_parent="$(
        cd -P "${path%/*}" 2>/dev/null &&
            /bin/pwd -P
    )" || {
        echo \
            "$description must be a canonical regular executable inside the fixture root." \
            >&2
        return 1
    }
    canonical_path="$canonical_parent/${path##*/}"
    case "$canonical_path" in
        "$plainpost_package_fixture_root/"*) ;;
        *)
            echo \
                "$description must be a canonical regular executable inside the fixture root." \
                >&2
            return 1
            ;;
    esac
    [[ -f "$canonical_path" &&
       ! -L "$canonical_path" &&
       -x "$canonical_path" ]] || {
        echo \
            "$description must be a canonical regular executable inside the fixture root." \
            >&2
        return 1
    }
    printf '%s\n' "$canonical_path"
}
