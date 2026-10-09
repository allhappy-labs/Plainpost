#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
summary_helper="$root/Scripts/lib/release-image-failure-summary.sh"
temporary=$(mktemp -d /private/tmp/plainpost-release-summary-contract.XXXXXX)
trap 'find "$temporary" -depth -delete >/dev/null 2>&1 || true' EXIT

diagnostic="$temporary/private-owner.log"
cat >"$diagnostic" <<'EOF'
stage=privacy-audit
ERROR swift-stage stage=backup-restore-verify-failed-snapshot
ERROR swift-stage stage=backup-restore-verify-failed-snapshot secret=must-not-render
ERROR swift-stage stage=backup-restore-verify-failed-snapshot-extra
ERROR swift-stage stage=backup-restore-verify-failed-status-state
ERROR swift-stage stage=backup-restore-verify-failed-status-secret
ERROR swift-stage stage=backup-restore-verify-failed secret=must-not-render
ERROR private database audit failed category=central-marker-count cell=node_enrollment_results.replacement_evidence_wire
ERROR private database audit failed category=inputs subcategory=actual-patterns
ERROR private database audit failed category=inputs subcategory=private-secret-must-not-render
ERROR private database audit failed category=central-marker-count cell=unclassified
ERROR private database audit failed category=central-marker-count cell=unknown
ERROR private database audit failed category=unknown
ERROR private database audit failed category=unknown cell=unclassified
ERROR private database audit failed category=central-connect raw=must-not-render
ERROR private database audit failed category=central-connect
ERROR private database audit failed category=node-two-marker-query reason=missing-node-installation-state
node-two-schema-checkpoint phase=before-privacy-audit status=failed cause=node-installation-state
node-two-schema-checkpoint phase=before-privacy-audit status=passed state=reset
node-two-schema-checkpoint phase=before-privacy-audit status=failed cause=reset-probe
ERROR private database audit failed category=node-two-connect reason=private-secret
ERROR private database audit failed category=custom-injected cell=secret-value
ERROR private database audit failed category=central-marker-count cell=secret-value raw=secret-value
ERROR private database audit failed category=central-marker-count cell=node_enrollment_claimsXendpoint_ciphertext
EOF

for schema_cause in container-missing container-not-running psql-connect migration-ledger migration-head node-installation-state node-current-authority-state node-secrets relation-query reset-query reset-probe reset-mismatch unexpected-output; do
  printf 'node-two-schema-checkpoint phase=after-restarts status=failed cause=%s\n' "$schema_cause" >>"$diagnostic"
done
summary=$(bash -c '. "$1"; release_image_failure_summary "$2"' _ "$summary_helper" "$diagnostic")
grep -Fx 'ERROR swift-stage stage=backup-restore-verify-failed-snapshot' <<<"$summary" >/dev/null || {
	printf 'release summary omitted backup/restore verification mismatch class\n' >&2
	exit 1
}
grep -Fx 'ERROR swift-stage stage=backup-restore-verify-failed-status-state' <<<"$summary" >/dev/null || {
	printf 'release summary omitted backup/restore status mismatch class\n' >&2
	exit 1
}
grep -Fx 'ERROR private database audit failed category=central-marker-count cell=node_enrollment_results.replacement_evidence_wire' <<<"$summary" >/dev/null || {
	printf 'release summary omitted valid private database audit category/cell\n' >&2
	exit 1
}
grep -Fx 'ERROR private database audit failed category=central-connect' <<<"$summary" >/dev/null || {
	printf 'release summary omitted valid private database audit category\n' >&2
	exit 1
}
grep -Fx 'ERROR private database audit failed category=node-two-marker-query reason=missing-node-installation-state' <<<"$summary" >/dev/null || {
	printf 'release summary omitted valid node database audit reason\n' >&2
	exit 1
}
grep -Fx 'node-two-schema-checkpoint phase=before-privacy-audit status=failed cause=node-installation-state' <<<"$summary" >/dev/null || {
  printf 'release summary omitted node-two schema checkpoint failure\n' >&2
  exit 1
}
grep -Fx 'node-two-schema-checkpoint phase=before-privacy-audit status=passed state=reset' <<<"$summary" >/dev/null || {
  printf 'release summary omitted node-two reset baseline evidence\n' >&2
  exit 1
}
grep -Fx 'node-two-schema-checkpoint phase=before-privacy-audit status=failed cause=reset-probe' <<<"$summary" >/dev/null || {
	printf 'release summary omitted node-two reset probe failure\n' >&2
	exit 1
}
for schema_cause in container-missing container-not-running psql-connect migration-ledger migration-head node-installation-state node-current-authority-state node-secrets relation-query reset-query reset-probe reset-mismatch unexpected-output; do
  grep -Fx "node-two-schema-checkpoint phase=after-restarts status=failed cause=$schema_cause" <<<"$summary" >/dev/null || {
    printf 'release summary omitted node-two schema cause=%s\n' "$schema_cause" >&2
    exit 1
  }
done
[ "$(grep -Fc 'node-two-schema-checkpoint phase=after-restarts status=failed cause=reset-probe' <<<"$summary")" -eq 1 ] || {
	printf 'release summary duplicated node-two reset probe failure\n' >&2
	exit 1
}
reset_probe_diagnostic="$temporary/reset-probe-owner.log"
printf 'node-two-schema-checkpoint phase=before-privacy-audit status=failed cause=reset-probe\n' >"$reset_probe_diagnostic"
i=1
while [ "$i" -le 100 ]; do
	printf 'stage=images-loaded\n' >>"$reset_probe_diagnostic"
	i=$((i + 1))
done
reset_probe_summary=$(bash -c '. "$1"; release_image_failure_summary "$2"' _ "$summary_helper" "$reset_probe_diagnostic")
[ "$(grep -Fc 'node-two-schema-checkpoint phase=before-privacy-audit status=failed cause=reset-probe' <<<"$reset_probe_summary")" -eq 1 ] || {
	printf 'release summary lost reset probe after later valid records\n' >&2
	exit 1
}
! grep -Eq 'postgresql://|password|secret|SELECT|node_installation_state' <<<"$reset_probe_summary" || {
	printf 'release summary leaked reset probe diagnostic data\n' >&2
	exit 1
}
grep -Fx 'ERROR private database audit failed category=inputs subcategory=actual-patterns' <<<"$summary" >/dev/null || {
	printf 'release summary omitted valid private database audit input subcategory\n' >&2
	exit 1
}
grep -Fx 'ERROR private database audit failed category=central-marker-count' <<<"$summary" >/dev/null || {
	printf 'release summary omitted category-only private database audit failure\n' >&2
	exit 1
}
grep -Fx 'ERROR private database audit failed category=unknown' <<<"$summary" >/dev/null || {
	printf 'release summary omitted unknown fallback category\n' >&2
	exit 1
}
if grep -Eq 'category=unknown (cell|raw)=|must-not-render|private-secret-must-not-render|central-connect raw=|node-two-connect reason=private-secret' <<<"$summary"; then
	printf 'release summary retained an unanchored or raw private audit suffix\n' >&2
	exit 1
fi
if grep -Fx 'ERROR private database audit failed category=central-marker-count cell=unclassified' <<<"$summary" >/dev/null; then
	printf 'release summary retained an unallowlisted private database audit cell\n' >&2
	exit 1
fi
if grep -Eq 'custom-injected|secret-value|raw=|node_enrollment_claimsXendpoint_ciphertext|status-secret|snapshot-extra|backup-restore-verify-failed-snapshot secret=|backup-restore-verify-failed secret=' <<<"$summary"; then
	printf 'release summary retained non-allowlisted private database audit data\n' >&2
	exit 1
fi
i=1
while [ "$i" -le 100 ]; do
	printf 'ERROR private database audit failed category=inputs subcategory=node-one-database-file reason=mode\n' >>"$diagnostic"
	i=$((i + 1))
done
printf 'ERROR private database audit failed category=inputs subcategory=node-one-database-file reason=mode marker=reason-hostile\n' >>"$diagnostic"
reason_summary=$(bash -c '. "$1"; release_image_failure_summary "$2"' _ "$summary_helper" "$diagnostic")
reason_count=$(grep -c '^ERROR private database audit failed category=inputs subcategory=node-one-database-file reason=mode$' <<<"$reason_summary" || true)
[ "$reason_count" -eq 80 ] || {
	printf 'release summary reason tail retained %s records, want 80\n' "$reason_count" >&2
	exit 1
}
if grep -Eq 'marker=reason-|reason=mode .* ' <<<"$reason_summary"; then
	printf 'release summary retained an appended or unallowlisted input reason field\n' >&2
	exit 1
fi

printf 'release_image_failure_summary_private_audit_contract=passed\n'
