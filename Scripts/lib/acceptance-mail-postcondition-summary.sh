#!/bin/sh

# Keep postcondition failures useful after the private owner removes its
# temporary fixture: only the fixed classification crosses into the runtime
# summary. Never copy the control command's diagnostic text or authoritative
# mail values into the owner log.
acceptance_mail_postcondition_failure_summary() {
  result_file=$1
  runtime_log=$2
  category=unclassified
  if [ -f "$result_file" ]; then
    result_category=$(sed -n 's/^postcondition-category=\(.*\)$/\1/p' "$result_file" | sed -n '1p')
    case "$result_category" in
      delivery-count|delivery-identity|delivery-security|draft-state|sent-state|envelope|content-security|correlation)
        category=$result_category
        ;;
    esac
  fi
  printf 'ERROR acceptance-mail-postcondition outcome=mismatch category=%s\n' "$category" >>"$runtime_log"
}
