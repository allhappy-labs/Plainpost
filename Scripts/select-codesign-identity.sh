#!/usr/bin/env bash
set -euo pipefail

configuration="${1:-debug}"
output_mode="${2:-identity}"
required_team_identifier="9XN7WN8JN2"
requested_identity="${PLAINPOST_CODESIGN_IDENTITY:-}"
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_contract_script="$root_dir/Scripts/lib/plainpost-package-fixture-contract.sh"
if [[ ! -f "$fixture_contract_script" || -L "$fixture_contract_script" ]]; then
    echo "Missing Plainpost package fixture contract." >&2
    exit 1
fi
# shellcheck source=Scripts/lib/plainpost-package-fixture-contract.sh
source "$fixture_contract_script"

reject_package_fixture_mode() {
    echo "$1" >&2
    exit 1
}

validate_package_fixture_overrides() {
    local requested_mode="${PLAINPOST_PACKAGE_TEST_MODE:-}"
    local requested_root="${PLAINPOST_PACKAGE_TEST_ROOT:-}"
    local fixture_records_present=false
    local available_records_present=false

    [[ -z "${PLAINPOST_PACKAGE_TEST_CODESIGN_IDENTITY_RECORDS+x}" ]] ||
        fixture_records_present=true
    [[ -z "${PLAINPOST_AVAILABLE_CODESIGN_IDENTITIES+x}" ]] ||
        available_records_present=true

    if [[ "$requested_mode" != "1" ]]; then
        if [[ "$fixture_records_present" == "true" ]]; then
            reject_package_fixture_mode \
                "PLAINPOST_PACKAGE_TEST_CODESIGN_IDENTITY_RECORDS requires structural fixture mode."
        fi
        if [[ -n "$requested_mode" ||
              -n "$requested_root" ||
              "$available_records_present" == "true" ]]; then
            reject_package_fixture_mode \
                "Signing identity fixture inputs require structural fixture mode."
        fi
    fi
}

validate_package_fixture_overrides
plainpost_validate_package_fixture \
    "$root_dir" \
    "$configuration" \
    "${PLAINPOST_PACKAGE_TEST_MODE:-}" \
    "${PLAINPOST_PACKAGE_TEST_ROOT:-}"
package_fixture_mode="$plainpost_package_fixture_mode"

uppercase() {
    /usr/bin/tr '[:lower:]' '[:upper:]'
}

emit_adhoc_identity() {
    if [[ "$output_mode" == "--metadata" ]]; then
        printf '%s\n' "-|-"
    else
        printf '%s\n' "-"
    fi
}

if [[ -z "$requested_identity" || "$requested_identity" == "-" ]]; then
    if [[ "$configuration" == "release" ]]; then
        echo "Release packaging requires PLAINPOST_CODESIGN_IDENTITY." >&2
        exit 1
    fi
    emit_adhoc_identity
    exit 0
fi

if [[ ! "$requested_identity" =~ ^[[:xdigit:]]{40}$ ]]; then
    echo \
        "PLAINPOST_CODESIGN_IDENTITY must be an exact SHA-1 certificate fingerprint." \
        >&2
    exit 1
fi

identity_validation_directory=""
cleanup_identity_validation() {
    if [[ -n "$identity_validation_directory" && -d "$identity_validation_directory" ]]; then
        rm -rf -- "$identity_validation_directory"
    fi
}
trap cleanup_identity_validation EXIT

collect_identity_records() {
    local available_identities
    local fingerprint
    local label
    local certificate_output
    local certificate_directory
    local certificate_path
    local certificate_sha1
    local certificate_sha256
    local certificate_subject
    local certificate_ou
    local certificate_common_name
    local fingerprint_upper
    local identity_index=0
    local matching_certificate_path
    local matching_certificate_count

    available_identities=""
    if [[ "$package_fixture_mode" == "true" ]]; then
        available_identities="${PLAINPOST_AVAILABLE_CODESIGN_IDENTITIES:-}"
    else
        available_identities="$(
            /usr/bin/security find-identity -v -p codesigning 2>/dev/null || true
        )"
    fi

    while IFS= read -r line; do
        fingerprint="$(
            printf '%s\n' "$line" |
                /usr/bin/awk '
                    match($0, /[[:xdigit:]]{40}/) {
                        print substr($0, RSTART, RLENGTH)
                    }
                '
        )"
        label="$(
            printf '%s\n' "$line" |
                /usr/bin/awk -F '"' 'NF >= 3 { print $2 }'
        )"
        [[ -n "$fingerprint" && -n "$label" ]] || continue
        fingerprint_upper="$(printf '%s' "$fingerprint" | uppercase)"
        identity_index=$((identity_index + 1))
        certificate_directory="$identity_validation_directory/$identity_index"
        mkdir -p "$certificate_directory"
        certificate_output="$(
            /usr/bin/security find-certificate -a -c "$label" -p 2>/dev/null ||
                true
        )"
        [[ -n "$certificate_output" ]] || continue
        printf '%s\n' "$certificate_output" |
            /usr/bin/awk -v output_directory="$certificate_directory" '
                /-----BEGIN CERTIFICATE-----/ {
                    certificate_index += 1
                    output_path = output_directory "/certificate-" certificate_index ".pem"
                }
                output_path != "" {
                    print > output_path
                }
                /-----END CERTIFICATE-----/ {
                    close(output_path)
                    output_path = ""
                }
            '
        matching_certificate_path=""
        matching_certificate_count=0
        for certificate_path in "$certificate_directory"/certificate-*.pem; do
            [[ -f "$certificate_path" ]] || continue
            certificate_sha1="$(
                /usr/bin/openssl x509 \
                    -in "$certificate_path" -noout -fingerprint -sha1 2>/dev/null |
                    /usr/bin/awk -F= '
                        NF == 2 {
                            gsub(":", "", $2)
                            print toupper($2)
                        }
                    '
            )"
            if [[ "$certificate_sha1" == "$fingerprint_upper" ]]; then
                matching_certificate_count=$((matching_certificate_count + 1))
                matching_certificate_path="$certificate_path"
            fi
        done
        [[ "$matching_certificate_count" -eq 1 ]] || continue
        /usr/bin/openssl x509 \
            -in "$matching_certificate_path" -noout -checkend 0 >/dev/null 2>&1 ||
            continue
        certificate_sha256="$(
            /usr/bin/openssl x509 \
                -in "$matching_certificate_path" -noout -fingerprint -sha256 2>/dev/null |
                /usr/bin/awk -F= 'NF == 2 { gsub(":", "", $2); print toupper($2) }'
        )"
        certificate_subject="$(
            /usr/bin/openssl x509 \
                -in "$matching_certificate_path" \
                -noout -subject -nameopt sep_multiline 2>/dev/null
        )"
        certificate_ou="$(
            printf '%s\n' "$certificate_subject" |
                /usr/bin/awk -F= '
                    /^[[:space:]]*OU[[:space:]]*=/ {
                        value = $2
                        sub(/^[[:space:]]*/, "", value)
                        sub(/[[:space:]]*$/, "", value)
                        print value
                        exit
                    }
                '
        )"
        certificate_common_name="$(
            printf '%s\n' "$certificate_subject" |
                /usr/bin/awk -F= '
                    /^[[:space:]]*CN[[:space:]]*=/ {
                        value = $2
                        sub(/^[[:space:]]*/, "", value)
                        sub(/[[:space:]]*$/, "", value)
                        print value
                        exit
                    }
                '
        )"
        printf '%s|%s|%s|%s|%s\n' \
            "$fingerprint_upper" \
            "$certificate_sha256" \
            "$certificate_ou" \
            "$certificate_common_name" \
            "$label"
    done <<< "$available_identities"
}

identity_records=""
if [[ "$package_fixture_mode" == "true" ]]; then
    identity_records="${PLAINPOST_PACKAGE_TEST_CODESIGN_IDENTITY_RECORDS:-}"
fi
if [[ -z "$identity_records" && "$package_fixture_mode" != "true" ]]; then
    identity_validation_directory="$(
        /usr/bin/mktemp -d "${TMPDIR:-/tmp}/plainpost-signing-identity.XXXXXX"
    )"
    identity_records="$(collect_identity_records)"
fi

requested_fingerprint="$(printf '%s' "$requested_identity" | uppercase)"
matches=()
while IFS='|' read -r sha1 sha256 organizational_unit common_name label extra; do
    [[ -z "${extra:-}" ]] || continue
    [[ "$sha1" =~ ^[[:xdigit:]]{40}$ ]] || continue
    [[ "$sha256" =~ ^[[:xdigit:]]{64}$ ]] || continue
    sha1_upper="$(printf '%s' "$sha1" | uppercase)"
    sha256_upper="$(printf '%s' "$sha256" | uppercase)"
    if [[ "$requested_fingerprint" == "$sha1_upper" ]]; then
        matches+=("$sha1_upper|$sha256_upper|$organizational_unit|$common_name|$label")
    fi
done <<< "$identity_records"

if [[ "${#matches[@]}" -eq 0 ]]; then
    echo "No matching Apple Development signing identity was found." >&2
    exit 1
fi
if [[ "${#matches[@]}" -ne 1 ]]; then
    echo "The requested Apple Development signing identity is ambiguous." >&2
    exit 1
fi

IFS='|' read -r selected_sha1 selected_sha256 selected_ou selected_common_name selected_label \
    <<< "${matches[0]}"
if [[ "$selected_ou" != "$required_team_identifier" ]]; then
    echo "The signing identity certificate must use organizational unit $required_team_identifier." >&2
    exit 1
fi
if [[ "$selected_common_name" != "Apple Development:"* ]]; then
    echo "The signing identity must be an Apple Development certificate." >&2
    exit 1
fi

if [[ "$output_mode" == "--metadata" ]]; then
    printf '%s|%s\n' "$selected_sha1" "$selected_sha256"
else
    printf '%s\n' "$selected_sha1"
fi
