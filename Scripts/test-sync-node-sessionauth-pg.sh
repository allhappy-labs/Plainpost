#!/usr/bin/env bash
set -euo pipefail

container="plainpost-sync-node-task5-pg-$$"
port="55439"
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker run --rm -d --name "$container" -e POSTGRES_USER=plainpost -e POSTGRES_PASSWORD=plainpost-test-only -e POSTGRES_DB=plainpost -p "127.0.0.1:${port}:5432" postgres:18.6-alpine3.24@sha256:d3e1620b530c944afa6e887d22eb899824da68e19c52024bf98f5220c88a65b2 >/dev/null
for _ in $(seq 1 30); do
  if docker exec "$container" pg_isready -U plainpost -d plainpost >/dev/null; then
    break
  fi
  sleep 1
done
docker exec "$container" pg_isready -U plainpost -d plainpost >/dev/null

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/Services/PlainpostGo"
TEST_POSTGRES_URL="postgres://plainpost:plainpost-test-only@127.0.0.1:${port}/plainpost?sslmode=disable" \
  PLAINPOST_REQUIRE_LIVE_POSTGRES=1 \
  go test -race ./internal/node/postgres -run 'LiveClientSequenceCAS|Task5(ClientSequenceMigration|A)' -count=1
TEST_POSTGRES_URL="postgres://plainpost:plainpost-test-only@127.0.0.1:${port}/plainpost?sslmode=disable" \
  PLAINPOST_REQUIRE_LIVE_POSTGRES=1 \
  go test -race ./internal/node/secrets -run 'TestLiveCurrentAuthorityStateIsEncryptedCASRestartSafeAndRotationSafe' -count=1
TEST_POSTGRES_URL="postgres://plainpost:plainpost-test-only@127.0.0.1:${port}/plainpost?sslmode=disable" \
  PLAINPOST_REQUIRE_LIVE_POSTGRES=1 \
  go test -race ./internal/central/postgres -run 'Test(CurrentAuthorityLive(InitialContinuationAndReplayFence|RejectsNoncurrentAndReplacedAuthority|AcceptedRevocationImmediatelyFencesFormerClient|OverlappingAcceptedRevocationHasOneLockOrderedWinner|RecoveryThenFreshNodeEnrollment)|NodeReplacementLive(RevokesOldSessionsBeforeReturningResult|ImmediatelyFencesOldAuthorityAndAdmitsReplacement|OverlappingCurrentAuthorityHasOneLockOrderedWinner))' -count=1
TEST_POSTGRES_URL="postgres://plainpost:plainpost-test-only@127.0.0.1:${port}/plainpost?sslmode=disable" \
  PLAINPOST_REQUIRE_LIVE_POSTGRES=1 \
  go test ./cmd/plainpost-sync-node -run '^(TestAggregateReadiness.*|TestDeferredClientAuth.*|TestProductionRestore.*|TestRunNodeProduction.*|TestRunKeepsConfiguredListenersLive.*)$' -count=1
