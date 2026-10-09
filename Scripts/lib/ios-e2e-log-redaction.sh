#!/bin/zsh

redact_ios_fixture_log() {
    local fixture_log="$1"
    rtk sed -E \
      -e 's/(PLAINPOST_E2E_INVITATION_BASE64=)[^[:space:]]+/\1[REDACTED]/g' \
      -e 's/(PLAINPOST_E2E_CONTROL_TOKEN=)[^[:space:]]+/\1[REDACTED]/g' \
      "$fixture_log"
}
