#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
owner="$root/Scripts/test-sync-node-mail-matrix.sh"
swift="$root/Tests/PlainpostAccountRuntimeTests/NodeMailAuthorityLiveScenario.swift"
swift_live="$root/Tests/PlainpostAccountRuntimeTests/SyncNodePrivateTransportLiveTests.swift"
private="$root/Scripts/test-sync-node-private-transport.sh"
client_api="$root/Scripts/test-sync-node-client-api.sh"
compose="$root/Deploy/acceptance/compose.private-transport.yaml"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/plainpost-mail-matrix-contract.XXXXXX")
fixture_source="$root/Scripts/lib/plainpost_acceptance_mail_fixture.py"
fixture_state="$root/Scripts/lib/plainpost_acceptance_mail_state.py"
postcondition_summary_helper="$root/Scripts/lib/acceptance-mail-postcondition-summary.sh"
trap 'find "$fixture" -depth -delete' EXIT HUP INT TERM
legacy_cleanup=rm
legacy_cleanup="$legacy_cleanup -rf "
if grep -F "$legacy_cleanup" "$0" >/dev/null; then
  printf 'contract fixture cleanup must use exact-target find -depth -delete\n' >&2
  exit 1
fi
grep -F 'find "$fixture" -depth -delete' "$0" >/dev/null
[ -x "$owner" ] || { printf 'matrix owner must be executable\n' >&2; exit 1; }
[ -r "$postcondition_summary_helper" ] || { printf 'postcondition summary helper must exist\n' >&2; exit 1; }
. "$postcondition_summary_helper"
postcondition_result="$fixture/postcondition.result"
postcondition_log="$fixture/postcondition.log"
printf '%s\n' 'postcondition-category=sent-state' >"$postcondition_result"
acceptance_mail_postcondition_failure_summary "$postcondition_result" "$postcondition_log"
grep -Fx 'ERROR acceptance-mail-postcondition outcome=mismatch category=sent-state' "$postcondition_log" >/dev/null
printf '%s\n' 'postcondition-category=not-an-allowlisted-class' >"$postcondition_result"
acceptance_mail_postcondition_failure_summary "$postcondition_result" "$postcondition_log"
grep -Fx 'ERROR acceptance-mail-postcondition outcome=mismatch category=unclassified' "$postcondition_log" >/dev/null
if grep -E '[[:space:]](sender|recipient|digest|message|path|password|secret)=' "$postcondition_log" >/dev/null; then
  printf 'postcondition summary must not expose authoritative values\n' >&2
  exit 1
fi
postcondition_summary_output="$fixture/postcondition-summary.out"
if ! PLAINPOST_SYNC_NODE_MAIL_POSTCONDITION_SUMMARY_TEST=enabled "$private" >"$postcondition_summary_output" 2>&1; then
  printf 'private owner postcondition summary test failed\n' >&2
  exit 1
fi
grep -Fx 'mail_postcondition_failure_summary_begin' "$postcondition_summary_output" >/dev/null
grep -Fx 'mail_postcondition_failure_summary_end' "$postcondition_summary_output" >/dev/null
postcondition_summary_count=$(grep -Fxc 'ERROR acceptance-mail-postcondition outcome=mismatch category=sent-state' "$postcondition_summary_output" || true)
[ "$postcondition_summary_count" -eq 40 ] || {
  printf 'private owner postcondition summary must retain exactly the bounded fixed-category tail\n' >&2
  exit 1
}
if grep -F 'postcondition-summary-secret-never-render' "$postcondition_summary_output" >/dev/null ||
   grep -E '^ERROR acceptance-mail-postcondition outcome=mismatch category=[a-z-]+ secret=' "$postcondition_summary_output" >/dev/null; then
  printf 'private owner postcondition summary leaked an unallowlisted field\n' >&2
  exit 1
fi

selectors='smtp-authentication smtp-recipient-451 smtp-recipient-550 smtp-after-354 smtp-mid-data smtp-final-reply smtp-quit-loss smtp-cancel-before-data smtp-cancel-after-data smtp-sent-append-failure smtp-provider-restart-after-acceptance smtp-untrusted-certificate smtp-same-ca-wrong-host smtp-tls1.1 smtp-auth-before-starttls smtp-concurrent-sends smtp-ambiguous-replay'
imap_selectors='imap-authentication imap-untrusted-certificate imap-same-ca-wrong-host imap-tls1.1 imap-catalog imap-header-fetch imap-body-fetch imap-attachment-fetch imap-delayed-literal imap-truncated-literal imap-uid-gaps imap-expunge imap-uidvalidity-reset imap-idle-wakeup imap-poll-fallback imap-provider-restart-mid-page imap-provider-restart-after-commit imap-node-restart-before-ack imap-node-restart-after-ack imap-concurrent-mutations imap-stale-authority imap-mime-boundaries'
owner_selectors=$(sed -n "s/^  smtp) selectors='\(.*\)' ;;/\1/p" "$owner")
[ "$owner_selectors" = "$selectors" ] || { printf 'owner selector mapping diverges from the closed contract\n' >&2; exit 1; }
owner_imap_selectors=$(sed -n "s/^  imap) selectors='\(.*\)' ;;/\1/p" "$owner")
[ "$owner_imap_selectors" = "$imap_selectors" ] || { printf 'owner IMAP selector mapping diverges from the closed contract\n' >&2; exit 1; }
shell_control_actions='provider-transition attachment-release-probe restart-node restart-imap-fixture restart-smtp-fixture mail-postcondition smtp-matrix-resume imap-matrix-resume imap-matrix-reset-uidvalidity imap-matrix-assert-authentication imap-matrix-arm-authentication imap-matrix-arm-tls-failure imap-matrix-append-message imap-matrix-assert-no-idle imap-matrix-catalog-probe imap-matrix-fetch-probe imap-matrix-delayed-literal-probe arm-sent-append-failure smtp-matrix-assert-no-auth smtp-matrix-assert-authentication-command restore-smtp-fixture-normal restore-imap-fixture-normal'
shell_control_allowlist=$(sed -n '/control_signal_path()/,/^  }/p' "$private")
for action in $shell_control_actions; do
  printf '%s\n' "$shell_control_allowlist" | grep -F "$action" >/dev/null || {
    printf 'shell control action is outside the closed allowlist: %s\n' "$action" >&2
    exit 1
  }
done
if grep -F 'discover-catalog' "$private" >/dev/null; then
  printf 'catalog discovery must not mutate the durable acceptance seed profile\n' >&2
  exit 1
fi
grep -F 'imap-matrix-catalog-probe' "$private" >/dev/null
grep -F 'run_catalog_probe unavailable' "$private" >/dev/null
grep -F 'run_catalog_probe '\'''\''' "$private" >/dev/null
grep -F 'imap-matrix-catalog-probe' "$swift" >/dev/null
grep -F 'imapMatrixUsesDedicatedCatalogProbeForTesting' "$swift" >/dev/null
grep -F 'IMAPMatrixCase(selector: "imap-catalog", fault: "none", phase: "none"' "$swift" >/dev/null
if grep -F 'IMAPMatrixCase(selector: "imap-catalog", fault: "imap-catalog", phase: "catalog"' "$swift" >/dev/null; then
  printf 'catalog selector must not wait on the unreachable Runtime catalog phase\n' >&2
  exit 1
fi
grep -F 'run_controller_child "imap-catalog-probe-$catalog_probe_expectation" "$controller_child_timeout_seconds"' "$private" >/dev/null
grep -F 'imap-header-fetch) imap_matrix_fault=none; imap_matrix_result=none; imap_matrix_phase=none; imap_matrix_protocol=imap; acceptance_imap_fetch_phase=header-fetch' "$private" >/dev/null
grep -F 'imap-body-fetch) imap_matrix_fault=none; imap_matrix_result=none; imap_matrix_phase=none; imap_matrix_protocol=imap; acceptance_imap_fetch_phase=body-fetch' "$private" >/dev/null
grep -F 'imap-delayed-literal) imap_matrix_fault=none; imap_matrix_result=none; imap_matrix_phase=none; imap_matrix_protocol=imap; acceptance_imap_fetch_phase=header-fetch' "$private" >/dev/null
grep -F 'imap-matrix-fetch-probe' "$private" >/dev/null
grep -F 'run_fetch_probe unavailable' "$private" >/dev/null
grep -F 'if ! run_fetch_probe' "$private" >/dev/null
grep -F 'recovery=two-message projection=unchanged' "$private" >/dev/null
if grep -F 'recovery=one-message' "$private" >/dev/null; then
  printf 'fetch probe recovery cardinality must match the two-message fixture\n' >&2
  exit 1
fi
grep -F 'imap-matrix-fetch-probe' "$swift" >/dev/null
grep -F 'imapMatrixUsesDedicatedFetchProbeForTesting' "$swift" >/dev/null
grep -F 'imap-matrix-delayed-literal-probe' "$private" >/dev/null
grep -F 'imap-matrix-arm-tls-failure|imap-matrix-append-message|imap-matrix-assert-no-idle|imap-matrix-catalog-probe|imap-matrix-fetch-probe|imap-matrix-delayed-literal-probe' "$private" >/dev/null
grep -F 'imapMatrixUsesDedicatedDelayedLiteralProbeForTesting' "$swift" >/dev/null
grep -F 'delayed_literal_header_occurrence' "$private" >/dev/null
grep -F 'phase imap header-fetch "$delayed_literal_header_occurrence" delay --delay-ms 1000' "$private" >/dev/null
grep -F 'acceptance-imap-delayed-literal-probe outcome=applied phase=header-fetch action=delay recovery=two-message projection=unchanged' "$private" >/dev/null
if grep -F 'imap-delayed-literal) imap_matrix_fault=none; imap_matrix_result=none; imap_matrix_phase=header-fetch' "$private" >/dev/null; then
  printf 'delayed literal must not arm an initial header-fetch barrier\n' >&2
  exit 1
fi
if ! awk '
  /if \[ -e "\$imap_matrix_delayed_literal_probe_request" \]; then/ { branch = 1 }
  branch && /delayed_literal_header_count_before=/ { before = NR }
  branch && /phase imap header-fetch "\$delayed_literal_header_occurrence" delay --delay-ms 1000/ { arm = NR }
  branch && /if ! run_fetch_probe/ { probe = NR }
  branch && /delayed_literal_header_count_after=/ { after = NR }
  branch && /delayed_literal_projection_after=/ { projection = NR }
  branch && /: >"\$imap_matrix_delayed_literal_probe_applied"/ { applied = NR }
  branch && /fi/ && before && arm && probe && after && projection && applied { exit !(before < arm && arm < probe && probe < after && after < projection && projection < applied) }
' "$private"; then
  printf 'delayed literal probe must capture baseline, arm next phase delay, fetch, compare phase/projection, then publish\n' >&2
  exit 1
fi
if ! awk '
  /if \[ -e "\$imap_matrix_fetch_probe_request" \]; then/ { branch = 1 }
  branch && /arm-fault "imap-\$acceptance_imap_fetch_phase" 1 disconnect/ { arm = NR }
  branch && /run_fetch_probe unavailable/ { failed_probe = NR }
  branch && /if ! run_fetch_probe/ { success_probe = NR }
  branch && /fetch_probe_projection_after=/ { projection = NR }
  branch && /: >"\$imap_matrix_fetch_probe_applied"/ { applied = NR }
  branch && /fi/ && arm && failed_probe && success_probe && projection && applied { exit !(arm < failed_probe && failed_probe < success_probe && success_probe < projection && projection < applied) }
' "$private"; then
  printf 'header/body fetch probe must arm, exercise typed failure, recover, compare projection, then publish\n' >&2
  exit 1
fi
grep -F 'probeFetch := flag.Bool("probe-fetch"' "$root/Services/PlainpostGo/cmd/plainpost-sync-node-acceptance-seed/main.go" >/dev/null
grep -F 'fetchPhase := flag.String("fetch-phase"' "$root/Services/PlainpostGo/cmd/plainpost-sync-node-acceptance-seed/main.go" >/dev/null
grep -F 'expectFetchError := flag.String("expect-fetch-error"' "$root/Services/PlainpostGo/cmd/plainpost-sync-node-acceptance-seed/main.go" >/dev/null
grep -F 'ProbeSyncNodeAcceptanceFetch' "$root/Services/PlainpostGo/cmd/plainpost-sync-node-acceptance-seed/main.go" "$root/Services/PlainpostGo/internal/acceptance/sync_node_provider.go" >/dev/null
if [ "$(grep -F -c ': >"$imap_matrix_catalog_probe_applied"' "$private")" -ne 1 ] ||
   [ "$(grep -F -c ': >"$imap_matrix_catalog_probe_failed"' "$private")" -ne 1 ]; then
  printf 'catalog probe must publish exactly one public terminal marker per request path\n' >&2
  exit 1
fi
if ! awk '
  /if \[ -e "\$imap_matrix_catalog_probe_request" \]; then/ { branch = 1 }
  branch && /arm-fault imap-catalog 1 disconnect/ { arm = NR }
  branch && /run_catalog_probe unavailable/ { failed_probe = NR }
  branch && index($0, "run_catalog_probe ''") { success_probe = NR }
  branch && /catalog_projection_after=/ { projection = NR }
  branch && /: >"\$imap_matrix_catalog_probe_applied"/ { applied = NR }
  branch && /fi/ && arm && failed_probe && success_probe && projection && applied { exit !(arm < failed_probe && failed_probe < success_probe && success_probe < projection && projection < applied) }
' "$private"; then
  printf 'catalog probe action must arm, run typed failure, recover, compare projection, then publish\n' >&2
  exit 1
fi
if grep -F 'imap_matrix_phase=catalog' "$private" >/dev/null; then
  printf 'catalog selector must use the standalone probe, not an unreachable sync phase\n' >&2
  exit 1
fi
swift_selectors=$(sed -n 's/.*SMTPMatrixCase(selector: "\([^"]*\)".*/\1/p' "$swift" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
[ "$swift_selectors" = "$selectors" ] || { printf 'Swift selector mapping diverges from the closed contract\n' >&2; exit 1; }
swift_imap_selectors=$(sed -n 's/.*IMAPMatrixCase(selector: "\([^"]*\)".*/\1/p' "$swift" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
[ "$swift_imap_selectors" = "$imap_selectors" ] || { printf 'Swift IMAP selector mapping diverges from the closed contract\n' >&2; exit 1; }
for selector in $selectors; do
  grep -F "$selector" "$owner" >/dev/null || { printf 'owner missing selector %s\n' "$selector" >&2; exit 1; }
  grep -F "\"$selector\"" "$swift" >/dev/null || { printf 'Swift missing selector %s\n' "$selector" >&2; exit 1; }
done
for selector in $imap_selectors; do
  grep -F "$selector" "$owner" >/dev/null || { printf 'owner missing IMAP selector %s\n' "$selector" >&2; exit 1; }
  grep -F "\"$selector\"" "$swift" >/dev/null || { printf 'Swift missing IMAP selector %s\n' "$selector" >&2; exit 1; }
done
grep -F 'if [ "$acceptance_mail_scenario" = imap-uid-gaps ]; then' "$private" >/dev/null
grep -F 'prepare_uid_gap_fixture "$temporary/mail-state/mailbox.json"' "$private" >/dev/null
grep -F 'return f"Message-ID: <{message_id}@example.test>\r\nSubject: {subject}\r\n\r\n{body}\r\n"' "$private" >/dev/null
grep -F 'UID-gap fixture seed did not match its exact fixture fields' "$private" >/dev/null
uid_gap_preflight_output="$fixture/uid-gap-preflight.log"
if ! PLAINPOST_SYNC_NODE_UID_GAP_PREFLIGHT_TEST=enabled "$private" >"$uid_gap_preflight_output" 2>&1; then
  printf 'UID-gap preflight production path failed\n' >&2
  exit 1
fi
grep -F 'uid-gap-preflight-test=passed' "$uid_gap_preflight_output" >/dev/null
if grep -F 'hand-derived identities' "$uid_gap_preflight_output" >/dev/null; then
  printf 'UID-gap preflight retained obsolete identity wording\n' >&2
  exit 1
fi
grep -F -- '--group smtp' "$owner" >/dev/null
grep -F -- '--group imap' "$owner" >/dev/null
grep -F -- '--all' "$owner" >/dev/null
grep -F 'all) selectors=' "$owner" >/dev/null
grep -F 'case "$selector" in' "$owner" >/dev/null
grep -F 'test-sync-node-client-api.sh' "$owner" >/dev/null
grep -F 'PLAINPOST_SYNC_NODE_ACCEPTANCE_SWIFT_FILTER=PlainpostAccountRuntimeTests.SyncNodePrivateTransportLiveTests/testRealCentralAndNodeProcessesClosePrivateLifecycle' "$client_api" >/dev/null
if grep -F 'PLAINPOST_SYNC_NODE_ACCEPTANCE_SWIFT_FILTER=SyncNodePrivateTransportLiveTests' "$client_api" >/dev/null ||
   grep -F 'testNestedAcceptanceStreamCancellationStressReleasesLifecycleAcrossChunkTimings' "$client_api" >/dev/null; then
  printf 'client API wrapper must not select the broad Swift test class\n' >&2
  exit 1
fi
if grep -F 'test-sync-node-private-transport.sh' "$owner" >/dev/null; then
  printf 'matrix owner must invoke the authoritative client-api wrapper\n' >&2
  exit 1
fi
grep -F 'PLAINPOST_SYNC_NODE_ACCEPTANCE_MAIL_SCENARIO="$selector"' "$owner" >/dev/null
grep -F 'PlainpostNodeMailAuthority' "$swift" >/dev/null
grep -F 'authority.mutations.perform(.send' "$swift" >/dev/null
grep -F 'secondaryAuthority.mutations.perform(.send' "$swift" >/dev/null
grep -F 'smtp-matrix-resume' "$swift" >/dev/null
grep -F 'imap-matrix-resume' "$swift" >/dev/null
grep -F 'imap-truncated-literal' "$private" >/dev/null
grep -F 'smtp_matrix_fault=none' "$private" >/dev/null
grep -F 'smtp_matrix_protocol=smtp' "$private" >/dev/null
grep -F 'imap_matrix_fault=imap-truncated-literal' "$private" >/dev/null
grep -F 'imap_matrix_phase=attachment-fetch' "$private" >/dev/null
grep -F 'imap-*)' "$private" >/dev/null
if ! awk '
  /case "\$acceptance_mail_scenario" in/ { section = 1 }
  section && /imap-\*\)/ { imap = NR; imap_section = 1 }
  imap_section && /run_node_two_activation_sequence/ { direct = NR }
  imap_section && /^  \*\)/ { ordinary = NR; imap_section = 0 }
  ordinary && /wait_for_signal authority-outage/ { outage = NR }
  END { exit !(imap && direct && ordinary && outage && imap < direct && direct < ordinary && ordinary < outage) }
' "$private"; then
  printf 'all IMAP selectors must activate node two before the SMTP authority-outage lifecycle\n' >&2
  exit 1
fi
grep -F 'imap-authentication-startup-fault' "$private" >/dev/null
grep -F 'imap-matrix-arm-authentication' "$private" >/dev/null
grep -F 'arm-fault imap-authentication 1 rejected' "$private" >/dev/null
grep -F 'acceptance-imap-authentication-durable-block' "$private" >/dev/null
grep -F 'imap-matrix-arm-tls-failure' "$private" >/dev/null
grep -F 'assert_expected_imap_tls_startup_fault' "$private" >/dev/null
grep -F 'terminal_restart_action=imap-terminal-fault-restart-node' "$private" >/dev/null
grep -F 'run_controller_child "$terminal_restart_action"' "$private" >/dev/null
grep -F 'rm -f "$temporary/control/$terminal_restart_action.applied"' "$private" >/dev/null
if ! awk '
  /if \[ -e "\$restart_node_request" \]; then/ { restart = 1 }
  restart && /assert_expected_imap_authentication_startup_fault|assert_expected_imap_tls_startup_fault/ { proof = NR }
  restart && /: >"\$restart_node_applied"/ { public = NR }
  restart && /fi/ && proof && public { exit !(proof < public) }
' "$private"; then
  printf 'expected IMAP fault restart must prove the fault before publishing public restart success\n' >&2
  exit 1
fi
grep -F 'acceptance_imap_tls_terminal_mode' "$private" >/dev/null
grep -F 'imap_tls_projection_baseline' "$private" >/dev/null
grep -F 'imap_tls_authentication_count_baseline' "$private" >/dev/null
grep -F 'imap-untrusted-certificate|imap-same-ca-wrong-host|imap-tls1.1' "$private" >/dev/null
for terminal_selector in imap-untrusted-certificate imap-same-ca-wrong-host; do
  grep -F "[ \"\$acceptance_mail_scenario\" = $terminal_selector ] ||" "$private" >/dev/null
done
grep -F '[ "$acceptance_mail_scenario" = imap-tls1.1 ]; then' "$private" >/dev/null
if grep -F 'imap-untrusted-certificate) acceptance_imap_tls_mode=' "$private" >/dev/null ||
   grep -F 'imap-same-ca-wrong-host) acceptance_imap_tls_mode=' "$private" >/dev/null ||
   grep -F 'imap-tls1.1) acceptance_imap_tls_mode=' "$private" >/dev/null; then
  printf 'IMAP terminal TLS selector is applied before healthy baseline\n' >&2
  exit 1
fi
grep -F 'imap-matrix-\(matrixCase.selector)-authority-replacement' "$swift" >/dev/null
grep -F 'imap-matrix-\(matrixCase.selector)-durable-block-observed' "$swift" >/dev/null
grep -F 'imap-matrix-\(matrixCase.selector)-healthy-baseline' "$swift" >/dev/null
grep -F 'imap_authentication_expected_after=$((imap_authentication_count_baseline + 1))' "$private" >/dev/null
grep -F 'imap_authentication_count_baseline=$(mail_python -c' "$private" >/dev/null
grep -F 'imap_authentication_count" != "$imap_authentication_expected_after"' "$private" >/dev/null
grep -F 'imap_authentication_expected_after' "$private" >/dev/null
grep -F 'case "$1" in' "$private" >/dev/null
if grep -F 'expected_imap_authentication_count' "$private" >/dev/null ||
   grep -F 'imap_authentication_expected_after=2' "$private" >/dev/null; then
  printf 'IMAP authentication fault contract contains a hard-coded count\n' >&2
  exit 1
fi
grep -F 'if [ "$acceptance_mail_scenario" != imap-authentication ] &&' "$private" >/dev/null
grep -F 'phase "$imap_matrix_protocol" "$imap_matrix_phase" 1 pause' "$private" >/dev/null
grep -F 'if [ -e "$imap_matrix_resume_request" ]' "$private" >/dev/null
grep -F 'imap_matrix_resume_occurrence=1' "$private" >/dev/null
grep -F 'phase "$imap_matrix_protocol" "$imap_matrix_phase" "$imap_matrix_resume_occurrence" resume' "$private" >/dev/null
grep -F 'imap-matrix-reset-uidvalidity' "$private" >/dev/null
grep -F 'reset-uidvalidity' "$private" >/dev/null
grep -F 'restore-imap-fixture-normal' "$private" >/dev/null
grep -F 'imap-matrix-assert-authentication' "$private" >/dev/null
grep -F 'imap-matrix-append-message' "$private" >/dev/null
grep -F 'imap-matrix-assert-no-idle' "$private" >/dev/null
grep -F 'imap-matrix-\(matrixCase.selector)-recovery-begin' "$swift" >/dev/null
grep -F 'imap_tls_handshake_count_baseline=' "$private" >/dev/null
grep -F 'elif [ "$imap_tls_handshake_count" -gt "$imap_tls_handshake_count_baseline" ]; then' "$private" >/dev/null
grep -F 'outcome=missing-provider' "$private" >/dev/null
grep -F 'outcome=authentication-changed' "$private" >/dev/null
grep -F 'outcome=handshake-missing' "$private" >/dev/null
grep -F 'imap_tls_handshake_proof=observed' "$private" >/dev/null
grep -F 'handshake=%s' "$private" >/dev/null
grep -F 'imap_tls_handshake_proof=pre-sni-rejected' "$private" >/dev/null
if ! awk '
  /if \[ "\$imap_tls_handshake_count" -gt "\$imap_tls_handshake_count_baseline" \]; then/ { observed = NR }
  /elif \[ "\$acceptance_mail_scenario" = imap-tls1\.1 \] &&/ { legacy = NR }
  /\[ "\$acceptance_imap_tls_terminal_mode" = legacy-tls \]/ { legacy_mode = NR }
  /\[ "\$imap_tls_handshake_count" = "\$imap_tls_handshake_count_baseline" \]/ { zero = NR }
  /imap_tls_handshake_proof=pre-sni-rejected/ { proof = NR }
  /outcome=handshake-missing/ { missing = NR }
  END { exit !(observed && legacy && legacy_mode && zero && proof && missing && observed < legacy && legacy_mode < zero && zero < proof && proof < missing) }
' "$private"; then
  printf 'IMAP TLS handshake proof must require observation for certificate/hostname faults and allow only legacy pre-SNI rejection\n' >&2
  exit 1
fi
grep -F 'outcome=checkpoint-invalid' "$private" >/dev/null
grep -F 'assert_expected_imap_blocked_checkpoint' "$private" >/dev/null
grep -F 'assert_expected_imap_blocked_checkpoint authentication' "$private" >/dev/null
grep -F 'assert_expected_imap_blocked_checkpoint tls' "$private" >/dev/null
grep -F 'blocked_checkpoint_invalid_count' "$private" >/dev/null
grep -F '[ "$blocked_checkpoint_count" -lt 1 ]' "$private" >/dev/null
grep -F 'cursor IS NOT NULL' "$private" >/dev/null
grep -F 'projection_revision IS NOT NULL' "$private" >/dev/null
grep -F 'blocked_error_tag IS DISTINCT FROM' "$private" >/dev/null
if grep -F '[ "$blocked_checkpoint_count" != 1 ]' "$private" >/dev/null; then
  printf 'IMAP terminal checkpoint validation must accept multiple valid blocked checkpoints\n' >&2
  exit 1
fi
grep -F 'emit_imap_terminal_failure_summary' "$private" >/dev/null
grep -F 'emit_mail_postcondition_failure_summary' "$private" >/dev/null
grep -F 'imap_terminal_failure_summary_begin' "$private" >/dev/null
grep -F 'imap_tls_authentication_count" != "$imap_tls_authentication_count_baseline"' "$private" >/dev/null
if ! awk '
  /if \[ -e "\$imap_matrix_arm_tls_failure_request" \]; then/ { arm = 1 }
  arm && /run_controller_child imap-tls-stop-node-one/ { stop = NR }
  arm && /imap_tls_authentication_count_baseline=\$\(mail_python -c/ && ! baseline { baseline = NR }
  arm && /imap_tls_handshake_count_baseline=\$\(mail_python -c/ && ! handshake { handshake = NR }
  arm && /imap_tls_projection_baseline=\$\(docker/ && ! projection { projection = NR }
  arm && /compose_run up -d --no-deps --force-recreate imap-fixture/ { recreate = NR }
  END { exit !(stop && baseline && handshake && projection && recreate && stop < baseline && baseline < handshake && handshake < projection && projection < recreate) }
' "$private"; then
  printf 'IMAP TLS node stop must precede stable baselines and bad-listener recreation\n' >&2
  exit 1
fi
if grep -F 'imapTLSStartupHandshakeProofForTesting' "$swift" >/dev/null ||
   grep -F 'tls-handshake-before-login' "$swift" >/dev/null; then
  printf 'IMAP TLS matrix must use post-baseline shell observation counts\n' >&2
  exit 1
fi
grep -F 'tls-handshake' "$fixture_source" >/dev/null
grep -F 'set_servername_callback' "$fixture_source" >/dev/null
grep -F '"tls-handshake"' "$fixture_state" >/dev/null
grep -F 'Data(repeating: 0, count: 262144)' "$swift" >/dev/null
grep -F 'ijnSq9OZmrc8NNskdoSc3fMDzjibNYJoUPmnAFibSpA' "$swift" >/dev/null
grep -F 'imapMatrixRecoveryErrorIsTransientForTesting' "$swift" >/dev/null
grep -F 'recovery-attempts=' "$swift" >/dev/null
grep -F 'message-recovery-attempts=' "$swift" >/dev/null
grep -F 'imap-matrix-\(matrixCase.selector)-over-limit' "$swift" >/dev/null
grep -F 'imap-matrix-\(matrixCase.selector)-malformed-header' "$swift" >/dev/null
grep -F 'imap-matrix-\(matrixCase.selector)-success' "$swift" >/dev/null
grep -F 'imap-matrix-\(matrixCase.selector)-snapshot-success' "$swift" >/dev/null
grep -F 'imap-matrix-\(matrixCase.selector)-metadata-begin' "$swift" >/dev/null
grep -F 'imap-matrix-\(matrixCase.selector)-metadata-end' "$swift" >/dev/null
grep -F 'imap-matrix-\(matrixCase.selector)-\(attachmentClass)-open' "$swift" >/dev/null
grep -F 'imap-matrix-\(matrixCase.selector)-\(attachmentClass)-drain' "$swift" >/dev/null
grep -F 'imap-matrix-\(matrixCase.selector)-over-limit-open' "$swift" >/dev/null
grep -F 'imap-matrix-\(matrixCase.selector)-over-limit-drain' "$swift" >/dev/null
grep -F 'imap-matrix-\(matrixCase.selector)-accepted-limit-open' "$swift" >/dev/null
grep -F 'imap-matrix-\(matrixCase.selector)-accepted-limit-drain' "$swift" >/dev/null
grep -F 'imap-matrix-\(matrixCase.selector)-message-projection-read-begin' "$swift" >/dev/null
grep -F 'imap-matrix-\(matrixCase.selector)-message-projection-read-end' "$swift" >/dev/null
grep -F 'post-restart-imap-work' "$swift" >/dev/null
grep -F 'provider-session-replaced' "$swift" >/dev/null
grep -F 'provider-session-revision-wait-begin' "$swift" >/dev/null
grep -F 'provider-session-revision-changed' "$swift" >/dev/null
grep -F 'waitForRevisionChangeForTesting(' "$swift" >/dev/null
grep -F 'authorityReplacement:' "$swift" >/dev/null
grep -F 'performAuthorityReplacement(authorityReplacement)' "$swift" >/dev/null
grep -F 'signMutation(' "$swift" >/dev/null
grep -F 'NodeSessionError.authenticationRejected' "$swift" >/dev/null
grep -F 'old-session-no-side-effect' "$swift" >/dev/null
grep -F 'replacementBaseline' "$swift" >/dev/null
grep -F 'replacementAfterRejectedMutation' "$swift" >/dev/null
grep -F 'replacement-session-applied' "$swift" >/dev/null
for marker in \
  'node-two-protected-presentation-begin' \
  'node-two-protected-presentation-end' \
  'node-two-central-enroll-begin' \
  'node-two-central-enroll-end' \
  'node-two-central-enroll-failure' \
  'node-two-central-enroll-response' \
  'node-two-activation-signal' \
  'node-two-activation-wait-begin' \
  'node-two-activation-wait-end' \
  'hot-activation-discovery-begin' \
  'hot-activation-discovery-end' \
  'hot-activation-ready-begin' \
  'hot-activation-ready-end' \
  'hot-activation-signed-status-begin' \
  'hot-activation-signed-status-end' \
  'node-two-replacement-client-begin' \
  'node-two-replacement-client-end'; do
  grep -F "$marker" "$swift_live" >/dev/null
done
grep -F 'Node restart before acknowledgement must retain the committed read mutation' "$swift" >/dev/null
grep -F 'imap-matrix-\(matrixCase.selector)-response-drop-observed' "$swift" >/dev/null
grep -F 'imapMatrixRestartReplayStateIsAppliedForTesting' "$swift" >/dev/null
grep -F 'fresh-authenticated-session' "$swift" >/dev/null
grep -F 'literal-released' "$swift" >/dev/null
grep -F 'command-observed' "$swift" >/dev/null
grep -F 'idle-absent' "$swift" >/dev/null
for marker in 'imap-delayed-literal' 'imap-provider-restart-mid-page' 'imap-provider-restart-after-commit' 'imap-node-restart-before-ack' 'imap-node-restart-after-ack' 'imap-idle-wakeup' 'imap-poll-fallback' 'imap-uid-gaps' 'imap-expunge' 'imap-uidvalidity-reset' 'imap-concurrent-mutations' 'imap-stale-authority' 'imap-mime-boundaries'; do
  grep -F "$marker" "$swift" >/dev/null
done
if ! awk '
  /case "imap-concurrent-mutations"/ { branch = 1 }
  branch && /imap-matrix-append-message/ { appends += 1 }
  branch && /appendDelta = try await waitForNonEmptyDelta/ { delta = NR }
  branch && /let concurrentSnapshot/ { snapshot = NR }
  branch && /case "imap-stale-authority"/ { exit !(appends >= 2 && delta && snapshot && delta < snapshot) }
' "$swift"; then
  printf 'concurrent IMAP mutations must await the bounded delta containing both appended messages before selecting targets\n' >&2
  exit 1
fi
if ! awk '
  /case "imap-concurrent-mutations"/ { branch = 1 }
  branch && /baseline-begin/ { baseline_begin = NR }
  branch && /baseline-end/ { baseline_end = NR }
  branch && /secondary-status-confirmation-end/ { confirmation = NR }
  branch && /appendDelta = try await waitForNonEmptyDelta/ { delta = NR }
  branch && /let concurrentSnapshot/ { snapshot = NR }
  branch && /let concurrentTargets = imapConcurrentMutationTargetsForTesting/ { targets = NR }
  branch && /case "imap-stale-authority"/ {
    exit !(baseline_begin && baseline_end && confirmation && delta && snapshot && targets &&
      baseline_begin < baseline_end && baseline_end < confirmation && confirmation < delta && delta < snapshot && snapshot < targets)
  }
' "$swift"; then
  printf 'concurrent IMAP mutations must stabilize the complete two-message baseline before status and append, then select targets only from the post-append snapshot\n' >&2
  exit 1
fi
if ! awk '
  /case "imap-concurrent-mutations"/ { branch = 1 }
  branch && /case "imap-stale-authority"/ { exit !(confirmation && firstMutation && confirmation < firstMutation) }
  branch && /secondary-status-confirmation-end/ { confirmation = NR }
  branch && /async let read =/ && !firstMutation { firstMutation = NR }
' "$swift"; then
  printf 'concurrent IMAP mutations must confirm the secondary authority status before launching mutations\n' >&2
  exit 1
fi
if ! awk '
  /case "imap-concurrent-mutations"/ { branch = 1 }
  branch && /case "imap-stale-authority"/ { exit !(applied && waitBegin && waitEnd && committed && applied < waitBegin && waitBegin < waitEnd && waitEnd < committed) }
  branch && /let deleteResult = try await delete/ { applied = NR }
  branch && /projection-wait-begin/ { waitBegin = NR }
  branch && /let projected = try await waitForConcurrentMutationProjectionForTesting/ { waitBegin = NR }
  branch && /projection-wait-end/ { waitEnd = NR }
  branch && /projection-committed/ { committed = NR }
' "$swift"; then
  printf 'concurrent IMAP mutations must await an advanced snapshot containing all durable effects before asserting projection\n' >&2
  exit 1
fi
grep -F 'actual.messages.count == previous.messages.count' "$swift" >/dev/null
grep -F 'Set(actualIDs).count == actualIDs.count' "$swift" >/dev/null
grep -F 'actual.messages.contains(where: { $0.id == archiveMessageID })' "$swift" >/dev/null
grep -F 'actual.messages.contains(where: { $0.id == deleteMessageID })' "$swift" >/dev/null
grep -F 'waitForAcceptanceFixtureSnapshotForTesting' "$swift" >/dev/null
grep -F 'imapAcceptanceFixtureShapeMatches' "$swift" >/dev/null
grep -F '(message.labels.contains("ARCHIVE") || message.labels.contains("ALL"))' "$swift" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_IMAP_TLS_MODE' "$compose" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_IMAP_WRONG_HOST_TLS_CERT' "$compose" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_IMAP_UNTRUSTED_TLS_CERT' "$compose" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_IMAP_WAIT_FOR_IDLE_CHANGE' "$compose" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_IMAP_IDLE_TARGET' "$compose" >/dev/null
grep -F 'imap-idle-wakeup) acceptance_imap_idle=1; acceptance_imap_wait_idle_change=1' "$private" >/dev/null
grep -F 'imap-provider-restart-mid-page) acceptance_imap_idle=1; acceptance_imap_wait_idle_change=1; acceptance_imap_idle_target=INBOX' "$private" >/dev/null
grep -F 'export PLAINPOST_ACCEPTANCE_IMAP_IDLE_TARGET=' "$private" >/dev/null
grep -F 'imapMatrixUsesIdleBarrierForTesting' "$swift" >/dev/null
if ! awk '
  /if matrixCase.selector == "imap-provider-restart-mid-page"/ { branch = 1 }
  branch && /healthy-baseline/ { healthy = NR }
  branch && /idle-observed/ { idle = NR }
  branch && /imap-matrix-arm-provider-restart/ { arm = NR }
  branch && /let deltaPages/ { exit !(healthy && idle && arm && healthy < idle && idle < arm) }
' "$swift"; then
  printf 'mid-page IMAP restart must observe IDLE before arming the exact header barrier\n' >&2
  exit 1
fi
grep -F 'PLAINPOST_SYNC_NODE_ACCEPTANCE_MAIL_STATE_ROOT' "$private" >/dev/null
grep -F 'run_direct_mode_acceptance' "$owner" >/dev/null
grep -F -- '--filter NotificationRuntimeTests/testProductionAuthenticatedProducerSelectorSwitchesMacSyncNodeMacWithAuthoritativeReload' "$owner" >/dev/null
grep -F 'stage=mail-matrix scenario=direct-mode-switch-authoritative-reload outcome=pass' "$owner" >/dev/null
grep -F 'find "$direct_policy_tmp" -depth -delete' "$owner" >/dev/null
grep -F 'arm-fault' "$private" >/dev/null
grep -F 'smtp_matrix_fault_occurrence=1' "$private" >/dev/null
grep -F 'arm-sent-append-failure' "$private" >/dev/null
grep -F 'arm-sent-append-failure' "$swift" >/dev/null
grep -F 'imap-sent-append' "$private" >/dev/null
if sed -n '/smtp-sent-append-failure)/,/;;/p' "$private" | grep -F 'smtp_matrix_fault=imap-mutation' >/dev/null; then
  echo 'sent append failure must not arm the generic IMAP mutation fault' >&2
  exit 1
fi
grep -F 'smtp_matrix_protocol=imap' "$private" >/dev/null
grep -F 'phase "${smtp_matrix_protocol:-smtp}"' "$private" >/dev/null
grep -F 'restart-imap-fixture' "$swift" >/dev/null
grep -F 'sentCount: 0' "$swift" >/dev/null
grep -F 'smtp-untrusted-certificate' "$private" >/dev/null
grep -F 'smtp-same-ca-wrong-host' "$private" >/dev/null
grep -F 'smtp-tls1.1' "$private" >/dev/null
grep -F 'smtp-auth-before-starttls' "$private" >/dev/null
grep -F 'acceptance_smtp_tls_mode=untrusted-cert' "$private" >/dev/null
grep -F 'acceptance_smtp_tls_mode=wrong-host' "$private" >/dev/null
grep -F 'acceptance_smtp_tls_mode=legacy-tls' "$private" >/dev/null
grep -F 'acceptance_smtp_tls_mode=auth-before-starttls' "$private" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_SMTP_UNTRUSTED_TLS_CERT' "$compose" >/dev/null
grep -F 'smtp-matrix-assert-no-auth' "$private" >/dev/null
grep -F 'restore-smtp-fixture-normal' "$private" >/dev/null
grep -F 'smtp-matrix-assert-no-auth' "$swift" >/dev/null
grep -F 'authentication-command' "$private" >/dev/null
grep -F 'smtp-matrix-assert-authentication-command' "$swift" >/dev/null
if grep -F 's.sendall(b"EHLO probe\\r\\n")' "$private" >/dev/null ||
   grep -F 's.sendall(b"AUTH PLAIN\\r\\n")' "$private" >/dev/null ||
   ! grep -F 's.sendall(b"EHLO probe\r\n")' "$private" >/dev/null ||
   ! grep -F 's.sendall(b"AUTH PLAIN\r\n")' "$private" >/dev/null; then
  printf 'SMTP authentication-command probe must send real CRLF bytes, not literal backslash escapes\n' >&2
  exit 1
fi
# A provider-backed recovery send consumes its recovery draft. Keep the
# recovery postcondition aligned with the same send lifecycle asserted by the
# ordinary accepted-send path above.
if ! sed -n '/if tlsStartupFailure {/,/return/p' "$swift" |
   grep -F 'checkpoint: "send-delivery", draftCount: 0, deliveryCount: 1,' >/dev/null; then
  printf 'SMTP TLS recovery must expect the recovery draft to be consumed by the accepted send\n' >&2
  exit 1
fi
grep -F 'stage=mail-matrix scenario=%s outcome=%s' "$owner" >/dev/null
if "$owner" --scenario unknown-selector >/dev/null 2>&1; then
  printf 'unknown SMTP matrix selector was accepted\n' >&2
  exit 1
fi
if "$owner" --group unknown-group >/dev/null 2>&1; then
  printf 'unknown SMTP matrix group was accepted\n' >&2
  exit 1
fi

# The matrix gate must preserve the authoritative client wrapper's exact
# failure status. A generic status 1 would erase the distinction between
# transient/unavailable and protocol failures.
status_wrapper="$fixture/status-wrapper"
cat >"$status_wrapper" <<'EOF'
#!/bin/sh
printf 'fake client wrapper failure\n' >&2
exit 42
EOF
chmod 0700 "$status_wrapper"
set +e
PLAINPOST_SYNC_NODE_MAIL_MATRIX_CLIENT_API_WRAPPER="$status_wrapper" "$owner" --scenario smtp-authentication >"$fixture/status-output" 2>&1
status=$?
set -e
[ "$status" -eq 42 ] || { printf 'matrix owner changed authoritative failure status to %s\n' "$status" >&2; exit 1; }
grep -F 'stage=mail-matrix scenario=smtp-authentication outcome=fail' "$fixture/status-output" >/dev/null

set +e
PLAINPOST_SYNC_NODE_MAIL_MATRIX_CLIENT_API_WRAPPER="$status_wrapper" "$owner" --all >"$fixture/all-status-output" 2>&1
status=$?
set -e
[ "$status" -eq 42 ] || { printf 'matrix all owner changed authoritative failure status to %s\n' "$status" >&2; exit 1; }
grep -Fx 'stage=mail-matrix scenario=direct-mode-switch-authoritative-reload outcome=pass' "$fixture/all-status-output" >/dev/null
if grep -Eq '(mailbox|request|digest|token|credential|password|secret|smtp|imap)[=_][^ ]+' "$fixture/all-status-output"; then
  printf 'matrix Direct policy summary leaked a private coordinate\n' >&2
  exit 1
fi
printf 'sync-node-mail-matrix contract: PASS\n'
