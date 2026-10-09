#!/bin/sh
set -eu

# The fixture owns the authoritative SQLite namespace once it is running. Run
# the transition inside that container; only pre-start callers use the host
# fallback. The Node projection delta remains the proof that the restarted
# provider consumed it. Keep this child bounded and let the caller's
# controller own the single terminal signal.
transition_script=${1:-}
transition_root=${2:-}
transition_attempts=${3:-6}
transition_retry_delay_seconds=${4:-0.5}
transition_container=${5:-}
transition_authority_phase=${6:-prestart}
case "$transition_attempts" in
  ''|*[!0-9]*|0) exit 2 ;;
esac
transition_attempt=1
while [ "$transition_attempt" -le "$transition_attempts" ]; do
  if [ -n "$transition_script" ] && [ -d "$transition_root" ] && {
    if [ "$transition_authority_phase" = poststart ]; then
      if [ -n "$transition_container" ] && [ "$transition_container" != unavailable ]; then
        docker exec "$transition_container" python3 /opt/plainpost/plainpost_acceptance_mail_fixture.py transition >/dev/null 2>&1
      else
        false
      fi
    else
      PLAINPOST_ACCEPTANCE_MAIL_ROOT="$transition_root" \
      PYTHONPATH="$(dirname "$transition_script")" \
      python3 "$transition_script" transition >/dev/null 2>&1
    fi
  }; then
    printf 'ERROR acceptance-provider-transition attempt=%s outcome=applied\n' "$transition_attempt" >&2
    exit 0
  fi
  if [ "$transition_attempt" -lt "$transition_attempts" ]; then
    sleep "$transition_retry_delay_seconds"
  fi
  transition_attempt=$((transition_attempt + 1))
done
printf 'ERROR acceptance-provider-transition attempt=%s outcome=failed\n' "$transition_attempts" >&2
exit 1
