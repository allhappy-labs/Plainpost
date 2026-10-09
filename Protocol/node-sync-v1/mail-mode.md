# node-sync-v1 mail mode

Mail mode lets one Plainpost account hold several provider accounts on a Sync
Node. It is additive. `node-sync.schema.json`, `protocol-v1.json` and every
existing family stay unchanged, so deployed decoders keep working:

- The legacy routes project the primary account. These are `/v1/snapshot`,
  `/v1/deltas`, `/v1/search` with an empty mailbox filter,
  `GET /v1/mailboxes/assignments` and `/v1/status`.
- `/v1/status` keeps its frozen shape. Per-account status is available only
  through `GET /v1/mail/accounts`.

The closed wire shapes are in `node-sync-mail-mode.schema.json`.
`fixtures/mail-mode-v1.json` pins them for both codecs. Regenerate the fixture
with `Scripts/generate-mail-mode-contract-vectors.py`, and use `--check` to fail
on drift. The Go Node embeds an exact copy of the schema as
`internal/node/clientapi/mail_mode_schema.json`, and a test fails if the copy
drifts. The Node validates every mail-mode family it decodes or emits against
that copy.

## Routes

All routes sit inside the authenticated private Node handler. The Plainpost
account always comes from the verified session principal, never from JSON.

| Route | Method and request family | Result family |
|---|---|---|
| `/v1/mail/capabilities` | GET, empty body | `node-sync.mail-capabilities.v1` |
| `/v1/mail/accounts` | GET, empty body | `node-sync.mail-accounts-result.v1` |
| `/v1/mail/snapshot` | POST `node-sync.account-snapshot-request.v1` | existing `node-sync.snapshot-page.v1`: messages of that account only, and the cursor is bound to the account |
| `/v1/mail/deltas` | POST existing `node-sync.delta-request.v1` | `node-sync.mail-delta-page.v1`: changes of every ready account, each carrying `logicalMailboxID`, plus the accounts still waiting for their first import |
| `/v1/mail/providers/google/import` | POST `node-sync.google-token-import-request.v1` | `node-sync.provider-import-result.v1` |
| `/v1/mail/providers/imap/import` | POST `node-sync.imap-provider-import-request.v1` | `node-sync.provider-import-result.v1` |
| `/v1/mail/providers/remove` | POST `node-sync.provider-remove-request.v1` | `node-sync.provider-remove-result.v1` |
| `/v1/mail/mirror/coordinates` | POST `node-sync.mirror-coordinates-request.v1` | `node-sync.mirror-coordinates-result.v1` |
| `/v1/mail/messages/<logicalMailboxID>/<messageID>` | GET, empty body | existing `node-sync.message-result.v1`, only for a message of that logical mailbox (see "Scoped reads") |
| `/v1/mail/attachments/<logicalMailboxID>/<attachmentID>` | GET, empty body, no `Range` | the legacy attachment byte stream, only for an attachment of that logical mailbox (see "Scoped reads") |

Compatibility:

- A Node without mail mode answers `GET /v1/mail/capabilities` with 404.
  Clients map that to "update required".
- Transport, authentication and undecodable responses mean only "unavailable".
- Reads retry like the legacy read routes.
- The two import routes and the remove route are dispatched exactly once, so a
  secret-bearing body is never replayed automatically under new request
  signing.

### Scoped reads

`GET /v1/messages/<messageID>` and `GET /v1/attachments/<attachmentID>` are
unchanged. They still serve a message or attachment of any provider account
of the Plainpost account, for older clients. A client bound to one provider
account cannot check that itself, because `node-sync.message-result.v1` does
not carry a logical mailbox. It uses the two scoped routes instead:

- `<logicalMailboxID>` is the canonical raw base64url of the 32 nonzero bytes,
  like every mail-mode logical mailbox ID. `<messageID>` is encoded exactly as
  in the legacy message route, and `<attachmentID>` is the opaque attachment
  ID from a message result. A non-canonical segment is `400 invalid_request`.
  Any path under `/v1/mail/messages/` or `/v1/mail/attachments/` that is not
  exactly those two non-empty segments is `404 invalid_request`. There is no
  query parameter.
- A message belongs to the logical mailbox that owns its attachments. The
  scoped message route answers only for that logical mailbox, with the same
  bytes as the legacy route. It issues attachment IDs only after that check.
  An attachment ID is bound to the logical mailbox it was issued for. The
  scoped attachment route opens it only through that logical mailbox, and it
  checks this before it fetches or reads any attachment bytes.
- A message or attachment of another logical mailbox answers `404 conflict`.
  So does an unknown message or attachment ID, and a logical mailbox the
  principal's account does not have. A foreign object and an unknown one get
  the same status and body, so a client cannot tell them apart from the
  response alone; timing can still differ between them, exactly like a
  missing message or attachment on the legacy routes. A foreign message whose
  owner account is still completing its baseline import can answer
  `503 unavailable` instead, because the Node checks that owner account's
  availability before it checks whether the message belongs to the requested
  scope.
- The scope defends against a client mistake, such as a stale or
  mismatched logical mailbox in a local cache. It is not a boundary the
  authenticated principal is confined to: the same principal can always read
  any of its provider accounts through the account-wide legacy routes
  (`GET /v1/messages/<messageID>`, `GET /v1/attachments/<attachmentID>`).
- Method, body, `Range`, admission and problem rules are those of the legacy
  routes, and reads retry like the legacy read routes. A Node without the
  scoped routes answers `404 invalid_request`, the same as any other unknown
  route under `/v1/mail/`; a scoped not-found on a Node that does serve them
  is `404 conflict` instead, as above. A Node that has the scoped routes but
  cannot serve them answers `503 unavailable`, and it never falls back to an
  account-wide read.
- The routes log nothing on success and never log an ID.

## Canonical form

Mail mode uses the node-sync-v1 canonical JSON rules in `errors.md`:

- Keys sort by UTF-8 bytes and strings use minimal escaping.
- Every family has a `kind` discriminator.
- Unknown, duplicate and missing members are rejected, and so are
  non-canonical bytes. Decoders re-encode and compare bytes, so accepted input
  is always canonical.
- Each family is at most 1,048,576 bytes.
- 32-byte IDs are canonical raw base64url of nonzero bytes.
- Every string rejects NUL.

## Field rules

| Field | Rule |
|---|---|
| `version` (capabilities) | Exactly `"1"`. Decoders reject every other value, so the native value has no version member. |
| `providerIdentity`, `expectedProviderIdentity` | Lower-case ASCII dot-atom addr-spec of 3...320 bytes. It has exactly one `@`, a non-empty local part of lower-case letters, digits, dots and RFC 5322 atext symbols, and a non-empty domain of lower-case letters, digits, dots and hyphens. The schema pattern is authoritative. |
| `providerKind` | `gmail` or `generic`. |
| `state` (account) | `ready`, `degraded` or `authentication_required`. |
| `refreshToken`, `password` | 1...16384 UTF-8 bytes without CR, LF or NUL. |
| `username` | 1...512 UTF-8 bytes without CR, LF or NUL. |
| `host` | Lower-case DNS name or IPv4 address of 1...253 bytes. It starts and ends alphanumeric, and inner characters come from `a-z 0-9 . -`. |
| `port` | Canonical decimal string `1`...`65535`. |
| `security` | `implicit_tls` or `starttls`. |
| `roles` | `drafts`, `inbox`, `sent` and `trash` are required. `archive` is optional: it is omitted when absent, never null. Each path is 1...512 UTF-8 bytes, and the paths are pairwise distinct by exact bytes. |
| `limit` (account snapshot) | JSON integer `1`...`200`, the same as the legacy snapshot and delta requests. |
| `after` | Opaque cursor of at most 4096 bytes. |
| `messageIDs` | 1...200 identifiers (1...512 bytes), strictly sorted by UTF-8 bytes. |
| `records` | At most 200, strictly sorted by `messageID` bytes. `rfcMessageID` is always present, and it is null or 1...998 bytes. |
| `memberships` | At most 200 per record. They are strictly sorted by raw logical mailbox bytes, then `mailboxPath` bytes, so one logical mailbox and path appears at most once. |
| `mailboxPath` | 1...512 UTF-8 bytes. |
| `uid`, `uidValidity` | Canonical decimal strings `1`...`4294967295`. |
| `flags` | Strictly sorted, unique subset of `answered`, `deleted`, `draft`, `flagged` and `seen`. |
| `accounts` | At most 200. Logical mailboxes and provider identities are unique, and at most one account is `primary`. The Node chooses the order. The Node omits an account this family cannot represent (for example a stored non-ASCII identity or a generic profile without a composing identity). |
| `primaryState` (accounts) | `available`: exactly one listed account is `primary`. `unavailable`: the primary account exists but is omitted, so no listed account is `primary`; the secondaries are still listed. `none`: the Plainpost account has no provider accounts and `accounts` is empty. |
| `waitingAccounts` (mail delta page) | At most 200 logical mailbox IDs, strictly sorted by raw bytes. Each account's first import (baseline) is incomplete: it is outside the page scope and no change names it. A logical mailbox without an enabled provider configuration is never listed. When a waiting account completes, the scope changes and the cursor becomes `stale_cursor` for every account, so changes of ready accounts made since the cursor are no longer delivered through it. Recovery is lossless only in this order: (1) bootstrap a fresh delta cursor with an empty `after`; (2) snapshot, through `/v1/mail/snapshot`, every account that `/v1/mail/accounts` lists and that the fresh page does not report as waiting (every ready account, not only the one that completed); (3) continue deltas from the fresh cursor. Changes committed between steps 1 and 2 are delivered again as idempotent upserts. |
| `changes` (mail delta page) | The legacy `change` shapes, at most 200. |
| `assignments` | At most 200 discovered mailboxes with the legacy shape. A non-null `logicalMailboxID` names the owning account or import result. |
| `state` (import) | `created`, `unchanged` or `replaced`. |
| `state` (removal) | `removed` or `absent`. |

## Problems

Mail mode reuses `node-sync.problem.v1`. Problems never carry provider bodies.

- An identity mismatch is `unauthorized`.
- A logical mailbox bound to a different identity is `conflict`. So is an
  identity bound to a different logical mailbox.
- A missing Desktop client configuration is `unavailable`.
- A `/v1/mail/snapshot` for a logical mailbox that the principal's account
  does not have is `unauthorized`.

## Security

Credential requests carry a refresh token or password only from a trusted
device to its own Node. Both codecs redact these request values from every
description, formatter, reflection and structured log.

### Mirror coordinates

`POST /v1/mail/mirror/coordinates` is the only mail-mode route that returns
provider identifiers (spec Amendment 3). The snapshot, delta and search
families, legacy or mail mode, still never carry them.

- **Who may call it.** Only a session principal with current trust: a device
  of the same Plainpost account whose request passed session authentication
  under the account's current trust epoch. The account comes from that
  principal, never from JSON. An unknown message ID and a message ID of
  another account are omitted in the same way, so the response never reveals
  whether a foreign ID exists. A message with no addressable membership is
  also omitted.
- **What it exposes.** For each known message: `messageID`, the RFC
  Message-ID (or null) and, for each membership, `logicalMailboxID`,
  `mailboxPath` (the provider mailbox name from IMAP LIST), `uidValidity`,
  `uid` and `flags`. A membership is listed only for an active provider
  mailbox epoch with an observed UIDVALIDITY and a raw ID that is a canonical
  decimal UID. After a UIDVALIDITY change, the retired epoch is omitted until
  the new epoch's baseline records its UIDs. A provider-confirmed tombstone
  has no coordinates. Omission therefore means "no addressable coordinates
  right now", not "deleted": a client removes a mirrored row only on a
  `membership_removed` delta that leaves no memberships or on `tombstoned`. The route never returns credentials, session material,
  bodies, attachments, labels or provider endpoints.
- **Why.** The Mac already holds the credential for these provider accounts,
  and direct IMAP sync already knows these coordinates. A native local store
  can then key mirrored rows by account, mailbox, UIDVALIDITY and UID, the
  same way it keys direct sync rows. The route gives a trusted device of the
  same account nothing that the device's own credential owner cannot read
  from the provider.
- **Bounds.** A request names 1...200 unique message IDs sorted by UTF-8
  bytes. Each result has at most 200 records and at most 200 memberships per
  record. The canonical family is at most 1,048,576 bytes. A result over that
  cap is `conflict`, and the client retries with half the batch. So is a
  message with two memberships at the same logical mailbox and path, which
  the closed family cannot represent. One database read covers at most 40,000
  membership rows.
- **Logging.** The Node logs only failed reads, and only in fixed vocabulary
  (`route=mirror_coordinates`, `outcome=failed` and the problem category).
  Message IDs, RFC Message-IDs, mailbox paths, UIDs and flags never reach a
  log.
