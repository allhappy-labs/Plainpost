# Account cryptographic transcripts v1

This document defines the byte-level account-v1 contract used by Swift and Go.
It applies after mandatory Sign in with Apple and does not revive the retired QR
invitation protocol. JSON parsing is only the first validation step: consumers
decode canonical base64url and UInt64 strings, enforce the semantic rules below,
rebuild the exact transcript, and verify the selected signer before accepting
authority.

## Canonical primitives

- `LP(value)` is `U32BE(value.count) || value`. Every field below, including a
  fixed-width integer or nested transcript, is length-prefixed.
- `U16BE`, `U32BE`, and `U64BE` are fixed-width unsigned big-endian integers.
- Every wire UInt64 is a JSON string matching `^[1-9][0-9]{0,19}$`. A semantic
  parser accumulates decimal digits with checked arithmetic and rejects zero,
  leading zeroes, signs, whitespace, fractions, and values above
  `18446744073709551615`. Only the parsed value enters transcripts as `U64BE`.
- A UUID is its 16 RFC 4122 network-order bytes. JSON UUID text is lowercase
  canonical form.
- Protocol strings are exact UTF-8 bytes. Enum values are not normalized.
- Binary JSON values are canonical unpadded base64url: decode strictly, reject
  whitespace or `=`, re-encode, and require byte-for-byte equality.
- A P-256 public key is exactly 65 bytes in SEC1/X9.63 uncompressed form,
  `0x04 || X || Y`. Reject any other prefix/length, coordinates outside the
  field, the point at infinity, and points not on P-256.
- `SHA256(value)` means the 32 raw digest bytes. `HMAC-SHA256` and
  `HKDF-SHA256` use RFC 2104 and RFC 5869 respectively.

### Canonical P-256 signatures

Every account-v1 signature is ECDSA-P256-SHA256 over the complete transcript
bytes. Its wire form is exactly 64 bytes, `I2OSP(r, 32) || I2OSP(s, 32)`; DER is
never accepted. For P-256 group order

```text
n = FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
```

both `r` and `s` are in `[1, n - 1]`. Signers normalize `s` to
`min(s, n - s)`. Verifiers reject signatures whose `s` is greater than

```text
floor(n / 2) = 7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8
```

## Central bootstrap key trust

Official clients ship an offline P-256 root public key and its `rootKeyID`.
Changing that root requires a signed official-app update. The root is never an
online service key. Online bootstrap-challenge, recovery-authorization, and
trust-pagination keys rotate through bounded, directly root-signed
`CentralBootstrapKeyManifestV1` values.

Manifest entries are strictly sorted by UTF-8 `keyID`, have unique IDs, and
number at most eight. Their validity interval is contained by the manifest
interval. The root-signature transcript is:

```text
LP(UTF8("Plainpost.CentralBootstrapKeyManifest.v1"))
LP(U16BE(1))
LP(UTF8(rootKeyID))
LP(U64BE(manifestVersion))
LP(UTF8(notBefore))
LP(UTF8(expiresAt))
LP(previousManifestDigest or empty)
LP(U16BE(keys.count))
for key in keys:
    LP(UTF8(key.keyID))
    LP(UTF8(key.purpose))
    LP(key.publicKey)
    LP(UTF8(key.notBefore))
    LP(UTF8(key.expiresAt))
    LP(UTF8(key.status))
```

`canonicalSignedBootstrapKeyManifestBytes` appends `LP(rootSignature)`, and
`manifestDigest = SHA256(canonicalSignedBootstrapKeyManifestBytes)`. A client
accepts a manifest only under its shipped root, within its half-open validity
interval `notBefore <= verificationTime < expiresAt`, and after validating
every entry. It persists the highest accepted `(manifestVersion,
manifestDigest)`. A lower version is rollback; the same version with another
digest is equivocation. Any strictly higher root-signed version is accepted
even when intermediate versions were never observed. `previousManifestDigest`
is optional audit metadata only: clients may report a mismatch but never make
it an acceptance dependency. An unknown root ID requires an app update. A
selected key must have the required purpose, status `active`, and a half-open
validity interval containing both current verification time and the signed
object's `issuedAt` or `createdAt`. Expired, future, or revoked keys fail closed.

Before authentication, clients may fetch `GET
/.well-known/plainpost/account-bootstrap-keys`. The closed response contains
one `current` manifest and at most four `overlap` manifests unique by
`(manifestVersion, manifestDigest)`. Each
manifest is independently verified under the shipped offline root; the HTTPS
response and server do not add trust. The service caps the response at 64 KiB,
rate-limits each source to 30 requests per minute with burst 5, and emits an
ETag plus a cache lifetime no later than the current manifest expiry. Clients
may use a cached still-valid manifest during network failure, but never extend
its expiry. The bundled initial manifest is
`fixtures/central-bootstrap-manifest-v1.json`.

## Apple exchange and bootstrap

### Device proof and request correlation

`AccountExchangeRequestV1` contains no platform assertion. Its device proof is
verified with `deviceBundle.signingKey` over:

```text
LP(UTF8("Plainpost.AccountExchangeProof.v1"))
LP(U16BE(1))
LP(SHA256(ASCII(appleIdentityToken)))
LP(nonce)
LP(deviceBundle.signingKey)
LP(deviceBundle.agreementKey)
```

The complete signed request transcript includes that proof:

```text
LP(UTF8("Plainpost.AccountExchangeRequest.v1"))
LP(U16BE(1))
LP(SHA256(ASCII(appleIdentityToken)))
LP(nonce)
LP(deviceBundle.signingKey)
LP(deviceBundle.agreementKey)
LP(deviceProof)
```

```text
exchangeRequestDigest = SHA256(canonicalSignedExchangeRequestBytes)
```

The client retains this digest for its in-flight request and rejects a response
whose digest differs. The server stores the digest with the challenge and
requires the same digest at finalize. Token, nonce, key, or proof substitution
therefore changes the request identity even if another request is valid.

The shared vectors carry each complete semantic `AccountExchangeRequestV1`,
including an exact synthetic compact token, nonce, public bundle, and proof.
Conformance implementations start from those semantic fields and independently
rebuild the ASCII token digest, proof transcript/signature, complete signed
request bytes, and `exchangeRequestDigest`; stored transcript hex is an expected
result, never an input to verification.

The Apple verifier returns the validated audience/client ID. The central
service maps an immutable configuration allowlist: the macOS official bundle
client ID maps to `macos`, and the iOS/iPadOS official bundle client ID maps to
the combined `ios` entitlement class. Unknown audiences fail. An iPad-facing
label may exist only inside encrypted metadata and never affects caps. A Sync
Node never uses Apple bootstrap; trusted-device node enrollment assigns its
`sync_node` class server-side.

For pending admission, the server persists the exact bounded
`PendingDeviceV1` with account ID, assigned device ID, audience-derived
platform, exchange public bundle and digest, and lifetime. Its canonical
authorization bytes are:

```text
LP(UTF8("Plainpost.PendingDeviceAuthorization.v1"))
LP(U16BE(1))
LP(accountIDBytes)
LP(deviceIDBytes)
LP(UTF8(platform))
LP(publicBundle.signingKey)
LP(publicBundle.agreementKey)
LP(exchangeRequestDigest)
LP(UTF8(createdAt))
LP(UTF8(expiresAt))
```

`pendingDeviceDigest = SHA256(pendingDeviceAuthorizationBytes)`. Admission
binds this digest, and the new trust record's account, device ID, platform, and
both public keys must exactly equal the live stored pending authorization.
Because Apple exchange can derive only `macos` or `ios`, it can never produce a
`sync_node` pending authorization.

### Signed bootstrap challenge

The selected online key signs:

```text
LP(UTF8("Plainpost.AccountBootstrapChallenge.v1"))
LP(U16BE(1))
LP(challengeIDBytes)
LP(challengeNonce)
LP(exchangeRequestDigest)
LP(accountIDBytes)
LP(deviceIDBytes)
LP(UTF8(mode))
LP(UTF8(platform))
LP(publicBundle.signingKey)
LP(publicBundle.agreementKey)
LP(UTF8(createdAt))
LP(UTF8(expiresAt))
LP(UTF8(serverKeyID))
```

`canonicalSignedBootstrapChallengeBytes` appends `LP(serverSignature)`, and
`challengeDigest = SHA256(canonicalSignedBootstrapChallengeBytes)`. The client
first verifies a current root-signed manifest and key status, then this
signature, then its own `exchangeRequestDigest` correlation.

The challenge lifetime is at most five minutes. The server stores its ID,
nonce, exchange-request digest, validated identity/audience mapping, assigned
account/device IDs, derived platform, exact public bundle, mode, expiry, and
unused state in one bounded transactional record. No raw Apple token, subject,
name, or email enters it. Genesis is used only for an identity without an
account; pending is used for an existing account.

### One-time recovery authorization

After a fresh validated Apple exchange, the server may issue a bounded
`RecoveryAuthorizationV1` using a current manifest key whose purpose is exactly
`recovery_authorization`:

```text
LP(UTF8("Plainpost.RecoveryAuthorization.v1"))
LP(U16BE(1))
LP(authorizationIDBytes)
LP(accountIDBytes)
LP(U64BE(newEpoch))
LP(replacementDeviceIDBytes)
LP(UTF8(audienceDerivedPlatform))
LP(replacementBundle.signingKey)
LP(replacementBundle.agreementKey)
LP(exchangeRequestDigest)
LP(UTF8(issuedAt))
LP(UTF8(expiresAt))
LP(UTF8(serverKeyID))
```

`canonicalSignedRecoveryAuthorizationBytes` appends `LP(serverSignature)`, and
`recoveryAuthorizationDigest` is its SHA-256 digest. The authorization is
short-lived, account- and epoch-specific, stored server-side, and consumed
exactly once atomically with the recovery commit. Its replacement ID, platform,
bundle, exchange digest, account, and new epoch must exactly match the recovery
state and replacement record. Only `macos` and `ios` are valid; `sync_node`, a
wrong audience class, an expired/consumed authorization, or another recovery's
digest is rejected before commit validation, CAS, or any persistent write.

### Device-signed bootstrap finalize

Exactly `challenge.publicBundle.signingKey` verifies:

```text
LP(UTF8("Plainpost.AccountBootstrapFinalize.v1"))
LP(U16BE(1))
LP(exchangeRequestDigest)
LP(challengeDigest)
LP(challenge.challengeIDBytes)
LP(challenge.challengeNonce)
LP(challenge.accountIDBytes)
LP(challenge.deviceIDBytes)
LP(UTF8(challenge.mode))
LP(UTF8(challenge.platform))
LP(challenge.publicBundle.signingKey)
LP(challenge.publicBundle.agreementKey)
LP(genesisCommitDigest or empty)
```

Both finalize digest fields must equal the recomputed nested values and the
stored challenge. For genesis, `genesisCommitDigest` is the digest of the exact
`TrustStateCommitV1` defined below. Its signed state matches all challenge
identity, platform, and key fields, and its sole package targets that same
self-signed member. Pending carries JSON `null` and an empty final LP value.

The shared vectors include complete genesis and pending
`AccountBootstrapFinalizeV1` wire messages. Each names its exact expected
`challenge.publicBundle.signingKey`; genesis embeds and binds the exact genesis
commit, while pending embeds JSON `null` and signs the empty final field.
Conformance tests rebuild both transcripts and reject server-key or wrong-device
verification, exchange/challenge digest substitution, genesis-null,
pending-with-commit, and cross-mode substitution.

Finalize rejects replay, expiry, request-response substitution, digest/key/ID/
platform substitution, cross-mode, and cross-account use. Challenge
consumption, genesis or pending persistence, and activation are atomic. Every
activation carries `currentTrustCommit` as an untrusted convenience hint. A
client accepts it only after fetching and verifying the contiguous commit
history from its persisted high-water; a pending client gains no account
authority until it is subsequently admitted by that chain.

## Session key and refresh transcripts

Every Sync Node enrollment result, offline lease, and bounded refresh
credential repeats one atomic operation binding:

```text
LP(UTF8("Plainpost.SyncNodeOperationBinding.v1")) || LP(U16BE(1))
LP(accountIDBytes) || LP(U64BE(trustEpoch)) || LP(claimIDBytes)
LP(nodeDeviceIDBytes) || LP(UTF8(centralAudience)) || LP(UTF8(action))
LP(replacedNodeIDBytesOrEmpty)
LP(replacementRevocationDigestOrEmpty) || LP(admissionEvidenceDigest)
LP(issuanceDigest)
```

For `enroll`, both replacement fields are empty/null. For `replace`, both are
required and identify the exact old node and its revocation record. The three
closed documents repeat those fields verbatim. `centralAudience` is a nonempty
canonical UTF-8 string of at most 255 bytes with no NUL, CR, or LF; Task 6
supplies and verifies the configured production value before accepting a
credential, so a credential cannot replay against another Central deployment.
Their canonical transcripts are:

```text
LP(UTF8("Plainpost.SyncNodeEnrollmentResult.v1")) || LP(U16BE(1))
LP(operationBindingTranscript) || LP(UTF8(committedAt))

LP(UTF8("Plainpost.SyncNodeOfflineLease.v1")) || LP(U16BE(1))
LP(operationBindingTranscript) || LP(leaseIDBytes)
LP(UTF8(issuedAt)) || LP(UTF8(expiresAt)) || LP(UTF8(serverKeyID))

LP(UTF8("Plainpost.SyncNodeRefreshCredential.v1")) || LP(U16BE(1))
LP(operationBindingTranscript) || LP(credentialIDBytes)
LP(UTF8(issuedAt)) || LP(UTF8(expiresAt)) || LP(credentialBytes)
```

The lease signature covers its transcript. `admissionEvidenceDigest` is
`SHA256(canonical admission-evidence JSON)`. `issuanceDigest` is
`SHA256(SessionIssuanceTranscript(evidence, centralAudience, sessionDigest))`.
`sessionDigest` is `SHA256(SessionDigestV1(refreshCredentialBytes,
offlineLeaseIDBytes))`, so both Central and the approving Apple client can
recompute it from the returned documents. That transcript binds the canonical
admission transcript, Central audience, and session digest. These are frozen
as cross-document linkage for the later atomic admission implementation, not
as transport framing.

`SessionKeyManifestV1` is signed by the configured offline root over:

```text
LP(UTF8("Plainpost.SessionKeyManifest.v1"))
LP(U16BE(1))
LP(UTF8(rootKeyID))
LP(U64BE(manifestVersion))
LP(UTF8(notBefore))
LP(UTF8(expiresAt))
LP(U16BE(keyCount))
for each key sorted by keyID:
  LP(UTF8(keyID)) || LP(UTF8(purpose)) || LP(P256 public key)
  LP(UTF8(notBefore)) || LP(UTF8(expiresAt)) || LP(UTF8(status))
```

The refresh device proof is signed by the bound device signing key over:

```text
LP(UTF8("Plainpost.DeviceSessionProof.v1")) || LP(U16BE(1))
LP(accountIDBytes) || LP(deviceIDBytes) || LP(UTF8("POST"))
LP(UTF8("/v1/sessions/refresh")) || LP(SHA256(exact request body))
LP(U64BE(timestampUnixSeconds)) || LP(32-byte nonce)
```

Timestamps are canonical whole-second UTC. Refresh responses and manifests use
the closed wire contracts in `account.schema.json`; access and offline-lease
keys are purpose-separated and must cover the complete issued lifetime.

Every authenticated Task 7 account route additionally requires a closed DPoP
proof signed by the access-token device key over the exact request target
(path plus canonical query), body, and access token:

```text
LP(UTF8("Plainpost.DeviceAccountRequestProof.v1")) || LP(U16BE(1))
LP(UTF8(method)) || LP(UTF8(requestTarget))
LP(SHA256(exact request body)) || LP(SHA256(UTF8(accessToken)))
LP(U64BE(timestampUnixSeconds)) || LP(32-byte nonce)
LP(accountIDBytes) || LP(deviceIDBytes)
```

The server rechecks the exact device as active, accepts only GET/POST/PUT,
allows at most five minutes of clock skew, and atomically records the nonce.
Missing, replayed, cross-device, or method/path/query/body/token-substituted
proofs reject before route logic or persistence.

## Device approval matching transcript

The completed approval transcript is:

```text
LP(UTF8("Plainpost.AccountTrust.v1"))
LP(U16BE(protocolVersion))
LP(accountIDBytes)
LP(existingDeviceIDBytes)
LP(pendingDeviceIDBytes)
LP(existingSigningPublicKey)
LP(existingAgreementPublicKey)
LP(pendingSigningPublicKey)
LP(pendingAgreementPublicKey)
LP(existingNonce)
LP(pendingNonce)
LP(U64BE(expiresAtUnixMilliseconds))
```

Both nonces are distinct random 32-byte values. Expiry is a canonical positive
decimal UInt64 on the wire, is after creation, and is at most five minutes
later. Roles are fixed. `handshakeDigest = SHA256(transcript)`. The response,
secret transfer, and admission transition carry this digest. Each handshake
allows one recorded comparison; mismatch, expiry, cancellation, or a second
confirmation requires new nonces.

### Exactly six unbiased decimal digits

Let `D0 = handshakeDigest`. Interpret its first 20 most-significant bits as an
unsigned integer. Accept `0...999999` and render exactly six digits. Reject
larger candidates. For retry counter `c` beginning at one:

```text
retryInput(c) = LP(UTF8("Plainpost.AccountTrust.SASRetry.v1"))
              || LP(D0)
              || LP(U32BE(c))
Dc = SHA256(retryInput(c))
candidate(c) = first20MSB(Dc)
```

Counter zero is never encoded; failure at `4,294,967,295` fails closed.
`first20MSB(d) = (d[0] << 12) | (d[1] << 4) | (d[2] >> 4)`.

## Signed trust history

### Active device records

`TrustStateV1.members` contains only current active trusted devices, strictly
sorted by raw device UUID bytes, with no duplicate IDs. A device record signs:

```text
LP(UTF8("Plainpost.DeviceTrustRecord.v1"))
LP(U16BE(1))
LP(accountIDBytes)
LP(U64BE(epoch))
LP(U64BE(revision))
LP(deviceIDBytes)
LP(UTF8(platform))
LP(publicBundle.signingKey)
LP(publicBundle.agreementKey)
LP(signerDeviceIDBytes)
```

`canonicalSignedTrustRecordBytes` appends `LP(signature)` and its digest is
SHA-256 of those bytes. A newly admitted or changed record has `revision` equal
to its resulting state revision. Every unchanged surviving record is retained
byte-for-byte, including its older revision and signature. Every member record's
account and epoch equal its enclosing state, and device IDs are unique.

The enclosing transition's signer rules apply only to records newly created or
changed in the resulting state. An unchanged survivor is accepted only when its
complete canonical signed record bytes equal its exact verified predecessor
record in the contiguous commit history. It inherits that predecessor's
authority even if the original signer is no longer active. Any survivor byte
change makes it a changed record and requires current-transition authorization;
an unauthorized mutation fails closed.

Genesis has one record self-signed by that record's device. Admission's new
record is signed by the prior active approver whose completed handshake and
bound `pendingDeviceDigest` name the exact stored account, device,
audience-derived platform, and public bundle. Recovery's sole replacement
record is self-signed only when it exactly matches the one-time
`RecoveryAuthorizationV1` bound into the transition. Creation requires that
authorization to be live; historical verification uses the persisted evidence
described below. No other new or changed
self-signing is authorized. Verifiers
reject cross-account or cross-epoch records, unknown signers on new or changed
records, and new or changed signers not authorized by the transition. These
checks do not retroactively invalidate a byte-identical survivor whose original
signer later became inactive.

### Signed transition and complete state

Every state has one transition. Target IDs and prior-record digest entries are
strictly sorted by device ID and unique. Genesis targets its sole new member
and has no priors. Admission targets one new member, has no prior, and carries
the handshake and pending-device authorization digests. Revocation or
suspension targets exactly one removed member and carries that exact prior
record digest. Recovery targets every
prior active member and carries every corresponding prior digest; both arrays
are equal sets and bounded to 11. Recovery also carries the exact one-time
recovery-authorization digest.

```text
transitionBytes =
    LP(UTF8(transition.kind))
 || LP(U16BE(targetDeviceIDs.count))
 || each LP(targetDeviceIDBytes)
 || LP(U16BE(priorRecordDigests.count))
 || each LP(deviceIDBytes) || LP(recordDigest)
 || LP(handshakeDigest or empty)
 || LP(pendingDeviceDigest or empty)
 || LP(recoveryAuthorizationDigest or empty)
```

The 64-byte account key material is
`mailboxMatchingKey || metadataKey`, each 32 random bytes, and:

```text
keyCommitment = SHA256(mailboxMatchingKey || metadataKey)
```

The state signature covers:

```text
LP(UTF8("Plainpost.TrustState.v1"))
LP(U16BE(1))
LP(accountIDBytes)
LP(U64BE(epoch))
LP(U64BE(revision))
LP(previousCommitDigest or empty)
LP(transitionBytes)
LP(U64BE(keyGeneration))
LP(keyCommitment)
LP(U16BE(members.count))
for member in members:
    LP(canonicalSignedTrustRecordBytes(member))
LP(signerDeviceIDBytes)
```

`previousCommitDigest` is empty only for genesis. Every admission, revocation,
suspension, and recovery state signs the exact SHA-256 digest of the immediately
preceding atomic `TrustStateCommitV1`; recovery therefore links across the epoch
boundary to the last prior-epoch commit. `canonicalSignedTrustStateBytes`
appends `LP(signature)`, and
`stateDigest = SHA256(canonicalSignedTrustStateBytes)`. The state signer
resolves through verified contiguous history. Genesis and recovery are signed
by their authorized self-signed replacement. Admission is signed by the same
prior active approver that signed the admitted record and completed the matching
handshake. A removal binds the removed member's exact prior record digest and
is signed by an authorized surviving member that was active in the prior state.

### Lifecycle and high-water rules

- **Genesis:** epoch `1`, revision `1`, null predecessor, one self-signed active
  member, genesis transition, key generation `1`, and fresh key material.
- **Admission:** same epoch, prior revision plus one, exact prior atomic
  `commitDigest`,
  one new active member whose record revision equals the new state revision,
  account/device/platform/bundle exactly matching the live stored pending
  authorization bound by `pendingDeviceDigest`, unchanged survivors
  byte-identical, and the current key generation and commitment unchanged. The
  signer packages the current keys to all resulting active members, including
  the new device. A mismatch is rejected before atomic commit/CAS.
- **Revocation/suspension:** same epoch and next revision; the target is removed
  rather than retained as a member, and `previousCommitDigest` equals the exact
  prior atomic commit. Survivors are byte-identical. Both account
  keys rotate atomically, key generation increments exactly once, packages go
  only to survivors, and private mailbox IDs and encrypted metadata are
  recomputed under the new generation. The target receives no package. The
  final active device cannot be removed outside recovery or deletion.
- **Recovery:** epoch is prior epoch plus one, revision `1`,
  `previousCommitDigest` equals the last prior-epoch atomic commit, transition
  records all prior active devices (maximum 11), and one replacement device is
  self-signed. The bound live one-time recovery authorization must exactly match
  its account, new epoch, replacement ID, Apple-derived `macos`/`ios` platform,
  and bundle; Sync Node recovery is impossible. Fresh keys are created at
  generation `1`; no old key material returns. The resulting one-member state has exactly
  one package for the replacement device. Sessions and leases for the prior
  epoch are atomically suspended.
- Active membership remains capped at 5 `macos`, 5 combined `ios`, and 1
  `sync_node`, transactionally enforced from server-derived classes. Because
  tombstones live in signed history rather than current members, lifetime
  replacement count is unlimited and history is retrieved in bounded pages.
- Commit high-water identity is `(accountID, epoch, revision, commitDigest)`.
  Comparison is lexicographic by epoch first, revision second. Any
  higher epoch beats every lower epoch; recovery `(oldEpoch + 1, 1)` therefore
  beats all prior coordinates. Lower coordinates are rollback. Equal
  account/epoch/revision coordinates require the identical `commitDigest` and
  byte-identical canonical commit or report equivocation, even when the signed
  `stateDigest` is identical but package bytes differ. Jumps require every
  contiguous predecessor commit and complete commit.

A package-only fork is therefore not hidden by a shared `stateDigest`. If
atomic commits A and B have identical signed state bytes but different valid
package bytes, then `stateDigest(A) == stateDigest(B)` while
`commitDigest(A) != commitDigest(B)`. A successor C whose device-signed
`previousCommitDigest` names A is rejected when the persisted checkpoint or
history head is B. Replacing A with B would invalidate C's state signature;
page-delivery signatures cannot authorize the substitution.

### Lifecycle step-up, recovery, and deletion control plane

All lifecycle JSON uses the same closed canonical representation in Go and
Swift: UTF-8 JSON, no whitespace, lexicographically sorted object keys,
canonical unpadded base64url, canonical UUID text, whole-second UTC timestamps,
and decimal-string UInt64 values. Unknown, duplicate, reordered, missing, or
non-canonical fields reject before authorization or persistence. The shared
`accountLifecycle` fixture is the executable cross-language oracle.

An active device obtains a single-use, at-most-five-minute step-up for
`add_device`, `revoke_device`, `suspend_device`, or `delete_account`. The fresh
Apple token is method-local: the request carries it only to the verifier, which
discards it after checking issuer, audience, nonce, account identity, and
platform. Only the request digest and signed authorization may be persisted.
Local biometric confirmation occurs immediately before submitting the signed
candidate or deletion request and is never encoded as a server-verifiable
claim.

```text
stepUpRequestTranscript =
    LP(UTF8("Plainpost.AccountStepUpRequest.v1"))
 || LP(U16BE(1))
 || LP(accountIDBytes)
 || LP(actorDeviceIDBytes)
 || LP(targetDeviceIDBytes or empty)
 || LP(UTF8(action))
 || LP(currentCommitDigest)
 || LP(requestNonce)
 || LP(appleNonce)
 || LP(SHA256(UTF8(identityToken)))

stepUpRequestDigest = SHA256(stepUpRequestTranscript)

stepUpAuthorizationTranscript =
    LP(UTF8("Plainpost.AccountStepUpAuthorization.v1"))
 || LP(U16BE(1))
 || LP(authorizationIDBytes)
 || LP(accountIDBytes)
 || LP(actorDeviceIDBytes)
 || LP(targetDeviceIDBytes or empty)
 || LP(UTF8(action))
 || LP(currentCommitDigest)
 || LP(stepUpRequestDigest)
 || LP(UTF8(issuedAt))
 || LP(UTF8(expiresAt))
 || LP(UTF8(serverKeyID))
```

The authorization signature is raw low-S P-256 under a live manifest key whose
purpose is exactly `recovery_authorization`. It is consumed in the same
serializable transaction as the admission/removal commit, exact evidence,
packages, device lifecycle, security event, and trust head. An exact retry of
the already-published byte-identical head is idempotent; a different action,
target, request digest, authority row, or candidate rejects without mutation.

Last-resort recovery does not use the ordinary step-up request. Fresh Apple
verification issues one purpose-signed `RecoveryAuthorizationV1` bound to the
exact prior atomic head and replacement bundle. The replacement verifies the
complete prior history, constructs a non-publishing epoch-reset candidate, and
proves that exact submission with its replacement device key. Central
acceptance, prior-session and lease suspension, replacement-session issuance,
security event, and head advance are one transaction. The client installs only
the byte-identical accepted entry and recipient package using its authenticated
local recovery journal.

Global deletion is likewise action- and head-bound. Before live rows are
disabled, the service appends a gapless marker to a physically separate durable
journal and blocks account traffic through that captured sequence. Version 3
markers contain only a random opaque account handle, deletion generation,
marker digest, whole-second deletion time, and a bounded canonical set of
opaque cleanup handles/kinds/statuses/credential digests. They contain no
account UUID, Apple identity, endpoint, label, mailbox, token, or key. Replay
can therefore reconstruct the deletion record, cleanup targets, purge outbox,
security event, and authority revocation after a stale account snapshot is
restored. Readiness remains false until the durable journal high-water is
applied.

Registered clients and Sync Nodes use their target-bound cleanup credential
only for `cleanup-check` and `cleanup-ack`; it never authorizes account traffic.
Reachable Plainpost-managed targets erase local databases, caches, drafts,
outbox/operation journals, attachments, registrations, and controlled key
copies before acknowledging. Provider accounts and provider-hosted mail are
never deleted. Offline targets remain `erasure_pending`; independently managed
snapshots or copied keys remain `operator_action_required`. Restore checks the
deletion gate before readiness, preventing stale state from resurrecting the
account.

### Persistent transition evidence

Trust history transports and locally persists an exact `TrustHistoryEntryV1`
for every commit. Genesis, revocation, and suspension entries carry null
evidence. Admission entries carry a closed `TrustAdmissionEvidenceV1` with the
exact `PendingDeviceV1` plus the complete peer response (complete offer and
pending nonce). Recovery entries carry a closed `TrustRecoveryEvidenceV1` with
the exact `RecoveryAuthorizationV1` plus the exact historical
`CentralBootstrapKeyManifestV1` that authorized its `serverKeyID`. These public
objects contain no private material.

Admission evidence independently rebuilds both `pendingDeviceDigest` and
`handshakeDigest` and must match every account, device, platform, bundle,
signer, and time-window field in the admitted state. Recovery evidence first
verifies the supplied manifest directly under the app-pinned offline root,
then selects exactly one active `recovery_authorization` key whose manifest and
key half-open lifetimes contain `authorization.issuedAt`, and finally verifies
the authorization signature and at-most-five-minute authorization window.
Historical verification is independent of current wall-clock time, the current
manifest, and the current-plus-four overlap cache. Live recovery creation still
requires `issuedAt <= now < expiresAt` and a currently accepted manifest.

For page binding:

```text
admissionEvidenceDigest = SHA256(
    LP(pendingDeviceDigest) || LP(handshakeDigest))
signedRecoveryAuthorizationDigest = SHA256(
    recoveryAuthorizationTranscript || LP(serverSignature))
historicalManifestDigest = SHA256(
    canonicalManifestTranscript || LP(rootSignature))
recoveryEvidenceDigest = SHA256(
    LP(signedRecoveryAuthorizationDigest) || LP(historicalManifestDigest))
historyEntryDigest = SHA256(
    LP(commitDigest) || LP(UTF8(evidence.kind or empty))
                     || LP(evidenceDigest or empty))
```

The closed evidence codecs reject missing, unknown, or duplicate fields,
non-canonical base64url and decimal strings, invalid points/signatures, and
invalid time bounds before authority verification.

### Bounded trust-history pages

A checkpoint is `(epoch, revision, commitDigest)`. `checkpointBytes` is
`LP(U64BE(epoch)) || LP(U64BE(revision)) || LP(commitDigest)`. `afterBytes` is
`LP(UTF8("genesis"))` for the genesis sentinel, otherwise
`LP(checkpointBytes(after))`. A closed cursor is signed by a currently active
manifest key with purpose `trust_pagination` over:

```text
LP(UTF8("Plainpost.TrustCursor.v1"))
LP(U16BE(1))
LP(accountIDBytes)
LP(afterBytes)
LP(checkpointBytes(snapshotHead))
LP(UTF8(issuedAt))
LP(UTF8(expiresAt))
LP(UTF8(serverKeyID))
```

`canonicalSignedTrustCursorBytes` appends `LP(signature)` and
`cursorDigest = SHA256(canonicalSignedTrustCursorBytes)`. Cursor validity is at
most five minutes and half-open: `issuedAt <= verificationTime < expiresAt`.

The closed page is signed by the same purpose-scoped key over:

```text
LP(UTF8("Plainpost.TrustStatePage.v1"))
LP(U16BE(1))
LP(requestCursorDigest)
LP(accountIDBytes)
LP(checkpointBytes(snapshotHead))
LP(U16BE(entries.count))
for entry in entries:
    LP(historyEntryDigest)
LP(nextCursorDigest or empty)
LP(U16BE(terminal ? 1 : 0))
LP(UTF8(issuedAt))
LP(UTF8(expiresAt))
LP(UTF8(serverKeyID))
```

`canonicalSignedTrustStatePageBytes` appends `LP(serverSignature)`. Page
validity is also at most five minutes and half-open. The page's embedded
`requestCursor` is always non-null. For an initial checkpoint/genesis query,
the server mints it with `after` exactly equal to that query and freezes the
current head before signing the page. For a continuation, it is byte-identical
to the cursor supplied by the client. Its digest is always bound by the page
signature. A continuation's `nextCursor.after` is the last returned checkpoint
and its frozen `snapshotHead` is unchanged. The account, frozen head, time
interval, and server key agree across cursor and page.

The first request is `GET /v1/trust/chain?after=genesis&limit={1...32}` or names
the persisted checkpoint with `afterEpoch`, `afterRevision`, and
`afterCommitDigest`. Continuations use a canonical base64url JSON `cursor` and
the same limit; encoded cursor input is capped at 4096 bytes. A nonterminal page
contains exactly 1...32 contiguous commit/evidence entries and a next cursor.
A terminal page has no next cursor; it contains 1...32 entries ending at the frozen head, or is
empty only when `requestCursor.after == snapshotHead`. Commit ordering, exact
`state.previousCommitDigest` links, coordinates, account, package coverage, and
page-to-page frozen head are verified. Gaps, reordering, duplicates, equivocation, premature terminal pages,
or commits beyond the frozen head fail closed.

Cursor and page server signatures authenticate delivery only; signed device
records, states, and packages remain the sole trust authority. On cursor or
page expiry the client discards the page sequence and restarts from its
persisted verified high-water, never from unverified page data.

## Account group key packages

Packages are created only after the signed state is finalized, avoiding a
digest cycle. There is exactly one package for every resulting active member,
with no extra recipient. The package sender is the state signer.

For each recipient, generate a fresh ephemeral P-256 agreement key and 12-byte
random nonce. Let `Z` be P-256 ECDH between that ephemeral private key and the
recipient record's agreement public key. Derive:

```text
packageInfo = LP(UTF8("Plainpost.AccountGroupKeyPackage.KDF.v1"))
           || LP(accountIDBytes)
           || LP(U64BE(epoch))
           || LP(U64BE(stateRevision))
           || LP(U64BE(keyGeneration))
           || LP(stateDigest)
           || LP(recipientDeviceIDBytes)
           || LP(senderDeviceIDBytes)
packageKey = HKDF-SHA256(IKM=Z, salt=stateDigest, info=packageInfo, L=32)
```

The AES-256-GCM AAD is:

```text
LP(UTF8("Plainpost.AccountGroupKeyPackage.AAD.v1"))
LP(U16BE(1))
LP(accountIDBytes)
LP(U64BE(epoch))
LP(U64BE(stateRevision))
LP(U64BE(keyGeneration))
LP(stateDigest)
LP(keyCommitment)
LP(recipientDeviceIDBytes)
LP(senderDeviceIDBytes)
LP(senderEphemeralPublicKey)
```

Encrypt the exact 64-byte key material with no compression. Wire
`encryptedKeyMaterial` is `ciphertext(64) || tag(16)`; nonce is separate. The
package signature transcript is:

```text
LP(UTF8("Plainpost.AccountGroupKeyPackage.Signature.v1"))
LP(U16BE(1))
LP(accountIDBytes)
LP(U64BE(epoch))
LP(U64BE(stateRevision))
LP(U64BE(keyGeneration))
LP(stateDigest)
LP(keyCommitment)
LP(recipientDeviceIDBytes)
LP(senderDeviceIDBytes)
LP(senderEphemeralPublicKey)
LP(SHA256(nonce || ciphertext || tag))
```

`canonicalSignedAccountGroupKeyPackageBytes` is that transcript followed by
`LP(signature)`.

The server verifies recipient coverage, state/generation/commitment metadata,
sender and package signatures, sizes, and uniqueness, but never plaintext.
Recipients decrypt and compare the key commitment before use.

## Atomic trust-state commits

`TrustStateCommitV1` is the only accepted and persisted trust-transition unit.
Its state is finalized and signed first; `stateDigest` is then computed; its
packages are then built and signed against that digest. Packages are strictly
sorted by raw `recipientDeviceID`, unique, and cover exactly every resulting
active state member once. Every package has the same account, epoch, state
revision, key generation, state digest, and key commitment as the state; no
removed or nonmember ID appears. `senderDeviceID` equals the state signer and is
authorized by the transition rules. Genesis has exactly one self package.

The canonical commit bytes are:

```text
LP(UTF8("Plainpost.TrustStateCommit.v1"))
LP(U16BE(1))
LP(canonicalSignedTrustStateBytes(state))
LP(U16BE(keyPackages.count))
for package in keyPackages:
    LP(canonicalSignedAccountGroupKeyPackageBytes(package))
```

```text
commitDigest = SHA256(canonicalTrustStateCommitBytes)
```

No additional commit signature is needed: the complete state and every ordered
package are already signed by the authorized transition signer, and the digest
commits to their complete signed bytes. Bootstrap finalize binds this digest.
Admission, revocation, suspension, and recovery submit exactly one commit to
atomic `PUT /v1/trust/state-commit`; state, packages, and head advance persist
transactionally or not at all. Individual state/package writes are rejected.
History pages contain ordered commit/evidence entries, so chain acceptance also proves package
coverage for every generation.

The server compare-and-swap key, client checkpoint, idempotency key, and page
authority all use `(accountID, epoch, revision, commitDigest)`. A retry at equal
account/epoch/revision is idempotent only when the canonical commit bytes and
`commitDigest` are identical. A different package set, package signature, or
other commit byte is equivocation even if `stateDigest` is unchanged.

## Encrypted account records

Task 6 owns interoperable encryption/decryption. The current 32-byte metadata
key encrypts plaintext of 1..65,508 bytes with a unique 12-byte nonce and
AES-256-GCM, without compression. Each local device derives an 8-byte namespace
as the first eight bytes of
`HMAC-SHA256(metadataKey, LP("Plainpost.MetadataNonceNamespace.v1") ||
LP(canonicalSignedLocalMemberTrustRecord))`. The signed member record binds the
stable device ID, admission/re-admission revision, platform, public bundle, and
record authority. Each retained generation persists that exact namespace plus
an atomically compare-and-swapped monotonic 32-bit counter. The nonce is
`namespace || U32BE(counter)`; a namespace mismatch or counter overflow fails
closed and requires key-generation rotation. This prevents devices sharing the
same metadata key from sharing an AES-GCM nonce stream. The bounded state is
deleted only when that generation is explicitly retired. Wire `envelope` is exactly
`nonce(12) || ciphertext || tag(16)` and is at most 65,536 bytes.

AAD is:

```text
LP(UTF8("Plainpost.EncryptedAccountRecord.AAD.v1"))
LP(U16BE(1))
LP(accountIDBytes)
LP(recordIDBytes)
LP(U64BE(epoch))
LP(U64BE(keyGeneration))
LP(U64BE(trustRevision))
LP(U64BE(recordRevision))
```

The member selected by `signerDeviceID` signs:

```text
LP(UTF8("Plainpost.EncryptedAccountRecord.Signature.v1"))
LP(U16BE(1))
LP(accountIDBytes)
LP(recordIDBytes)
LP(U64BE(epoch))
LP(U64BE(keyGeneration))
LP(U64BE(trustRevision))
LP(U64BE(recordRevision))
LP(SHA256(envelope))
LP(signerDeviceIDBytes)
```

The signer is active in the exact selected trust state and the generation and
commitment select the locally held metadata key. Per record, high-water is
lexicographic `(epoch, keyGeneration, recordRevision)`. Lower values are
rollback; equal coordinates require the same signed envelope digest or report
equivocation. Before creating a first high-water row, the client CAS-reserves
its sorted unique `recordID` in one per-account device-only index capped at the
same 4,096 entries as the frozen inventory proof. Reuse does not consume another
slot; a malformed/over-cap index or a 4,097th distinct ID fails closed before a
row write, and a crash after reservation leaves only bounded retry state.
Prior-generation records are re-encrypted after rotation and
prior-epoch records are never imported after recovery. Nonce reuse under one
metadata key is a release-blocking failure. The server's Task 7 CRUD remains
opaque and validates only bounds, signatures, ownership, and monotonic fields.

### Frozen record inventory and explicit generation retirement

Generation retirement requires a closed `AccountRecordInventoryProofV1` signed
by a currently live manifest key with purpose `trust_pagination`. The central
service atomically freezes the complete record inventory after the exact trust
head `(accountID, epoch, revision, trustCommitDigest)`, rejects writes for the
generation while frozen, and returns at most 4,096 entries sorted by unique
`recordID`. Each entry binds the record coordinate plus both
`SHA256(envelope)` and `SHA256(signature)`. An empty inventory is valid only as
an authenticated zero-count proof. The half-open proof lifetime is at most five
minutes.

The entry transcript is:

```text
LP(UTF8("Plainpost.AccountRecordInventoryEntry.v1"))
LP(U16BE(1))
LP(recordIDBytes)
LP(U64BE(epoch))
LP(U64BE(keyGeneration))
LP(U64BE(trustRevision))
LP(U64BE(recordRevision))
LP(envelopeDigest)
LP(signatureDigest)
```

The proof signature preimage is:

```text
LP(UTF8("Plainpost.AccountRecordInventoryProof.v1"))
LP(U16BE(1))
LP(accountIDBytes)
LP(trustCommitDigest)
LP(U64BE(epoch))
LP(U64BE(keyGeneration))
LP(U16BE(entries.count))
for entry in entries:
    LP(recordInventoryEntryTranscript)
LP(UTF8(issuedAt))
LP(UTF8(expiresAt))
LP(UTF8(serverKeyID))
```

The client verifies the exact frozen head, key purpose/status/lifetime,
low-S signature, expiry, sorted completeness, and one-to-one equality between
the proof entries and the supplied resealed records before removing old local
material. Omission, substitution, stale head, wrong generation, wrong purpose,
or expiry rejects without retirement.

## Sync Node enrollment admission (account-v1)

Sync Node enrollment is a separate account-v1 state machine. It never uses Apple bootstrap, generic device admission, rendezvous, recovery, or legacy pairing records. The Node Noise static public key is only a claim/evidence binding; this protocol does not define Noise transport framing.

`enroll` is valid only when `replacedNodeID` is empty and its `enroll_sync_node` step-up targets the proposed node. A normal enrollment conflicts if an active node exists. `replace` is valid only when its `replace_sync_node` step-up targets the same exact active old node named by `replacedNodeID`; the evidence separately binds the proposed node. Replacement preserves Apple account members and all trust history. Claim ciphertext, setup verifier material, matching strings, private keys, plaintext endpoints, sessions, and dependency error bodies are never put in public views, signed evidence, or audit output.

All inputs use LP framing defined above. The domains are intentionally distinct:

```text
Claim proof: LP("Plainpost.SyncNodeClaimProof.v1") LP(U16BE(1)) LP(claimID) LP(nodeDeviceID) LP(signingPublicKey) LP(agreementPublicKey) LP(noiseStaticPublicKey) LP(endpointDigest) LP(createdAt) LP(expiresAt)
Matching confirmation: LP("Plainpost.SyncNodeMatchingConfirmation.v1") LP(U16BE(1)) LP(accountID) LP(claimProof)
Admission approval: LP("Plainpost.SyncNodeAdmissionApproval.v1") LP(U16BE(1)) LP(accountID) LP(U64BE(epoch)) LP(approverDeviceID) LP(claimID) LP(nodeDeviceID) LP(action) LP(replacedNodeID-or-empty) LP(signingPublicKey) LP(agreementPublicKey) LP(noiseStaticPublicKey) LP(endpointDigest) LP(matchingDigest) LP(stepUpAuthorizationTranscript) LP(idempotencyKey)
Replacement approval: LP("Plainpost.SyncNodeReplacementApproval.v1") LP(U16BE(1)) LP(admissionApproval)
Session issuance: LP("Plainpost.SyncNodeSessionIssuance.v1") LP(U16BE(1)) LP(admissionApproval-with-empty-idempotency-key) LP(UTF8(centralAudience)) LP(sessionDigest)
Session digest: SHA256(LP("Plainpost.SyncNodeSessionDigest.v1") LP(U16BE(1)) LP(refreshCredentialBytes) LP(offlineLeaseIDBytes))
Idempotency digest: SHA256(LP("Plainpost.SyncNodeAdmissionIdempotency.v1") LP(U16BE(1)) LP(accountID) LP(idempotencyKey))
```

Central looks up a committed replay by `accountID` and the idempotency digest.
The older `Plainpost.SyncNodeReplayLookup.v1` transcript helpers, which also
bind `claimID`, still exist in the Go and Swift code but are not used for the
lookup.

### Declared Central audience (additive)

`account.sync-node-admission-request.v1` may carry an eighth key,
`expectedCentralAudience`: the audience the Apple client pinned from its
Server Setup profile v2. It is a JSON string that satisfies the audience wire
rule. It is covered by the DPoP body digest. It is not part of the admission
request digest, the idempotency digest, or any signature transcript, so a
legacy seven-key replay and a declared replay of one committed request return
the same stored result.

Central compares a present value with its configured audience immediately
after structural validation. On mismatch, it returns HTTP 422
(`application/problem+json`) before replay lookup, step-up verification, or
any transaction. An absent key is the legacy form and is not gated. A present
key that is not a JSON string satisfying the wire rule is a malformed request
(HTTP 400).

Apple clients obtain the expected audience only from `sync-node.bootstrap-profile.v2`.
They never derive it from the Central origin. The Node verifier leaf
`sync-node.bootstrap-verifier.v2` carries the same label, and the Node refuses
to bind it under a different `PLAINPOST_NODE_CENTRAL_AUDIENCE`. Both documents
require the portable label form `^[A-Za-z0-9][A-Za-z0-9_.:-]{0,254}$`.

### Possibly committed admission outcomes

`POST /v1/sync-nodes/enrollment/approve` and `POST /v1/sync-nodes/replacement`
return HTTP 500 (`application/problem+json`) whenever the admission may already
be committed:

- the transaction commit was sent but its outcome is unknown;
- a stored result exists for this idempotency key but cannot be read or
  opened, or the opened result does not bind this request's account, claim,
  Node, action, and Central audience;
- the result of a new commit does not bind the request, or cannot be encoded.

A stored result whose request digest differs from this request is an
idempotency conflict (HTTP 409), not a replay. A 4xx answer is definite for
the attempt it answers: that attempt did not commit. Apple clients treat any
5xx, a transport loss, or an undecodable 2xx as possibly committed. They keep
the exact request and idempotency key and replay it. After an uncertain
attempt, a later 4xx does not release the request, and after any 2xx the
client never cancels the claim.

### Claim cancellation

`POST /v1/sync-nodes/claims/cancel` carries `setupCode` and `claimID`. Central
answers HTTP 204 when the claim matching that ID and setup verifier is not
consumed: it records the cancellation, or finds it already cancelled. Expiry
does not prevent this, and repeating the cancel returns 204 again. A consumed,
unknown, or mismatched claim returns HTTP 404. Cancellation runs under the same
serializable claim lock as admission, and a claim is never both cancelled and
consumed, so a 204 proves the claim was never admitted. An Apple client
releases an uncertain admission request only after a 204; any other answer
keeps the request for replay.

### Cleanup-capability admission extension

The additive cleanup capability is canonical
`account.sync-node-cleanup-capability.v1`: account ID, claim ID, node device
ID, random target handle, independent random cleanup credential, positive next
deletion generation, and issued-at. Its digest is `SHA256(canonical wire)`.
Central persists only `SHA256(cleanup credential)` in the registration and the
whole capability only in the separately encrypted admission replay value.

V2 operation binding adds that capability digest and uses
`Plainpost.SyncNodeOperationBinding.v2`; result, refresh, lease, session
issuance, and session digest use their corresponding `.v2` domains. The V2
session digest frames refresh credential bytes, lease ID, and capability digest.
The replay AAD is exactly `Plainpost.SyncNodeAdmissionReplay.v2`. V1 replay
ciphertext and documents retain their original meaning and AAD.

`account.cleanup-check.v2` contains only target handle and generation. Its
credential is the canonical `Authorization: Cleanup <base64url>` header. A V2
response is one of `clean`, `erasure_pending`, or `erased`; only an exact
active registered Sync Node can receive `clean`.

The step-up input is the existing `Plainpost.AccountStepUpAuthorization.v1` transcript and therefore binds its authorization ID and absolute expiry. Every field above is mutation-sensitive; generic trust/admission codecs reject `account.sync-node-admission-evidence.v1` as an unknown kind.

## Canonical retry vector

The four points below use deterministic P-256 private scalars 10, 11, 12, and
13 exclusively for the existing-signing, existing-agreement, pending-signing,
and pending-agreement SAS roles. The shared fixture publishes those and every
other synthetic private scalar as conspicuously test-only conformance input.
They are non-production keys and must never enter a real account, manifest, or
deployment. The expiry is a decimal wire string parsed to the same U64BE bytes
used below.

```text
protocolVersion: 1
accountID: 00112233-4455-6677-8899-aabbccddeeff
existingDeviceID: 11111111-2222-3333-4444-555555555555
pendingDeviceID: aaaaaaaa-bbbb-cccc-dddd-00000000000c
existingSigningPublicKey: 04cef66d6b2a3a993e591214d1ea223fb545ca6c471c48306e4c36069404c5723f878662a229aaae906e123cdd9d3b4c10590ded29fe751eeeca34bbaa44af0773
existingAgreementPublicKey: 043ed113b7883b4c590638379db0c21cda16742ed0255048bf433391d374bc21d19099209accc4c8a224c843afa4f4c68a090d04da5e9889dae2f8eefce82a3740
pendingSigningPublicKey: 04741dd5bda817d95e4626537320e5d55179983028b2f82c99d500c5ee8624e3c40770b46a9c385fdc567383554887b1548eeb912c35ba5ca71995ff22cd4481d3
pendingAgreementPublicKey: 04177c837ae0ac495a61805df2d85ee2fc792e284b65ead58a98e15d9d46072c0163bb58cd4ebea558a24091adb40f4e7226ee14c3a1fb4df39c43bbe2efc7bfd8
existingNonce: 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
pendingNonce: 202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f
expiresAtUnixMilliseconds: "1735689600003"
transcript: 00000019506c61696e706f73742e4163636f756e7454727573742e76310000000200010000001000112233445566778899aabbccddeeff000000101111111122223333444455555555555500000010aaaaaaaabbbbccccdddd00000000000c0000004104cef66d6b2a3a993e591214d1ea223fb545ca6c471c48306e4c36069404c5723f878662a229aaae906e123cdd9d3b4c10590ded29fe751eeeca34bbaa44af077300000041043ed113b7883b4c590638379db0c21cda16742ed0255048bf433391d374bc21d19099209accc4c8a224c843afa4f4c68a090d04da5e9889dae2f8eefce82a37400000004104741dd5bda817d95e4626537320e5d55179983028b2f82c99d500c5ee8624e3c40770b46a9c385fdc567383554887b1548eeb912c35ba5ca71995ff22cd4481d30000004104177c837ae0ac495a61805df2d85ee2fc792e284b65ead58a98e15d9d46072c0163bb58cd4ebea558a24091adb40f4e7226ee14c3a1fb4df39c43bbe2efc7bfd800000020000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f00000020202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f00000008000001941f297c03
D0: f9ee6d0ee0d3dfaf5c655c15311a5559fc43da6bcc577ed3fa8342dc0d28db77
candidate0: 1023718 (rejected)
retryInput(1): 00000022506c61696e706f73742e4163636f756e7454727573742e53415352657472792e763100000020f9ee6d0ee0d3dfaf5c655c15311a5559fc43da6bcc577ed3fa8342dc0d28db770000000400000001
D1: 34fc10faa4355371d5219d1aeb222d044eb7dd959ae3acfc44a1202eb1353903
authenticationString: 217025
```

The shared manifest, semantic exchanges, challenges, complete finalizes,
commit forks A/B plus successor C, pending/recovery authorizations, group
packages, pagination, encrypted record, and role inventory live in
`fixtures/crypto-vectors-v1.json`. It publishes the exact synthetic 32-byte
private scalars and 64-byte account-key plaintext needed to independently
derive every public point, RFC 6979 signature, ECDH/HKDF/AES-GCM result, and
commitment. Structured wrong-role cases name only defined roles and all expect
rejection. Tests rebuild every byte and never use JSON serialization, stored
transcript hex, hidden ordering, or guessed key material as a cryptographic
preimage.

## Sync Node current-authority v1

`account.sync-node-current-authority-request.v1` is a Node-authenticated,
closed request. Exactly one selector is present: checkpoint (`after`) or the
raw canonical signed trust cursor (`cursor`). Its signature transcript is:

```text
LP("Plainpost.SyncNodeCurrentAuthorityRequest.v1") || LP(U16BE(1)) ||
LP(accountID) || LP(nodeDeviceID) || LP(clientDeviceID) ||
LP(clientRequestDigest) || LP(centralAudience) || LP(selector) || LP(nonce) ||
LP(issuedAt)
```

The selector is `LP("checkpoint") || LP(U64BE(epoch)||U64BE(revision)||digest)`
or `LP("cursor") || LP(SHA256(canonicalCursorJSON))`. The request digest is
`SHA256(transcript || LP(nodeSignature))`.

`account.sync-node-current-authority.v1` wraps the exact canonical
`account.trust-state-page.v1`; it never substitutes a lossy page projection.
It is signed by the active `trust_pagination` key over:

```text
LP("Plainpost.SyncNodeCurrentAuthority.v1") || LP(U16BE(1)) ||
LP(requestDigest) || LP(accountID) || LP(nodeDeviceID) || LP(clientDeviceID) ||
LP(clientRequestDigest) || LP(authorityHead) || LP(nodeRecordDigest) ||
LP(SHA256(canonicalPageJSON)) || LP(centralAudience) || LP(issuedAt) ||
LP(expiresAt) || LP(serverKeyID)
```

The wrapper has a maximum 60-second half-open window and cannot outlive the
nested page. `current-authority.request.verify` is fixed to device signing;
`current-authority.response.verify` is fixed to pagination. V1 is closed.
