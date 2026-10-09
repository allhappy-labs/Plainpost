#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compose="$root/Deploy/acceptance/compose.private-transport.yaml"
owner="$root/Scripts/test-sync-node-private-transport.sh"
attachment_release_contract="$root/Scripts/test-sync-node-private-transport-attachment-release-contract.sh"
attachment_release_helper="$root/Scripts/lib/acceptance-attachment-release-probe.sh"
task7_category_contract="$root/Scripts/test-task7-privacy-audit-category-contract.sh"
task7_category_helper="$root/Scripts/lib/task7-privacy-audit-category.sh"
controller_helper="$root/Scripts/lib/acceptance-controller.sh"
process_supervisor="$root/Scripts/lib/acceptance-process-supervisor.py"
fixture_restart_helper="$root/Scripts/lib/acceptance-fixture-restart.sh"
fixture_crash_category_helper="$root/Scripts/lib/acceptance-fixture-crash-category.sh"
certificate_san_helper="$root/Scripts/lib/verify-certificate-dns-san.sh"
provider_transition_helper="$root/Scripts/lib/acceptance-provider-transition.sh"
node_restart_helper="$root/Scripts/lib/acceptance-node-restart.sh"
node_two_schema_checkpoint_helper="$root/Scripts/lib/acceptance-node-two-schema-checkpoint.sh"
wrapper="$root/Scripts/lib/postgres-tls-entrypoint.sh"
swift_scenario="$root/Tests/PlainpostAccountRuntimeTests/NodeMailAuthorityLiveScenario.swift"
swift_live="$root/Tests/PlainpostAccountRuntimeTests/SyncNodePrivateTransportLiveTests.swift"
swift_client="$root/Sources/PlainpostNodeTransport/NodeSyncClient.swift"
swift_models="$root/Sources/PlainpostNodeTransport/NodeSyncModels.swift"
acceptance_seed_main="$root/Services/PlainpostGo/cmd/plainpost-sync-node-acceptance-seed/main.go"
mail_fixture="$root/Scripts/lib/plainpost_acceptance_mail_fixture.py"
authority_source="$root/Sources/PlainpostAccountRuntime/PlainpostNodeMailAuthority.swift"
authority_tests="$root/Tests/PlainpostAccountRuntimeTests/PlainpostNodeMailAuthorityTests.swift"
release_override_writer="$root/Scripts/lib/write-release-private-transport-override.sh"
attachment_storage_contract="$root/Scripts/test-sync-node-client-api-attachment-storage-contract.sh"
backup_restore_contract="$root/Scripts/test-sync-node-private-transport-backup-restore-contract.sh"

# Exercise the controller helper's real child lifecycle. A stubborn child
# must be terminated with TERM/KILL and reaped, publishing only one private
# failed signal; a successful child publishes only one mode-0600 applied
# signal. Source-token checks below remain limited to owner wiring.
. "$controller_helper"
test -x "$controller_helper"
test -x "$fixture_restart_helper"
test -x "$fixture_crash_category_helper"
test -x "$certificate_san_helper"
test -x "$provider_transition_helper"
test -x "$node_two_schema_checkpoint_helper"
node_two_schema_checkpoint_phases=$(grep -E '^[[:space:]]*(if )?node_two_schema_checkpoint [a-z-]+' "$owner" | sed -E 's/.*node_two_schema_checkpoint ([a-z-]+).*/\1/' | sort -u)
[ -n "$node_two_schema_checkpoint_phases" ]
for node_two_schema_checkpoint_phase in $node_two_schema_checkpoint_phases; do
  NODE_TWO_SCHEMA_CHECKPOINT=1 NODE_TWO_SCHEMA_CHECKPOINT_RELEASE=0 \
    "$node_two_schema_checkpoint_helper" "$node_two_schema_checkpoint_phase"
done
grep -F 'node_database_inspection_role=plainpost_node_bootstrap' "$owner" >/dev/null || {
  printf 'private transport lacks source-mode Node inspection role default\n' >&2
  exit 1
}
grep -F 'node_database_inspection_role=plainpost_sync_node' "$owner" >/dev/null || {
  printf 'release mode lacks runtime Node inspection role\n' >&2
  exit 1
}
bootstrap_node_database_query_count=$(grep -Fc -- 'psql -U plainpost_node_bootstrap -d "$node_one_database_name"' "$owner" || true)
[ "$bootstrap_node_database_query_count" -eq 1 ] || {
  printf 'private transport uses bootstrap for direct Node database inspection (%s call sites)\n' "$bootstrap_node_database_query_count" >&2
  exit 1
}
grep -F 'schema_privileges=$(docker exec "$database_container" psql -U plainpost_node_bootstrap -d "$node_one_database_name"' "$owner" >/dev/null || {
  printf 'private transport lost the bootstrap-authenticated schema privilege assertion\n' >&2
  exit 1
}
central_connect_revoke_line=$(grep -n -m1 -F "REVOKE ALL ON DATABASE plainpost_central FROM PUBLIC" "$owner" | cut -d: -f1)
central_connect_grant_line=$(grep -n -m1 -F "GRANT CONNECT ON DATABASE plainpost_central TO plainpost_central" "$owner" | cut -d: -f1)
[ -n "$central_connect_revoke_line" ] && [ -n "$central_connect_grant_line" ] &&
  [ "$central_connect_revoke_line" -lt "$central_connect_grant_line" ] || {
  printf 'release Central init must revoke PUBLIC database access before scoped CONNECT grant\n' >&2
  exit 1
}

# LibreSSL (including the Xcode toolchain) does not implement the OpenSSL
# `x509 -ext` option.  Exercise the portable verifier against a real cert and
# ensure a similarly-prefixed hostname cannot satisfy the exact SAN check.
if grep -F -- '-noout -ext subjectAltName' "$owner" >/dev/null; then
  printf 'private transport still uses the non-portable x509 -ext SAN check\n' >&2
  exit 1
fi
grep -F 'verify_certificate_dns_san' "$owner" >/dev/null
# Go's x509 parser (used by the MinIO fixture) rejects explicit EC parameter
# blocks.  Every private-transport EC key must therefore use the portable
# named-curve encoding, while retaining P-256 and the existing SAN checks.
private_ec_generations=$(grep -c -- '-newkey ec' "$owner")
private_named_curve_generations=$(grep -c -- 'ec_param_enc:named_curve' "$owner")
if [ "$private_ec_generations" -eq 0 ] || [ "$private_ec_generations" -ne "$private_named_curve_generations" ]; then
  printf 'private transport EC certificates must use named-curve parameters\n' >&2
  exit 1
fi
private_ca_signature_generations=$(grep -c -- 'openssl req -x509 -sha256' "$owner")
private_leaf_signature_generations=$(grep -c -- 'openssl x509 -req -sha256' "$owner")
if [ "$private_ca_signature_generations" -ne 2 ] || [ "$private_leaf_signature_generations" -ne 2 ]; then
  printf 'private transport CA and leaf certificate signing must use SHA-256\n' >&2
  exit 1
fi
certificate_san_contract_root=$(mktemp -d "/tmp/plainpost-certificate-san-contract.XXXXXX")
certificate_san_contract_key="$certificate_san_contract_root/ca.key"
certificate_san_contract_crt="$certificate_san_contract_root/ca.crt"
certificate_san_contract_server_key="$certificate_san_contract_root/server.key"
certificate_san_contract_csr="$certificate_san_contract_root/server.csr"
certificate_san_contract_server_crt="$certificate_san_contract_root/server.crt"
certificate_san_contract_extensions="$certificate_san_contract_root/extensions"
cleanup_certificate_san_contract() {
  find "$certificate_san_contract_root" -depth -delete >/dev/null 2>&1 || true
}
trap cleanup_certificate_san_contract EXIT HUP INT TERM
openssl req -x509 -sha256 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
  -subj '/CN=Plainpost SAN contract CA' -keyout "$certificate_san_contract_key" \
  -out "$certificate_san_contract_crt" >/dev/null 2>&1
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -subj '/CN=node-one.private-beta.ts.net' -keyout "$certificate_san_contract_server_key" \
  -out "$certificate_san_contract_csr" >/dev/null 2>&1
printf '%s\n' \
  'subjectAltName=DNS:node-one.private-beta.ts.net,DNS:node-one.private-beta.ts.net.evil.example' \
  'extendedKeyUsage=serverAuth' >"$certificate_san_contract_extensions"
openssl x509 -req -sha256 -days 1 -in "$certificate_san_contract_csr" \
  -CA "$certificate_san_contract_crt" -CAkey "$certificate_san_contract_key" \
  -CAcreateserial -extfile "$certificate_san_contract_extensions" \
  -out "$certificate_san_contract_server_crt" >/dev/null 2>&1
certificate_san_signature_algorithm() {
  openssl x509 -in "$1" -noout -text |
    awk '/Signature Algorithm:/{print; exit}' |
    grep -Eiq 'sha-?256'
}
if ! certificate_san_signature_algorithm "$certificate_san_contract_crt" ||
   ! certificate_san_signature_algorithm "$certificate_san_contract_server_crt"; then
  printf 'private transport certificates must use SHA-256 signatures\n' >&2
  exit 1
fi
"$certificate_san_helper" "$certificate_san_contract_server_crt" \
  node-one.private-beta.ts.net
if "$certificate_san_helper" "$certificate_san_contract_server_crt" \
  node-one.private-beta.ts.net.evil; then
  printf 'certificate SAN verifier accepted a non-exact hostname\n' >&2
  exit 1
fi
cleanup_certificate_san_contract
trap - EXIT HUP INT TERM
test -x "$node_restart_helper"
# Process-group signals must use the external utility.  The macOS /bin/sh and
# Bash builtins accept the same-looking syntax differently in nested harnesses;
# the controller must therefore make group targeting explicit and portable.
grep -F '/bin/kill -TERM -- "-$controller_child_pgid"' "$controller_helper" >/dev/null
grep -F '/bin/kill -KILL -- "-$controller_child_pgid"' "$controller_helper" >/dev/null
grep -F '/bin/kill -0 -- "-$controller_child_pgid"' "$controller_helper" >/dev/null
grep -F 'case "$controller_child_pgid" in' "$controller_helper" >/dev/null
grep -F 'case "$controller_harness_pgid" in' "$controller_helper" >/dev/null

# Execute the node restart helper with fake Docker/curl binaries so the
# contract proves the complete private environment reaches Compose together
# with the explicit bounded restart timeout. This catches accidental comments
# inside the backslash-continued environment assignment block.
node_restart_contract_root=$(mktemp -d "/tmp/plainpost-node-restart-helper-contract.XXXXXX")
cleanup_node_restart_contract() {
	find "$node_restart_contract_root" -depth -delete >/dev/null 2>&1 || true
}
abort_node_restart_contract() {
	cleanup_node_restart_contract
	trap - EXIT HUP INT TERM
	exit 130
}
trap cleanup_node_restart_contract EXIT
trap abort_node_restart_contract HUP INT TERM
mkdir -m 0700 "$node_restart_contract_root/bin"
node_restart_capture="$node_restart_contract_root/docker.capture"
node_restart_curl_capture="$node_restart_contract_root/curl.capture"
cat >"$node_restart_contract_root/bin/docker" <<'SH'
#!/bin/sh
{
  printf 'PLAINPOST_PRIVATE_ROOT=%s\n' "$PLAINPOST_PRIVATE_ROOT"
  printf 'PLAINPOST_PRIVATE_NODE_IMAGE=%s\n' "$PLAINPOST_PRIVATE_NODE_IMAGE"
  printf 'PLAINPOST_ACCEPTANCE_NODE_UID=%s\n' "$PLAINPOST_ACCEPTANCE_NODE_UID"
  printf 'PLAINPOST_ACCEPTANCE_NODE_GID=%s\n' "$PLAINPOST_ACCEPTANCE_NODE_GID"
  printf 'PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE=%s\n' "$PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE"
  printf 'PLAINPOST_ACCEPTANCE_ATTACHMENT_DIR=%s\n' "$PLAINPOST_ACCEPTANCE_ATTACHMENT_DIR"
  printf 'PLAINPOST_ACCEPTANCE_DROP_RESPONSES=%s\n' "$PLAINPOST_ACCEPTANCE_DROP_RESPONSES"
  printf 'PLAINPOST_ACCEPTANCE_S3_ENDPOINT=%s\n' "$PLAINPOST_ACCEPTANCE_S3_ENDPOINT"
  printf 'PLAINPOST_ACCEPTANCE_S3_BUCKET=%s\n' "$PLAINPOST_ACCEPTANCE_S3_BUCKET"
  printf 'PLAINPOST_ACCEPTANCE_S3_REGION=%s\n' "$PLAINPOST_ACCEPTANCE_S3_REGION"
  printf 'PLAINPOST_ACCEPTANCE_S3_ADDRESSING=%s\n' "$PLAINPOST_ACCEPTANCE_S3_ADDRESSING"
  printf 'PLAINPOST_ACCEPTANCE_S3_ACCESS_KEY_FILE=%s\n' "$PLAINPOST_ACCEPTANCE_S3_ACCESS_KEY_FILE"
  printf 'PLAINPOST_ACCEPTANCE_S3_SECRET_KEY_FILE=%s\n' "$PLAINPOST_ACCEPTANCE_S3_SECRET_KEY_FILE"
  printf 'argv=%s\n' "$*"
} >"$NODE_RESTART_CAPTURE"
exit 0
SH
cat >"$node_restart_contract_root/bin/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >"$NODE_RESTART_CURL_CAPTURE"
exit 0
SH
chmod 0700 "$node_restart_contract_root/bin/docker" "$node_restart_contract_root/bin/curl"
node_restart_status=0
PATH="$node_restart_contract_root/bin:$PATH" NODE_RESTART_CAPTURE="$node_restart_capture" NODE_RESTART_CURL_CAPTURE="$node_restart_curl_capture" \
  "$node_restart_helper" \
  /tmp/plainpost-compose.yaml contract-project "$node_restart_contract_root" node-two node-image \
  1000 1000 s3 /node-attachments drop-phase https://s3.invalid bucket region path-style \
  /run/secrets/s3_access /run/secrets/s3_secret node-two.private-beta.ts.net 28443 || node_restart_status=$?
[ "$node_restart_status" -eq 0 ]
test -f "$node_restart_curl_capture"
grep -F 'https://node-two.private-beta.ts.net:18443/readyz' "$node_restart_curl_capture" >/dev/null
grep -F 'PLAINPOST_PRIVATE_ROOT=/tmp/plainpost-node-restart-helper-contract.' "$node_restart_capture" >/dev/null
grep -F 'PLAINPOST_PRIVATE_NODE_IMAGE=node-image' "$node_restart_capture" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_NODE_UID=1000' "$node_restart_capture" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_NODE_GID=1000' "$node_restart_capture" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE=s3' "$node_restart_capture" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_ATTACHMENT_DIR=/node-attachments' "$node_restart_capture" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_DROP_RESPONSES=drop-phase' "$node_restart_capture" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_S3_ENDPOINT=https://s3.invalid' "$node_restart_capture" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_S3_BUCKET=bucket' "$node_restart_capture" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_S3_REGION=region' "$node_restart_capture" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_S3_ADDRESSING=path-style' "$node_restart_capture" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_S3_ACCESS_KEY_FILE=/run/secrets/s3_access' "$node_restart_capture" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_S3_SECRET_KEY_FILE=/run/secrets/s3_secret' "$node_restart_capture" >/dev/null
grep -F 'argv=compose -p contract-project -f /tmp/plainpost-compose.yaml restart --timeout 10 node-two' "$node_restart_capture" >/dev/null
rm -f "$node_restart_curl_capture"
node_restart_status=0
PATH="$node_restart_contract_root/bin:$PATH" NODE_RESTART_CAPTURE="$node_restart_capture" NODE_RESTART_CURL_CAPTURE="$node_restart_curl_capture" \
  "$node_restart_helper" \
  /tmp/plainpost-compose.yaml contract-project "$node_restart_contract_root" node-two node-image \
  1000 1000 s3 /node-attachments drop-phase https://s3.invalid bucket region path-style \
  /run/secrets/s3_access /run/secrets/s3_secret node-two.private-beta.ts.net 28443 presentation || node_restart_status=$?
[ "$node_restart_status" -eq 0 ]
test ! -e "$node_restart_curl_capture"
node_restart_status=0
PATH="$node_restart_contract_root/bin:$PATH" NODE_RESTART_CAPTURE="$node_restart_capture" NODE_RESTART_CURL_CAPTURE="$node_restart_curl_capture" \
  "$node_restart_helper" \
  /tmp/plainpost-compose.yaml contract-project "$node_restart_contract_root" node-two node-image \
  1000 1000 s3 /node-attachments drop-phase https://s3.invalid bucket region path-style \
  /run/secrets/s3_access /run/secrets/s3_secret node-two.private-beta.ts.net 28443 health || node_restart_status=$?
[ "$node_restart_status" -eq 0 ]
test -f "$node_restart_curl_capture"
grep -F 'https://node-two.private-beta.ts.net:18443/healthz' "$node_restart_curl_capture" >/dev/null
rm -f "$node_restart_curl_capture"
node_restart_status=0
PATH="$node_restart_contract_root/bin:$PATH" NODE_RESTART_CAPTURE="$node_restart_capture" NODE_RESTART_CURL_CAPTURE="$node_restart_curl_capture" \
  "$node_restart_helper" \
  /tmp/plainpost-compose.yaml contract-project "$node_restart_contract_root" node-two node-image \
  1000 1000 s3 /node-attachments drop-phase https://s3.invalid bucket region path-style \
  /run/secrets/s3_access /run/secrets/s3_secret node-two.private-beta.ts.net 28443 unknown || node_restart_status=$?
[ "$node_restart_status" -eq 2 ]
test ! -e "$node_restart_curl_capture"
cleanup_node_restart_contract
[ ! -e "$node_restart_contract_root" ]
trap - EXIT HUP INT TERM

# Mutation-mode restarts must release the paused IMAP phase between stopping
# and starting node-one. Exercise the helper with fake Docker/curl binaries so
# the contract proves the exact ordering, readiness probe, and complete private
# Compose environment without booting Docker. The normal-mode contract above
# separately proves the default restart command remains unchanged.
node_mutation_contract_root=$(mktemp -d "/tmp/plainpost-node-mutation-helper-contract.XXXXXX")
cleanup_node_mutation_contract() {
	find "$node_mutation_contract_root" -depth -delete >/dev/null 2>&1 || true
}
abort_node_mutation_contract() {
	cleanup_node_mutation_contract
	trap - EXIT HUP INT TERM
	exit 130
}
trap cleanup_node_mutation_contract EXIT
trap abort_node_mutation_contract HUP INT TERM
mkdir -m 0700 "$node_mutation_contract_root/bin"
node_mutation_capture="$node_mutation_contract_root/docker.capture"
cat >"$node_mutation_contract_root/bin/docker" <<'SH'
#!/bin/sh
{
  printf 'docker:%s\n' "$*"
  printf 'env:PLAINPOST_PRIVATE_ROOT=%s\n' "$PLAINPOST_PRIVATE_ROOT"
  printf 'env:PLAINPOST_PRIVATE_NODE_IMAGE=%s\n' "$PLAINPOST_PRIVATE_NODE_IMAGE"
  printf 'env:PLAINPOST_ACCEPTANCE_NODE_UID=%s\n' "$PLAINPOST_ACCEPTANCE_NODE_UID"
  printf 'env:PLAINPOST_ACCEPTANCE_NODE_GID=%s\n' "$PLAINPOST_ACCEPTANCE_NODE_GID"
  printf 'env:PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE=%s\n' "$PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE"
  printf 'env:PLAINPOST_ACCEPTANCE_ATTACHMENT_DIR=%s\n' "$PLAINPOST_ACCEPTANCE_ATTACHMENT_DIR"
  printf 'env:PLAINPOST_ACCEPTANCE_DROP_RESPONSES=%s\n' "$PLAINPOST_ACCEPTANCE_DROP_RESPONSES"
  printf 'env:PLAINPOST_ACCEPTANCE_S3_ENDPOINT=%s\n' "$PLAINPOST_ACCEPTANCE_S3_ENDPOINT"
  printf 'env:PLAINPOST_ACCEPTANCE_S3_BUCKET=%s\n' "$PLAINPOST_ACCEPTANCE_S3_BUCKET"
  printf 'env:PLAINPOST_ACCEPTANCE_S3_REGION=%s\n' "$PLAINPOST_ACCEPTANCE_S3_REGION"
  printf 'env:PLAINPOST_ACCEPTANCE_S3_ADDRESSING=%s\n' "$PLAINPOST_ACCEPTANCE_S3_ADDRESSING"
  printf 'env:PLAINPOST_ACCEPTANCE_S3_ACCESS_KEY_FILE=%s\n' "$PLAINPOST_ACCEPTANCE_S3_ACCESS_KEY_FILE"
  printf 'env:PLAINPOST_ACCEPTANCE_S3_SECRET_KEY_FILE=%s\n' "$PLAINPOST_ACCEPTANCE_S3_SECRET_KEY_FILE"
} >>"$NODE_MUTATION_CAPTURE"
exit 0
SH
cat >"$node_mutation_contract_root/bin/curl" <<'SH'
#!/bin/sh
printf 'curl:%s\n' "$*" >>"$NODE_MUTATION_CAPTURE"
exit 0
SH
chmod 0700 "$node_mutation_contract_root/bin/docker" "$node_mutation_contract_root/bin/curl"
node_mutation_status=0
PATH="$node_mutation_contract_root/bin:$PATH" NODE_MUTATION_CAPTURE="$node_mutation_capture" \
  "$node_restart_helper" \
  /tmp/plainpost-compose.yaml mutation-project "$node_mutation_contract_root" node-one node-image \
  1000 1000 s3 /node-attachments drop-phase https://s3.invalid bucket region path-style \
  /run/secrets/s3_access /run/secrets/s3_secret node-one.private-beta.ts.net 28443 mutation || node_mutation_status=$?
[ "$node_mutation_status" -eq 0 ]
node_mutation_events=$(grep -E '^(docker|curl):' "$node_mutation_capture" | sed -E 's/^curl:.*/curl:healthz/')
node_mutation_expected=$(cat <<'EOF'
docker:compose -p mutation-project -f /tmp/plainpost-compose.yaml stop --timeout 10 node-one
docker:compose -p mutation-project -f /tmp/plainpost-compose.yaml exec -T imap-fixture python3 /opt/plainpost/plainpost_acceptance_mail_control.py --root /var/lib/plainpost phase imap mutation 1 disconnect
docker:compose -p mutation-project -f /tmp/plainpost-compose.yaml exec -T imap-fixture python3 /opt/plainpost/plainpost_acceptance_mail_control.py --root /var/lib/plainpost wait-phase-release imap mutation 1 --timeout-ms 30000
docker:compose -p mutation-project -f /tmp/plainpost-compose.yaml start node-one
curl:healthz
EOF
)
[ "$node_mutation_events" = "$node_mutation_expected" ] || {
	printf 'mutation restart order=%s\n' "$node_mutation_events" >&2
	exit 1
}
if grep -F ' restart ' "$node_mutation_capture" >/dev/null; then
	printf 'mutation restart unexpectedly invoked Compose restart\n' >&2
	exit 1
fi
for node_mutation_env in \
  'PLAINPOST_PRIVATE_ROOT=' \
  'PLAINPOST_PRIVATE_NODE_IMAGE=node-image' \
  'PLAINPOST_ACCEPTANCE_NODE_UID=1000' \
  'PLAINPOST_ACCEPTANCE_NODE_GID=1000' \
  'PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE=s3' \
  'PLAINPOST_ACCEPTANCE_ATTACHMENT_DIR=/node-attachments' \
  'PLAINPOST_ACCEPTANCE_DROP_RESPONSES=drop-phase' \
  'PLAINPOST_ACCEPTANCE_S3_ENDPOINT=https://s3.invalid' \
  'PLAINPOST_ACCEPTANCE_S3_BUCKET=bucket' \
  'PLAINPOST_ACCEPTANCE_S3_REGION=region' \
  'PLAINPOST_ACCEPTANCE_S3_ADDRESSING=path-style' \
  'PLAINPOST_ACCEPTANCE_S3_ACCESS_KEY_FILE=/run/secrets/s3_access' \
  'PLAINPOST_ACCEPTANCE_S3_SECRET_KEY_FILE=/run/secrets/s3_secret'; do
  node_mutation_env_count=$(grep -F -c "env:$node_mutation_env" "$node_mutation_capture" || true)
	  [ "$node_mutation_env_count" -eq 4 ] || {
	  printf 'mutation environment %s reached %s Docker calls, want 4\n' "$node_mutation_env" "$node_mutation_env_count" >&2
	  exit 1
  }
done
grep -F "env:PLAINPOST_PRIVATE_ROOT=$node_mutation_contract_root" "$node_mutation_capture" >/dev/null
cleanup_node_mutation_contract
[ ! -e "$node_mutation_contract_root" ]
trap - EXIT HUP INT TERM

controller_contract_root=$(mktemp -d "${TMPDIR:-/tmp}/plainpost-controller-contract.XXXXXX")
mkdir -m 0700 "$controller_contract_root/control"
stalled_child_pid_file="$controller_contract_root/stalled-child.pid"
if acceptance_controller_run "$controller_contract_root/control" stalled 1 sh -c 'trap "" TERM; sleep 30 & child=$!; printf "%s\n" "$child" >"$1"; wait "$child"' sh "$stalled_child_pid_file" >"$controller_contract_root/stalled.log" 2>&1; then
  printf 'stalled controller child unexpectedly succeeded\n' >&2
  exit 1
fi
test -f "$controller_contract_root/control/stalled.failed"
test ! -e "$controller_contract_root/control/stalled.applied"
[ "$(stat -f '%Lp' "$controller_contract_root/control/stalled.failed" 2>/dev/null || stat -c '%a' "$controller_contract_root/control/stalled.failed")" = 600 ]
[ "$(find "$controller_contract_root/control" -maxdepth 1 -type f -name 'stalled.*' | wc -l | tr -d '[:space:]')" = 1 ]
stalled_child_pid=$(tr -d '[:space:]' <"$stalled_child_pid_file")
if kill -0 "$stalled_child_pid" 2>/dev/null; then
  printf 'stalled controller descendant survived group termination\n' >&2
  exit 1
fi
mkdir -m 0700 "$controller_contract_root/timeout-orphan"
timeout_orphan_child_pid_file="$controller_contract_root/timeout-orphan/child.pid"
timeout_orphan_status=0
acceptance_controller_run "$controller_contract_root/timeout-orphan" restart-node 1 \
  sh -c 'trap "exit 0" TERM; (trap "" TERM; sleep 30) & child=$!; printf "%s\\n" "$child" >"$1"; wait "$child"' \
  sh "$timeout_orphan_child_pid_file" >"$controller_contract_root/timeout-orphan.log" 2>&1 || timeout_orphan_status=$?
test "$timeout_orphan_status" -ne 0
timeout_orphan_child_pid=$(tr -d '[:space:]' <"$timeout_orphan_child_pid_file")
if kill -0 "$timeout_orphan_child_pid" 2>/dev/null; then
  printf 'timeout controller descendant survived TERM/KILL and reap\n' >&2
  kill -KILL "$timeout_orphan_child_pid" 2>/dev/null || true
  exit 1
fi
test -f "$controller_contract_root/timeout-orphan/restart-node.failed"
test ! -e "$controller_contract_root/timeout-orphan/restart-node.applied"
mkdir -m 0700 "$controller_contract_root/success"
acceptance_controller_run "$controller_contract_root/success" success 2 sh -c 'exit 0' >"$controller_contract_root/success.log" 2>&1
test -f "$controller_contract_root/success/success.applied"
test ! -e "$controller_contract_root/success/success.failed"
[ "$(stat -f '%Lp' "$controller_contract_root/success/success.applied" 2>/dev/null || stat -c '%a' "$controller_contract_root/success/success.applied")" = 600 ]
[ "$(find "$controller_contract_root/success" -maxdepth 1 -type f -name 'success.*' | wc -l | tr -d '[:space:]')" = 1 ]
grep -F 'controller-child-timeout action=stalled' "$controller_contract_root/stalled.log" >/dev/null
grep -F 'controller-child-reaped action=stalled' "$controller_contract_root/stalled.log" >/dev/null
grep -F 'controller-child-reaped action=success status=0' "$controller_contract_root/success.log" >/dev/null

# Exercise the node-two presentation failure selector against a noisy,
# privacy-filtered runtime log. The production selector must retain exactly
# its bounded tail and terminal failure class, while excluding a planted
# sensitive marker.
node_two_summary_contract_root=$(mktemp -d "/tmp/plainpost-node-two-summary-contract.XXXXXX")
node_two_summary_patterns="$node_two_summary_contract_root/patterns"
node_two_summary_log="$node_two_summary_contract_root/runtime.log"
node_two_summary_output="$node_two_summary_contract_root/output.log"
node_two_summary_secret='plainpost-node-two-private-secret-20260831'
printf '%s\n' "$node_two_summary_secret" >"$node_two_summary_patterns"
for summary_index in $(seq 1 60); do
  printf 'ERROR controller-child-reaped action=node-two-presentation-probe-%s status=0\n' "$summary_index" >>"$node_two_summary_log"
done
printf 'ERROR controller-child-reaped action=node-two-presentation-probe-secret detail=%s\n' "$node_two_summary_secret" >>"$node_two_summary_log"
printf 'ERROR controller-child-timeout action=node-two-presentation-restart timeout_seconds=10\n' >>"$node_two_summary_log"
printf 'ERROR acceptance-node-two-presentation outcome=failed restart_status=1 command_status=124 attempts=0 elapsed_seconds=10 timeout_seconds=46\n' >>"$node_two_summary_log"
printf 'ERROR node-two-presentation unavailable\n' >>"$node_two_summary_log"
if PLAINPOST_SYNC_NODE_NODE_TWO_PRESENTATION_SUMMARY_TEST=enabled \
  PLAINPOST_SYNC_NODE_NODE_TWO_PRESENTATION_SUMMARY_LOG="$node_two_summary_log" \
  PLAINPOST_SYNC_NODE_NODE_TWO_PRESENTATION_SUMMARY_PATTERNS="$node_two_summary_patterns" \
  "$owner" >"$node_two_summary_output" 2>&1; then
  :
else
  printf 'node-two presentation summary selector contract failed\n' >&2
  exit 1
fi
node_two_summary_body=$(sed -n '/^node_two_presentation_failure_summary_begin$/,/^node_two_presentation_failure_summary_end$/p' "$node_two_summary_output")
printf '%s\n' "$node_two_summary_body" | grep -F 'ERROR controller-child-timeout action=node-two-presentation-restart' >/dev/null
printf '%s\n' "$node_two_summary_body" | grep -F 'ERROR acceptance-node-two-presentation outcome=failed' >/dev/null
printf '%s\n' "$node_two_summary_body" | grep -F 'ERROR node-two-presentation unavailable' >/dev/null
if printf '%s\n' "$node_two_summary_body" | grep -F "$node_two_summary_secret" >/dev/null; then
  printf 'node-two presentation summary leaked a sensitive marker\n' >&2
  exit 1
fi
node_two_summary_records=$(printf '%s\n' "$node_two_summary_body" | grep -c 'action=node-two-presentation-probe-' || true)
[ "$node_two_summary_records" -eq 37 ] || {
	printf 'node-two presentation summary retained %s records, want 37\n' "$node_two_summary_records" >&2
	exit 1
}
printf '%s\n' "$node_two_summary_body" | grep -F 'action=node-two-presentation-probe-24 status=0' >/dev/null
if printf '%s\n' "$node_two_summary_body" | grep -F 'action=node-two-presentation-probe-23 status=0' >/dev/null; then
  printf 'node-two presentation summary exceeded its exact 40-record tail\n' >&2
  exit 1
fi
find "$node_two_summary_contract_root" -depth -delete

# Attachment hydration/open diagnostics are fixed-field, failure-only records.
# Exercise the owner's bounded summary through a private synthetic log so the
# contract proves the allowlist, tail bound, and privacy filter without booting
# the full acceptance stack.
attachment_summary_contract_root=$(mktemp -d "/tmp/plainpost-attachment-summary-contract.XXXXXX")
attachment_summary_patterns="$attachment_summary_contract_root/patterns"
attachment_summary_log="$attachment_summary_contract_root/runtime.log"
attachment_summary_output="$attachment_summary_contract_root/output.log"
attachment_summary_secret='plainpost-attachment-private-secret-20260831'
printf '%s\n' "$attachment_summary_secret" >"$attachment_summary_patterns"
for attachment_summary_index in $(seq 1 90); do
  printf 'time=0 level=DEBUG msg=[DEBUG-sync-node-attachment] category=hydrate stage=provider-fetch outcome=failed ok=false count_class=one error_class=unavailable\n' >>"$attachment_summary_log"
done
printf 'time=0 level=DEBUG msg=[DEBUG-sync-node-attachment] category=hydrate stage=provider-fetch outcome=failed ok=false count_class=one error_class=unknown detail=%s\n' "$attachment_summary_secret" >>"$attachment_summary_log"
printf '%s\n' '{"time":"0","level":"ERROR","msg":"[DEBUG-sync-node-attachment]","category":"open","stage":"capability-hydrate-handoff","outcome":"failed","ok":false,"count_class":"one","error_class":"unavailable"}' >>"$attachment_summary_log"
printf '%s\n' '{"time":"0","level":"ERROR","msg":"[DEBUG-sync-node-attachment]","category":"open","stage":"open","outcome":"failed","ok":false,"count_class":"one","error_class":"conflict"}' >>"$attachment_summary_log"
if PLAINPOST_SYNC_NODE_ATTACHMENT_DIAGNOSTIC_SUMMARY_TEST=enabled \
  PLAINPOST_SYNC_NODE_ATTACHMENT_DIAGNOSTIC_SUMMARY_LOG="$attachment_summary_log" \
  PLAINPOST_SYNC_NODE_ATTACHMENT_DIAGNOSTIC_SUMMARY_PATTERNS="$attachment_summary_patterns" \
  "$owner" >"$attachment_summary_output" 2>&1; then
  :
else
  printf 'attachment diagnostic summary selector contract failed\n' >&2
  exit 1
fi
attachment_summary_body=$(sed -n '/^attachment_diagnostic_summary_begin$/,/^attachment_diagnostic_summary_end$/p' "$attachment_summary_output")
printf '%s\n' "$attachment_summary_body" | grep -F 'capability-hydrate-handoff' >/dev/null
printf '%s\n' "$attachment_summary_body" | grep -F 'category=hydrate stage=provider-fetch outcome=failed ok=false count_class=one error_class=unavailable' >/dev/null
printf '%s\n' "$attachment_summary_body" | grep -E 'category(=|":")open.*stage(=|":")open.*outcome(=|":")failed.*ok(=|":)(false).*count_class(=|":")one.*error_class(=|":")conflict' >/dev/null
if printf '%s\n' "$attachment_summary_body" | grep -F "$attachment_summary_secret" >/dev/null; then
  printf 'attachment diagnostic summary leaked a sensitive marker\n' >&2
  exit 1
fi
attachment_summary_records=$(printf '%s\n' "$attachment_summary_body" | grep -E -c 'msg(=|":")\[DEBUG-sync-node-attachment\]' || true)
[ "$attachment_summary_records" -eq 80 ] || {
  printf 'attachment diagnostic summary retained %s records, want 80\n' "$attachment_summary_records" >&2
  exit 1
}
find "$attachment_summary_contract_root" -depth -delete

# Attachment HTTP stream diagnostics retain only fixed route/phase/outcome and
# error classes. Exercise the owner's bounded summary without booting Compose;
# raw reader detail and identifier-like fields must be excluded.
attachment_stream_summary_contract_root=$(mktemp -d "/tmp/plainpost-attachment-stream-summary-contract.XXXXXX")
attachment_stream_summary_patterns="$attachment_stream_summary_contract_root/patterns"
attachment_stream_summary_log="$attachment_stream_summary_contract_root/runtime.log"
attachment_stream_summary_output="$attachment_stream_summary_contract_root/output.log"
attachment_stream_summary_secret='plainpost-attachment-stream-private-secret-20260831'
printf '%s\n' "$attachment_stream_summary_secret" >"$attachment_stream_summary_patterns"
for attachment_stream_summary_index in $(seq 1 90); do
  printf 'time=0 level=DEBUG msg=[DEBUG-sync-node-attachment] category=stream route=attachment phase=copy outcome=completed error_class=none\n' >>"$attachment_stream_summary_log"
done
printf 'time=0 level=ERROR msg=[DEBUG-sync-node-attachment] category=stream route=attachment phase=copy outcome=failed error_class=stream detail=%s\n' "$attachment_stream_summary_secret" >>"$attachment_stream_summary_log"
printf 'time=0 level=ERROR msg=[DEBUG-sync-node-attachment] category=stream route=attachment phase=trailing-probe outcome=failed error_class=trailing-data\n' >>"$attachment_stream_summary_log"
if PLAINPOST_SYNC_NODE_ATTACHMENT_STREAM_SUMMARY_TEST=enabled \
  PLAINPOST_SYNC_NODE_ATTACHMENT_STREAM_SUMMARY_LOG="$attachment_stream_summary_log" \
  PLAINPOST_SYNC_NODE_ATTACHMENT_STREAM_SUMMARY_PATTERNS="$attachment_stream_summary_patterns" \
  "$owner" >"$attachment_stream_summary_output" 2>&1; then
  :
else
  printf 'attachment stream summary selector contract failed\n' >&2
  exit 1
fi
attachment_stream_summary_body=$(sed -n '/^attachment_stream_summary_begin$/,/^attachment_stream_summary_end$/p' "$attachment_stream_summary_output")
printf '%s\n' "$attachment_stream_summary_body" | grep -F 'category=stream route=attachment phase=copy outcome=completed error_class=none' >/dev/null
printf '%s\n' "$attachment_stream_summary_body" | grep -F 'phase=trailing-probe outcome=failed error_class=trailing-data' >/dev/null
if printf '%s\n' "$attachment_stream_summary_body" | grep -F "$attachment_stream_summary_secret" >/dev/null ||
   printf '%s\n' "$attachment_stream_summary_body" | grep -E 'detail=|attachment_id=|size=|path=' >/dev/null; then
  printf 'attachment stream summary leaked non-fixed stream data\n' >&2
  exit 1
fi
attachment_stream_summary_records=$(printf '%s\n' "$attachment_stream_summary_body" | grep -c 'category=stream route=attachment' || true)
[ "$attachment_stream_summary_records" -eq 80 ] || {
  printf 'attachment stream summary retained %s records, want 80\n' "$attachment_stream_summary_records" >&2
  exit 1
}
find "$attachment_stream_summary_contract_root" -depth -delete

# Crash evidence is classified from a private mode-0600 Docker log without
# retaining raw output. Every source phrase maps to one fixed allowlisted
# category and unknown/noisy data falls back safely.
fixture_crash_contract_root=$(mktemp -d "/tmp/plainpost-fixture-crash-contract.XXXXXX")
. "$fixture_crash_category_helper"
for fixture_crash_case in \
  'sqlite-busy-locked|database is locked' \
  'sqlite-busy-locked|sqlite3 busy' \
  'sqlite-schema|sqlite schema malformed' \
  'sqlite-schema|no such table: messages' \
  'bind-address|OSError: [Errno 98] Address already in use' \
  'bind-address|bind: cannot assign requested address' \
  'signal|terminated by signal 9' \
  'signal|Killed' \
  'python-exception|Traceback (most recent call last):' \
  'python-runtime-error|RuntimeError: fixture failed' \
  'python-value-error|ValueError: fixture failed' \
  'python-os-error|FileNotFoundError: fixture failed' \
  'python-ssl-error|ssl.SSLError: fixture failed' \
  'sqlite-operational|sqlite3.OperationalError: fixture failed'; do
  fixture_crash_expected=${fixture_crash_case%%|*}
  fixture_crash_log="$fixture_crash_contract_root/$fixture_crash_expected.log"
  printf '%s\n' "${fixture_crash_case#*|}" >"$fixture_crash_log"
  chmod 0600 "$fixture_crash_log"
  fixture_crash_actual=$(acceptance_fixture_crash_category "$fixture_crash_log")
  [ "$fixture_crash_actual" = "$fixture_crash_expected" ] || {
    printf 'fixture crash category %s mapped to %s\n' "$fixture_crash_expected" "$fixture_crash_actual" >&2
    exit 1
  }
done
fixture_crash_unknown="$fixture_crash_contract_root/unknown.log"
printf '%s\n' 'secret=private-value /tmp/private/path SQL SELECT' >"$fixture_crash_unknown"
chmod 0600 "$fixture_crash_unknown"
[ "$(acceptance_fixture_crash_category "$fixture_crash_unknown")" = unknown ]
fixture_crash_insecure="$fixture_crash_contract_root/insecure.log"
printf '%s\n' 'database is locked' >"$fixture_crash_insecure"
chmod 0644 "$fixture_crash_insecure"
[ "$(acceptance_fixture_crash_category "$fixture_crash_insecure")" = unknown ]

# The restart helper must retain only fixed crash fields, and the owner must
# select that marker after Compose capture with the existing bounded tail.
grep -F 'acceptance_fixture_crash_category' "$fixture_restart_helper" >/dev/null
grep -F 'event=crash-classification' "$fixture_restart_helper" >/dev/null
grep -F 'exit_code=' "$fixture_restart_helper" >/dev/null
grep -F 'oom=' "$fixture_restart_helper" >/dev/null
grep -F 'cause=' "$fixture_restart_helper" >/dev/null
grep -F 'crash-classification' "$owner" >/dev/null
awk '
  /compose_run logs --no-color --no-log-prefix --tail 1000/ { compose=NR }
  /fixture_restart_failure_summary_begin/ { summary=NR }
  END { exit !(compose > 0 && summary > compose) }
' "$owner"
fixture_crash_record='ERROR acceptance-fixture-restart fixture=smtp-fixture event=crash-classification exit_code=1 oom=false cause=python-runtime-error'
printf '%s\n' "$fixture_crash_record" | grep -E '^ERROR acceptance-fixture-restart fixture=smtp-fixture event=crash-classification exit_code=[0-9]+ oom=(true|false) (cause=(sqlite-busy-locked|sqlite-schema|bind-address|signal|python-runtime-error|python-value-error|python-os-error|python-ssl-error|python-exception|unknown)|cause=sqlite-operational sqlite_subcategory=(locked|open|disk-io|schema|readonly|corrupt|other|none) sqlite_operation=(wal-open|transaction|schema-migration|schema-create|projection-repair|read|other|none))$' >/dev/null
fixture_crash_sqlite_record='ERROR acceptance-fixture-restart fixture=smtp-fixture event=crash-classification exit_code=1 oom=false cause=sqlite-operational sqlite_subcategory=locked sqlite_operation=transaction'
printf '%s\n' "$fixture_crash_sqlite_record" | grep -E '^ERROR acceptance-fixture-restart fixture=smtp-fixture event=crash-classification exit_code=[0-9]+ oom=(true|false) (cause=(sqlite-busy-locked|sqlite-schema|bind-address|signal|python-runtime-error|python-value-error|python-os-error|python-ssl-error|python-exception|unknown)|cause=sqlite-operational sqlite_subcategory=(locked|open|disk-io|schema|readonly|corrupt|other|none) sqlite_operation=(wal-open|transaction|schema-migration|schema-create|projection-repair|read|other|none))$' >/dev/null
if printf '%s\n' "$fixture_crash_record" | grep -E 'private-value|/tmp/|SQL|container' >/dev/null; then
  printf 'fixture crash classification contract retained private data\n' >&2
  exit 1
fi
fixture_crash_summary_log="$fixture_crash_contract_root/runtime.log"
fixture_crash_summary_patterns="$fixture_crash_contract_root/patterns"
printf 'fixture-crash-private-secret\n' >"$fixture_crash_summary_patterns"
for fixture_crash_index in $(seq 1 95); do
  printf '%s index=%s\n' "$fixture_crash_record" "$fixture_crash_index" >>"$fixture_crash_summary_log"
done
printf '%s secret=fixture-crash-private-secret\n' "$fixture_crash_record" >>"$fixture_crash_summary_log"
fixture_crash_summary=$(grep -E '^ERROR acceptance-fixture-restart fixture=smtp-fixture event=crash-classification ' "$fixture_crash_summary_log" | grep -F -v -f "$fixture_crash_summary_patterns" | tail -80)
[ "$(printf '%s\n' "$fixture_crash_summary" | wc -l | tr -d ' ')" -eq 80 ]
printf '%s\n' "$fixture_crash_summary" | grep -F 'index=16' >/dev/null
printf '%s\n' "$fixture_crash_summary" | grep -F 'index=95' >/dev/null
if printf '%s\n' "$fixture_crash_summary" | grep -F 'index=15' >/dev/null || printf '%s\n' "$fixture_crash_summary" | grep -F 'fixture-crash-private-secret' >/dev/null; then
  printf 'fixture crash summary exceeded its exact bounded redacted tail\n' >&2
  exit 1
fi
find "$fixture_crash_contract_root" -depth -delete

# A zero-status process-group leader is not sufficient evidence of success:
# its owned descendant may still be alive after the leader exits.
mkdir -m 0700 "$controller_contract_root/leader-exit"
leader_exit_child_pid_file="$controller_contract_root/leader-exit/child.pid"
leader_exit_status=0
acceptance_controller_run "$controller_contract_root/leader-exit" leader-exit 2 \
  sh -c 'sleep 30 & child=$!; printf "%s\n" "$child" >"$1"; exit 0' sh "$leader_exit_child_pid_file" \
  >"$controller_contract_root/leader-exit.log" 2>&1 || leader_exit_status=$?
test -s "$leader_exit_child_pid_file"
if [ "$leader_exit_status" -eq 0 ]; then
  leader_exit_child_pid=$(tr -d '[:space:]' <"$leader_exit_child_pid_file")
  kill -KILL "$leader_exit_child_pid" 2>/dev/null || true
  printf 'leader-exit controller child unexpectedly published applied\n' >&2
  exit 1
fi
leader_exit_child_pid=$(tr -d '[:space:]' <"$leader_exit_child_pid_file")
if kill -0 "$leader_exit_child_pid" 2>/dev/null; then
  printf 'leader-exit controller descendant survived group termination\n' >&2
  exit 1
fi
test -f "$controller_contract_root/leader-exit/leader-exit.failed"
test ! -e "$controller_contract_root/leader-exit/leader-exit.applied"

# Missing and partial handshakes must fail closed before any arithmetic or
# process-group signal is attempted. The fake launcher keeps the real child
# bounded while controlling only the handshake bytes.
controller_real_python3=$(command -v python3)
cat >"$controller_contract_root/python3" <<'SH'
#!/bin/sh
if [ "$1" = "-c" ] && case "$2" in *"os.setsid()"*) true ;; *) false ;; esac; then
  case "${FAKE_CONTROLLER_HANDSHAKE_MODE:-missing}" in
    missing) ;;
    partial) printf '%s' ':123' >"$CONTROLLER_HANDSHAKE" ;;
    *) printf '%s' 'unsafe' >"$CONTROLLER_HANDSHAKE" ;;
  esac
  shift 2
  exec "$@"
fi
exec "$REAL_CONTROLLER_PYTHON3" "$@"
SH
chmod 0700 "$controller_contract_root/python3"
for handshake_mode in missing partial; do
  handshake_action="handshake-$handshake_mode"
  if PATH="$controller_contract_root:$PATH" REAL_CONTROLLER_PYTHON3="$controller_real_python3" \
    FAKE_CONTROLLER_HANDSHAKE_MODE="$handshake_mode" \
    acceptance_controller_run "$controller_contract_root/control" "$handshake_action" 1 \
    sh -c 'sleep 30' >"$controller_contract_root/$handshake_action.log" 2>&1; then
    printf '%s handshake unexpectedly succeeded\n' "$handshake_mode" >&2
    exit 1
  fi
  test -f "$controller_contract_root/control/$handshake_action.failed"
  test ! -e "$controller_contract_root/control/$handshake_action.applied"
  if grep -E 'integer expression|illegal number|kill:.*-' "$controller_contract_root/$handshake_action.log" >/dev/null; then
    printf '%s handshake reached unsafe arithmetic or signaling\n' "$handshake_mode" >&2
    exit 1
  fi
done

# An interrupt can arrive while the run-side handshake is still being
# validated. stop_child must reject the malformed PGID and safely fall back to
# the owned leader PID without arithmetic diagnostics or group signaling.
cat >"$controller_contract_root/stop-child-driver.sh" <<'SH'
#!/bin/sh
set -eu
helper=$1
root=$2
. "$helper"
mkdir -m 0700 "$root/stop-control"
sleep 30 &
controller_child_pid=$!
controller_child_pgid=':123'
controller_child_signal_root="$root/stop-control"
controller_child_signal_action=partial-stop
acceptance_controller_stop_child
if kill -0 "$controller_child_pid" 2>/dev/null; then
  printf 'malformed PGID stop left child alive\n' >&2
  exit 1
fi
test -f "$root/stop-control/partial-stop.failed"
SH
chmod 0700 "$controller_contract_root/stop-child-driver.sh"
if ! "$controller_contract_root/stop-child-driver.sh" "$controller_helper" "$controller_contract_root" \
  >"$controller_contract_root/partial-stop.log" 2>&1; then
  printf 'malformed PGID stop unexpectedly failed\n' >&2
  exit 1
fi
if grep -E 'integer expression|illegal number|kill:.*-' "$controller_contract_root/partial-stop.log" >/dev/null; then
  printf 'malformed PGID stop reached unsafe arithmetic or signaling\n' >&2
  exit 1
fi
find "$controller_contract_root" -depth -delete

# Drive the real interruption path: the foreground controller receives TERM
# while its child ignores TERM, so the owned group must be KILLed and reaped,
# and the interrupted action must still publish one private failed signal.
interrupt_contract_root=$(mktemp -d "/tmp/plainpost-controller-interrupt.XXXXXX")
mkdir -m 0700 "$interrupt_contract_root/control"
cat >"$interrupt_contract_root/driver.sh" <<'SH'
#!/bin/sh
set -eu
helper=$1
root=$2
pid_file=$root/child.pid
. "$helper"
controller_child_pid=''
controller_child_pgid=''
controller_child_signal_root=''
controller_child_signal_action=''
on_interrupt() {
  acceptance_controller_stop_child
  exit 143
}
trap on_interrupt HUP INT TERM
driver_pid=$$
(sleep 0.2; kill -TERM "$driver_pid") &
sender=$!
acceptance_controller_run "$root/control" interrupted 30 \
  sh -c 'trap "" TERM; sleep 30 & child=$!; printf "%s\n" "$child" >"$1"; wait "$child"' \
  sh "$pid_file"
wait "$sender" 2>/dev/null || true
SH
chmod 0700 "$interrupt_contract_root/driver.sh"
if "$interrupt_contract_root/driver.sh" "$controller_helper" "$interrupt_contract_root"; then
  printf 'controller interruption driver unexpectedly succeeded\n' >&2
  exit 1
fi
test -f "$interrupt_contract_root/control/interrupted.failed"
test ! -e "$interrupt_contract_root/control/interrupted.applied"
[ "$(stat -f '%Lp' "$interrupt_contract_root/control/interrupted.failed" 2>/dev/null || stat -c '%a' "$interrupt_contract_root/control/interrupted.failed")" = 600 ]
[ "$(find "$interrupt_contract_root/control" -maxdepth 1 -type f -name 'interrupted.*' | wc -l | tr -d '[:space:]')" = 1 ]
interrupt_child_pid=$(tr -d '[:space:]' <"$interrupt_contract_root/child.pid")
if kill -0 "$interrupt_child_pid" 2>/dev/null; then
  printf 'interrupted controller descendant survived TERM/KILL and reap\n' >&2
  exit 1
fi
find "$interrupt_contract_root" -depth -delete

# Capture every Docker argv used by the fixture helper while it runs its
# protocol probe. The password is deliberately present only in a private
# mode-0600 file; it must not reach Docker argv or helper output.
fixture_contract_root=$(mktemp -d "/tmp/plainpost-fixture-contract.XXXXXX")
mkdir -m 0700 "$fixture_contract_root/bin" "$fixture_contract_root/control" "$fixture_contract_root/mail-fixture"
fixture_docker_log="$fixture_contract_root/docker.argv"
fixture_run_log="$fixture_contract_root/run.log"
fixture_password_file="$fixture_contract_root/provider_password"
printf '%s' 'acceptance-password' >"$fixture_password_file"
chmod 0600 "$fixture_password_file"
cat >"$fixture_contract_root/bin/docker" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_DOCKER_LOG"
if [ "$1" = compose ]; then
  case " $* " in
    *" ps -q "*) printf '%s\n' fixture-container ;;
  esac
fi
if [ "$1" = exec ] && [ "$2" = -i ]; then
  cat >/dev/null
fi
exit 0
SH
chmod 0700 "$fixture_contract_root/bin/docker"
cat >"$fixture_contract_root/mail-fixture/plainpost_acceptance_mail_control.py" <<'PY'
import sys
sys.exit(0)
PY
if ! PATH="$fixture_contract_root/bin:$PATH" FAKE_DOCKER_LOG="$fixture_docker_log" \
  "$fixture_restart_helper" \
  "$compose" contract-project "$fixture_contract_root" smtp-fixture node-image 1000 1000 \
  s3 /attachments false https://s3.invalid bucket region path-style \
  /tmp/s3-access /tmp/s3-secret "$fixture_password_file" >"$fixture_run_log" 2>&1; then
  printf 'fixture helper argv probe unexpectedly failed\n' >&2
  exit 1
fi
if grep -F 'acceptance-password' "$fixture_docker_log" "$fixture_run_log" >/dev/null; then
  printf 'fixture password reached Docker argv or helper output\n' >&2
  exit 1
fi
test "$(stat -f '%Lp' "$fixture_contract_root/control/smtp-fixture.status" 2>/dev/null || stat -c '%a' "$fixture_contract_root/control/smtp-fixture.status")" = 600
find "$fixture_contract_root" -depth -delete

# A restarted IMAP fixture can accept its container restart before its TLS
# listener is ready. The helper must retry the real in-container probe.
fixture_contract_root=$(mktemp -d "/tmp/plainpost-fixture-retry-contract.XXXXXX")
mkdir -m 0700 "$fixture_contract_root/bin" "$fixture_contract_root/control" "$fixture_contract_root/mail-fixture"
fixture_docker_log="$fixture_contract_root/docker.argv"
fixture_run_log="$fixture_contract_root/run.log"
fixture_probe_count="$fixture_contract_root/probe.count"
cat >"$fixture_contract_root/bin/docker" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_DOCKER_LOG"
if [ "$1" = compose ]; then
  case " $* " in
    *" ps -q "*) printf '%s\n' fixture-container ;;
  esac
fi
if [ "$1" = exec ] && [ "$2" = -i ]; then
  probe_count=0
  if [ -f "$FAKE_PROBE_COUNT" ]; then probe_count=$(cat "$FAKE_PROBE_COUNT"); fi
  probe_count=$((probe_count + 1))
  printf '%s\n' "$probe_count" >"$FAKE_PROBE_COUNT"
  cat >/dev/null
  if [ "$probe_count" -le "${FAKE_PROBE_FAILURES:-0}" ]; then exit 1; fi
fi
exit 0
SH
chmod 0700 "$fixture_contract_root/bin/docker"
cat >"$fixture_contract_root/mail-fixture/plainpost_acceptance_mail_control.py" <<'PY'
import sys
sys.exit(0)
PY
if ! PATH="$fixture_contract_root/bin:$PATH" FAKE_DOCKER_LOG="$fixture_docker_log" \
  FAKE_PROBE_COUNT="$fixture_probe_count" FAKE_PROBE_FAILURES=2 \
  "$fixture_restart_helper" \
  "$compose" contract-project "$fixture_contract_root" imap-fixture node-image 1000 1000 \
  s3 /attachments false https://s3.invalid bucket region path-style \
  /tmp/s3-access /tmp/s3-secret /tmp/unneeded-password >"$fixture_run_log" 2>&1; then
  printf 'fixture IMAP retry probe unexpectedly failed\n' >&2
  exit 1
fi
[ "$(tr -d '[:space:]' <"$fixture_probe_count")" = 3 ]
find "$fixture_contract_root" -depth -delete

# A restarted IMAP fixture can still reject the transition command for a
# bounded readiness window. The transition child must retry those transient
# failures, while the controller owns exactly one terminal signal for the
# request (applied on eventual success, failed after the bounded attempts).
transition_contract_root=$(mktemp -d "/tmp/plainpost-provider-transition-contract.XXXXXX")
mkdir -m 0700 "$transition_contract_root/control" "$transition_contract_root/state"
cat >"$transition_contract_root/transition.py" <<'PY'
import os
from pathlib import Path

counter = Path(os.environ["FAKE_TRANSITION_COUNT"])
attempts = int(counter.read_text() or "0") if counter.exists() else 0
attempts += 1
counter.write_text(str(attempts))
raise SystemExit(1 if attempts <= int(os.environ.get("FAKE_TRANSITION_FAILURES", "0")) else 0)
PY
transition_success_status=0
FAKE_TRANSITION_COUNT="$transition_contract_root/success.count" \
  FAKE_TRANSITION_FAILURES=2 \
  acceptance_controller_run "$transition_contract_root/control" provider-transition 5 \
  "$provider_transition_helper" "$transition_contract_root/transition.py" "$transition_contract_root/state" 3 0.01 >"$transition_contract_root/success.log" 2>&1 || transition_success_status=$?
[ "$transition_success_status" -eq 0 ]
[ "$(tr -d '[:space:]' <"$transition_contract_root/success.count")" = 3 ]
test -f "$transition_contract_root/control/provider-transition.applied"
test ! -e "$transition_contract_root/control/provider-transition.failed"
[ "$(find "$transition_contract_root/control" -maxdepth 1 -type f -name 'provider-transition.*' | wc -l | tr -d '[:space:]')" = 1 ]
transition_failure_status=0
FAKE_TRANSITION_COUNT="$transition_contract_root/failure.count" \
  FAKE_TRANSITION_FAILURES=3 \
  acceptance_controller_run "$transition_contract_root/control" provider-transition-failure 5 \
  "$provider_transition_helper" "$transition_contract_root/transition.py" "$transition_contract_root/state" 3 0.01 >"$transition_contract_root/failure.log" 2>&1 || transition_failure_status=$?
[ "$transition_failure_status" -ne 0 ]
[ "$(tr -d '[:space:]' <"$transition_contract_root/failure.count")" = 3 ]
test -f "$transition_contract_root/control/provider-transition-failure.failed"
test ! -e "$transition_contract_root/control/provider-transition-failure.applied"
[ "$(find "$transition_contract_root/control" -maxdepth 1 -type f -name 'provider-transition-failure.*' | wc -l | tr -d '[:space:]')" = 1 ]
find "$transition_contract_root" -depth -delete

# Exercise the cleanup owner, not only its source markers.  This probe starts
# a zero-delay setsid leader with a surviving child, waits the leader away,
# and verifies the retained process group is still cleaned safely.
if ! PLAINPOST_SYNC_NODE_PROCESS_CLEANUP_TEST=enabled "$owner" >/dev/null 2>&1; then
  printf 'acceptance process-group cleanup probe failed\n' >&2
  exit 1
fi
if ! "$attachment_release_contract" >/dev/null 2>&1; then
  printf 'attachment release controller contract probe failed\n' >&2
  exit 1
fi
test -x "$attachment_release_contract"
test -x "$attachment_release_helper"
grep -F 'acceptance_attachment_release_poll_attempts=${6:-20}' "$attachment_release_helper" >/dev/null
grep -F 'acceptance_attachment_release_poll_delay_seconds=${7:-0.25}' "$attachment_release_helper" >/dev/null

for service in postgres-node-one postgres-node-two; do
  grep -F "  $service:" "$compose" >/dev/null
done
grep -F 'POSTGRES_USER: plainpost_node_bootstrap' "$compose" >/dev/null
grep -F 'POSTGRES_DB: postgres' "$compose" >/dev/null
grep -F 'node-postgres-init.sql:/docker-entrypoint-initdb.d/001-node-authority.sql:ro' "$compose" >/dev/null
grep -F 'plainpost_sync_node LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS' "$owner" >/dev/null
grep -F 'plainpost_restore_admin LOGIN NOSUPERUSER CREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS' "$owner" >/dev/null
grep -F 'plainpost_restore_stage LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS' "$owner" >/dev/null
grep -F 'CREATE DATABASE plainpost_sync_node OWNER plainpost_restore_admin' "$owner" >/dev/null
grep -F 'GRANT plainpost_restore_stage TO plainpost_restore_admin' "$owner" >/dev/null
grep -F 'GRANT plainpost_sync_node TO plainpost_restore_admin' "$owner" >/dev/null
grep -F 'GRANT plainpost_restore_stage TO plainpost_restore_admin WITH INHERIT TRUE, SET TRUE;' "$owner" >/dev/null || {
  printf 'release owner must preserve explicit PostgreSQL role membership options for restore stage\n' >&2
  exit 1
}
grep -F 'GRANT plainpost_sync_node TO plainpost_restore_admin WITH INHERIT TRUE, SET TRUE;' "$owner" >/dev/null || {
  printf 'release owner must preserve explicit PostgreSQL role membership options for runtime node\n' >&2
  exit 1
}
grep -F "where member=(select oid from pg_roles where rolname='plainpost_restore_admin')" "$owner" >/dev/null
grep -F "string_agg(pg_get_userbyid(roleid), ',' order by pg_get_userbyid(roleid))" "$owner" >/dev/null
grep -F "plainpost_restore_stage,plainpost_sync_node" "$owner" >/dev/null
grep -F 'restore_admin_database_url' "$owner" >/dev/null
grep -F 'restore_stage_database_url' "$owner" >/dev/null
grep -F 'PLAINPOST_NODE_RESTORE_ADMIN_DATABASE_URL_FILE: /run/secrets/restore_admin_database_url' "$compose" >/dev/null
grep -F 'PLAINPOST_NODE_RESTORE_STAGE_DATABASE_URL_FILE: /run/secrets/restore_stage_database_url' "$compose" >/dev/null
grep -F 'PLAINPOST_NODE_BACKUP_ROOT: /node-data/backups' "$compose" >/dev/null
grep -F 'PLAINPOST_NODE_BACKUP_KEY_FILE: /run/secrets/backup_key' "$compose" >/dev/null
grep -F 'PLAINPOST_NODE_FIXED_ATTACHMENT_DIR: /node-attachments' "$compose" >/dev/null
grep -F 'multipart/mixed' "$owner" >/dev/null
grep -F 'Content-Disposition: attachment' "$owner" >/dev/null
grep -F 'Content-Transfer-Encoding: base64' "$owner" >/dev/null
grep -F 'async def upgrade_smtp_tls' "$mail_fixture" >/dev/null
grep -F 'writer = await upgrade_smtp_tls(reader, writer, context)' "$mail_fixture" >/dev/null
grep -F 'await start_tls(context, ssl_handshake_timeout=10)' "$mail_fixture" >/dev/null
grep -F 'server_side=True, ssl_handshake_timeout=10' "$mail_fixture" >/dev/null
if grep -F 'StreamReaderProtocol(asyncio.StreamReader())' "$mail_fixture" >/dev/null || grep -F '250 TLS established' "$mail_fixture" >/dev/null; then
  printf 'SMTP STARTTLS fixture replaces the active reader or emits a post-handshake response\n' >&2
  exit 1
fi
grep -F 'attachment-snapshot-digest=absent' "$swift_scenario" >/dev/null
grep -F 'let hydratedAttachment = complete.metadata' "$swift_scenario" >/dev/null
grep -F 'authenticated attachment response must publish a SHA-256 content digest' "$swift_scenario" >/dev/null
grep -F 'PLAINPOST_NODE_CENTRAL_CA_FILE: /run/public/ca.crt' "$compose" >/dev/null
grep -F 'go run ./cmd/plainpost-sync-node-acceptance-preflight' "$owner" >/dev/null
grep -F 'Node fixed attachment root is not host-writable' "$owner" >/dev/null
grep -F 'Node backup root is not host-writable' "$owner" >/dev/null
grep -F 'GRANT USAGE, CREATE ON SCHEMA public TO plainpost_sync_node' "$owner" >/dev/null
grep -F 'rolsuper::text || chr(9) || rolcreatedb::text' "$owner" >/dev/null
grep -F '[ "$role_flags" = '\''true' "$owner" >/dev/null
grep -F '[ "$schema_privileges" = '\''true' "$owner" >/dev/null
grep -F 'has_database_privilege' "$owner" >/dev/null
grep -F 'candidate.datallowconn and not candidate.datistemplate' "$owner" >/dev/null
grep -F "candidate.datname <> 'plainpost_sync_node'" "$owner" >/dev/null
grep -F 'plainpost_sync_node@%s:5432/plainpost_sync_node?sslmode=verify-full&sslrootcert=/run/plainpost-public/postgres-ca.pem' "$owner" >/dev/null
grep -F 'postgres-$node_name' "$owner" >/dev/null
if ! grep -F 'for database_service in $release_database_services; do' "$owner" >/dev/null || \
   ! grep -F 'postgres) database_node=node-one ;;' "$owner" >/dev/null || \
   ! grep -F 'postgres-node-two) database_node=node-two ;;' "$owner" >/dev/null; then
  printf 'provider credential mode check does not follow the database service mapping\n' >&2
  exit 1
fi
grep -F 'ssl=on' "$wrapper" >/dev/null
grep -F '/run/plainpost-public/postgres-ca.pem' "$compose" >/dev/null
test -x "$wrapper"
grep -F '/usr/local/bin/docker-entrypoint.sh postgres' "$wrapper" >/dev/null
if grep -F 'cp /run/postgres-tls/server.crt' "$compose" >/dev/null; then
  printf 'PostgreSQL TLS setup bypasses official initdb entrypoint\n' >&2
  exit 1
fi
(cd "$root/Services/PlainpostGo" && go test ./internal/node/config -run '^TestPrivateTransportAcceptanceUsesProductionAuthorityContract$' -count=1) >/dev/null
for node in one two; do
  grep -F "PLAINPOST_TAILSCALE_HOSTNAME: node-$node.private-beta.ts.net" "$compose" >/dev/null
  grep -F "PLAINPOST_NODE_CLIENT_ADDR: 0.0.0.0:8080" "$compose" >/dev/null
  grep -F "PLAINPOST_NODE_CLIENT_PUBLIC_URL: https://node-$node.private-beta.ts.net:18443" "$compose" >/dev/null
  grep -F "PLAINPOST_NODE_ENROLLMENT_ENDPOINT: https://node-$node.private-beta.ts.net:18443" "$compose" >/dev/null
  grep -F "PLAINPOST_NODE_CENTRAL_API_URL: https://node-$node.private-beta.ts.net:18081" "$compose" >/dev/null
  grep -F "PLAINPOST_ACCEPTANCE_TCP_UPSTREAM: node-$node:8080" "$compose" >/dev/null
  grep -F "${node}-central-tls:/run/tls:ro" "$compose" >/dev/null
done
grep -F 'PLAINPOST_ACCEPTANCE_LISTEN_ADDR: :18081' "$compose" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_UPSTREAM: http://central:8080' "$compose" >/dev/null
grep -F 'condition: service_healthy' "$compose" >/dev/null
grep -F '"/plainpost-acceptance-tls-proxy", "healthcheck"' "$compose" >/dev/null
grep -F "database_authority=''" "$owner" >/dev/null
grep -F 'database_authority=$(docker exec "$database_container" psql -U plainpost_sync_node -d "$node_one_database_name" -Atc' "$owner" >/dev/null
grep -F 'for _ in $(seq 1 90); do' "$owner" >/dev/null
grep -F "database_authority_expected=\$(printf 'plainpost_sync_node\\tplainpost_sync_node')" "$owner" >/dev/null
if grep -F '[ "$database_authority" = '\''plainpost_sync_node\\tplainpost_sync_node' "$owner" >/dev/null; then
  printf 'PostgreSQL authority assertion compares a literal backslash-t\n' >&2
  exit 1
fi
grep -F 'target: 18443' "$compose" >/dev/null
grep -F 'docker port "$node_one_relay" 18443/tcp' "$owner" >/dev/null
grep -F 'PLAINPOST_SYNC_NODE_ACCEPTANCE_NODE_ONE_RESOLVE="node-one.private-beta.ts.net:18443:' "$owner" >/dev/null
grep -F 'acceptance_attachment_dir=/node-attachments' "$owner" >/dev/null
grep -F "Destination \"/node-attachments\"" "$owner" >/dev/null
grep -F 'node-one-data/attachments:/node-attachments:rw' "$compose" >/dev/null
grep -F 'node-two-data/attachments:/node-attachments:rw' "$compose" >/dev/null
grep -F 'wait_for_node_one_ready()' "$owner" >/dev/null
grep -F 'wait_for_node_ready()' "$owner" >/dev/null
grep -F 'wait_for_node_two_ready()' "$owner" >/dev/null
grep -F 'compose_run up -d --force-recreate node-two node-two-relay' "$owner" >/dev/null
grep -F 'bootstrap_provisioner=${PLAINPOST_SYNC_NODE_BOOTSTRAP_PROVISIONER:-$root/Deploy/sync-node/scripts/provision-owner-bootstrap.py}' "$owner" >/dev/null
grep -F 'export_node_installation_identity node-two' "$owner" >/dev/null
grep -F 'provision_node_bootstrap node-two https://node-two.private-beta.ts.net:18443' "$owner" >/dev/null
grep -F 'PLAINPOST_SYNC_NODE_BOOTSTRAP_PROFILE_TWO="$node_two_bootstrap_profile"' "$owner" >/dev/null
if grep -F '/plainpost-sync-node enrollment-presentation' "$owner" >/dev/null; then
  printf 'private transport still invokes the manual enrollment presentation CLI\n' >&2
  exit 1
fi
# acceptance-node-restart.sh's presentation mode returns after its explicit
# ten-second Compose restart. Its ordinary readiness mode adds ten probes;
# each probe may consume curl's five-second deadline and one-second delay. Keep
# the presentation controller and Swift budgets strictly nested, while keeping
# ordinary node restarts above the full readiness-mode budget.
node_two_presentation_helper_restart_seconds=10
node_two_presentation_helper_attempts=10
node_two_presentation_helper_command_timeout_seconds=5
node_two_presentation_helper_retry_delay_seconds=1
node_two_presentation_helper_worst_case_seconds=$node_two_presentation_helper_restart_seconds
node_two_default_helper_worst_case_seconds=$((node_two_presentation_helper_restart_seconds + node_two_presentation_helper_attempts * (node_two_presentation_helper_command_timeout_seconds + node_two_presentation_helper_retry_delay_seconds)))
grep -F 'docker compose -p "$project" -f "$compose" restart --timeout 10 "$node_service"' "$node_restart_helper" >/dev/null
grep -F 'restart_mode=${19:-readiness}' "$node_restart_helper" >/dev/null
grep -F 'readiness|health|presentation|mutation)' "$node_restart_helper" >/dev/null
grep -F '[ "$restart_mode" = presentation ]' "$node_restart_helper" >/dev/null
grep -F 'for _ in 1 2 3 4 5 6 7 8 9 10; do' "$node_restart_helper" >/dev/null
grep -F -- '--max-time 5' "$node_restart_helper" >/dev/null
grep -F 'sleep 1' "$node_restart_helper" >/dev/null
node_restart_timeout_seconds=$(sed -n 's/^node_restart_timeout_seconds=\([0-9][0-9]*\)$/\1/p' "$owner")
swift_node_two_activation_restart_timeout_seconds=$(sed -n 's/^private let acceptanceNodeTwoRestartControllerTimeoutSeconds = \([0-9][0-9]*\)$/\1/p' "$swift_live")
swift_node_two_activation_restart_count=$(sed -n 's/^private let acceptanceNodeTwoActivationRestartCount = \([0-9][0-9]*\)$/\1/p' "$swift_live")
swift_node_two_activation_scheduling_margin_seconds=$(sed -n 's/^private let acceptanceNodeTwoActivationSchedulingMarginSeconds = \([0-9][0-9]*\)$/\1/p' "$swift_live")
provider_poll_interval_seconds=$(sed -n 's/^provider_poll_interval_seconds=\([0-9][0-9]*\)$/\1/p' "$owner")
provider_mailbox_count=$(sed -n 's/^provider_mailbox_count=\([0-9][0-9]*\)$/\1/p' "$owner")
provider_transition_scheduling_margin_seconds=$(sed -n 's/^provider_transition_scheduling_margin_seconds=\([0-9][0-9]*\)$/\1/p' "$owner")
provider_cycle_seconds=$((provider_poll_interval_seconds * provider_mailbox_count + provider_transition_scheduling_margin_seconds))
client_signal_idle_timeout_seconds=$((provider_cycle_seconds + 30))
client_scenario_cap_seconds=$((provider_cycle_seconds * 4 + 60))
[ "$node_restart_timeout_seconds" -gt "$node_two_default_helper_worst_case_seconds" ] || {
	printf 'ordinary node restart timeout does not contain helper readiness budget\n' >&2
	exit 1
}
[ "$swift_node_two_activation_restart_timeout_seconds" = "$node_restart_timeout_seconds" ] || {
	printf 'Swift node-two activation budget is not derived from the owner restart timeout\n' >&2
	exit 1
}
[ "$swift_node_two_activation_scheduling_margin_seconds" = "$provider_transition_scheduling_margin_seconds" ] || {
	printf 'Swift node-two activation margin diverges from the owner scheduling margin\n' >&2
	exit 1
}

grep -F 'private let acceptanceNodeTwoActivationWaitSeconds =' "$swift_live" >/dev/null
grep -F 'acceptanceNodeTwoRestartControllerTimeoutSeconds * acceptanceNodeTwoActivationRestartCount' "$swift_live" >/dev/null || {
	printf 'Swift node-two activation wait must be an explicit derived expression\n' >&2
	exit 1
}
grep -F '+ acceptanceNodeTwoActivationSchedulingMarginSeconds' "$swift_live" >/dev/null || {
	printf 'Swift node-two activation wait must include the owner scheduling margin\n' >&2
	exit 1
}
swift_node_two_activation_wait_seconds=$((swift_node_two_activation_restart_timeout_seconds * swift_node_two_activation_restart_count))
swift_node_two_activation_wait_seconds=$((swift_node_two_activation_wait_seconds + swift_node_two_activation_scheduling_margin_seconds))
node_two_activation_restart_calls=$(awk '
  /wait_for_signal node-two-activated/ { active=1 }
  active && /restart_node_bounded node-two node-two\.private-beta\.ts\.net "\$node_two_port" startup-node-two-[12]$/ { count++ }
  active && /: >"\$temporary\/control\/node-two-restarted"/ { print count; exit }
' "$owner")
[ "$node_two_activation_restart_calls" -eq "$swift_node_two_activation_restart_count" ] || {
	printf 'owner node-two activation restart count diverges from Swift budget\n' >&2
	exit 1
}
node_two_activation_readiness_checks=$(awk '
  /wait_for_signal node-two-activated/ { active=1 }
  active && /wait_for_node_two_ready after-restart-[12]$/ { count++ }
  active && /: >"\$temporary\/control\/node-two-restarted"/ { print count; exit }
' "$owner")
[ "$node_two_activation_readiness_checks" -eq "$swift_node_two_activation_restart_count" ] || {
	printf 'owner node-two activation readiness checks must cover each restart\n' >&2
	exit 1
}
[ "$swift_node_two_activation_wait_seconds" -gt "$((node_restart_timeout_seconds * swift_node_two_activation_restart_count))" ] || {
	printf 'Swift node-two activation wait does not contain the persistence restart budget\n' >&2
	exit 1
}
[ "$swift_node_two_activation_wait_seconds" -le "$client_signal_idle_timeout_seconds" ] || {
	printf 'Swift node-two activation wait exceeds owner client idle cap\n' >&2
	exit 1
}
[ "$swift_node_two_activation_wait_seconds" -le "$client_scenario_cap_seconds" ] || {
	printf 'Swift node-two activation wait exceeds owner scenario cap\n' >&2
	exit 1
}
grep -F 'restart_node_bounded node-two' "$owner" >/dev/null
grep -F 'restart_mode=${5:-readiness}' "$owner" >/dev/null
grep -F 'acceptance_controller_run "$temporary" "$restart_action" "$node_restart_timeout_seconds"' "$owner" >/dev/null
grep -F 'wait_for_signal node-two-hot-ready' "$owner" >/dev/null
grep -F 'assert_node_process_identity node-two' "$owner" >/dev/null
grep -F 'terminal_restart_action=restart-node' "$owner" >/dev/null
grep -F 'terminal_restart_action=imap-terminal-fault-restart-node' "$owner" >/dev/null
grep -F 'run_controller_child "$terminal_restart_action" "$node_restart_timeout_seconds" env' "$owner" >/dev/null
grep -F 'restart_mode=readiness' "$owner" >/dev/null
grep -F 'if [ "$acceptance_mail_scenario" = imap-node-restart-before-ack ]; then' "$owner" >/dev/null
grep -F 'imap-node-restart-before-ack) acceptance_imap_mutation_phase=0' "$owner" >/dev/null
grep -F 'acceptance_response_drops="${acceptance_response_drops:+$acceptance_response_drops,}mutation"' "$owner" >/dev/null
grep -F 'POST /v1/mutations=armed' "$owner" >/dev/null
if grep -F 'restart_mode=mutation' "$owner" >/dev/null; then
  printf 'before-ack response-drop scenario must use readiness restart, not provider mutation restart\n' >&2
  exit 1
fi
grep -F "require_response_drop_evidence 'POST /v1/mutations' dropped mutation-initial-dropped initial" "$owner" >/dev/null
grep -F 'check_mutation_response_drop_correlation initial' "$owner" >/dev/null
grep -F 'imap-matrix-\(matrixCase.selector)-response-drop-transport' "$swift_scenario" >/dev/null
if awk '
  /case "imap-node-restart-before-ack":/ { inside = 1; next }
  inside && /case "imap-node-restart-after-ack":/ { exit 1 }
  inside && /matrixCase[.]selector[)]-rejected/ { bad = 1 }
  END { exit bad ? 0 : 1 }
' "$swift_scenario"; then
  printf 'before-ack mutation response drop must not be reported as a rejected terminal result\n' >&2
  exit 1
fi
grep -F '"$node_one_port" "$restart_mode"' "$owner" >/dev/null
grep -F 'mutation)' "$node_restart_helper" >/dev/null
grep -F 'docker compose -p "$project" -f "$compose" stop --timeout 10 "$node_service"' "$node_restart_helper" >/dev/null
grep -F 'phase imap mutation 1 disconnect' "$node_restart_helper" >/dev/null
grep -F 'wait-phase-release imap mutation 1 --timeout-ms 30000' "$node_restart_helper" >/dev/null
grep -F 'if [ "$restart_mode" = health ] || [ "$restart_mode" = mutation ]; then' "$node_restart_helper" >/dev/null
grep -F 'docker compose -p "$project" -f "$compose" start "$node_service"' "$node_restart_helper" >/dev/null
grep -F 'restart_node_bounded node-two node-two.private-beta.ts.net "$node_two_port" startup-node-two-deletion health' "$owner" >/dev/null
if ! awk '
  /restart_node_bounded node-two node-two\.private-beta\.ts\.net "\$node_two_port" startup-node-two-deletion health$/ { restart=NR }
  restart && /wait_for_node_two_deleted_503 after-deletion$/ { probe=NR }
  restart && /: >"\$temporary\/control\/node-two-deletion-restarted"/ { marker=NR }
  restart && /wait "\$swift_pid"/ { swift=NR }
  /printf '\''stage=privacy-audit\\n'\''/ { audit=NR }
  END { exit !(restart && probe > restart && marker > probe && swift > marker && audit > swift) }
' "$owner"; then
	printf 'final node-two restart must prove exact 503 before Swift completion and privacy audit\n' >&2
	exit 1
fi
grep -F 'node_two_deletion_readiness_timeout_seconds=45' "$owner" >/dev/null
grep -F 'node_two_deletion_wait_seconds=150' "$owner" >/dev/null
grep -F 'wait_for_node_two_deleted_503()' "$owner" >/dev/null
grep -F -- "--output /dev/null --write-out '%{http_code}'" "$owner" >/dev/null
grep -F '[ "$readiness_status" = 503 ]' "$owner" >/dev/null
grep -F 'readiness_deadline_ms=$((readiness_started_ms + node_two_deletion_readiness_timeout_seconds * 1000))' "$owner" >/dev/null
grep -F 'readiness_remaining_ms=$((readiness_deadline_ms - $(acceptance_controller_monotonic_ms)))' "$owner" >/dev/null
grep -F -- '--max-time "$readiness_max_time_seconds"' "$owner" >/dev/null
grep -F '[ "$readiness_max_time_seconds" -ge 1 ] || break' "$owner" >/dev/null
grep -F 'if [ "$((node_restart_timeout_seconds + node_two_deletion_readiness_timeout_seconds))" -ge "$node_two_deletion_wait_seconds" ]; then' "$owner" >/dev/null
if ! awk '
  /node_two_deletion_readiness_timeout_seconds=45/ { probe=45 }
  /node_restart_timeout_seconds=75/ { restart=75 }
  /private let acceptanceNodeTwoDeletionWaitSeconds = 150/ { swift=150 }
  /waitForSignal\("node-two-deletion-restarted", timeoutSeconds: acceptanceNodeTwoDeletionWaitSeconds\)/ { call=1 }
  END { exit !(probe && restart && swift && call && restart + probe < swift) }
' "$owner" "$swift_live"; then
	printf 'node-two deletion exact-503 probe must fit the dedicated Swift deletion waiter\n' >&2
	exit 1
fi
grep -F 'node-two-protected-presentation-begin' "$swift_live" >/dev/null
grep -F 'node-two-protected-presentation-end' "$swift_live" >/dev/null
grep -F 'signal("node-two-hot-ready")' "$swift_live" >/dev/null
grep -F 'waitForHotActivation(' "$swift_live" >/dev/null
grep -F 'timeoutSeconds: acceptanceNodeTwoActivationWaitSeconds' "$swift_live" >/dev/null
grep -F 'scan_privacy_file()' "$owner" >/dev/null
grep -F '[ ! -e "$error_surface" ] && [ ! -L "$error_surface" ]' "$owner" >/dev/null
if awk '/grep .*error-surfaces/ { bad=1 } END { exit bad ? 0 : 1 }' "$owner"; then
  printf 'privacy scan passes an empty error-surface glob as a file\n' >&2
  exit 1
fi
grep -F 'postgres://plainpost_node_bootstrap@postgres-node-one:5432/plainpost_sync_node?sslmode=disable' "$compose" >/dev/null
grep -F 'postgres://plainpost_node_bootstrap@postgres-node-two:5432/plainpost_sync_node?sslmode=disable' "$compose" >/dev/null
if grep -F 'postgres://plainpost@postgres:5432/node_one' "$compose" >/dev/null || grep -F 'postgres://plainpost@postgres:5432/node_two' "$compose" >/dev/null; then
  printf 'privacy audit targets non-existent Node databases on the Central PostgreSQL service\n' >&2
  exit 1
fi
if grep -E 'node_two_presentation_control_loop|node_two_presentation_pid' "$owner" >/dev/null; then
	printf 'removed node-two presentation watcher remains in the private owner\n' >&2
	exit 1
fi
if awk '
  /provision_node_bootstrap node-two / { provision=NR }
  /run_in_owned_session .*swift-test-isolated.sh/ { swift=NR }
  END { exit (provision > 0 && swift > 0 && provision < swift) ? 0 : 1 }
' "$owner"; then :; else
	printf 'node-two protected bootstrap must be provisioned before Swift starts\n' >&2
	exit 1
fi
grep -F 'wait_for_signal node-two-hot-ready' "$owner" >/dev/null
grep -F 'assert_node_process_identity node-two' "$owner" >/dev/null
grep -F 'seed_node_two_acceptance_provider || exit 1' "$owner" >/dev/null
for authority_outage_marker in \
  'authority-outage-wait-begin' 'authority-outage-wait-end' \
  'authority-outage-pause-begin' 'authority-outage-pause-end' \
  'authority-outage-restart-begin' 'authority-outage-restart-end' \
  'authority-outage-readiness-begin' 'authority-outage-readiness-end' \
  'authority-outage-publish-unavailable' 'authority-recover-wait-begin' \
  'authority-recover-wait-end' 'authority-outage-unpause-begin' \
  'authority-outage-unpause-end' 'authority-outage-publish-restored'; do
  grep -F "control_marker $authority_outage_marker" "$owner" >/dev/null || {
    printf 'missing authority outage control marker: %s\n' "$authority_outage_marker" >&2
    exit 1
  }
done
for node_one_marker in \
  'node-one-restart-wait-begin' 'node-one-restart-wait-end' \
  'node-one-checkpoint-before-begin' 'node-one-checkpoint-before-end' \
  'node-one-restart-2-begin' 'node-one-restart-2-end' \
  'node-one-readiness-2-begin' 'node-one-readiness-2-end' \
  'node-one-checkpoint-2-begin' 'node-one-checkpoint-2-end' \
  'node-one-publish-restarted'; do
  grep -F "control_marker $node_one_marker" "$owner" >/dev/null || {
    printf 'missing node-one lifecycle control marker: %s\n' "$node_one_marker" >&2
    exit 1
  }
done
grep -F 'acceptance_control_summary_begin' "$owner" >/dev/null
grep -F 'acceptance_control_summary_end' "$owner" >/dev/null
grep -E 'grep -E .*acceptance-control stage=' "$owner" >/dev/null
awk '
  /compose_run logs --no-color --no-log-prefix --tail 1000/ { compose=NR }
  /acceptance_control_summary_begin/ { summary=NR }
  END { exit (compose > 0 && summary > compose) ? 0 : 1 }
' "$owner"
if grep -F 'restart_node_bounded node-one node-one.private-beta.ts.net "$node_one_port" startup-node-one-authority-outage health' "$owner" >/dev/null &&
   grep -F 'wait_for_node_health authority-outage-restart' "$owner" >/dev/null; then
  :
else
  printf 'authority outage restart must use liveness probes while Central is paused\n' >&2
  exit 1
fi
if awk '
  /provision_node_bootstrap node-two/ { provisioned=NR }
  /run_in_owned_session .*swift-test-isolated.sh/ { swift=NR }
  END { exit (provisioned > 0 && swift > provisioned) ? 0 : 1 }
' "$owner"; then :; else
  printf 'node-two protected profile is not provisioned before the Swift fixture\n' >&2
  exit 1
fi
grep -F 'default_signal_wait_seconds=120' "$owner" >/dev/null
grep -F 'provider_poll_interval_seconds=60' "$owner" >/dev/null
grep -F 'provider_mailbox_count=6' "$owner" >/dev/null
grep -F 'provider_transition_scheduling_margin_seconds=15' "$owner" >/dev/null
grep -F 'provider_cycle_seconds=$((provider_poll_interval_seconds * provider_mailbox_count + provider_transition_scheduling_margin_seconds))' "$owner" >/dev/null
grep -F 'provider_transition_attempts=6' "$owner" >/dev/null
grep -F 'provider_transition_retry_delay_seconds=0.5' "$owner" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_MAIL_ROOT="$transition_root"' "$provider_transition_helper" >/dev/null
grep -F 'PYTHONPATH="$(dirname "$transition_script")"' "$provider_transition_helper" >/dev/null
grep -F 'python3 "$transition_script" transition' "$provider_transition_helper" >/dev/null
grep -F 'docker exec "$transition_container" python3 /opt/plainpost/plainpost_acceptance_mail_fixture.py transition' "$provider_transition_helper" >/dev/null
grep -F 'provider_transition_container=$(compose_run ps -q imap-fixture' "$owner" >/dev/null
if grep -F 'python3 "$temporary/mail-fixture/plainpost_acceptance_mail_control.py" --root "$temporary/mail-state" status' "$owner" >/dev/null; then
  printf 'provider/control state reads must use the fixture namespace after startup\n' >&2
  exit 1
fi
grep -F 'mail_fixture_running()' "$owner" >/dev/null
grep -F 'mail_control()' "$owner" >/dev/null
grep -F 'mail_python()' "$owner" >/dev/null
grep -F 'mail_authority_phase=prestart' "$owner" >/dev/null
grep -F 'mail_authority_phase=poststart' "$owner" >/dev/null
grep -F 'mail_control post-start authority requires a live fixture container' "$owner" >/dev/null
grep -F '"$provider_transition_container" poststart' "$owner" >/dev/null
grep -F 'transition_authority_phase=${6:-prestart}' "$provider_transition_helper" >/dev/null
grep -F '[ "$transition_authority_phase" = poststart ]' "$provider_transition_helper" >/dev/null

# Post-start state access must fail closed when the fixture is restarting; a
# fake host interpreter is the sentinel proving no host fallback was invoked.
authority_gate_root=$(mktemp -d "/tmp/plainpost-mail-authority-gate-contract.XXXXXX")
mkdir -m 0700 "$authority_gate_root/bin" "$authority_gate_root/mail-fixture" "$authority_gate_root/mail-state"
cat >"$authority_gate_root/bin/docker" <<'SH'
#!/bin/sh
if [ "$1" = inspect ]; then printf '%s\n' restarting; exit 0; fi
exit 0
SH
cat >"$authority_gate_root/bin/python3" <<'SH'
#!/bin/sh
: >"$AUTHORITY_GATE_SENTINEL"
exit 0
SH
chmod 0700 "$authority_gate_root/bin/docker" "$authority_gate_root/bin/python3"
awk '/^mail_fixture_running\(\)/,/^run_controller_child\(\)/ { if ($0 !~ /^run_controller_child\(\)/) print }' "$owner" >"$authority_gate_root/gate-functions.sh"
cat >"$authority_gate_root/gate-contract.sh" <<'SH'
#!/bin/sh
set -eu
temporary=$1
mail_authority_phase=poststart
compose_run() { printf '%s\n' fixture-container; }
. "$temporary/gate-functions.sh"
if mail_control status >/dev/null 2>&1; then exit 1; fi
if mail_python -c 'pass' >/dev/null 2>&1; then exit 1; fi
test ! -e "$AUTHORITY_GATE_SENTINEL"
SH
chmod 0700 "$authority_gate_root/gate-contract.sh"
if PATH="$authority_gate_root/bin:$PATH" AUTHORITY_GATE_SENTINEL="$authority_gate_root/host-fallback" \
  "$authority_gate_root/gate-contract.sh" "$authority_gate_root"; then :; else
  printf 'post-start mail authority gate contract failed\n' >&2
  exit 1
fi
cat >"$authority_gate_root/transition-sentinel.py" <<'PY'
from pathlib import Path
import os
Path(os.environ["AUTHORITY_GATE_SENTINEL"]).touch()
PY
if AUTHORITY_GATE_SENTINEL="$authority_gate_root/host-fallback" \
  "$provider_transition_helper" "$authority_gate_root/transition-sentinel.py" "$authority_gate_root/mail-state" 1 0 '' poststart >/dev/null 2>&1; then
  printf 'post-start provider transition accepted an empty fixture container\n' >&2
  exit 1
fi
test ! -e "$authority_gate_root/host-fallback"
find "$authority_gate_root" -depth -delete
grep -F 'client_provider_bounded_phase_count=4' "$owner" >/dev/null
grep -F 'client_signal_idle_timeout_seconds=$((provider_cycle_seconds + 30))' "$owner" >/dev/null
grep -F 'client_scenario_cap_seconds=$((provider_cycle_seconds * client_provider_bounded_phase_count + 60))' "$owner" >/dev/null
grep -F 'client_scenario_started_at=$(date +%s)' "$owner" >/dev/null
grep -F 'default_node_readiness_wait_seconds=120' "$owner" >/dev/null
grep -F 'client_node_readiness_wait_seconds=$((provider_cycle_seconds + 60))' "$owner" >/dev/null
grep -F 'readiness_wait_seconds=$default_node_readiness_wait_seconds' "$owner" >/dev/null
grep -F 'readiness_wait_seconds=$client_node_readiness_wait_seconds' "$owner" >/dev/null
grep -F 'readiness_started_at=$(date +%s)' "$owner" >/dev/null
grep -F 'readiness_elapsed_seconds=' "$owner" >/dev/null
grep -F 'readiness_attempts=' "$owner" >/dev/null
grep -F 'signal_wait_seconds=$default_signal_wait_seconds' "$owner" >/dev/null
grep -F 'swift_log_bytes' "$owner" >/dev/null
grep -F 'swift-progress-begin' "$owner" >/dev/null
grep -F 'acceptance-signal-timeout signal=' "$owner" >/dev/null
grep -F 'idle_seconds=' "$owner" >/dev/null
grep -F 'total_seconds=' "$owner" >/dev/null
grep -F 'cat "$temporary/swift.log" >>"$runtime_log"' "$owner" >/dev/null
grep -F 'kill -0 "$swift_pid"' "$owner" >/dev/null
grep -F 'private struct RecordingNodeSessionSender: NodeSessionStreamingRequestSending' "$swift_live" >/dev/null
grep -F 'let base: any NodeSessionStreamingRequestSending' "$swift_live" >/dev/null
grep -F 'func stream(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPStreamResponse' "$swift_live" >/dev/null
grep -F 'private struct CurlNodeHTTPTransport: NodeHTTPStreamingTransport' "$swift_live" >/dev/null
grep -F 'func stream(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPStreamResponse' "$swift_live" >/dev/null
grep -F 'CurlAcceptanceProcessStream' "$swift_live" >/dev/null
grep -F 'outputPipe' "$swift_live" >/dev/null
grep -F 'private static let supervisorScript' "$swift_live" >/dev/null
grep -F 'supervisorExecutable: String = "/usr/bin/python3"' "$swift_live" >/dev/null
grep -F 'configuredProcess.executableURL = URL(fileURLWithPath: supervisorExecutable)' "$swift_live" >/dev/null
grep -F 'configuredProcess.arguments = ["-c", Self.supervisorScript' "$swift_live" >/dev/null
grep -F 'subprocess.Popen' "$swift_live" >/dev/null
grep -F 'sys.argv[2:]' "$swift_live" >/dev/null
grep -F 'signal.signal(signal.SIGTERM' "$swift_live" >/dev/null
grep -F 'child.kill()' "$swift_live" >/dev/null
grep -F 'child.wait()' "$swift_live" >/dev/null
awk '
  /private static let supervisorScript/ { inside=1 }
  inside && /for descriptor in \(1, 2\)/ { descriptor_loop=NR }
  inside && /os\.close\(descriptor\)/ { descriptor_close=NR }
  inside && /"""#/ {
    exit !(descriptor_loop > 0 && descriptor_close > descriptor_loop)
  }
  END { exit !(descriptor_loop > 0 && descriptor_close > descriptor_loop) }
' "$swift_live"
grep -F 'onProcessSpawnBegin' "$swift_live" >/dev/null
grep -F 'try outputPipe.fileHandleForWriting.close()' "$swift_live" >/dev/null
grep -F 'process.terminate()' "$swift_live" >/dev/null
if grep -F 'Darwin.kill' "$swift_live" >/dev/null; then
  echo "private transport contract: parent must not signal a target PID" >&2
  exit 1
fi
grep -F 'PlainpostNodeMailAuthority' "$swift_live" >/dev/null
grep -F 'PlainpostNodeMailAuthorityFactory.make' "$swift_live" >/dev/null
grep -F 'NodeMailAuthorityLiveScenario.run(authority:' "$swift_live" >/dev/null
grep -F 'authority.search.search' "$swift_scenario" >/dev/null
grep -F 'authority.messages.message' "$swift_scenario" >/dev/null
grep -F 'authority.attachments.attachment' "$swift_scenario" >/dev/null
grep -F 'stage("attachment-complete-open-end")' "$swift_scenario" >/dev/null
grep -F 'stage("attachment-complete-first-byte")' "$swift_scenario" >/dev/null
grep -F 'stage("attachment-complete-drain-end")' "$swift_scenario" >/dev/null
awk '
  /stage\("attachment-complete-open-end"\)/ { open=NR }
  /stage\("attachment-complete-first-byte"\)/ { first=NR }
  /stage\("attachment-complete-drain-end"\)/ { drain=NR }
  END { exit !(open > 0 && first > open && drain > first) }
' "$swift_scenario"
if grep -F 'let unicode = try await client.search' "$swift_scenario" >/dev/null ||
   grep -F 'let body = try await client.message' "$swift_scenario" >/dev/null ||
   grep -F 'let early = try await client.attachment' "$swift_scenario" >/dev/null ||
   grep -F 'let complete = try await client.attachment' "$swift_scenario" >/dev/null; then
  printf 'live read verification bypasses the returned production authority capabilities\n' >&2
  exit 1
fi
grep -F -- '--cacert "$temporary/ca.crt"' "$owner" >/dev/null
grep -F -- "--write-out '\\nhttp_status=%{http_code}'" "$owner" >/dev/null
grep -F 'acceptance-readiness' "$owner" >/dev/null
grep -F 'printf '\''%s\n'\'' "$readiness_summary" >&2' "$owner" >/dev/null
grep -F 'runtime-readiness-worker' Services/PlainpostGo/internal/node/sync/runtime.go >/dev/null
grep -F 'durable_baseline_complete' Services/PlainpostGo/internal/node/sync/runtime.go >/dev/null
grep -F 'durable_failure_count' Services/PlainpostGo/internal/node/sync/runtime.go >/dev/null
grep -F 'in_memory_owner' Services/PlainpostGo/internal/node/sync/runtime.go >/dev/null
grep -F 'unexpected signal' "$owner" >/dev/null
grep -F 'Fatal error' "$owner" >/dev/null
grep -F 'NodeMailAuthorityLiveTests' "$owner" >/dev/null
grep -F 'trap '\''finish "$?"'\'' EXIT' "$owner" >/dev/null
grep -F 'finish "$1"' "$owner" >/dev/null
grep -F 'cleanup || status=1' "$owner" >/dev/null
grep -F "swift_pid=''" "$owner" >/dev/null
grep -F "swift_pgid=''" "$owner" >/dev/null
grep -F 'stop_swift_process' "$owner" >/dev/null
grep -F 'swift_shutdown_poll_attempts=' "$owner" >/dev/null
grep -F 'signal_swift_process TERM' "$owner" >/dev/null
grep -F 'signal_swift_process KILL' "$owner" >/dev/null
grep -F 'wait "$swift_pid" 2>/dev/null || true' "$owner" >/dev/null
grep -F "swift-process-termination outcome=forced" "$owner" >/dev/null
grep -F 'run_in_owned_session' "$owner" >/dev/null
grep -F 'capture_owned_process_group' "$owner" >/dev/null
grep -F 'process_supervisor="$root/Scripts/lib/acceptance-process-supervisor.py"' "$owner" >/dev/null
grep -F 'exec python3 "$process_supervisor" -- "$@"' "$owner" >/dev/null
grep -F 'kill "-$signal" "$swift_pid"' "$owner" >/dev/null
grep -F 'swift_pgid=' "$owner" >/dev/null
grep -F "python3 -c 'import os; print(os.getpgrp())'" "$owner" >/dev/null
if grep -F 'ps -o pgid= -p "$swift_pid"' "$owner" >/dev/null; then
  printf 'owned Swift PGID must not depend on a live leader ps lookup\n' >&2
  exit 1
fi
grep -F '[ "$swift_pid" -le 1 ]' "$owner" >/dev/null
grep -F '[ "$swift_pid" = "$harness_pgid" ]' "$owner" >/dev/null
grep -F 'acceptance-process-supervisor.py' "$root/Scripts/lib/acceptance-process-supervisor.py" >/dev/null
grep -F 'start_new_session=True' "$root/Scripts/lib/acceptance-process-supervisor.py" >/dev/null
grep -F 'process_identity' "$root/Scripts/lib/acceptance-process-supervisor.py" >/dev/null
grep -F 'descendants' "$root/Scripts/lib/acceptance-process-supervisor.py" >/dev/null
grep -F 'PRE_TERMINATION_SNAPSHOTS = 2' "$root/Scripts/lib/acceptance-process-supervisor.py" >/dev/null
grep -F 'def prepare_for_stop(self):' "$root/Scripts/lib/acceptance-process-supervisor.py" >/dev/null
if ! awk '
  /if self.stop_requested:/ { stop=NR }
  /self.prepare_for_stop\(\)/ && stop { prepare=NR }
  /self.signal_owned\(signal.SIGTERM\)/ && prepare { signal=NR; exit }
  END { exit !(stop && prepare && signal && stop < prepare && prepare < signal) }
' "$root/Scripts/lib/acceptance-process-supervisor.py"; then
  printf 'supervisor must discover descendants before terminating the owned group\n' >&2
  exit 1
fi
grep -F 'KILL_GRACE_SECONDS' "$root/Scripts/lib/acceptance-process-supervisor.py" >/dev/null
grep -F 'if time.monotonic() >= deadline:' "$root/Scripts/lib/acceptance-process-supervisor.py" >/dev/null
grep -F 'return 124' "$root/Scripts/lib/acceptance-process-supervisor.py" >/dev/null
grep -F 'process_is_live_non_zombie()' "$owner" >/dev/null
grep -F 'process_stopped()' "$owner" >/dev/null
grep -F 'ps -p "$process_pid" -o stat=' "$owner" >/dev/null
grep -F 'Z*) return 1' "$owner" >/dev/null
grep -F 'acceptance_filter=${PLAINPOST_SYNC_NODE_ACCEPTANCE_SWIFT_FILTER:-PlainpostAccountRuntimeTests.SyncNodePrivateTransportLiveTests/testRealCentralAndNodeProcessesClosePrivateLifecycle}' "$owner" >/dev/null
if grep -F 'acceptance_filter=${PLAINPOST_SYNC_NODE_ACCEPTANCE_SWIFT_FILTER:-SyncNodePrivateTransportLiveTests/' "$owner" >/dev/null ||
   grep -F 'acceptance_filter=${PLAINPOST_SYNC_NODE_ACCEPTANCE_SWIFT_FILTER:-SyncNodePrivateTransportLiveTests/testNestedAcceptanceStreamCancellationStress' "$owner" >/dev/null; then
  printf 'default live filter must select only the exact lifecycle test, not the stress suite\n' >&2
  exit 1
fi
if grep -F 'testNestedAcceptanceStreamCancellationStressReleasesLifecycleAcrossChunkTimings' "$owner" >/dev/null; then
  printf 'default live harness must not embed the cancellation stress test\n' >&2
  exit 1
fi
grep -F 'process-cleanup-leader-exit-test=passed' "$owner" >/dev/null
grep -F 'process-cleanup-leader-exit-child-survived=passed' "$owner" >/dev/null
grep -F 'process-cleanup-success-path-test=passed' "$owner" >/dev/null
grep -F 'process-cleanup-detached-test=failed reason=detached-child-survived-group-stop' "$owner" >/dev/null
grep -F 'controller_child_pid' "$owner" >/dev/null
grep -F 'stop_controller_child' "$owner" >/dev/null
grep -F 'stop_client_control_loop' "$owner" >/dev/null
grep -F 'controller_shutdown_poll_attempts=' "$owner" >/dev/null
grep -F 'run_process_cleanup_test' "$owner" >/dev/null
grep -F 'PLAINPOST_SYNC_NODE_PROCESS_CLEANUP_TEST' "$owner" >/dev/null
if ! awk '
  /finish\(\)/ { inside=1 }
  inside && /stop_swift_process/ { swift_line=NR }
  inside && /stop_client_control_loop/ { control_line=NR }
  inside && /trap - EXIT/ && swift_line && control_line { trap_line=NR; exit }
  END { exit !(swift_line && control_line && trap_line && swift_line < control_line && control_line < trap_line) }
' "$owner"; then
  printf 'finish must stop Swift and the client control loop before disabling EXIT\n' >&2
  exit 1
fi
if ! awk '
  /swift_exit_status=0/ { marker=NR }
  /wait "\$swift_pid"/ && marker { swift_line=NR }
  /stop_swift_process/ && swift_line && !stop_line { stop_line=NR }
  /privacy_markers_found=0/ { privacy_line=NR }
  /stop_client_control_loop/ && privacy_line { control_line=NR }
  /trap - EXIT/ && privacy_line && control_line { trap_line=NR; exit }
  END { exit !(swift_line && stop_line && privacy_line && control_line && trap_line && swift_line < stop_line && stop_line < privacy_line && privacy_line < control_line && control_line < trap_line) }
' "$owner"; then
  printf 'successful cleanup must clean the retained Swift process group before disabling EXIT\n' >&2
  exit 1
fi
if grep -F 'exit "$1"' "$owner" >/dev/null; then
  printf 'signal handler can bypass the exact cleanup owner\n' >&2
  exit 1
fi
grep -F 'ERROR swift-stage' "$swift_scenario" >/dev/null
grep -F 'FileHandle.standardError.write' "$swift_scenario" >/dev/null
grep -F 'private static func controlFileName' "$swift_scenario" >/dev/null
grep -F 'return "\(action).\(phase)"' "$swift_scenario" >/dev/null
grep -F '["request", "applied", "failed"]' "$swift_scenario" >/dev/null
grep -F 'phase: "failed"' "$swift_scenario" >/dev/null
grep -F 'mail-postcondition' "$swift_scenario" >/dev/null
grep -F 'imap-truncated-literal' "$swift_scenario" >/dev/null
for selector in imap-authentication imap-untrusted-certificate imap-same-ca-wrong-host imap-tls1.1 imap-catalog imap-header-fetch imap-body-fetch imap-attachment-fetch imap-delayed-literal imap-uid-gaps imap-expunge imap-uidvalidity-reset imap-idle-wakeup imap-poll-fallback imap-provider-restart-mid-page imap-provider-restart-after-commit imap-node-restart-before-ack imap-node-restart-after-ack imap-concurrent-mutations imap-stale-authority imap-mime-boundaries; do
  grep -F "$selector" "$swift_scenario" >/dev/null
  grep -F "$selector" "$owner" >/dev/null
done
grep -F 'imap-matrix-resume' "$swift_scenario" >/dev/null
grep -F 'restore-imap-fixture-normal' "$swift_scenario" >/dev/null
grep -F 'imap-matrix-assert-authentication' "$swift_scenario" >/dev/null
grep -F 'imap-matrix-append-message' "$swift_scenario" >/dev/null
grep -F 'imap-matrix-assert-no-idle' "$swift_scenario" >/dev/null
grep -F 'imap-matrix-\(matrixCase.selector)-recovery-begin' "$swift_scenario" >/dev/null
grep -F 'restart-imap-fixture' "$swift_scenario" >/dev/null
grep -F 'restart-smtp-fixture' "$swift_scenario" >/dev/null
grep -F 'imap_matrix_fault=imap-truncated-literal' "$owner" >/dev/null
grep -F 'phase "$imap_matrix_protocol" "$imap_matrix_phase" 1 pause' "$owner" >/dev/null
grep -F 'if [ -e "$imap_matrix_resume_request" ]' "$owner" >/dev/null
grep -F 'imap_matrix_resume_occurrence=1' "$owner" >/dev/null
grep -F 'if [ "$acceptance_mail_scenario" = imap-provider-restart-mid-page ]' "$owner" >/dev/null
grep -F 'phase "$imap_matrix_protocol" "$imap_matrix_phase" "$imap_matrix_resume_occurrence" resume' "$owner" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_IMAP_TLS_MODE' "$compose" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_IMAP_WRONG_HOST_TLS_CERT' "$compose" >/dev/null
grep -F 'PLAINPOST_ACCEPTANCE_IMAP_UNTRUSTED_TLS_CERT' "$compose" >/dev/null
for fixture_service in imap-fixture smtp-fixture; do
  if ! awk -v target="$fixture_service" '
    $0 == "  " target ":" { inside = 1; next }
    inside && $0 ~ /^  [A-Za-z0-9_-]+:/ { inside = 0 }
    inside && /stop_grace_period: 1s/ { found = 1 }
    END { exit !found }
  ' "$compose"; then
    printf '%s must bound Docker stop grace so fixture restart fits the controller budget\n' "$fixture_service" >&2
    exit 1
  fi
done
grep -F 'draft-created' "$swift_scenario" >/dev/null
grep -F 'draft-updated' "$swift_scenario" >/dev/null
grep -F 'draft-deleted' "$swift_scenario" >/dev/null
grep -F 'draft-create-replay' "$swift_scenario" >/dev/null
grep -F 'draft-update-replay' "$swift_scenario" >/dev/null
grep -F 'draft-delete-replay' "$swift_scenario" >/dev/null
grep -F 'draft-create-replay-postcondition' "$swift_scenario" >/dev/null
grep -F 'draft-update-replay-postcondition' "$swift_scenario" >/dev/null
grep -F 'draft-delete-replay-postcondition' "$swift_scenario" >/dev/null
grep -F 'restart-imap-fixture-postcondition' "$swift_scenario" >/dev/null
grep -F 'restart-imap-fixture-provider-recovery-cursor-begin' "$swift_scenario" >/dev/null
grep -F 'restart-imap-fixture-provider-recovery-cursor-end' "$swift_scenario" >/dev/null
grep -F 'restart-imap-fixture-provider-recovery-request-begin' "$swift_scenario" >/dev/null
grep -F 'restart-imap-fixture-provider-recovery-request-end' "$swift_scenario" >/dev/null
grep -F 'restart-imap-fixture-provider-recovery-wait-begin' "$swift_scenario" >/dev/null
grep -F 'restart-imap-fixture-provider-recovery-wait-end' "$swift_scenario" >/dev/null
grep -F 'restart-imap-fixture-provider-recovery-delta-begin' "$swift_scenario" >/dev/null
grep -F 'restart-imap-fixture-provider-recovery-delta-end' "$swift_scenario" >/dev/null
if ! awk '
  /restart-imap-fixture-postcondition/ { post = NR }
  /restart-imap-fixture-provider-recovery-cursor-begin/ { cursor = NR }
  /restart-imap-fixture-provider-recovery-request-begin/ { request = NR }
  /restart-imap-fixture-provider-recovery-wait-end/ { wait = NR }
  /restart-imap-fixture-provider-recovery-delta-end/ { delta = NR }
  /let sendSave = try await authority\.mutations\.perform/ { send = NR }
  END { exit !(post && cursor > post && request > cursor && wait > request && delta > wait && send > delta) }
' "$swift_scenario"; then
  printf 'restart fixture recovery must prove a fresh provider delta before send-draft setup\n' >&2
  exit 1
fi
if ! awk '
  /case "imap-node-restart-before-ack":/ { inside = 1; next }
  inside && /case "imap-node-restart-after-ack":/ { stop = 1; next }
  inside && !stop && /try await wait\(controlRoot, action: "restart-node"\)/ { restart = NR }
  inside && !stop && restart && NR > restart && /recovery-replay-begin/ { replay_begin = NR }
  inside && !stop && restart && NR > restart && replay_begin && /client\.reconcilePendingMutation\(\)/ { replay = NR }
  inside && !stop && restart && NR > restart && replay && /recovery-replay-end/ { replay_end = NR }
  inside && !stop && restart && NR > restart && replay_end && /waitForSnapshotMatchingForTesting\(/ { recovery = NR }
  END { exit !(inside && stop && restart && replay_begin > restart && replay > replay_begin && replay_end > replay && recovery > replay_end) }
' "$swift_scenario"; then
  printf 'mutation restart must replay the retained mutation before proving snapshot recovery\n' >&2
  exit 1
fi
grep -F 'restart-node-postcondition' "$swift_scenario" >/dev/null
grep -F 'docker exec -i' "$fixture_restart_helper" >/dev/null
grep -F 'smtp-fixture' "$fixture_restart_helper" >/dev/null
grep -F 'STARTTLS' "$fixture_restart_helper" >/dev/null
grep -F 'AUTH PLAIN' "$fixture_restart_helper" >/dev/null
grep -F 'if any(line.startswith(b"250 ")' "$fixture_restart_helper" >/dev/null
grep -F 'ssl._create_unverified_context().wrap_socket' "$fixture_restart_helper" >/dev/null
grep -F 'password = open("/tmp/plainpost-smtp-probe-password"' "$fixture_restart_helper" >/dev/null
grep -F 'fixture_container" python3' "$fixture_restart_helper" >/dev/null
grep -F 'plainpost-smtp-probe-password' "$fixture_restart_helper" >/dev/null
grep -F 'fixture_probe_attempts=${PLAINPOST_ACCEPTANCE_FIXTURE_PROBE_ATTEMPTS:-6}' "$fixture_restart_helper" >/dev/null
grep -F 'fixture_probe_failure_class=probe-command' "$fixture_restart_helper" >/dev/null
grep -F 'connection-refused' "$fixture_restart_helper" >/dev/null
grep -F 'protocol-timeout' "$fixture_restart_helper" >/dev/null
grep -F 'tls-failure' "$fixture_restart_helper" >/dev/null
grep -F 'protocol-failure' "$fixture_restart_helper" >/dev/null
grep -F 'PLAINPOST_SMTP_PROBE_STARTED' "$fixture_restart_helper" >/dev/null
grep -F 'except BaseException:' "$fixture_restart_helper" >/dev/null
grep -F 'docker inspect --format' "$fixture_restart_helper" >/dev/null
grep -F 'restart_count=' "$fixture_restart_helper" >/dev/null
grep -F 'controller_child_timeout_seconds=20' "$owner" >/dev/null
for fixture_marker in \
  'fixture_marker container-resolve ready' \
  'fixture_marker container-resolve failed' \
  'fixture_marker compose-restart begin' \
  'fixture_marker compose-restart end' \
  'fixture_marker compose-restart failed' \
  'fixture_marker probe ready' \
  'fixture_marker probe unavailable' \
  'fixture_marker status-capture begin' \
  'fixture_marker status-capture end' \
  'fixture_marker status-capture failed'; do
  grep -F "$fixture_marker" "$fixture_restart_helper" >/dev/null
done
grep -F 'docker exec "$fixture_container" python3 /opt/plainpost/plainpost_acceptance_mail_control.py' "$fixture_restart_helper" >/dev/null
grep -F -- '--root /var/lib/plainpost status' "$fixture_restart_helper" >/dev/null
grep -F 'fixture_restart_failure_summary_begin' "$owner" >/dev/null
grep -F 'fixture_restart_failure_summary_end' "$owner" >/dev/null
grep -F 'node_two_presentation_failure_summary_begin' "$owner" >/dev/null
grep -F 'node_two_presentation_failure_summary_end' "$owner" >/dev/null
grep -F 'emit_node_two_presentation_failure_summary' "$owner" >/dev/null
grep -F 'tail -40' "$owner" >/dev/null
grep -F 'tail -80' "$owner" >/dev/null
if grep -F 'docker exec -i' "$fixture_restart_helper" | grep -F -- '-e PLAINPOST_ACCEPTANCE_SMTP_PASSWORD' >/dev/null; then
  printf 'SMTP fixture probe exposes its password through docker exec argv\n' >&2
  exit 1
fi
grep -F 'fixture_probe_password_file' "$owner" >/dev/null
if grep -F 'fixture_probe_password=' "$owner" >/dev/null || grep -F 'smtp_password=' "$owner" >/dev/null; then
  printf 'fixture restart passes a raw SMTP credential through the owner process\n' >&2
  exit 1
fi
grep -F 'run_controller_child' "$owner" >/dev/null
grep -F "trap 'controller_interrupted 129' HUP" "$owner" >/dev/null
grep -F "trap 'controller_interrupted 130' INT" "$owner" >/dev/null
grep -F "trap 'controller_interrupted 143' TERM" "$owner" >/dev/null
grep -F 'controller-child-timeout' "$controller_helper" >/dev/null
grep -F 'controller-child-reaped' "$controller_helper" >/dev/null
grep -F 'CONTROLLER_HANDSHAKE' "$controller_helper" >/dev/null
grep -F '[ "$controller_child_pgid" -ne "$controller_child_pid" ]' "$controller_helper" >/dev/null
grep -F 'acceptance_controller_stop_child' "$owner" >/dev/null
grep -F 'signal_once' "$owner" >/dev/null
grep -F 'mail_postcondition_state_expectation=' "$owner" >/dev/null
grep -F 'attachment-release-failed' "$swift_scenario" >/dev/null
grep -F 'control_signal_path()' "$owner" >/dev/null
grep -F '. "$root/Scripts/lib/acceptance-attachment-release-probe.sh"' "$owner" >/dev/null
grep -F 'acceptance_attachment_release_probe "$temporary/control" "$attachment_release_request" "$attachment_release_applied" "$attachment_release_failed" "$runtime_log"' "$owner" >/dev/null
grep -F 'provider_transition_request=$(control_signal_path "$temporary/control" provider-transition request)' "$owner" >/dev/null
grep -F 'provider_transition_failed=$(control_signal_path "$temporary/control" provider-transition failed)' "$owner" >/dev/null
grep -F 'rm -f "$provider_transition_applied" "$provider_transition_failed"' "$owner" >/dev/null
grep -F 'run_controller_child provider-transition "$controller_child_timeout_seconds"' "$owner" >/dev/null
grep -F 'provider_transition_helper' "$owner" >/dev/null
grep -F '"$temporary/mail-fixture/plainpost_acceptance_mail_fixture.py" "$temporary/mail-state"' "$owner" >/dev/null
grep -F 'attachment_release_request=$(control_signal_path "$temporary/control" attachment-release-probe request)' "$owner" >/dev/null
grep -F 'attachment_release_failed=$(control_signal_path "$temporary/control" attachment-release-probe failed)' "$owner" >/dev/null
grep -F -- "-name '*.stream-active'" "$attachment_release_helper" >/dev/null
grep -F 'acceptance-attachment-release outcome=released' "$attachment_release_helper" >/dev/null
grep -F 'acceptance-attachment-release outcome=active' "$attachment_release_helper" >/dev/null
grep -F ': >"$acceptance_attachment_release_failed"' "$attachment_release_helper" >/dev/null
grep -F 'earlyIterator.cancel()' "$swift_scenario" >/dev/null
grep -F 'attachment-active-before-cancel=' "$swift_scenario" >/dev/null
grep -F 'restart_node_request=$(control_signal_path "$temporary/control" restart-node request)' "$owner" >/dev/null
grep -F 'restart_node_failed=$(control_signal_path "$temporary/control" restart-node failed)' "$owner" >/dev/null
grep -F 'rm -f "$restart_node_applied" "$restart_node_failed"' "$owner" >/dev/null
grep -F 'rm -f "$fixture_request" "$fixture_applied" "$fixture_failed" "$temporary/control/$fixture_service.status"' "$owner" >/dev/null
grep -F 'ERROR acceptance-provider-transition' "$owner" >/dev/null
grep -F 'fixture_transition_before=' "$owner" >/dev/null
grep -F 'fixture_transition_after=' "$owner" >/dev/null
grep -F 'status-initial-begin' "$swift_scenario" >/dev/null
grep -F 'waitForNonEmptyDelta' "$swift_scenario" >/dev/null
grep -F 'client.delta(after: cursor, limit: 2)' "$swift_scenario" >/dev/null
grep -F 'genericProviderPollIntervalSeconds = 60' "$swift_scenario" >/dev/null
grep -F 'acceptanceFixtureMailboxCount = 6' "$swift_scenario" >/dev/null
grep -F 'providerTransitionSchedulingMarginSeconds = 15' "$swift_scenario" >/dev/null
grep -F 'genericProviderPollIntervalSeconds * acceptanceFixtureMailboxCount + providerTransitionSchedulingMarginSeconds + genericProviderPollIntervalSeconds' "$swift_scenario" >/dev/null
grep -F 'acceptanceProviderTransitionPollAttempts' "$swift_scenario" >/dev/null
grep -F 'acceptanceControlSignalPollAttempts = acceptanceProviderTransitionPollAttempts' "$swift_scenario" >/dev/null
if awk '
  /private static func waitForNonEmptyDelta/ { inside=1 }
  inside && /for _ in 0..<120/ { obsolete=1 }
  inside && /private static func waitForInitialSnapshot/ { exit !obsolete }
  END { if (obsolete) exit 0; exit 1 }
' "$swift_scenario"; then
  printf 'delta transition wait retains the obsolete fixed 120-attempt bound\n' >&2
  exit 1
fi
grep -F 'provider-transition-wait-end' "$swift_scenario" >/dev/null
grep -F 'delta-transition-error' "$swift_scenario" >/dev/null
grep -F 'ERROR swift-curl-failure' Tests/PlainpostAccountRuntimeTests/SyncNodePrivateTransportLiveTests.swift >/dev/null
grep -F 'curlDiagnosticCode' Tests/PlainpostAccountRuntimeTests/SyncNodePrivateTransportLiveTests.swift >/dev/null
grep -F -- '"--connect-timeout",String(acceptanceProviderRequestTimeoutSeconds)' Tests/PlainpostAccountRuntimeTests/SyncNodePrivateTransportLiveTests.swift >/dev/null
grep -F -- '"--max-time",String(acceptanceProviderRequestTimeoutSeconds)' Tests/PlainpostAccountRuntimeTests/SyncNodePrivateTransportLiveTests.swift >/dev/null
grep -F 'acceptanceProviderRequestTimeoutSeconds' Tests/PlainpostAccountRuntimeTests/SyncNodePrivateTransportLiveTests.swift >/dev/null
grep -F 'read-apply-begin' "$swift_scenario" >/dev/null
grep -F 'variant: .setLabels(messageIDs: [message.id], addLabelIDs: ["FLAGGED"]' "$swift_scenario" >/dev/null
grep -F 'XCTAssertEqual(labelResult.state, "applied"' "$swift_scenario" >/dev/null
grep -F 'label-replay-second-end' "$swift_scenario" >/dev/null
grep -F 'labels.contains("FLAGGED")' "$swift_scenario" >/dev/null
if grep -F 'addLabelIDs: ["STARRED"]' "$swift_scenario" >/dev/null; then
  printf 'generic label acceptance fabricates Gmail STARRED semantics\n' >&2
  exit 1
fi
grep -F 'DraftRenderer().render' "$authority_source" >/dev/null
grep -F 'signDraftOperation' "$swift_scenario" >/dev/null
grep -F 'authority.mutations.apply(canonicalOperation: sendOperation)' "$swift_scenario" >/dev/null
grep -F 'canonicalOperation: readOperation' "$swift_scenario" >/dev/null
grep -F 'XCTAssertEqual(applied.state, "applied"' "$swift_scenario" >/dev/null
grep -F 'NodeDraftRevisionLedger' "$authority_source" >/dev/null
grep -F 'expectedRevisionForSave' "$authority_source" >/dev/null
grep -F 'revision(for draftID' "$authority_source" >/dev/null
grep -F 'public func draftState(id:' "$swift_client" >/dev/null
grep -F 'node-sync.draft-state.v1' "$swift_models" >/dev/null
grep -F 'ReadDraftState' "$root/Services/PlainpostGo/internal/node/clientapi/http.go" >/dev/null
grep -F 'ReadDraftState' "$root/Services/PlainpostGo/internal/node/clientapi/service.go" >/dev/null
grep -F 'hydrate(draftID:' "$authority_source" >/dev/null
grep -F 'reconcilePendingMutation()' "$swift_client" >/dev/null
grep -F 'maximumPendingAttempts' "$authority_source" >/dev/null
grep -F 'pendingRetryDelay' "$authority_source" >/dev/null
grep -F 'while result.state == "pending"' "$authority_source" >/dev/null
grep -F 'guard result.state == "applied"' "$authority_source" >/dev/null
grep -F 'canonicalOperation: canonicalOperation' "$authority_source" >/dev/null
grep -F 'testDraftRevisionLedgerDoesNotRegressWhenAnOlderSaveIsReplayed' "$authority_tests" >/dev/null
grep -F 'testMutationCapabilityReconcilesPendingWithTheSameCanonicalOperation' "$authority_tests" >/dev/null
grep -F 'testMutationCapabilityThrowsForTerminalFailureStatesWithoutRetrying' "$authority_tests" >/dev/null
grep -F 'testMutationCapabilityTimesOutPendingReconciliationWithinConfiguredBound' "$authority_tests" >/dev/null
if grep -F 'expectedRevision: current.revision' "$swift_scenario" >/dev/null || grep -F 'expectedRevision: afterDraft.revision' "$swift_scenario" >/dev/null; then
  printf 'draft acceptance flow bypasses the production authority mutation path\n' >&2
  exit 1
fi
grep -F 'attachment-complete-end' "$swift_scenario" >/dev/null
grep -F 'attachment-candidate-count=' "$swift_scenario" >/dev/null
grep -F 'Content-Type: multipart/alternative' "$owner" >/dev/null
grep -F 'Content-Type: text/html; charset=utf-8' "$owner" >/dev/null
grep -F 'Unicode <strong>acceptance</strong> body' "$owner" >/dev/null
grep -F 'From: acceptance@example.test' "$owner" >/dev/null
grep -F 'To: recipient@example.test' "$owner" >/dev/null
grep -F 'From: acceptance@example.test' "$mail_fixture" >/dev/null
grep -F 'To: recipient@example.test' "$mail_fixture" >/dev/null
grep -F 'XCTAssertEqual(body.bodyHTML, "<p>Unicode <strong>acceptance</strong> body</p>")' "$swift_scenario" >/dev/null
grep -F 'privacy_test_filtered=$(grep -F -v -f "$patterns" "$privacy_test_log" || true)' "$owner" >/dev/null
grep -F 'PLAINPOST_SYNC_NODE_PRIVACY_FAILURE_TEST' "$owner" >/dev/null
if ! awk '
  /let firstBootstrap = try await fetchBootstrapPresentation/ { bootstrap=NR }
  /let firstPresentation = firstBootstrap.presentation/ && bootstrap && !presentation { presentation=NR }
  /appendPrivacyPatterns\(\[/ && presentation && !append { append=NR }
  END { exit !(bootstrap && presentation && append && bootstrap < presentation && presentation < append) }
' "$swift_live"; then
  printf 'primary enrollment presentation is not registered before subsequent live operations\n' >&2
  exit 1
fi
if ! awk '
  /let credentials = try XCTUnwrap/ { credentials=NR }
  /Data\(credentials.accessToken.utf8\)/ && credentials && !append { append=NR }
  END { exit !(credentials && append && credentials < append) }
' "$swift_live"; then
  printf 'primary credentials are not registered before subsequent live operations\n' >&2
  exit 1
fi
if grep -F 'if let attachment = message.attachments.first' "$swift_scenario" >/dev/null; then
  printf 'attachment coverage is optional\n' >&2
  exit 1
fi
grep -F 'guard let attachment = message.attachments.first else' "$swift_scenario" >/dev/null

if ! grep -F 'AccountDeviceIdentity.generate()' "$swift_live" >/dev/null ||
   ! grep -F 'CentralAccountAdmissionRendezvous' "$swift_live" >/dev/null ||
   ! grep -F 'makeAdmissionCandidate' "$swift_live" >/dev/null ||
   ! grep -F 'revokeDevice' "$swift_live" >/dev/null; then
  printf 'second admitted client lifecycle is missing\n' >&2
  exit 1
fi
if ! grep -F 'secondary-snapshot' "$swift_scenario" >/dev/null ||
   ! grep -F 'secondary-delta' "$swift_scenario" >/dev/null ||
   ! grep -F 'authenticationRejected' "$swift_live" >/dev/null; then
  printf 'second client cursor and stale-fence coverage is missing\n' >&2
  exit 1
fi
grep -F 'restart-status-end' "$swift_scenario" >/dev/null
grep -F 'error == .transportAfterDispatch' "$swift_scenario" >/dev/null
grep -F 'response-drop-\(label)-exact-replay-begin' "$swift_scenario" >/dev/null
grep -F 'response-drop-\(label)-exact-replay-end' "$swift_scenario" >/dev/null
grep -F 'response-drop-\(label)-fresh-commit' "$swift_scenario" >/dev/null
grep -F 'statusWithPostDispatchRecovery(label: "status", client: client)' "$swift_scenario" >/dev/null
grep -F 'statusWithPostDispatchRecovery(label: "restart-status", client: client)' "$swift_scenario" >/dev/null
grep -F 'reconcilePendingRequest()' "$swift_scenario" >/dev/null
grep -F 'XCTAssertTrue(restartStatusResult.recovered' "$swift_scenario" >/dev/null
grep -F 'assignment-provider-readiness-begin' "$swift_scenario" >/dev/null
grep -F 'assignment-provider-readiness-end' "$swift_scenario" >/dev/null
if grep -F 'PUT /v1/mailboxes/assignments=' "$owner" >/dev/null; then
  printf 'generic client API harness writes an assignment response-drop phase state\n' >&2
  exit 1
fi
if ! awk '
  /compose_run pause central-tls/ { pause = NR }
  /restart_node_bounded node-one/ && pause { restart = NR }
  /wait_for_node_health authority-outage-restart/ && restart { ready = NR }
  /: >"\$temporary\/control\/authority-unavailable"/ { unavailable = NR }
  END { exit !(pause && restart && ready && unavailable && pause < restart && restart < ready && ready < unavailable) }
' "$owner"; then
  printf 'authority-unavailable is published before node-one restart liveness\n' >&2
  exit 1
fi

# Every IMAP matrix selector owns the node-two activation handshake: Swift
# emits node-two-activated and then waits for node-two-restarted while the
# replacement is in progress. The ordinary lifecycle retains its Central
# authority-outage wait before the same activation sequence. Keep the actual
# case ordering executable so those two signal protocols cannot be interchanged.
if ! awk '
  /: >"\$temporary\/control\/node-one-restarted"/ { lifecycle_anchor = 1; next }
  lifecycle_anchor && /case "\$acceptance_mail_scenario" in/ { lifecycle = NR; lifecycle_anchor = 0; next }
  lifecycle && /imap-\*\)/ { imap_branch = NR; next }
  imap_branch && !ordinary_branch && !imap_activation && /run_node_two_activation_sequence/ { imap_activation = NR; next }
  imap_branch && !ordinary_branch && !imap_outage && /wait_for_signal authority-outage/ { imap_outage = NR; next }
  imap_branch && !ordinary_branch && /^  \*\)/ { ordinary_branch = NR; next }
  ordinary_branch && !ordinary_outage && /wait_for_signal authority-outage/ { ordinary_outage = NR; next }
  ordinary_branch && !ordinary_activation && /run_node_two_activation_sequence/ { ordinary_activation = NR; next }
  END {
    exit !(lifecycle && imap_branch && imap_activation && ordinary_branch &&
      ordinary_outage && ordinary_activation && imap_activation < ordinary_branch &&
      !imap_outage && ordinary_outage < ordinary_activation)
  }
' "$owner"; then
  printf 'IMAP selectors must activate node-two before the ordinary authority-outage lifecycle\n' >&2
  exit 1
fi

# Terminal IMAP assertion failures are retained as fixed-vocabulary records;
# their summary must not expose counters, provider details, or raw assertion
# values.
for imap_terminal_outcome in \
  'outcome=missing-provider' \
  'outcome=authentication-changed' \
  'outcome=handshake-missing' \
  'outcome=checkpoint-invalid' \
  'outcome=projection-changed' \
  'outcome=expected'; do
  grep -F "$imap_terminal_outcome" "$owner" >/dev/null
done
grep -F 'imap_tls_handshake_proof=observed' "$owner" >/dev/null
grep -F 'handshake=%s' "$owner" >/dev/null
grep -F 'emit_imap_terminal_failure_summary' "$owner" >/dev/null
grep -F 'imap_terminal_failure_summary_begin' "$owner" >/dev/null
grep -F 'imap_terminal_failure_summary_end' "$owner" >/dev/null

# The replacement authority has its own PostgreSQL and secret mounts.  It
# must seed the existing generic provider after activation and before its
# bounded persistence restart; otherwise a healthy-but-unconfigured replacement cannot
# serve the first replacement snapshot.  Keep this executable ordering
# contract tied to the real service and owner invocation.
if ! grep -F 'sync-node-acceptance-seed-node-two:' "$compose" >/dev/null ||
   ! awk '
     /sync-node-acceptance-seed-node-two:/ { service = 1; next }
     service && /node-two-secrets:\/run\/secrets:ro/ { node_two_secrets = 1 }
     service && /node-one-secrets:\/run\/secrets:ro/ { node_one_secrets = 1 }
     service && /^  [a-zA-Z0-9_-]+:/ { exit !(node_two_secrets && !node_one_secrets) }
     END { exit !(node_two_secrets && !node_one_secrets) }
   ' "$compose" ||
   ! awk '
     /run_node_two_activation_sequence\(\)/ { active = 1 }
     active && /wait_for_signal node-two-activated/ { activated = NR }
     active && /wait_for_signal node-two-hot-ready/ { hot_ready = NR }
     active && /assert_node_process_identity node-two/ { same_process = NR }
     active && /seed_node_two_acceptance_provider \|\| exit 1/ { seed_call = NR }
     active && /restart_node_bounded node-two .*startup-node-two-2/ { restart = NR }
     END { exit !(activated && hot_ready && same_process && seed_call && restart && activated < hot_ready && hot_ready < same_process && same_process < seed_call && seed_call < restart) }
   ' "$owner" ||
   ! awk '
     /seed_node_two_acceptance_provider\(\)/ { active = 1 }
     active && /acceptance-provider-seed-node-two-start/ { seed_start = NR }
     active && /sync-node-acceptance-seed-node-two/ { seed_service = NR }
     active && /acceptance-provider-seed-node-two-success/ { seed_success = NR }
     active && /acceptance-provider-seed-node-two-checkpoint/ { seed_checkpoint = NR }
     active && /acceptance-provider-seed-node-two-failed/ { seed_failed = NR }
     active && /^}/ { exit !(seed_start && seed_service && seed_success && seed_checkpoint && seed_start < seed_service && seed_service < seed_success && seed_success < seed_checkpoint) }
     END { exit !(seed_start && seed_service && seed_success && seed_checkpoint) }
   ' "$owner"; then
  printf 'node-two replacement must seed its own provider before restart\n' >&2
  exit 1
fi
grep -F 'swift_failure_summary_begin' "$owner" >/dev/null
grep -F 'swift.log' "$owner" >/dev/null
grep -F 'swift_stage_failure_summary_begin' "$owner" >/dev/null
grep -F 'acceptance_provider_transition_summary_begin' "$owner" >/dev/null
grep -F 'provider_failure_summary_begin' "$owner" >/dev/null
grep -F '\[DEBUG-sync-node-runtime\] provider failure' "$owner" >/dev/null
grep -F '"stage", "runtime-provider-failure"' Services/PlainpostGo/internal/node/sync/runtime.go >/dev/null
grep -F 'provider_tag' Services/PlainpostGo/internal/node/sync/runtime.go >/dev/null
grep -F 'retry_disposition' Services/PlainpostGo/internal/node/sync/runtime.go >/dev/null
grep -F 'swift_stage_log="$temporary/swift-stage.log"' "$owner" >/dev/null
grep -F 'PLAINPOST_SYNC_NODE_STAGE_LOG="$swift_stage_log"' "$owner" >/dev/null
grep -F 'swift_stage_log_bytes' "$owner" >/dev/null
grep -F 'cat "$swift_stage_log"' "$owner" >/dev/null
grep -F 'cat "$temporary/swift.log" >>"$runtime_log"' "$owner" >/dev/null
grep -F 'swift_exit_status=0' "$owner" >/dev/null
grep -F 'swift-exit status=' "$owner" >/dev/null
grep -F 'capture_acceptance_provider_state()' "$owner" >/dev/null
grep -F 'acceptance-provider-state database=unknown outcome=reference-unavailable' "$owner" >/dev/null
grep -F 'ERROR acceptance-provider-state node=node-one' "$owner" >/dev/null
for provider_state_label in mailbox projection_head projection_change_count projection_message_count projection_membership_count generic_sync_mailboxes; do
  grep -F "'ERROR acceptance-provider-state $provider_state_label=" "$owner" >/dev/null
done
if ! awk '
  /compose_run logs --no-color --no-log-prefix --tail 1000/ { logs=NR }
  /capture_acceptance_provider_state$/ { capture=NR }
  /failure_summary_begin/ && logs && capture { summary=NR; exit }
  END { exit !(logs && capture && logs < capture && capture < summary) }
' "$owner"; then
  printf 'acceptance provider state is not captured after container logs and before failure summary\n' >&2
  exit 1
fi
if ! awk '
  /compose_run logs --no-color --no-log-prefix --tail 1000/ { logs=NR }
  /capture_acceptance_provider_state$/ { capture=NR }
  /fixture_restart_failure_summary_begin/ { begin=NR }
  /grep -E.*acceptance-fixture-restart.*tail -80/ { filter=NR }
  /fixture_restart_failure_summary_end/ { end=NR }
  /failure_summary_begin/ && begin { generic=NR }
  END { exit !(logs && capture && begin && filter && end && generic && logs < capture && capture < begin && begin < filter && filter < end && end < generic) }
' "$owner"; then
  printf 'fixture restart summary must retain bounded diagnostics after compose capture and before generic failure output\n' >&2
  exit 1
fi
if ! awk '
  /compose_run logs --no-color --no-log-prefix --tail 1000/ { logs=NR }
  /capture_acceptance_provider_state$/ { capture=NR }
  /provider_failure_summary_begin/ { begin=NR }
  /grep -E.*provider failure.*tail -80/ { filter=NR }
  /provider_failure_summary_end/ { end=NR }
  /fixture_restart_failure_summary_begin/ && begin { fixture=NR }
  /failure_summary_begin/ && begin { generic=NR }
  END { exit !(logs && capture && begin && filter && end && fixture && generic && logs < capture && capture < begin && begin < filter && filter < end && end < fixture && fixture < generic) }
' "$owner"; then
  printf 'provider failure summary must retain bounded diagnostics after compose capture and before generic failure output\n' >&2
  exit 1
fi
grep -F 'filter_summary_patterns "$patterns" | tail -80' "$owner" >/dev/null
grep -F 'grep -F -v -f "$filter_summary_pattern_file"' "$owner" >/dev/null
grep -F 'controller-(child-timeout|descendant-survived|child-reaped)' "$owner" >/dev/null

# Provider failures are retained as a bounded fixed-field summary only. The
# selector must exclude arbitrary slog records and redact matching secrets
# before keeping exactly the newest 80 lines.
provider_failure_summary_contract_root=$(mktemp -d "/tmp/plainpost-provider-failure-summary-contract.XXXXXX")
provider_failure_summary_log="$provider_failure_summary_contract_root/runtime.log"
provider_failure_summary_patterns="$provider_failure_summary_contract_root/patterns"
provider_failure_secret='provider-failure-secret-never-render'
printf '%s\n' "$provider_failure_secret" >"$provider_failure_summary_patterns"
for provider_failure_attempt in $(seq 1 90); do
  printf 'time=2026-08-31T00:00:00Z level=ERROR msg="[DEBUG-sync-node-runtime] provider failure" stage=runtime-provider-failure worker_stage=wait-for-change mailbox_stage=provider-recovery provider_tag=unavailable retry_disposition=safe failure_count=%s\n' \
    "$provider_failure_attempt" >>"$provider_failure_summary_log"
done
printf 'time=2026-08-31T00:00:00Z level=ERROR msg="[DEBUG-sync-node-runtime] provider failure" stage=runtime-provider-failure worker_stage=wait-for-change mailbox_stage=provider-recovery provider_tag=unavailable retry_disposition=safe failure_count=91 secret=%s\n' \
  "$provider_failure_secret" >>"$provider_failure_summary_log"
provider_failure_summary_tail=$(grep -E 'msg="\[DEBUG-sync-node-runtime\] provider failure" stage=runtime-provider-failure worker_stage=(synchronize|wait-for-change) mailbox_stage=provider-recovery provider_tag=[a-z_]+ retry_disposition=(never|safe|reconcile_first) failure_count=[0-9]+$' "$provider_failure_summary_log" | grep -F -v -f "$provider_failure_summary_patterns" | tail -80)
test "$(printf '%s\n' "$provider_failure_summary_tail" | wc -l | tr -d '[:space:]')" = 80
printf '%s\n' "$provider_failure_summary_tail" | head -1 | grep -F 'failure_count=11' >/dev/null
printf '%s\n' "$provider_failure_summary_tail" | tail -1 | grep -F 'failure_count=90' >/dev/null
if printf '%s\n' "$provider_failure_summary_tail" | grep -F "$provider_failure_secret" >/dev/null; then
  printf 'provider failure summary leaked a sensitive matching line\n' >&2
  exit 1
fi
find "$provider_failure_summary_contract_root" -depth -delete

# The fixture helper emits only fixed-vocabulary lifecycle markers. Exercise
# its success, restart-failure, and service-allowlist branches with a fake
# Docker boundary; no credentials or container values enter the output.
marker_contract_root=$(mktemp -d "/tmp/plainpost-fixture-marker-contract.XXXXXX")
mkdir -m 0700 "$marker_contract_root/bin" "$marker_contract_root/control" "$marker_contract_root/mail-fixture" "$marker_contract_root/mail-state" "$marker_contract_root/node-one-secrets"
printf '%s' acceptance-password >"$marker_contract_root/node-one-secrets/provider_password"
chmod 0600 "$marker_contract_root/node-one-secrets/provider_password"
cat >"$marker_contract_root/mail-fixture/plainpost_acceptance_mail_control.py" <<'PY'
import sys
sys.exit(0)
PY
cat >"$marker_contract_root/bin/docker" <<'SH'
#!/bin/sh
: "${FAKE_STATUS_EXEC_LOG:=/dev/null}"
if [ "$1" = compose ]; then
  case " $* " in
    *" ps -q "*) printf '%s\n' fixture-container; exit 0 ;;
    *" restart "*) [ "${FAKE_RESTART_FAILURE:-0}" -eq 0 ]; exit "$?" ;;
  esac
  exit 0
fi
if [ "$1" = inspect ]; then
  printf '%s\n' "${FAKE_INSPECT_STATE:-}"
  exit 0
fi
if [ "$1" = exec ] && [ "$2" = fixture-container ]; then
  [ "$3" = python3 ] && [ "$4" = /opt/plainpost/plainpost_acceptance_mail_control.py ] || exit 91
  [ "$5" = --root ] && [ "$6" = /var/lib/plainpost ] && [ "$7" = status ] || exit 92
  printf '%s\n' exact-container-status-capture >"$FAKE_STATUS_EXEC_LOG"
  printf '%s\n' '{"messages":[],"deliveries":[],"faults":[],"phases":[],"phase_counters":[],"observations":[]}'
  exit 0
fi
if [ "$1" = exec ] && [ "$2" = -i ]; then
  probe_count=0
  if [ -f "$FAKE_PROBE_COUNT" ]; then probe_count=$(cat "$FAKE_PROBE_COUNT"); fi
  probe_count=$((probe_count + 1))
  printf '%s\n' "$probe_count" >"$FAKE_PROBE_COUNT"
  cat >/dev/null
  if [ "${FAKE_PROBE_STARTED:-0}" -eq 1 ]; then printf '%s\n' PLAINPOST_SMTP_PROBE_STARTED; fi
  [ "$probe_count" -gt "${FAKE_PROBE_FAILURES:-0}" ]
  exit "$?"
fi
exit 0
SH
chmod 0700 "$marker_contract_root/bin/docker"
FAKE_PROBE_COUNT="$marker_contract_root/probe.count" FAKE_STATUS_EXEC_LOG="$marker_contract_root/status-exec.log" FAKE_PROBE_FAILURES=1 FAKE_INSPECT_STATE='running|starting|4' \
  PATH="$marker_contract_root/bin:$PATH" \
  "$fixture_restart_helper" "$compose" marker-project "$marker_contract_root" smtp-fixture node-image 1000 1000 \
  s3 /attachments false https://s3.invalid bucket region path-style \
  /tmp/s3-access /tmp/s3-secret "$marker_contract_root/node-one-secrets/provider_password" \
  >"$marker_contract_root/success.log" 2>&1
grep -F 'fixture=smtp-fixture event=container-resolve outcome=ready' "$marker_contract_root/success.log" >/dev/null
grep -F 'fixture=smtp-fixture event=compose-restart outcome=begin' "$marker_contract_root/success.log" >/dev/null
grep -F 'fixture=smtp-fixture event=compose-restart outcome=end' "$marker_contract_root/success.log" >/dev/null
grep -F 'fixture=smtp-fixture event=probe attempt=1 outcome=unavailable' "$marker_contract_root/success.log" >/dev/null
grep -F 'fixture=smtp-fixture event=probe attempt=1 outcome=unavailable class=docker-exec exit=1 state=running health=starting restart_count=4' "$marker_contract_root/success.log" >/dev/null
grep -F 'fixture=smtp-fixture event=probe attempt=2 outcome=ready' "$marker_contract_root/success.log" >/dev/null
grep -F 'fixture=smtp-fixture event=status-capture outcome=begin' "$marker_contract_root/success.log" >/dev/null
grep -F 'fixture=smtp-fixture event=status-capture outcome=end' "$marker_contract_root/success.log" >/dev/null
grep -F 'exact-container-status-capture' "$marker_contract_root/status-exec.log" >/dev/null
if ! awk '
  /event=container-resolve outcome=ready/ { resolve=NR }
  /event=compose-restart outcome=begin/ { restart_begin=NR }
  /event=compose-restart outcome=end/ { restart_end=NR }
  /event=probe attempt=1 outcome=unavailable/ { probe_unavailable=NR }
  /event=probe attempt=2 outcome=ready/ { probe_ready=NR }
  /event=status-capture outcome=begin/ { status_begin=NR }
  /event=status-capture outcome=end/ { status_end=NR }
  END { exit !(resolve < restart_begin && restart_begin < restart_end && restart_end < probe_unavailable && probe_unavailable < probe_ready && probe_ready < status_begin && status_begin < status_end) }
' "$marker_contract_root/success.log"; then
  printf 'fixture helper success markers are out of order\n' >&2
  exit 1
fi
if grep -F 'acceptance-password' "$marker_contract_root/success.log" >/dev/null; then
  printf 'fixture helper success markers leaked a credential\n' >&2
  exit 1
fi
if FAKE_RESTART_FAILURE=1 FAKE_PROBE_COUNT="$marker_contract_root/failure.count" \
  PATH="$marker_contract_root/bin:$PATH" \
  "$fixture_restart_helper" "$compose" marker-project "$marker_contract_root" smtp-fixture node-image 1000 1000 \
  s3 /attachments false https://s3.invalid bucket region path-style \
  /tmp/s3-access /tmp/s3-secret "$marker_contract_root/node-one-secrets/provider_password" \
  >"$marker_contract_root/failure.log" 2>&1; then
  printf 'fixture helper restart-failure branch unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'fixture=smtp-fixture event=compose-restart outcome=begin' "$marker_contract_root/failure.log" >/dev/null
grep -F 'fixture=smtp-fixture event=compose-restart outcome=failed' "$marker_contract_root/failure.log" >/dev/null
if ! awk '
  /event=compose-restart outcome=begin/ { begin=NR }
  /event=compose-restart outcome=failed/ { failed=NR }
  END { exit !(begin && failed && begin < failed) }
' "$marker_contract_root/failure.log"; then
  printf 'fixture helper restart-failure markers are out of order\n' >&2
  exit 1
fi
if grep -F 'acceptance-password' "$marker_contract_root/failure.log" >/dev/null; then
  printf 'fixture helper restart-failure markers leaked a credential\n' >&2
  exit 1
fi
if grep -F 'event=probe ' "$marker_contract_root/failure.log" >/dev/null || grep -F 'event=status-capture ' "$marker_contract_root/failure.log" >/dev/null; then
  printf 'fixture helper emitted post-restart markers after restart failure\n' >&2
  exit 1
fi

# A started probe that exits with an unmapped status is distinct from Docker
# failing to execute the probe. Keep only the fixed sentinel and numeric exit.
FAKE_PROBE_COUNT="$marker_contract_root/python.count" FAKE_PROBE_FAILURES=1 FAKE_PROBE_STARTED=1 \
  PATH="$marker_contract_root/bin:$PATH" \
  "$fixture_restart_helper" "$compose" marker-project "$marker_contract_root" smtp-fixture node-image 1000 1000 \
  s3 /attachments false https://s3.invalid bucket region path-style \
  /tmp/s3-access /tmp/s3-secret "$marker_contract_root/node-one-secrets/provider_password" \
  >"$marker_contract_root/python.log" 2>&1
grep -F 'fixture=smtp-fixture event=probe attempt=1 outcome=unavailable class=python-exit exit=1' "$marker_contract_root/python.log" >/dev/null

if PATH="$marker_contract_root/bin:$PATH" \
  "$fixture_restart_helper" "$compose" marker-project "$marker_contract_root" untrusted-fixture node-image 1000 1000 \
  s3 /attachments false https://s3.invalid bucket region path-style \
  /tmp/s3-access /tmp/s3-secret "$marker_contract_root/node-one-secrets/provider_password" \
  >"$marker_contract_root/invalid.log" 2>&1; then
  printf 'fixture helper accepted an untrusted service vocabulary\n' >&2
  exit 1
fi
test ! -s "$marker_contract_root/invalid.log"
find "$marker_contract_root" -depth -delete

# Bound the production-equivalent summary selector after privacy filtering:
# retain the newest 80 safe lifecycle records and all restart failure classes.
summary_contract_root=$(mktemp -d "/tmp/plainpost-fixture-summary-contract.XXXXXX")
summary_log="$summary_contract_root/runtime.log"
summary_patterns="$summary_contract_root/patterns"
summary_secret='fixture-summary-secret-never-render'
printf '%s\n' "$summary_secret" >"$summary_patterns"
for summary_attempt in $(seq 1 90); do
  printf 'ERROR acceptance-fixture-restart fixture=smtp-fixture event=probe attempt=%s outcome=unavailable\n' "$summary_attempt" >>"$summary_log"
done
printf 'ERROR acceptance-fixture-restart fixture=smtp-fixture event=probe attempt=91 outcome=unavailable secret=%s\n' "$summary_secret" >>"$summary_log"
printf '%s\n' 'ERROR controller-child-timeout action=restart-smtp-fixture timeout_seconds=20' >>"$summary_log"
printf '%s\n' 'ERROR controller-descendant-survived action=restart-smtp-fixture' >>"$summary_log"
printf '%s\n' 'ERROR controller-child-reaped action=restart-smtp-fixture status=124' >>"$summary_log"
printf '%s\n' 'ERROR acceptance-fixture-restart fixture=smtp-fixture event=crash-classification exit_code=1 oom=false cause=python-value-error' >>"$summary_log"
printf '%s\n' 'ERROR acceptance-fixture-restart fixture=smtp-fixture event=crash-classification exit_code=1 oom=false cause=custom-private-class' >>"$summary_log"
printf '%s\n' "$fixture_crash_sqlite_record" >>"$summary_log"
summary_tail=$(grep -E '^(ERROR acceptance-fixture-restart fixture=(imap-fixture|smtp-fixture) event=(container-resolve|compose-restart|probe|status-capture)( |$)|ERROR acceptance-fixture-restart fixture=(imap-fixture|smtp-fixture) event=crash-classification exit_code=[0-9]+ oom=(true|false) (cause=(sqlite-busy-locked|sqlite-schema|bind-address|signal|python-runtime-error|python-value-error|python-os-error|python-ssl-error|python-exception|unknown)( |$)|cause=sqlite-operational sqlite_subcategory=(locked|open|disk-io|schema|readonly|corrupt|other|none) sqlite_operation=(wal-open|transaction|schema-migration|schema-create|projection-repair|read|other|none)( |$))|ERROR controller-(child-timeout|descendant-survived|child-reaped) action=restart-(imap-fixture|smtp-fixture)( |$))' "$summary_log" | grep -F -v -f "$summary_patterns" | tail -80)
test "$(printf '%s\n' "$summary_tail" | wc -l | tr -d '[:space:]')" = 80
printf '%s\n' "$summary_tail" | head -1 | grep -F 'attempt=16' >/dev/null
printf '%s\n' "$summary_tail" | grep -F 'attempt=90' >/dev/null
printf '%s\n' "$summary_tail" | grep -F 'controller-child-timeout action=restart-smtp-fixture' >/dev/null
printf '%s\n' "$summary_tail" | grep -F 'controller-descendant-survived action=restart-smtp-fixture' >/dev/null
printf '%s\n' "$summary_tail" | grep -F 'controller-child-reaped action=restart-smtp-fixture' >/dev/null
printf '%s\n' "$summary_tail" | grep -F 'event=crash-classification exit_code=1 oom=false cause=python-value-error' >/dev/null
printf '%s\n' "$summary_tail" | grep -F 'event=crash-classification exit_code=1 oom=false cause=sqlite-operational sqlite_subcategory=locked sqlite_operation=transaction' >/dev/null
if printf '%s\n' "$summary_tail" | grep -F "$summary_secret" >/dev/null; then
  printf 'fixture restart summary leaked a sensitive matching line\n' >&2
  exit 1
fi
if printf '%s\n' "$summary_tail" | grep -F 'cause=custom-private-class' >/dev/null; then
  printf 'fixture restart summary accepted an untrusted crash cause\n' >&2
  exit 1
fi
find "$summary_contract_root" -depth -delete

# Execute the owner's real top-level and control-loop signal handlers. Each
# signal has its conventional status and must not collapse HUP into INT.
owner_signal_contract_root=$(mktemp -d "/tmp/plainpost-owner-signal-contract.XXXXXX")
owner_signal_harness="$owner_signal_contract_root/harness.sh"
{
  printf '%s\n' '#!/bin/sh' 'set -eu' 'finish() { exit "$1"; }' 'stop_controller_child() { :; }'
  awk '/^on_signal\(\)/,/^}/' "$owner"
  awk '/^controller_interrupted\(\)/,/^}/' "$owner"
  grep -m1 -F "trap 'on_signal 129' HUP" "$owner"
  grep -m1 -F "trap 'on_signal 130' INT" "$owner"
  grep -m1 -F "trap 'on_signal 143' TERM" "$owner"
  grep -m1 -F "trap 'controller_interrupted 129' HUP" "$owner"
  grep -m1 -F "trap 'controller_interrupted 130' INT" "$owner"
  grep -m1 -F "trap 'controller_interrupted 143' TERM" "$owner"
  cat <<'SH'
mode=$1
signal_name=$2
if [ "$mode" = owner ]; then
  trap 'on_signal 129' HUP
  trap 'on_signal 130' INT
  trap 'on_signal 143' TERM
else
  trap 'controller_interrupted 129' HUP
  trap 'controller_interrupted 130' INT
  trap 'controller_interrupted 143' TERM
fi
(sleep 0.1; kill -"$signal_name" "$$") &
while :; do sleep 1; done
SH
} >"$owner_signal_harness"
chmod 0700 "$owner_signal_harness"
for owner_signal_mode in owner control; do
  for owner_signal_name in HUP INT TERM; do
    owner_signal_status=0
    "$owner_signal_harness" "$owner_signal_mode" "$owner_signal_name" || owner_signal_status=$?
    owner_signal_expected=129
    [ "$owner_signal_name" = INT ] && owner_signal_expected=130
    [ "$owner_signal_name" = TERM ] && owner_signal_expected=143
    [ "$owner_signal_status" -eq "$owner_signal_expected" ] || {
      printf '%s %s returned %s, expected %s\n' "$owner_signal_mode" "$owner_signal_name" "$owner_signal_status" "$owner_signal_expected" >&2
      exit 1
    }
  done
done
find "$owner_signal_contract_root" -depth -delete

grep -F -- '--connect-to "$readiness_hostname:18443:127.0.0.1:$readiness_port"' "$owner" >/dev/null
grep -F 'readiness_path=${4:-readyz}' "$owner" >/dev/null
grep -F '"https://$readiness_hostname:18443/$readiness_path"' "$owner" >/dev/null
grep -F 'wait_for_node_one_ready after-restart-2' "$owner" >/dev/null
grep -F 'wait_for_node_one_ready control-restart' "$owner" >/dev/null
grep -F 'wait_for_node_two_ready after-restart-2' "$owner" >/dev/null
test -x "$attachment_storage_contract"
"$attachment_storage_contract" >/dev/null
test -x "$backup_restore_contract"
"$backup_restore_contract" >/dev/null
grep -F 'sync-node-acceptance-seed' "$compose" >/dev/null
grep -F 'Task7PrivacyAuditCategory' "$acceptance_seed_main" >/dev/null
grep -F 'Task7PrivacyAuditReason' "$acceptance_seed_main" >/dev/null
for catalog_probe_service in sync-node-acceptance-seed sync-node-acceptance-seed-node-two; do
  if ! awk -v service="$catalog_probe_service" '
    $0 == "  " service ":" { active = 1; next }
    active && /^  [A-Za-z0-9_-]+:/ { exit !(certificate && ca_mount) }
    active && /SSL_CERT_FILE: \/run\/public\/ca.crt/ { certificate = 1 }
    active && /ca\.crt:\/run\/public\/ca.crt:ro/ { ca_mount = 1 }
    END { exit !(certificate && ca_mount) }
  ' "$compose"; then
    printf '%s must use the acceptance PostgreSQL CA for production provider TLS probes\n' "$catalog_probe_service" >&2
    exit 1
  fi
done
if grep -F 'discover-catalog' "$acceptance_seed_main" "$root/Services/PlainpostGo/internal/acceptance/sync_node_provider.go" "$owner" >/dev/null; then
	printf 'catalog discovery must not mutate the durable acceptance seed profile\n' >&2
	exit 1
fi
grep -F 'probeCatalog := flag.Bool("probe-catalog"' "$acceptance_seed_main" >/dev/null
grep -F 'expectCatalogError := flag.String("expect-catalog-error"' "$acceptance_seed_main" >/dev/null
grep -F 'ProbeSyncNodeAcceptanceCatalog' "$acceptance_seed_main" >/dev/null
grep -F 'ValidateAcceptanceCatalog' "$acceptance_seed_main" >/dev/null
grep -F 'catalogProbeProviderConfig' "$root/Services/PlainpostGo/internal/acceptance/sync_node_provider.go" >/dev/null
grep -F 'imap_matrix_catalog_probe_request' "$owner" >/dev/null
grep -F 'run_catalog_probe unavailable' "$owner" >/dev/null
grep -F 'probeFetch := flag.Bool("probe-fetch"' "$acceptance_seed_main" >/dev/null
grep -F 'fetchPhase := flag.String("fetch-phase"' "$acceptance_seed_main" >/dev/null
grep -F 'expectFetchError := flag.String("expect-fetch-error"' "$acceptance_seed_main" >/dev/null
grep -F 'ProbeSyncNodeAcceptanceFetch' "$acceptance_seed_main" "$root/Services/PlainpostGo/internal/acceptance/sync_node_provider.go" >/dev/null
grep -F 'imap_matrix_fetch_probe_request' "$owner" >/dev/null
grep -F 'run_fetch_probe unavailable' "$owner" >/dev/null
grep -F 'if ! run_fetch_probe' "$owner" >/dev/null
if grep -F 'imap-header-fetch) imap_matrix_fault=imap-header-fetch' "$owner" >/dev/null ||
   grep -F 'imap-body-fetch) imap_matrix_fault=imap-body-fetch' "$owner" >/dev/null; then
  printf 'header/body disconnect faults must not be armed before Node readiness\n' >&2
  exit 1
fi
grep -F 'run_catalog_probe '\'''\''' "$owner" >/dev/null

# Release/source selection is one configuration authority. Repeated switches
# drift easily when the owner grows; later stages must consume the selected
# service/database properties instead of branching on the mode again.
release_mode_switches=$(grep -Ec 'if \[ "\$release_mode"' "$owner" || true)
[ "$release_mode_switches" -le 1 ] || {
	printf 'private transport repeats release/source mode switches (%s)\n' "$release_mode_switches" >&2
	exit 1
}
grep -F 'transport_mode=' "$owner" >/dev/null || {
	printf 'private transport lacks centralized transport mode configuration\n' >&2
	exit 1
}

# Task 10 must retain bounded release evidence for both PostgreSQL server and
# packaged clients, plus each current migration authority. A generic health
# check or a source-only assertion is not sufficient evidence.
for required in \
	'release_server_version=' 'release_dump_client_version=' 'release_restore_client_version=' \
	'release_central_account_head=' 'release_central_deletion_journal_head=' 'release_node_migration_head=' \
	'release-postgres-client-versions=' 'release-migration-heads='; do
	grep -F -- "$required" "$owner" >/dev/null || {
		printf 'private transport lacks PostgreSQL 18 release evidence %s\n' "$required" >&2
		exit 1
	}
done

# The release privacy stage must consume file-backed authenticated URLs for
# the primary and isolated replacement databases. Credentials never appear in
# Compose argv or the parent environment.
release_compose="$root/Deploy/acceptance/compose.release-images.yaml"
test -x "$release_override_writer"
for required in '-account-database-file' '/run/secrets/central-database-url' \
	'-node-one-database-file' '/run/secrets/node-database-url' \
	'-node-two-database-file' '/run/secrets/node-two-database-url'; do
	grep -F -- "$required" "$release_compose" >/dev/null || {
		printf 'release privacy audit lacks file-backed database input %s\n' "$required" >&2
		exit 1
	}
done
for required in 'postgres://plainpost_central:' 'postgres://plainpost_sync_node:' \
	'postgres-node-two' 'sslmode=verify-full&sslrootcert='; do
	grep -F -- "$required" "$owner" >/dev/null || {
		printf 'release owner lacks authenticated verified database target %s\n' "$required" >&2
		exit 1
	}
done
if grep -Eq 'PLAINPOST_RELEASE_(CENTRAL|NODE)_DB_PASSWORD=' "$owner"; then
	printf 'release owner passes database passwords through Compose environment\n' >&2
	exit 1
fi
grep -F 'scan_privacy_file "$privacy_audit_output" container-log' "$owner" >/dev/null || {
	printf 'release owner does not scan ephemeral privacy-audit output\n' >&2
	exit 1
}
for required in 'privacy_audit_container=' \
	'run --name "$privacy_audit_container" privacy-audit' \
	'docker inspect "$privacy_audit_container"' \
	'privacy-audit-container-inspect.json' \
	'docker rm "$privacy_audit_container"'; do
	grep -F -- "$required" "$owner" >/dev/null || {
		printf 'release privacy audit lacks ephemeral container inspection/cleanup %s\n' "$required" >&2
		exit 1
	}
done
if grep -F -- 'run --rm privacy-audit' "$owner" >/dev/null; then
	printf 'release privacy audit removes its container before inspection\n' >&2
	exit 1
fi

# Render the active release merge and inspect effective values, proving the
# base acceptance trust/raw settings cannot survive the release override.
release_render_root=$(mktemp -d /tmp/plainpost-release-postgres-render.XXXXXX)
release_render_override="$release_render_root/private-transport.release.override.yaml"
PLAINPOST_PRIVATE_ROOT="$release_render_root" bash "$release_override_writer" "$release_render_override"
release_rendered="$release_render_root/compose.json"
if ! PLAINPOST_PRIVATE_ROOT="$release_render_root" \
	PLAINPOST_RELEASE_CENTRAL_IMAGE='registry.local/plainpost-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
	PLAINPOST_RELEASE_NODE_IMAGE='registry.local/plainpost-node@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
	PLAINPOST_PRIVATE_NODE_IMAGE='registry.local/plainpost-node@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
	docker compose --profile privacy -f "$compose" -f "$release_render_override" config --format json >"$release_rendered"; then
	find "$release_render_root" -depth -delete
	printf 'release private-transport Compose merge failed\n' >&2
	exit 1
fi
if ! jq -e '
	.services.central.environment.PLAINPOST_ENV == "acceptance" and
	.services.central.environment.PLAINPOST_ACCEPTANCE_FILE_SECRET_AUTHORITY == "enabled" and
	.services.central.environment.PLAINPOST_DATABASE_URL == "" and
	.services.central.environment.PLAINPOST_DELETION_JOURNAL_DATABASE_URL == "" and
	.services.central.environment.PLAINPOST_RATE_LIMIT_PEPPER == "" and
	.services.central.environment.PLAINPOST_DATABASE_URL_FILE == "/run/secrets/central-database-url" and
	.services.central.environment.PLAINPOST_DELETION_JOURNAL_DATABASE_URL_FILE == "/run/secrets/central-deletion-journal-database-url" and
	.services.central.environment.PLAINPOST_RATE_LIMIT_PEPPER_FILE == "/run/secrets/rate-limit-pepper" and
	.services.postgres.environment.POSTGRES_HOST_AUTH_METHOD == "scram-sha-256" and
	.services["postgres-node-two"].environment.POSTGRES_HOST_AUTH_METHOD == "scram-sha-256" and
	([.services["privacy-audit"].command[]] | index("-account-database-file") != null) and
	([.services["privacy-audit"].command[]] | index("-node-one-database-file") != null) and
	([.services["privacy-audit"].command[]] | index("-node-two-database-file") != null) and
	(([.services["privacy-audit"].command[]] | any(test("^postgres://"))) | not) and
	([.services["privacy-audit"].volumes[].target] | index("/run/central-secrets") != null) and
	([.services["privacy-audit"].volumes[].target] | index("/run/node-one-secrets") != null) and
	([.services["privacy-audit"].volumes[].target] | index("/run/node-two-secrets") != null) and
	([.services["privacy-audit"].volumes[].target] | index("/run/plainpost-public/postgres-ca.pem") != null)
' "$release_rendered" >/dev/null; then
	find "$release_render_root" -depth -delete
	printf 'release private-transport Compose merge retained raw URL or trust auth\n' >&2
	exit 1
fi
find "$release_render_root" -depth -delete
test -x "$task7_category_contract"
test -x "$task7_category_helper"
grep -F '. "$task7_privacy_audit_category_helper"' "$owner" >/dev/null
grep -F 'task7_privacy_audit_category_from_output' "$owner" >/dev/null
grep -F 'task7_privacy_audit_node_failure_from_output' "$owner" >/dev/null
if ! "$task7_category_contract" >/dev/null; then
  printf 'Task 7 category propagation contract probe failed\n' >&2
  exit 1
fi
task7_category_root=$(mktemp -d "${TMPDIR:-/tmp}/plainpost-task7-category-contract.XXXXXX")
task7_category_probe="$task7_category_root/output"
task7_category_go_cache="$task7_category_root/go-cache"
cleanup_task7_category_probe() {
  find "$task7_category_root" -depth -delete >/dev/null 2>&1 || true
}
trap cleanup_task7_category_probe EXIT
mkdir -m 0700 "$task7_category_go_cache"
: >"$task7_category_probe"
chmod 0600 "$task7_category_probe"
if (cd "$root/Services/PlainpostGo" && GOCACHE="$task7_category_go_cache" go run ./cmd/plainpost-sync-node-acceptance-seed -audit-task-7-private-transport >"$task7_category_probe" 2>&1); then
  printf 'Task 7 category CLI unexpectedly succeeded without audit inputs\n' >&2
  exit 1
fi
if [ "$(sed -n '1p' "$task7_category_probe")" != 'sync node Task 7 privacy audit unavailable category=inputs subcategory=database-argument-mode' ]; then
  printf 'Task 7 category CLI did not publish the fixed input category\n' >&2
  exit 1
fi
if grep -Eiq 'plainpost-acceptance-v1|fixture-account|identityToken|appleSubject|refreshCredential|offlineLease|privateKey|keyMaterial|accountMatchingKey|metadataKey|rawNonce|decryptedMetadata|mcpCredential|session-signing-2026|plainpost-root-prod' "$task7_category_probe"; then
  printf 'Task 7 category CLI published forbidden private material\n' >&2
  exit 1
fi
grep -F -- '-node-database-file /run/secrets/database_url' "$owner" >/dev/null
grep -F -- '-provider-password /run/secrets/provider_password' "$owner" >/dev/null
grep -F 'generic_profile JSONB' Services/PlainpostGo/internal/node/postgres/migrations/0021_generic_provider_sessions.sql >/dev/null
if grep -F -- '-node-database "' "$owner" >/dev/null || grep -F -- 'database_url=$(sed' "$owner" >/dev/null; then
  printf 'provider seed exposes the database authority in argv\n' >&2
  exit 1
fi
cleanup_probe_log=$(mktemp "${TMPDIR:-/tmp}/plainpost-process-cleanup-contract.XXXXXX")
chmod 0600 "$cleanup_probe_log"
cleanup_probe_iteration=1
while [ "$cleanup_probe_iteration" -le 5 ]; do
  if ! PLAINPOST_SYNC_NODE_PROCESS_CLEANUP_TEST=enabled "$owner" >"$cleanup_probe_log" 2>&1; then
    cat "$cleanup_probe_log" >&2 || true
    rm -f "$cleanup_probe_log"
    printf 'owned process cleanup probe failed at iteration %s\n' "$cleanup_probe_iteration" >&2
    exit 1
  fi
  grep -F 'process-cleanup-test=passed' "$cleanup_probe_log" >/dev/null
  grep -F 'process-cleanup-leader-exit-test=passed' "$cleanup_probe_log" >/dev/null
  grep -F 'process-cleanup-success-path-test=passed' "$cleanup_probe_log" >/dev/null
  cleanup_probe_iteration=$((cleanup_probe_iteration + 1))
done
rm -f "$cleanup_probe_log"

# A normal child exit must not leave the owner waiting forever for a
# reparented descendant.  This is a real executable probe of the supervisor,
# not a source-shape assertion: the child forks a detached helper, exits, and
# the supervisor must terminate that exact remembered process and return a
# bounded lifecycle failure.
supervisor_orphan_probe_status=0
supervisor_orphan_probe_output=$(python3 - "$process_supervisor" <<'PY' 2>&1
import os
import signal
import subprocess
import sys
import tempfile

supervisor = os.path.abspath(sys.argv[1])
probe_root = tempfile.mkdtemp(prefix="plainpost-supervisor-orphan-")
pid_path = os.path.join(probe_root, "orphan.pid")
child_code = (
    "import os,sys,time; "
    "pid=os.fork(); "
    "(time.sleep(1),os._exit(0)) if pid else "
    "(os.setsid(),open(sys.argv[1],'w').write(str(os.getpid())),time.sleep(30))"
)
process = subprocess.Popen([
    sys.executable, supervisor, "--", sys.executable, "-c", child_code, pid_path
])
status = None
try:
    status = process.wait(timeout=8)
except subprocess.TimeoutExpired:
    process.kill()
    process.wait()
    if os.path.exists(pid_path):
        try:
            os.kill(int(open(pid_path, encoding="ascii").read()), signal.SIGKILL)
        except (OSError, ValueError):
            pass
    raise SystemExit("supervisor retained a reparented child past its bounded exit")
finally:
    if os.path.exists(pid_path):
        try:
            os.kill(int(open(pid_path, encoding="ascii").read()), signal.SIGKILL)
        except (OSError, ValueError):
            pass
    try:
        os.unlink(pid_path)
    except OSError:
        pass
    try:
        os.rmdir(probe_root)
    except OSError:
        pass
if status != 125:
    raise SystemExit(f"supervisor orphan lifecycle status was {status}, want 125")
print("supervisor-orphan-probe=passed")
PY
) || supervisor_orphan_probe_status=$?
if [ "$supervisor_orphan_probe_status" -ne 0 ]; then
  printf '%s\n' "$supervisor_orphan_probe_output" >&2
  printf 'supervisor orphan lifecycle probe failed\n' >&2
  exit 1
fi
printf '%s\n' "$supervisor_orphan_probe_output"
privacy_probe_log=$(mktemp "${TMPDIR:-/tmp}/plainpost-privacy-failure-contract.XXXXXX")
chmod 0600 "$privacy_probe_log"
if ! PLAINPOST_SYNC_NODE_PRIVACY_FAILURE_TEST=enabled "$owner" >"$privacy_probe_log" 2>&1; then
  cat "$privacy_probe_log" >&2 || true
  rm -f "$privacy_probe_log"
  printf 'forced early-failure privacy probe failed\n' >&2
  exit 1
fi
grep -F 'privacy-failure-test=passed' "$privacy_probe_log" >/dev/null
rm -f "$privacy_probe_log"
printf 'sync_node_private_transport_postgres_contract=passed\n'
