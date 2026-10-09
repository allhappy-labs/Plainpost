#!/bin/zsh
set -euo pipefail
zmodload zsh/datetime

APP_PATH="${1:-$PWD/.build/Plainpost.app}"
APP_PATH="${APP_PATH:A}"
OUTPUT_ROOT="${2:-$PWD/output}"
EXECUTABLE="$APP_PATH/Contents/MacOS/Plainpost"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_DIR="$OUTPUT_ROOT/inbox-performance-$TIMESTAMP"
CSV="$OUTPUT_DIR/process.csv"
WINDOW_PROBE="$PWD/Scripts/wait-for-app-window.swift"
WINDOW_PROBE_BINARY="$OUTPUT_DIR/wait-for-app-window"

if [[ ! -x "$EXECUTABLE" ]]; then
  print -u2 "Plainpost executable is missing: $EXECUTABLE"
  exit 2
fi

mkdir -p "$OUTPUT_DIR"
print 'elapsed_seconds,cpu_percent,rss_kib' > "$CSV"
swiftc -O "$WINDOW_PROBE" -o "$WINDOW_PROBE_BINARY"
launch_epoch="$EPOCHREALTIME"
open -n "$APP_PATH"

pid=''
for _ in {1..120}; do
  pid="$(pgrep -n -f "^$EXECUTABLE$" || true)"
  [[ -n "$pid" ]] && break
  sleep 0.1
done
if [[ -z "$pid" ]]; then
  print -u2 'Plainpost did not launch.'
  exit 3
fi
print "$pid" > "$OUTPUT_DIR/pid.txt"
process_epoch="$EPOCHREALTIME"
sample "$pid" 11 -file "$OUTPUT_DIR/startup-sample.txt" >/dev/null 2>&1 &
startup_sample_pid="$!"

window_ready=0
window_elapsed="$("$WINDOW_PROBE_BINARY" "$pid" "$process_epoch" 5.0 2>/dev/null || true)"
request_to_window_elapsed="$(( EPOCHREALTIME - launch_epoch ))"
launch_service_elapsed="$(( process_epoch - launch_epoch ))"
if [[ -n "$window_elapsed" ]]; then
  window_ready=1
else
  window_elapsed="$(( EPOCHREALTIME - process_epoch ))"
fi
print "window_seconds=$window_elapsed" > "$OUTPUT_DIR/responsiveness.txt"
print "request_to_window_seconds=$request_to_window_elapsed" >> "$OUTPUT_DIR/responsiveness.txt"
print "launch_service_seconds=$launch_service_elapsed" >> "$OUTPUT_DIR/responsiveness.txt"

peak_rss=0
for sample_index in {0..47}; do
  if ! kill -0 "$pid" 2>/dev/null; then
    print -u2 'Plainpost exited during measurement.'
    exit 4
  fi
  process_sample="$(ps -p "$pid" -o %cpu=,rss=)"
  cpu="${${(z)process_sample}[1]}"
  rss="${${(z)process_sample}[2]}"
  (( rss > peak_rss )) && peak_rss="$rss"
  printf '%.2f,%s,%s\n' "$(( sample_index * 0.25 ))" "$cpu" "$rss" >> "$CSV"
  sleep 0.25
done
wait "$startup_sample_pid" 2>/dev/null || true

settled_rss="$(tail -n 1 "$CSV" | cut -d, -f3)"
print "peak_rss_kib=$peak_rss" >> "$OUTPUT_DIR/responsiveness.txt"
print "settled_rss_kib=$settled_rss" >> "$OUTPUT_DIR/responsiveness.txt"
sample "$pid" 1 -file "$OUTPUT_DIR/sample.txt" >/dev/null 2>&1 || true
heap "$pid" > "$OUTPUT_DIR/heap.txt" 2>&1 || true
vmmap -summary "$pid" > "$OUTPUT_DIR/vmmap-summary.txt" 2>&1 || true
footprint -p "$pid" > "$OUTPUT_DIR/footprint.txt" 2>&1 || true
settled_footprint_mib="$(awk '
  /phys_footprint:/ && !/peak/ {
    value=$2; unit=$3
    if (unit == "GB") value *= 1024
    else if (unit == "KB") value /= 1024
    else if (unit == "B") value /= 1048576
    printf "%.2f", value
  }
' "$OUTPUT_DIR/footprint.txt")"
peak_footprint_mib="$(awk '
  /phys_footprint_peak:/ {
    value=$2; unit=$3
    if (unit == "GB") value *= 1024
    else if (unit == "KB") value /= 1024
    else if (unit == "B") value /= 1048576
    printf "%.2f", value
  }
' "$OUTPUT_DIR/footprint.txt")"
print "settled_footprint_mib=$settled_footprint_mib" >> "$OUTPUT_DIR/responsiveness.txt"
print "peak_footprint_mib=$peak_footprint_mib" >> "$OUTPUT_DIR/responsiveness.txt"

if (( window_ready == 0 )) || (( window_elapsed > 5.0 )); then
  print -u2 'Plainpost window did not become responsive within 5 seconds.'
  exit 5
fi
if [[ -z "$settled_footprint_mib" || -z "$peak_footprint_mib" ]]; then
  print -u2 'Plainpost physical-footprint metrics were unavailable.'
  exit 6
fi
if (( settled_footprint_mib > 250.0 )); then
  print -u2 "Settled physical footprint exceeded 250 MiB: $settled_footprint_mib MiB"
  exit 7
fi
if (( peak_footprint_mib > 350.0 )); then
  print -u2 "Peak physical footprint exceeded 350 MiB: $peak_footprint_mib MiB"
  exit 8
fi

print "$OUTPUT_DIR"
