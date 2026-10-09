#!/usr/bin/env bash
set -euo pipefail
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
aasa="$root_dir/Deploy/sync-node/apple-app-site-association.json"
entitlements="$root_dir/Apps/PlainpostiOS/Config/Plainpost.entitlements"
domain="$(awk -F' = ' '/^PLAINPOST_GOOGLE_REDIRECT_HOST = / {print $2}' "$root_dir/Apps/PlainpostiOS/Config/Base.xcconfig")"
redirect="$(awk -F' = ' '/^PLAINPOST_GOOGLE_REDIRECT_URI = / {print $2}' "$root_dir/Apps/PlainpostiOS/Config/Base.xcconfig")"
team="$(awk -F' = ' '/^[[:space:]]*DEVELOPMENT_TEAM = / {gsub(/;/,"",$2); print $2; exit}' "$root_dir/Apps/PlainpostiOS/Plainpost.xcodeproj/project.pbxproj")"
bundle="$(awk -F' = ' '/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER = com\.marynavdovenko\.Plainpost\.iOS;/ {gsub(/;/,"",$2); print $2; exit}' "$root_dir/Apps/PlainpostiOS/Plainpost.xcodeproj/project.pbxproj")"
[[ -s "$aasa" && -s "$entitlements" ]] || { echo "associated-domain evidence is missing" >&2; exit 1; }
/usr/bin/python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$aasa"
grep -Fq 'applinks:$(PLAINPOST_GOOGLE_REDIRECT_HOST)' "$entitlements"
[[ "$redirect" == "https://$domain/oauth/google" ]] || { echo "callback URI and associated domain disagree" >&2; exit 1; }
[[ -n "$team" && "$team" != "TEAM_ID" && "$team" =~ ^[A-Z0-9]{10}$ ]] || { echo "project development team is missing or placeholder" >&2; exit 1; }
[[ -n "$bundle" && "$bundle" != *'$(PRODUCT_BUNDLE_IDENTIFIER)'* ]] || { echo "project bundle identity is missing or unresolved" >&2; exit 1; }
expected_app_id="$team.$bundle"
/usr/bin/python3 - "$aasa" "$expected_app_id" <<'PY'
import json
import sys

path, expected_app_id = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    actual = json.load(handle)
expected = {
    "applinks": {
        "details": [{
            "appIDs": [expected_app_id],
            "components": [{
                "/": "/oauth/google*",
                "comment": "Plainpost Google OAuth HTTPS callback",
            }],
        }],
    },
}
if actual != expected:
    raise SystemExit("AASA does not exactly match the single expected OAuth callback detail")
PY
echo "local associated-domain contract is valid for $domain ($expected_app_id); live Apple HTTPS deployment remains unverified"
