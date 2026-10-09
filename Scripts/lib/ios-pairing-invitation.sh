#!/bin/zsh

read_ios_pairing_invitation() {
    local invitation_file="$1"
    local invitation="$(<"$invitation_file")"
    [[ -n "$invitation" ]] || return 1

    local source_hash="$(rtk shasum -a 256 "$invitation_file" | rtk awk '{ print $1 }')"
    local forwarded_hash="$(rtk printf %s "$invitation" | rtk shasum -a 256 | rtk awk '{ print $1 }')"
    [[ "$source_hash" == "$forwarded_hash" ]] || return 1

    if ! rtk printf %s "$invitation" | rtk base64 -D | rtk jq -e '
      .protocolVersion == 1 and (.endpoint.host.port | type == "number")
    ' >/dev/null; then
        return 1
    fi
    rtk printf %s "$invitation"
}
