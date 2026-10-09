#!/bin/sh
set -eu

compose=$1
project=$2
temporary=$3
node_service=$4
node_image=$5
node_uid=$6
node_gid=$7
attachment_storage=$8
attachment_dir=$9
drop_responses=${10}
s3_endpoint=${11}
s3_bucket=${12}
s3_region=${13}
s3_addressing=${14}
s3_access_key_file=${15}
s3_secret_key_file=${16}
hostname=${17}
port=${18}
restart_mode=${19:-readiness}

case "$restart_mode" in
  readiness|health|presentation|mutation) ;;
  *) printf 'unsupported node restart mode: %s\n' "$restart_mode" >&2; exit 2 ;;
esac

# Keep Compose's stop grace bounded so the helper's documented worst-case
# remains 10 seconds for restart plus ten five-second readiness probes and
# their one-second retry delays. Mutation mode stops the node, asks the
# fixture to disconnect the exact mutation occurrence, waits for the fixture
# transaction barrier to unwind, and only then starts the node. This prevents
# the old provider command from continuing and committing after restart.
export PLAINPOST_PRIVATE_ROOT="$temporary"
export PLAINPOST_PRIVATE_NODE_IMAGE="$node_image"
export PLAINPOST_ACCEPTANCE_NODE_UID="$node_uid"
export PLAINPOST_ACCEPTANCE_NODE_GID="$node_gid"
export PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE="$attachment_storage"
export PLAINPOST_ACCEPTANCE_ATTACHMENT_DIR="$attachment_dir"
export PLAINPOST_ACCEPTANCE_DROP_RESPONSES="$drop_responses"
export PLAINPOST_ACCEPTANCE_S3_ENDPOINT="$s3_endpoint"
export PLAINPOST_ACCEPTANCE_S3_BUCKET="$s3_bucket"
export PLAINPOST_ACCEPTANCE_S3_REGION="$s3_region"
export PLAINPOST_ACCEPTANCE_S3_ADDRESSING="$s3_addressing"
export PLAINPOST_ACCEPTANCE_S3_ACCESS_KEY_FILE="$s3_access_key_file"
export PLAINPOST_ACCEPTANCE_S3_SECRET_KEY_FILE="$s3_secret_key_file"
if [ "$restart_mode" = mutation ]; then
  docker compose -p "$project" -f "$compose" stop --timeout 10 "$node_service"
  docker compose -p "$project" -f "$compose" exec -T imap-fixture \
    python3 /opt/plainpost/plainpost_acceptance_mail_control.py \
    --root /var/lib/plainpost phase imap mutation 1 disconnect
  docker compose -p "$project" -f "$compose" exec -T imap-fixture \
    python3 /opt/plainpost/plainpost_acceptance_mail_control.py \
    --root /var/lib/plainpost wait-phase-release imap mutation 1 --timeout-ms 30000
  docker compose -p "$project" -f "$compose" start "$node_service"
else
  docker compose -p "$project" -f "$compose" restart --timeout 10 "$node_service"
fi

if [ "$restart_mode" = presentation ]; then
  # A pre-activation node is expected to be unavailable on /readyz; the
  # caller's bounded enrollment-presentation probe establishes readiness.
  exit 0
fi

for _ in 1 2 3 4 5 6 7 8 9 10; do
  restart_probe_path=readyz
  if [ "$restart_mode" = health ] || [ "$restart_mode" = mutation ]; then
    restart_probe_path=healthz
  fi
  if curl --silent --fail --max-time 5 --noproxy '*' --cacert "$temporary/ca.crt" \
    --connect-to "$hostname:18443:127.0.0.1:$port" "https://$hostname:18443/$restart_probe_path" >/dev/null; then
    exit 0
  fi
  sleep 1
done
exit 1
