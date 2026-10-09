#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
target="$root/Scripts/test-sync-node-client-api.sh"
attachment_storage_contract="$root/Scripts/test-sync-node-client-api-attachment-storage-contract.sh"

grep -F 'test-sync-node-private-transport.sh' "$target" >/dev/null
grep -F 'PLAINPOST_SYNC_NODE_CLIENT_API=enabled' "$target" >/dev/null
grep -F 'PLAINPOST_SYNC_NODE_ACCEPTANCE_SWIFT_FILTER=PlainpostAccountRuntimeTests.SyncNodePrivateTransportLiveTests/testRealCentralAndNodeProcessesClosePrivateLifecycle' "$target" >/dev/null
if grep -F 'PLAINPOST_SYNC_NODE_ACCEPTANCE_SWIFT_FILTER=SyncNodePrivateTransportLiveTests' "$target" >/dev/null ||
   grep -F 'testNestedAcceptanceStreamCancellationStressReleasesLifecycleAcrossChunkTimings' "$target" >/dev/null; then
  printf 'client API gate must select only the exact lifecycle test\n' >&2
  exit 1
fi
if grep -F 'sync-node-client-api-owner.sh' "$target" >/dev/null; then
  printf 'client API gate still has a parallel owner\n' >&2
  exit 1
fi
if grep -F 'PLAINPOST_SYNC_NODE_CLIENT_API_FIXTURE' "$target" >/dev/null; then
  printf 'client API gate still consumes an exported session fixture\n' >&2
  exit 1
fi
test -x "$attachment_storage_contract"
"$attachment_storage_contract" >/dev/null
printf 'sync_node_client_api_owner_contract=passed\n'
