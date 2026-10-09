# Provider conformance fixtures

These version-1, language-neutral fixtures cover Gmail, iCloud, and generic
secure IMAP/SMTP behavior. They deliberately separate two kinds of evidence:

- `cases[].script` is an ordered byte transcript for a local peer. It proves
  client wire behavior and remains the only source of raw peer bytes.
- `operations[]` is a strict, typed semantic stimulus plus a full expected
  result union. Its input configures the semantic peer and named public
  operation; its expected result is compared only after actual client/cache/
  server output is observed. It is joined to a case by ID, never decoded from
  a final client command.

`imap-transcripts.json` has 18 typed operations for mailbox discovery, `sync`,
wait, mutations (including `set_flags` add/remove/expected-mod-sequence and
Gmail-only `set_labels` deltas), lazy part fetch, TLS, OAuth, and Sent
behavior.
`smtp-transcripts.json` has 19 typed submit operations. Each has a canonical
envelope, RFC 5322 source and Message-ID, explicit peer capability set, phase
scenario, Sent behavior, cancellation phase, and an exact outcome or
provider-error expectation.

Every driver must reject unknown nested fields, require a one-to-one operation
and case ID set, enforce bounded/canonical values, validate the
provider/authentication/Sent binding, and compare the complete action result
for exact equality. An expected-only mutation and a peer-output mutation with
unchanged expected data must fail. A mutation of a raw transcript's final
client command must not alter the typed operation executed by the semantic
runner; separate raw-peer tests must reject that mutation.

IMAP input is a closed action-discriminated union rather than a shared
placeholder bag. Its full result union contains the frozen public outcome
states/codes and Sent-copy states; non-submit operations require
`not_applicable`. In particular, a Gmail Sent-copy `append` is the typed IMAP
no-op result (`applied`/`applied`/`not_applicable`), a reconciliation cursor
may validly have `scanUID < lastUID`, and the named oversized catalog/labels
case independently drives an oversized catalog response line and a real
Gmail labels literal.

The MIME corpus has 13 literal RFC 5322 sources plus seven generated cases
containing eight N/N+1 dimensions. Every generated case has one closed,
deterministic `generator`; both language drivers must send every generated
boundary through their real sync and lazy-hydration path, not a metadata-only
fixture projection. The shared sources cover RFC 2231 continuations and
decomposed Unicode normalized to NFC, as well as duplicate/malformed
Message-ID and address count/aggregate bounds. The named
`attachments-256-and-metadata-64kib-boundaries` case has one
`repeated_parts` generator with the closed `attachment_boundaries` payload.
That single payload carries attachment count 256/257 and canonical attachment
metadata 65,536/65,537 bytes (path, filename, MIME type, disposition, and
Content-ID UTF-8 bytes), so its two fixed sub-boundaries still exercise all
four N/N+1 values without a plural generator collection.
The 50 MiB per-part generator emits base64 wire input so Go and Swift prove the
decoded-byte boundary through their real paths; Go separately bounds wire
literals while decoded bytes remain the authoritative limit. Go's
message-wide attachment budget is likewise metered after transfer decoding,
and aggregate overflow closes/releases the underlying part transport without
requiring caller `Close`.

Execution boundaries are intentional:

- Go executes IMAP operations through `ProviderSession` and SMTP operations
  through `liveRuntime.submit`, including fixed Gmail/iCloud profiles and the
  reject → refresh → persist-before-retry Gmail OAuth path.
- Swift executes the public IMAP and password StartTLS surfaces against local
  semantic peers. Swift has no public Gmail OAuth-submit, iCloud Sent-policy,
  or context-cancellation API, so those shared typed fields are checked by
  explicit test-only contract boundaries. They are not represented as invented
  Swift production APIs.

Credentials, authorization headers, usernames, and live endpoint overrides
are prohibited. Test peers use synthetic runtime credentials and local
loopback addresses only. Microsoft, Outlook, Office365, and Graph are outside
this fixture scope.
