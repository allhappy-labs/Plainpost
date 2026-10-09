#!/usr/bin/env bash
set -euo pipefail

# Calendar interoperability and lifecycle acceptance runner.
#
#   Scripts/test-calendar-e2e.sh --fixture
#     Starts only task-owned disposable services, labelled
#     plainpost.task=calendar-e2e and plainpost.run=<run id>:
#       - PostgreSQL 18 (Node storage)
#       - sabredav-basic:     sabre/dav 4.7.0 minimal RFC 4791 server (no
#                             sync-collection, no scheduling)
#       - baikal-scheduling:  stock Baikal 0.10.1 (sabre/dav 4.7.0 with RFC 6638
#                             scheduling and RFC 6578 sync-token)
#       - radicale-sync:      Radicale 3.8.0 (sync-token, no scheduling)
#     plus in-process TLS fault, SMTP sink and Google provider fixtures owned by
#     the Go acceptance tests. Every required Go owner must PASS; a skip, an
#     absent owner or any failure fails the run. Containers are removed on exit.
#
#   Scripts/test-calendar-e2e.sh --live
#     Refuses to run unless PLAINPOST_CALENDAR_LIVE_AUTHORIZED=1 and
#     PLAINPOST_CALENDAR_TEST_CONFIG names an owner-only, git-ignored or
#     out-of-tree regular file whose authorization scope and recipient
#     allowlist validate before any send. The file is never printed.
#
# Output is limited to opaque case IDs, outcomes, UTC timestamps, versions,
# image digests and artifact paths. Secrets (random per run) stay in an
# owner-only temporary directory that is removed on exit.

readonly postgres_image="postgres:18.6-alpine3.24@sha256:d3e1620b530c944afa6e887d22eb899824da68e19c52024bf98f5220c88a65b2"
readonly baikal_image="ckulka/baikal:0.10.1-nginx@sha256:434bdd162247cc6aa6f878c9b4dce6216e39e79526b980453b13812d5f8ebf4b"
readonly radicale_image="tomsquest/docker-radicale:3.8.0.0@sha256:d311a35c91acb341c509fa8c692bd280720a6c3e73aa5d9a743453eeed4341c3"
readonly task_label="plainpost.task=calendar-e2e"
readonly live_authorization_scope="plainpost-calendar-live-acceptance-v1"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly go_root="$repo_root/Services/PlainpostGo"
readonly assets="$repo_root/Scripts/calendar-e2e"

# Fixture case ID -> required Go owner. Each must print its own --- PASS line.
readonly -a fixture_cases=(
	"server-matrix-negotiation:TestCalendarAcceptanceServerMatrixNegotiatesCapabilities"
	"purelymail-compatible-edit:TestCalendarAcceptanceGenericCalDAVEditPreservesSource"
	"basic-rsvp-accept-maybe-decline:TestCalendarAcceptanceBasicRSVPEachResponse"
	"scheduling-rsvp-zero-smtp:TestCalendarAcceptanceSchedulingRSVPZeroSMTP"
	"google-missing-invite:TestCalendarAcceptanceGoogleMissingInviteUnresolved"
	"partial-response:TestCalendarAcceptancePartialResponseRetriesOnlySafePhase"
	"lost-smtp-ack:TestCalendarAcceptanceLostSMTPAcknowledgementNeverResends"
	"lost-caldav-ack:TestCalendarAcceptanceLostCalDAVAcknowledgementReconciles"
	"recurrence-dst:TestCalendarAcceptanceRecurrenceAcrossDST"
	"accounts-equal-uid-switch:TestCalendarAcceptanceEqualUIDAcrossConnectionsAndSwitch"
	"compatibility-old-new-node:TestCalendarAcceptanceNodeCompatibility"
	"lifecycle-pending-work:TestCalendarAcceptanceLifecyclePendingWork"
	"mailbox-remap-required:TestCalendarAcceptanceUnmappedMailboxRequiresRemap"
	"live-gate-refusal:TestCalendarE2ERunnerLiveRefusesWithoutAuthorization"
	"live-gate-allowlist:TestCalendarLiveConfigValidationRefusesUnsafeConfigs"
	"runner-privacy:TestCalendarE2ERunnerFailureOutputAndLiveLogAreRedactedAndBounded"
	"invitation-worker-lifetime:TestCalendarAcceptanceInvitationStaysActionableAcrossWorkerLifetime"
	"series-occurrence-invitation:TestCalendarAcceptanceSeriesOccurrenceInvitationOutsideBrowsedWeeks"
	"unprojectable-resource:TestCalendarAcceptanceUnprojectableResourceLeavesCalendarVisible"
	"thread-discovery-sessions:TestCalendarAcceptanceThreadInvitationDiscoveryOpensOneSession"
	"failed-reconnect-pending-work:TestCalendarAcceptanceFailedReconnectKeepsPendingWork"
	"unseen-invitation-destination:TestCalendarAcceptanceUnseenInvitationUsesChosenCalendar"
	"updated-invitation-response:TestCalendarAcceptanceUpdatedInvitationRespondsToExistingCopy"
	"disconnect-settles-retained-responses:TestCalendarAcceptanceDisconnectSettlesRetainedResponses"
)
# Cases that need authorized live accounts. The fixture run reports them
# BLOCKED; only --live can execute them.
readonly -a live_cases=(
	"live-google-edit:TestCalendarLiveGoogleEdit"
	"live-purelymail-edit:TestCalendarLivePurelymailEdit"
	"live-basic-rsvp-organizer-evidence:TestCalendarLiveBasicRSVPOrganizerEvidence"
	"live-scheduling-server-zero-smtp:TestCalendarLiveSchedulingServer"
	"live-google-rsvp:TestCalendarLiveGoogleRSVP"
)

usage() {
	echo "usage: $0 --fixture | --live" >&2
	exit 2
}

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

run_id=""
temp_root=""
declare -a created_containers=()

cleanup() {
	local status="$?"
	trap - EXIT INT TERM
	local name
	if ((${#created_containers[@]})); then
		for name in "${created_containers[@]}"; do
			if ! docker container rm --force --volumes "$name" >/dev/null 2>&1; then
				echo "cleanup: could not remove container $name" >&2
				status=1
			fi
		done
	fi
	if [[ -n "$run_id" ]] && command -v docker >/dev/null 2>&1; then
		local remaining
		if ! remaining="$(docker ps -aq --filter "label=$task_label" --filter "label=plainpost.run=$run_id" 2>/dev/null)"; then
			echo "cleanup: could not list task-owned containers for run $run_id" >&2
			status=1
		elif [[ -n "$remaining" ]]; then
			echo "cleanup: task-owned containers remain for run $run_id" >&2
			status=1
		fi
	fi
	if [[ -n "$temp_root" && -e "$temp_root" ]]; then
		if ! rm -rf "$temp_root" || [[ -e "$temp_root" ]]; then
			echo "cleanup: temp root remains: $temp_root" >&2
			status=1
		fi
	fi
	exit "$status"
}

make_temp_root() {
	run_id="$(printf '%s-%s' "$$" "$(date +%s)")"
	temp_root="$(mktemp -d "${TMPDIR:-/tmp}/plainpost-calendar-e2e.XXXXXX")"
	chmod 0700 "$temp_root"
}

ensure_image() {
	local image="$1"
	if ! docker image inspect "$image" >/dev/null 2>&1; then
		# Pulls only by immutable digest; a tag alone is never resolved.
		[[ "$image" == *@sha256:* ]] || { echo "refusing to pull an image without a digest" >&2; return 1; }
		docker pull --quiet "$image" >/dev/null
	fi
	local digest
	digest="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image" | grep -F "${image#*@}" | head -n 1)" || digest=""
	[[ -n "$digest" ]] || { echo "image digest mismatch for pinned image" >&2; return 1; }
}

container_create() {
	local name="$1"
	shift
	docker container create --name "$name" --label "$task_label" --label "plainpost.run=$run_id" "$@" >/dev/null
	created_containers+=("$name")
}

host_port() {
	docker port "$1" "$2" | sed -n 's/^127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p' | head -n 1
}

random_secret() { openssl rand -hex 18; }

start_postgres() {
	local name="plainpost-calendar-e2e-pg-$run_id" password port logs
	password="$(random_secret)"
	container_create "$name" --publish 127.0.0.1::5432 --env POSTGRES_PASSWORD="$password" --env POSTGRES_DB=calendar_e2e "$postgres_image"
	docker container start "$name" >/dev/null
	for _ in $(seq 1 90); do
		logs="$(docker container logs --tail 40 "$name" 2>&1)" || logs=""
		if [[ "$logs" == *"PostgreSQL init process complete; ready for start up."* ]] &&
			docker exec "$name" pg_isready -U postgres -d calendar_e2e >/dev/null 2>&1; then
			port="$(host_port "$name" 5432/tcp)"
			[[ -n "$port" ]] || return 1
			printf 'postgres://postgres:%s@127.0.0.1:%s/calendar_e2e?sslmode=disable' "$password" "$port" >"$temp_root/postgres-url"
			printf '%s' "$name" >"$temp_root/postgres-container"
			return 0
		fi
		sleep 1
	done
	echo "calendar e2e PostgreSQL 18 did not become ready" >&2
	return 1
}

# seed_sabre writes users, principals and one default calendar each into the
# Baikal/sabre SQLite schema. The script (with random passwords) is piped over
# stdin and never appears on a command line.
seed_sabre() {
	local name="$1" domain="$2"
	shift 2
	local script="$temp_root/seed-$name.sh" credentials="$temp_root/users-$name.tsv" user password id=0
	: >"$credentials"
	{
		echo 'set -eu'
		echo 'cd /var/www/baikal/Specific/db'
		echo 'sqlite3 db.sqlite < /var/www/baikal/Core/Resources/Db/SQLite/db.sql'
		for user in "$@"; do
			id=$((id + 1))
			password="$(random_secret)"
			printf '%s\t%s\t%s@%s\t/dav.php/calendars/%s/default/\n' "$user" "$password" "$user" "$domain" "$user" >>"$credentials"
			printf "sqlite3 db.sqlite \"INSERT INTO users(username,digesta1) VALUES('%s','\$(printf '%%s' '%s:BaikalDAV:%s' | md5sum | cut -d' ' -f1)'); INSERT INTO principals(uri,email,displayname) VALUES('principals/%s','%s@%s','%s'); INSERT INTO calendars(id,synctoken,components) VALUES(%d,1,'VEVENT,VTODO'); INSERT INTO calendarinstances(calendarid,principaluri,access,displayname,uri,timezone) VALUES(%d,'principals/%s',1,'Default','default','');\"\n" \
				"$user" "$user" "$password" "$user" "$user" "$domain" "$user" "$id" "$id" "$user"
		done
		echo 'chown -R nginx:nginx /var/www/baikal/Specific'
	} >"$script"
	chmod 0600 "$script" "$credentials"
	docker exec -i "$name" sh -s <"$script" >/dev/null
	rm -f "$script"
}

wait_http() {
	local port="$1" path="$2" netrc="$3" code
	for _ in $(seq 1 60); do
		code="$(curl --silent --output /dev/null --write-out '%{http_code}' --netrc-file "$netrc" --request OPTIONS "http://127.0.0.1:$port$path" 2>/dev/null)" || code="unreachable"
		if [[ "$code" == "200" ]]; then
			return 0
		fi
		sleep 1
	done
	echo "calendar server on port $port did not become ready" >&2
	return 1
}

first_netrc() {
	local credentials="$1" out="$2" user password
	IFS=$'\t' read -r user password _ <"$credentials"
	printf 'machine 127.0.0.1 login %s password %s\n' "$user" "$password" >"$out"
	chmod 0600 "$out"
}

start_sabre_basic() {
	local name="plainpost-calendar-e2e-sabredav-basic-$run_id" port
	container_create "$name" --publish 127.0.0.1::80 "$baikal_image"
	docker cp "$assets/baikal.yaml" "$name:/var/www/baikal/config/baikal.yaml" >/dev/null
	docker cp "$assets/sabredav-basic-server.php" "$name:/var/www/baikal/html/dav.php" >/dev/null
	docker container start "$name" >/dev/null
	sleep 2
	seed_sabre "$name" basic.calendar.test u1 u2 u3 u4 u5 u6 u7 u8 u9 u10 u11 u12 u13 u14 u15 u16 u17 u18 u19 u20 u21 u22
	port="$(host_port "$name" 80/tcp)"
	first_netrc "$temp_root/users-$name.tsv" "$temp_root/netrc-basic"
	wait_http "$port" /dav.php/ "$temp_root/netrc-basic"
	local sabre_version
	sabre_version="$(curl --silent --netrc-file "$temp_root/netrc-basic" --request OPTIONS --dump-header - --output /dev/null "http://127.0.0.1:$port/dav.php/" | tr -d '\r' | sed -n 's/^X-Sabre-Version: //Ip' | head -n 1)"
	write_profile sabredav-basic "sabre/dav (minimal CalDAV server, task-owned configuration)" "$sabre_version" "$baikal_image" basic "$port" "$temp_root/users-$name.tsv"
}

start_baikal_scheduling() {
	local name="plainpost-calendar-e2e-baikal-scheduling-$run_id" port
	container_create "$name" --publish 127.0.0.1::80 "$baikal_image"
	docker cp "$assets/baikal.yaml" "$name:/var/www/baikal/config/baikal.yaml" >/dev/null
	docker container start "$name" >/dev/null
	sleep 2
	seed_sabre "$name" scheduling.calendar.test u1 u2 u3 u4 organizer
	port="$(host_port "$name" 80/tcp)"
	first_netrc "$temp_root/users-$name.tsv" "$temp_root/netrc-scheduling"
	wait_http "$port" /dav.php/ "$temp_root/netrc-scheduling"
	local baikal_version sabre_version
	baikal_version="$(docker exec "$name" sed -n 's/.*define("BAIKAL_VERSION", "\([^"]*\)").*/\1/p' /var/www/baikal/Core/Distrib.php)"
	sabre_version="$(curl --silent --netrc-file "$temp_root/netrc-scheduling" --request OPTIONS --dump-header - --output /dev/null "http://127.0.0.1:$port/dav.php/" | tr -d '\r' | sed -n 's/^X-Sabre-Version: //Ip' | head -n 1)"
	write_profile baikal-scheduling "Baikal (stock server, sabre/dav $sabre_version)" "$baikal_version" "$baikal_image" scheduling "$port" "$temp_root/users-$name.tsv"
}

start_radicale() {
	local name="plainpost-calendar-e2e-radicale-sync-$run_id" port user password credentials="$temp_root/users-radicale.tsv" users="$temp_root/radicale-users"
	: >"$credentials"
	: >"$users"
	chmod 0600 "$credentials" "$users"
	for user in u1 u2 u3; do
		password="$(random_secret)"
		printf '%s:%s\n' "$user" "$password" >>"$users"
		printf '%s\t%s\t%s@radicale.calendar.test\t/%s/calendar/\n' "$user" "$password" "$user" "$user" >>"$credentials"
	done
	container_create "$name" --publish 127.0.0.1::5232 "$radicale_image"
	docker cp "$assets/radicale.conf" "$name:/config/config" >/dev/null
	# The Radicale process runs as an unprivileged user; the copied file keeps
	# its host mode, so it is made readable only inside the 0700 temp root.
	chmod 0644 "$users"
	docker cp "$users" "$name:/config/users" >/dev/null
	rm -f "$users"
	docker container start "$name" >/dev/null
	port="$(host_port "$name" 5232/tcp)"
	first_netrc "$credentials" "$temp_root/netrc-radicale"
	wait_http "$port" / "$temp_root/netrc-radicale"
	while IFS=$'\t' read -r user password _ calendar; do
		printf 'machine 127.0.0.1 login %s password %s\n' "$user" "$password" >"$temp_root/netrc-radicale-user"
		chmod 0600 "$temp_root/netrc-radicale-user"
		local code
		code="$(curl --silent --output /dev/null --write-out '%{http_code}' --netrc-file "$temp_root/netrc-radicale-user" --request MKCOL --header 'Content-Type: application/xml' \
			--data '<d:mkcol xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:set><d:prop><d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>Default</d:displayname></d:prop></d:set></d:mkcol>' \
			"http://127.0.0.1:$port$calendar")"
		[[ "$code" == "201" ]] || { echo "radicale calendar creation failed ($code)" >&2; return 1; }
	done <"$credentials"
	rm -f "$temp_root/netrc-radicale-user"
	local radicale_version
	radicale_version="$(docker exec "$name" /venv/bin/python -c 'import radicale; print(radicale.VERSION)')"
	write_profile radicale-sync "Radicale" "$radicale_version" "$radicale_image" sync "$port" "$credentials"
}

write_profile() {
	local id="$1" implementation="$2" version="$3" image="$4" mode="$5" port="$6" credentials="$7"
	python3 - "$temp_root/servers.d/$id.json" "$id" "$implementation" "$version" "$image" "$mode" "$port" "$credentials" <<'PY'
import json, os, sys
out, sid, impl, version, image, mode, port, creds = sys.argv[1:]
users = []
with open(creds) as handle:
    for line in handle:
        name, password, email, calendar = line.rstrip("\n").split("\t")
        users.append({"username": name, "password": password, "email": email, "calendar": calendar})
os.makedirs(os.path.dirname(out), mode=0o700, exist_ok=True)
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as handle:
    json.dump({"id": sid, "implementation": impl, "version": version, "image": image, "mode": mode, "upstream": "http://127.0.0.1:%s" % port, "users": users}, handle)
PY
}

assemble_config() {
	python3 - "$temp_root/servers.d" "$temp_root/calendar-e2e.json" <<'PY'
import json, os, sys
source, out = sys.argv[1:]
servers = [json.load(open(os.path.join(source, name))) for name in sorted(os.listdir(source))]
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as handle:
    json.dump({"servers": servers}, handle)
PY
}

record_versions() {
	local file="$1"
	python3 - "$temp_root/servers.d" >"$file" <<'PY'
import json, os, sys
source = sys.argv[1]
for name in sorted(os.listdir(source)):
    s = json.load(open(os.path.join(source, name)))
    print("calendar e2e server: id=%s implementation=%s version=%s image=%s mode=%s" % (s["id"], s["implementation"], s["version"], s["image"], s["mode"]))
PY
}

run_fixture_owners() {
	local artifacts="$1" log="$temp_root/go-acceptance.log" status=0 entry case test
	local pattern
	pattern="^($(printf '%s\n' "${fixture_cases[@]}" | cut -d: -f2 | paste -sd'|' -))\$"
	(
		cd "$go_root"
		env TEST_POSTGRES_URL="$(<"$temp_root/postgres-url")" PLAINPOST_REQUIRE_LIVE_POSTGRES=1 \
			PLAINPOST_CALENDAR_REQUIRE_INTEROP=1 \
			PLAINPOST_CALENDAR_E2E_CONFIG="$temp_root/calendar-e2e.json" \
			PLAINPOST_CALENDAR_E2E_ARTIFACTS="$artifacts" \
			PLAINPOST_CALENDAR_E2E_PG_CONTAINER="$(<"$temp_root/postgres-container")" \
			go test -race ./internal/acceptance -run "$pattern" -count=1 -v -timeout 30m
	) >"$log" 2>&1 || status=$?
	cp "$log" "$artifacts/go-acceptance.log"
	chmod 0600 "$artifacts/go-acceptance.log"
	local failed=0
	if grep -Eq -- '--- SKIP:|\[no test files\]|no tests to run' "$log"; then
		grep -E -- '--- SKIP:|\[no test files\]|no tests to run' "$log" | sed 's/^/calendar e2e skipped owner: /' >&2
		echo "calendar e2e: a required owner skipped or no tests ran" >&2
		failed=1
	fi
	for entry in "${fixture_cases[@]}"; do
		case="${entry%%:*}"
		test="${entry#*:}"
		if grep -Eq -- "^--- PASS: ${test} \\(" "$log"; then
			echo "calendar e2e case: id=$case outcome=PASS at=$(utc_now)"
		elif grep -Eq -- "^--- (FAIL|SKIP): ${test} \\(" "$log"; then
			echo "calendar e2e case: id=$case outcome=FAIL at=$(utc_now)" >&2
			failed=1
		else
			echo "calendar e2e case: id=$case outcome=ABSENT at=$(utc_now) (required owner did not execute)" >&2
			failed=1
		fi
	done
	if ((status)); then
		sed -nE '/^(---|[[:space:]]+[a-z_]+_test\.go:[0-9]+:|panic:|FAIL)/p' "$log" | grep -v -- '--- PASS' | redact_stream "$temp_root/calendar-e2e.json" "$temp_root/postgres-url" 80 >&2
		echo "calendar e2e: go test exited $status" >&2
		failed=1
	fi
	return "$failed"
}

# Secrets of a run: every credential-like string in the (fixture or live) config
# -- server passwords, tokens, client secrets -- and the PostgreSQL password.
readonly secret_collector='
import json, re, urllib.parse
def collect(config, pg):
    found = []
    def walk(node, key=""):
        if isinstance(node, dict):
            for k, v in node.items():
                walk(v, k)
        elif isinstance(node, list):
            for v in node:
                walk(v, key)
        elif isinstance(node, str) and len(node) >= 4 and re.search(r"pass|secret|token|credential|key", key, re.I):
            found.append(node)
    try:
        walk(json.load(open(config)))
    except Exception:
        pass
    try:
        password = urllib.parse.urlparse(open(pg).read().strip()).password
        if password:
            found.append(password)
    except Exception:
        pass
    return sorted(set(found), key=len, reverse=True)
'

# scan_secrets CONFIG POSTGRES_URL_FILE ROOT fails if any run secret appears in
# an artifact under ROOT. Matches are never printed.
scan_secrets() {
	python3 -c "$secret_collector"'
import os, sys
config, pg, root = sys.argv[1:]
secrets = collect(config, pg)
leaks = 0
for base, _, names in os.walk(root):
    for name in names:
        data = open(os.path.join(base, name), "rb").read()
        leaks += sum(1 for secret in secrets if secret.encode() in data)
if leaks:
    sys.stderr.write("calendar e2e: %d secret occurrence(s) found in artifacts\n" % leaks)
    sys.exit(1)
print("calendar e2e privacy scan: %d artifact secret patterns absent" % len(secrets))
' "$1" "$2" "$3"
}

# scan_artifacts is the fixture privacy scan of one artifact directory.
scan_artifacts() {
	scan_secrets "$temp_root/calendar-e2e.json" "$temp_root/postgres-url" "$1"
}

# redact_stream CONFIG POSTGRES_URL_FILE MAX_LINES prints at most MAX_LINES
# lines of stdin, each bounded to 240 bytes, with every run secret replaced.
redact_stream() {
	python3 -c "$secret_collector"'
import sys
config, pg, limit = sys.argv[1], sys.argv[2], int(sys.argv[3])
secrets = collect(config, pg)
count = 0
for raw in sys.stdin.buffer:
    if count >= limit:
        print("calendar e2e: further failure lines withheld")
        break
    line = raw.decode("utf-8", "replace").rstrip("\n")
    for secret in secrets:
        line = line.replace(secret, "[redacted]")
    encoded = line.encode("utf-8")[:240].decode("utf-8", "ignore")
    for secret in secrets:
        encoded = encoded.replace(secret, "[redacted]")
    print(encoded)
    count += 1
' "$1" "$2" "$3"
}

# opaque_live_log LOG keeps only test outcome lines; provider identifiers and
# assertion text from live runs never reach the artifact.
opaque_live_log() {
	grep -E '^(=== RUN   Test[A-Za-z0-9_/-]+|--- (PASS|FAIL|SKIP): Test[A-Za-z0-9_/-]+ \([0-9.]+s\)|PASS|FAIL|(ok|FAIL)[[:space:]]+[A-Za-z0-9./_-]+([[:space:]]+[0-9.]+s)?)$' "$1" | head -n 400 || true
}

fixture_main() {
	command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
	command -v go >/dev/null || { echo "go is required" >&2; exit 1; }
	make_temp_root
	trap cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	local artifacts="$repo_root/.build/verification/calendar-e2e/$run_id"
	mkdir -p "$artifacts"
	chmod 0700 "$artifacts"
	echo "calendar e2e run: id=$run_id mode=fixture started=$(utc_now) source=$(git -C "$repo_root" rev-parse HEAD)"
	local image
	for image in "$postgres_image" "$baikal_image" "$radicale_image"; do
		ensure_image "$image"
	done
	mkdir -p "$temp_root/servers.d"
	chmod 0700 "$temp_root/servers.d"
	start_postgres
	start_sabre_basic
	start_baikal_scheduling
	start_radicale
	assemble_config
	record_versions "$artifacts/servers.txt"
	cat "$artifacts/servers.txt"
	echo "calendar e2e image: postgres=$postgres_image"
	local status=0
	run_fixture_owners "$artifacts" || status=$?
	scan_artifacts "$artifacts" || status=1
	local entry
	for entry in "${live_cases[@]}"; do
		echo "calendar e2e case: id=${entry%%:*} outcome=BLOCKED at=$(utc_now) reason=requires-authorized-live-accounts"
	done
	echo "calendar e2e artifacts: $artifacts"
	if ((status)); then
		echo "calendar e2e fixture FAILED" >&2
		exit 1
	fi
	echo "calendar e2e fixture PASS (live cases remain BLOCKED)"
}

# ---------------------------------------------------------------------------
# Live mode

live_refuse() {
	echo "calendar e2e live REFUSED: $1" >&2
	exit 3
}

validate_live_config_file() {
	local path="$1"
	[[ "$path" == /* ]] || live_refuse "PLAINPOST_CALENDAR_TEST_CONFIG must be an absolute path"
	[[ ! -L "$path" ]] || live_refuse "config must not be a symbolic link"
	[[ -f "$path" ]] || live_refuse "config is not a regular file"
	local owner mode
	if stat -f '%u' "$path" >/dev/null 2>&1; then
		owner="$(stat -f '%u' "$path")"
		mode="$(stat -f '%Lp' "$path")"
	else
		owner="$(stat -c '%u' "$path")"
		mode="$(stat -c '%a' "$path")"
	fi
	[[ "$owner" == "$(id -u)" ]] || live_refuse "config must be owned by the invoking user"
	[[ "$mode" == "600" || "$mode" == "400" ]] || live_refuse "config must be owner-readable only (0600 or 0400)"
	local directory
	directory="$(cd "$(dirname "$path")" && pwd -P)"
	if git -C "$directory" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		git -C "$directory" check-ignore --quiet "$path" || live_refuse "config inside a git work tree must be git-ignored"
		if git -C "$directory" ls-files --error-unmatch "$path" >/dev/null 2>&1; then
			live_refuse "config must not be tracked by git"
		fi
	fi
}

# The validator reads the file without echoing any of its values. It enforces
# the authorization scope, dedicated test calendars and that every address a
# case could send to is in the explicit recipient allowlist.
validate_live_config_contents() {
	python3 - "$1" "$live_authorization_scope" "$(printf '%s\n' "${live_cases[@]}" | cut -d: -f1 | paste -sd, -)" <<'PY' || live_refuse "config failed validation (details withheld)"
import json, re, sys
path, scope, case_ids = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
address = re.compile(r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")
def fail(reason):
    sys.stderr.write("live config invalid: %s\n" % reason)
    sys.exit(1)
try:
    config = json.load(open(path))
except Exception:
    fail("not JSON")
auth = config.get("authorization") or {}
if auth.get("scope") != scope or not auth.get("approvedBy") or not auth.get("approvedAt"):
    fail("authorization scope/approval missing")
allow = config.get("recipientAllowlist")
if not isinstance(allow, list) or not allow or len(allow) > 32:
    fail("recipient allowlist missing or too large")
allowed = set()
for entry in allow:
    if not isinstance(entry, str) or not address.match(entry):
        fail("allowlist entry is not an exact address")
    allowed.add(entry.lower())
cases = config.get("cases")
if not isinstance(cases, dict) or set(cases) - set(case_ids):
    fail("unknown case ids")
for cid, case in cases.items():
    if not isinstance(case, dict) or case.get("dedicatedTestCalendar") is not True:
        fail("case %s does not use a dedicated test calendar" % cid)
    for key in ("organizer", "attendee"):
        value = case.get(key)
        if value is not None and (not isinstance(value, str) or value.lower() not in allowed):
            fail("case %s %s is not allowlisted" % (cid, key))
    recipients = case.get("recipients", [])
    if not isinstance(recipients, list):
        fail("case %s recipients invalid" % cid)
    for value in recipients:
        if not isinstance(value, str) or value.lower() not in allowed:
            fail("case %s recipient is not allowlisted" % cid)
    for value in case.get("guests", []):
        if not isinstance(value, str) or value.lower() not in allowed:
            fail("case %s guest is not allowlisted" % cid)
PY
}

live_main() {
	[[ "${PLAINPOST_CALENDAR_LIVE_AUTHORIZED:-}" == "1" ]] || live_refuse "explicit authorization PLAINPOST_CALENDAR_LIVE_AUTHORIZED=1 is required"
	local config="${PLAINPOST_CALENDAR_TEST_CONFIG:-}"
	[[ -n "$config" ]] || live_refuse "PLAINPOST_CALENDAR_TEST_CONFIG is required"
	# Live owners store Node state only in a task-owned PostgreSQL 18 container;
	# a database URL inherited from the caller's environment is never used.
	[[ -z "${TEST_POSTGRES_URL:-}" ]] || live_refuse "an inherited TEST_POSTGRES_URL is not used by live runs; unset it (the runner starts its own PostgreSQL 18)"
	validate_live_config_file "$config"
	validate_live_config_contents "$config"
	command -v go >/dev/null || { echo "go is required" >&2; exit 1; }
	command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
	make_temp_root
	trap cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	local artifacts="$repo_root/.build/verification/calendar-e2e/$run_id-live"
	mkdir -p "$artifacts"
	chmod 0700 "$artifacts"
	echo "calendar e2e run: id=$run_id mode=live started=$(utc_now) source=$(git -C "$repo_root" rev-parse HEAD)"
	ensure_image "$postgres_image"
	start_postgres
	echo "calendar e2e image: postgres=$postgres_image"
	local pattern log="$temp_root/go-live.log" status=0
	pattern="^($(printf '%s\n' "${live_cases[@]}" | cut -d: -f2 | paste -sd'|' -))\$"
	(
		cd "$go_root"
		env -u TEST_POSTGRES_URL TEST_POSTGRES_URL="$(<"$temp_root/postgres-url")" PLAINPOST_REQUIRE_LIVE_POSTGRES=1 \
			PLAINPOST_CALENDAR_LIVE_AUTHORIZED=1 \
			PLAINPOST_CALENDAR_TEST_CONFIG="$config" PLAINPOST_CALENDAR_E2E_ARTIFACTS="$artifacts" \
			PLAINPOST_CALENDAR_E2E_PG_CONTAINER="$(<"$temp_root/postgres-container")" \
			go test ./internal/acceptance -run "$pattern" -count=1 -v -timeout 30m
	) >"$log" 2>&1 || status=$?
	local entry failed=0
	for entry in "${live_cases[@]}"; do
		if grep -Eq -- "^--- PASS: ${entry#*:} \\(" "$log"; then
			echo "calendar e2e case: id=${entry%%:*} outcome=PASS at=$(utc_now)"
		else
			echo "calendar e2e case: id=${entry%%:*} outcome=FAIL at=$(utc_now)" >&2
			failed=1
		fi
	done
	# Live logs may contain provider identifiers: the artifact keeps only opaque
	# outcome lines and must pass the privacy scan; only the path is reported.
	opaque_live_log "$log" >"$artifacts/go-live.log"
	chmod 0600 "$artifacts/go-live.log"
	scan_secrets "$config" "$temp_root/postgres-url" "$artifacts" || failed=1
	echo "calendar e2e artifacts: $artifacts"
	if ((status || failed)); then
		echo "calendar e2e live FAILED" >&2
		exit 1
	fi
	echo "calendar e2e live PASS"
}

main() {
	[[ $# -eq 1 ]] || usage
	case "$1" in
	--fixture) fixture_main ;;
	--live) live_main ;;
	*) usage ;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
