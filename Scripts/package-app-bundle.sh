#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${PLAINPOST_BUILD_CONFIGURATION:-debug}"
fixture_contract_script="$root_dir/Scripts/lib/plainpost-package-fixture-contract.sh"
if [[ ! -f "$fixture_contract_script" || -L "$fixture_contract_script" ]]; then
    echo "Missing Plainpost package fixture contract." >&2
    exit 1
fi
# shellcheck source=Scripts/lib/plainpost-package-fixture-contract.sh
source "$fixture_contract_script"
agent_binary="$root_dir/.build/$configuration/PlainpostBackgroundAgent"
bridge_binary="$root_dir/.build/$configuration/PlainpostBrowserBridge"
cli_binary="$root_dir/.build/$configuration/plainpost"
service_binary="$root_dir/.build/$configuration/PlainpostService"
default_bundle="$root_dir/.build/Plainpost.app"
bundle="${PLAINPOST_APP_BUNDLE_OUTPUT:-$default_bundle}"
build_dir="$root_dir/.build"
required_team_identifier="9XN7WN8JN2"
required_app_application_identifier="9XN7WN8JN2.com.marynavdovenko.Plainpost"
required_service_application_identifier="9XN7WN8JN2.com.marynavdovenko.Plainpost.Service"
required_service_keychain_group="9XN7WN8JN2.com.marynavdovenko.Plainpost.AccountShared"
allowed_profile_keychain_group="$required_team_identifier.*"

reject_package_fixture_mode() {
    echo "$1" >&2
    exit 1
}

package_test_overrides_present() {
    [[ -n "${PLAINPOST_PACKAGE_TEST_HOOK+x}" ||
       -n "${PLAINPOST_PACKAGE_TEST_XCODEBUILD_COMMAND+x}" ||
       -n "${PLAINPOST_PACKAGE_TEST_CODESIGN_COMMAND+x}" ||
       -n "${PLAINPOST_PACKAGE_TEST_CODESIGN_IDENTITY_RECORDS+x}" ||
       -n "${PLAINPOST_PACKAGE_TEST_PROFILE_DECODER_COMMAND+x}" ||
       -n "${PLAINPOST_AVAILABLE_CODESIGN_IDENTITIES+x}" ]]
}

validate_package_fixture_overrides() {
    local requested_mode="${PLAINPOST_PACKAGE_TEST_MODE:-}"
    local requested_root="${PLAINPOST_PACKAGE_TEST_ROOT:-}"

    if [[ "$requested_mode" != "1" ]]; then
        if [[ -n "$requested_mode" ||
              -n "$requested_root" ]] ||
            package_test_overrides_present; then
            reject_package_fixture_mode \
                "PLAINPOST_PACKAGE_TEST_* overrides require structural fixture mode."
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

reject_bundle_output() {
    echo "PLAINPOST_APP_BUNDLE_OUTPUT must be an .app below .build." >&2
    exit 1
}

validate_bundle_output() {
    [[ "$bundle" == /* && "$bundle" == *.app ]] || reject_bundle_output
    [[ "$bundle" != *"//"* && "$bundle" != *"/." && "$bundle" != *"/."/* ]] || reject_bundle_output
    [[ "$bundle" != *"/./"* && "$bundle" != *"/../"* ]] || reject_bundle_output
    [[ -d "$build_dir" && ! -L "$build_dir" ]] || reject_bundle_output
    case "$bundle" in
        "$build_dir/"*.app) ;;
        *) reject_bundle_output ;;
    esac
    if [[ "$package_fixture_mode" == "true" &&
          "${bundle##*/}" == "Plainpost.app" ]]; then
        reject_package_fixture_mode \
            "Structural fixture mode cannot target Plainpost.app."
    fi
    if [[ "$package_fixture_mode" == "true" ]]; then
        if ! (
            plainpost_validate_fixture_descendant \
                "$bundle" \
                "Structural fixture bundle" \
                false
        ) 2>/dev/null; then
            reject_bundle_output
        fi
    fi

    local relative_path="${bundle#"$build_dir/"}"
    local current_path="$build_dir"
    local component
    local components=()
    IFS='/' read -r -a components <<< "$relative_path"
    for component in "${components[@]}"; do
        [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || reject_bundle_output
        current_path="$current_path/$component"
        [[ ! -L "$current_path" ]] || reject_bundle_output
    done

    [[ ! -e "$bundle" || -d "$bundle" ]] || reject_bundle_output
    bundle_parent="${bundle%/*}"
}

prepare_bundle_output_parent() {
    local current_path="$build_dir"
    local component
    local components=()
    local relative_path="${bundle#"$build_dir/"}"

    mkdir -p "$bundle_parent"
    IFS='/' read -r -a components <<< "$relative_path"
    current_path="$build_dir"
    for component in "${components[@]}"; do
        current_path="$current_path/$component"
        [[ ! -L "$current_path" ]] || reject_bundle_output
    done
}

validate_bundle_output
bundle_parent="${bundle%/*}"
bundle_leaf="${bundle##*/}"
xcode_configuration="Debug"
if [[ "$configuration" == "release" ]]; then
    xcode_configuration="Release"
fi
derived_data="$root_dir/.build/xcode-derived"
if [[ "$package_fixture_mode" != "true" ]]; then
    build_artifacts="$root_dir/Scripts/lib/build_artifacts.py"
    swift_products="$(rtk proxy python3 "$build_artifacts" swift-products --root "$root_dir" --cache "$root_dir/.build" --configuration "$xcode_configuration" --signing adhoc)"
    agent_binary="$swift_products/PlainpostBackgroundAgent"
    bridge_binary="$swift_products/PlainpostBrowserBridge"
    cli_binary="$swift_products/plainpost"
    service_binary="$swift_products/PlainpostService"
    derived_data="$(rtk proxy python3 "$build_artifacts" cache --root "$root_dir" --purpose mac-app --configuration "$xcode_configuration" --signing unsigned)"
    helper_receipts=()
    for product in PlainpostBackgroundAgent PlainpostBrowserBridge plainpost PlainpostService; do
        receipt="$root_dir/.build/build-receipts/$configuration-$product.json"
        rtk proxy python3 "$build_artifacts" build --root "$root_dir" --cache "$root_dir/.build" \
          --configuration "$xcode_configuration" --signing adhoc --receipt "$receipt" \
          --product "$product=${swift_products#"$root_dir/.build/"}/$product" -- \
          rtk proxy swift build --package-path "$root_dir" --scratch-path "$root_dir/.build" \
          --configuration "$configuration" --product "$product"
        helper_receipts+=("$receipt")
    done
fi
native_bundle="$derived_data/Build/Products/$xcode_configuration/Plainpost.app"
runtime_stop_script="$root_dir/Scripts/stop-packaged-runtime.sh"
signing_identity_script="$root_dir/Scripts/select-codesign-identity.sh"
launch_agent_label="${PLAINPOST_LAUNCH_AGENT_LABEL:-com.marynavdovenko.Plainpost.BackgroundAgent}"
service_info_plist="$root_dir/Support/PlainpostService/Info.plist"
service_entitlements="$root_dir/Support/PlainpostService/PlainpostService.entitlements"
app_entitlements="$root_dir/Support/PlainpostApp/PlainpostApp.entitlements"
xcodebuild_command="${PLAINPOST_PACKAGE_TEST_XCODEBUILD_COMMAND:-/usr/bin/xcodebuild}"
codesign_command="${PLAINPOST_PACKAGE_TEST_CODESIGN_COMMAND:-/usr/bin/codesign}"
if [[ "$package_fixture_mode" != "true" ]]; then
    xcodebuild_command="/usr/bin/xcodebuild"
    codesign_command="/usr/bin/codesign"
elif [[ -z "${PLAINPOST_PACKAGE_TEST_XCODEBUILD_COMMAND:-}" ||
        -z "${PLAINPOST_PACKAGE_TEST_CODESIGN_COMMAND:-}" ]]; then
    xcodebuild_command="/usr/bin/false"
    codesign_command="/usr/bin/false"
else
    xcodebuild_command="$(
        plainpost_fixture_tool_path \
            "$xcodebuild_command" \
            "Fixture Xcodebuild command"
    )"
    codesign_command="$(
        plainpost_fixture_tool_path \
            "$codesign_command" \
            "Fixture codesign command"
    )"
fi

if [[ ! -x "$agent_binary" ]]; then
    echo "Missing built background agent: $agent_binary" >&2
    exit 1
fi
if [[ ! -x "$bridge_binary" ]]; then
    echo "Missing built browser bridge: $bridge_binary" >&2
    exit 1
fi
if [[ ! -x "$cli_binary" ]]; then
    echo "Missing built CLI: $cli_binary" >&2
    exit 1
fi
if [[ ! -x "$service_binary" ]]; then
    echo "Missing built service: $service_binary" >&2
    exit 1
fi
if [[ ! "$launch_agent_label" =~ ^[[:alnum:]][[:alnum:]._-]*$ ]]; then
    echo "Invalid PLAINPOST_LAUNCH_AGENT_LABEL." >&2
    exit 1
fi

package_preflight_directory="$(
    /usr/bin/mktemp -d \
        "${TMPDIR:-/tmp}/plainpost-package-preflight.XXXXXX"
)"
cleanup_package_preflight() {
    if [[ -n "$package_preflight_directory" &&
          -d "$package_preflight_directory" ]]; then
        rm -rf -- "$package_preflight_directory"
    fi
}
trap cleanup_package_preflight EXIT

reject_service_info() {
    echo \
        "Service Info.plist does not match the committed packaging contract." \
        >&2
    exit 1
}

reject_service_entitlements() {
    echo \
        "Service entitlements do not match the committed packaging contract." \
        >&2
    exit 1
}

reject_app_entitlements() {
    echo \
        "App entitlements do not match the committed packaging contract." \
        >&2
    exit 1
}

sha256_file() {
    /usr/bin/shasum -a 256 "$1" |
        /usr/bin/awk '{ print toupper($1) }'
}

require_plist_value() {
    local plist_path="$1"
    local key_path="$2"
    local expected_type="$3"
    local expected="$4"
    local rejection_function="$5"
    local actual

    actual="$(
        /usr/bin/plutil -extract "$key_path" raw \
            -expect "$expected_type" -o - \
            "$plist_path" 2>/dev/null
    )" || "$rejection_function"
    [[ "$actual" == "$expected" ]] || "$rejection_function"
}

validated_service_info_plist="$package_preflight_directory/Info.plist"
validated_service_entitlements="$package_preflight_directory/PlainpostService.entitlements"
validated_app_entitlements="$package_preflight_directory/PlainpostApp.entitlements"
[[ -f "$service_info_plist" && ! -L "$service_info_plist" ]] ||
    reject_service_info
[[ -f "$service_entitlements" && ! -L "$service_entitlements" ]] ||
    reject_service_entitlements
[[ -f "$app_entitlements" && ! -L "$app_entitlements" ]] ||
    reject_app_entitlements
/usr/bin/ditto "$service_info_plist" "$validated_service_info_plist" ||
    reject_service_info
/usr/bin/ditto "$service_entitlements" "$validated_service_entitlements" ||
    reject_service_entitlements
/usr/bin/ditto "$app_entitlements" "$validated_app_entitlements" ||
    reject_app_entitlements
/usr/bin/plutil -lint "$validated_service_info_plist" >/dev/null 2>&1 ||
    reject_service_info
/usr/bin/plutil -lint "$validated_service_entitlements" >/dev/null 2>&1 ||
    reject_service_entitlements
/usr/bin/plutil -lint "$validated_app_entitlements" >/dev/null 2>&1 ||
    reject_app_entitlements

require_plist_value \
    "$validated_service_info_plist" CFBundleDevelopmentRegion string en \
    reject_service_info
require_plist_value \
    "$validated_service_info_plist" CFBundleExecutable string PlainpostService \
    reject_service_info
require_plist_value \
    "$validated_service_info_plist" CFBundleIdentifier string \
    com.marynavdovenko.Plainpost.Service reject_service_info
require_plist_value \
    "$validated_service_info_plist" CFBundleInfoDictionaryVersion string 6.0 \
    reject_service_info
require_plist_value \
    "$validated_service_info_plist" CFBundleName string PlainpostService \
    reject_service_info
require_plist_value \
    "$validated_service_info_plist" CFBundlePackageType string APPL \
    reject_service_info
require_plist_value \
    "$validated_service_info_plist" CFBundleShortVersionString string 0.1.0 \
    reject_service_info
require_plist_value \
    "$validated_service_info_plist" CFBundleVersion string 1 \
    reject_service_info
require_plist_value \
    "$validated_service_info_plist" LSBackgroundOnly bool true \
    reject_service_info
require_plist_value \
    "$validated_service_info_plist" LSMinimumSystemVersion string 26.0 \
    reject_service_info

service_info_key_scratch="$package_preflight_directory/info-keys.plist"
/usr/bin/ditto "$validated_service_info_plist" "$service_info_key_scratch" ||
    reject_service_info
for service_info_key in \
    CFBundleDevelopmentRegion \
    CFBundleExecutable \
    CFBundleIdentifier \
    CFBundleInfoDictionaryVersion \
    CFBundleName \
    CFBundlePackageType \
    CFBundleShortVersionString \
    CFBundleVersion \
    LSBackgroundOnly \
    LSMinimumSystemVersion; do
    /usr/libexec/PlistBuddy \
        -c "Delete :$service_info_key" \
        "$service_info_key_scratch" >/dev/null 2>&1 ||
        reject_service_info
done
[[ "$(
    /usr/bin/plutil -convert json -o - \
        "$service_info_key_scratch" 2>/dev/null
)" == "{}" ]] || reject_service_info

require_plist_value \
    "$validated_service_entitlements" \
    'com\.apple\.application-identifier' \
    string "$required_service_application_identifier" \
    reject_service_entitlements
require_plist_value \
    "$validated_service_entitlements" \
    'com\.apple\.developer\.team-identifier' \
    string "$required_team_identifier" reject_service_entitlements
service_keychain_group_count="$(
    /usr/bin/plutil -extract keychain-access-groups raw \
        -expect array -o - \
        "$validated_service_entitlements" 2>/dev/null
)" || reject_service_entitlements
[[ "$service_keychain_group_count" == "1" ]] ||
    reject_service_entitlements
require_plist_value \
    "$validated_service_entitlements" keychain-access-groups.0 string \
    "$required_service_keychain_group" reject_service_entitlements

service_entitlement_key_scratch="$package_preflight_directory/entitlement-keys.plist"
/usr/bin/ditto \
    "$validated_service_entitlements" \
    "$service_entitlement_key_scratch" ||
    reject_service_entitlements
for service_entitlement_key in \
    com.apple.application-identifier \
    com.apple.developer.team-identifier \
    keychain-access-groups; do
    /usr/libexec/PlistBuddy \
        -c "Delete :$service_entitlement_key" \
        "$service_entitlement_key_scratch" >/dev/null 2>&1 ||
        reject_service_entitlements
done
[[ "$(
    /usr/bin/plutil -convert json -o - \
        "$service_entitlement_key_scratch" 2>/dev/null
)" == "{}" ]] || reject_service_entitlements

require_plist_value \
    "$validated_app_entitlements" \
    'com\.apple\.application-identifier' \
    string "$required_app_application_identifier" \
    reject_app_entitlements
require_plist_value \
    "$validated_app_entitlements" \
    'com\.apple\.developer\.team-identifier' \
    string "$required_team_identifier" reject_app_entitlements
app_sign_in_mode_count="$(
    /usr/bin/plutil -extract 'com\.apple\.developer\.applesignin' raw \
        -expect array -o - \
        "$validated_app_entitlements" 2>/dev/null
)" || reject_app_entitlements
[[ "$app_sign_in_mode_count" == "1" ]] || reject_app_entitlements
require_plist_value \
    "$validated_app_entitlements" \
    'com\.apple\.developer\.applesignin.0' string Default \
    reject_app_entitlements
require_plist_value \
    "$validated_app_entitlements" \
    'com\.apple\.security\.personal-information\.addressbook' bool true \
    reject_app_entitlements
require_plist_value \
    "$validated_app_entitlements" \
    'com\.apple\.security\.personal-information\.calendars' bool true \
    reject_app_entitlements
app_keychain_group_count="$(
    /usr/bin/plutil -extract keychain-access-groups raw \
        -expect array -o - \
        "$validated_app_entitlements" 2>/dev/null
)" || reject_app_entitlements
[[ "$app_keychain_group_count" == "1" ]] || reject_app_entitlements
require_plist_value \
    "$validated_app_entitlements" keychain-access-groups.0 string \
    "$required_service_keychain_group" reject_app_entitlements

app_entitlement_key_scratch="$package_preflight_directory/app-entitlement-keys.plist"
/usr/bin/ditto \
    "$validated_app_entitlements" \
    "$app_entitlement_key_scratch" ||
    reject_app_entitlements
for app_entitlement_key in \
    com.apple.application-identifier \
    com.apple.developer.team-identifier \
    com.apple.developer.applesignin \
    com.apple.security.personal-information.addressbook \
    com.apple.security.personal-information.calendars \
    keychain-access-groups; do
    /usr/libexec/PlistBuddy \
        -c "Delete :$app_entitlement_key" \
        "$app_entitlement_key_scratch" >/dev/null 2>&1 ||
        reject_app_entitlements
done
[[ "$(
    /usr/bin/plutil -convert json -o - \
        "$app_entitlement_key_scratch" 2>/dev/null
)" == "{}" ]] || reject_app_entitlements

validated_service_info_sha256="$(
    sha256_file "$validated_service_info_plist"
)"
validated_service_entitlements_sha256="$(
    sha256_file "$validated_service_entitlements"
)"
validated_app_entitlements_sha256="$(
    sha256_file "$validated_app_entitlements"
)"

identity_metadata="$("$signing_identity_script" "$configuration" --metadata)"
IFS='|' read -r signing_identity signing_certificate_sha256 identity_extra \
    <<< "$identity_metadata"
if [[ -n "${identity_extra:-}" || -z "$signing_identity" || -z "$signing_certificate_sha256" ]]; then
    echo "Signing identity validation returned malformed metadata." >&2
    exit 1
fi

reject_service_profile() {
    echo "$1" >&2
    exit 1
}

reject_app_profile() {
    echo "$1" >&2
    exit 1
}

profile_decoder_command=""
if [[ "$package_fixture_mode" == "true" ]]; then
    profile_decoder_command="${PLAINPOST_PACKAGE_TEST_PROFILE_DECODER_COMMAND:-}"
    [[ -n "$profile_decoder_command" ]] || reject_service_profile \
        "Structural fixture mode requires a fixture profile decoder."
    profile_decoder_command="$(
        plainpost_fixture_tool_path \
            "$profile_decoder_command" \
            "Fixture profile decoder command"
    )"
fi

if [[ "$signing_identity" != "-" ]]; then
    app_provisioning_profile="${PLAINPOST_APP_PROVISIONING_PROFILE:-}"
    if [[ -z "$app_provisioning_profile" ||
          "$app_provisioning_profile" != /* ||
          ! -f "$app_provisioning_profile" ||
          -L "$app_provisioning_profile" ]]; then
        reject_app_profile \
            "Signed app packaging requires PLAINPOST_APP_PROVISIONING_PROFILE."
    fi

    validated_app_profile="$package_preflight_directory/PlainpostApp.provisionprofile"
    /usr/bin/ditto "$app_provisioning_profile" "$validated_app_profile" ||
        reject_app_profile \
            "The app provisioning profile could not be snapshotted."
    validated_app_profile_sha256="$(sha256_file "$validated_app_profile")"
    decoded_app_profile="$package_preflight_directory/app-profile.plist"
    if [[ -n "$profile_decoder_command" ]]; then
        "$profile_decoder_command" "$validated_app_profile" \
            > "$decoded_app_profile" ||
            reject_app_profile \
                "The app provisioning profile could not be decoded."
    else
        /usr/bin/security cms -D -i "$validated_app_profile" \
            > "$decoded_app_profile" 2>/dev/null ||
            reject_app_profile \
                "The app provisioning profile could not be decoded."
    fi
    /usr/bin/plutil -lint "$decoded_app_profile" >/dev/null 2>&1 ||
        reject_app_profile \
            "The decoded app provisioning profile is not a property list."
    [[ "$(sha256_file "$validated_app_profile")" == "$validated_app_profile_sha256" ]] ||
        reject_app_profile \
            "The app provisioning profile snapshot changed during validation."

    app_profile_team_count="$(
        /usr/bin/plutil -extract TeamIdentifier raw -o - \
            "$decoded_app_profile" 2>/dev/null
    )" || reject_app_profile \
        "The app provisioning profile must contain team identifier $required_team_identifier."
    [[ "$app_profile_team_count" == "1" ]] || reject_app_profile \
        "The app provisioning profile must contain team identifier $required_team_identifier."
    app_profile_team_identifier="$(
        /usr/bin/plutil -extract TeamIdentifier.0 raw -o - \
            "$decoded_app_profile" 2>/dev/null
    )" || reject_app_profile \
        "The app provisioning profile must contain team identifier $required_team_identifier."
    [[ "$app_profile_team_identifier" == "$required_team_identifier" ]] ||
        reject_app_profile \
            "The app provisioning profile must contain team identifier $required_team_identifier."

    app_profile_application_identifier="$(
        /usr/bin/plutil -extract \
            'Entitlements.com\.apple\.application-identifier' raw -o - \
            "$decoded_app_profile" 2>/dev/null
    )" || reject_app_profile \
        "The app provisioning profile must contain application identifier $required_app_application_identifier."
    [[ "$app_profile_application_identifier" != *"*"* ]] ||
        reject_app_profile \
            "The app provisioning profile contains a wildcard application identifier."
    [[ "$app_profile_application_identifier" == "$required_app_application_identifier" ]] ||
        reject_app_profile \
            "The app provisioning profile must contain application identifier $required_app_application_identifier."

    app_profile_keychain_group_count="$(
        /usr/bin/plutil -extract Entitlements.keychain-access-groups raw -o - \
            "$decoded_app_profile" 2>/dev/null
    )" || reject_app_profile \
        "The app provisioning profile must contain keychain group $required_service_keychain_group."
    matching_app_keychain_group=false
    for ((profile_index = 0; profile_index < app_profile_keychain_group_count; profile_index++)); do
        app_profile_keychain_group="$(
            /usr/bin/plutil -extract \
                "Entitlements.keychain-access-groups.$profile_index" raw -o - \
                "$decoded_app_profile" 2>/dev/null
        )" || reject_app_profile \
            "The app provisioning profile has an invalid keychain access group."
        if [[ "$app_profile_keychain_group" == "$required_service_keychain_group" ||
              "$app_profile_keychain_group" == "$allowed_profile_keychain_group" ]]; then
            matching_app_keychain_group=true
        fi
    done
    [[ "$matching_app_keychain_group" == "true" ]] || reject_app_profile \
        "The app provisioning profile must contain keychain group $required_service_keychain_group."

    app_profile_sign_in_count="$(
        /usr/bin/plutil -extract \
            'Entitlements.com\.apple\.developer\.applesignin' raw -o - \
            "$decoded_app_profile" 2>/dev/null
    )" || reject_app_profile \
        "The app provisioning profile must enable Sign in with Apple."
    [[ "$app_profile_sign_in_count" == "1" ]] || reject_app_profile \
        "The app provisioning profile must enable Sign in with Apple."
    app_profile_sign_in_mode="$(
        /usr/bin/plutil -extract \
            'Entitlements.com\.apple\.developer\.applesignin.0' raw -o - \
            "$decoded_app_profile" 2>/dev/null
    )" || reject_app_profile \
        "The app provisioning profile must enable Sign in with Apple."
    [[ "$app_profile_sign_in_mode" == "Default" ]] || reject_app_profile \
        "The app provisioning profile must enable Sign in with Apple."

    app_profile_expiration="$(
        /usr/bin/plutil -extract ExpirationDate raw -o - \
            "$decoded_app_profile" 2>/dev/null
    )" || reject_app_profile \
        "The app provisioning profile must contain a valid expiration date."
    app_profile_expiration_epoch="$(
        /bin/date -j -u -f "%Y-%m-%dT%H:%M:%SZ" \
            "$app_profile_expiration" "+%s" 2>/dev/null
    )" || reject_app_profile \
        "The app provisioning profile must contain a valid expiration date."
    current_epoch="$(/bin/date -u "+%s")"
    ((app_profile_expiration_epoch > current_epoch)) ||
        reject_app_profile \
            "The app provisioning profile has expired."

    app_profile_certificate_count="$(
        /usr/bin/plutil -extract DeveloperCertificates raw -o - \
            "$decoded_app_profile" 2>/dev/null
    )" || reject_app_profile \
        "The app provisioning profile contains no developer certificates."
    matching_app_developer_certificate=false
    for ((profile_index = 0; profile_index < app_profile_certificate_count; profile_index++)); do
        app_profile_certificate_path="$package_preflight_directory/app-certificate-$profile_index.der"
        /usr/bin/plutil -extract "DeveloperCertificates.$profile_index" raw -o - \
            "$decoded_app_profile" 2>/dev/null |
            /usr/bin/base64 -D > "$app_profile_certificate_path" ||
            reject_app_profile \
                "The app provisioning profile contains an invalid developer certificate."
        app_profile_certificate_sha256="$(sha256_file "$app_profile_certificate_path")"
        if [[ "$app_profile_certificate_sha256" == "$signing_certificate_sha256" ]]; then
            matching_app_developer_certificate=true
        fi
    done
    [[ "$matching_app_developer_certificate" == "true" ]] ||
        reject_app_profile \
            "The app provisioning profile does not contain the selected Apple Development certificate."

    service_provisioning_profile="${PLAINPOST_SERVICE_PROVISIONING_PROFILE:-}"
    if [[ -z "$service_provisioning_profile" ||
          "$service_provisioning_profile" != /* ||
          ! -f "$service_provisioning_profile" ||
          -L "$service_provisioning_profile" ]]; then
        reject_service_profile \
            "Signed service packaging requires PLAINPOST_SERVICE_PROVISIONING_PROFILE."
    fi

    validated_service_profile="$package_preflight_directory/embedded.provisionprofile"
    /usr/bin/ditto "$service_provisioning_profile" "$validated_service_profile" ||
        reject_service_profile \
            "The service provisioning profile could not be snapshotted."
    validated_service_profile_sha256="$(
        sha256_file "$validated_service_profile"
    )"
    decoded_service_profile="$package_preflight_directory/profile.plist"
    if [[ -n "$profile_decoder_command" ]]; then
        "$profile_decoder_command" "$validated_service_profile" \
            > "$decoded_service_profile" ||
            reject_service_profile \
                "The service provisioning profile could not be decoded."
    else
        /usr/bin/security cms -D -i "$validated_service_profile" \
            > "$decoded_service_profile" 2>/dev/null ||
            reject_service_profile \
                "The service provisioning profile could not be decoded."
    fi
    /usr/bin/plutil -lint "$decoded_service_profile" >/dev/null 2>&1 ||
        reject_service_profile \
            "The decoded service provisioning profile is not a property list."
    [[ "$(sha256_file "$validated_service_profile")" == "$validated_service_profile_sha256" ]] ||
        reject_service_profile \
            "The service provisioning profile snapshot changed during validation."

    profile_team_count="$(
        /usr/bin/plutil -extract TeamIdentifier raw -o - \
            "$decoded_service_profile" 2>/dev/null
    )" || reject_service_profile \
        "The service provisioning profile must contain team identifier $required_team_identifier."
    [[ "$profile_team_count" == "1" ]] || reject_service_profile \
        "The service provisioning profile must contain team identifier $required_team_identifier."
    profile_team_identifier="$(
        /usr/bin/plutil -extract TeamIdentifier.0 raw -o - \
            "$decoded_service_profile" 2>/dev/null
    )" || reject_service_profile \
        "The service provisioning profile must contain team identifier $required_team_identifier."
    [[ "$profile_team_identifier" == "$required_team_identifier" ]] ||
        reject_service_profile \
            "The service provisioning profile must contain team identifier $required_team_identifier."

    profile_application_identifier="$(
        /usr/bin/plutil -extract \
            'Entitlements.com\.apple\.application-identifier' raw -o - \
            "$decoded_service_profile" 2>/dev/null
    )" || reject_service_profile \
        "The service provisioning profile must contain application identifier $required_service_application_identifier."
    [[ "$profile_application_identifier" != *"*"* ]] ||
        reject_service_profile \
            "The service provisioning profile contains a wildcard application identifier."
    [[ "$profile_application_identifier" == "$required_service_application_identifier" ]] ||
        reject_service_profile \
            "The service provisioning profile must contain application identifier $required_service_application_identifier."

    profile_keychain_group_count="$(
        /usr/bin/plutil -extract Entitlements.keychain-access-groups raw -o - \
            "$decoded_service_profile" 2>/dev/null
    )" || reject_service_profile \
        "The service provisioning profile must contain keychain group $required_service_keychain_group."
    matching_keychain_group=false
    for ((profile_index = 0; profile_index < profile_keychain_group_count; profile_index++)); do
        profile_keychain_group="$(
            /usr/bin/plutil -extract \
                "Entitlements.keychain-access-groups.$profile_index" raw -o - \
                "$decoded_service_profile" 2>/dev/null
        )" || reject_service_profile \
            "The service provisioning profile has an invalid keychain access group."
        if [[ "$profile_keychain_group" == "$required_service_keychain_group" ||
              "$profile_keychain_group" == "$allowed_profile_keychain_group" ]]; then
            matching_keychain_group=true
        fi
    done
    [[ "$matching_keychain_group" == "true" ]] || reject_service_profile \
        "The service provisioning profile must contain keychain group $required_service_keychain_group."

    profile_expiration="$(
        /usr/bin/plutil -extract ExpirationDate raw -o - \
            "$decoded_service_profile" 2>/dev/null
    )" || reject_service_profile \
        "The service provisioning profile must contain a valid expiration date."
    profile_expiration_epoch="$(
        /bin/date -j -u -f "%Y-%m-%dT%H:%M:%SZ" \
            "$profile_expiration" "+%s" 2>/dev/null
    )" || reject_service_profile \
        "The service provisioning profile must contain a valid expiration date."
    current_epoch="$(/bin/date -u "+%s")"
    ((profile_expiration_epoch > current_epoch)) ||
        reject_service_profile \
            "The service provisioning profile has expired."

    profile_certificate_count="$(
        /usr/bin/plutil -extract DeveloperCertificates raw -o - \
            "$decoded_service_profile" 2>/dev/null
    )" || reject_service_profile \
        "The service provisioning profile contains no developer certificates."
    matching_developer_certificate=false
    for ((profile_index = 0; profile_index < profile_certificate_count; profile_index++)); do
        profile_certificate_path="$package_preflight_directory/certificate-$profile_index.der"
        /usr/bin/plutil -extract "DeveloperCertificates.$profile_index" raw -o - \
            "$decoded_service_profile" 2>/dev/null |
            /usr/bin/base64 -D > "$profile_certificate_path" ||
            reject_service_profile \
                "The service provisioning profile contains an invalid developer certificate."
        profile_certificate_sha256="$(
            /usr/bin/shasum -a 256 "$profile_certificate_path" |
                /usr/bin/awk '{ print toupper($1) }'
        )"
        if [[ "$profile_certificate_sha256" == "$signing_certificate_sha256" ]]; then
            matching_developer_certificate=true
        fi
    done
    [[ "$matching_developer_certificate" == "true" ]] ||
        reject_service_profile \
            "The service provisioning profile does not contain the selected Apple Development certificate."
else
    app_provisioning_profile=""
    validated_app_profile_sha256=""
    service_provisioning_profile=""
    validated_service_profile_sha256=""
fi

assert_package_preflight_integrity() {
    [[ "$(sha256_file "$validated_service_info_plist")" == "$validated_service_info_sha256" ]] ||
        reject_service_info
    [[ "$(sha256_file "$validated_service_entitlements")" == "$validated_service_entitlements_sha256" ]] ||
        reject_service_entitlements
    [[ "$(sha256_file "$validated_app_entitlements")" == "$validated_app_entitlements_sha256" ]] ||
        reject_app_entitlements
    if [[ "$signing_identity" != "-" ]]; then
        [[ "$(sha256_file "$validated_app_profile")" == "$validated_app_profile_sha256" ]] ||
            reject_app_profile \
                "The app provisioning profile snapshot changed during validation."
        [[ "$(sha256_file "$validated_service_profile")" == "$validated_service_profile_sha256" ]] ||
            reject_service_profile \
                "The service provisioning profile snapshot changed during validation."
    fi
}

assert_package_preflight_integrity
/bin/chmod 400 \
    "$validated_service_info_plist" \
    "$validated_service_entitlements" \
    "$validated_app_entitlements"
if [[ "$signing_identity" != "-" ]]; then
    /bin/chmod 400 "$validated_app_profile" "$validated_service_profile"
fi

prepare_bundle_output_parent
cd -P "$bundle_parent"
if [[ -n "${PLAINPOST_PACKAGE_TEST_HOOK:-}" ]]; then
    "$PLAINPOST_PACKAGE_TEST_HOOK"
fi
pinned_bundle="$(/bin/pwd -P)/$bundle_leaf"

if [[ "$package_fixture_mode" == "true" ]]; then
"$xcodebuild_command" \
    -project "$root_dir/Plainpost.xcodeproj" \
    -scheme Plainpost \
    -configuration "$xcode_configuration" \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build
else
    rtk proxy python3 "$build_artifacts" build --root "$root_dir" --cache "$derived_data" \
      --configuration "$xcode_configuration" --signing unsigned \
      --receipt "$derived_data/plainpost-app-receipt.json" \
      --product "app=Build/Products/$xcode_configuration/Plainpost.app" -- \
      "$xcodebuild_command" -project "$root_dir/Plainpost.xcodeproj" -scheme Plainpost \
      -configuration "$xcode_configuration" -sdk macosx -derivedDataPath "$derived_data" \
      CODE_SIGNING_ALLOWED=NO build
    for receipt in "${helper_receipts[@]}"; do
        rtk proxy python3 "$build_artifacts" verify --root "$root_dir" --configuration "$xcode_configuration" \
          --signing adhoc --receipt "$receipt"
    done
fi

if [[ ! -d "$native_bundle" ]]; then
    echo "Missing native Xcode application bundle: $native_bundle" >&2
    exit 1
fi

assert_package_preflight_integrity
"$runtime_stop_script" "$pinned_bundle" "$launch_agent_label"
rm -rf -- "$bundle_leaf"
/usr/bin/ditto "$native_bundle" "$bundle_leaf"
app_info_plist="$bundle_leaf/Contents/Info.plist"
reject_app_document_registration() {
    echo "Plainpost server setup document registration failed." >&2
    exit 1
}
[[ -f "$app_info_plist" && ! -L "$app_info_plist" ]] ||
    reject_app_document_registration
/usr/bin/plutil -lint "$app_info_plist" >/dev/null 2>&1 ||
    reject_app_document_registration
for registration_key in CFBundleDocumentTypes UTExportedTypeDeclarations; do
    if /usr/bin/plutil -extract "$registration_key" raw -o - \
        "$app_info_plist" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Delete :$registration_key" \
            "$app_info_plist" >/dev/null 2>&1 ||
            reject_app_document_registration
    fi
done
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes array" "$app_info_plist" ||
    reject_app_document_registration
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0 dict" "$app_info_plist" ||
    reject_app_document_registration
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:CFBundleTypeName string 'Plainpost Server Setup'" "$app_info_plist" ||
    reject_app_document_registration
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string Viewer" "$app_info_plist" ||
    reject_app_document_registration
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:LSHandlerRank string Owner" "$app_info_plist" ||
    reject_app_document_registration
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes array" "$app_info_plist" ||
    reject_app_document_registration
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string com.marynavdovenko.plainpost.server-setup" "$app_info_plist" ||
    reject_app_document_registration
/usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations array" "$app_info_plist" ||
    reject_app_document_registration
/usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:0 dict" "$app_info_plist" ||
    reject_app_document_registration
/usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:0:UTTypeIdentifier string com.marynavdovenko.plainpost.server-setup" "$app_info_plist" ||
    reject_app_document_registration
/usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:0:UTTypeDescription string 'Plainpost Server Setup'" "$app_info_plist" ||
    reject_app_document_registration
/usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:0:UTTypeConformsTo array" "$app_info_plist" ||
    reject_app_document_registration
/usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:0:UTTypeConformsTo:0 string public.json" "$app_info_plist" ||
    reject_app_document_registration
/usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:0:UTTypeTagSpecification dict" "$app_info_plist" ||
    reject_app_document_registration
/usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension array" "$app_info_plist" ||
    reject_app_document_registration
/usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension:0 string plainpostserver" "$app_info_plist" ||
    reject_app_document_registration
/usr/bin/plutil -lint "$app_info_plist" >/dev/null 2>&1 ||
    reject_app_document_registration
require_plist_value "$app_info_plist" \
    CFBundleDocumentTypes.0.LSItemContentTypes.0 string \
    com.marynavdovenko.plainpost.server-setup reject_app_document_registration
require_plist_value "$app_info_plist" \
    UTExportedTypeDeclarations.0.UTTypeIdentifier string \
    com.marynavdovenko.plainpost.server-setup reject_app_document_registration
require_plist_value "$app_info_plist" \
    'UTExportedTypeDeclarations.0.UTTypeTagSpecification.public\.filename-extension.0' \
    string plainpostserver reject_app_document_registration
helper_bundle="$bundle_leaf/Contents/Library/Helpers/PlainpostBackgroundAgent.app"
mkdir -p "$helper_bundle/Contents/MacOS"
/usr/bin/ditto "$root_dir/Support/PlainpostBackgroundAgent/Info.plist" "$helper_bundle/Contents/Info.plist"
/usr/bin/ditto "$agent_binary" "$helper_bundle/Contents/MacOS/PlainpostBackgroundAgent"
chmod 755 "$helper_bundle/Contents/MacOS/PlainpostBackgroundAgent"
service_helper_bundle="$bundle_leaf/Contents/Library/Helpers/PlainpostService.app"
mkdir -p "$service_helper_bundle/Contents/MacOS"
/usr/bin/ditto \
    "$validated_service_info_plist" \
    "$service_helper_bundle/Contents/Info.plist"
/usr/bin/ditto "$service_binary" "$service_helper_bundle/Contents/MacOS/PlainpostService"
chmod 755 "$service_helper_bundle/Contents/MacOS/PlainpostService"
# SwiftPM resource bundles (the bundled Central configuration and account trust
# anchors) must sit in each helper's own Resources: a helper's Bundle.module
# looks there and traps when the bundle is missing. The products directory
# holds them next to the helper binaries.
swift_resource_directory="${service_binary%/*}"
for resource_bundle in "$swift_resource_directory"/*.bundle; do
    [[ -d "$resource_bundle" && ! -L "$resource_bundle" ]] || continue
    for helper in "$helper_bundle" "$service_helper_bundle"; do
        mkdir -p "$helper/Contents/Resources"
        /usr/bin/ditto "$resource_bundle" "$helper/Contents/Resources/${resource_bundle##*/}"
    done
done
if [[ "$package_fixture_mode" != "true" &&
      ! -d "$service_helper_bundle/Contents/Resources/Plainpost_PlainpostAccountRuntime.bundle" ]]; then
    echo "The service helper is missing Plainpost_PlainpostAccountRuntime.bundle; it would crash on its first account request." >&2
    exit 1
fi
bundled_launch_agent_directory="$bundle_leaf/Contents/Library/LaunchAgents"
bundled_launch_agent_plist="$bundled_launch_agent_directory/com.marynavdovenko.Plainpost.BackgroundAgent.plist"
mkdir -p "$bundled_launch_agent_directory"
/usr/bin/plutil -create xml1 "$bundled_launch_agent_plist"
/usr/libexec/PlistBuddy -c "Add :Label string $launch_agent_label" "$bundled_launch_agent_plist"
/usr/libexec/PlistBuddy -c \
    "Add :BundleProgram string Contents/Library/Helpers/PlainpostService.app/Contents/MacOS/PlainpostService" \
    "$bundled_launch_agent_plist"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$bundled_launch_agent_plist"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string PlainpostService" "$bundled_launch_agent_plist"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string --xpc-service" "$bundled_launch_agent_plist"
/usr/libexec/PlistBuddy -c "Add :ProcessType string Background" "$bundled_launch_agent_plist"
/usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$bundled_launch_agent_plist"
/usr/libexec/PlistBuddy -c "Add :KeepAlive dict" "$bundled_launch_agent_plist"
/usr/libexec/PlistBuddy -c "Add :KeepAlive:SuccessfulExit bool false" "$bundled_launch_agent_plist"
/usr/libexec/PlistBuddy -c "Add :ThrottleInterval integer 10" "$bundled_launch_agent_plist"
/usr/libexec/PlistBuddy -c "Add :MachServices dict" "$bundled_launch_agent_plist"
/usr/libexec/PlistBuddy -c "Add :MachServices:com.marynavdovenko.Plainpost.Service bool true" "$bundled_launch_agent_plist"
/usr/bin/plutil -lint "$bundled_launch_agent_plist" >/dev/null
# The login item launches the app itself with an explicit flag, so the app
# can trust that it was opened at login and start hidden. KeepAlive stays
# false: Quit means quit until the next login.
login_launch_agent_label="com.marynavdovenko.Plainpost.LoginApp"
login_launch_agent_plist="$bundled_launch_agent_directory/$login_launch_agent_label.plist"
reject_login_item() {
    echo "Plainpost login item registration failed." >&2
    exit 1
}
app_executable="$(
    /usr/bin/plutil -extract CFBundleExecutable raw -o - "$app_info_plist" 2>/dev/null
)" || reject_login_item
[[ "$app_executable" =~ ^[[:alnum:]][[:alnum:]._-]*$ &&
   -f "$bundle_leaf/Contents/MacOS/$app_executable" &&
   ! -L "$bundle_leaf/Contents/MacOS/$app_executable" ]] ||
    reject_login_item
/usr/bin/plutil -create xml1 "$login_launch_agent_plist"
/usr/libexec/PlistBuddy -c "Add :Label string $login_launch_agent_label" "$login_launch_agent_plist"
/usr/libexec/PlistBuddy -c "Add :BundleProgram string Contents/MacOS/$app_executable" "$login_launch_agent_plist"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$login_launch_agent_plist"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $app_executable" "$login_launch_agent_plist"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string --launched-at-login" "$login_launch_agent_plist"
/usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$login_launch_agent_plist"
/usr/libexec/PlistBuddy -c "Add :KeepAlive bool false" "$login_launch_agent_plist"
/usr/libexec/PlistBuddy -c "Add :LimitLoadToSessionType string Aqua" "$login_launch_agent_plist"
/usr/libexec/PlistBuddy -c "Add :AssociatedBundleIdentifiers array" "$login_launch_agent_plist"
/usr/libexec/PlistBuddy -c "Add :AssociatedBundleIdentifiers:0 string com.marynavdovenko.Plainpost" "$login_launch_agent_plist"
/usr/bin/plutil -lint "$login_launch_agent_plist" >/dev/null || reject_login_item
/usr/bin/ditto "$bridge_binary" "$bundle_leaf/Contents/MacOS/PlainpostBrowserBridge"
chmod 755 "$bundle_leaf/Contents/MacOS/PlainpostBrowserBridge"
/usr/bin/ditto "$cli_binary" "$bundle_leaf/Contents/MacOS/PlainpostCLI"
chmod 755 "$bundle_leaf/Contents/MacOS/PlainpostCLI"
if [[ "$signing_identity" != "-" ]]; then
    assert_package_preflight_integrity
    /usr/bin/ditto \
        "$validated_app_profile" \
        "$bundle_leaf/Contents/embedded.provisionprofile"
    /usr/bin/ditto \
        "$validated_service_profile" \
        "$service_helper_bundle/Contents/embedded.provisionprofile"
fi

container_identifier="${PLAINPOST_ICLOUD_CONTAINER_IDENTIFIER:-}"
if [[ "$configuration" == "release" && "$signing_identity" == "-" ]]; then
    echo "Release packaging requires PLAINPOST_CODESIGN_IDENTITY." >&2
    exit 1
fi
timestamp_argument="--timestamp=none"
agent_signing_arguments=(
    --force
    --sign "$signing_identity"
    "$timestamp_argument"
    --identifier com.marynavdovenko.Plainpost.BackgroundAgent
)
service_signing_arguments=(
    --force
    --sign "$signing_identity"
    "$timestamp_argument"
    --identifier com.marynavdovenko.Plainpost.Service
)
runtime_options=()
app_entitlement_arguments=()
if [[ "$signing_identity" != "-" ]]; then
    runtime_options=(--options runtime)
    app_entitlement_arguments=(
        --entitlements "$validated_app_entitlements"
    )
    service_signing_arguments+=(
        --entitlements "$validated_service_entitlements"
    )
else
    echo \
        "Warning: ad-hoc debug package is for source/UI testing only; its service is not a signed vault runtime." \
        >&2
fi
if [[ -n "$container_identifier" ]]; then
    if [[ "$container_identifier" != iCloud.* ]]; then
        echo "CloudKit container identifiers must start with iCloud." >&2
        exit 1
    fi
    if [[ "$signing_identity" == "-" ]]; then
        echo "CloudKit packaging requires PLAINPOST_CODESIGN_IDENTITY." >&2
        exit 1
    fi
    generated_entitlements="$root_dir/.build/PlainpostBackgroundAgent.entitlements"
    /usr/bin/sed "s|__PLAINPOST_ICLOUD_CONTAINER_IDENTIFIER__|$container_identifier|g" \
        "$root_dir/Support/PlainpostBackgroundAgent/PlainpostBackgroundAgent.entitlements.template" \
        > "$generated_entitlements"
    /usr/bin/plutil -lint "$generated_entitlements" >/dev/null
    agent_signing_arguments+=(--entitlements "$generated_entitlements")
fi
for embedded_binary in "$bundle_leaf/Contents/MacOS/"*.dylib; do
    if [[ -f "$embedded_binary" ]]; then
        "$codesign_command" --force --sign "$signing_identity" "$timestamp_argument" "${runtime_options[@]}" "$embedded_binary"
        "$codesign_command" --verify --strict "$embedded_binary"
    fi
done
"$codesign_command" \
    --force --sign "$signing_identity" "$timestamp_argument" \
    --identifier com.marynavdovenko.Plainpost.CLI \
    "${runtime_options[@]}" \
    "$bundle_leaf/Contents/MacOS/PlainpostCLI"
"$codesign_command" --verify --strict "$bundle_leaf/Contents/MacOS/PlainpostCLI"
"$codesign_command" \
    --force --sign "$signing_identity" "$timestamp_argument" \
    --identifier com.marynavdovenko.Plainpost.BrowserHost \
    "${runtime_options[@]}" \
    "$bundle_leaf/Contents/MacOS/PlainpostBrowserBridge"
"$codesign_command" --verify --strict "$bundle_leaf/Contents/MacOS/PlainpostBrowserBridge"
"$codesign_command" \
    --force --sign "$signing_identity" "$timestamp_argument" \
    --identifier com.marynavdovenko.Plainpost.BackgroundAgent \
    "${runtime_options[@]}" \
    "$helper_bundle/Contents/MacOS/PlainpostBackgroundAgent"
"$codesign_command" \
    --verify --strict \
    "$helper_bundle/Contents/MacOS/PlainpostBackgroundAgent"
"$codesign_command" \
    --force --sign "$signing_identity" "$timestamp_argument" \
    --identifier com.marynavdovenko.Plainpost.Service \
    "${runtime_options[@]}" \
    "$service_helper_bundle/Contents/MacOS/PlainpostService"
"$codesign_command" \
    --verify --strict \
    "$service_helper_bundle/Contents/MacOS/PlainpostService"
"$codesign_command" "${agent_signing_arguments[@]}" "${runtime_options[@]}" "$helper_bundle"
"$codesign_command" --verify --strict "$helper_bundle"
assert_package_preflight_integrity
[[ "$(sha256_file "$service_helper_bundle/Contents/Info.plist")" == "$validated_service_info_sha256" ]] ||
    reject_service_info
if [[ "$signing_identity" != "-" ]]; then
    embedded_app_profile_sha256="$(
        sha256_file "$bundle_leaf/Contents/embedded.provisionprofile"
    )"
    [[ "$embedded_app_profile_sha256" == "$validated_app_profile_sha256" ]] ||
        reject_app_profile \
            "The embedded app provisioning profile changed before signing."
    embedded_service_profile_sha256="$(
        sha256_file "$service_helper_bundle/Contents/embedded.provisionprofile"
    )"
    [[ "$embedded_service_profile_sha256" == "$validated_service_profile_sha256" ]] ||
        reject_service_profile \
            "The embedded service provisioning profile changed before signing."
fi
"$codesign_command" \
    "${service_signing_arguments[@]}" \
    "${runtime_options[@]}" \
    "$service_helper_bundle"
"$codesign_command" --verify --strict "$service_helper_bundle"
"$codesign_command" \
    --force --sign "$signing_identity" "$timestamp_argument" \
    --identifier com.marynavdovenko.Plainpost \
    "${app_entitlement_arguments[@]}" \
    "${runtime_options[@]}" \
    "$bundle_leaf"
"$codesign_command" --verify --deep --strict "$bundle_leaf"

# The signed profile decides the effective groups. The service reads the
# account and Sync Node records from AccountShared, so a profile that drops
# it must fail the package, not the first Node request.
if [[ "$signing_identity" != "-" && "$package_fixture_mode" != "true" ]]; then
    effective_service_entitlements="$(
        /usr/bin/mktemp "${TMPDIR:-/tmp}/plainpost-service-entitlements.XXXXXX"
    )"
    if ! "$codesign_command" -d --entitlements :- "$service_helper_bundle" \
            >"$effective_service_entitlements" 2>/dev/null ||
        ! /usr/bin/plutil -extract keychain-access-groups json -o - \
            "$effective_service_entitlements" 2>/dev/null |
            /usr/bin/grep -Fq "\"$required_service_keychain_group\""; then
        /bin/rm -f "$effective_service_entitlements"
        echo "The signed service does not carry the $required_service_keychain_group Keychain group." >&2
        exit 1
    fi
    /bin/rm -f "$effective_service_entitlements"
fi

echo "$bundle"
