#!/bin/sh

task7_privacy_audit_category_from_output() {
  task7_category_output=$1
  task7_category=unknown
  while IFS= read -r task7_category_line; do
    case "$task7_category_line" in
      "sync node Task 7 privacy audit unavailable category="*)
        task7_candidate=${task7_category_line#sync node Task 7 privacy audit unavailable category=}
        task7_candidate=${task7_candidate%% *}
        case "$task7_candidate" in
          inputs|returned-inputs|central-connect|central-marker-query|central-marker-count|central-contamination-guard|central-returned-contamination-guard|central-returned-counts-query|central-returned-counts|node-one-connect|node-one-marker-query|node-one-marker-count|node-two-connect|node-two-marker-query|node-two-marker-count)
            task7_category=$task7_candidate
            ;;
        esac
        ;;
    esac
  done <"$task7_category_output"
  printf '%s\n' "$task7_category"
}

task7_privacy_audit_input_subcategory_from_output() {
  task7_input_output=$1
  task7_input_subcategory=unknown
  while IFS= read -r task7_input_line; do
    case "$task7_input_line" in
      "sync node Task 7 privacy audit unavailable category=inputs subcategory="*)
        task7_candidate=${task7_input_line#sync node Task 7 privacy audit unavailable category=inputs subcategory=}
        task7_candidate=${task7_candidate%% *}
        case "$task7_candidate" in
          central-database-file|node-one-database-file|node-two-database-file|actual-patterns|database-argument-mode|unknown)
            task7_input_subcategory=$task7_candidate
            ;;
        esac
        ;;
    esac
  done <"$task7_input_output"
  printf '%s\n' "$task7_input_subcategory"
}

task7_privacy_audit_input_reason_from_output() {
  task7_input_reason_output=$1
  task7_input_reason=unknown
  while IFS= read -r task7_input_reason_line; do
    case "$task7_input_reason_line" in
      "sync node Task 7 privacy audit unavailable category=inputs subcategory="*)
        task7_candidate=${task7_input_reason_line#sync node Task 7 privacy audit unavailable category=inputs subcategory=}
        case "$task7_candidate" in
          *" reason="*) ;;
          *) continue ;;
        esac
        task7_input_subcategory_candidate=${task7_candidate%% reason=*}
        task7_input_reason_candidate=${task7_candidate#* reason=}
        case "$task7_input_subcategory_candidate" in
          central-database-file|node-one-database-file|node-two-database-file) ;;
          *) continue ;;
        esac
        case "$task7_input_reason_candidate" in
          missing-open|stat-type|mode|owner|link-count|empty-size|changed-during-read|url-invalid|tls-mode)
            task7_input_reason=$task7_input_reason_candidate
            ;;
        esac
        ;;
    esac
  done <"$task7_input_reason_output"
  printf '%s\n' "$task7_input_reason"
}

task7_privacy_audit_input_failure_from_output() {
  task7_input_failure_output=$1
  task7_input_failure_subcategory=unknown
  task7_input_failure_reason=unknown
  while IFS= read -r task7_input_failure_line; do
    case "$task7_input_failure_line" in
      "sync node Task 7 privacy audit unavailable category=inputs subcategory="*)
        task7_candidate=${task7_input_failure_line#sync node Task 7 privacy audit unavailable category=inputs subcategory=}
        case "$task7_candidate" in
          central-database-file|node-one-database-file|node-two-database-file|actual-patterns|database-argument-mode|unknown)
            task7_input_failure_subcategory=$task7_candidate
            task7_input_failure_reason=unknown
            ;;
          central-database-file\ reason=*|node-one-database-file\ reason=*|node-two-database-file\ reason=*)
            task7_pair_subcategory=${task7_candidate%% reason=*}
            task7_pair_reason=${task7_candidate#* reason=}
            case "$task7_pair_reason" in
              missing-open|stat-type|mode|owner|link-count|empty-size|changed-during-read|url-invalid|tls-mode)
                task7_input_failure_subcategory=$task7_pair_subcategory
                task7_input_failure_reason=$task7_pair_reason
                ;;
            esac
            ;;
        esac
        ;;
    esac
  done <"$task7_input_failure_output"
  printf '%s %s\n' "$task7_input_failure_subcategory" "$task7_input_failure_reason"
}

task7_privacy_audit_cell_from_output() {
  task7_cell_output=$1
  task7_cell=unknown
  while IFS= read -r task7_cell_line; do
    case "$task7_cell_line" in
      "sync node Task 7 privacy audit unavailable category=central-marker-count cell="*)
        task7_candidate=${task7_cell_line#sync node Task 7 privacy audit unavailable category=central-marker-count cell=}
        task7_candidate=${task7_candidate%% *}
        case "$task7_candidate" in
          node_enrollment_claims.endpoint_ciphertext|node_enrollment_claims.setup_verifier|node_enrollment_claims.signing_public_key|node_enrollment_claims.agreement_public_key|node_enrollment_claims.noise_static_public_key|node_enrollment_results.credential_result_ciphertext|node_enrollment_results.replacement_evidence_wire|encrypted_account_records.record_wire|encrypted_account_records.envelope)
            task7_cell=$task7_candidate
            ;;
        esac
        ;;
    esac
  done <"$task7_cell_output"
  printf '%s\n' "$task7_cell"
}

task7_privacy_audit_node_failure_from_output() {
  task7_node_failure_output=$1
  task7_node_failure_category=unknown
  task7_node_failure_reason=unknown
  while IFS= read -r task7_node_failure_line; do
    case "$task7_node_failure_line" in
      "sync node Task 7 privacy audit unavailable category="*)
        task7_node_failure_candidate=${task7_node_failure_line#*category=}
        task7_node_failure_candidate=${task7_node_failure_candidate%% *}
        case "$task7_node_failure_candidate" in
          node-one-connect|node-one-marker-query|node-two-connect|node-two-marker-query) ;;
          *) continue ;;
        esac
        task7_node_failure_category=$task7_node_failure_candidate
        task7_node_failure_reason=unknown
        case "$task7_node_failure_line" in
          "sync node Task 7 privacy audit unavailable category=$task7_node_failure_candidate reason="*)
            task7_candidate=${task7_node_failure_line#* reason=}
            case "$task7_candidate" in
              relation-missing|missing-node-installation-state|missing-node-current-authority-state|missing-node-secrets|permission|canceled-deadline|connection|unknown)
                task7_node_failure_reason=$task7_candidate
                ;;
            esac
            ;;
        esac
        ;;
    esac
  done <"$task7_node_failure_output"
  printf '%s %s\n' "$task7_node_failure_category" "$task7_node_failure_reason"
}
