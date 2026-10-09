#!/bin/sh

# Run one acceptance controller child with a finite monotonic budget. The
# caller owns the child PID while this function runs, so an interrupt handler
# can terminate the same process before the harness exits.
acceptance_controller_monotonic_ms() {
  python3 -c 'import time; print(time.monotonic_ns() // 1000000)'
}

acceptance_controller_reject_group() {
  kill -KILL "$controller_child_pid" 2>/dev/null || true
  wait "$controller_child_pid" 2>/dev/null || true
  acceptance_controller_signal_once "$acceptance_controller_root" "$acceptance_controller_action" failed || true
  controller_child_pid=''
  controller_child_pgid=''
  controller_child_signal_root=''
  controller_child_signal_action=''
}

acceptance_controller_run() {
  acceptance_controller_root=$1
  acceptance_controller_action=$2
  acceptance_controller_timeout_seconds=$3
  shift 3

  controller_child_signal_root=$acceptance_controller_root
  controller_child_signal_action=$acceptance_controller_action
  acceptance_controller_started_at_ms=$(acceptance_controller_monotonic_ms)
  acceptance_controller_deadline_ms=$((acceptance_controller_started_at_ms + acceptance_controller_timeout_seconds * 1000))
  acceptance_controller_handshake="$acceptance_controller_root/.controller-$acceptance_controller_action.$$"
  rm -f "$acceptance_controller_handshake"
  CONTROLLER_HANDSHAKE="$acceptance_controller_handshake" \
    python3 -c 'import os,sys; os.setsid(); path=os.environ["CONTROLLER_HANDSHAKE"]; open(path,"w",encoding="ascii").write(str(os.getpgrp())); os.execvp(sys.argv[1],sys.argv[1:])' "$@" &
  controller_child_pid=$!
  controller_child_pgid=''
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if [ -s "$acceptance_controller_handshake" ]; then
      controller_child_pgid=$(tr -d '[:space:]' <"$acceptance_controller_handshake")
      break
    fi
    kill -0 "$controller_child_pid" 2>/dev/null || break
    sleep 0.01
  done
  rm -f "$acceptance_controller_handshake"
  controller_harness_pgid=$(python3 -c 'import os; print(os.getpgrp())' 2>/dev/null | tr -d '[:space:]' || true)
  case "$controller_child_pgid" in
    ''|*[!0-9]*) acceptance_controller_reject_group; return 1 ;;
  esac
  case "$controller_harness_pgid" in
    ''|*[!0-9]*) acceptance_controller_reject_group; return 1 ;;
  esac
  if [ "$controller_child_pgid" -ne "$controller_child_pid" ] || [ "$controller_child_pgid" -le 1 ] || [ "$controller_child_pgid" = "$controller_harness_pgid" ]; then
    kill -KILL "$controller_child_pid" 2>/dev/null || true
    wait "$controller_child_pid" 2>/dev/null || true
    acceptance_controller_signal_once "$acceptance_controller_root" "$acceptance_controller_action" failed || true
    controller_child_pid=''
    controller_child_pgid=''
    controller_child_signal_root=''
    controller_child_signal_action=''
    return 1
  fi
  acceptance_controller_timed_out=0
  while kill -0 "$controller_child_pid" 2>/dev/null; do
    if [ "$(acceptance_controller_monotonic_ms)" -ge "$acceptance_controller_deadline_ms" ]; then
      acceptance_controller_timed_out=1
      /bin/kill -TERM -- "-$controller_child_pgid" 2>/dev/null || true
      for _ in 1 2 3 4 5; do
        kill -0 "$controller_child_pid" 2>/dev/null || break
        sleep 0.2
      done
      if kill -0 "$controller_child_pid" 2>/dev/null; then
        /bin/kill -KILL -- "-$controller_child_pgid" 2>/dev/null || true
      fi
      # The leader may have honored TERM while an owned descendant ignored
      # it. The leader PID is no longer a sufficient liveness check: always
      # terminate the tracked process group before publishing failure.
      if /bin/kill -0 -- "-$controller_child_pgid" 2>/dev/null; then
        /bin/kill -KILL -- "-$controller_child_pgid" 2>/dev/null || true
      fi
      break
    fi
    sleep 0.1
  done

  # The process-group leader can exit successfully while a descendant keeps
  # the owned group alive. That is not an applied controller action: reap the
  # leader, terminate every owned descendant, and report failure below.
  acceptance_controller_group_survived=0
  if [ "$acceptance_controller_timed_out" -eq 0 ] && /bin/kill -0 -- "-$controller_child_pgid" 2>/dev/null; then
    acceptance_controller_group_survived=1
    /bin/kill -TERM -- "-$controller_child_pgid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      /bin/kill -0 -- "-$controller_child_pgid" 2>/dev/null || break
      sleep 0.2
    done
    if /bin/kill -0 -- "-$controller_child_pgid" 2>/dev/null; then
      /bin/kill -KILL -- "-$controller_child_pgid" 2>/dev/null || true
    fi
  fi

  acceptance_controller_status=0
  wait "$controller_child_pid" 2>/dev/null || acceptance_controller_status=$?
  if [ "$acceptance_controller_group_survived" -eq 1 ] && [ "$acceptance_controller_status" -eq 0 ]; then
    acceptance_controller_status=125
    printf 'ERROR controller-descendant-survived action=%s\n' "$acceptance_controller_action"
  fi
  if [ "$acceptance_controller_timed_out" -eq 1 ]; then
    acceptance_controller_status=124
    printf 'ERROR controller-child-timeout action=%s timeout_seconds=%s\n' \
      "$acceptance_controller_action" "$acceptance_controller_timeout_seconds"
  fi
  printf 'ERROR controller-child-reaped action=%s status=%s\n' \
    "$acceptance_controller_action" "$acceptance_controller_status"
  controller_child_pid=''
  controller_child_pgid=''

  acceptance_controller_terminal='failed'
  if [ "$acceptance_controller_status" -eq 0 ]; then
    acceptance_controller_terminal='applied'
  fi
  acceptance_controller_signal_once \
    "$acceptance_controller_root" "$acceptance_controller_action" "$acceptance_controller_terminal"
  controller_child_signal_root=''
  controller_child_signal_action=''
  return "$acceptance_controller_status"
}

acceptance_controller_signal_once() {
  acceptance_signal_root=$1
  acceptance_signal_action=$2
  acceptance_signal_phase=$3
  case "$acceptance_signal_phase" in
    applied|failed) ;;
    *) return 1 ;;
  esac
  acceptance_signal_target="$acceptance_signal_root/$acceptance_signal_action.$acceptance_signal_phase"
  acceptance_signal_applied="$acceptance_signal_root/$acceptance_signal_action.applied"
  acceptance_signal_failed="$acceptance_signal_root/$acceptance_signal_action.failed"
  if [ -e "$acceptance_signal_applied" ] || [ -e "$acceptance_signal_failed" ]; then
    return 1
  fi
  acceptance_signal_temporary="$acceptance_signal_target.$$"
  (umask 077; : >"$acceptance_signal_temporary"; chmod 0600 "$acceptance_signal_temporary")
  mv -f "$acceptance_signal_temporary" "$acceptance_signal_target"
}

acceptance_controller_stop_child() {
  acceptance_stop_root=$controller_child_signal_root
  acceptance_stop_action=$controller_child_signal_action
  acceptance_stop_group=''
  if [ -n "$controller_child_pid" ] && [ -n "$controller_child_pgid" ]; then
    acceptance_stop_harness_pgid=$(python3 -c 'import os; print(os.getpgrp())' 2>/dev/null | tr -d '[:space:]' || true)
    case "$controller_child_pgid" in
      ''|*[!0-9]*) ;;
      *)
        case "$acceptance_stop_harness_pgid" in
          ''|*[!0-9]*) ;;
          *)
            if [ "$controller_child_pgid" -gt 1 ] && [ "$controller_child_pgid" != "$acceptance_stop_harness_pgid" ]; then
              acceptance_stop_group="-$controller_child_pgid"
            fi
            ;;
        esac
        ;;
    esac
  fi
  if [ -n "$controller_child_pid" ] && [ -n "$acceptance_stop_group" ]; then
    /bin/kill -TERM -- "$acceptance_stop_group" 2>/dev/null || true
  elif [ -n "$controller_child_pid" ]; then
    kill -TERM "$controller_child_pid" 2>/dev/null || true
  fi
  if [ -n "$controller_child_pid" ]; then
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      kill -0 "$controller_child_pid" 2>/dev/null || break
      sleep 0.25
    done
    if kill -0 "$controller_child_pid" 2>/dev/null; then
      if [ -n "$acceptance_stop_group" ]; then
        /bin/kill -KILL -- "$acceptance_stop_group" 2>/dev/null || true
      else
        kill -KILL "$controller_child_pid" 2>/dev/null || true
      fi
    fi
    if [ -n "$acceptance_stop_group" ] && /bin/kill -0 -- "$acceptance_stop_group" 2>/dev/null; then
      /bin/kill -KILL -- "$acceptance_stop_group" 2>/dev/null || true
    fi
    wait "$controller_child_pid" 2>/dev/null || true
  fi
  if [ -n "$acceptance_stop_root" ] && [ -n "$acceptance_stop_action" ]; then
    acceptance_controller_signal_once "$acceptance_stop_root" "$acceptance_stop_action" failed || true
  fi
  controller_child_pid=''
  controller_child_pgid=''
  controller_child_signal_root=''
  controller_child_signal_action=''
}
