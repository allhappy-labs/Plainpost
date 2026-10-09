# Temporal Removal and Local Workflow Migration

Temporal was removed from Plainpost on 2026-07-10. It required a separate server and a large gRPC/NIO dependency graph that did not fit the product's local, low-footprint design.

Plainpost now uses:

- GRDB 7.11.1 and system SQLite for migrations, local data, FTS5, durable jobs, finite leases, retries, cancellation, and progress;
- `PlainpostBackgroundAgent` for scheduled local synchronization and due-job execution;
- Keychain for IMAP/SMTP credentials;
- `PlainpostOperations` for shared macOS/iOS-safe operation contracts;
- `PlainpostDeviceSync` for optional opaque CloudKit private-database wake signals.

No Temporal server, namespace, task queue, API key, worker, or environment variables are required.

## Local operation diagnostics

```sh
swift run PlainpostService operations status \
  --db-path "$HOME/Library/Application Support/Plainpost/Plainpost.sqlite" \
  --json

swift run PlainpostService operations sync \
  --account acc_me_example_com \
  --db-path "$HOME/Library/Application Support/Plainpost/Plainpost.sqlite" \
  --json
```

Use `--complete-history` on `operations sync` to request complete selected-mailbox history.

## Background agent

```sh
PLAINPOST_DATA_DIR="$HOME/Library/Application Support/Plainpost" \
swift run PlainpostBackgroundAgent
```

The agent polls only on a persisted schedule and sleeps between work. The packaged LaunchAgent starts this executable directly; it no longer starts a stdio service that exits when stdin closes.

## Privacy boundary

All mail, indexes, jobs, generated AI artifacts, and credentials remain local. CloudKit, when configured by a signed macOS/iOS product, contains only a schema version, a random 32-byte wake token, and a timestamp in the user's private database. It contains no account, mailbox, message, sender, subject, body, attachment, credential, or key data.

The full replacement design is in `docs/superpowers/specs/2026-07-10-local-workflows-grdb-cloudkit-design.md`.
