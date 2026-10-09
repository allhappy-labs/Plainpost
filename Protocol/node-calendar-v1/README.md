# Private calendar API v1

All routes are inside the signed Node session boundary. Account, client, Node,
trust epoch, sequence, method, path and body digest come from that session.
Clients must settle the retained signed request before sending a different one.
A 404/501 capability probe means the Node requires an update; authentication and
transport failures remain distinct.

| Route | Method | Request family | Result family |
| --- | --- | --- | --- |
| `/v1/calendar/capabilities` | GET | empty body | `capabilities` |
| `/v1/calendar/connections/read` | POST | `connections-request` | `connections-result` |
| `/v1/calendar/connections/configure` | POST | `connection-command` | `connection-result` |
| `/v1/calendar/connections/disconnect` | POST | `disconnect-command` | `connection-result` |
| `/v1/calendar/window` | POST | `window-request` | `window-result` |
| `/v1/calendar/event` | POST | `event-request` | `event-result` |
| `/v1/calendar/invitations` | POST | `invitation-read-request` | `invitation-read-result` |
| `/v1/calendar/commands` | POST | `command-request` | `command-result` |
| `/v1/calendar/operations/read` | POST | `operation-read-request` | `operation-read-result` |

Every family includes `kind: "node-calendar.<family>.v1"`. Calendar route errors
use `node-calendar.problem.v1`; rejection at the outer authentication/admission
boundary retains that boundary's existing error format. Native status mapping
happens before any result decoding.

The schema is authoritative. Generation/sequence counters are JSON integers
bounded by 9007199254740991. Step states are `not_needed`, `pending`, `in_flight`,
`confirmed`, `failed`, and `uncertain`. `CalendarTime` uses `date` or `date_time`;
legacy offset-free wall values and RFC3339 offset values preserve their TZID.
These Task 1 definitions supersede inconsistent earlier plan prose.

Native events expose opaque event, connection and calendar IDs plus original
recurrence identity and display/permission fields. They never expose EventKey,
provider resource coordinates or account IDs. Connections include redacted
calendar catalog metadata. Provider links remain explicit display fields.
The original domain event form and singular receipt/invitation families remain
compatibility vectors; current native routes use redacted events and batch reads.

Native invitations (`invitation-read-result`) add display fields derived only
from the invitation's own payload: `title`, `location`, nullable `start`/`end`
CalendarTimes and a nullable https `meetingURL` (clients apply their own link
policy). `eventID` remains the invitation identity that response commands name;
it is not a stored event ID. Nullable `calendarEventID` is the single projected
event on the account's enabled connections for the invitation attendee that
matches UID, organizer and original recurrence identity; absent or ambiguous
matches are null and never guessed. Clients read events, navigate and refresh
only through `calendarEventID`.

`operation-read-result` carries `unknownOperationIDs`: requested operations the
account never admitted. It is the only definitive "not received" signal; a 409
(authority, trust, mailbox mapping or account mismatch) never means unknown.

Configuration is a `command` envelope containing `operationID`, optional
`connectionID`, `expectedGeneration`, provider `kind`, the closed `configuration`
union (`google` or `caldav`), nullable `sendingMailboxID`, and nullable
`attendeeAddress`. Creation omits `connectionID` and uses generation zero; the
Node generates a UUID. Updates require an existing current UUID/generation.
Disconnected UUIDs are terminal. Reconnection creates a new UUID.

`capabilities` carries `google: {configured, clientID}`. `configured` is true
only when the Node has both a Google "Desktop app" OAuth client ID and a
readable client-secret file; `clientID` is then that non-secret ID and is
`null` otherwise. The client secret never appears on the wire. Google
configuration carries the authorization code, PKCE verifier, the advertised
client ID and the exact RFC 8252 loopback redirect
`http://127.0.0.1:<port>/oauth/calendar/google` (port 1024–65535, no userinfo,
query or fragment). The Node rejects any other redirect or client ID and
exchanges and refreshes only as its configured client.

Setup has a separate encrypted pending journal and durable account-scoped body
digest, generation, trust-epoch and operation-ID record. Exchange is claimed
in-flight before provider I/O. A committed encrypted credential resumes promotion
without exchanging the Google code again. An unresolvable in-flight exchange is
uncertain. Authorization-code digests also prevent reuse across operation IDs.
Credentials and temporary setup material are erased on disconnect. Setup body/code
digests and the original redacted terminal result remain for delayed exact retries;
a consumed Google code cannot be submitted under another operation ID. Disconnect
receipts likewise retain only metadata. Both histories cascade on final account
erasure. Credential writes and cleanup are fenced by connection generation.

The CalDAV adapter currently supports only same-origin redirects. An explicit
approved-origin list may contain the configured origin; other origins fail
admission rather than weakening the adapter's outbound/credential boundary.

Command bodies are limited to 256 KiB, connection bodies to 64 KiB, and each
window response to 8 MiB. The signed TLS sender and retained replay use that same
ceiling only for the authenticated `POST /v1/calendar/window` request class; other
buffered routes retain their 1 MiB ceiling. Window `cursor` and `nextCursor` are required strings;
empty starts/ends pagination. Cursors are bound to the account, trust epoch,
window and snapshot. Changed snapshots return conflict, and oversized individual
results return unavailable. Neither case becomes an empty successful window.
The native client collects pages with duplicate-event, cycle and total-page
bounds. Batch ID reads accept at most 200 distinct opaque IDs.

Edit/RSVP and invitation handlers remain explicitly unavailable until their
later durable coordinators are supplied. Capability and HTTP/native route
forwarding are already installed; no placeholder acknowledges provider writes.

## Closed codec rules

The Go Node and the native transport both embed an exact copy of
`node-calendar.schema.json` (tests fail on drift) and validate every family they
decode or emit against it before typed decoding. A value that fails is rejected
as a whole; the Node answers `unavailable` rather than emit a non-conformant
success. Both codecs apply the same interpretation:

- Input is at most 8 MiB of UTF-8 without a byte order mark, one RFC 8259 value
  with nothing after it, nested at most 64 levels. Duplicate object keys are
  rejected after unescaping. Keys, enums and uniqueness compare exact UTF-8
  bytes, never Unicode canonical equivalence.
- String escapes must be valid; surrogate escapes must form a pair. NUL is
  rejected in every string (identifiers also carry the schema's no-NUL pattern).
- `minLength`/`maxLength` count Unicode scalar values (JSON Schema code points),
  not bytes. `maxItems`, `uniqueItems`, `required`, `additionalProperties`,
  `propertyNames`, `const`, `enum`, `oneOf`, `anyOf` and `not` follow JSON
  Schema 2020-12. Only the two schema patterns are recognized; any other pattern
  fails closed.
- Counters must be canonical integer lexemes (`0` or no leading zero; no sign,
  fraction or exponent) within 0..9007199254740991. `1.0`, `1e0`, `01`, `-0`,
  quoted numbers and booleans are rejected.
- `format: date-time` is asserted with a strict RFC 3339 profile:
  `YYYY-MM-DDTHH:MM:SS` then `Z` or a nonzero `+HH:MM`/`-HH:MM` offset, uppercase
  separators, a real calendar day, no fractional or leap seconds. Write UTC as
  `Z`, never `+00:00`.
- An edit's `start` and `end` are each an `editTime`: a full `calendarTime`, or
  the `unchangedTime` sentinel `{"kind":"date_time","value":"","timezone":""}`.
  A pair of sentinels keeps the provider's timing, so a title-only edit and a
  series safe-field edit never rewrite DTSTART/DTEND or trip the series timing
  guard. The Node rejects a sentinel paired with a real time.
- Timezone names match `^[A-Za-z0-9_+/-]+$` (IANA names such as `Etc/GMT+5`
  contain digits). A `calendarTime` zone must additionally resolve in the
  platform zone database and is never `Local` or a `GMT+`/`GMT-`/`UTC+`/`UTC-` offset alias.
  A connection catalog calendar may carry an empty timezone when the provider
  offers no IANA name; the Node reduces a CalDAV `calendar-timezone` VTIMEZONE to
  its single TZID.
- Canonical bytes are sorted keys, no insignificant whitespace, raw non-ASCII,
  unescaped `/`, and the shared short escapes (`\b \f \n \r \t \" \\`), lowercase
  `\u00XX` for other controls and `\u2028`/`\u2029`.

### Field bounds

Identifiers (`$defs.identifier`) are 1..512 code points; opaque cursors
0..4096; revisions, codes, addresses, disabled reasons, thread/message IDs and
collection names 512; recurrence IDs 128 (512 on native events); stamps 128;
methods 32; collection colors 64; calendar time values 64; timezones 255;
endpoints, redirect URIs and provider links 2048; authorization codes 4096;
passwords 16384; event titles and locations 65536; notes 1048576. Arrays: 200
batch IDs, receipts, invitations, connections and catalog calendars; 16
approved redirect origins; 10000 window events. Window failure keys are
identifiers and values at most 512.

Native invitation display fields are bounded for the invitations route's 1 MiB
response ceiling: `title` and `location` at most 512 code points and
`meetingURL` at most 1024. The Node truncates payload SUMMARY/LOCATION at a
code point boundary and omits longer meeting links. With Node-issued identifier
sizes (64-character invitation/event IDs, message IDs up to 128, UIDs up to 256,
RFC 5321 addresses) a full 200-invitation read with two-byte text at those
bounds encodes to about 0.9 MiB (`TestCalendarInvitationReadAtDisplayBoundsFitsResponseCeiling`).
A read whose identifiers or four-byte display text approach their schema
maxima can exceed the ceiling; the Node then returns `unavailable`, never a
truncated or malformed success.

### Catalog bounds and setup codes

`connections-result` lists only enabled connections: established connections,
setups still pending or in flight, failed reconfigurations of an existing
connection, and the newest failed or abandoned connection-creation attempt.
Disconnected, erased and superseded attempts are terminal history and are
omitted. A creation attempt (a setup with expected generation zero) that settles
`uncertain` or `failed` supersedes every older failed creation attempt: those
rows are generation-fenced and disabled, and their setup material and catalog
are erased. Their non-secret setup record and redacted terminal result remain,
so exact retries still read the original outcome and consumed authorization
codes stay fenced. The Node admits a new connection only while fewer than 200
connections are listed (otherwise `conflict`). The read therefore stays within
the 200-connection bound. If that invariant is ever violated, the read fails
closed with `unavailable` and never drops an active connection.

Storage never admits more than 200 calendars for one connection (setup
completion and catalog writes return `calendar_limit`). When discovery finds
more, the setup settles `failed` with `connection-result.code` =
`calendar_limit`. No credential or calendar is promoted and the prepared
credential is erased. Both calendar checks run before the prepared setup journal is
encrypted, so the outcome never depends on the secret store's 64 KiB plaintext
ceiling. A within-bound catalog whose prepared journal still exceeds that ceiling
(very long names or CalDAV hrefs) settles `failed` with `calendar_metadata_limit`
under the same rules. A realistic 200-calendar Google catalog journals in about
55 KB. Both failures record the redacted terminal result, so an exact retry
returns the same code without a second exchange. `code` is a closed enum: `""`,
`calendar_limit` or `calendar_metadata_limit`.

### Shared vectors

`fixtures/protocol-v1.json` holds the canonical `families`, the legacy
`failures`, the private route table (`routes`: method, path, request/result
family, request body ceiling) and `cases`: accept/reject vectors derived from the
schema by `Scripts/generate-calendar-contract-vectors.py` (run with `--check` to
verify they are current). Cases cover every field bound (ASCII, two-byte and
four-byte text at and over the bound), empty identifiers, NUL, type confusion,
every closed enum value and near misses, counters and non-canonical number
lexemes, booleans, nullability, required and unknown/duplicate nested fields,
family kinds and versions, date-time and timezone rules, array bounds and
uniqueness, the edit/response and provider-configuration unions, pagination
cursors and final pages, JSON syntax and encoding, canonical escaping and
documents over 8 MiB. A case's `expand` list performs ordered byte substitutions
(`unit` text with `{i}` as a five-digit index, or raw `unitHex`) so large inputs
stay small in the fixture. `Scripts/test-calendar-contract.sh` compares the Go
and native digest reports for every case and requires them to be identical.
