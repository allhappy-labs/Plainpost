#!/bin/sh
set -eu

# Client API acceptance deliberately shares the private-transport owner. The
# enrollment presentation, Central admission, Node activation, TLS relays,
# provider peers, attachment root, restart controls, and cleanup must have one
# lifecycle owner. In particular, this gate never accepts a caller-supplied
# session JSON document or a second speculative Compose project.
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export PLAINPOST_SYNC_NODE_CLIENT_API=enabled

PLAINPOST_SYNC_NODE_PRIVATE_ACCEPTANCE=enabled \
PLAINPOST_SYNC_NODE_CLIENT_API=enabled \
PLAINPOST_SYNC_NODE_ACCEPTANCE_DROP_RESPONSES=status \
PLAINPOST_SYNC_NODE_ACCEPTANCE_SWIFT_FILTER=PlainpostAccountRuntimeTests.SyncNodePrivateTransportLiveTests/testRealCentralAndNodeProcessesClosePrivateLifecycle \
  exec "$root/Scripts/test-sync-node-private-transport.sh"
