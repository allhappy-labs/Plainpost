#!/bin/sh

# Emit a bounded, privacy-filtered terminal summary for each acceptance stream.
# Callers own the surrounding summary markers and stderr redirection.
sync_node_stream_terminal_summary() {
  sync_node_stream_runtime_log=$1
  sync_node_stream_privacy_patterns=$2

  # Early startup failures can run before the main script has materialized its
  # privacy-pattern file. Emit no records in that state; once the file exists,
  # retain the normal fixed-field filtering below.
  if [ ! -f "$sync_node_stream_privacy_patterns" ]; then
    return 0
  fi

  grep -F '[DEBUG-sync-node-stream]' "$sync_node_stream_runtime_log" \
    | grep -F -v -f "$sync_node_stream_privacy_patterns" \
    | awk '
      {
        id = ""; event = ""; present = ""
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^stream_id=/) id = $i
          if ($i ~ /^event=/) event = $i
          if ($i ~ /^present=/) present = $i
        }
        if (id == "") next
        count[id]++
        if (event == "event=lifecycle-removed") terminal[id] = event " " present
      }
      END {
        for (id in count) printf "%s count=%d terminal=%s\n", id, count[id], terminal[id]
      }
    ' \
    | sort -t= -k2,2n \
    | tail -40
}
