# Plainpost Node Backup Container v1

This document defines the one-account, one-node encrypted backup container.
The backup key is an externally mounted, exactly 32-byte AES-256 key. The
format does not derive or persist that key.

## Security properties

- Algorithm: AES-256-GCM with its standard 16-byte tag; no compression.
- Every persisted manifest and payload byte is ciphertext. The only visible
  metadata is the fixed format header and random nonce namespace.
- Each writer samples one random 8-byte nonce namespace. GCM nonces are the
  namespace followed by a big-endian 32-bit counter. Counter zero is unused
  and reserved in v1; chunk counters begin at one, the manifest consumes the
  next counter, and the final record consumes the one after that. A writer
  fails before it could reuse a counter.
- Plaintext payload records are at most 4,194,304 bytes.

## Byte framing

All integer fields are unsigned big-endian unless stated otherwise. A `LP(x)`
field is `u32(len(x)) || x`.

```
header := "PLAINPOST-NODE-BACKUP" || u8(1) || nonceNamespace[8]
record := u8(type) || u32(counter) || u32(ciphertextLength) || ciphertext
container := header || chunkRecord* || manifestRecord || finalRecord
```

`ciphertext` is a GCM ciphertext including its 16-byte tag. Types are `1` for
the manifest, `2` for a payload chunk, and `3` for the final record. The
manifest record follows all chunks; chunks begin at counter one, and manifest
and final consume the following counters. The reader scans and authenticates
the complete encrypted transcript before it returns a Reader. Reordering,
duplication, omission, truncation, or trailing data fails.

The encrypted canonical manifest is:

```
accountUUID[16] || nodeUUID[16] || trustEpoch u64 || trustCommitDigest[32]
|| nodeSchemaVersion u32 || postgreSQLMajor u16 || createdAtUnixSeconds i64
|| entryCount u32
|| (LP(entryName UTF-8) || entrySize u64 || entryMode u32 || entrySHA256[32]) * entryCount
```

Entries are non-empty UTF-8 names with no NUL, at most 1,024 bytes, sort
strictly by name, and have no duplicates. Entry mode is exactly regular-file
permission mode `0600` (no file-type, group/other, or execute bits). Each
entry SHA-256 digest is non-zero. A manifest has at most 4,096 entries.
`createdAt` is UTC at whole-second precision. Account and node identities are
non-zero canonical UUID values; the trust epoch, schema version, and PostgreSQL
major version are non-zero.

## Authenticated data

Let:

```
baseAAD := LP("Plainpost.NodeBackup.AAD.v1") || LP(header)
manifestDigest := SHA-256(canonicalManifestPlaintext)
prefixDigest := SHA-256(header || chunkRecord* || manifestRecord)
```

The manifest record uses `baseAAD`. A chunk with counter `c` uses:

```
baseAAD || u8(2) || u32(c)
```

The final plaintext is `u32(chunkCount) || prefixDigest`. Its AAD is:

```
baseAAD || u8(3) || u32(finalCounter) || manifestDigest
|| u32(chunkCount) || LP(prefixDigest)
```

The digest deliberately covers every byte before the self-authenticating final
record; including a digest field inside the bytes it hashes is impossible
without a fixed-point construction. The final record is separately GCM
authenticated, and its AAD and plaintext both bind the computed digest and
count. Consequently header, manifest, ordered chunks, final count, and the
complete pre-final container byte stream are cryptographically bound.

## Publication and key custody

The writer creates a random, destination-local staging file with
`O_CREATE|O_EXCL` and mode `0600`. It writes ciphertext with partial-write
handling, fsyncs the file and its directory, then publishes with an atomic
native no-replace rename: `renameatx_np(RENAME_EXCL)` on Darwin and
`renameat2(RENAME_NOREPLACE)` on Linux. Unsupported platforms fail closed.
Any post-rename fsync/cleanup error reports publication uncertainty and never
deletes the visible destination.

An uncertain publication is also a durable, account-bound operator
reservation. Its receipt records the container and manifest digests while the
reservation remains blocking; a restart may clear that reservation only after
the recovery operation re-fsyncs the parent directory and authenticates the
same container, or after an exact operator deletion attestation bound to the
account, backup ID, and reservation revision. File authentication by itself
never upgrades an uncertain publication to verified.

The implementation clears owned key, canonical-manifest, plaintext-chunk, and
intermediate ciphertext buffers where Go permits. Go and its runtime/compiler
do not guarantee that all copies, registers, or garbage-collected allocations
are scrubbed; mounted-key custody and process memory protection remain outside
this format module.
