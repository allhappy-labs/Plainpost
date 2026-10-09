# node-calendar-v1 problems

Every protocol failure uses the closed `node-calendar.problem.v1` shape with one
category: `invalid_request`, `unauthorized`, `conflict`, `not_found`, or
`unavailable`. Problem responses carry no provider error, credential, endpoint,
or internal storage detail.

A `conflict` may carry one bounded refinement `code`:
- `target_calendar_required`: a response would create a new attendee copy and
  more than one writable calendar could hold it; resend with `targetCalendarID`.
- `snapshot_changed`: a window's events changed between pages; restart from the
  first page.
- `calendar_index_pending`: a readable calendar of the connection has not
  finished its first complete synchronization, so whether the invitation's
  event already exists is unknown. Nothing was admitted; respond again after the
  calendar syncs. Invitation reads report such an invitation as `unresolved`
  with revision `calendar_index_pending` until then.

Calendar connection IDs are opaque strings on this wire. The Sync Node creates
them as UUIDs and validates that invariant at connection admission; clients
must not infer identity or authority from their spelling.

Window cursors are Node-issued opaque strings. An omitted `cursor` begins a
window read. A present `nextCursor` continues a bounded result page, including
when a valid result exceeds the response-size bound.

The shared fixture corpus keeps one legacy rejection vector each for unknown
and duplicate fields, an unsafe numeric counter, a wrong family variant, and an
oversized identifier, plus the schema-derived `cases` described in README.md. Decoders reject duplicate keys before ordinary JSON
object decoding, because JSON's last-key-wins behavior would otherwise hide a
conflicting request.
