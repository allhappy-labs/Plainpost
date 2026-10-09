#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
image='postgres:18.6-alpine3.24@sha256:d3e1620b530c944afa6e887d22eb899824da68e19c52024bf98f5220c88a65b2'
command -v docker >/dev/null 2>&1 || { printf '%s\n' 'Docker is required for PostgreSQL storage contracts' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf '%s\n' 'python3 is required for PostgreSQL storage contracts' >&2; exit 1; }

workspace=$(mktemp -d /private/tmp/plainpost-pg18-storage-contract.XXXXXX)
trap 'rm -rf -- "$workspace"' EXIT
mkdir -p -- "$workspace/private" "$workspace/secrets"

render() {
  local name=$1
  shift
  docker compose "$@" config --format json >"$workspace/$name.json"
}

render central -f "$root/Deploy/central/compose.dev.yml"
render acceptance --profile acceptance-live -f "$root/Deploy/acceptance/compose.yaml"
PLAINPOST_PRIVATE_ROOT="$workspace/private" \
PLAINPOST_PRIVATE_NODE_IMAGE='registry.invalid/plainpost-private-node@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  render private-transport -f "$root/Deploy/acceptance/compose.private-transport.yaml"
PLAINPOST_TASK6_POSTGRES_PORT=55436 \
PLAINPOST_TASK6_MINIO_PORT=59000 \
PLAINPOST_TASK6_SECRET_DIR="$workspace/secrets" \
  render storage -f "$root/Deploy/sync-node/compose.test-storage.yml"
render unraid --env-file "$root/Deploy/sync-node/env.unraid.example" -f "$root/Deploy/sync-node/compose.unraid.yml"

python3 - "$workspace" "$image" <<'PY'
import json
import pathlib
import sys

workspace = pathlib.Path(sys.argv[1])
expected = sys.argv[2]
expected_services = {
    "central": {"account-postgres", "deletion-journal-postgres"},
    "acceptance": {"account-db", "deletion-journal-db"},
    "private-transport": {"postgres", "postgres-node-one", "postgres-node-two"},
    "storage": {"postgres"},
    "unraid": {"postgres"},
}

for path in sorted(workspace.glob("*.json")):
    document = json.loads(path.read_text())
    services = document.get("services", {})
    owners = expected_services[path.stem]
    missing = owners.difference(services)
    if missing:
        raise SystemExit(f"{path.name} is missing PostgreSQL owner(s): {sorted(missing)}")
    unknown = {
        name for name, service in services.items()
        if isinstance(service.get("image"), str) and "postgres" in service["image"].lower()
    }.difference(owners)
    if unknown:
        raise SystemExit(f"{path.name} has unexpected PostgreSQL owner(s): {sorted(unknown)}")
    for name in sorted(owners):
        service = services[name]
        if path.stem == "unraid":
            expected_entrypoint = ["/docker-entrypoint-initdb.d/plainpost-postgresql-18-guard"]
            expected_guard_target = "/docker-entrypoint-initdb.d"
        elif path.stem != "storage":
            expected_entrypoint = ["/usr/local/bin/plainpost-postgresql-18-guard"]
            expected_guard_target = "/usr/local/bin/plainpost-postgresql-18-guard"
        else:
            expected_entrypoint = None
            expected_guard_target = None
        if expected_entrypoint is not None:
            if service.get("entrypoint") != expected_entrypoint:
                raise SystemExit(f"{path.name}:{name} does not use the shared PostgreSQL 18 guard")
            guard_targets = [volume.get("target") for volume in service.get("volumes", [])]
            if guard_targets.count(expected_guard_target) != 1:
                raise SystemExit(f"{path.name}:{name} does not mount the shared PostgreSQL 18 guard exactly once")
        if path.stem == "storage":
            if service.get("image") != expected:
                raise SystemExit(f"{path.name}:{name} is not pinned to PostgreSQL 18")
            targets = [volume.get("target") for volume in service.get("volumes", [])]
            if "/var/lib/postgresql" in targets or "/var/lib/postgresql/data" in targets:
                raise SystemExit(f"{path.name}:{name} must remain deliberately ephemeral")
            continue
        if service.get("image") != expected:
            raise SystemExit(f"{path.name}:{name} is not pinned to {expected}")
        targets = [volume.get("target") for volume in service.get("volumes", [])]
        if "/var/lib/postgresql/data" in targets:
            raise SystemExit(f"{path.name}:{name} persists beneath the versioned data directory")
        if targets.count("/var/lib/postgresql") != 1:
            raise SystemExit(f"{path.name}:{name} must persist at /var/lib/postgresql")

print("PostgreSQL 18 storage Compose contract passed")
PY
