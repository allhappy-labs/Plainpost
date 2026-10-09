#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

release_image_failure_summary() {
  local private_owner_log=$1
  printf 'release-image acceptance: private-transport failure summary\n'
  grep -E -e '^ERROR private database audit failed category=(node-one-connect|node-one-marker-query|node-two-connect|node-two-marker-query) reason=(missing-node-installation-state|missing-node-current-authority-state|missing-node-secrets)$' -e '^node-two-schema-checkpoint phase=(initial-ready|after-restarts|before-privacy-audit) status=failed cause=(container-missing|container-not-running|psql-connect|migration-ledger|migration-head|node-installation-state|node-current-authority-state|node-secrets|relation-query|unexpected-output|query)$' -e '^(stage=(images-loaded|postgres-tools|privacy-audit|cleanup)|release-traffic=swift-client status=(passed|failed)|release-backup-restore status=passed|release-postgres-(server|client-versions|migration-heads)=|ERROR swift-stage stage=backup-restore-(begin|baseline-begin|baseline-end|request-begin|request-end|wait-begin|wait-end|verify-begin|verify-failed|verify-failed-(status-(state|reachability|version|storage|provider-identity|assignments|backup|endpoint)|snapshot|message|attachment-metadata|attachment-bytes)|verify-end|success|end)( |$)|ERROR release-backup-restore step=(prepare|preflight-container-names|stop-node|backup-execute|backup-verify|backup-publish|negative-fixture-build|negative-case|restore-execute|restore-verify|database-reference) status=failed$|ERROR release-backup-restore prepare-step=(context|journal-load|key|reader-open|manifest|deletion-before|references|manifest-digest|plan|journal-staging|database-create|attachments-create|payload|payload-context|payload-database-restore|payload-database-client|payload-database-connection|payload-database-archive-input|payload-database-sql-execution|payload-database-process|payload-database-context|payload-attachment-write|payload-integrity|database-validate|attachments-seal|payload-eof|reader-close|deletion-after|journal-prepared)$|ERROR release-backup-restore commit-step=(journal-intent|verify-current|database-check|database-switch|attachment-check|attachment-switch|activation|active-verification|retirement|committed-journal)$|ERROR release-backup-restore post-child-step=(reference-validation|quarantine|attachment-quarantine|audit-secret-promotion|node-start|readiness|marker-publish) status=(begin|passed|failed)$|ERROR release-backup-restore failure category=(config|lock|source|assembly|prepare|digest|commit|teardown|pty|unknown)$|ERROR release-backup-restore action-deadline-exceeded step=(cleanup|database-quarantine|node-start|readiness)( |$)|ERROR release-backup-restore (active-database-reference-invalid|runtime evidence unavailable)( |$)|active release database reference is (unavailable|not a restore database); values suppressed( |$)|ERROR private database audit failed category=unknown$|ERROR private database audit failed category=inputs( subcategory=(central-database-file|node-one-database-file|node-two-database-file|actual-patterns|database-argument-mode|unknown)( reason=(missing-open|stat-type|mode|owner|link-count|empty-size|changed-during-read|url-invalid|tls-mode|unknown))?)?$|ERROR private database audit failed category=(returned-inputs|central-connect|central-marker-query|central-marker-count|central-contamination-guard|central-returned-contamination-guard|central-returned-counts-query|central-returned-counts|node-one-marker-count|node-two-marker-count)( cell=[^[:space:]]+)?$|ERROR private database audit failed category=(node-one-connect|node-one-marker-query|node-two-connect|node-two-marker-query)( reason=(relation-missing|permission|canceled-deadline|connection|unknown))?$|private acceptance cleanup failed category=(cleanup-reentry|compose-down|containers-query|containers-remove|containers-retained|runtime-image|volumes-query|volumes-remove|volumes-retained|networks-query|networks-remove|networks-retained|generated-cache|private-temp)( |$)|ERROR acceptance-fixture-restart fixture=(imap-fixture|smtp-fixture) event=(container-resolve|compose-restart|probe|status-capture)( |$)|ERROR acceptance-fixture-restart fixture=(imap-fixture|smtp-fixture) event=crash-classification exit_code=[0-9]+ oom=(true|false) (cause=(sqlite-busy-locked|sqlite-schema|bind-address|signal|python-runtime-error|python-value-error|python-os-error|python-ssl-error|python-exception|unknown)( |$)|cause=sqlite-operational sqlite_subcategory=(locked|open|disk-io|schema|readonly|corrupt|other|none) sqlite_operation=(wal-open|transaction|schema-migration|schema-create|projection-repair|read|other|none)( |$))|ERROR controller-(child-timeout|descendant-survived|child-reaped) action=(restart-(imap-fixture|smtp-fixture)|release-backup-restore-(run|cleanup|database-quarantine|node-start))( |$))' \
    "$private_owner_log" |
  awk '
    /^ERROR swift-stage stage=backup-restore-verify-failed( |$)/ {
      if ($0 != "ERROR swift-stage stage=backup-restore-verify-failed") next
    }
    /^ERROR swift-stage stage=backup-restore-verify-failed-/ {
      if ($0 !~ /^ERROR swift-stage stage=backup-restore-verify-failed-(status-(state|reachability|version|storage|provider-identity|assignments|backup|endpoint)|snapshot|message|attachment-metadata|attachment-bytes)$/) next
    }
    /^ERROR private database audit failed category=/ {
      if ($0 ~ /^ERROR private database audit failed category=inputs( |$)/) {
        subcategory = "unknown"
        reason = ""
        for (field = 1; field <= NF; field++) {
          if ($field ~ /^subcategory=/) subcategory = substr($field, 13)
          if ($field ~ /^reason=/) reason = substr($field, 8)
        }
        if (subcategory == "central-database-file" || subcategory == "node-one-database-file" || subcategory == "node-two-database-file" || subcategory == "actual-patterns" || subcategory == "database-argument-mode" || subcategory == "unknown")
          if (reason == "missing-open" || reason == "stat-type" || reason == "mode" || reason == "owner" || reason == "link-count" || reason == "empty-size" || reason == "changed-during-read" || reason == "url-invalid" || reason == "tls-mode")
            print "ERROR private database audit failed category=inputs subcategory=" subcategory " reason=" reason
          else
            print "ERROR private database audit failed category=inputs subcategory=" subcategory
        else
          print "ERROR private database audit failed category=inputs subcategory=unknown"
        next
      }
      cell_start = index($0, " cell=")
      if (cell_start == 0) {
        print
        next
      }
      cell = substr($0, cell_start + 6)
      if (cell == "node_enrollment_claims.endpoint_ciphertext" ||
          cell == "node_enrollment_claims.setup_verifier" ||
          cell == "node_enrollment_claims.signing_public_key" ||
          cell == "node_enrollment_claims.agreement_public_key" ||
          cell == "node_enrollment_claims.noise_static_public_key" ||
          cell == "node_enrollment_results.credential_result_ciphertext" ||
          cell == "node_enrollment_results.replacement_evidence_wire" ||
          cell == "encrypted_account_records.record_wire" ||
          cell == "encrypted_account_records.envelope") print
      else print substr($0, 1, cell_start - 1)
      next
    }
    { print }
  ' | tail -80 || true
  {
    grep -E '^node-two-schema-checkpoint phase=(initial-ready|after-restarts|before-privacy-audit) status=passed state=reset$' "$private_owner_log" || true
    grep -E '^node-two-schema-checkpoint phase=(initial-ready|after-restarts|before-privacy-audit) status=failed cause=(reset-query|reset-probe|reset-mismatch)$' "$private_owner_log" || true
  } | tail -80 || true
  awk '
    function emit(stage, errno_class) {
      printf "filesystem attachment backend failed stage=%s errno_class=%s\n", stage, errno_class
    }
    {
      if (index($0, "[DEBUG-sync-node-startup] filesystem attachment backend failed") == 0) next
      stage = ""
      errno_class = ""
      if ($0 ~ /(^|[,{])"stage":"root-open"([,}]|$)/ || $0 ~ /(^|[[:space:]])stage=root-open([[:space:]]|$)/) stage = "root-open"
      else if ($0 ~ /(^|[,{])"stage":"root-identity"([,}]|$)/ || $0 ~ /(^|[[:space:]])stage=root-identity([[:space:]]|$)/) stage = "root-identity"
      else if ($0 ~ /(^|[,{])"stage":"root-policy"([,}]|$)/ || $0 ~ /(^|[[:space:]])stage=root-policy([[:space:]]|$)/) stage = "root-policy"
      else if ($0 ~ /(^|[,{])"stage":"staging-open\/create"([,}]|$)/ || $0 ~ /(^|[[:space:]])stage=staging-open\/create([[:space:]]|$)/) stage = "staging-open/create"
      else if ($0 ~ /(^|[,{])"stage":"objects-open\/create"([,}]|$)/ || $0 ~ /(^|[[:space:]])stage=objects-open\/create([[:space:]]|$)/) stage = "objects-open/create"
      if ($0 ~ /(^|[,{])"errno_class":"permission"([,}]|$)/ || $0 ~ /(^|[[:space:]])errno_class=permission([[:space:]]|$)/) errno_class = "permission"
      else if ($0 ~ /(^|[,{])"errno_class":"identity-race"([,}]|$)/ || $0 ~ /(^|[[:space:]])errno_class=identity-race([[:space:]]|$)/) errno_class = "identity-race"
      else if ($0 ~ /(^|[,{])"errno_class":"mount-boundary"([,}]|$)/ || $0 ~ /(^|[[:space:]])errno_class=mount-boundary([[:space:]]|$)/) errno_class = "mount-boundary"
      else if ($0 ~ /(^|[,{])"errno_class":"missing"([,}]|$)/ || $0 ~ /(^|[[:space:]])errno_class=missing([[:space:]]|$)/) errno_class = "missing"
      else if ($0 ~ /(^|[,{])"errno_class":"other"([,}]|$)/ || $0 ~ /(^|[[:space:]])errno_class=other([[:space:]]|$)/) errno_class = "other"
      if (stage != "" && errno_class != "") emit(stage, errno_class)
    }
  ' "$private_owner_log"
  awk '
    /^ERROR operations-backup-failure category=auth-config([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=auth-config"
    }
    /^ERROR operations-backup-failure category=runtime-start([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=runtime-start"
    }
    /^ERROR operations-backup-failure category=backup-execute$/ {
      print "ERROR operations-backup-failure category=backup-execute"
    }
    /^ERROR operations-backup-failure category=runtime-stop\/output([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=runtime-stop/output"
    }
    /^ERROR operations-backup-failure category=unknown([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=unknown"
    }
    /^ERROR operations-backup-failure category=backup-execute stage=obligation-reserve([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=backup-execute stage=obligation-reserve"
    }
    /^ERROR operations-backup-failure category=backup-execute stage=quiesce([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=backup-execute stage=quiesce"
    }
    /^ERROR operations-backup-failure category=backup-execute stage=key([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=backup-execute stage=key"
    }
    /^ERROR operations-backup-failure category=backup-execute stage=staging-cleanup\/container-create([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=backup-execute stage=staging-cleanup/container-create"
    }
    /^ERROR operations-backup-failure category=backup-execute stage=postgres-dump([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=backup-execute stage=postgres-dump"
    }
    /^ERROR operations-backup-failure category=backup-execute stage=attachments([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=backup-execute stage=attachments"
    }
    /^ERROR operations-backup-failure category=backup-execute stage=manifest\/finalize([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=backup-execute stage=manifest/finalize"
    }
    /^ERROR operations-backup-failure category=backup-execute stage=publication([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=backup-execute stage=publication"
    }
    /^ERROR operations-backup-failure category=backup-execute stage=obligation-complete([[:space:]]|$)/ {
      print "ERROR operations-backup-failure category=backup-execute stage=obligation-complete"
    }
  ' "$private_owner_log"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  [[ $# -eq 1 ]] || { printf 'release-image failure summary: usage error\n' >&2; exit 1; }
  release_image_failure_summary "$1"
fi
