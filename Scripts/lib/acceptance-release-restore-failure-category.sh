#!/bin/sh

# Classify the one-off restore's private PTY transcript without forwarding
# transcript contents. Every accepted message is an exact fixed diagnostic
# emitted by the operations command; unknown output remains fail-closed.
classify_release_restore_failure() {
  restore_failure_status=${1:-}
  restore_failure_transcript=${2:-}
  case "$restore_failure_status" in
    124|125)
      printf 'pty\n'
      return 0
      ;;
  esac
  [ -f "$restore_failure_transcript" ] || {
    printf 'unknown\n'
    return 0
  }
  awk '
    BEGIN { category = "unknown" }
    {
      sub(/\r$/, "")
      if ($0 == "ERROR operations-restore-failure category=config") category = "config"
      else if ($0 == "ERROR operations-restore-failure category=lock") category = "lock"
      else if ($0 == "ERROR operations-restore-failure category=source") category = "source"
      else if ($0 == "ERROR operations-restore-failure category=assembly") category = "assembly"
      else if ($0 == "ERROR operations-restore-failure category=prepare") category = "prepare"
      else if ($0 == "ERROR operations-restore-failure category=digest") category = "digest"
      else if ($0 == "ERROR operations-restore-failure category=commit") category = "commit"
      else if ($0 == "ERROR operations-restore-failure category=teardown") category = "teardown"
    }
    END { print category }
  ' "$restore_failure_transcript" || printf 'unknown\n'
}

# Return only an exact Prepare step from the closed operations vocabulary.
# Child stderr, database errors, URLs, and suffixed fields remain unknown.
classify_release_restore_prepare_step() {
  restore_prepare_transcript=${1:-}
  [ -f "$restore_prepare_transcript" ] || {
    printf 'unknown\n'
    return 0
  }
  awk '
    BEGIN { step = "unknown" }
    {
      sub(/\r$/, "")
      if ($0 == "ERROR operations-restore-prepare step=context") step = "context"
      else if ($0 == "ERROR operations-restore-prepare step=journal-load") step = "journal-load"
      else if ($0 == "ERROR operations-restore-prepare step=key") step = "key"
      else if ($0 == "ERROR operations-restore-prepare step=reader-open") step = "reader-open"
      else if ($0 == "ERROR operations-restore-prepare step=manifest") step = "manifest"
      else if ($0 == "ERROR operations-restore-prepare step=deletion-before") step = "deletion-before"
      else if ($0 == "ERROR operations-restore-prepare step=references") step = "references"
      else if ($0 == "ERROR operations-restore-prepare step=manifest-digest") step = "manifest-digest"
      else if ($0 == "ERROR operations-restore-prepare step=plan") step = "plan"
      else if ($0 == "ERROR operations-restore-prepare step=journal-staging") step = "journal-staging"
      else if ($0 == "ERROR operations-restore-prepare step=database-create") step = "database-create"
      else if ($0 == "ERROR operations-restore-prepare step=attachments-create") step = "attachments-create"
      else if ($0 == "ERROR operations-restore-prepare step=payload") step = "payload"
      else if ($0 == "ERROR operations-restore-prepare step=payload-context") step = "payload-context"
      else if ($0 == "ERROR operations-restore-prepare step=payload-database-restore") step = "payload-database-restore"
      else if ($0 == "ERROR operations-restore-prepare step=payload-database-client") step = "payload-database-client"
      else if ($0 == "ERROR operations-restore-prepare step=payload-database-connection") step = "payload-database-connection"
      else if ($0 == "ERROR operations-restore-prepare step=payload-database-archive-input") step = "payload-database-archive-input"
      else if ($0 == "ERROR operations-restore-prepare step=payload-database-sql-execution") step = "payload-database-sql-execution"
      else if ($0 == "ERROR operations-restore-prepare step=payload-database-process") step = "payload-database-process"
      else if ($0 == "ERROR operations-restore-prepare step=payload-database-context") step = "payload-database-context"
      else if ($0 == "ERROR operations-restore-prepare step=payload-attachment-write") step = "payload-attachment-write"
      else if ($0 == "ERROR operations-restore-prepare step=payload-integrity") step = "payload-integrity"
      else if ($0 == "ERROR operations-restore-prepare step=database-validate") step = "database-validate"
      else if ($0 == "ERROR operations-restore-prepare step=attachments-seal") step = "attachments-seal"
      else if ($0 == "ERROR operations-restore-prepare step=payload-eof") step = "payload-eof"
      else if ($0 == "ERROR operations-restore-prepare step=reader-close") step = "reader-close"
      else if ($0 == "ERROR operations-restore-prepare step=deletion-after") step = "deletion-after"
      else if ($0 == "ERROR operations-restore-prepare step=journal-prepared") step = "journal-prepared"
    }
    END { print step }
  ' "$restore_prepare_transcript" || printf 'unknown\n'
}

# Return only an exact Commit step from the closed operations vocabulary.
# Transcript contents and child errors are never forwarded.
classify_release_restore_commit_step() {
  restore_commit_transcript=${1:-}
  [ -f "$restore_commit_transcript" ] || {
    printf 'unknown\n'
    return 0
  }
  awk '
    BEGIN { step = "unknown" }
    {
      sub(/\r$/, "")
      if ($0 == "ERROR operations-restore-commit step=journal-intent") step = "journal-intent"
      else if ($0 == "ERROR operations-restore-commit step=verify-current") step = "verify-current"
      else if ($0 == "ERROR operations-restore-commit step=database-check") step = "database-check"
      else if ($0 == "ERROR operations-restore-commit step=database-switch") step = "database-switch"
      else if ($0 == "ERROR operations-restore-commit step=attachment-check") step = "attachment-check"
      else if ($0 == "ERROR operations-restore-commit step=attachment-switch") step = "attachment-switch"
      else if ($0 == "ERROR operations-restore-commit step=activation") step = "activation"
      else if ($0 == "ERROR operations-restore-commit step=active-verification") step = "active-verification"
      else if ($0 == "ERROR operations-restore-commit step=retirement") step = "retirement"
      else if ($0 == "ERROR operations-restore-commit step=committed-journal") step = "committed-journal"
    }
    END { print step }
  ' "$restore_commit_transcript" || printf 'unknown\n'
}
