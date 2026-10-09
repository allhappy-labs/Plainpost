#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$root"
artifacts="$root/Scripts/lib/build_artifacts.py"
fixture_cache="$root/.build"
fixture_products="$(rtk proxy python3 "$artifacts" swift-products --root "$root" --cache "$fixture_cache" --signing adhoc)"
fixture="$fixture_products/PlainpostIOSMailFixture"
ledger="$root/.build/ios-standalone-mail-e2e-ledger.txt"
work=$(mktemp -d "${TMPDIR:-/tmp}/plainpost-ios-mail-e2e.XXXXXX")
fixture_pid=
cleanup() {
  if [[ -n "$fixture_pid" ]]; then
    if [[ -n "${PLAINPOST_MAIL_FIXTURE_CONTROL:-}" ]]; then
      python3 - "$PLAINPOST_MAIL_FIXTURE_CONTROL" <<'PY' >/dev/null 2>&1 || true
import sys, urllib.request
urllib.request.urlopen('http://127.0.0.1:' + sys.argv[1] + '/shutdown', timeout=2).close()
PY
    fi
    for _ in {1..20}; do
      kill -0 "$fixture_pid" 2>/dev/null || break
      sleep 0.1
    done
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

df_kb=$(df -Pk "$root" | awk 'NR==2 { print $4 }')
if (( df_kb < 15728640 )); then
  printf 'stage=disk outcome=fail reason=less-than-15-GiB-free\n' >&2
  exit 1
fi

rtk proxy python3 "$artifacts" build --root "$root" --cache "$fixture_cache" --signing adhoc \
  --receipt "$work/fixture-receipt.json" \
  --product "fixture=${fixture_products#"$fixture_cache/"}/PlainpostIOSMailFixture" -- \
  rtk proxy swift build --product PlainpostIOSMailFixture --scratch-path "$fixture_cache" >"$work/build.log" 2>&1 || {
  printf 'stage=fixture-build outcome=fail\n' >&2
  exit 1
}
rtk proxy python3 "$artifacts" verify --root "$root" --signing adhoc --receipt "$work/fixture-receipt.json"

"$fixture" "$work/readiness.json" >"$work/fixture.log" 2>&1 &
fixture_pid=$!
for _ in {1..100}; do
  [[ -s "$work/readiness.json" ]] && break
  kill -0 "$fixture_pid" 2>/dev/null || { printf 'stage=fixture outcome=fail reason=stopped\n' >&2; exit 1; }
  sleep 0.1
done
[[ -s "$work/readiness.json" ]] || { printf 'stage=fixture outcome=fail reason=readiness-timeout\n' >&2; exit 1; }

eval "$(python3 - "$work/readiness.json" <<'PY'
import json, shlex, sys
data = json.load(open(sys.argv[1]))
for env, field in [('PLAINPOST_MAIL_FIXTURE_CONTROL','controlPort'),
                   ('PLAINPOST_MAIL_FIXTURE_IMAP_PORT','imapPort'),
                   ('PLAINPOST_MAIL_FIXTURE_SMTP_PORT','smtpPort'),
                   ('PLAINPOST_MAIL_FIXTURE_IMAP_ANCHOR','anchor'),
                   ('PLAINPOST_MAIL_FIXTURE_SMTP_ANCHOR','smtpAnchor')]:
    print('export ' + env + '=' + shlex.quote(str(data[field])))
PY
)"
# Xcode injects TEST_RUNNER_* values into the UI test runner environment.
export TEST_RUNNER_PLAINPOST_MAIL_FIXTURE_CONTROL="$PLAINPOST_MAIL_FIXTURE_CONTROL"
export TEST_RUNNER_PLAINPOST_MAIL_FIXTURE_IMAP_PORT="$PLAINPOST_MAIL_FIXTURE_IMAP_PORT"
export TEST_RUNNER_PLAINPOST_MAIL_FIXTURE_SMTP_PORT="$PLAINPOST_MAIL_FIXTURE_SMTP_PORT"
export TEST_RUNNER_PLAINPOST_MAIL_FIXTURE_IMAP_ANCHOR="$PLAINPOST_MAIL_FIXTURE_IMAP_ANCHOR"
export TEST_RUNNER_PLAINPOST_MAIL_FIXTURE_SMTP_ANCHOR="$PLAINPOST_MAIL_FIXTURE_SMTP_ANCHOR"
export TEST_RUNNER_PLAINPOST_SETUP_ONLY="${PLAINPOST_SETUP_ONLY:-0}"
python3 - "$PLAINPOST_MAIL_FIXTURE_CONTROL" <<'PY'
import json, sys, urllib.request
with urllib.request.urlopen('http://127.0.0.1:' + sys.argv[1] + '/state', timeout=5) as response:
    assert json.load(response)['smtpDataCount'] == 0
PY

# Set PLAINPOST_IOS_SIMULATOR_ID to target a specific simulator instead of the default "iPhone 17 Pro" lookup.
simulator_id="${PLAINPOST_IOS_SIMULATOR_ID:-$(xcrun simctl list devices available -j | python3 -c 'import json,sys; devices=[d for group in json.load(sys.stdin)["devices"].values() for d in group if d["name"] == "iPhone 17 Pro" and d["isAvailable"]]; print(devices[0]["udid"] if devices else "")')}"
[[ -n "$simulator_id" ]] || { printf 'stage=simulator outcome=fail reason=iPhone-17-Pro-unavailable\n' >&2; exit 1; }
xcrun simctl boot "$simulator_id" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$simulator_id" -b >"$work/boot.log" 2>&1
# Uninstall removes only this app bundle and its container on this simulator.
xcrun simctl terminate "$simulator_id" com.marynavdovenko.Plainpost.iOS >/dev/null 2>&1 || true
xcrun simctl uninstall "$simulator_id" com.marynavdovenko.Plainpost.iOS >/dev/null 2>&1 || true
if xcrun simctl get_app_container "$simulator_id" com.marynavdovenko.Plainpost.iOS app >/dev/null 2>&1; then
  printf 'stage=simulator-reset outcome=fail reason=app-still-installed\n' >&2
  exit 1
fi

result="$root/.build/ios-standalone-mail-e2e.xcresult"
rm -rf "$result"
# Device Keychain writes require an ad hoc signed simulator app.
signing=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
ios_derived="$(rtk proxy python3 "$artifacts" cache --root "$root" --purpose ios-standalone --sdk iphonesimulator --signing adhoc)"
runner_receipt="$ios_derived/plainpost-runner-receipt.json"
rtk proxy python3 "$artifacts" build --root "$root" --cache "$ios_derived" --sdk iphonesimulator \
  --signing adhoc --receipt "$runner_receipt" --scheme Plainpost \
  --expected-target PlainpostTests --expected-target PlainpostUITests -- \
  rtk proxy xcodebuild -project Apps/PlainpostiOS/Plainpost.xcodeproj -scheme Plainpost \
  -configuration Debug -sdk iphonesimulator -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$ios_derived" "${signing[@]}" AppIdentifierPrefix=9XN7WN8JN2. build-for-testing >"$work/xcodebuild-build.log" 2>&1
runner="$(rtk proxy python3 "$artifacts" verify --root "$root" --sdk iphonesimulator --signing adhoc --receipt "$runner_receipt" --role xctestrun)"
perl -e 'alarm 1500; exec @ARGV' \
  xcodebuild test-without-building -xctestrun "$runner" \
    -destination "platform=iOS Simulator,id=$simulator_id" -parallel-testing-enabled NO \
    -only-testing:PlainpostUITests/PlainpostUITests/testStandaloneDirectMailCleanInstallToRestart \
    -resultBundlePath "$result" >"$work/xcodebuild.log" 2>&1 &
test_pid=$!
pass_seen_at=-1
teardown_hung=0
test_failure_seen=0
while kill -0 "$test_pid" 2>/dev/null; do
  if (( test_failure_seen == 0 )) && grep -q "Test Case .* failed" "$work/xcodebuild.log"; then
    test_failure_seen=1
    xcrun simctl io "$simulator_id" screenshot "$root/.build/ios-standalone-failure.png" >/dev/null 2>&1 || true
  fi
  if grep -q "Test Suite 'Selected tests' passed" "$work/xcodebuild.log"; then
    if (( pass_seen_at < 0 )); then pass_seen_at=$SECONDS; fi
    # Xcode can spend over 30 seconds finalizing the xcresult bundle after
    # XCTest reports success. Do not terminate it before Info.plist is written.
    if (( SECONDS - pass_seen_at >= 180 )); then
      teardown_hung=1
      kill -TERM "$test_pid" 2>/dev/null || true
      break
    fi
  fi
  sleep 1
done
test_exit=0
wait "$test_pid" || test_exit=$?
suite_passed=0
if grep -q "Test Suite 'Selected tests' passed" "$work/xcodebuild.log" \
  && grep -q 'Executed 1 test, with 0 failures' "$work/xcodebuild.log"; then
  suite_passed=1
fi
summary="$work/xcresult-summary.json"
summary_valid=0
if xcrun xcresulttool get test-results summary --path "$result" --compact >"$summary" 2>/dev/null; then
  if python3 - "$summary" "$simulator_id" <<'PY'
import json, sys
summary = json.load(open(sys.argv[1]))
assert summary['result'] == 'Passed'
assert summary['totalTestCount'] == 1
assert summary['passedTests'] == 1
assert summary['failedTests'] == 0
assert summary['skippedTests'] == 0
configurations = summary['devicesAndConfigurations']
if isinstance(configurations, dict): configurations = [configurations]
assert any(entry['device']['deviceId'] == sys.argv[2] for entry in configurations)
PY
  then summary_valid=1; fi
fi
if (( suite_passed != 1 || summary_valid != 1 || test_exit != 0 )); then
  result_info=0
  [[ -f "$result/Info.plist" ]] && result_info=1
  printf 'gate-detail test-exit=%s suite-passed=%s summary-valid=%s result-info=%s\n' \
    "$test_exit" "$suite_passed" "$summary_valid" "$result_info" >&2
  python3 - "$work/xcodebuild.log" <<'PY' >&2
import sys
source = open(sys.argv[1], errors='replace').read()
for marker in ('** TEST SUCCEEDED **', '** TEST FAILED **',
               'Testing failed:', 'Result bundle written to:',
               'Failed to create a new result bundle reader'):
    if marker in source:
        print('xcode-marker=' + marker)
PY
  if (( teardown_hung == 1 && suite_passed == 1 && summary_valid == 1 )); then
    printf 'stage=xcodebuild-teardown outcome=inconclusive reason=terminated-after-selected-suite-pass simulator=%s\n' "$simulator_id" >&2
  else
    printf 'stage=xcuitest outcome=fail simulator=%s\n' "$simulator_id" >&2
  fi
  rm -rf "$root/.build/ios-standalone-failure-images"
  xcrun xcresulttool export attachments --path "$result" \
    --output-path "$root/.build/ios-standalone-failure-images" --only-failures >/dev/null 2>&1 || true
  # XCTest activity lines can contain values typed into secure fields. Keep
  # the raw log in the temporary directory only; never echo it to stderr.
  python3 - "$work/xcodebuild.log" <<'PY' >&2
import re, sys
source = open(sys.argv[1], errors='replace').read()
for line in source.splitlines():
    match = re.search(r'PlainpostUITests\.swift:(\d+): error:', line)
    if match:
        print('failure-location=PlainpostUITests.swift:' + match.group(1))
        break
for line in source.splitlines():
    match = re.search(r'setup field (account-setup\.[a-z-]+) did not become tappable', line)
    if match:
        print('failure-setup-field=' + match.group(1))
        break
if 'Neither element nor any descendant has keyboard focus' in source:
    fields = re.findall(r"identifier: '(account-setup\.[a-z-]+)'", source)
    print('failure-keyboard-focus-field=' + (fields[-1] if fields else 'unknown'))
for identifier in ('Reply', 'Archive', 'Delete', 'mailbox.toolbar.compose',
                   'mailbox.toolbar.command-center', 'Mark as Unread', 'Mark as Read'):
    if identifier + ' is not hittable' in source:
        print('failure-navigation-action=' + identifier)
        break
for status in ('passed', 'failed'):
    if re.search(r"Test Case '-\[PlainpostUITests\.PlainpostUITests testStandaloneDirectMailCleanInstallToRestart\]' " + status, source):
        print('selected-test=' + status)
        break
PY
  python3 - "$PLAINPOST_MAIL_FIXTURE_CONTROL" <<'PY' >&2
import json, sys, urllib.request
try:
    with urllib.request.urlopen('http://127.0.0.1:' + sys.argv[1] + '/state', timeout=3) as response:
        state = json.load(response)
    print('fixture-state smtpDataCount={smtpDataCount} imapLoginCount={imapLoginCount} injected={injected} offline={offline}'.format(**state))
except Exception:
    print('fixture-state unavailable')
PY
  exit 1
fi
python3 - "$PLAINPOST_MAIL_FIXTURE_CONTROL" "$ledger" "$simulator_id" "${PLAINPOST_SETUP_ONLY:-0}" <<'PY'
import json, sys, urllib.request
with urllib.request.urlopen('http://127.0.0.1:' + sys.argv[1] + '/state', timeout=5) as response:
    state = json.load(response)
setup_only = sys.argv[4] == '1'
assert state['smtpDataCount'] == (1 if setup_only else 4), 'unexpected SMTP DATA count'
if not setup_only: assert state['offline'], 'offline stage did not run'
with open(sys.argv[2], 'w') as output:
    output.write('outcome=pass stage=' + ('setup' if setup_only else 'full')
        + ' tests=1 failures=0 simulator=' + sys.argv[3] + '\n')
    output.write('tls=implicit-TLS-1.2-plus-explicit-test-CA\n')
    output.write('smtpDataCount=' + str(state['smtpDataCount']) + '\n')
    output.write('imapLoginCount=' + str(state['imapLoginCount']) + '\n')
    output.write('offline=' + str(state['offline']).lower() + '\n')
PY
printf 'stage=ios-standalone-mail-e2e outcome=pass simulator=%s\n' "$simulator_id"
