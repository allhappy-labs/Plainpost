#!/usr/bin/env bash
# Contract for the packaged login item and for stopping a packaged runtime
# without breaking the user's registered Plainpost.
#
# Runs package-app-bundle.sh and stop-packaged-runtime.sh in structural
# fixture mode only: fake xcodebuild, codesign, profile decoder and
# launchctl, inside a throwaway fixture root. It never signs, installs or
# calls the real launchctl.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
login_label="com.marynavdovenko.Plainpost.LoginApp"
service_label="com.marynavdovenko.Plainpost.BackgroundAgent"
app_bundle_identifier="com.marynavdovenko.Plainpost"
temporary_root="${TMPDIR:-/tmp}"
temporary_root="${temporary_root%/}"
fixture_roots=()
fixture_pids=()

# A recorded pid may have exited and been reused by an unrelated process:
# only kill it while lsof shows it still runs the fixture sleeper from one
# of this run's temporary roots.
pid_runs_fixture_sleeper() {
    local pid="$1"
    local text_paths
    local root
    local canonical
    text_paths="$(/usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null)" || return 1
    for root in ${fixture_roots[@]+"${fixture_roots[@]}"}; do
        canonical="$(cd -P "$root" 2>/dev/null && /bin/pwd -P)" || canonical="$root"
        if printf '%s\n' "$text_paths" |
            /usr/bin/awk -v lexical="n$root/" -v physical="n$canonical/" '
                index($0, lexical) == 1 || index($0, physical) == 1 { found = 1 }
                END { exit found ? 0 : 1 }
            '; then
            return 0
        fi
    done
    return 1
}

cleanup() {
    local pid
    local root
    for pid in ${fixture_pids[@]+"${fixture_pids[@]}"}; do
        if pid_runs_fixture_sleeper "$pid"; then
            /bin/kill -KILL "$pid" 2>/dev/null || true
        fi
    done
    for root in ${fixture_roots[@]+"${fixture_roots[@]}"}; do
        [[ "$root" == "$temporary_root"/plainpost-packaging-* ||
           "$root" == "$temporary_root"/plainpost-outside-* ]] &&
            /bin/rm -rf -- "$root"
    done
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "ok - $*"
}

new_fixture_root() {
    local uuid
    uuid="$(/usr/bin/uuidgen)"
    fixture_root="$temporary_root/plainpost-packaging-$uuid"
    /bin/mkdir -p "$fixture_root/Scripts/lib" "$fixture_root/.build"
    fixture_roots+=("$fixture_root")
    printf 'Plainpost package fixture v1\n' \
        >"$fixture_root/.plainpost-package-test-fixture"
    /bin/cp "$repo_root/Scripts/lib/plainpost-package-fixture-contract.sh" \
        "$fixture_root/Scripts/lib/"
}

copy_repository_file() {
    local relative_path="$1"
    /bin/mkdir -p "$fixture_root/$(dirname "$relative_path")"
    /bin/cp "$repo_root/$relative_path" "$fixture_root/$relative_path"
}

write_executable() {
    local relative_path="$1"
    local contents="$2"
    /bin/mkdir -p "$fixture_root/$(dirname "$relative_path")"
    printf '%s' "$contents" >"$fixture_root/$relative_path"
    /bin/chmod 755 "$fixture_root/$relative_path"
}

run_fixture_script() {
    local name="$1"
    shift
    set +e
    script_output="$(
        /usr/bin/env -i \
            PATH=/usr/bin:/bin:/usr/sbin:/sbin \
            HOME="$HOME" \
            TMPDIR="$temporary_root" \
            "$@" \
            /bin/bash "$fixture_root/Scripts/$name" \
                ${script_arguments[@]+"${script_arguments[@]}"} 2>&1
    )"
    script_status=$?
    set -e
}

plist_value() {
    /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

require_plist_value() {
    local plist="$1"
    local key="$2"
    local expected="$3"
    local actual
    actual="$(plist_value "$plist" "$key")" ||
        fail "$plist is missing $key"
    [[ "$actual" == "$expected" ]] ||
        fail "$plist $key is '$actual', expected '$expected'"
}

require_plist_type() {
    local plist="$1"
    local key="$2"
    local expected="$3"
    local actual
    actual="$(/usr/bin/plutil -type "$key" "$plist" 2>/dev/null)" ||
        fail "$plist is missing $key"
    [[ "$actual" == "$expected" ]] ||
        fail "$plist $key has type '$actual', expected '$expected'"
}

prepare_packaging_fixture() {
    new_fixture_root
    copy_repository_file Scripts/package-app-bundle.sh
    copy_repository_file Scripts/select-codesign-identity.sh
    copy_repository_file Support/PlainpostApp/Info.plist
    copy_repository_file Support/PlainpostApp/PlainpostApp.entitlements
    copy_repository_file Support/PlainpostBackgroundAgent/Info.plist
    copy_repository_file Support/PlainpostService/Info.plist
    copy_repository_file Support/PlainpostService/PlainpostService.entitlements
    write_executable .build/debug/PlainpostBackgroundAgent "background-agent sentinel"
    write_executable .build/debug/PlainpostBrowserBridge "browser-bridge sentinel"
    write_executable .build/debug/PlainpostService "service sentinel"
    write_executable .build/debug/plainpost "cli sentinel"
    native_app="$fixture_root/.build/xcode-derived/Build/Products/Debug/Plainpost.app"
    /bin/mkdir -p "$native_app/Contents/MacOS"
    /bin/cp "$repo_root/Support/PlainpostApp/Info.plist" "$native_app/Contents/Info.plist"
    write_executable \
        .build/xcode-derived/Build/Products/Debug/Plainpost.app/Contents/MacOS/Plainpost \
        "native-app sentinel"
    write_executable Scripts/stop-packaged-runtime.sh $'#!/bin/sh\nexit 0\n'
    write_executable fake-xcodebuild.sh $'#!/bin/sh\nexit 0\n'
    write_executable fake-codesign.sh $'#!/bin/sh\nexit 0\n'
    write_executable fake-profile-decoder.sh $'#!/bin/sh\n/bin/cat "$1"\n'
    packaged_bundle="$fixture_root/.build/PlainpostFixture.app"
}

run_packaging() {
    script_arguments=()
    run_fixture_script package-app-bundle.sh \
        PLAINPOST_PACKAGE_TEST_MODE=1 \
        PLAINPOST_PACKAGE_TEST_ROOT="$fixture_root" \
        PLAINPOST_RUNTIME_STOP_TEST_MODE=1 \
        PLAINPOST_RUNTIME_STOP_TEST_ROOT="$fixture_root" \
        PLAINPOST_APP_BUNDLE_OUTPUT="$packaged_bundle" \
        PLAINPOST_CODESIGN_IDENTITY= \
        PLAINPOST_PACKAGE_TEST_XCODEBUILD_COMMAND="$fixture_root/fake-xcodebuild.sh" \
        PLAINPOST_PACKAGE_TEST_CODESIGN_COMMAND="$fixture_root/fake-codesign.sh" \
        PLAINPOST_PACKAGE_TEST_PROFILE_DECODER_COMMAND="$fixture_root/fake-profile-decoder.sh"
}

# --- 1. The package carries the login item next to the service agent. ------
prepare_packaging_fixture
run_packaging
[[ "$script_status" -eq 0 ]] || fail "fixture packaging failed: $script_output"

login_plist="$packaged_bundle/Contents/Library/LaunchAgents/$login_label.plist"
service_plist="$packaged_bundle/Contents/Library/LaunchAgents/$service_label.plist"
[[ -f "$login_plist" && ! -L "$login_plist" ]] ||
    fail "the package has no login item plist at $login_plist"
/usr/bin/plutil -lint "$login_plist" >/dev/null || fail "login plist is malformed"
require_plist_value "$login_plist" Label "$login_label"
require_plist_value "$login_plist" BundleProgram "Contents/MacOS/Plainpost"
require_plist_type "$login_plist" ProgramArguments array
[[ "$(/usr/bin/plutil -extract ProgramArguments raw -o - "$login_plist")" == "2" ]] ||
    fail "login ProgramArguments must hold exactly the executable and the login flag"
require_plist_value "$login_plist" ProgramArguments.0 "Plainpost"
require_plist_value "$login_plist" ProgramArguments.1 "--launched-at-login"
require_plist_type "$login_plist" RunAtLoad bool
require_plist_value "$login_plist" RunAtLoad true
# KeepAlive false: Quit means quit, and stopping the process for a package
# replacement can never be undone by launchd respawning it.
require_plist_type "$login_plist" KeepAlive bool
require_plist_value "$login_plist" KeepAlive false
require_plist_value "$login_plist" LimitLoadToSessionType Aqua
require_plist_type "$login_plist" AssociatedBundleIdentifiers array
[[ "$(/usr/bin/plutil -extract AssociatedBundleIdentifiers raw -o - "$login_plist")" == "1" ]] ||
    fail "login AssociatedBundleIdentifiers must name only the app"
require_plist_value "$login_plist" AssociatedBundleIdentifiers.0 "$app_bundle_identifier"
if plist_value "$login_plist" MachServices >/dev/null; then
    fail "the login item must not claim Mach services"
fi
pass "login item plist carries the login flag and launches the app hidden at login"

# The service agent keeps the RunAtLoad/KeepAlive the Node mirror relies on
# for uptime while the app is closed.
require_plist_value "$service_plist" Label "$service_label"
require_plist_value "$service_plist" RunAtLoad true
require_plist_value "$service_plist" KeepAlive.SuccessfulExit false
require_plist_value "$service_plist" \
    BundleProgram "Contents/Library/Helpers/PlainpostService.app/Contents/MacOS/PlainpostService"
pass "service agent keeps RunAtLoad and KeepAlive for mirror uptime"

# The app registers exactly the names packaging writes.
swift_source="$repo_root/Sources/PlainpostCore/PlainpostLoginLaunch.swift"
/usr/bin/grep -Fq "public static let label = \"$login_label\"" "$swift_source" ||
    fail "PlainpostLoginLaunch.label does not match the packaged label"
/usr/bin/grep -Fq "public static let plistName = \"$login_label.plist\"" "$swift_source" ||
    fail "PlainpostLoginLaunch.plistName does not match the packaged plist"
/usr/bin/grep -Fq 'public static let argument = "--launched-at-login"' "$swift_source" ||
    fail "PlainpostLoginLaunch.argument does not match the packaged argument"
pass "app login-launch identifiers match the packaged plist"

# --- 2. An unsafe executable name never reaches the login plist. ----------
# '../Info.plist' names a file that exists, so only the name check stops it.
for executable_name in '../Info.plist' '../Plainpost' 'Plain post' ''; do
    prepare_packaging_fixture
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $executable_name" \
        "$native_app/Contents/Info.plist"
    run_packaging
    [[ "$script_status" -ne 0 ]] ||
        fail "packaging accepted CFBundleExecutable '$executable_name'"
    [[ ! -e "$packaged_bundle/Contents/Library/LaunchAgents/$login_label.plist" ]] ||
        fail "packaging wrote a login plist for CFBundleExecutable '$executable_name'"
done
pass "packaging refuses an unsafe app executable name"

# --- 3. Stopping a packaged runtime. ---------------------------------------
prepare_stop_fixture() {
    new_fixture_root
    copy_repository_file Scripts/stop-packaged-runtime.sh
    stop_bundle="$fixture_root/.build/PlainpostStopFixture.app"
    /bin/mkdir -p "$stop_bundle/Contents/MacOS"
    launchctl_log="$fixture_root/launchctl.log"
    : >"$launchctl_log"
    write_executable fake-launchctl.sh "#!/bin/bash
state_dir=\"$fixture_root/launchctl-state\"
/usr/bin/printf '%s\\n' \"\$*\" >> \"$launchctl_log\"
label=\"\${2##*/}\"
case \"\$1\" in
  print)
    [[ -f \"\$state_dir/\$label.loaded\" ]] || exit 113
    /usr/bin/printf '%s = {\\n' \"\$2\"
    /bin/cat \"\$state_dir/\$label.description\"
    ;;
  bootout)
    [[ -f \"\$state_dir/\$label.loaded\" ]] || exit 113
    /bin/rm -f \"\$state_dir/\$label.loaded\"
    ;;
  *) exit 73 ;;
esac
"
    /bin/mkdir -p "$fixture_root/launchctl-state"
}

load_job() {
    local label="$1"
    local program="$2"
    local mach_service="${3:-}"
    local state_dir="$fixture_root/launchctl-state"
    {
        printf '    program = %s\n' "$program"
        printf '    arguments = {\n        %s\n    }\n' "$program"
        if [[ -n "$mach_service" ]]; then
            printf '    mach services = {\n        "%s" => true\n    }\n' "$mach_service"
        fi
        printf '}\n'
    } >"$state_dir/$label.description"
    : >"$state_dir/$label.loaded"
}

job_loaded() {
    [[ -f "$fixture_root/launchctl-state/$1.loaded" ]]
}

# Starts a sleeper at an executable path with argv[0] set to its bare file
# name, the way launchd starts a job from ProgramArguments[0]; prints its pid.
start_launchd_style_process() {
    local executable="$1"
    /bin/mkdir -p "${executable%/*}"
    # A copied platform binary is killed at launch, so build a sleeper.
    if [[ ! -x "$fixture_root/sleeper" ]]; then
        printf '#include <unistd.h>\nint main(void) { sleep(60); return 0; }\n' \
            >"$fixture_root/sleeper.c"
        /usr/bin/clang "$fixture_root/sleeper.c" -o "$fixture_root/sleeper" ||
            fail "could not build the fixture process"
    fi
    /bin/cp "$fixture_root/sleeper" "$executable"
    (exec -a "${executable##*/}" "$executable") &
    started_pid=$!
    fixture_pids+=("$started_pid")
    /bin/sleep 0.2
    /bin/kill -0 "$started_pid" 2>/dev/null || fail "the fixture process did not start"
    [[ "$(/bin/ps -o comm= -p "$started_pid")" == "${executable##*/}" ]] ||
        fail "the fixture process does not carry a bare argv[0]"
}

start_bundle_app_process() {
    start_launchd_style_process "$stop_bundle/Contents/MacOS/Plainpost"
    app_pid=$started_pid
    start_launchd_style_process \
        "$stop_bundle/Contents/Library/Helpers/PlainpostService.app/Contents/MacOS/PlainpostService"
    service_pid=$started_pid
    # Same file names in another installation: never this bundle's runtime.
    start_launchd_style_process "$fixture_root/OtherInstall/PlainpostOther.app/Contents/MacOS/Plainpost"
    other_app_pid=$started_pid
    start_launchd_style_process \
        "$fixture_root/OtherInstall/PlainpostOther.app/Contents/Library/Helpers/PlainpostService.app/Contents/MacOS/PlainpostService"
    other_service_pid=$started_pid
    start_outside_fixture_process
}

# A same-named process outside the fixture root: the structural fixture
# guard in the stop script must never signal it, even if matching is wrong.
start_outside_fixture_process() {
    outside_root="$temporary_root/plainpost-outside-$(/usr/bin/uuidgen)"
    fixture_roots+=("$outside_root")
    start_launchd_style_process "$outside_root/Plainpost"
    outside_pid=$started_pid
}

require_other_installation_untouched() {
    /bin/kill -0 "$outside_pid" 2>/dev/null ||
        fail "a process outside the fixture root was signalled"
    /bin/kill -0 "$other_app_pid" 2>/dev/null ||
        fail "another installation's app with the same name was stopped"
    /bin/kill -0 "$other_service_pid" 2>/dev/null ||
        fail "another installation's service with the same name was stopped"
}

run_stop() {
    script_arguments=("$stop_bundle" "$service_label")
    run_fixture_script stop-packaged-runtime.sh \
        PLAINPOST_RUNTIME_STOP_TEST_MODE=1 \
        PLAINPOST_RUNTIME_STOP_TEST_ROOT="$fixture_root" \
        PLAINPOST_RUNTIME_STOP_TEST_LAUNCHCTL_COMMAND="$fixture_root/fake-launchctl.sh"
}

wait_for_exit() {
    local pid="$1"
    local attempt
    for attempt in {1..50}; do
        /bin/kill -0 "$pid" 2>/dev/null || return 0
        /bin/sleep 0.1
    done
    return 1
}

# 3a. Both jobs belong to the bundle being replaced: the service job is
# booted out (its KeepAlive would respawn the old binary), the app started
# by the login job is stopped, and the login registration is kept so the
# next login still opens Plainpost.
prepare_stop_fixture
load_job "$service_label" \
    "$stop_bundle/Contents/Library/Helpers/PlainpostService.app/Contents/MacOS/PlainpostService" \
    com.marynavdovenko.Plainpost.Service
load_job "$login_label" "$stop_bundle/Contents/MacOS/Plainpost"
start_bundle_app_process
run_stop
[[ "$script_status" -eq 0 ]] || fail "stop failed for this bundle's jobs: $script_output"
job_loaded "$service_label" && fail "this bundle's service job stayed loaded"
job_loaded "$login_label" || fail "the login job was booted out"
/usr/bin/grep -Fq "bootout gui/" "$launchctl_log" || fail "service job was not booted out"
/usr/bin/grep -Fq "bootout gui/$(/usr/bin/id -u)/$login_label" "$launchctl_log" &&
    fail "the login job must never be booted out"
wait_for_exit "$app_pid" || fail "the app started by the login job kept running"
wait_for_exit "$service_pid" || fail "the service started by launchd kept running"
require_other_installation_untouched
pass "stop boots out this bundle's service, stops its app and keeps the login item"

# 3b. Both jobs belong to another Plainpost, such as the user's registered
# /Applications/Plainpost.app: nothing is booted out, and packaging this
# bundle is not blocked by them.
prepare_stop_fixture
load_job "$service_label" \
    "/Applications/Plainpost.app/Contents/Library/Helpers/PlainpostService.app/Contents/MacOS/PlainpostService" \
    com.marynavdovenko.Plainpost.Service
load_job "$login_label" "/Applications/Plainpost.app/Contents/MacOS/Plainpost"
start_bundle_app_process
run_stop
[[ "$script_status" -eq 0 ]] ||
    fail "another Plainpost's registered jobs blocked the stop: $script_output"
job_loaded "$service_label" || fail "another Plainpost's service job was booted out"
job_loaded "$login_label" || fail "another Plainpost's login job was booted out"
/usr/bin/grep -Fq "bootout" "$launchctl_log" &&
    fail "a job outside the bundle being replaced was booted out"
wait_for_exit "$app_pid" || fail "this bundle's app process kept running"
require_other_installation_untouched
[[ "$script_output" == *"WARNING: LaunchAgent $service_label belongs to another Plainpost"* ]] ||
    fail "leaving a foreign job loaded printed no warning: $script_output"
pass "stop never boots out a registered Plainpost outside the bundle being replaced"

# 3c. A job naming this bundle but not its service keeps being refused with
# nothing booted out and nothing stopped.
prepare_stop_fixture
load_job "$service_label" "$stop_bundle/Contents/MacOS/UnrelatedService" \
    com.marynavdovenko.Plainpost.Service
start_bundle_app_process
run_stop
[[ "$script_status" -ne 0 ]] || fail "a mismatched job inside the bundle was accepted"
[[ "$script_output" == *"Loaded LaunchAgent does not match the Plainpost service runtime"* ]] ||
    fail "unexpected refusal: $script_output"
job_loaded "$service_label" || fail "a refused job was booted out"
/bin/kill -0 "$app_pid" 2>/dev/null || fail "a refused stop terminated processes"
pass "stop still refuses a mismatched job inside the bundle"

# 3d. A job whose description has no single program line is refused too:
# it cannot be proven to be somebody else's.
prepare_stop_fixture
load_job "$service_label" "/Applications/Plainpost.app/Contents/MacOS/Plainpost" \
    com.marynavdovenko.Plainpost.Service
printf '    program = %s\n    program = %s\n}\n' \
    "$stop_bundle/Contents/Library/Helpers/PlainpostService.app/Contents/MacOS/PlainpostService" \
    "/Applications/Plainpost.app/Contents/Library/Helpers/PlainpostService.app/Contents/MacOS/PlainpostService" \
    >"$fixture_root/launchctl-state/$service_label.description"
run_stop
[[ "$script_status" -ne 0 ]] || fail "an ambiguous job description was accepted"
job_loaded "$service_label" || fail "an ambiguous job was booted out"
pass "stop refuses an ambiguous job description"

echo "login item packaging contract passed"
