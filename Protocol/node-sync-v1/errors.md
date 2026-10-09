# node-sync-v1 problems

Every protocol failure uses the closed `node-sync.problem.v1` shape and exactly
one category. Problems carry no provider error, storage location, credential,
session value, or internal operation detail.

| Category | Meaning |
| --- | --- |
| `invalid_request` | The request body, path-bound input, or canonical wire form is invalid. |
| `unauthorized` | The authenticated session principal cannot use the requested object. |
| `conflict` | A valid request conflicts with current durable state. |
| `stale_cursor` | The supplied opaque cursor cannot continue this compatible revision. |
| `unavailable` | A bounded dependency is unavailable; clients must not infer provider details. |

The HTTP adapter owns status-code mapping. It must not add problem categories or
return mutable diagnostic fields.

## Signed mutation operation

node-sync.operation.v1 is the semantic, source-neutral operation carried as
raw-base64url canonicalOperation by node-sync.mutation-request.v1.
MutationRequest.CanonicalOperation is the exact canonical byte sequence that
the HTTP adapter will pass to mutation.Service.Apply; neither codec normalizes
it. Before any future key lookup or cryptographic verification, decoders
re-encode both the signed envelope and its unsigned form byte for byte and
reject a mismatch.

The signed object has canonical lowercase UUID accountID, clientID, and nodeID;
nonzero canonical-decimal trustEpoch and authorityEpoch; a nonzero exact
32-byte logicalMailboxID in canonical raw-base64url; idempotencyKey, UTC
whole-second issuedAt, exactly one operation variant, and a raw-base64url
64-byte P-256 signature. The final signed envelope is at most 256 KiB, the
existing mutation-service ceiling. RFC5322 draft content is at most 180 KiB
(184320 decoded bytes), leaving bounded metadata and the outer raw-base64url
JSON body safely below the 1 MiB HTTP limit.

The signature transcript is exactly:

1. u32be(len(Plainpost.NodeSyncOperation.v1)) then Plainpost.NodeSyncOperation.v1
2. u32be(2) then u16be(1)
3. u32be(len(unsignedOperation)) then unsignedOperation

unsignedOperation is a separately validated value with no signature field;
the signed value attaches exactly 64 signature bytes after its canonical bytes
are frozen. The shared mutation vector pins all nine signed envelopes and
their unsigned transcripts for both Go and Swift.

Allowed variants are closed: save_draft (draftID, zero-allowed
expectedRevision, raw-base64url RFC5322 plus exact decoded byte count);
delete_draft and send (draftID plus nonzero expected revision); set_labels
(nonempty sorted byte-unique message IDs, sorted byte-unique disjoint
add/remove labels, and at least one change); set_read and set_flagged
(nonempty sorted byte-unique message IDs plus a boolean); move (nonempty
sorted byte-unique message IDs plus destinationMailboxPath); archive; and
delete (nonempty sorted byte-unique message IDs).

A move names its destination by the mailboxPath that mirror coordinates
publish for the same logical mailbox. The Node resolves it only against its
own active mailboxes of that logical mailbox at the writer epoch; an unknown
or inactive path is not found, and the signed path is never passed on to the
provider. A Node older than these variants answers them invalid_request
before any provider effect; clients show that as an outdated Sync Node.
Discovery may return its bounded safe providerIdentity, but no provider raw ID,
verifier result, token, or secret appears in this protocol.

## Canonical JSON

All top-level families are closed kind-versioned objects, including
path/query-bound semantic request families. UTF-8 object keys sort
lexicographically by UTF-8 bytes. Strings use minimal RFC 8259 escaping:
slash, <, >, &, and non-ASCII stay literal, except U+2028 and U+2029 which
are always lower-case \u2028 and \u2029. There is no Unicode normalization.
Collection sorting and uniqueness compare raw UTF-8 bytes, so canonically
equivalent strings remain distinct. Timestamps are UTC YYYY-MM-DDTHH:MM:SSZ,
years 0001 through 9999.

x-plainpost-maxUtf8Bytes is a local JSON Schema keyword. The repository's Ajv
fixture workflow validates it separately from standard maxLength, so multi-byte
input cannot widen any byte ceiling.

Every top-level canonical node-sync-v1 JSON family is at most 1,048,576
encoded bytes. Decoders reject oversized raw data before parsing, and encoders
reject oversized canonical output before it can reach the bounded Node
transport. This aggregate envelope bound does not narrow individual durable
mail-field vocabulary; signed operations retain their stricter 256 KiB bound.

Search query is a required, nonempty mail/search value of at most 4096 UTF-8
bytes and rejects every Unicode control (Cc) scalar. Message `inReplyTo` and
`references` entries are nonempty, NUL-free UTF-8 RFC message references of at
most 998 bytes, not generic 512-byte identifiers. Page limits remain `1...200`,
cursors remain at most 4096 bytes, and every mutation identifier array is at
most 200 items. A nonempty delta `after` is always a Node-issued authenticated
opaque cursor; an empty `after` bootstraps the current delta tail and returns a
new opaque tail cursor for the next poll. Decimal revisions are response facts,
never delta request baselines.
