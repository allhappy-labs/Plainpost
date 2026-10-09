#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
owner="$root/Scripts/test-sync-node-private-transport.sh"
client_wrapper="$root/Scripts/test-sync-node-client-api.sh"
contract_root=$(mktemp -d /private/tmp/plainpost-client-attachment-storage-contract.XXXXXX)
trap 'find "$contract_root" -depth -delete >/dev/null 2>&1 || true' EXIT HUP INT TERM
mkdir -m 0700 "$contract_root/bin"
cp /usr/bin/false "$contract_root/bin/docker"
chmod 0700 "$contract_root/bin/docker"

run_selection() {
  local name=$1
  shift
  local output="$contract_root/$name.log"
  if env "$@" \
    PATH="$contract_root/bin:$PATH" \
    PLAINPOST_SYNC_NODE_ATTACHMENT_STORAGE_SELECTION_TEST=enabled \
    "$owner" >"$output" 2>&1; then
    return 0
  fi
  return 1
}

run_client_selection() {
  local name=$1
  shift
  local output="$contract_root/$name.log"
  if env "$@" \
    PATH="$contract_root/bin:$PATH" \
    PLAINPOST_SYNC_NODE_ATTACHMENT_STORAGE_SELECTION_TEST=enabled \
    bash "$client_wrapper" >"$output" 2>&1; then
    return 0
  fi
  return 1
}

run_client_initialization() {
  local name=$1
  shift
  local output="$contract_root/$name.log"
  if env "$@" \
    PATH="$contract_root/bin:$PATH" \
    PLAINPOST_SYNC_NODE_ATTACHMENT_STORAGE_INITIALIZATION_TEST=enabled \
    bash "$client_wrapper" >"$output" 2>&1; then
    return 0
  fi
  return 1
}

run_client_selection client-default \
  -u PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE \
  PLAINPOST_SYNC_NODE_CLIENT_API=enabled
grep -Fx 'attachment-storage-selection storage=filesystem dir=/node-attachments s3=disabled' "$contract_root/client-default.log" >/dev/null

run_client_selection client-explicit-s3 \
  PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE=s3
grep -Fx 'attachment-storage-selection storage=s3 dir= s3=enabled' "$contract_root/client-explicit-s3.log" >/dev/null

run_client_selection client-explicit-filesystem \
  PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE=filesystem
grep -Fx 'attachment-storage-selection storage=filesystem dir=/node-attachments s3=disabled' "$contract_root/client-explicit-filesystem.log" >/dev/null

run_client_initialization client-explicit-s3 \
  PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE=s3
grep -Fx 'attachment-storage-initialization storage=s3 phase-file=present mode=600 s3-credentials=present' "$contract_root/client-explicit-s3.log" >/dev/null

run_selection private-default \
  -u PLAINPOST_SYNC_NODE_CLIENT_API \
  -u PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE
grep -Fx 'attachment-storage-selection storage=s3 dir= s3=enabled' "$contract_root/private-default.log" >/dev/null

invalid_output="$contract_root/invalid.log"
if env PLAINPOST_ACCEPTANCE_ATTACHMENT_STORAGE=unsupported \
  PATH="$contract_root/bin:$PATH" \
  PLAINPOST_SYNC_NODE_ATTACHMENT_STORAGE_SELECTION_TEST=enabled \
  "$owner" >"$invalid_output" 2>&1; then
  printf 'unsupported attachment storage unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fx 'unsupported attachment storage: unsupported' "$invalid_output" >/dev/null

printf 'sync_node_client_api_attachment_storage_contract=passed\n'
