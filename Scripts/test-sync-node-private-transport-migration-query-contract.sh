#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
owner="$root/Scripts/test-sync-node-private-transport.sh"

fail() {
	printf 'private transport migration-query contract: %s\n' "$*" >&2
	exit 1
}

[ -x "$owner" ] || fail 'private transport owner is missing or not executable'

# Each release migration head must select its version/name pair from the
# qualified table it describes. The former max(version) expression had no
# FROM clause and fails in PostgreSQL before the packaged owner can advance.
for migration_table in account.schema_migrations \
	deletion_journal.schema_migrations node_schema_migrations; do
	migration_query="SELECT version::text || ':' || name FROM $migration_table ORDER BY version DESC LIMIT 1"
	grep -F -- "$migration_query" "$owner" >/dev/null ||
		fail "missing valid migration-head query for $migration_table"
done
if grep -F -- 'SELECT max(version)::text ||' "$owner" >/dev/null; then
	fail 'owner retains the invalid max(version) migration-head query'
fi

# The Node migration table does not exist until node-one starts and applies its
# migrations. Keep its probe, expected head, and combined evidence after the
# existing enrollment-presentation success gate; Central's two queries remain
# in the earlier PostgreSQL startup block.
node_start_line=$(grep -n -m1 -F 'compose_run up -d node-one node-one-relay' "$owner" | cut -d: -f1)
node_ready_line=$(grep -n -m1 -F 'node-one enrollment presentation missing' "$owner" | cut -d: -f1)
node_loop_line=$(grep -n -m1 -F 'for node_migration_attempt in $(seq 1 90); do' "$owner" | cut -d: -f1)
node_query_line=$(grep -n -m1 -F 'release_node_migration_head=$(docker exec' "$owner" | cut -d: -f1)
node_retry_line=$(grep -n -m1 -F 'release_node_migration_head=$(docker exec' "$owner" |
	grep -F '2>>"$runtime_log" || true' | cut -d: -f1)
node_break_line=$(grep -n -m1 -F "[ \"\$release_node_migration_head\" = '27:0027_capture_optional_address_search_path.sql' ] && break" "$owner" | cut -d: -f1)
node_assertion_line=$(grep -n -m1 -F "[ \"\$release_node_migration_head\" = '27:0027_capture_optional_address_search_path.sql' ] || { printf" "$owner" | cut -d: -f1)
node_evidence_line=$(grep -n -m1 -F "release-migration-heads=central-account:%s central-deletion-journal:%s node:%s" "$owner" | cut -d: -f1)
[ -n "$node_start_line" ] && [ -n "$node_ready_line" ] && [ -n "$node_query_line" ] &&
	[ -n "$node_loop_line" ] && [ -n "$node_retry_line" ] && [ -n "$node_break_line" ] &&
	[ -n "$node_assertion_line" ] && [ -n "$node_evidence_line" ] ||
	fail 'private transport migration-head startup landmarks are incomplete'
[ "$node_start_line" -lt "$node_ready_line" ] &&
	[ "$node_ready_line" -lt "$node_loop_line" ] &&
	[ "$node_loop_line" -lt "$node_query_line" ] &&
	[ "$node_query_line" -le "$node_retry_line" ] &&
	[ "$node_retry_line" -lt "$node_break_line" ] &&
	[ "$node_break_line" -lt "$node_assertion_line" ] &&
	[ "$node_assertion_line" -lt "$node_evidence_line" ] ||
	fail 'Node migration query/check/evidence precedes node-one enrollment readiness'

printf 'sync_node_private_transport_migration_query_contract=passed\n'
