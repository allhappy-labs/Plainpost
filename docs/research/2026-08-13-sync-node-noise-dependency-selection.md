# Sync Node Task 7 Noise Dependency Selection

Date: 2026-08-13  
Status: **Go approved with controls; Swift production dependency not selected; Task 7 G8 remains blocked**  
Scope: `Noise_XX_25519_ChaChaPoly_SHA256` and
`Noise_IK_25519_ChaChaPoly_SHA256` for the Sync Node transport. This is a
dependency decision record, not an implementation authorization.

## Decision

1. **Go — approve `github.com/flynn/noise` v1.1.0, exactly
   `4d9f71cd4ba1fe81415efac312664ccc4bc79b46`, for a private Task 7 adapter.**
   It implements both required patterns and the required primitives; its test
   corpus contains the exact requested suite names. v1.1.0 is after the
   package's nonce-overflow and unauthenticated-nonce-increment fix (v1.0.0).
   It must be consumed as `github.com/flynn/noise v1.1.0`; Go's module checksum
   database records the immutable module content. The existing root module's
   `golang.org/x/crypto v0.48.0` remains the selected transitive crypto module;
   do not permit the candidate's older direct requirement to lower it.

2. **Swift — do not approve `swift-libp2p/swift-noise` as a production
   dependency yet.** The exact signed tag commit
   `0adfd28786322784860fb3c8f228591c6e8fd92f` (0.1.1) does technically
   implement the two suites, deterministic vector inputs, transcript binding,
   rekeying, and the appropriate X25519/ChaChaPoly/SHA-256 construction. It is
   MIT licensed and has only one direct dependency, Apple `swift-crypto`.
   But its own README calls the code a proof of concept, it has no published
   security policy or audit, no GitHub release, a small maintenance history,
   and exports unsafe session controls. That fails Task 7's independently
   reviewed production-dependency requirement.

3. **Do not bridge a C or Rust implementation merely to bypass the Swift
   decision.** `snow` is a genuine, maintained Rust Noise state machine, but
   its own README says it has no formal audit and its previous nonce issue was
   only patched in 0.9.5. A Rust FFI core therefore adds a language, binary,
   build, ABI, memory, and incident-response owner without satisfying G8 by
   itself. The same is true of the reference-oriented Noise-C project absent a
   separate review and an owned Swift bridge. `libsodium` is **not** a Noise
   implementation: it supplies primitives; its `crypto_kx` construction uses
   BLAKE2b rather than the required SHA-256 Noise symmetric state. A
   hand-written Swift transcript over those primitives is explicitly rejected.

**Result:** do not start Task 7's production transport. The Go choice removes
only the Go-library uncertainty. G8 is green only after Plainpost names an
owner and approves an independently reviewed Swift implementation (native or a
maintained bridge) at an immutable revision.

## Required integration boundary

The approved Go dependency is not permission to expose its low-level API.
The Task 7 adapter must own the `HandshakeState` and the two post-split cipher
states and provide only:

- construction of the fixed suite and either XX or IK pattern;
- exact framing, direction, prologue, handshake-hash/channel-binding, and
  close-on-authentication-failure behavior specified by Task 7;
- ordered encrypt/decrypt and the scheduled one-direction rekey operation.

It must never expose `Cipher`, `UnsafeKey`, `UnsafeNewCipherState`, `SetNonce`,
or arbitrary cipher suites/patterns to callers. It must not persist or resume a
transport cipher state. The selected version correctly fails closed at nonce
exhaustion, but the adapter still treats that as a terminal session failure.

Tests may inject `Config.Random` in Go and fixed static/ephemeral test keys in
Swift. Production must leave Go randomness unset (the library then selects
`crypto/rand.Reader`) and must never accept a production randomness override.
The tests must run the project-owned, immutable **official Noise vector corpus**
for both exact suites, then project-owned Go↔Swift vectors and malformed-frame,
reflection, nonce, rekey, and session-close cases. Library-local vectors alone
are useful evidence, not the cross-language acceptance oracle.

## Candidate matrix

| Candidate | Exact XX + IK / suite | Vector and deterministic hook | Security and maintenance assessment | License / graph | Decision |
| --- | --- | --- | --- | --- | --- |
| `flynn/noise` v1.1.0 | Yes: `HandshakeXX`, `HandshakeIK`, `DH25519`, `CipherChaChaPoly`, and `HashSHA256`. | `Config.Random io.Reader`; repository vector harness includes both exact suite names. | The GitHub advisory records two nonce flaws before v1.0.0 and says v1.0.0 fixed them. v1.1.0 is post-fix. The selected tag commit is from 2024-02-02; Plainpost owns updates and incident response. | 3-clause BSD; direct `x/crypto` requirement is old, but this repository already resolves `x/crypto` to v0.48.0. | **Adopt behind the private adapter.** |
| `swift-libp2p/swift-noise` 0.1.1 | Yes: fundamental `XX` and `IK`, X25519, ChaChaPoly1305 and SHA-256. | Config accepts fixed ephemeral keys; XX/IK tests use fixed keys and assert ciphertexts. | README explicitly calls it a proof of concept. No audit or published security policy was found; the public `HandshakeState` is non-thread-safe and marked `@unchecked Sendable`; it exposes nonce setting and rekeying. | MIT; one direct dependency, `swift-crypto` 4.x (an Apple project under Apache-2.0). | **Reject for production today.** May be an evaluation-only candidate at the exact revision. |
| `snow` v0.9.6 through Rust FFI | Yes: parsed Noise protocol name and builder support the exact suites. | `fixed_ephemeral_key_for_testing_only`; test vector suite. | Maintained, but README says no formal audit. GitHub advisory says its stateful transport nonce issue was patched only in 0.9.5. An FFI wrapper would become security-critical code. | Apache-2.0 OR MIT; substantial Rust crypto graph. | **Do not bridge now.** Reconsider only with a maintained mobile FFI package, security review, and explicit owner. |
| Noise-C through Swift C FFI | Reference implementation describes itself as a C Noise implementation. | No selection evidence establishes the required Swift API/ownership or current vector lane. | No G8-grade review/maintenance/Swift bridge evidence established. | MIT. | **Reject as a shortcut.** |
| `libsodium` primitives | No: not a Noise state machine. | N/A. | A custom transcript/state machine would recreate the high-risk work G8 forbids. | ISC; cryptographic primitives only. | **Reject.** |

## Exact immutable references

### Go candidate

- Version/tag: `v1.1.0` resolves to
  `4d9f71cd4ba1fe81415efac312664ccc4bc79b46` (queried from the official
  repository on 2026-08-13). The tag itself is not signed, so Go's module sum
  verification and Plainpost's dependency-review record are required.
- Pattern and suite implementation:
  [`patterns.go`](https://github.com/flynn/noise/blob/v1.1.0/patterns.go) and
  [`cipher_suite.go`](https://github.com/flynn/noise/blob/v1.1.0/cipher_suite.go).
- Deterministic construction, state safety and dangerous exports:
  [`state.go`](https://github.com/flynn/noise/blob/v1.1.0/state.go).
- Local vector harness and exact required-suite entries:
  [`vector_test.go`](https://github.com/flynn/noise/blob/v1.1.0/vector_test.go)
  and [`vectors.txt`](https://github.com/flynn/noise/blob/v1.1.0/vectors.txt).
- Dependency manifest and BSD license:
  [`go.mod`](https://github.com/flynn/noise/blob/v1.1.0/go.mod) and
  [`LICENSE`](https://github.com/flynn/noise/blob/v1.1.0/LICENSE).
- The official GitHub advisory says versions before v1.0.0 had nonce overflow
  and unauthenticated-failure state desynchronization, both fixed in v1.0.0:
  [GHSA-g9mp-8g3h-3c5c](https://github.com/advisories/GHSA-g9mp-8g3h-3c5c).

### Swift candidate (rejected for production)

- Evaluation-only pin:
  [`0adfd28786322784860fb3c8f228591c6e8fd92f`](https://github.com/swift-libp2p/swift-noise/commit/0adfd28786322784860fb3c8f228591c6e8fd92f)
  (tag `0.1.1`; signed commit). Do not add it to `Package.swift` or
  `Package.resolved` without a later approval.
- Exact patterns, cipher suite construction, state API and nonce behavior:
  [`Noise.swift`](https://github.com/swift-libp2p/swift-noise/blob/0adfd28786322784860fb3c8f228591c6e8fd92f/Sources/Noise/Noise.swift).
- Exact IK and XX KAT suites, plus malformed-message/rekey/nonce tests:
  [`IK.swift`](https://github.com/swift-libp2p/swift-noise/blob/0adfd28786322784860fb3c8f228591c6e8fd92f/Tests/NoiseTests/IK.swift),
  [`XX.swift`](https://github.com/swift-libp2p/swift-noise/blob/0adfd28786322784860fb3c8f228591c6e8fd92f/Tests/NoiseTests/XX.swift), and
  [`NegativeAndTransportTests.swift`](https://github.com/swift-libp2p/swift-noise/blob/0adfd28786322784860fb3c8f228591c6e8fd92f/Tests/NoiseTests/NegativeAndTransportTests.swift).
- Direct dependency and supported platforms:
  [`Package.swift`](https://github.com/swift-libp2p/swift-noise/blob/0adfd28786322784860fb3c8f228591c6e8fd92f/Package.swift).
  Its range is not an immutable consumer pin; if selected later, Plainpost must
  pin the exact revision and commit `Package.resolved`.
- Candidate self-assessment and license:
  [`README.md`](https://github.com/swift-libp2p/swift-noise/blob/0adfd28786322784860fb3c8f228591c6e8fd92f/README.md) and
  [`LICENSE.md`](https://github.com/swift-libp2p/swift-noise/blob/0adfd28786322784860fb3c8f228591c6e8fd92f/LICENSE.md).

### Bridge alternatives (not selected)

- Snow source, features and direct crypto dependency graph:
  [`Cargo.toml` v0.9.6](https://github.com/mcginty/snow/blob/v0.9.6/Cargo.toml),
  [`README.md` v0.9.6](https://github.com/mcginty/snow/blob/v0.9.6/README.md),
  [`builder.rs` v0.9.6](https://github.com/mcginty/snow/blob/v0.9.6/src/builder.rs), and
  [`vectors.rs` v0.9.6](https://github.com/mcginty/snow/blob/v0.9.6/tests/vectors.rs).
  Its prior nonce advisory is
  [GHSA-7g9j-g5jg-3vv3](https://github.com/advisories/GHSA-7g9j-g5jg-3vv3).
- Noise-C describes itself as a reference C implementation:
  [`README.md`](https://github.com/rweather/noise-c/blob/master/README.md).
- Libsodium documents `crypto_kx` as a BLAKE2b-based key derivation API, not a
  Noise protocol implementation:
  [Key exchange](https://doc.libsodium.org/key_exchange).

## Normative protocol basis

The selected suite and ownership rules follow the [Noise Protocol Framework,
revision 34](https://noiseprotocol.org/noise.html): the official XX and IK
token sequences, `CipherState` nonce exhaustion behavior, `Rekey`, handshake
hash channel binding, and the requirement to delete a failed handshake state
are in the specification. The spec is the protocol authority; library APIs do
not change those requirements.

## Work needed to clear G8

An accountable party must make one of these choices before Task 7 transport
implementation begins:

1. **Commission/review `swift-libp2p/swift-noise` 0.1.1** for Plainpost's
   exact suite and usage; fix or explicitly accept its findings; name the
   maintenance and vulnerability-response owner; then adopt only the reviewed
   commit behind a Plainpost actor/private adapter and committed
   `Package.resolved`.
2. **Select a different native Swift Noise implementation** that is already
   independently reviewed and supplies immutable source, maintained releases,
   compatible platform support, a bounded safe session API, and a security
   response owner.
3. **Fund a Rust/C core and Swift bridge review** only if an owned ABI, build
   provenance, memory-lifetime/zeroization policy, upgrade process, and mobile
   packaging owner are accepted. `snow` v0.9.6 alone is not approval.

For every path, add a dependency lock/audit test that rejects branches,
floating semver ranges, changed checksums, raw symmetric-state/key exports,
or an unreviewed dependency revision. Record the named owner and escalation
path in the Task 7 acceptance report.
