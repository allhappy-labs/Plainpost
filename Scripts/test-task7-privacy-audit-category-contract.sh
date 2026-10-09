#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/plainpost-task7-category.XXXXXX")
trap 'find "$temporary" -depth -delete >/dev/null 2>&1 || true' EXIT

. "$root/Scripts/lib/task7-privacy-audit-category.sh"

output="$temporary/audit-output"
printf '%s\n' \
  'sync node Task 7 privacy audit unavailable category=inputs subcategory=actual-patterns' \
  'sync node Task 7 privacy audit unavailable category=central-returned-counts cell=node_enrollment_results.replacement_evidence_wire' \
  'private-secret-must-not-be-published' >"$output"
category=$(task7_privacy_audit_category_from_output "$output")
[ "$category" = central-returned-counts ] || {
  printf 'Task 7 category contract selected %s\n' "$category" >&2
  exit 1
}

subcategory=$(task7_privacy_audit_input_subcategory_from_output "$output")
[ "$subcategory" = actual-patterns ] || {
  printf 'Task 7 input subcategory contract selected %s\n' "$subcategory" >&2
  exit 1
}

cell=$(task7_privacy_audit_cell_from_output "$output")
[ "$cell" = unknown ] || {
  printf 'Task 7 cell contract accepted a non-central category\n' >&2
  exit 1
}

printf '%s\n' \
  'sync node Task 7 privacy audit unavailable category=central-marker-count cell=node_enrollment_results.replacement_evidence_wire' \
  'sync node Task 7 privacy audit unavailable category=central-marker-count cell=private-secret-must-not-be-published' >"$output"
cell=$(task7_privacy_audit_cell_from_output "$output")
[ "$cell" = node_enrollment_results.replacement_evidence_wire ] || {
  printf 'Task 7 cell contract selected %s\n' "$cell" >&2
  exit 1
}

if printf '%s\n' "$cell" | grep -Eiq 'plainpost|secret|token|credential|private'; then
  printf 'Task 7 cell contract published sensitive material\n' >&2
  exit 1
fi

diagnostic="$temporary/diagnostic"
printf 'private database audit failed category=central-marker-count cell=%s; values suppressed\n' "$cell" >"$diagnostic"
grep -Fx 'private database audit failed category=central-marker-count cell=node_enrollment_results.replacement_evidence_wire; values suppressed' "$diagnostic" >/dev/null

printf '%s\n' \
  'sync node Task 7 privacy audit unavailable category=central-marker-count cell=private-secret-must-not-be-published' >"$output"
cell=$(task7_privacy_audit_cell_from_output "$output")
[ "$cell" = unknown ] || {
  printf 'Task 7 cell contract accepted an unallowlisted cell\n' >&2
  exit 1
}
if printf '%s\n' "$cell" | grep -Eiq 'plainpost|secret|token|credential|private'; then
  printf 'Task 7 unknown cell fallback published sensitive material\n' >&2
  exit 1
fi

printf '%s\n' \
  'sync node Task 7 privacy audit unavailable category=inputs subcategory=private-value' \
  'sync node Task 7 privacy audit unavailable category=inputs subcategory=unknown' >"$output"
subcategory=$(task7_privacy_audit_input_subcategory_from_output "$output")
[ "$subcategory" = unknown ] || {
  printf 'Task 7 input subcategory contract accepted an unallowlisted value\n' >&2
  exit 1
}
printf '%s\n' \
  'sync node Task 7 privacy audit unavailable category=inputs subcategory=node-one-database-file reason=mode' \
  'sync node Task 7 privacy audit unavailable category=inputs subcategory=node-one-database-file reason=postgres://secret' >"$output"
reason=$(task7_privacy_audit_input_reason_from_output "$output")
[ "$reason" = mode ] || {
  printf 'Task 7 input reason contract selected %s\n' "$reason" >&2
  exit 1
}
failure=$(task7_privacy_audit_input_failure_from_output "$output")
[ "$failure" = 'node-one-database-file mode' ] || {
  printf 'Task 7 input failure contract selected %s\n' "$failure" >&2
  exit 1
}
if printf '%s\n' "$reason" | grep -Eiq 'secret|postgres|plainpost|/'; then
  printf 'Task 7 input reason contract published sensitive material\n' >&2
  exit 1
fi
printf '%s\n' \
  'sync node Task 7 privacy audit unavailable category=node-two-marker-query reason=missing-node-current-authority-state' \
  'sync node Task 7 privacy audit unavailable category=node-one-connect reason=connection' >"$output"
failure=$(task7_privacy_audit_node_failure_from_output "$output")
[ "$failure" = 'node-one-connect connection' ] || {
	printf 'Task 7 node reason contract selected %s\n' "$failure" >&2
  exit 1
}
printf '%s\n' \
  'sync node Task 7 privacy audit unavailable category=node-two-marker-count reason=permission' >"$output"
failure=$(task7_privacy_audit_node_failure_from_output "$output")
[ "$failure" = 'unknown unknown' ] || {
	printf 'Task 7 node reason contract accepted a count reason: %s\n' "$failure" >&2
  exit 1
}
printf '%s\n' \
  'sync node Task 7 privacy audit unavailable category=node-two-marker-query reason=private-secret' \
  'sync node Task 7 privacy audit unavailable category=node-two-marker-query' >"$output"
failure=$(task7_privacy_audit_node_failure_from_output "$output")
[ "$failure" = 'node-two-marker-query unknown' ] || {
	printf 'Task 7 node reason contract synthesized or leaked a reason: %s\n' "$failure" >&2
  exit 1
}
printf '%s\n' \
  'sync node Task 7 privacy audit unavailable category=node-two-marker-query reason=relation-missing' \
  'sync node Task 7 privacy audit unavailable category=node-two-connect reason=permission' >"$output"
failure=$(task7_privacy_audit_node_failure_from_output "$output")
[ "$failure" = 'node-two-connect permission' ] || {
	printf 'Task 7 node reason contract did not select the complete latest record: %s\n' "$failure" >&2
  exit 1
}
printf '%s\n' \
  'sync node Task 7 privacy audit unavailable category=node-two-marker-query reason=relation-missing' \
  'sync node Task 7 privacy audit unavailable category=node-two-connect' >"$output"
failure=$(task7_privacy_audit_node_failure_from_output "$output")
[ "$failure" = 'node-two-connect unknown' ] || {
  printf 'Task 7 node failure contract synthesized independent category/reason: %s\n' "$failure" >&2
  exit 1
}
printf '%s\n' \
  'sync node Task 7 privacy audit unavailable category=node-two-marker-query reason=relation-missing' \
  'sync node Task 7 privacy audit unavailable category=node-two-connect reason=permission' >"$output"
failure=$(task7_privacy_audit_node_failure_from_output "$output")
[ "$failure" = 'node-two-connect permission' ] || {
  printf 'Task 7 node failure contract did not keep an atomic pair: %s\n' "$failure" >&2
  exit 1
}
printf '%s\n' \
  'sync node Task 7 privacy audit unavailable category=node-two-marker-query reason=relation-missing' \
  'sync node Task 7 privacy audit unavailable category=node-two-marker-query raw=private-secret' >"$output"
failure=$(task7_privacy_audit_node_failure_from_output "$output")
[ "$failure" = 'node-two-marker-query unknown' ] || {
  printf 'Task 7 node failure contract retained an older pair after malformed latest record: %s\n' "$failure" >&2
  exit 1
}
printf '%s\n' \
  'sync node Task 7 privacy audit unavailable category=inputs subcategory=private-secret reason=mode' \
  'sync node Task 7 privacy audit unavailable category=inputs subcategory=node-one-database-file' >"$output"
reason=$(task7_privacy_audit_input_reason_from_output "$output")
[ "$reason" = unknown ] || {
  printf 'Task 7 input reason contract synthesized a reason across lines: %s\n' "$reason" >&2
  exit 1
}
failure=$(task7_privacy_audit_input_failure_from_output "$output")
[ "$failure" = 'node-one-database-file unknown' ] || {
  printf 'Task 7 input failure contract synthesized a reason across lines: %s\n' "$failure" >&2
  exit 1
}
printf '%s\n' \
  'sync node Task 7 privacy audit unavailable category=inputs subcategory=node-one-database-file reason=mode' \
  'sync node Task 7 privacy audit unavailable category=inputs subcategory=node-two-database-file' >"$output"
failure=$(task7_privacy_audit_input_failure_from_output "$output")
[ "$failure" = 'node-two-database-file unknown' ] || {
  printf 'Task 7 input failure contract combined independent records: %s\n' "$failure" >&2
  exit 1
}
printf '%s\n' 'sync node Task 7 privacy audit unavailable category=private-secret-must-not-be-published' >"$output"
category=$(task7_privacy_audit_category_from_output "$output")
[ "$category" = unknown ] || {
  printf 'Task 7 category contract accepted an unknown category\n' >&2
  exit 1
}

printf 'task7_privacy_audit_category_contract=passed\n'
