#!/bin/zsh

ios_e2e_add_visual_environment_value() {
    local test_run="$1"
    local key="$2"
    local value="$3"
    rtk /usr/libexec/PlistBuddy -c \
      "Add :PlainpostUITests:TestingEnvironmentVariables:$key string $value" \
      "$test_run"
}

ios_e2e_forward_visual_environment() {
    local test_run="$1"
    local key=""
    local value=""

    for key in \
      PLAINPOST_VISUAL_REDUCE_TRANSPARENCY \
      PLAINPOST_VISUAL_REDUCE_MOTION \
      PLAINPOST_VISUAL_INCREASED_CONTRAST \
      PLAINPOST_E2E_VISUAL_RTL; do
        value="$(rtk printenv "$key" 2>/dev/null || true)"
        [[ "$value" == "1" ]] || continue
        ios_e2e_add_visual_environment_value "$test_run" "$key" "$value"
    done

    value="$(rtk printenv PLAINPOST_VISUAL_DYNAMIC_TYPE 2>/dev/null || true)"
    case "$value" in
        xxxl|accessibility3|accessibility5)
            ios_e2e_add_visual_environment_value \
              "$test_run" PLAINPOST_VISUAL_DYNAMIC_TYPE "$value"
            ;;
    esac

    value="$(rtk printenv PLAINPOST_VISUAL_DARK_MODE 2>/dev/null || true)"
    if [[ "$value" == "1" ]]; then
        ios_e2e_add_visual_environment_value \
          "$test_run" PLAINPOST_VISUAL_DARK_MODE "$value"
    fi
}
