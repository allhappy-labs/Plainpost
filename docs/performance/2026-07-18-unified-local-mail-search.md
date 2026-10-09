# Unified Local Mail Search Performance and Migration Evidence

Measured on 2026-07-19 from the remediation-D unified-search completion
boundary.

## Test environment

- Mac16,12, Apple silicon (`arm64`), 10 logical processors
- 24 GiB physical memory (25,769,803,776 bytes)
- macOS 26.5.2 (25F84)
- Swift release configuration
- 30 measured warm iterations per workload, deterministic synthetic seed
- Peak search-operation RSS sampled every 1 millisecond from immediately
  before the cold search through the warm, paged, plan, and cancellation
  workloads. The sampler records only bounded summary state, caps itself at
  600,000 periodic samples, is cancelled and awaited when the operation ends,
  and fails closed if Darwin RSS sampling fails or the cap expires before the
  operation completes. An explicit readiness handshake guarantees that the
  first periodic sample completes before the operation begins.
- The 10,000-message run is the hard performance gate. The 50,000- and
  100,000-message runs are non-gating scaling evidence.

The reproducible entry points are:

```sh
rtk swift run -c release PlainpostSearchBenchmark --messages 10000 --iterations 30 --enforce-budgets --output-json /tmp/plainpost-search-remediation-d-final/10000.json
rtk Scripts/benchmark-mail-search.sh --synthetic-all --output-directory /tmp/plainpost-search-remediation-d-final
rtk env PLAINPOST_BENCH_SOURCE_DB="$HOME/Library/Application Support/Plainpost/Plainpost.sqlite" Scripts/benchmark-mail-search.sh --production-copy --output-directory /tmp/plainpost-search-remediation-d-final
```

Production-copy mode opens the protected source read-only, uses SQLite online
backup to make a transactionally consistent destination in a wrapper-owned
temporary directory, and performs every preparation, migration, validation,
and search write only against that destination. Exact-path, symlink, hard-link,
and DB/WAL/SHM sidecar aliases are rejected before the source is opened or an
output is created. EXIT/INT/TERM traps remove the temporary directory while
preserving status.

The authoritative format-version-3 artifacts are:

| Artifact | `generatedAt` | SHA-256 |
| --- | --- | --- |
| 10,000 synthetic | 2026-07-19T20:07:35Z | `020475bacd553db1cca94f497025fa21a56ac789e81805454b56bf017855beea` |
| 50,000 synthetic | 2026-07-19T20:07:42Z | `24b8a4a7afc87990c8d8907af008f867f83a3a392918a9711ac0c564e768a37d` |
| 100,000 synthetic | 2026-07-19T20:07:56Z | `dfbd8897d4b52ddc439fd45ef8dcf9c80c7a5ab958fadc3a3ee5c8f17afe6e7a` |
| Disposable production-shaped migration | 2026-07-19T20:08:14Z | `3d8b454288081b4d21cc68a8c6deaceceb04950746076bc9b46f6587dd1dd171` |

Correctness failures always return nonzero. Non-enforced 50,000/100,000 runs
relax performance budgets only.

## Synthetic results

All warm times are milliseconds; each cell is p50 / p95.

| Messages | Structured | Common message | Common conversation | Phrase | Fielded | Rare | Two-page message |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10,000 | 2.647 / 2.910 | 4.268 / 4.482 | 10.491 / 10.939 | 3.854 / 4.558 | 3.045 / 3.248 | 1.109 / 1.219 | 7.005 / 7.273 |
| 50,000 | 15.061 / 15.526 | 18.825 / 20.605 | 64.374 / 67.343 | 16.871 / 18.376 | 26.007 / 27.276 | 7.706 / 8.047 | 35.566 / 37.408 |
| 100,000 | 28.977 / 29.676 | 36.171 / 39.582 | 127.459 / 130.453 | 31.540 / 34.201 | 84.539 / 90.138 | 15.334 / 16.296 | 68.752 / 72.425 |

| Messages | Cold first page | Cancellation | Peak RSS delta | Final retained delta | Database | Search structures |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10,000 | 6.264 ms | 0.067 ms, observed | 9,388,032 B | 9,306,112 B | 15,613,952 B | 7,700,480 B |
| 50,000 | 20.297 ms | 0.065 ms, observed | 14,811,136 B | 14,581,760 B | 77,012,992 B | 38,281,216 B |
| 100,000 | 39.901 ms | 0.062 ms, observed | 20,103,168 B | 19,628,032 B | 155,807,744 B | 76,640,256 B |

The enforced 10,000-message report passed with no violations:

| Budget | Limit | Measured |
| --- | ---: | ---: |
| Structured p95 | 75 ms | 2.910 ms |
| Message p95 | 250 ms | 4.482 ms |
| Conversation p95 | 400 ms | 10.939 ms |
| Cold first page | 1,000 ms | 6.264 ms |
| Cancellation | 100 ms | 0.067 ms |
| Peak search-operation RSS delta | below 25 MiB | 9,388,032 B |
| Search structures | at most 106.9 MB | 7,700,480 B |

The RSS budget now gates the highest sampled resident set during the complete
representative search-operation window relative to its pre-operation baseline.
It no longer mistakes final retained process growth for an operation peak.

## Query-plan evidence

The 100,000-message text plans contain one `MATERIALIZE fts_scores`, one ranked
FTS candidate scan, and an indexed score join. The remaining correlated FTS
lookup is bounded winner-snippet extraction. The structured-only plan uses
`mail_search_documents_inbox` and does not mention the FTS table.

## Disposable production-shaped v21 to v22 to v23 proof

The production source is currently schema v23, not a naturally captured v21
file. The artifact therefore records
`naturallyCapturedV21Source: false` and the exact controlled preparation method:

`transactional-current-backup-to-production-shaped-v21-legacy-reconstruction`

Inside one transaction on the disposable destination only, the harness:

1. validates the current v23 projection and its v22/v23 registrations;
2. creates the real v21 `message_search_metadata` and content-storing
   `message_fts` schema;
3. fills those legacy tables from all real canonical production messages and
   their current sender, recipient, Bcc, filename, identifier, mailbox, label,
   subject, and body projection data;
4. validates legacy metadata/FTS counts and legacy FTS integrity;
5. removes only the destination's current search structures and v22/v23
   registrations, then records destination `user_version = 21`; and
6. runs the real registered store migrator, executing v22 and then v23.

This is an honest production-shaped downgrade/migration proof using current
production rows. It is deliberately not described as a naturally captured v21
production database.

The proof passed every fail-closed boundary:

- Source rows: 9,378 messages, 8,245 threads, two accounts, 19 mailboxes
- Controlled destination before migration: schema 21; 9,378 canonical rows,
  9,378 legacy metadata rows, and 9,378 legacy FTS rows
- Destination after migration: schema 23; v22 executed=true; v23 executed=true
- Projection/FTS after migration: 9,378 / 9,378
- SQLite `integrity_check`: passed; FTS5 integrity validation: passed
- Legacy search tables after migration: absent
- Disposable destination: 567,590,912 bytes
- Search structures: 81,338,368 bytes, below the 106,900,000-byte invariant
- Cold first page: 21.852 ms; cancellation: 0.059 ms and observed
- Peak search-operation RSS delta: 5,521,408 bytes
- Warm p95: structured 4.292 ms, message 23.475 ms, conversation 33.940 ms,
  phrase 7.829 ms, fielded 0.576 ms, rare 8.527 ms, two-page 36.526 ms
- Correctness and performance violation arrays: empty; `passed: true`

The protected source fingerprints were identical before and after:

- SQLite DB: 558,923,776 bytes, unchanged mtime, SHA-256
  `f663663791cf7e6fa1111d46313e6f2bd98c6a0f25592d26f9489e357ea2fb2c`
- WAL: 0 bytes, unchanged mtime, SHA-256
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`

## Cleanup and acceptance boundary

- `SQLiteMailStore.searchMessages` and its independent FTS quoting, ranking,
  deletion, and limit behavior are deleted. Its tests now call
  `SQLiteMailSearchService`; the separate explicit Ask Mail retrieval path is
  retained.
- Legacy search-table creation and removal remain centralized in
  `SQLiteMailSearchSchema` for migration only.
- Source scans find no superseded deterministic production search route and no
  query/history/snippet logging or query-content telemetry.
- Final focused/full suite, release-build, signed simulator, and source-scan
  evidence is recorded in `docs/progress.md` and the ignored remediation report.

These are automated source, unit/integration, performance, and simulator
results. They are not physical iPhone/iPad evidence and do not prove human
VoiceOver speech, rotor order, gesture behavior, biometric prompts, production
networking, or App Store signing/provisioning. Those physical and
assistive-technology acceptance items remain open.
