# Account protocol v1 fixtures

`crypto-vectors-v1.json` also reserves the Sync Node enrollment transcript domains. These vectors bind claim identity, account/epoch/approver, all three public keys, endpoint digest, action, exact replacement node and revocation, step-up authorization, idempotency key, admission evidence, configured Central audience, and one issuance digest repeated by result, lease, and refresh documents. Its framed `SessionDigestV1` derives only from the returned refresh credential bytes and offline-lease ID, so Apple can independently verify issuance without an opaque session token. Audience-substitution tests prove cross-Central replay rejection; Task 6 supplies the production audience. The shared high-S rejecting signature proves Go/Swift decoder parity. They contain no setup-code plaintext, endpoint plaintext, session plaintext, or private keys.

These language-neutral conformance inputs include production public artifacts
and synthetic test-only vectors. Swift and Go tests rebuild exact transcript
bytes rather than signing JSON. Each named vector is an independent scenario
unless it explicitly embeds or references another vector's digest.

## Required fixture rules

- Protocol messages validate against `account.schema.json`. Binary values are
  strict unpadded base64url and decoded byte counts are checked.
- Parsers reject unknown fields, malformed/off-curve P-256 keys, raw signature
  length/scalar/high-S errors, duplicates, invalid timestamp relationships,
  oversize inputs, and every semantically invalid conditional.
- Wire UInt64 values are positive decimal strings. Shared tests accept
  `18446744073709551615` and reject `18446744073709551616`, `01`, `0`, `+1`,
  and numeric JSON `1` before transcript construction.
- `central-bootstrap-manifest-v1.json`,
  `production-session-key-manifest-v1.json`,
  `production-root-public-key.txt`, `production-root-descriptor.json`, and
  `production-session-root-descriptor.json` are public production artifacts.
  The bootstrap and session manifests verify under separate published offline
  roots. The bootstrap manifest has
  bootstrap-challenge, trust-pagination, and recovery-authorization roles; the
  session manifest has distinct access and offline-lease keys. Private online
  rings are external deployment secrets and never enter this fixture set.
  `central-bootstrap-manifest-test-v1.json` is the legacy synthetic
  counterpart: only tests may inject it with the synthetic root/scalar inputs
  from `crypto-vectors-v1.json`. Tests reject unknown root, bad root signature,
  lower version, same-version/different-digest, future or expired manifests,
  and expired/revoked/wrong-purpose keys. They accept a strictly higher version
  even after skipped versions and treat predecessor mismatch as audit-only.
  Every validity interval is half-open.
- `apple-audience-platform-negative.json` has a valid device proof made with
  deterministic signing/agreement roles used nowhere else and no client
  platform field. Both public keys differ from every root, service, device,
  package, metadata, and SAS role in `crypto-vectors-v1.json`. The negative
  harness supplies an otherwise valid
  Apple identity with audience `com.attacker.unrecognized`; exchange returns
  `unknown_apple_audience`. Adding a client `platform` field fails the closed
  schema. The official macOS audience maps only to `macos`; official iOS and
  iPadOS use the combined `ios` class. Sync Node bootstrap is rejected.
- Exchange tests start from each semantic `AccountExchangeRequestV1`: exact fake
  compact Apple token, nonce, public bundle, and proof. They rebuild the token
  digest, proof transcript/signature, complete request transcript, and
  `exchangeRequestDigest`; prebuilt transcript bytes are expected outputs only.
  A challenge from another valid request fails client correlation and finalize
  storage checks with `exchange_request_digest_mismatch`.
- Complete genesis and pending finalize vectors rebuild their nested challenge
  digest and finalize transcript, verify `deviceSignature` with exactly the
  explicit expected challenge signing key, bind the exact genesis commit digest
  or empty pending value, and reject server/wrong-device keys, digest
  substitution, genesis-null, pending-with-commit, and cross-mode mutations.
- Trust cursors and pages are closed and signed by the manifest-authorized
  `trust_pagination` key, binding the request cursor digest, account, frozen
  head, ordered commit/evidence history entries, next cursor, terminal flag,
  and half-open lifetime. Admission entries carry the exact pending-device
  authorization and complete offer/response; recovery entries carry the exact
  authorization and historical root-signed bootstrap manifest. Genesis and
  removal entries carry null evidence. Historical recovery revalidates the
  supplied manifest under the pinned offline root and selects its purpose key
  at authorization issue time even after that manifest leaves current overlap.
  Their signatures authenticate delivery only. Test exact 1...32 pages,
  empty-terminal only after head, multi-page catch-up, gap, reorder, duplicate,
  head drift, premature terminal, equivocation, and expiry restart from the
  persisted verified high-water.
- Account request-proof vectors bind the exact method, RequestURI including
  query, body digest, access-token digest, whole-second timestamp, nonce,
  account, and device to the device signing key. Swift and Go execute every
  published substitution; the service additionally proves nonce replay rejects.
- Record-inventory proofs are closed, short-lived `trust_pagination` signatures
  over an exact frozen trust head/generation and the complete sorted set of
  record coordinates plus envelope/signature digests. Mutation coverage includes
  omission, substitution, stale head, expiry, wrong purpose, and authenticated
  zero-count retirement.
- Current state members are active only. Tests enforce account/epoch equality,
  unique sorted devices, genesis self-signing, matching prior-approver admission,
  one-time-authorized recovery self-signing, survivor-authorized removal, and
  changed or admitted revision equality. Admission/removal fixtures retain unchanged
  survivors byte-identically with inherited exact-predecessor authority even
  after the original signer is inactive, and reject mutation without
  current-transition authority. Transition prior-record sets, unlimited
  lifetime replacement through pages, and the active 5/5/1 cap remain enforced.
- Admission recomputes the canonical server-stored pending-device digest and
  requires the new record's account, device ID, audience-derived platform, and
  public bundle to match exactly. Recovery verifies and atomically consumes a
  short-lived one-time purpose-key-signed authorization binding the same fields,
  exchange digest, and new epoch. Wrong class, `sync_node`, and cross-
  authorization cases using other valid authorizations reject before
  commit/CAS; Sync Node remains enrollment-only.
- State-commit/group-package tests require exactly one sorted unique recipient
  per resulting member and transactionally reject partial, missing, duplicate,
  extra, wrong-generation, wrong-state-digest, and removed-recipient sets. They
  verify ECDH/HKDF/AES-GCM/signature/commitment and state/generation binding.
  High-water, CAS, idempotency, and page authority use `(accountID, epoch,
  revision, commitDigest)`; different equal-coordinate commit/package bytes are
  equivocation even if `stateDigest` is unchanged.
- Every non-genesis state signature binds `previousCommitDigest`, the exact
  immediately prior atomic commit. The explicit A/B/C vector has valid
  package-only forks A/B with one `stateDigest`; successor C names A and must
  reject from checkpoint/history B.
- Metadata tests compare exact AAD/envelope/signature bytes, reject nonce reuse,
  compression, oversize plaintext/ciphertext, stale generation/revision,
  signer-state mismatch, rollback, and same-coordinate equivocation.
- All sixteen cryptographic roles have distinct deterministic public keys,
  including the Apple-negative-only signing/agreement roles, and each
  fixture role publishes an exact 32-byte private scalar inside a conspicuous
  non-production `testOnlyInputs` block. That block also publishes the exact
  synthetic 64-byte account-key plaintext so independent Swift/Go harnesses can
  derive every public point, RFC 6979 signature, ECDH/HKDF/AES-GCM value,
  commitment, and metadata vector without hidden bytes or guessed ordering.
  Wrong-role cases are bounded objects `{operation, attemptedKeyRole,
  expected:"reject"}` naming only defined roles. The retry vector in
  `../trust-transcript.md` ends at `217025`.

## Fixture inventory

| File | Purpose |
| --- | --- |
| `central-bootstrap-manifest-v1.json` | Initial root-signed online bootstrap key manifest bundled with official clients. |
| `production-session-key-manifest-v1.json` | Root-signed public production access-token and offline-lease key manifest served by the central API. |
| `account-root-signed-production-session-key-manifest-test-v1.json` | Test-only copy of the prior account-root-signed production session manifest used to verify migration and resigning behavior. |
| `production-root-public-key.txt` | Unpadded base64url production offline-root public key for mounted server verification. |
| `production-root-descriptor.json` | Public production offline-root descriptor bundled with official clients. |
| `production-session-root-descriptor.json` | Public production session offline-root descriptor bundled with official clients. |
| `central-bootstrap-manifest-test-v1.json` | Synthetic legacy manifest used only through explicit test injection. |
| `crypto-vectors-v1.json` | Test-only scalar/key inputs; semantic exchanges; exact manifest, challenges, finalizes, pending/recovery authorizations, A/B/C atomic commits/packages, signed pagination, device-bound account request proofs, encrypted record, SAS, and structured wrong-role cases shared by Swift and Go. |
| `trust-v1.json` | Public peer-approval SAS transcript/digest vector used by the device-local trust runtime; it contains no private scalars. |
| `apple-audience-platform-negative.json` | Valid isolated-role key proof paired by the harness with an unrecognized Apple audience. |

Planned mutation fixtures include manifest rollback/equivocation and boundary
cases, bootstrap response substitution, cursor/page expiry and terminal cases,
atomic commit/package coverage, record-authority violations, metadata
nonce/rollback, and the existing matching-code attack set. An absent planned
negative is never an accepted case.
