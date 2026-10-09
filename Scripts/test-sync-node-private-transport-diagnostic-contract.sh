#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
target="$root/Scripts/test-sync-node-private-transport.sh"
stream_summary_helper="$root/Scripts/lib/sync-node-stream-diagnostic-summary.sh"
privacy_scan_helper="$root/Scripts/lib/sync-node-privacy-scan.sh"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/plainpost-private-transport-diagnostic.XXXXXX")
trap 'find "$fixture" -depth -delete >/dev/null 2>&1 || true' EXIT HUP INT TERM

# The privacy scanner must retain only fixed source/origin categories. Exercise
# every category through the real helper, including an unclassified legacy
# pattern, while ensuring neither the matched value nor its file path escapes.
if [ ! -f "$privacy_scan_helper" ]; then
  printf 'privacy scan helper is missing\n' >&2
  exit 1
fi
. "$privacy_scan_helper"
privacy_contract_patterns="$fixture/privacy-classifier-patterns"
privacy_contract_origins="$fixture/privacy-classifier-origins"
privacy_contract_output="$fixture/privacy-classifier-output"
: >"$privacy_contract_patterns"
: >"$privacy_contract_origins"
: >"$privacy_contract_output"
chmod 0600 "$privacy_contract_patterns" "$privacy_contract_origins" "$privacy_contract_output"
privacy_contract_sources='runtime-log container-log runtime-config error-surface'
privacy_contract_origins_list='s3-access s3-secret provider-password returned-client unknown'
for privacy_contract_origin in $privacy_contract_origins_list; do
  privacy_contract_value="privacy-${privacy_contract_origin}-secret"
  printf '%s\n' "$privacy_contract_value" >>"$privacy_contract_patterns"
  if [ "$privacy_contract_origin" != unknown ]; then
    printf '%s\t%s\n' "$privacy_contract_origin" "$privacy_contract_value" >>"$privacy_contract_origins"
  fi
done
for privacy_contract_source in $privacy_contract_sources; do
  for privacy_contract_origin in $privacy_contract_origins_list; do
    privacy_contract_value="privacy-${privacy_contract_origin}-secret"
    privacy_contract_file="$fixture/${privacy_contract_source}-${privacy_contract_origin}"
    printf 'source=%s origin=%s value=%s\n' "$privacy_contract_source" "$privacy_contract_origin" "$privacy_contract_value" >"$privacy_contract_file"
    : >"$privacy_contract_output"
    if acceptance_scan_privacy_file "$privacy_contract_file" "$privacy_contract_source" "$privacy_contract_patterns" "$privacy_contract_origins" "$privacy_contract_output"; then
      printf 'privacy classifier accepted a matching value source=%s origin=%s\n' "$privacy_contract_source" "$privacy_contract_origin" >&2
      exit 1
    fi
    grep -F "ERROR acceptance-privacy-match source=$privacy_contract_source origin=$privacy_contract_origin" "$privacy_contract_output" >/dev/null
    if grep -F "$privacy_contract_value" "$privacy_contract_output" >/dev/null || grep -F "$privacy_contract_file" "$privacy_contract_output" >/dev/null; then
      printf 'privacy classifier leaked source value or path\n' >&2
      exit 1
    fi
  done
done
printf 'privacy-classifier-contract=passed\n'

# Fixture crash classification must expose only fixed exception families. The
# source log remains private; this contract exercises category selection and
# rejects arbitrary Python/SQLite class names from the summary vocabulary.
fixture_crash_category_helper="$root/Scripts/lib/acceptance-fixture-crash-category.sh"
fixture_crash_category_root="$fixture/fixture-crash-category"
mkdir -m 0700 "$fixture_crash_category_root"
. "$fixture_crash_category_helper"
for fixture_crash_case in \
  'python-runtime-error|RuntimeError: fixture failed' \
  'python-value-error|ValueError: fixture failed' \
  'python-os-error|FileNotFoundError: fixture failed' \
  'python-ssl-error|ssl.SSLError: fixture failed' \
  'sqlite-operational|sqlite3.OperationalError: fixture failed'; do
  fixture_crash_expected=${fixture_crash_case%%|*}
  fixture_crash_log="$fixture_crash_category_root/$fixture_crash_expected.log"
  printf '%s\n' "${fixture_crash_case#*|}" >"$fixture_crash_log"
  chmod 0600 "$fixture_crash_log"
  [ "$(acceptance_fixture_crash_category "$fixture_crash_log")" = "$fixture_crash_expected" ] || {
    printf 'fixture crash category %s was not classified safely\n' "$fixture_crash_expected" >&2
    exit 1
  }
done

# SQLite operational diagnostics expose only fixed subcategory/seam fields;
# messages, paths, and SQL text never cross this boundary.
for fixture_sqlite_case in \
  'locked|sqlite3.OperationalError: database is locked|BEGIN IMMEDIATE' \
  'open|sqlite3.OperationalError: unable to open database file|PRAGMA journal_mode' \
  'disk-io|sqlite3.OperationalError: disk I/O error|SELECT' \
  'schema|sqlite3.OperationalError: no such table: messages|ALTER TABLE' \
  'readonly|sqlite3.OperationalError: attempt to write a readonly database|BEGIN IMMEDIATE' \
  'corrupt|sqlite3.DatabaseError: database disk image is malformed|SELECT' \
  'other|sqlite3.OperationalError: unexpected operation|unknown seam'; do
  fixture_sqlite_expected=${fixture_sqlite_case%%|*}
  fixture_sqlite_rest=${fixture_sqlite_case#*|}
  fixture_sqlite_log="$fixture_crash_category_root/sqlite-$fixture_sqlite_expected.log"
  printf '%s\n' "${fixture_sqlite_rest%|*} ${fixture_sqlite_rest#*|}" >"$fixture_sqlite_log"
  chmod 0600 "$fixture_sqlite_log"
  [ "$(acceptance_fixture_sqlite_subcategory "$fixture_sqlite_log")" = "$fixture_sqlite_expected" ] || {
    printf 'sqlite subcategory %s was not classified safely\n' "$fixture_sqlite_expected" >&2
    exit 1
  }
  fixture_sqlite_operation_expected=other
  case "${fixture_sqlite_rest#*|}" in
    'BEGIN IMMEDIATE') fixture_sqlite_operation_expected=transaction ;;
    'PRAGMA journal_mode') fixture_sqlite_operation_expected=wal-open ;;
    'ALTER TABLE') fixture_sqlite_operation_expected=schema-migration ;;
    SELECT) fixture_sqlite_operation_expected=read ;;
    'unknown seam') fixture_sqlite_operation_expected=other ;;
  esac
  [ "$(acceptance_fixture_sqlite_operation "$fixture_sqlite_log")" = "$fixture_sqlite_operation_expected" ] || {
    printf 'sqlite operation for %s was not classified safely\n' "$fixture_sqlite_expected" >&2
    exit 1
  }
done
printf 'fixture-sqlite-diagnostic-contract=passed\n'

fixture_crash_unknown_class="$fixture_crash_category_root/unknown-class.log"
printf '%s\n' 'custom.UnknownError: private detail' >"$fixture_crash_unknown_class"
chmod 0600 "$fixture_crash_unknown_class"
[ "$(acceptance_fixture_crash_category "$fixture_crash_unknown_class")" = python-exception ]

fixture_crash_summary="$fixture_crash_category_root/summary.log"
printf '%s\n' 'ERROR acceptance-fixture-restart fixture=smtp-fixture event=crash-classification exit_code=1 oom=false cause=python-value-error' >"$fixture_crash_summary"
printf '%s\n' 'ERROR acceptance-fixture-restart fixture=smtp-fixture event=crash-classification exit_code=1 oom=false cause=custom-private-class' >>"$fixture_crash_summary"
fixture_crash_summary_body=$(grep -E '^ERROR acceptance-fixture-restart fixture=smtp-fixture event=crash-classification exit_code=[0-9]+ oom=(true|false) (cause=(sqlite-busy-locked|sqlite-schema|bind-address|signal|python-runtime-error|python-value-error|python-os-error|python-ssl-error|python-exception|unknown)|cause=sqlite-operational sqlite_subcategory=(locked|open|disk-io|schema|readonly|corrupt|other|none) sqlite_operation=(wal-open|transaction|schema-migration|schema-create|projection-repair|read|other|none))$' "$fixture_crash_summary")
printf '%s\n' "$fixture_crash_summary_body" | grep -F 'cause=python-value-error' >/dev/null
if printf '%s\n' "$fixture_crash_summary_body" | grep -F 'custom-private-class' >/dev/null; then
  printf 'fixture crash summary accepted an untrusted cause vocabulary\n' >&2
  exit 1
fi
grep -F 'cause=(sqlite-busy-locked|sqlite-schema|bind-address|signal|python-runtime-error|python-value-error|python-os-error|python-ssl-error|python-exception|unknown)( |$)|cause=sqlite-operational sqlite_subcategory=(locked|open|disk-io|schema|readonly|corrupt|other|none) sqlite_operation=(wal-open|transaction|schema-migration|schema-create|projection-repair|read|other|none)( |$)' "$target" >/dev/null
printf 'fixture-crash-category-contract=passed\n'

# Privacy-audit failures are emitted into the private runtime log before the
# owner exits. The owner must retain a bounded, fixed-field summary on stderr
# so packaged release wrappers can report the failure after cleanup removes
# that private log. This is intentionally exercised through the real owner
# summary test seam, not by duplicating its filtering logic here.
privacy_audit_summary_output="$fixture/privacy-audit-summary-output"
grep -F 'private-database-audit-summary-temp-leaked=1' "$target" >/dev/null || {
  printf 'privacy audit summary test lacks a safe leaked-temp failure marker\n' >&2
  exit 1
}
grep -F 'if [ -e "$temporary" ]; then' "$target" >/dev/null || {
  printf 'privacy audit summary test does not verify exact temporary removal\n' >&2
  exit 1
}
if PLAINPOST_SYNC_NODE_PRIVATE_DATABASE_AUDIT_FAILURE_SUMMARY_TEST=enabled \
  bash "$target" >"$privacy_audit_summary_output" 2>&1; then
  printf 'privacy audit summary test unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fx 'ERROR private database audit failed category=central-marker-count cell=node_enrollment_results.replacement_evidence_wire' "$privacy_audit_summary_output" >/dev/null || {
  printf 'privacy audit summary omitted valid category/cell\n' >&2
  exit 1
}
grep -Fx 'ERROR private database audit failed category=central-connect' "$privacy_audit_summary_output" >/dev/null || {
  printf 'privacy audit summary omitted valid category\n' >&2
  exit 1
}
grep -Fx 'ERROR private database audit failed category=node-two-marker-query reason=missing-node-current-authority-state' "$privacy_audit_summary_output" >/dev/null || {
  printf 'privacy audit summary omitted valid node query reason\n' >&2
  exit 1
}
grep -Fx 'ERROR private database audit failed category=inputs subcategory=actual-patterns' "$privacy_audit_summary_output" >/dev/null || {
  printf 'privacy audit summary omitted valid input subcategory\n' >&2
  exit 1
}
grep -Fx 'ERROR private database audit failed category=unknown' "$privacy_audit_summary_output" >/dev/null || {
  printf 'privacy audit summary omitted unknown fallback category\n' >&2
  exit 1
}
grep -Fx 'ERROR private database audit failed category=central-marker-count' "$privacy_audit_summary_output" >/dev/null || {
  printf 'privacy audit summary did not degrade unknown cell to category-only\n' >&2
  exit 1
}
if grep -Fx 'ERROR private database audit failed category=central-marker-count cell=unknown' "$privacy_audit_summary_output" >/dev/null; then
  printf 'privacy audit summary exposed unknown cell sentinel\n' >&2
  exit 1
fi
if grep -F 'private-database-audit-summary-temp-leaked=1' "$privacy_audit_summary_output" >/dev/null; then
  printf 'privacy audit summary reported a leaked temporary root\n' >&2
  exit 1
fi
if grep -Eq 'custom-injected|secret-value|raw=|node_enrollment_claimsXendpoint_ciphertext|category=unknown (cell|raw)=|private-secret-must-not-render|node-two-connect reason=private-secret' "$privacy_audit_summary_output"; then
  printf 'privacy audit summary retained non-allowlisted data\n' >&2
  exit 1
fi
printf 'private-database-audit-summary-contract=passed\n'

privacy_audit_reason_summary_output="$fixture/privacy-audit-reason-summary-output"
if PLAINPOST_SYNC_NODE_PRIVATE_DATABASE_AUDIT_REASON_SUMMARY_TEST=enabled \
  bash "$target" >"$privacy_audit_reason_summary_output" 2>&1; then
  printf 'privacy audit reason summary test unexpectedly succeeded\n' >&2
  exit 1
fi
privacy_audit_reason_count=$(grep -c '^ERROR private database audit failed category=inputs subcategory=node-one-database-file reason=mode$' "$privacy_audit_reason_summary_output" || true)
[ "$privacy_audit_reason_count" -eq 80 ] || {
  printf 'privacy audit reason summary retained %s records, want 80\n' "$privacy_audit_reason_count" >&2
  exit 1
}
if grep -Eq 'marker=reason-hostile|reason=mode .* ' "$privacy_audit_reason_summary_output"; then
  printf 'privacy audit reason summary retained an appended or unallowlisted field\n' >&2
  exit 1
fi
printf 'private-database-audit-reason-summary-contract=passed\n'

privacy_audit_reason_leak_output="$fixture/privacy-audit-reason-leak-output"
if PLAINPOST_SYNC_NODE_PRIVATE_DATABASE_AUDIT_REASON_SUMMARY_TEST=enabled \
  PLAINPOST_SYNC_NODE_PRIVATE_DATABASE_AUDIT_REASON_SUMMARY_TEMP_LEAK_TEST=enabled \
  bash "$target" >"$privacy_audit_reason_leak_output" 2>&1; then
  printf 'privacy audit reason leak marker test unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fx 'private-database-audit-reason-summary-temp-leaked=1' "$privacy_audit_reason_leak_output" >/dev/null || {
  printf 'privacy audit reason summary omitted fixed leaked-temp marker\n' >&2
  exit 1
}
if grep -Eq 'secret|postgres|plainpost|reason-hostile' "$privacy_audit_reason_leak_output"; then
  printf 'privacy audit reason leak marker exposed private data\n' >&2
  exit 1
fi
printf 'private-database-audit-reason-leak-marker-contract=passed\n'

# A clean runtime file is the success path for the scanner. Keep every input
# private and mode-restricted, including the empty origin/diagnostic sidecars;
# this catches a POSIX `if` fall-through that turns grep's clean status into a
# false operational failure.
privacy_clean_file="$fixture/privacy-clean-runtime.log"
privacy_clean_patterns="$fixture/privacy-clean-patterns"
privacy_clean_origins="$fixture/privacy-clean-origins"
privacy_clean_diagnostic="$fixture/privacy-clean-diagnostic.log"
printf '%s\n' 'ordinary sanitized runtime status' >"$privacy_clean_file"
printf '%s\n' 'private-value-that-is-absent' >"$privacy_clean_patterns"
: >"$privacy_clean_origins"
: >"$privacy_clean_diagnostic"
chmod 0600 "$privacy_clean_file" "$privacy_clean_patterns" "$privacy_clean_origins" "$privacy_clean_diagnostic"
if acceptance_scan_privacy_file "$privacy_clean_file" runtime-log "$privacy_clean_patterns" "$privacy_clean_origins" "$privacy_clean_diagnostic"; then
  :
else
  printf 'privacy scanner rejected a clean 0600 file\n' >&2
  exit 1
fi
if [ -s "$privacy_clean_diagnostic" ]; then
  printf 'privacy scanner emitted a diagnostic for a clean 0600 file\n' >&2
  exit 1
fi
printf 'privacy-clean-contract=passed\n'

# Invalid source classifications and an operationally unreadable scan target
# are fixed operational failures, never privacy matches. An empty pattern file
# is a valid clean scan and must retain the success status.
if acceptance_scan_privacy_file "$privacy_clean_file" invalid-source "$privacy_clean_patterns" "$privacy_clean_origins" "$privacy_clean_diagnostic"; then
  privacy_invalid_source_status=0
else
  privacy_invalid_source_status=$?
fi
[ "$privacy_invalid_source_status" -eq 2 ] || {
  printf 'privacy scanner accepted an invalid source classification\n' >&2
  exit 1
}
privacy_unreadable_file="$fixture/privacy-unreadable-scan-target"
mkdir "$privacy_unreadable_file"
if acceptance_scan_privacy_file "$privacy_unreadable_file" runtime-log "$privacy_clean_patterns" "$privacy_clean_origins" "$privacy_clean_diagnostic"; then
  privacy_unreadable_status=0
else
  privacy_unreadable_status=$?
fi
[ "$privacy_unreadable_status" -eq 2 ] || {
  printf 'privacy scanner accepted an unreadable scan target\n' >&2
  exit 1
}
: >"$privacy_clean_patterns"
if acceptance_scan_privacy_file "$privacy_clean_file" runtime-log "$privacy_clean_patterns" "$privacy_clean_origins" "$privacy_clean_diagnostic"; then
  :
else
  printf 'privacy scanner rejected an empty pattern file\n' >&2
  exit 1
fi
printf 'privacy-error-contract=passed\n'

patterns="$fixture/privacy-patterns"
runtime_log="$fixture/runtime.log"
printf 'sensitive-diagnostic-value\n' >"$patterns"
cat >"$runtime_log" <<'EOF'
{"level":"WARN","msg":"sync node mutation boundary","boundary":"mutation-admission","outcome":"rejected"}
{"level":"WARN","msg":"sync node mutation boundary","boundary":"mutation-service","outcome":"error","category":"unavailable"}
{"level":"WARN","msg":"sync node mutation boundary","boundary":"mutation-service","outcome":"error","category":"sensitive-diagnostic-value"}
EOF
# Terminal IMAP startup-fault diagnostics must retain only the fixed category
# and outcome vocabulary; arbitrary fields from a failed assertion must not
# escape into the bounded failure summary.
imap_terminal_summary_log="$fixture/imap-terminal-summary.log"
imap_terminal_summary_patterns="$fixture/imap-terminal-summary-patterns"
imap_terminal_summary_output="$fixture/imap-terminal-summary-output.log"
imap_terminal_summary_secret='imap-terminal-private-secret-20260831'
printf '%s\n' "$imap_terminal_summary_secret" >"$imap_terminal_summary_patterns"
cat >"$imap_terminal_summary_log" <<EOF
ERROR acceptance-imap-tls-startup-fault outcome=authentication-changed
ERROR acceptance-imap-tls-startup-fault outcome=handshake-missing
ERROR acceptance-imap-tls-durable-block outcome=checkpoint-invalid
ERROR acceptance-imap-authentication-durable-block outcome=projection-changed
ERROR acceptance-imap-tls-startup-fault outcome=expected detail=$imap_terminal_summary_secret
ERROR acceptance-imap-unrelated outcome=unexpected
EOF
if PLAINPOST_SYNC_NODE_IMAP_TERMINAL_FAILURE_SUMMARY_TEST=enabled \
  PLAINPOST_SYNC_NODE_IMAP_TERMINAL_FAILURE_SUMMARY_LOG="$imap_terminal_summary_log" \
  PLAINPOST_SYNC_NODE_IMAP_TERMINAL_FAILURE_SUMMARY_PATTERNS="$imap_terminal_summary_patterns" \
  "$target" >"$imap_terminal_summary_output" 2>&1; then
  :
else
  printf 'IMAP terminal failure summary selector contract failed\n' >&2
  exit 1
fi
grep -F 'imap_terminal_failure_summary_begin' "$target" >/dev/null
grep -F 'imap_terminal_failure_summary_end' "$target" >/dev/null
grep -F 'outcome=(authentication-changed|handshake-missing|checkpoint-invalid|projection-changed)' "$target" >/dev/null
grep -F 'filter_summary_patterns' "$target" >/dev/null
imap_terminal_summary_body=$(sed -n '/^imap_terminal_failure_summary_begin$/,/^imap_terminal_failure_summary_end$/p' "$imap_terminal_summary_output")
for imap_terminal_marker in \
  'ERROR acceptance-imap-tls-startup-fault outcome=authentication-changed' \
  'ERROR acceptance-imap-tls-startup-fault outcome=handshake-missing' \
  'ERROR acceptance-imap-tls-durable-block outcome=checkpoint-invalid' \
  'ERROR acceptance-imap-authentication-durable-block outcome=projection-changed'; do
  printf '%s\n' "$imap_terminal_summary_body" | grep -F "$imap_terminal_marker" >/dev/null
done
imap_terminal_summary_count=$(printf '%s\n' "$imap_terminal_summary_body" | grep -c '^ERROR acceptance-imap-' || true)
[ "$imap_terminal_summary_count" -eq 4 ]
if printf '%s\n' "$imap_terminal_summary_body" | grep -F "$imap_terminal_summary_secret" >/dev/null ||
   printf '%s\n' "$imap_terminal_summary_body" | grep -F 'acceptance-imap-unrelated' >/dev/null; then
  printf 'IMAP terminal failure summary leaked an unapproved record\n' >&2
  exit 1
fi

# Startup failures can occur before the main privacy-pattern file is created.
# The summary must remain silent (and must not emit a grep diagnostic) until a
# pattern file is available; this does not bypass filtering once it exists.
missing_patterns_output="$fixture/imap-terminal-summary-missing-patterns.log"
missing_patterns_path="$fixture/not-created-patterns"
if PLAINPOST_SYNC_NODE_IMAP_TERMINAL_FAILURE_SUMMARY_TEST=enabled \
  PLAINPOST_SYNC_NODE_IMAP_TERMINAL_FAILURE_SUMMARY_LOG="$imap_terminal_summary_log" \
  PLAINPOST_SYNC_NODE_IMAP_TERMINAL_FAILURE_SUMMARY_PATTERNS="$missing_patterns_path" \
  "$target" >"$missing_patterns_output" 2>&1; then
  :
else
  printf 'IMAP terminal summary must tolerate an absent early privacy-pattern file\n' >&2
  exit 1
fi
missing_patterns_body=$(sed -n '/^imap_terminal_failure_summary_begin$/,/^imap_terminal_failure_summary_end$/p' "$missing_patterns_output")
[ "$(printf '%s\n' "$missing_patterns_body" | wc -l | tr -d ' ')" -eq 2 ]
if grep -F 'No such file' "$missing_patterns_output" >/dev/null; then
  printf 'IMAP terminal summary emitted an absent-pattern diagnostic\n' >&2
  exit 1
fi

# Catalog probe failures must retain the exact bounded step that failed.  The
# selector is deliberately closed: no arm/probe/compare values or diagnostics
# may escape into the summary.
catalog_summary_log="$fixture/imap-catalog-summary.log"
catalog_summary_patterns="$fixture/imap-catalog-summary-patterns"
catalog_summary_output="$fixture/imap-catalog-summary-output.log"
catalog_summary_secret='imap-catalog-private-secret-20260831'
printf '%s\n' "$catalog_summary_secret" >"$catalog_summary_patterns"
for index in $(seq 1 82); do
  printf '%s\n' 'ERROR acceptance-imap-catalog-probe outcome=failed step=arm' >>"$catalog_summary_log"
done
{
  printf '%s\n' 'ERROR acceptance-imap-catalog-probe outcome=failed step=arm'
  printf '%s\n' 'ERROR acceptance-imap-catalog-probe outcome=failed step=expected-unavailable'
  printf '%s\n' 'ERROR acceptance-imap-catalog-probe outcome=failed step=recovery'
  printf '%s\n' 'ERROR acceptance-imap-catalog-probe outcome=failed step=projection'
  printf '%s\n' "ERROR acceptance-imap-catalog-probe outcome=failed step=secret value=$catalog_summary_secret"
  printf '%s\n' 'ERROR acceptance-imap-catalog-unrelated outcome=failed step=arm'
} >>"$catalog_summary_log"
if PLAINPOST_SYNC_NODE_IMAP_CATALOG_PROBE_SUMMARY_TEST=enabled \
  PLAINPOST_SYNC_NODE_IMAP_CATALOG_PROBE_SUMMARY_LOG="$catalog_summary_log" \
  PLAINPOST_SYNC_NODE_IMAP_CATALOG_PROBE_SUMMARY_PATTERNS="$catalog_summary_patterns" \
  "$target" >"$catalog_summary_output" 2>&1; then
  :
else
  printf 'IMAP catalog probe summary selector contract failed\n' >&2
  exit 1
fi
grep -F 'imap_catalog_probe_failure_summary_begin' "$target" >/dev/null
grep -F 'imap_catalog_probe_failure_summary_end' "$target" >/dev/null
grep -F 'step=(arm|expected-unavailable|recovery|projection)' "$target" >/dev/null
catalog_summary_body=$(sed -n '/^imap_catalog_probe_failure_summary_begin$/,/^imap_catalog_probe_failure_summary_end$/p' "$catalog_summary_output")
for catalog_summary_marker in \
  'ERROR acceptance-imap-catalog-probe outcome=failed step=arm' \
  'ERROR acceptance-imap-catalog-probe outcome=failed step=expected-unavailable' \
  'ERROR acceptance-imap-catalog-probe outcome=failed step=recovery' \
  'ERROR acceptance-imap-catalog-probe outcome=failed step=projection'; do
  printf '%s\n' "$catalog_summary_body" | grep -F "$catalog_summary_marker" >/dev/null
done
catalog_summary_count=$(printf '%s\n' "$catalog_summary_body" | grep -c '^ERROR acceptance-imap-catalog-probe ' || true)
[ "$catalog_summary_count" -eq 80 ]
if printf '%s\n' "$catalog_summary_body" | grep -F "$catalog_summary_secret" >/dev/null ||
   printf '%s\n' "$catalog_summary_body" | grep -F 'acceptance-imap-catalog-unrelated' >/dev/null ||
   printf '%s\n' "$catalog_summary_body" | grep -F 'step=secret' >/dev/null; then
  printf 'IMAP catalog probe summary leaked an unapproved record\n' >&2
  exit 1
fi

# Delayed-literal probe failures retain exactly the bounded controller step so
# a post-baseline transport failure is distinguishable from a phase or
# projection predicate failure. The selector must not expose arbitrary data.
delayed_literal_summary_log="$fixture/imap-delayed-literal-summary.log"
delayed_literal_summary_patterns="$fixture/imap-delayed-literal-summary-patterns"
delayed_literal_summary_output="$fixture/imap-delayed-literal-summary-output.log"
delayed_literal_summary_secret='imap-delayed-literal-private-secret-20260901'
printf '%s\n' "$delayed_literal_summary_secret" >"$delayed_literal_summary_patterns"
for index in $(seq 1 82); do
  printf '%s\n' 'ERROR acceptance-imap-delayed-literal-probe outcome=failed step=probe' >>"$delayed_literal_summary_log"
done
{
  printf '%s\n' 'ERROR acceptance-imap-delayed-literal-probe outcome=failed step=arm'
  printf '%s\n' 'ERROR acceptance-imap-delayed-literal-probe outcome=failed step=probe'
  printf '%s\n' 'ERROR acceptance-imap-delayed-literal-probe outcome=failed step=phase'
  printf '%s\n' 'ERROR acceptance-imap-delayed-literal-probe outcome=failed step=projection'
  printf '%s\n' "ERROR acceptance-imap-delayed-literal-probe outcome=failed step=secret value=$delayed_literal_summary_secret"
  printf '%s\n' 'ERROR acceptance-imap-delayed-literal-unrelated outcome=failed step=probe'
} >>"$delayed_literal_summary_log"
if PLAINPOST_SYNC_NODE_IMAP_DELAYED_LITERAL_PROBE_SUMMARY_TEST=enabled \
  PLAINPOST_SYNC_NODE_IMAP_DELAYED_LITERAL_PROBE_SUMMARY_LOG="$delayed_literal_summary_log" \
  PLAINPOST_SYNC_NODE_IMAP_DELAYED_LITERAL_PROBE_SUMMARY_PATTERNS="$delayed_literal_summary_patterns" \
  "$target" >"$delayed_literal_summary_output" 2>&1; then
  :
else
  printf 'IMAP delayed-literal probe summary selector contract failed\n' >&2
  exit 1
fi
grep -F 'imap_delayed_literal_probe_failure_summary_begin' "$target" >/dev/null
grep -F 'imap_delayed_literal_probe_failure_summary_end' "$target" >/dev/null
grep -F 'step=(arm|probe|phase|projection)' "$target" >/dev/null
delayed_literal_summary_body=$(sed -n '/^imap_delayed_literal_probe_failure_summary_begin$/,/^imap_delayed_literal_probe_failure_summary_end$/p' "$delayed_literal_summary_output")
for delayed_literal_summary_marker in \
  'ERROR acceptance-imap-delayed-literal-probe outcome=failed step=arm' \
  'ERROR acceptance-imap-delayed-literal-probe outcome=failed step=probe' \
  'ERROR acceptance-imap-delayed-literal-probe outcome=failed step=phase' \
  'ERROR acceptance-imap-delayed-literal-probe outcome=failed step=projection'; do
  printf '%s\n' "$delayed_literal_summary_body" | grep -F "$delayed_literal_summary_marker" >/dev/null
done
delayed_literal_summary_count=$(printf '%s\n' "$delayed_literal_summary_body" | grep -c '^ERROR acceptance-imap-delayed-literal-probe ' || true)
[ "$delayed_literal_summary_count" -eq 80 ]
if printf '%s\n' "$delayed_literal_summary_body" | grep -F "$delayed_literal_summary_secret" >/dev/null ||
   printf '%s\n' "$delayed_literal_summary_body" | grep -F 'acceptance-imap-delayed-literal-unrelated' >/dev/null ||
   printf '%s\n' "$delayed_literal_summary_body" | grep -F 'step=secret' >/dev/null; then
  printf 'IMAP delayed-literal probe summary leaked an unapproved record\n' >&2
  exit 1
fi

# Central admission rejects intentionally retain a generic 409 at the HTTP
# boundary. The acceptance-only server diagnostic exposes only this closed
# cause vocabulary, and the owner must retain a bounded, filtered tail after
# Compose capture so a transient offer failure is diagnosable without IDs,
# digests, or wire material.
central_admission_summary_log="$fixture/central-admission-summary.log"
central_admission_summary_patterns="$fixture/central-admission-summary-patterns"
central_admission_summary_output="$fixture/central-admission-summary-output.log"
central_admission_summary_secret='central-admission-private-secret-20260901'
printf '%s\n' "$central_admission_summary_secret" >"$central_admission_summary_patterns"
for index in $(seq 1 82); do
  printf 'time=2026-09-01T00:00:%02dZ level=ERROR msg="[DEBUG-central-admission] offer failure" cause=transaction\n' "$((index % 60))" >>"$central_admission_summary_log"
done
for cause in owner-pending-state-or-bundle nonce-replay-or-decode active-offer-conflict capacity insert serialization transaction; do
  printf 'time=2026-09-01T00:01:00Z level=ERROR msg="[DEBUG-central-admission] offer failure" cause=%s\n' "$cause" >>"$central_admission_summary_log"
done
printf 'time=2026-09-01T00:01:01Z level=ERROR msg="[DEBUG-central-admission] offer failure" cause=transaction detail=%s\n' "$central_admission_summary_secret" >>"$central_admission_summary_log"
if ! PLAINPOST_SYNC_NODE_CENTRAL_ADMISSION_FAILURE_SUMMARY_TEST=enabled \
  PLAINPOST_SYNC_NODE_CENTRAL_ADMISSION_FAILURE_SUMMARY_LOG="$central_admission_summary_log" \
  PLAINPOST_SYNC_NODE_CENTRAL_ADMISSION_FAILURE_SUMMARY_PATTERNS="$central_admission_summary_patterns" \
  "$target" >"$central_admission_summary_output" 2>&1; then
  printf 'central admission failure summary test failed\n' >&2
  exit 1
fi
grep -F 'central_admission_failure_summary_begin' "$target" >/dev/null
grep -F 'central_admission_failure_summary_end' "$target" >/dev/null
central_admission_summary_body=$(sed -n '/^central_admission_failure_summary_begin$/,/^central_admission_failure_summary_end$/p' "$central_admission_summary_output")
central_admission_summary_count=$(printf '%s\n' "$central_admission_summary_body" | grep -c 'msg="\[DEBUG-central-admission\] offer failure"' || true)
[ "$central_admission_summary_count" -eq 80 ]
for cause in owner-pending-state-or-bundle nonce-replay-or-decode active-offer-conflict capacity insert serialization transaction; do
  printf '%s\n' "$central_admission_summary_body" | grep -F "cause=$cause" >/dev/null
done
if printf '%s\n' "$central_admission_summary_body" | grep -F "$central_admission_summary_secret" >/dev/null ||
   printf '%s\n' "$central_admission_summary_body" | grep -E 'account|digest|wire|detail=' >/dev/null; then
  printf 'central admission summary retained unbounded or sensitive data\n' >&2
  exit 1
fi
awk '
  /compose_run logs --no-color --no-log-prefix --tail 1000/ { compose=NR }
  /^[[:space:]]+emit_central_admission_failure_summary$/ { summary=NR }
  END { exit !(compose > 0 && summary > compose) }
' "$target"

# Release backup/restore failures are written to the inner runtime log, which
# is removed by the private owner after this summary runs. Keep a bounded,
# fixed-field selector after Compose capture so the outer release adapter can
# retain the terminal step without exposing child output or private details.
grep -F 'release_backup_restore_failure_summary_begin' "$target" >/dev/null
grep -F 'release_backup_restore_failure_summary_end' "$target" >/dev/null
grep -F 'step=(prepare|preflight-container-names|stop-node|backup-execute|backup-verify|backup-publish|negative-fixture-build|negative-case|restore-execute|restore-verify|database-reference)' "$target" >/dev/null
grep -F 'prepare-step=(context|journal-load|key|reader-open|manifest|deletion-before|references|manifest-digest|plan|journal-staging|database-create|attachments-create|payload|payload-context|payload-database-restore|payload-database-client|payload-database-connection|payload-database-archive-input|payload-database-sql-execution|payload-database-process|payload-database-context|payload-attachment-write|payload-integrity|database-validate|attachments-seal|payload-eof|reader-close|deletion-after|journal-prepared)' "$target" >/dev/null
grep -F 'commit-step=(journal-intent|verify-current|database-check|database-switch|attachment-check|attachment-switch|activation|active-verification|retirement|committed-journal)' "$target" >/dev/null
grep -F 'post-child-step=(reference-validation|quarantine|attachment-quarantine|audit-secret-promotion|node-start|readiness|marker-publish) status=(begin|passed|failed)' "$target" >/dev/null
awk '
  /compose_run logs --no-color --no-log-prefix --tail 1000/ { compose=NR }
  /^[[:space:]]+emit_release_backup_restore_failure_summary$/ { summary=NR }
  END { exit !(compose > 0 && summary > compose) }
' "$target"
release_backup_restore_summary_log="$fixture/release-backup-restore-summary.log"
release_backup_restore_summary_patterns="$fixture/release-backup-restore-summary-patterns"
release_backup_restore_summary_output="$fixture/release-backup-restore-summary-output.log"
release_backup_restore_summary_secret='release-backup-restore-summary-private-secret-20260904'
printf '%s\n' "$release_backup_restore_summary_secret" >"$release_backup_restore_summary_patterns"
for index in $(seq 1 85); do
  printf '%s\n' 'ERROR release-backup-restore step=backup-execute status=failed' >>"$release_backup_restore_summary_log"
done
printf '%s\n' 'ERROR release-backup-restore step=prepare status=failed' >>"$release_backup_restore_summary_log"
printf '%s\n' \
  'ERROR release-backup-restore prepare-step=payload-database-restore' \
  'ERROR release-backup-restore prepare-step=payload-database-client' \
  'ERROR release-backup-restore prepare-step=payload-database-connection' \
  'ERROR release-backup-restore prepare-step=payload-database-archive-input' \
  'ERROR release-backup-restore prepare-step=payload-database-sql-execution' \
  'ERROR release-backup-restore prepare-step=payload-database-process' \
  'ERROR release-backup-restore prepare-step=payload-database-context' \
  'ERROR release-backup-restore prepare-step=payload-attachment-write' \
  'ERROR release-backup-restore prepare-step=payload-integrity' \
  'ERROR release-backup-restore prepare-step=payload-context' >>"$release_backup_restore_summary_log"
printf '%s\n' "ERROR release-backup-restore step=prepare-extra status=failed private-detail=$release_backup_restore_summary_secret" >>"$release_backup_restore_summary_log"
printf '%s\n' 'ERROR release-backup-restore failure category=prepare' >>"$release_backup_restore_summary_log"
printf '%s\n' 'ERROR release-backup-restore commit-step=retirement' >>"$release_backup_restore_summary_log"
printf '%s\n' "ERROR release-backup-restore failure category=prepare private-detail=$release_backup_restore_summary_secret" >>"$release_backup_restore_summary_log"
for post_child_step in reference-validation quarantine attachment-quarantine audit-secret-promotion node-start readiness marker-publish; do
  printf '%s\n' "ERROR release-backup-restore post-child-step=$post_child_step status=failed" >>"$release_backup_restore_summary_log"
done
printf '%s\n' "ERROR release-backup-restore post-child-step=marker-publish status=passed private-detail=$release_backup_restore_summary_secret" >>"$release_backup_restore_summary_log"
if ! PLAINPOST_SYNC_NODE_RELEASE_BACKUP_RESTORE_FAILURE_SUMMARY_TEST=enabled \
  PLAINPOST_SYNC_NODE_RELEASE_BACKUP_RESTORE_FAILURE_SUMMARY_LOG="$release_backup_restore_summary_log" \
  PLAINPOST_SYNC_NODE_RELEASE_BACKUP_RESTORE_FAILURE_SUMMARY_PATTERNS="$release_backup_restore_summary_patterns" \
  "$target" >"$release_backup_restore_summary_output" 2>&1; then
  printf 'release backup/restore failure summary selector contract failed\n' >&2
  exit 1
fi
release_backup_restore_summary_body=$(sed -n '/^release_backup_restore_failure_summary_begin$/,/^release_backup_restore_failure_summary_end$/p' "$release_backup_restore_summary_output")
printf '%s\n' "$release_backup_restore_summary_body" | grep -Fx 'ERROR release-backup-restore step=prepare status=failed' >/dev/null
for payload_step in payload-database-restore payload-database-client payload-database-connection payload-database-archive-input payload-database-sql-execution payload-database-process payload-database-context payload-attachment-write payload-integrity payload-context; do
  printf '%s\n' "$release_backup_restore_summary_body" | grep -Fx "ERROR release-backup-restore prepare-step=$payload_step" >/dev/null
done
printf '%s\n' "$release_backup_restore_summary_body" | grep -Fx 'ERROR release-backup-restore failure category=prepare' >/dev/null
printf '%s\n' "$release_backup_restore_summary_body" | grep -Fx 'ERROR release-backup-restore commit-step=retirement' >/dev/null
[ "$(printf '%s\n' "$release_backup_restore_summary_body" | grep -c '^ERROR release-backup-restore step=' || true)" -eq 61 ]
for post_child_step in reference-validation quarantine attachment-quarantine audit-secret-promotion node-start readiness marker-publish; do
  printf '%s\n' "$release_backup_restore_summary_body" | grep -Fx "ERROR release-backup-restore post-child-step=$post_child_step status=failed" >/dev/null
done
if printf '%s\n' "$release_backup_restore_summary_body" | grep -E 'post-child-step=.*private-detail|release-backup-restore-summary-private-secret' >/dev/null; then
  printf 'release backup/restore summary retained an unapproved post-child record\n' >&2
  exit 1
fi
if printf '%s\n' "$release_backup_restore_summary_body" | grep -E 'prepare-extra|private-detail|backup-restore-summary-private-secret' >/dev/null; then
  printf 'release backup/restore failure summary retained an unapproved record\n' >&2
  exit 1
fi

# Restore PTY failures must retain one closed category after the private
# runtime log is discarded. Exercise the classifier against every supported
# fixed message and hostile suffixes; no transcript contents may cross the
# diagnostic boundary.
restore_failure_category_helper="$root/Scripts/lib/acceptance-release-restore-failure-category.sh"
[ -f "$restore_failure_category_helper" ] || {
  printf 'restore failure category helper is missing\n' >&2
  exit 1
}
. "$restore_failure_category_helper"
restore_failure_category_root="$fixture/restore-failure-category"
mkdir -m 0700 "$restore_failure_category_root"
for restore_failure_case in \
  'config|ERROR operations-restore-failure category=config' \
  'lock|ERROR operations-restore-failure category=lock' \
  'source|ERROR operations-restore-failure category=source' \
  'assembly|ERROR operations-restore-failure category=assembly' \
  'prepare|ERROR operations-restore-failure category=prepare' \
  'digest|ERROR operations-restore-failure category=digest' \
  'commit|ERROR operations-restore-failure category=commit' \
  'teardown|ERROR operations-restore-failure category=teardown'; do
  restore_failure_expected=${restore_failure_case%%|*}
  restore_failure_message=${restore_failure_case#*|}
  restore_failure_transcript="$restore_failure_category_root/$restore_failure_expected.log"
  printf '%s\n' "$restore_failure_message" >"$restore_failure_transcript"
  chmod 0600 "$restore_failure_transcript"
  [ "$(classify_release_restore_failure 1 "$restore_failure_transcript")" = "$restore_failure_expected" ] || {
    printf 'restore failure category %s was not classified safely\n' "$restore_failure_expected" >&2
    exit 1
  }
done
restore_failure_pty_transcript="$restore_failure_category_root/pty.log"
: >"$restore_failure_pty_transcript"
chmod 0600 "$restore_failure_pty_transcript"
[ "$(classify_release_restore_failure 124 "$restore_failure_pty_transcript")" = pty ]
[ "$(classify_release_restore_failure 125 "$restore_failure_pty_transcript")" = pty ]
restore_failure_unknown_transcript="$restore_failure_category_root/unknown.log"
printf '%s\n' 'restore failed private-path=/run/secrets/restore-key secret=never-render' >"$restore_failure_unknown_transcript"
chmod 0600 "$restore_failure_unknown_transcript"
[ "$(classify_release_restore_failure 1 "$restore_failure_unknown_transcript")" = unknown ]
restore_failure_hostile_transcript="$restore_failure_category_root/hostile.log"
printf '%s\n' 'ERROR operations-restore-failure category=prepare private-detail=never-render' >"$restore_failure_hostile_transcript"
chmod 0600 "$restore_failure_hostile_transcript"
[ "$(classify_release_restore_failure 1 "$restore_failure_hostile_transcript")" = unknown ]
restore_failure_category_output=$(classify_release_restore_failure 1 "$restore_failure_unknown_transcript")
if printf '%s\n' "$restore_failure_category_output" | grep -E 'private-path|never-render|restore-failure-category' >/dev/null; then
  printf 'restore failure category leaked transcript details\n' >&2
  exit 1
fi
grep -F 'classify_release_restore_failure' "$root/Scripts/lib/acceptance-release-backup-restore.sh" >/dev/null
grep -F 'failure category=' "$root/Scripts/lib/acceptance-release-backup-restore.sh" >/dev/null
grep -F 'prepare-step=' "$root/Scripts/lib/acceptance-release-backup-restore.sh" >/dev/null
grep -F 'classify_release_restore_commit_step' "$root/Scripts/lib/acceptance-release-backup-restore.sh" >/dev/null
restore_prepare_step_transcript="$restore_failure_category_root/prepare-step.log"
printf '%s\n' 'ERROR operations-restore-failure category=prepare' 'ERROR operations-restore-prepare step=payload-integrity' >"$restore_prepare_step_transcript"
chmod 0600 "$restore_prepare_step_transcript"
[ "$(classify_release_restore_prepare_step "$restore_prepare_step_transcript")" = payload-integrity ] || {
  printf 'restore prepare step was not classified safely\n' >&2
  exit 1
}
restore_prepare_step_hostile="$restore_failure_category_root/prepare-step-hostile.log"
printf '%s\n' 'ERROR operations-restore-failure category=prepare' 'ERROR operations-restore-prepare step=payload-integrity private-detail=never-render' >"$restore_prepare_step_hostile"
chmod 0600 "$restore_prepare_step_hostile"
[ "$(classify_release_restore_prepare_step "$restore_prepare_step_hostile")" = unknown ] || {
  printf 'restore prepare step accepted an unallowlisted suffix\n' >&2
  exit 1
}
for restore_commit_step in journal-intent verify-current database-check database-switch attachment-check attachment-switch activation active-verification retirement committed-journal; do
  restore_commit_step_transcript="$restore_failure_category_root/commit-step-$restore_commit_step.log"
  printf '%s\n' 'ERROR operations-restore-failure category=commit' "ERROR operations-restore-commit step=$restore_commit_step" >"$restore_commit_step_transcript"
  chmod 0600 "$restore_commit_step_transcript"
  [ "$(classify_release_restore_commit_step "$restore_commit_step_transcript")" = "$restore_commit_step" ] || {
    printf 'restore commit step was not classified safely: %s\n' "$restore_commit_step" >&2
    exit 1
  }
done
restore_commit_step_hostile="$restore_failure_category_root/commit-step-hostile.log"
printf '%s\n' 'ERROR operations-restore-failure category=commit' 'ERROR operations-restore-commit step=retirement private-detail=never-render' >"$restore_commit_step_hostile"
chmod 0600 "$restore_commit_step_hostile"
[ "$(classify_release_restore_commit_step "$restore_commit_step_hostile")" = unknown ] || {
  printf 'restore commit step accepted an unallowlisted suffix\n' >&2
  exit 1
}
printf 'restore-failure-category-contract=passed\n'

# The immutable source owns an open descriptor until the restore path finishes
# with it. Keep the close defer before the hash-mismatch return so a validly
# opened but digest-mismatched source cannot leak its descriptor.
restore_operations_cli="$root/Services/PlainpostGo/cmd/plainpost-sync-node/operations_cli.go"
awk '
  /source, actualDigest, err := openImmutableRestoreSource/ { opened=NR }
  /defer func\(\) \{ err = joinLocalRestoreTeardownErrors\(err, source.File.Close\) \}/ { closed=NR }
  /hex.EncodeToString\(actualDigest\[:\]\) != strings.ToLower\(digest\)/ { checked=NR }
  END { exit !(opened > 0 && closed > opened && checked > closed) }
' "$restore_operations_cli"
printf 'restore-source-close-order-contract=passed\n'

# Central may emit either JSON slog or the default text slog handler. Keep the
# same fixed cause vocabulary visible through the owner summary seam, with the
# bounded tail and privacy checks applied equally to both forms.
central_admission_json_summary_log="$fixture/central-admission-json-summary.log"
central_admission_json_summary_output="$fixture/central-admission-json-summary-output.log"
central_admission_structured_secret='central-admission-structured-private-secret-20260901'
printf '%s\n' "$central_admission_structured_secret" >>"$central_admission_summary_patterns"
: >"$central_admission_json_summary_log"
for index in $(seq 1 82); do
  printf '{"time":"2026-09-01T00:02:%02dZ","level":"ERROR","msg":"[DEBUG-central-admission] offer failure","cause":"offer-binding"}\n' "$((index % 60))" >>"$central_admission_json_summary_log"
done
printf '%s\n' '2026/09/01 00:02:01 ERROR [DEBUG-central-admission] offer failure cause=offer-liveness' >>"$central_admission_json_summary_log"
# Appended fields are outside the fixed record shape and must not be retained.
printf '%s\n' "{\"time\":\"2026-09-01T00:02:02Z\",\"level\":\"ERROR\",\"msg\":\"[DEBUG-central-admission] offer failure\",\"cause\":\"offer-binding\",\"detail\":\"$central_admission_structured_secret\"}" >>"$central_admission_json_summary_log"
printf '%s\n' "2026/09/01 00:02:03 ERROR [DEBUG-central-admission] offer failure cause=offer-liveness detail=$central_admission_structured_secret" >>"$central_admission_json_summary_log"
printf '%s\n' '2026/09/01 00:02:04 source=/private/path ERROR [DEBUG-central-admission] offer failure cause=offer-binding' >>"$central_admission_json_summary_log"
if ! PLAINPOST_SYNC_NODE_CENTRAL_ADMISSION_FAILURE_SUMMARY_TEST=enabled \
  PLAINPOST_SYNC_NODE_CENTRAL_ADMISSION_FAILURE_SUMMARY_LOG="$central_admission_json_summary_log" \
  PLAINPOST_SYNC_NODE_CENTRAL_ADMISSION_FAILURE_SUMMARY_PATTERNS="$central_admission_summary_patterns" \
  "$target" >"$central_admission_json_summary_output" 2>&1; then
  printf 'central admission JSON selector fixture could not run\n' >&2
  exit 1
fi
central_admission_json_summary_body=$(sed -n '/^central_admission_failure_summary_begin$/,/^central_admission_failure_summary_end$/p' "$central_admission_json_summary_output")
if ! printf '%s\n' "$central_admission_json_summary_body" | grep -F '"msg":"[DEBUG-central-admission] offer failure"' >/dev/null ||
   ! printf '%s\n' "$central_admission_json_summary_body" | grep -F '"cause":"offer-binding"' >/dev/null ||
   ! printf '%s\n' "$central_admission_json_summary_body" | grep -F 'cause=offer-liveness' >/dev/null; then
  printf 'central admission structured selector omitted fixed offer cause\n' >&2
  exit 1
fi
central_admission_json_summary_count=$(printf '%s\n' "$central_admission_json_summary_body" | grep -c '"msg":"\[DEBUG-central-admission\] offer failure"' || true)
central_admission_default_summary_count=$(printf '%s\n' "$central_admission_json_summary_body" | grep -c 'ERROR \[DEBUG-central-admission\] offer failure cause=offer-liveness$' || true)
[ "$central_admission_json_summary_count" -eq 79 ]
[ "$central_admission_default_summary_count" -eq 1 ]
if printf '%s\n' "$central_admission_json_summary_body" | grep -F "$central_admission_structured_secret" >/dev/null ||
   printf '%s\n' "$central_admission_json_summary_body" | grep -F 'detail=' >/dev/null ||
   printf '%s\n' "$central_admission_json_summary_body" | grep -F '"detail"' >/dev/null ||
   printf '%s\n' "$central_admission_json_summary_body" | grep -F '/private/path' >/dev/null; then
  printf 'central admission structured summary retained an appended or sensitive field\n' >&2
  exit 1
fi

# Swift failure output must be captured exactly once before finish stops the
# owned supervisor. The owner-only synthetic mode below proves the same
# one-time capture and privacy-filtered retention without Docker or Swift.
grep -F 'capture_swift_log()' "$target" >/dev/null
if ! awk '
  function brace_delta(line, opens, closes) {
    opens = gsub(/\{/, "{", line)
    closes = gsub(/\}/, "}", line)
    return opens - closes
  }
  /^finish\(\) \{/ { inside=1; depth=1; next }
  inside {
    if (/capture_swift_log/) { capture=NR }
    if (/stop_swift_process/) { stop=NR }
    depth += brace_delta($0)
    if (depth == 0) { exit !(capture > 0 && stop > 0 && capture < stop) }
  }
  END { exit !(capture > 0 && stop > 0 && capture < stop) }
' "$target"; then
  printf 'finish must capture Swift output before stopping its supervisor\n' >&2
  exit 1
fi
swift_capture_output="$fixture/swift-log-capture-output.log"
if ! PLAINPOST_SYNC_NODE_SWIFT_LOG_CAPTURE_TEST=enabled "$target" >"$swift_capture_output" 2>&1; then
  printf 'Swift log capture synthetic contract failed\n' >&2
  exit 1
fi
grep -F 'swift-log-capture-test=passed count=1' "$swift_capture_output" >/dev/null
if grep -F 'swift-capture-private-secret' "$swift_capture_output" >/dev/null; then
  printf 'Swift log capture synthetic contract leaked a privacy marker\n' >&2
  exit 1
fi

for index in $(seq 1 82); do
  printf '[DEBUG-sync-node-runtime] client admission marker=admission-%s mutation=true client_api_ready=false mutation_ready=false recovery_blocked=true\n' "$index" >>"$runtime_log"
done
printf '[DEBUG-sync-node-runtime] client admission marker=sensitive secret=sensitive-diagnostic-value\n' >>"$runtime_log"
printf '[DEBUG-sync-node-runtime] client admission stage=base-client-admission dependency=repository outcome=failed failure_class=repository_not_ready context_class=active\n' >>"$runtime_log"
printf '[DEBUG-sync-node-runtime] client admission stage=base-client-admission dependency=secret-store outcome=failed failure_class=secret_store_not_ready context_class=active\n' >>"$runtime_log"
printf '[DEBUG-sync-node-runtime] client admission stage=base-client-admission dependency=repository outcome=failed failure_class=timeout context_class=deadline\n' >>"$runtime_log"
printf '[DEBUG-sync-node-runtime] client admission stage=base-client-admission dependency=request outcome=failed failure_class=canceled context_class=canceled\n' >>"$runtime_log"
for index in $(seq 1 45); do
  printf '[DEBUG-sync-node-stream] stream_id=%s event=process-run-success running=true\n' "$index" >>"$runtime_log"
  printf '[DEBUG-sync-node-stream] stream_id=%s event=lifecycle-removed present=false\n' "$index" >>"$runtime_log"
done
for index in $(seq 1 122); do
  printf '[DEBUG-sync-node-stream] stream_id=1 event=terminate-end marker=stream-%s running=false kill_sent=true kill_succeeded=true\n' "$index" >>"$runtime_log"
done
printf '[DEBUG-sync-node-stream] stream_id=45 event=terminate-end secret=sensitive-diagnostic-value\n' >>"$runtime_log"

cat >"$runtime_log.lifecycle" <<'EOF'
ERROR acceptance-signal-timeout signal=attachment-complete swift_alive=1
ERROR swift-process-termination outcome=forced
ERROR swift-process-termination secret=sensitive-diagnostic-value
EOF

# The production summary must select the fixed diagnostic message explicitly,
# then apply the existing privacy pattern filter before writing stderr.
grep -F "grep -F 'sync node mutation boundary' \"\$runtime_log\" | filter_summary_patterns \"\$patterns\"" "$target" >/dev/null
diagnostic_summary=$(grep -F 'sync node mutation boundary' "$runtime_log" | grep -F -v -f "$patterns")
printf '%s\n' "$diagnostic_summary" | grep -F 'mutation-admission' >/dev/null
printf '%s\n' "$diagnostic_summary" | grep -F 'category":"unavailable' >/dev/null
if printf '%s\n' "$diagnostic_summary" | grep -F 'sensitive-diagnostic-value' >/dev/null; then
  printf 'mutation diagnostic contract leaked a privacy marker\n' >&2
  exit 1
fi

# Timeout and forced-termination evidence has its own bounded summary so later
# compose output cannot evict the lifecycle boundary from a generic tail.
grep -F "grep -E '^ERROR (acceptance-signal-timeout|swift-process-termination)' \"\$runtime_log\" | filter_summary_patterns \"\$patterns\"" "$target" >/dev/null
lifecycle_summary=$(grep -E '^ERROR (acceptance-signal-timeout|swift-process-termination)' "$runtime_log.lifecycle" | grep -F -v -f "$patterns")
printf '%s\n' "$lifecycle_summary" | grep -F 'acceptance-signal-timeout' >/dev/null
printf '%s\n' "$lifecycle_summary" | grep -F 'outcome=forced' >/dev/null
if printf '%s\n' "$lifecycle_summary" | grep -F 'sensitive-diagnostic-value' >/dev/null; then
  printf 'lifecycle diagnostic contract leaked a privacy marker\n' >&2
  exit 1
fi

grep -F 'mutation_boundary_summary_begin' "$target" >/dev/null
grep -F 'mutation_boundary_summary_end' "$target" >/dev/null

# Runtime admission state is emitted before the HTTP route can be reached.
# Retain it in its own bounded summary so a pre-mutation 503 is distinguishable
# from a local authority fence, while applying the same privacy filter.
grep -F "grep -F '[DEBUG-sync-node-runtime] client admission' \"\$runtime_log\" | filter_summary_patterns \"\$patterns\"" "$target" >/dev/null
grep -F "grep -F '[DEBUG-sync-node-runtime] client admission' \"\$runtime_log\" | filter_summary_patterns \"\$patterns\" | tail -80 >&2 || true" "$target" >/dev/null
admission_summary=$(grep -F '[DEBUG-sync-node-runtime] client admission' "$runtime_log" | grep -F -v -f "$patterns" | tail -80)
admission_count=$(printf '%s\n' "$admission_summary" | wc -l | tr -d ' ')
[ "$admission_count" -eq 80 ]
printf '%s\n' "$admission_summary" | grep -F 'marker=admission-7' >/dev/null
printf '%s\n' "$admission_summary" | grep -F 'marker=admission-82' >/dev/null
if printf '%s\n' "$admission_summary" | grep -F 'marker=admission-6 mutation' >/dev/null; then
  printf 'runtime admission contract retained an unbounded early record\n' >&2
  exit 1
fi
for marker in \
  'stage=base-client-admission dependency=repository outcome=failed failure_class=repository_not_ready context_class=active' \
  'stage=base-client-admission dependency=secret-store outcome=failed failure_class=secret_store_not_ready context_class=active' \
  'stage=base-client-admission dependency=repository outcome=failed failure_class=timeout context_class=deadline' \
  'stage=base-client-admission dependency=request outcome=failed failure_class=canceled context_class=canceled'; do
  printf '%s\n' "$admission_summary" | grep -F "$marker" >/dev/null
done
if printf '%s\n' "$admission_summary" | grep -F 'sensitive-diagnostic-value' >/dev/null; then
  printf 'runtime admission contract leaked a privacy marker\n' >&2
  exit 1
fi

# Stream cancellation telemetry is state-only and must remain bounded and
# redacted after compose output has been appended.
grep -F "grep -F '[DEBUG-sync-node-stream]' \"\$runtime_log\" | filter_summary_patterns \"\$patterns\" | tail -120 >&2 || true" "$target" >/dev/null
stream_summary=$(grep -F '[DEBUG-sync-node-stream]' "$runtime_log" | grep -F -v -f "$patterns" | tail -120)
stream_count=$(printf '%s\n' "$stream_summary" | wc -l | tr -d ' ')
[ "$stream_count" -eq 120 ]
printf '%s\n' "$stream_summary" | grep -F 'marker=stream-3' >/dev/null
printf '%s\n' "$stream_summary" | grep -F 'marker=stream-122' >/dev/null
if printf '%s\n' "$stream_summary" | grep -F 'marker=stream-2 running' >/dev/null; then
  printf 'stream diagnostic contract retained an unbounded early record\n' >&2
  exit 1
fi
if printf '%s\n' "$stream_summary" | grep -F 'sensitive-diagnostic-value' >/dev/null; then
  printf 'stream diagnostic contract leaked a privacy marker\n' >&2
  exit 1
fi
grep -F 'acceptance_stream_lifecycle_summary_begin' "$target" >/dev/null
grep -F 'acceptance_stream_lifecycle_summary_end' "$target" >/dev/null
grep -F 'try CurlAcceptanceStreamDiagnostics.reset()' "$root/Tests/PlainpostAccountRuntimeTests/SyncNodePrivateTransportLiveTests.swift" >/dev/null
grep -F 'static func reset()' "$root/Tests/PlainpostAccountRuntimeTests/SyncNodePrivateTransportLiveTests.swift" >/dev/null
grep -F 'var nextStreamID' "$root/Tests/PlainpostAccountRuntimeTests/SyncNodePrivateTransportLiveTests.swift" >/dev/null
grep -F 'record(streamID: Int' "$root/Tests/PlainpostAccountRuntimeTests/SyncNodePrivateTransportLiveTests.swift" >/dev/null
stream_source="$root/Tests/PlainpostAccountRuntimeTests/SyncNodePrivateTransportLiveTests.swift"
cleanup_line=$(grep -nF 'private func cleanupArtifacts()' "$stream_source" | head -1 | cut -d: -f1)
lifecycle_line=$(grep -nF 'record("event=lifecycle-removed present=' "$stream_source" | head -1 | cut -d: -f1)
pump_line=$(grep -nF 'private func pump()' "$stream_source" | head -1 | cut -d: -f1)
[ "$lifecycle_line" -gt "$cleanup_line" ]
if sed -n "${pump_line},${cleanup_line}p" "$stream_source" | grep -F 'record("event=lifecycle-removed present=' >/dev/null; then
  printf 'stream lifecycle removal telemetry must follow artifact cleanup\n' >&2
  exit 1
fi
grep -F 'acceptance_stream_terminal_summary_begin' "$target" >/dev/null
grep -F 'acceptance_stream_terminal_summary_end' "$target" >/dev/null
grep -F 'stream_id=' "$root/Tests/PlainpostAccountRuntimeTests/SyncNodePrivateTransportLiveTests.swift" >/dev/null
grep -F '. "$stream_summary_helper"' "$target" >/dev/null
. "$stream_summary_helper"
stream_terminal_summary=$(sync_node_stream_terminal_summary "$runtime_log" "$patterns")
stream_count=$(printf '%s\n' "$stream_terminal_summary" | wc -l | tr -d ' ')
[ "$stream_count" -eq 40 ]
expected_stream_ids=$(for index in $(seq 6 45); do printf 'stream_id=%s\n' "$index"; done)
actual_stream_ids=$(printf '%s\n' "$stream_terminal_summary" | awk '{ print $1 }')
[ "$actual_stream_ids" = "$expected_stream_ids" ]
printf '%s\n' "$stream_terminal_summary" | grep -F 'stream_id=6 count=2 terminal=event=lifecycle-removed present=false' >/dev/null
printf '%s\n' "$stream_terminal_summary" | grep -F 'stream_id=45 count=2 terminal=event=lifecycle-removed present=false' >/dev/null
if printf '%s\n' "$stream_terminal_summary" | grep -F 'stream_id=5 ' >/dev/null; then
  printf 'stream terminal diagnostic contract retained an early stream\n' >&2
  exit 1
fi
if printf '%s\n' "$stream_terminal_summary" | grep -F 'sensitive-diagnostic-value' >/dev/null; then
  printf 'stream terminal diagnostic contract leaked a privacy marker\n' >&2
  exit 1
fi
grep -F 'sync_node_stream_terminal_summary "$runtime_log" "$patterns"' "$target" >/dev/null
awk '
  /compose_run logs --no-color --no-log-prefix --tail 1000/ { compose=NR }
  /acceptance_stream_lifecycle_summary_begin/ { summary=NR }
  END { exit !(compose > 0 && summary > compose) }
' "$target"
awk '
  /compose_run logs --no-color --no-log-prefix --tail 1000/ { compose=NR }
  /acceptance_stream_terminal_summary_begin/ { summary=NR }
  END { exit !(compose > 0 && summary > compose) }
' "$target"
grep -F 'runtime_admission_summary_begin' "$target" >/dev/null
grep -F 'runtime_admission_summary_end' "$target" >/dev/null
awk '
  /compose_run logs --no-color --no-log-prefix --tail 1000/ { compose=NR }
  /runtime_admission_summary_begin/ { summary=NR }
  END { exit !(compose > 0 && summary > compose) }
' "$target"
grep -F 'swift_lifecycle_failure_summary_begin' "$target" >/dev/null
grep -F 'swift_lifecycle_failure_summary_end' "$target" >/dev/null
awk '
  /compose_run logs --no-color --no-log-prefix --tail 1000/ { compose=NR }
  /swift_lifecycle_failure_summary_begin/ { summary=NR }
  END { exit !(compose > 0 && summary > compose) }
' "$target"
grep -F 'scan_privacy_file "$runtime_log"' "$target" >/dev/null
printf 'sync_node_private_transport_diagnostic_contract=passed\n'
