#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scenario=''
group=''
usage() {
  printf '%s\n' 'usage: test-sync-node-mail-matrix.sh --scenario SELECTOR | --group smtp | --group imap | --all' >&2
  exit 2
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --scenario) [ "$#" -ge 2 ] || usage; scenario=$2; shift 2 ;;
    --group) [ "$#" -ge 2 ] || usage; group=$2; shift 2 ;;
    --all) group=all; shift ;;
    *) usage ;;
  esac
done
[ -n "$scenario" ] || [ -n "$group" ] || usage
[ -z "$scenario" ] || [ -z "$group" ] || usage

direct_policy_tmp=''
cleanup_direct_policy_tmp() {
  if [ -n "$direct_policy_tmp" ] && [ -d "$direct_policy_tmp" ]; then
    find "$direct_policy_tmp" -depth -delete
  fi
}
trap cleanup_direct_policy_tmp EXIT HUP INT TERM

run_direct_mode_acceptance() {
  command -v swift >/dev/null 2>&1 || {
    printf '%s\n' 'Swift is required for Direct mode acceptance' >&2
    return 1
  }
  umask 077
  direct_policy_tmp=$(mktemp -d "${TMPDIR:-/tmp}/plainpost-mail-direct-policy.XXXXXX")
  if "$root/Scripts/swift-test-isolated.sh" --package-path "$root" \
    --filter NotificationRuntimeTests/testProductionAuthenticatedProducerSelectorSwitchesMacSyncNodeMacWithAuthoritativeReload \
    >"$direct_policy_tmp/direct-mode.log" 2>&1; then
    printf '%s\n' 'stage=mail-matrix scenario=direct-mode-switch-authoritative-reload outcome=pass'
    return 0
  fi
  printf '%s\n' 'stage=mail-matrix scenario=direct-mode-switch-authoritative-reload outcome=fail category=swift-test' >&2
  return 1
}

case "$group" in
  '') selectors=$scenario ;;
  smtp) selectors='smtp-authentication smtp-recipient-451 smtp-recipient-550 smtp-after-354 smtp-mid-data smtp-final-reply smtp-quit-loss smtp-cancel-before-data smtp-cancel-after-data smtp-sent-append-failure smtp-provider-restart-after-acceptance smtp-untrusted-certificate smtp-same-ca-wrong-host smtp-tls1.1 smtp-auth-before-starttls smtp-concurrent-sends smtp-ambiguous-replay' ;;
  imap) selectors='imap-authentication imap-untrusted-certificate imap-same-ca-wrong-host imap-tls1.1 imap-catalog imap-header-fetch imap-body-fetch imap-attachment-fetch imap-delayed-literal imap-truncated-literal imap-uid-gaps imap-expunge imap-uidvalidity-reset imap-idle-wakeup imap-poll-fallback imap-provider-restart-mid-page imap-provider-restart-after-commit imap-node-restart-before-ack imap-node-restart-after-ack imap-concurrent-mutations imap-stale-authority imap-mime-boundaries' ;;
  all) selectors='smtp-authentication smtp-recipient-451 smtp-recipient-550 smtp-after-354 smtp-mid-data smtp-final-reply smtp-quit-loss smtp-cancel-before-data smtp-cancel-after-data smtp-sent-append-failure smtp-provider-restart-after-acceptance smtp-untrusted-certificate smtp-same-ca-wrong-host smtp-tls1.1 smtp-auth-before-starttls smtp-concurrent-sends smtp-ambiguous-replay imap-authentication imap-untrusted-certificate imap-same-ca-wrong-host imap-tls1.1 imap-catalog imap-header-fetch imap-body-fetch imap-attachment-fetch imap-delayed-literal imap-truncated-literal imap-uid-gaps imap-expunge imap-uidvalidity-reset imap-idle-wakeup imap-poll-fallback imap-provider-restart-mid-page imap-provider-restart-after-commit imap-node-restart-before-ack imap-node-restart-after-ack imap-concurrent-mutations imap-stale-authority imap-mime-boundaries' ;;
  *) printf 'mail matrix group is outside the closed allowlist\n' >&2; exit 2 ;;
esac

if [ "$group" = all ]; then
  run_direct_mode_acceptance
fi

for selector in $selectors; do
  case "$selector" in
    smtp-authentication|smtp-recipient-451|smtp-recipient-550|smtp-after-354|smtp-mid-data|smtp-final-reply|smtp-quit-loss|smtp-cancel-before-data|smtp-cancel-after-data|smtp-sent-append-failure|smtp-provider-restart-after-acceptance|smtp-untrusted-certificate|smtp-same-ca-wrong-host|smtp-tls1.1|smtp-auth-before-starttls|smtp-concurrent-sends|smtp-ambiguous-replay|imap-authentication|imap-untrusted-certificate|imap-same-ca-wrong-host|imap-tls1.1|imap-catalog|imap-header-fetch|imap-body-fetch|imap-attachment-fetch|imap-delayed-literal|imap-truncated-literal|imap-uid-gaps|imap-expunge|imap-uidvalidity-reset|imap-idle-wakeup|imap-poll-fallback|imap-provider-restart-mid-page|imap-provider-restart-after-commit|imap-node-restart-before-ack|imap-node-restart-after-ack|imap-concurrent-mutations|imap-stale-authority|imap-mime-boundaries) ;;
    *) printf 'mail matrix selector is outside the closed allowlist\n' >&2; exit 2 ;;
  esac
  outcome=pass
  status=0
  client_api_wrapper=${PLAINPOST_SYNC_NODE_MAIL_MATRIX_CLIENT_API_WRAPPER:-$root/Scripts/test-sync-node-client-api.sh}
  if PLAINPOST_SYNC_NODE_ACCEPTANCE_MAIL_SCENARIO="$selector" \
    sh "$client_api_wrapper"; then
    :
  else
    status=$?
    outcome=fail
  fi
  printf 'stage=mail-matrix scenario=%s outcome=%s\n' "$selector" "$outcome"
  if [ "$outcome" != pass ]; then
    exit "$status"
  fi
done
