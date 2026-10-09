#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
owner="$root/Scripts/test-sync-node-private-transport.sh"
scenario="$root/Tests/PlainpostAccountRuntimeTests/NodeMailAuthorityLiveScenario.swift"
test -x "$owner"

# SMTP matrix execution returns immediately after its typed case. It therefore
# cannot publish the later restart-node control signal; the owner must require
# only the initial drop/replay/fresh-commit triplet for matrix runs, while the
# no-scenario full lifecycle retains both triplets.
if ! awk '
  /if let matrixCase = try smtpMatrixCaseFromEnvironment\(\)/ { matrix = NR }
  matrix && /runSMTPMatrixCase\(/ { invoked = NR }
  invoked && /^            return$/ { returned = NR }
  END { exit !(matrix && invoked && returned > invoked) }
' "$scenario"; then
	printf 'SMTP matrix early-return contract is missing\n' >&2
	exit 1
fi
if ! grep -F 'acceptance_response_drop_restart_expected=0' "$owner" >/dev/null ||
   ! grep -F 'acceptance_response_drop_expected_dropped_count=1' "$owner" >/dev/null ||
   ! grep -F 'acceptance_response_drop_expected_exact_replay_count=1' "$owner" >/dev/null ||
   ! grep -F 'acceptance_response_drop_expected_fresh_committed_count=1' "$owner" >/dev/null; then
	printf 'matrix response-drop cardinality is not reduced to one triplet\n' >&2
	exit 1
fi
if ! grep -F 'acceptance_response_drop_expected_dropped_count=2' "$owner" >/dev/null ||
   ! grep -F 'acceptance_response_drop_expected_exact_replay_count=2' "$owner" >/dev/null ||
   ! grep -F 'acceptance_response_drop_expected_fresh_committed_count=2' "$owner" >/dev/null; then
	printf 'full lifecycle response-drop cardinality does not retain two triplets\n' >&2
	exit 1
fi
if ! awk '
  /if \[ "\$acceptance_response_drop_restart_expected" -eq 1 \]; then/ { guard = NR }
  /require_response_drop_evidence .*status-restart-dropped restart/ { restart = NR }
  /check_status_response_drop_correlation restart/ { correlation = NR }
  END { exit !(guard && restart > guard && correlation > guard) }
' "$owner"; then
	printf 'restart response-drop evidence is not guarded by full-lifecycle expectation\n' >&2
	exit 1
fi
printf 'sync_node_private_transport_response_drop_cardinality_contract=passed\n'
