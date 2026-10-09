#!/bin/sh

# Keep privacy pattern values in the existing flat scan file and record their
# fixed origin in a separate 0600 sidecar. The sidecar is never emitted.
acceptance_privacy_pattern_append() {
  acceptance_privacy_patterns=$1
  acceptance_privacy_origins=$2
  acceptance_privacy_origin=$3
  acceptance_privacy_value=$4
  case "$acceptance_privacy_origin" in
    s3-access|s3-secret|provider-password|returned-client) ;;
    *) return 2 ;;
  esac
  [ -n "$acceptance_privacy_value" ] || return 0
  printf '%s\n' "$acceptance_privacy_value" >>"$acceptance_privacy_patterns"
  printf '%s\t%s\n' "$acceptance_privacy_origin" "$acceptance_privacy_value" >>"$acceptance_privacy_origins"
}

acceptance_privacy_classify_match() {
  acceptance_privacy_scan_file=$1
  acceptance_privacy_origins=$2
  acceptance_privacy_match_origin=unknown
  [ -s "$acceptance_privacy_origins" ] || return 0
  while IFS="$(printf '\t')" read -r acceptance_privacy_origin acceptance_privacy_value; do
    case "$acceptance_privacy_origin" in
      s3-access|s3-secret|provider-password|returned-client) ;;
      *) continue ;;
    esac
    [ -n "$acceptance_privacy_value" ] || continue
    if grep -F -q -- "$acceptance_privacy_value" "$acceptance_privacy_scan_file"; then
      acceptance_privacy_match_origin=$acceptance_privacy_origin
      return 0
    fi
  done <"$acceptance_privacy_origins"
}

acceptance_scan_privacy_file() {
  acceptance_privacy_scan_file=$1
  acceptance_privacy_source=$2
  acceptance_privacy_patterns=$3
  acceptance_privacy_origins=$4
  acceptance_privacy_diagnostic=$5
  case "$acceptance_privacy_source" in
    runtime-log|container-log|runtime-config|error-surface) ;;
    *) return 2 ;;
  esac
  [ -r "$acceptance_privacy_scan_file" ] || return 2
  [ -f "$acceptance_privacy_patterns" ] || return 2
  if grep -F -f "$acceptance_privacy_patterns" "$acceptance_privacy_scan_file" >/dev/null 2>&1; then
    acceptance_privacy_classify_match "$acceptance_privacy_scan_file" "$acceptance_privacy_origins"
    printf 'ERROR acceptance-privacy-match source=%s origin=%s\n' \
      "$acceptance_privacy_source" "$acceptance_privacy_match_origin" >>"$acceptance_privacy_diagnostic"
    return 1
  else
    acceptance_privacy_status=$?
  fi
  [ "$acceptance_privacy_status" -eq 1 ] || return 2
}

acceptance_privacy_record_pattern_file_tail() {
  acceptance_privacy_pattern_file=$1
  acceptance_privacy_origins=$2
  acceptance_privacy_origin=$3
  acceptance_privacy_start_line=$4
  case "$acceptance_privacy_origin" in
    returned-client) ;;
    *) return 2 ;;
  esac
  [ -f "$acceptance_privacy_pattern_file" ] || return 0
  acceptance_privacy_tail_start=$((acceptance_privacy_start_line + 1))
  tail -n "+$acceptance_privacy_tail_start" "$acceptance_privacy_pattern_file" |
    while IFS= read -r acceptance_privacy_value; do
      [ -n "$acceptance_privacy_value" ] || continue
      printf '%s\t%s\n' "$acceptance_privacy_origin" "$acceptance_privacy_value" >>"$acceptance_privacy_origins"
    done
}

acceptance_privacy_import_tab_patterns() {
  acceptance_privacy_tab_file=$1
  acceptance_privacy_patterns=$2
  acceptance_privacy_origins=$3
  acceptance_privacy_origin=$4
  case "$acceptance_privacy_origin" in
    returned-client) ;;
    *) return 2 ;;
  esac
  [ -f "$acceptance_privacy_tab_file" ] || return 0
  while IFS="$(printf '\t')" read -r acceptance_privacy_label acceptance_privacy_value; do
    [ -n "$acceptance_privacy_value" ] || continue
    acceptance_privacy_pattern_append "$acceptance_privacy_patterns" "$acceptance_privacy_origins" "$acceptance_privacy_origin" "$acceptance_privacy_value" || return 1
  done <"$acceptance_privacy_tab_file"
}
