# node-session-v1 transcripts

`node-session-v1` is the closed private-session wire contract shared by the
Sync Node and native clients. JSON byte fields use unpadded base64url. Every
object rejects unknown or omitted fields. UUIDs use lowercase canonical RFC
4122 spelling. Integer wire values are decimal strings with no leading zero.

`issuedAt` is a real UTC RFC3339 calendar instant with exactly whole-second
precision. IDs are nonzero lowercase RFC4122 UUIDs (versions 1 through 5,
RFC4122 variant). Audiences are ASCII hostname-like values with an optional
nonzero decimal port; methods are one to sixteen ASCII `A`-`Z` bytes; paths are
ASCII origin-form bytes. These rules reject Unicode whitespace and control
bytes. A signed request may carry at most `1_048_576` UTF-8 body bytes and uses
a sequence in `1...UInt64.max`.

Base64url is unpadded and canonical: encoded lengths with a one-character tail
and encodings with nonzero unused trailing bits are rejected. JSON Schema
cannot measure a string's UTF-8 byte length, so the committed acceptance corpus
is checked by the Go and Swift `ValidateRequestBody` protocol helpers using
UTF-8 bytes; it includes an `é` boundary case.

## Framing

Every transcript is the concatenation of ordered fields. Each field is encoded
as a four-byte unsigned big-endian byte length followed by its bytes. The schema
version is the two-byte unsigned big-endian value `1`, then it is itself
length-prefixed like every other field. UUID fields are their 16 raw RFC4122
bytes; counter fields are eight-byte unsigned big-endian values. Times are the
ASCII bytes of their canonical timestamp. No byte field is converted to text
inside a transcript.

## Endpoint envelope

`EndpointEnvelopeV1` is `{ "kind": "node.endpoint.v1", "ciphertext":
"<base64url>" }`.

`EndpointTranscript` fields:

1. `Plainpost.NodeEndpoint.v1`
2. schema version `1`
3. endpoint ciphertext bytes

## Activation request

`ActivationRequestV2` is `{ "kind": "node.activation.v2", "resultWire":
"<base64url>", "refreshWire": "<base64url>", "leaseWire": "<base64url>",
"trustCommitWire": "<base64url>", "admissionEvidenceWire": "<base64url>",
"claimProofSignature": "<base64url>" }`. A Node accepts this v2 shape only;
the evidence is required to recompute both operation-binding digests.

`ActivationTranscript` fields:

1. `Plainpost.NodeActivation.v2`
2. schema version `2`
3. result wire bytes
4. refresh credential wire bytes
5. offline lease wire bytes
6. trust-commit wire bytes
7. admission-evidence wire bytes
8. claim-proof signature bytes

`ActivationRequestV3` adds the canonical `cleanupCapabilityWire` immediately
before the claim proof. It uses `Plainpost.NodeActivation.v3` and U16BE(3).
V2 remains decodable solely for exact diagnostic replay; it cannot establish a
production-ready installation because it has no Central-issued capability.

## Signed request

`SignedRequestV1` is `{ "kind": "node.signed-request.v1", "accountID":
"<uuid>", "clientID": "<uuid>", "nodeID": "<uuid>", "trustEpoch":
"<positive decimal>", "audience": "<audience>", "sequence": "<positive
decimal>", "method": "<uppercase method>", "path": "<absolute path>",
"bodySHA256": "<base64url 32-byte digest>", "issuedAt": "<timestamp>",
"signature": "<base64url 64-byte signature>" }`.

`RequestTranscript` fields:

1. `Plainpost.NodeRequest.v1`
2. schema version `1`
3. account ID
4. client ID
5. node ID
6. trust epoch
7. audience UTF-8 bytes
8. sequence
9. method UTF-8 bytes
10. path UTF-8 bytes
11. body SHA-256 bytes
12. issued-at timestamp UTF-8 bytes

The envelope `signature` is deliberately outside `RequestTranscript`; it is a
P-256 signature over those preceding transcript bytes and would be circular if
included.

`path` is the exact transcript-bound HTTP origin-form request target. It has an
optional closed query of `key=value` pairs separated by one `&`; keys start with
ASCII letters, values are ASCII letters/digits/underscore/hyphen. Fragments,
percent encoding, empty pairs, and duplicate separators are rejected.

The vector in `fixtures/session-v1.json` pins all three transcript byte strings
and the SHA-256 digest of the request transcript.
