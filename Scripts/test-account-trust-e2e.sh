#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compose="$root/Deploy/acceptance/compose.yaml"
. "$root/Scripts/acceptance-network.sh"
project="plainpost-account-e2e-$$"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/plainpost-account-e2e.XXXXXX")
umask 077
log="$temporary/compose.log"
evidence="$temporary/evidence.json"
rendered_config="$temporary/compose-config.yaml"
privacy_patterns="$temporary/privacy-patterns"
sync_node_privacy_patterns="$temporary/sync-node-privacy-patterns"
returned_privacy_patterns="$temporary/sync-node-returned-privacy-patterns"
returned_database_privacy_patterns="$temporary/sync-node-returned-database-privacy-patterns"
private_http_sinks="$temporary/sync-node-private-http-sinks"
swift_acceptance_filter='PlainpostAccountRuntimeTests.SyncNodeEnrollmentLiveAcceptanceTests/testSwiftApprovalClientExercisesLiveCentralEnrollmentReplayAndReplacement'
retain=${PLAINPOST_ACCEPTANCE_RETAIN_FAILED:-0}
timeout_seconds=${PLAINPOST_ACCEPTANCE_TIMEOUT_SECONDS:-300}
status=1
watchdog_pid=
compose_cleanup_eligible=0

case "$timeout_seconds" in
  ''|*[!0-9]*)
    printf 'PLAINPOST_ACCEPTANCE_TIMEOUT_SECONDS must be a positive integer\n' >&2
    exit 2
    ;;
esac
if [ "$timeout_seconds" -lt 1 ]; then
  printf 'PLAINPOST_ACCEPTANCE_TIMEOUT_SECONDS must be a positive integer\n' >&2
  exit 2
fi

cleanup() {
  if [ -n "$watchdog_pid" ]; then
    kill "$watchdog_pid" >/dev/null 2>&1 || true
  fi
  if [ "$compose_cleanup_eligible" -eq 1 ] && { [ "$status" -eq 0 ] || [ "$retain" != 1 ]; }; then
    docker compose -p "$project" -f "$compose" down --volumes --remove-orphans >/dev/null 2>&1 || true
  else
    printf 'retained Compose project: %s\n' "$project" >&2
    printf 'cleanup: docker compose -p %s -f %s down --volumes --remove-orphans\n' "$project" "$compose" >&2
  fi
  if [ "$status" -ne 0 ] && [ "$retain" = 1 ]; then
    printf 'retained private diagnostics: %s\n' "$temporary" >&2
  else
    rm -rf "$temporary"
  fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

if ! env -u PLAINPOST_SYNC_NODE_ACCEPTANCE "$root/Scripts/swift-test-isolated.sh" --filter "$swift_acceptance_filter" >>"$log" 2>&1; then
  printf 'Swift Sync Node public-HTTP acceptance test build failed; raw service logs suppressed by privacy policy\n' >&2
  exit 1
fi
compose_cleanup_eligible=1
docker compose -p "$project" -f "$compose" config >"$rendered_config"
docker compose -p "$project" -f "$compose" up --build -d >"$log" 2>&1
(
  sleep "$timeout_seconds"
  : >"$temporary/timed-out"
  docker compose -p "$project" -f "$compose" down --volumes --remove-orphans >/dev/null 2>&1 || true
) &
watchdog_pid=$!

if ! docker compose -p "$project" -f "$compose" wait account-e2e >>"$log" 2>&1; then
  kill "$watchdog_pid" >/dev/null 2>&1 || true
  watchdog_pid=
  phase=account-e2e
  [ -f "$temporary/timed-out" ] && phase=deadline
  printf 'acceptance Compose run failed; phase=%s; raw service logs suppressed by privacy policy\n' "$phase" >&2
  docker compose -p "$project" -f "$compose" ps --format '{{.Service}} state={{.State}} exit={{.ExitCode}} health={{.Health}}' >&2 2>/dev/null || true
  if [ -f "$temporary/timed-out" ]; then
    printf 'acceptance exceeded %s-second deadline\n' "$timeout_seconds" >&2
  fi
  exit 1
fi
docker compose -p "$project" -f "$compose" cp account-e2e:/output/evidence.json "$evidence" >/dev/null
docker compose -p "$project" -f "$compose" cp account-e2e:/output/privacy-patterns "$privacy_patterns" >/dev/null
acceptance_base_url=http://127.0.0.1:18080
if ! acceptance_http_ready "http://127.0.0.1:18080/healthz"; then
  api_container=$(docker compose -p "$project" -f "$compose" ps -q plainpost-api 2>>"$log")
  if [ -z "$api_container" ]; then
    printf 'acceptance API container resolution failed\n' >&2
    exit 1
  fi
  api_ip=$(docker inspect --format "{{with index .NetworkSettings.Networks \"${project}_acceptance\"}}{{.IPAddress}}{{end}}" "$api_container" 2>>"$log")
  if ! acceptance_is_private_ipv4 "$api_ip"; then
    printf 'acceptance API private endpoint validation failed\n' >&2
    exit 1
  fi
  if ! acceptance_tcp_ready "$api_ip" 8080; then
    printf 'acceptance API private TCP readiness failed\n' >&2
    exit 1
  fi
  acceptance_base_url="http://$api_ip:8080"
  if ! acceptance_http_ready "$acceptance_base_url/healthz"; then
    printf 'acceptance API private HTTP readiness failed\n' >&2
    exit 1
  fi
  printf 'acceptance API using validated private-container fallback\n'
fi
if ! docker compose -p "$project" -f "$compose" --profile acceptance-live run --rm sync-node-acceptance-seed -privacy-patterns /output/sync-node-privacy-patterns >>"$log" 2>&1; then
	printf 'sync node acceptance claim seed failed; raw service logs suppressed by privacy policy\n' >&2
	exit 1
fi
docker compose -p "$project" -f "$compose" cp account-e2e:/output/sync-node-privacy-patterns "$sync_node_privacy_patterns" >/dev/null
if ! PLAINPOST_SYNC_NODE_ACCEPTANCE=enabled PLAINPOST_SYNC_NODE_ACCEPTANCE_BASE_URL="$acceptance_base_url" PLAINPOST_SYNC_NODE_RETURNED_PRIVACY_PATTERNS="$returned_privacy_patterns" PLAINPOST_SYNC_NODE_RETURNED_DATABASE_PRIVACY_PATTERNS="$returned_database_privacy_patterns" PLAINPOST_SYNC_NODE_PRIVATE_HTTP_SINKS="$private_http_sinks" "$root/Scripts/swift-test-isolated.sh" --skip-build --filter "$swift_acceptance_filter" >>"$log" 2>&1; then
	printf 'Swift Sync Node public-HTTP acceptance failed; raw service logs suppressed by privacy policy\n' >&2
	exit 1
fi
if [ ! -s "$returned_database_privacy_patterns" ]; then
  printf 'Swift Sync Node returned database privacy patterns missing\n' >&2
  exit 1
fi
if ! docker compose -p "$project" -f "$compose" --profile acceptance-live run --rm -T sync-node-acceptance-seed -import-returned-privacy-patterns /output/sync-node-returned-database-privacy-patterns <"$returned_database_privacy_patterns" >>"$log" 2>&1; then
  printf 'Swift Sync Node returned database privacy pattern import failed\n' >&2
  exit 1
fi
if ! docker compose -p "$project" -f "$compose" --profile acceptance-live run --rm sync-node-acceptance-audit >>"$log" 2>&1; then
  printf 'sync node acceptance privacy/catalog audit failed; raw service logs suppressed by privacy policy\n' >&2
  exit 1
fi
if ! docker compose -p "$project" -f "$compose" logs --no-color --no-log-prefix --tail 500 plainpost-api account-db deletion-journal-db account-e2e >>"$log" 2>&1; then
  printf 'acceptance runtime log collection failed; raw service logs suppressed by privacy policy\n' >&2
  exit 1
fi
kill "$watchdog_pid" >/dev/null 2>&1 || true
wait "$watchdog_pid" >/dev/null 2>&1 || true
watchdog_pid=
grep -q '"status": "passed"' "$evidence"
if [ ! -s "$returned_privacy_patterns" ]; then
  printf 'Swift Sync Node returned-value privacy patterns missing\n' >&2
  exit 1
fi
if [ ! -s "$private_http_sinks" ]; then
  printf 'Swift Sync Node private HTTP error-body evidence missing\n' >&2
  exit 1
fi
if grep -F -f "$privacy_patterns" -f "$sync_node_privacy_patterns" -f "$returned_privacy_patterns" "$log" "$evidence" "$rendered_config" "$private_http_sinks" >/dev/null 2>&1; then
  printf 'acceptance privacy scan found actual issued private material\n' >&2
  exit 1
fi
if grep -Eiq 'plainpost-acceptance-v1|fixture-account|identityToken|appleSubject|refreshCredential|offlineLease|privateKey|keyMaterial|accountMatchingKey|metadataKey|rawNonce|decryptedMetadata|mcpCredential|session-signing-2026|plainpost-root-prod' "$log" "$evidence" "$rendered_config" "$private_http_sinks"; then
  printf 'acceptance privacy scan found a forbidden secret-shaped value\n' >&2
  exit 1
fi
mkdir -p "$root/docs/verification"
published="$root/docs/verification/.account-trust-milestone.latest.json.tmp"
cp "$evidence" "$published"
mv "$published" "$root/docs/verification/account-trust-milestone.latest.json"
status=0
printf 'Plainpost account acceptance infrastructure passed (%s)\n' "$project"
