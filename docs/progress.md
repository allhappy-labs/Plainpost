# Plainpost Progress Tracker

The current reliability repair evidence boundary is indexed in
[`docs/verification/2026-09-05-reliability-gates.md`](verification/2026-09-05-reliability-gates.md).
It preserves historical verification dates and SHAs; its documented PASS,
FAIL, SKIP, and UNAVAILABLE outcomes are not replacements for historical
milestones.

## 2026-09-05 Reliability architecture repair boundary

- [x] D5's approved production restore-construction cancellation repair and
  its final CLI normalization fix are implemented, verified, and independently
  reviewed.
  The startup context now reaches
  the production factory, constructor, installation/recovery loads, and lazy
  account saga assembly. A live PostgreSQL proof observed the real constructor
  blocked on the installation singleton row, then proved listener exit returned
  while the blocker transaction remained open. The focused Go gate passed 26
  test events and the original full package passed 189; that tested file set was
  committed source-equivalently as
  `c29e1dd4356a8ea6a41b0504d74b0608b0a29aa4`. After final review found
  that local backup discarded constructor cancellation identity, a focused
  regression covered both cancellation and deadline causes while retaining the
  exact ordinary error vocabulary; the affected full package passed 192 test
  events. All final gates had zero failures and zero skips against isolated
  pinned PostgreSQL 18 fixtures. The earlier nine
  failures were traced to an unavailable `localhost:5435` fixture endpoint and
  all nine passed against the controlled endpoint; no fixture source repair was
  made. The initial final review at `0c9a55d8` reported 0 Critical, 1 Important,
  and 0 Minor findings; the bounded fix was committed as
  `e7e1e519a86375308243fb9999ee8656aedc577c`, and its scoped immutable rereview
  found 0 Critical, 0 Important, and 0 Minor findings with the combined verdict
  **Standards: PASS. Spec: PASS. APPROVE**. No merge, push, deployment, release
  gate, or D6-D8 work was performed. See
  [`docs/verification/2026-09-05-production-restore-cancellation-followup.md`](verification/2026-09-05-production-restore-cancellation-followup.md).

## Account-sync Milestone 1

- [ ] Task 7 central trust/metadata coordination is implemented and awaiting
  independent final review. PostgreSQL now atomically accepts exact
  commit/evidence pairs, consumes pending/recovery authority, suspends recovery
  sessions and leases, persists signed history, freezes complete record
  inventories, and enforces opaque-record high water. Real PostgreSQL tests
  cover all seven failpoints, recovery rollback, exact retries, different A/B
  successor races, freeze-vs-PUT in both lock orders, active-device rechecks,
  legacy migration compatibility, and future-write constraints. Authenticated
  routes require access plus device-key DPoP bound to exact method,
  RequestURI/query, body and token digests, timestamp, nonce, account and
  device; pending principals are limited to self-pending retrieval and trust
  history, while suspended/revoked devices, replay, substitutions, unsafe
  direct DELETE, and Apple `sync_node` enrollment reject. Signed trust pages,
  stable metadata pages, 0/1/4,096 inventory proofs, concrete runtime wiring,
  route-specific body limits, and the generalized Swift GET/POST/PUT client are
  present. Production loads bootstrap and `trust_pagination` private scalars
  from separate purpose-bound mounted artifacts, never loads a recovery
  scalar, and fails route construction/readiness instead of leaving a latent
  ready-but-503 service. Swift now has closed trust-cursor, signed
  trust-state-page, and
  encrypted-record-page codecs; verifies current manifest purpose, lifetime,
  exact request/frozen head/next cursor and page signatures before applying a
  page; and restarts failed cursors from the persisted verified coordinator
  checkpoint. Signed two-page tests prove restart and cancellation retain only
  a valid prefix. The authoritative account-request-proof vector binds method,
  RequestURI/query, body and token digests, timestamp, nonce, account, and
  device; Swift and Go execute every substitution and Go proves replay
  rejection. Go and Swift accept the full 32-entry trust page under one aligned
  16 MiB bound; Swift transport streaming enforces each route's smaller
  response budget, including the exact 2 MiB inventory-proof limit. Trust and
  record selectors reject missing, mixed, partial, duplicate, and unknown
  query fields before service dispatch; every other Task 7 route requires an
  empty raw query after authentication and before dependency dispatch. The
  broad live PostgreSQL central/API gate passes across all 10 Go packages; the
  128-test Swift account aggregate, schema/vector parsing, and diff checks
  pass. Independent final review remains.
- [x] Task 6 account-wide trust implementation is complete:
  the Swift runtime now uses exact peer SAS transcripts, signed atomic trust
  commits, P-256 group packages, purpose-verified recovery, device-only
  matching and metadata keys, and encrypted account records. Round-one review
  fixes added immutable commit-scoped material and authority snapshots behind
  one atomic CAS head, crash/race-safe restore, preflighted authorization-bound
  history, pre-membership and non-genesis recovery bootstrap, persisted
  historical signer authority, safe record resealing with explicit key
  retirement, expired-now historical recovery verification without weakening
  live expiry, and the closed canonical encrypted-record wire codec. Round-two
  review fixes now reconcile every state-sensitive actor operation against the
  persisted head; return a successfully committed state independently of
  retryable cleanup; distinguish same-checkpoint snapshot content; bound
  retained generations and authority history; garbage-collect unreachable
  immutable snapshots/material; allow authenticated empty record inventories;
  and retain pre-membership same-generation authority. Closed persistent
  history entries pair commits with full admission evidence or recovery
  authorization plus its historical offline-root-signed manifest. The shared
  schema, transcript, Task 7 plan, and signed pagination vector all use and bind
  those exact entries. Historical recovery remains verifiable after manifest
  expiry/overlap eviction while live recovery still enforces current expiry.
  Round-three fixes add a hardened per-account `fcntl` operation fence spanning
  reconcile, material use, publication, retirement, and garbage collection;
  its directory/file inode, owner, mode, link count, and symlink properties are
  validated and same-process aliases serialize by directory inode. A bounded
  per-account journal reserves every immutable key before write, cleans exact
  pre-CAS or losing-fork orphans after crash, retains bounded retry state on
  cleanup failure, and removes the need for Keychain enumeration. Metadata
  nonces use an eight-byte metadata-keyed namespace over the exact signed local
  member record plus a CAS-monotonic 32-bit counter; distinct admitted devices
  therefore have disjoint streams, and mismatch or overflow fails closed.
  Explicit retirement now requires a
  short-lived `trust_pagination`-signed complete frozen inventory proof bound to
  the exact trust head, generation, record coordinates, and envelope/signature
  digests; an authenticated zero-count proof is valid. Local record high-water
  rows are bounded by a CAS-protected per-account ID index: the 4,097th distinct
  record, malformed/over-cap state, and unindexed
  rows fail closed, while same-ID revisions reuse one slot and reservation
  crashes remain bounded. The authoritative page vector is a contiguous
  genesis/admission/recovery chain whose exact signed
  evidence bytes and all three entry digests are bound, with executable swap,
  pending-bundle substitution, and historical-manifest substitution mutations.
  Round-four review repairs validate every GC-journal entry against its exact
  owning account and snapshot/material/nonce key grammar before any deletion;
  structurally validate active and retired material references before load or
  cleanup; require locator uniqueness across active and retired references so a
  tombstone cannot alias and delete live material; independently prove that two
  differently coordinated retired references cannot share a fresh locator and
  trigger cleanup of either seeded victim row; bind active references to their
  exact retained authority commit; and
  allow the closed duplicate-key scanner's inventory `entries` field to reach
  its 4,096-item model limit without weakening the default 64-item scanner cap.
  Weak process-lock cache entries no longer grow per account, while reentrancy
  and a ready-signalled child-process `fcntl` barrier are covered. Recovery
  transition and history digests now use the single signed-authorization
  primitive, the deterministic pagination fixture and its signature cascade
  were regenerated, and Account API commit hashing routes through the canonical
  protocol primitive.
  It rejects expiry, substitution, second confirmation, package-only forks,
  rollback/equivocation, old generations after explicit retirement,
  `sync_node` Apple authorizations, cross-authorizations, and over-cap
  membership. The frozen roadmap conflict was resolved intentionally:
  `LogicalMailboxID` is the required opaque 32-byte `Data` HMAC value
  (base64url only at wire boundaries). Peer handshake models remain bound to
  their exact transcript, and their complete public values are serialized only
  inside transition evidence. RED evidence preceded each fix; the expanded
  focused coordinator suite passed 40/40. The broad account protocol/runtime
  aggregate passed 120/120 with isolated SwiftPM caches, the Go central account
  fixture consumer passed 58/58, account schema/shared fixture JSON documents
  passed `jq`, and `git diff --check` passed. Round-three independent review and
  final independent review approved the production slice, which is the clean
  base for Task 7.
- [x] Task 4 Swift account bootstrap runtime: Foundation-only closed account
  wire models rebuild the committed exchange, challenge, finalize, trust-state,
  package, and manifest transcripts. The device runtime uses distinct
  ThisDeviceOnly, non-synchronizable Keychain records for separate P-256
  signing/agreement identities and provisional state. It directly verifies the
  public root-signed manifest, retains a highest `(version,digest)` checkpoint,
  rejects rollback/equivocation, and selects only active, purpose-scoped keys
  within half-open validity windows. The fixed HTTPS client rejects redirects,
  malformed/status/content-type/size failures, response substitution, and
  high-S signatures; genesis builds and binds one encrypted self package while
  pending finalizes with a null commit. Task 3 intentionally supplies only a
  provisional acknowledgement—session/refresh/offline lease issuance remains
  Task 5.
- [x] Task 3 central Apple bootstrap: the Go API now validates bounded Apple
  RS256 identity tokens, derives a non-reversible identity HMAC, and creates a
  one-time signed genesis/pending challenge without storing token/profile data.
  Root-signed manifests and purpose-scoped online signing keys load only from
  mounted files; invalid configuration leaves liveness up but bootstrap
  readiness/routes unavailable. Mounted files are single-open, bounded,
  non-symlink, and permission checked; the current manifest requires all three
  online purposes without permitting root/public-key reuse. Apple bootstrap
  begin shares the fixed PostgreSQL source limiter before token/JWKS work,
  expired challenge nonces are cleaned in bounded batches, and HTTP accepts only
  UTF-8 JSON. Task 1 crypto fixtures directly guard canonical transcripts and
  digests, exhaustively exercise all 13 wrong-role cases, and keep P-256 signing
  and agreement roles nominally distinct. JWKS refresh continues independently
  of canceled waiters without negative-caching transient failures, and every
  mounted scalar is consumed only by its exact verified bootstrap entry.
  Sessions, generic trust history, recovery, and client integration remain
  separately scoped tasks.
- [x] Task 3A cleanup-capability prerequisite was accepted at `3a80eb82`.
  Central 0022 binds each
  cleanup registration to its admitted claim/node and each V2 result to that
  exact registration; V1 bytes and earlier migrations remain frozen. Live
  PostgreSQL 17 lifecycle, atomic-failpoint, replacement, privacy, migration,
  and V3 encrypted restart/master-rotation owners pass under `-race`; shared
  V2 vectors, schema validation, vet, and diff checks pass.
- [ ] Task 4 production restore/deletion readiness has repaired its final
  spec/standards findings and is pending rereview. Node migration 0012 adds a
  minimal authenticated singleton checkpoint; the PostgreSQL journal is
  restart-safe and monotonic, with real PostgreSQL 17 close/reopen proof for
  every phase plus transplant, malformed/auth-corrupt/stale, dependency, and
  count-only privacy/rollback-contamination owners. Those owners directly scan
  raw, base64url, Base64, and hex representation bytes across every bounded
  retained `BYTEA` sink, contaminate each branch in a rollback-only transaction,
  and report category/count-only failures without printing checked values. The
  Central V2 adapter
  treats only exact canonical HTTP 200 `clean` as ready, rejects every redirect
  before a second credential-bearing request, and verifies the final compiled
  Central route. Startup requires encrypted active V3 capability state before
  starting runtime; a real-store/factory/runNode owner proves clean startup and
  legacy state blocks it. `ManagedData.Purge` remains explicitly unavailable,
  so deletion can never be acknowledged before a real durable purge. Disposable
  PostgreSQL 17 focused race/migration, vet, AJV, and diff checks passed; no
  deployment or Unraid work was performed.
- [x] Task 5 + 5A private-session authentication is accepted: Sol's final
  independent two-axis review closed with **0 Standards findings and 0 Spec
  findings**. Central’s narrow
  Node-authenticated current-authority endpoint rechecks current Node/client
  membership, consumes a nonce, freezes a signed trust page, and returns a
  request-bound wrapper from the existing `trust_pagination` signer. The Node
  pins account-bootstrap authority, persists encrypted terminal high-water,
  validates fresh authority before sequence consumption, and fences revocation,
  replacement, recovery, and outage paths. Fresh focused race, disposable
  PostgreSQL 17 (including encrypted-state rotation/failpoints), vet, AJV, and
  protocol-diff evidence is closed by that final review. The closure work
  adds post-activation authority authentication, continuation-CAS restart,
  canonical wrapper decoding, a bounded `Fence.Authorize` churn owner, and
  encrypted current-authority state in rotation-crash restart coverage. Privacy
  evidence is limited to real Node/Central signing scalars and the protected
  request body; access/refresh credentials, offline leases, setup codes, Apple
  tokens, and group-key plaintext are not endpoint inputs and are not claimed.
  See `docs/verification/sync-node-task-5-sessionauth.md`. No deployment or
  Unraid work was performed.

  - Repair checkpoint: Node successor acceptance now reuses Central's canonical
    transition validator before persisting high-water; it rejects invalid
    removal history, uses the frozen request digest, requires current authority
    at construction, validates response expiry after I/O, and rejects
    non-canonical wrappers. Mounted public authority material is reloaded for
    each exchange. This is not Task 5 acceptance: live replacement/recovery,
    full CAS/manifest rotation, privacy, and disposable PostgreSQL evidence are
    still required. A later live owner now closes the recovery/new-epoch
    enrollment gap: canonical signed recovery fences the old Node and only the
    separate accepted fresh-node admission restores Node authority in the new
    epoch.

  - Task 5A transition-matrix checkpoint: a separate deterministic protocol
    fixture pins the canonical admission/recovery entry digests while retaining
    frozen account-v1 wires. The focused Node matrix drives valid admission,
    suspension, revocation, and recovery successors through the shared
    transition policy and `Fence.applyPage`; its `MemoryStore` revocation
    assertion proves only the persistence-interface CAS, while named live
    owner `TestLiveCurrentAuthorityStateIsEncryptedCASRestartSafeAndRotationSafe`
    separately proves encrypted PostgreSQL persistence. Its semantic negatives are independently re-signed,
    including recovery authorization/manifest material, and its reorder owner
    reverses two distinct valid commits. The current-authority churn owner
    begins from a current `After` snapshot, keeps the signed cursor snapshot
    frozen as eight distinct outer heads advance, and proves only verified
    bounded high-water with false readiness; rotation crash
    recovery verifies the authority row is rewrapped under the successor key
    and restarts without predecessor material.

Last updated: 2026-08-16 CEST

## Goal

Implement a local-first macOS email client named `Plainpost` with SwiftUI, CLI, MCP, IMAP/SMTP, local AI, approval-gated sending, SQLite cache, Keychain-backed credentials, audited agent actions, and a Spark-like Smart Inbox UX implemented with current/latest macOS design guidance and macOS 27-era UI elements where available.

## Current Status

> **2026-07-14 API boundary:** Public `plainpost ai ...` commands, `email.ai.*`
> MCP tools, and `email://ai-summary/*` resources were intentionally removed
> before release. AI remains application-owned through the macOS UI, Local API,
> durable operation queue, and `PlainpostBackgroundAgent`; external agents use
> ordinary mail-read and draft APIs, then reason in their own runtime.

- [x] Requirements file read.
- [x] Repository inspected.
- [x] Superpowers workflow loaded.
- [x] Stage 0 design baseline written.
- [x] Stage 0 implementation plan written.
- [x] Foundation scaffold implemented.
- [x] E2E mock IMAP/SMTP harness implemented.
- [x] MVP acceptance criteria verified.

## Superpowers Gates

| Gate | Status | Evidence |
| --- | --- | --- |
| Brainstorming | Stage 0 complete by assumptions | Used requirements' recommended decisions as baseline. |
| Design document | Stages 0-108 complete | Stage specs exist under `docs/superpowers/specs/`. |
| Implementation plan | Stages 0-108 complete | Stage plans exist under `docs/superpowers/plans/`. |
| TDD | Stages 0-106 complete; Stage 107 audit-only | Red runs observed before implementing missing APIs for Stage 0, harness slices, sync/cache, UI state, draft lifecycle/MIME, approval-gated SMTP, CLI JSON commands, local AI service, local AI search index, MCP tool registry, iOS-ready package support, SQLite cache, Keychain credentials, MCP acceptance naming, CLI AI acceptance commands, mailbox message actions, account add persistence, MCP stdio dispatch, UI account setup integration, UI approval queue integration, composer draft/request-send integration, audit log visibility, local labels/recategorization, pending approval notifications, command center, thread AI assistant panel, AI index status/rebuild, draft update/delete surfaces, CLI account sync, AI rewrite-draft surfaces, MCP AI draft reply, MCP mark-seen, CLI AI spec forms, MCP resources, send risk scoring hardening, body-read permission enforcement, agent mutation permission enforcement, message-mutation permission enforcement, AI permission enforcement, store-backed send status/cancel, Smart Inbox batch CLI actions, Smart Inbox batch IMAP service behavior, Smart Inbox pinned-card UI state, thread safe-HTML/blocked-image rendering state, high-risk approval authentication gating, SQLite draft/send-request/audit persistence, CLI SQLite send queue routing, MCP SQLite send queue routing, default local data directory routing, local Sent-copy recording after approval, attachment-read permission enforcement, Spark-like macOS inbox chrome, account setup default data directory routing, remote Sent IMAP append after approved SMTP, non-fatal remote Sent append failure warnings, PlainpostService process health, PlainpostService IMAP sync to SQLite, PlainpostService approval-gated SMTP, PlainpostService-owned account setup plus Keychain-backed sync, PlainpostService approval using stored SMTP credentials, PlainpostService remote Sent append using stored IMAP credentials, plainpost service-bridge account sync, plainpost service-bridge account setup, PlainpostService send-request creation, plainpost service-bridge send-request creation, MCP service-bridge send-request creation, service-bridge send status/cancel, service-mode Application Support default storage, account login username persistence, configurable Sent mailbox settings, persistent PlainpostService stdio service loop, MCP persistent service bridge reuse, live MCP stdio streaming, MCP service bridge startup/timeout failure handling, local Ollama-compatible AI provider support, AI provider status/settings visibility, persisted Settings provider selection, selected AI provider command execution, service-owned AI summary execution, MCP service-backed AI summary execution, service-owned AI draft reply execution, MCP service-backed AI draft reply execution, service-owned AI draft rewrite execution, MCP service-backed AI draft rewrite execution, service-owned AI classification execution, MCP service-backed AI classification execution, service-owned AI semantic search execution, AI index pause/resume CLI control, CLI server draft sync, service-owned draft sync, MCP service draft sync, remote draft metadata persistence, service-backed Smart Inbox batch actions, MCP service-backed Smart Inbox batch actions, service-backed mail seen-state actions, MCP service-backed mail seen-state actions, service-backed mail archive/delete actions, MCP service-backed mail archive/delete actions, UI mailbox row actions, production app runtime wiring, stored-credential GUI mailbox actions, stored-credential GUI approval SMTP, LaunchAgent helper packaging, cleartext transport guarding, implicit TLS SMTP transport, STARTTLS SMTP transport, implicit TLS IMAP transport, STARTTLS IMAP transport, and TLS 1.2+ floor enforcement. |
| Stage E2E verification | Stages 0-107 complete | `rtk swift test` passed 227 tests and `rtk swift build -c release` passed at 2026-07-09 08:36; Stage 107 reused those final gates for acceptance audit. |
| Completion verification | Complete | Stage 107 acceptance audit maps every MVP acceptance item to implemented stage evidence; final `rtk swift test` and release build passed at 2026-07-09 08:36; final diff check passed at 2026-07-09 08:37. |

## Implementation Stages

| Stage | Scope | Status | Verification Target |
| --- | --- | --- | --- |
| 0 | Swift package scaffold, domain models, repository protocols, audit log, fixtures, AI provider protocol, security policies, Bcc-safe draft rendering | Complete | `rtk swift test` passed 18 tests; `rtk swift run plainpost send request --help` documented local approval-only sending. GRDB and Keychain remain later-stage work. |
| 1 | Local realistic IMAP/SMTP harness | Complete | `rtk swift test --filter IMAPHarnessTests` passed 3 TCP E2E tests; `rtk swift test --filter SMTPHarnessTests` passed 2 TCP E2E tests; full `rtk swift test` passed 23 tests. Sync/cache remains a later slice. |
| 2 | IMAP sync into local cache | Complete | `rtk swift test --filter IMAPSyncCacheTests` passed against `LocalIMAPServer`; full `rtk swift test` passed 24 tests. |
| 3 | Classic and Smart Inbox UI shell | Complete | `rtk swift test --filter InboxViewModelTests` passed 4 UI state smoke tests; `rtk swift build --product PlainpostApp` passed. |
| 4 | Drafts, MIME rendering, Bcc safety | Complete | `rtk swift test --filter DraftLifecycleTests` passed; `rtk swift test --filter DraftAndSendPolicyTests` passed 6 MIME/send-policy tests; full `rtk swift test` passed 30 tests. |
| 5 | Approval-gated SMTP | Complete | `rtk swift test --filter ApprovalSMTPFlowTests` passed 4 local SMTP E2E tests: approve/send, deny, hash mismatch, and recipient rejection; full `rtk swift test` passed 34 tests. |
| 6 | `plainpost` CLI | Complete | `rtk swift test --filter CLISurfaceTests` passed 7 process-level CLI JSON tests; `rtk swift test --filter PlainpostCLIHarnessTests` passed local IMAP/SMTP CLI E2E; full `rtk swift test` passed 40 tests. |
| 7 | Local AI MVP | Complete | `rtk swift test --filter AIServiceTests` passed 5 local AI workflow tests; `rtk swift test --filter AIProviderTests` passed; full `rtk swift test` passed 45 tests. |
| 8 | AI index and semantic search | Complete | `rtk swift test --filter AISearchIndexTests` passed deterministic embedding and ranking tests; `rtk swift test --filter CLISurfaceTests/testAISearchReturnsRankedLocalMessageJSON` passed process-level CLI search. |
| 9 | MCP server | Complete | `rtk swift test --filter MCPToolRegistryTests` passed safe-tool registry tests; `rtk swift test --filter CLISurfaceTests/testMCPSchemaListsSafeToolsOnly` passed process-level schema export. |
| 10 | iOS-ready core compilation | Complete | Shared portability tests passed; `PlainpostCore`, `PlainpostAI`, and `PlainpostDB` built for `arm64-apple-ios17.0-simulator`. |
| 11 | SQLite cache and Keychain credentials | Complete | `SQLiteMailStoreTests` passed durable cache reload; `KeychainCredentialStoreTests` passed save/read/overwrite/delete against local Keychain. |
| 12 | MCP acceptance hardening | Complete | MCP tools now use required `email.*` names and send-related descriptions include the required direct-send warning phrase. |
| 13 | CLI AI acceptance commands | Complete | `plainpost ai summarize-thread`, `ai draft-reply`, and `ai classify` return local JSON without sending. |
| 14 | Mailbox message actions | Complete | IMAP TCP harness validates mark read/unread, archive via copy+delete+expunge, and delete via `\Deleted`+`EXPUNGE`; CLI action commands return safe JSON. |
| 15 | Account add persistence | Complete | Account setup verifies local IMAP/SMTP, stores account metadata in SQLite, stores IMAP/SMTP credentials in Keychain, and exposes process-level `plainpost account add`. |
| 16 | MCP stdio dispatcher | Complete | `plainpost mcp serve` handles newline JSON-RPC `tools/list` and safe `tools/call` over stdio, returns structured content, and rejects forbidden direct-send tools. |
| 17 | UI account setup integration | Complete | SwiftUI account setup view model submits through `AccountSetupService`; UI test validates real local IMAP/SMTP account setup with SQLite and Keychain. |
| 18 | UI approval queue integration | Complete | SwiftUI approval queue view model lists pending agent send requests, approves through local SMTP, and denies without SMTP. |
| 19 | Composer draft and request send UI | Complete | SwiftUI composer view model saves local drafts, creates pending send requests, and verifies composer-created requests can be approved through local SMTP. |
| 20 | Audit log visibility | Complete | SwiftUI audit log view model shows actor/action/target/result rows after composer-created send approval through local SMTP. |
| 21 | Local labels and recategorization | Complete | IMAP-synced messages can be locally labeled, unlabeled, and recategorized with audit entries; CLI and MCP expose safe JSON mutation surfaces without direct send. |
| 22 | Pending approval notifications | Complete | Composer-created send requests schedule a local approval notification payload and still require approval through the local SMTP harness before delivery. |
| 23 | Command center | Complete | SwiftUI app shell exposes a compact `Cmd+K` command center with the MVP command list, filtering, and local execution state. |
| 24 | Thread AI assistant panel | Complete | SwiftUI thread detail includes a local AI assistant panel with summary, action items, provider/model metadata, context IDs, and review warning. |
| 25 | AI index status and rebuild | Complete | Local AI index status/rebuild service, process-level `plainpost ai index status/rebuild`, and AI Index Status sidebar warning are verified. |
| 26 | Draft update and delete surfaces | Complete | Process-level CLI draft update/delete and MCP stdio draft create/update/delete work locally without send side effects. |
| 27 | CLI account sync | Complete | `plainpost account sync` uses the local TCP IMAP harness through `IMAPSyncService` and returns cached mailbox/message metadata without secrets. |
| 28 | AI draft rewrite surfaces | Complete | `plainpost ai rewrite-draft` and MCP `email.ai.rewrite_draft` return local-only non-mutating draft revisions and preserve direct-send rejection. |
| 29 | MCP AI draft reply | Complete | MCP `email.ai.draft_reply` creates a local AI-generated, review-required draft and still rejects direct send in the same stdio session. |
| 30 | MCP mark seen | Complete | MCP `email.mark_seen` updates local cached seen state; focused MCP/SQLite/UI tests, full suite, and release build passed after cleaning stale SwiftPM artifacts. |
| 31 | CLI AI spec forms | Complete | Process-level CLI tests verify documented positional `ai semantic-search`, `ai summarize-thread`, `ai draft-reply`, and `ai classify` forms while existing flag forms remain supported. |
| 32 | MCP resources | Complete | MCP stdio `resources/list` and `resources/read` expose safe local message, thread, Smart Inbox, AI summary, draft, and send-request resource views without send/approval side effects. |
| 33 | Send risk scoring hardening | Complete | `SendRequestPolicy` now emits deterministic approval risk flags for attachments and suspicious links in addition to existing agent, AI, Bcc, empty-subject, and many-recipient flags; full suite and release build passed. |
| 34 | Agent body-read permission enforcement | Complete | CLI `mail read --include body`, MCP `email.read`, and MCP `email://message/{id}` resource reads now deny body access when `PLAINPOST_AGENT_READ_BODY=false`; focused permission and process tests, full suite, and release build passed. |
| 35 | Agent draft and send-request permission enforcement | Complete | CLI and MCP draft creation/send-request surfaces now deny mutation when `PLAINPOST_AGENT_CREATE_DRAFTS=false` or `PLAINPOST_AGENT_REQUEST_SEND=false`; focused process tests, full suite, and release build passed. |
| 36 | Agent message-mutation permission enforcement | Complete | Store, CLI, and MCP label/category/seen-state mutations now deny restricted agents via `PLAINPOST_AGENT_ADD_LABELS=false`, `PLAINPOST_AGENT_RECATEGORIZE=false`, and `PLAINPOST_AGENT_MARK_SEEN=false`; focused process tests, full suite, and release build passed. |
| 37 | Agent AI permission enforcement | Complete | Core AI service/search, CLI AI commands, and MCP AI tools now deny restricted agents via `PLAINPOST_AGENT_USE_AI_SUMMARY=false`, `PLAINPOST_AGENT_USE_AI_DRAFT_REPLY=false`, `PLAINPOST_AGENT_USE_AI_SEMANTIC_SEARCH=false`, and `PLAINPOST_AGENT_USE_AI_CLASSIFICATION=false`; focused process tests, full suite, and release build passed. |
| 38 | Store-backed send status and cancel | Complete | CLI `send status/cancel` and MCP `email.send_status`/`email.cancel_send_request` now use local send-request state, return not-found for unknown IDs, and audit cancellation; focused process tests, full suite, and release build passed. |
| 39 | Smart Inbox batch CLI actions | Complete | CLI `smart-inbox batch newsletters --action archive-read --json` marks unread newsletter batch items seen through existing permission enforcement, reports them as archived to `Archive`, validates unsupported category/action inputs, and emits deterministic JSON; focused process tests, full suite, and release build passed. |
| 40 | Smart Inbox batch IMAP service | Complete | Core `SmartInboxBatchService` validates actor permission before IMAP mutation, archives matching newsletter messages through `LocalIMAPServer`, marks the local cache seen, and preserves CLI batch output; focused service/CLI tests, full suite, and release build passed. |
| 41 | Smart Inbox Pinned card | Complete | SwiftUI view-model state now includes a Pinned card between Newsletters and Seen, separates `Pinned`-labeled messages out of category/Seen cards, and exposes row-level pin state for rendering; focused UI tests, full suite, and release build passed. |
| 42 | Thread safe HTML and blocked remote images | Complete | Core `EmailBodyRenderer` strips script/style/img tags, counts blocked HTTP(S) remote images, and feeds sanitized thread message state into SwiftUI thread detail rendering; focused core/UI tests, full suite, and release build passed. |
| 43 | High-risk approval authentication gate | Complete | Approval queue items now flag requests with `riskScore >= 45` as requiring local authentication, authenticate before SMTP, block delivery when auth is denied, and preserve the lower-risk local SMTP approval path; focused UI/local SMTP tests, full suite, and release build passed. |
| 44 | SQLite draft and send queue persistence | Complete | `SQLiteMailStore` now persists drafts, send requests, approval status transitions, cancellations, and audit entries across database reopen, and can back the approval queue protocol; focused SQLite/approval tests, full suite, release build, and diff check passed. |
| 45 | CLI SQLite send queue path | Complete | `plainpost draft create`, `send request`, `send status`, and `send cancel` now use a caller-supplied `--db-path` SQLite store for cross-process durable send queue state while preserving the seeded in-memory default path; process CLI tests, full suite, release build, and diff check passed. |
| 46 | MCP SQLite send queue path | Complete | `plainpost mcp serve --db-path` now routes `email.create_draft`, `email.request_send`, `email.send_status`, and `email.cancel_send_request` through SQLite so send queue state persists across MCP stdio sessions; focused MCP tests, full suite, release build, and diff check passed. |
| 47 | Default local data directory | Complete | CLI and MCP durable send queue flows now resolve `PLAINPOST_DATA_DIR/Plainpost.sqlite` when `--db-path` is absent, creating the directory automatically while preserving fixture fallback without a durable location; focused process tests, full suite, release build, and diff check passed. |
| 48 | Local Sent copy after approval | Complete | Successful approval-gated SMTP delivery now records a local Sent mailbox/message copy with a stable message ID, Sent label, seen state, and `message.sent_copy` audit event in both in-memory and SQLite stores; local SMTP E2E, SQLite persistence, full suite, release build, and diff check passed. |
| 49 | Attachment-read permission enforcement | Complete | `AgentPermissions.readAttachments`, `MessageReadPolicy.validateAttachmentRead`, and CLI/MCP `include=attachments` checks now deny restricted agents via `PLAINPOST_AGENT_READ_ATTACHMENTS=false` without returning attachment payloads, body text, or secrets; focused core/process tests, full suite, release build, and diff check passed. |
| 50 | Spark-like macOS inbox chrome | Complete | The SwiftUI shell now exposes testable Spark-like inbox chrome with native toolbar search, Smart/Classic mode state, icon-based sync/compose/approval/command actions, restored `Cmd+K`, and richer Smart Inbox card metadata while staying macOS 15 compile-safe for future system styling; focused UI tests, app build, full suite, release build, and diff check passed. |
| 51 | Account add default data directory | Complete | `plainpost account add` now reuses configured SQLite store resolution so `PLAINPOST_DATA_DIR/Plainpost.sqlite` works when `--db-path` is absent, while explicit `--db-path` still works; local IMAP/SMTP process tests, full suite, release build, and diff check passed. |
| 52 | Remote Sent IMAP append | Complete | `PlaintextIMAPClient` and `LocalIMAPServer` now support literal `APPEND`, and GUI-approved SMTP delivery can append the rendered message to remote IMAP `Sent` while preserving local Sent copy/status behavior; local IMAP/SMTP E2E tests, full suite, release build, and diff check passed. |
| 53 | Non-fatal remote Sent append failure | Complete | Approved SMTP delivery now remains `sent` if the post-delivery remote IMAP Sent append fails, records local Sent copy, and audits `send.remote_sent_append_failed` without leaking secrets; focused local SMTP/IMAP tests, SQLite warning persistence, full suite, release build, and diff check passed. |
| 54 | PlainpostService health entrypoint | Complete | Added a `PlainpostService` executable with secret-safe `--health --json` output for SQLite, Keychain, IMAP sync, SMTP approval queue, MCP bridge, audit log, and local AI readiness; RED process test, focused service build/run, full suite, release build, and diff check passed. |
| 55 | PlainpostService IMAP sync to SQLite | Complete | `PlainpostService sync inbox` now connects to the local TCP IMAP harness, syncs inbox metadata through `IMAPSyncService`, persists mailbox/message cache into SQLite, and returns secret-safe JSON; RED E2E, focused GREEN, service build, full suite, release build, and diff check passed. |
| 56 | PlainpostService approval-gated SMTP | Complete | `PlainpostService approval approve` now loads a pending SQLite send request, approves it as a local GUI user, sends through the local TCP SMTP harness via `ApprovalSMTPService`, records local Sent copy/audit state, and returns secret-safe JSON; RED E2E, focused GREEN, service build, full suite, release build, and diff check passed. |
| 57 | PlainpostService account setup and Keychain sync | Complete | `PlainpostService account add` verifies local IMAP/SMTP, stores account metadata in SQLite and credentials in Keychain, and `PlainpostService sync inbox` can sync using SQLite account metadata plus Keychain IMAP credentials without a password argument; service-owned E2E, explicit sync/CLI regression tests, full suite, release build, and diff check passed. |
| 58 | PlainpostService stored SMTP approval | Complete | `PlainpostService approval approve` can now load the pending request's draft/account from SQLite, read `<account-id>:smtp` from Keychain, and deliver through the account SMTP host without SMTP password arguments; service-owned account/setup approval E2E, explicit approval regression, service build, full suite, release build, and diff check passed. |
| 59 | PlainpostService remote Sent append | Complete | Stored-account `PlainpostService approval approve` now reads `<account-id>:imap` from Keychain, appends the rendered outgoing message to remote IMAP `Sent` with `\Seen`, and still records local Sent copy/status; service-owned IMAP/SMTP E2E, stored/explicit approval regressions, service build, full suite, release build, and diff check passed. |
| 60 | plainpost service sync bridge | Complete | `plainpost account sync <account> --use-service --db-path ... --keychain-service ... --json` now invokes the sibling `PlainpostService`, syncs through stored SQLite account metadata and Keychain IMAP credentials, persists the cache, and preserves the direct CLI sync regression; service-bridge E2E, product builds, full suite, release build, and diff check passed. |
| 61 | plainpost service account add bridge | Complete | `plainpost account add --use-service ... --db-path ... --keychain-service ... --json` now invokes the sibling `PlainpostService`, verifies local IMAP/SMTP, persists SQLite account metadata and Keychain credentials through the service, and proves stored credential usability through service-backed sync; service account-add E2E, direct account-add and service-sync regressions, product builds, full suite, release build, and diff check passed. |
| 62 | PlainpostService send request creation | Complete | `PlainpostService send request` now creates a deterministic local draft and pending send request in SQLite without SMTP side effects, returning secret-safe service JSON for later approval; service send-request E2E, stored approval regression, service build, full suite, release build, and diff check passed. |
| 63 | plainpost service send request bridge | Complete | `plainpost send request --use-service ... --db-path ... --json` now invokes `PlainpostService send request`, persists the service-owned draft/send request in SQLite, and preserves the direct `--draft` send queue path; service-bridge send-request E2E, direct SQLite send queue regression, service primitive regression, product builds, full suite, release build, and diff check passed. |
| 64 | MCP service send request bridge | Complete | `plainpost mcp serve --use-service --db-path ...` now routes full-field `email.request_send` calls through `PlainpostService send request`, persists the service-owned draft/send request in SQLite, preserves direct MCP `draft_id` send queue behavior, and performs no SMTP delivery; service-bridge MCP E2E, direct MCP SQLite regression, CLI service bridge regression, product builds, full suite, release build, and diff check passed. |
| 65 | Service send status/cancel bridge | Complete | `PlainpostService send status/cancel`, `plainpost send status/cancel --use-service`, and MCP `email.send_status`/`email.cancel_send_request` under `plainpost mcp serve --use-service` now read and cancel service-owned SQLite send requests without SMTP side effects while preserving direct CLI/MCP SQLite queue behavior; service primitive E2E, CLI/MCP bridge E2Es, direct queue regressions, product builds, full suite, release build, and diff check passed. |
| 66 | Service-mode Application Support store | Complete | Service-mode `plainpost` bridges now synthesize a default SQLite path when `--db-path` is absent, preferring `PLAINPOST_DATA_DIR`, then test-safe `PLAINPOST_APPLICATION_SUPPORT_DIR`, then `$HOME/Library/Application Support/Plainpost/Plainpost.sqlite`, while preserving direct fixture-backed no-DB flows; local IMAP/SMTP E2E, existing default data-dir and service bridge regressions, product builds, full suite, release build, and diff check passed. |
| 67 | Persist account login username | Complete | Account setup now persists the submitted login username separately from email, SQLite migrates and reloads `accounts.username`, and service-mode stored IMAP sync, SMTP approval, and remote Sent append use that username while preserving old request initializer calls and legacy account JSON decoding; distinct-login IMAP/SMTP E2E, compatibility regressions, stored credential regressions, product builds, full suite, release build, and diff check passed. |
| 68 | Configurable Sent mailbox path | Complete | Account setup now persists a defaulted account Sent mailbox, SQLite migrates/reloads `accounts.sent_mailbox`, direct and service account-add paths accept optional `--sent-mailbox`, service approval appends remote Sent copies to the configured mailbox, local Sent-copy recording uses the configured path, and IMAP APPEND safely quotes mailbox names with spaces while rejecting control-character injection; local IMAP/SMTP E2E, migration/security regressions, product builds, full suite, release build, and diff check passed. |
| 69 | Persistent PlainpostService stdio loop | Complete | `PlainpostService serve --stdio --json` now stays alive for newline-delimited JSON request envelopes, dispatches existing service commands through the shared service dispatcher, returns structurally encoded per-request JSON envelopes with embedded service responses, rejects invalid request payloads without exiting, and persists state across multiple requests in one process; focused process E2E, NDJSON parsing assertions, service JSON control-character regressions, full suite, release build, and diff check passed. |
| 70 | MCP persistent service bridge reuse | Complete | `plainpost mcp serve --use-service` now streams MCP stdio responses while stdin remains open, opens one persistent `PlainpostService serve --stdio --json` subprocess for the MCP session, reuses it for service-backed `email.request_send`, `email.send_status`, and `email.cancel_send_request`, reports bridge startup failures without one-shot fallback, and converts hung service responses into MCP tool errors; wrapper-backed process E2E, live stdio regression, startup/timeout failure regressions, existing MCP service bridge regressions, service-loop regressions, full suite, release build, and diff check passed. |
| 71 | Local Ollama AI provider | Complete | `PlainpostAI` now includes an `OllamaProvider` behind the existing `AIProvider` protocol, with loopback-only configuration, chat and embedding model IDs, `/api/generate` generation, `/api/embeddings` vectors, and local JSON classification parsing; local TCP Ollama-compatible HTTP provider tests, non-loopback rejection regression, full suite, release build, and diff check passed. |
| 72 | AI provider status and Settings visibility | Complete | `plainpost ai provider status` now returns secret-safe local provider status for deterministic, disabled, and loopback-only Ollama providers, probes local Ollama `/api/tags` through the shared TCP harness, rejects remote AI endpoints, and `PlainpostUI` exposes a compact Settings provider status model/panel with local-only labels and model summaries; CLI process E2E, UI model tests, app build, full suite, release build, and diff check passed. |
| 73 | Persisted AI provider selection | Complete | Settings provider rows are selectable, known local provider choices persist through a UserDefaults-backed store, invalid provider IDs are ignored, and the app default uses the persistent Settings model; red/focused UI model tests, app build, full suite, release build, and diff check passed. |
| 74 | Selected provider command execution | Complete | `plainpost` AI execution paths now resolve deterministic, disabled, or loopback-only Ollama providers from local environment configuration, default to deterministic offline behavior, and prove selected Ollama execution by running `ai summarize-thread` through `LocalOllamaServer` `/api/generate`; focused CLI/provider E2E, full suite, release build, and diff check passed. |
| 75 | Service-owned AI thread summary | Complete | `PlainpostService ai summarize-thread` now runs local AI summaries through the service process using the selected local provider, `plainpost ai summarize-thread --use-service` bridges to it, and `SQLiteMailStore` conforms to `LocalAIStore` for DB-backed service summaries while seeded fallback preserves process E2E tests; service-bridge Ollama E2E, focused AI/service tests, full suite, release build, and diff check passed. |
| 76 | MCP service-backed AI thread summary | Complete | `plainpost mcp serve --use-service` now routes `email.ai.summarize_thread` through the persistent `PlainpostService` bridge when present, preserving direct MCP behavior otherwise and proving selected Ollama execution through MCP JSON-RPC plus service stdio; MCP service-bridge Ollama E2E, focused MCP service tests, full suite, release build, and diff check passed. |
| 77 | Service-owned AI draft reply | Complete | `PlainpostService ai draft-reply` now creates review-required local AI drafts through the service process using the selected local provider, `plainpost ai draft-reply --use-service` bridges to it, and service JSON exposes body/review/approval invariants without direct send capability; service-bridge Ollama E2E, focused AI/service tests, full suite, release build, and diff check passed. |
| 78 | MCP service-backed AI draft reply | Complete | `plainpost mcp serve --use-service` now routes `email.ai.draft_reply` through the persistent `PlainpostService` bridge when present, preserving direct MCP behavior otherwise and proving selected Ollama execution plus review-required service JSON through MCP stdio; MCP service-bridge Ollama E2E, focused service tests, full suite, release build, and diff check passed. |
| 79 | Service-owned AI draft rewrite | Complete | `PlainpostService ai rewrite-draft` now returns non-mutating local AI rewrite revisions through the service process using the selected local provider, `plainpost ai rewrite-draft --use-service` bridges to it, and service JSON exposes model/local-only/sent invariants; service-bridge Ollama E2E, focused AI/service tests, full suite, release build, and diff check passed. |
| 80 | MCP service-backed AI draft rewrite | Complete | `plainpost mcp serve --use-service` now routes `email.ai.rewrite_draft` through the persistent `PlainpostService` bridge when present, preserving direct MCP behavior otherwise and proving selected Ollama execution plus non-mutating service rewrite JSON through MCP stdio; MCP service-bridge Ollama E2E, focused service tests, full suite, release build, and diff check passed. |
| 81 | Service-owned AI classification | Complete | `PlainpostService ai classify` now returns local message classification through the service process using the selected local provider, `plainpost ai classify --use-service` bridges to it, and service JSON exposes category/confidence/reason/local-only metadata without secrets; service-bridge Ollama E2E, focused AI/service tests, full suite, release build, and diff check passed. |
| 82 | MCP service-backed AI classification | Complete | `plainpost mcp serve --use-service` now routes `email.ai.classify` through the persistent `PlainpostService` bridge when present, preserving direct MCP behavior otherwise and proving selected Ollama execution plus service-shaped classification JSON through MCP stdio; MCP service-bridge Ollama E2E, focused service tests, full suite, release build, and diff check passed. |
| 83 | Service-owned AI semantic search | Complete | `PlainpostService ai semantic-search` now builds a transient local search index and runs local embeddings through the selected provider, `plainpost ai semantic-search --use-service` bridges to it, and service JSON exposes query/hit/model/local-only metadata without secrets; service-bridge Ollama embedding E2E, focused AI/service tests, full suite, release build, and diff check passed. |
| 84 | MCP service-backed AI semantic search | Complete | `plainpost mcp serve --use-service` now routes `email.ai.semantic_search` through the persistent `PlainpostService` bridge when present, preserving direct MCP behavior otherwise and proving selected Ollama embedding execution plus service-shaped search JSON through MCP stdio; MCP service-bridge Ollama embedding E2E, focused service tests, full suite, release build, and diff check passed. |
| 85 | AI index pause/resume CLI | Complete | `plainpost ai index pause/resume --json` now return secret-safe local index control state, restricted agents are denied via the existing semantic-search/index permission, command discovery lists the documented subcommands, and the SwiftUI index status model maps paused state as needing attention; focused CLI/UI tests, full suite, release build, and diff check passed. |
| 86 | CLI server draft sync | Complete | `plainpost draft sync <draft-id> --to-server --json` now loads a local SQLite or seeded draft, renders MIME-safe headers/body, appends it to the remote IMAP Drafts mailbox with `\Draft` via the local IMAP `APPEND` path, and returns secret-safe sync metadata; local IMAP server-draft E2E, focused draft/IMAP regressions, full suite, release build, and diff check passed. |
| 87 | Service-owned draft sync | Complete | `plainpost draft sync <draft-id> --to-server --use-service --json` now delegates to `PlainpostService`, which loads the SQLite draft, resolves its stored account, reads the account IMAP password from Keychain, appends the rendered draft to remote IMAP Drafts with `\Draft`, and returns secret-safe service metadata; the stage also preserves caller-supplied `--account` and `--from` on CLI-created drafts so service-owned draft operations resolve the correct account. |
| 88 | MCP service draft sync | Complete | MCP now exposes safe `email.sync_draft` for service-backed server Drafts sync, routes it through the persistent `PlainpostService` bridge, and preserves optional `account`/`from` metadata on MCP-created durable drafts so a full MCP create-then-sync flow appends to remote IMAP Drafts through stored Keychain credentials without exposing secrets or sending mail. |
| 89 | Remote draft metadata persistence | Complete | IMAP APPEND now returns UIDPLUS APPENDUID metadata, the local IMAP harness assigns deterministic append UIDs, direct/service/MCP draft sync JSON exposes server draft mailbox/UID, and SQLite/in-memory drafts persist server draft metadata with a `draft.server_sync` audit event; focused IMAP/service/direct/MCP tests, full suite, release build, and diff check passed. |
| 90 | Service-backed Smart Inbox batch actions | Complete | `SQLiteMailStore` now persists message label/category/seen mutations with audit entries, and `plainpost smart-inbox batch ... --use-service` routes through `PlainpostService`, stored SQLite account/message state, Keychain IMAP credentials, and the local IMAP archive flow while preserving direct CLI behavior; focused SQLite/service/direct/core tests, full suite, release build, and diff check passed. |
| 91 | MCP service-backed Smart Inbox batch actions | Complete | MCP now exposes safe `email.smart_inbox_batch`, routes it through the persistent `PlainpostService` bridge in `plainpost mcp serve --use-service`, archives matching Smart Inbox messages through stored Keychain IMAP credentials, and persists the local seen state without exposing secrets or enabling direct send; registry/schema checks, MCP/CLI service E2Es, full suite, release build, and diff check passed. |
| 92 | Service-backed mail seen-state actions | Complete | `plainpost mail mark-read/mark-unread ... --use-service` now routes through `PlainpostService`, stored SQLite account/message state, Keychain IMAP credentials, and the local IMAP `\Seen` flag path while persisting SQLite `isSeen`; focused local IMAP/SQLite E2E, direct CLI regression, Smart Inbox service regression, full suite, release build, and diff check passed. |
| 93 | MCP service-backed mail seen-state actions | Complete | MCP `email.mark_seen` now routes account-backed service-mode calls through `PlainpostService mail mark-read/mark-unread`, stored SQLite state, Keychain IMAP credentials, and the local IMAP `\Seen` path while preserving direct MCP fixture behavior; focused MCP service E2E, direct MCP regression, CLI service regression, full suite, release build, and diff check passed. |
| 94 | Service-backed mail archive/delete actions | Complete | `MessageSummary` and SQLite now persist mailbox/deleted metadata, and `plainpost mail archive/delete ... --use-service` routes through `PlainpostService`, stored SQLite account/message state, Keychain IMAP credentials, and the local IMAP archive/delete paths while preserving direct CLI and mark-read/unread behavior; SQLite migration regression, local IMAP archive/delete E2Es, full suite, release build, and diff check passed. |
| 95 | MCP service-backed mail archive/delete actions | Complete | MCP now exposes safe `email.archive` and `email.delete`, routes account-backed service-mode calls through `PlainpostService mail archive/delete`, stored SQLite state, Keychain IMAP credentials, and the local IMAP archive/delete paths while preserving direct MCP fixture behavior; focused MCP registry/direct/service E2Es, full suite, release build, and diff check passed. |
| 96 | UI mailbox row actions | Complete | SwiftUI inbox rows now expose icon-backed mark read/unread, archive, and delete actions through `InboxMailActionViewModel`; the UI action service mutates local IMAP and local metadata, and focused UI/local IMAP tests, app build, full suite, release build, and diff check passed. |
| 97 | Production app runtime wiring | Complete | `PlainpostAppRuntime` now opens and migrates the Application Support SQLite store, composes Keychain-backed account setup plus shared store-backed composer, approval queue, audit, inbox, and mailbox action view models, and `PlainpostApplication` boots through that runtime with a visible fallback; focused runtime local IMAP/SMTP/SQLite/Keychain tests, app build, full suite, release build, and diff check passed. |
| 98 | Stored-credential GUI mailbox actions | Complete | Runtime inbox row actions now resolve the stored SQLite account plus Keychain IMAP password, mutate the configured local IMAP server, and persist SQLite metadata without storing secrets; focused runtime IMAP/SMTP/SQLite/Keychain tests, UI tests, app build, full suite, release build, and diff check passed. |
| 99 | Stored-credential GUI approval SMTP | Complete | Runtime approval queue now resolves the draft's SQLite account plus Keychain SMTP/IMAP passwords, sends approved drafts through the configured local SMTP server, appends remote IMAP Sent copies, records local Sent copies in the configured Sent mailbox path, and keeps secrets out of SQLite; focused runtime IMAP/SMTP/SQLite/Keychain tests, UI tests, app build, full suite, release build, and diff check passed. |
| 100 | LaunchAgent helper packaging | Complete | `PlainpostLaunchAgentPlist` generates a parseable secret-safe user LaunchAgent plist for `PlainpostService serve --stdio --json`, and `plainpost service launch-agent install/status --json` writes and reads it without loading launchd; focused core/process tests, full core tests, full CLI integration harness, full suite, release build, and diff check passed. |
| 101 | Cleartext transport guard | Complete | `MailTransportSecurityPolicy` allows the existing plaintext IMAP/SMTP clients only for loopback harness hosts and rejects remote cleartext before opening sockets; focused security tests, loopback IMAP/SMTP account E2E, full core tests, full suite, release build, and diff check passed. |
| 102 | Implicit TLS SMTP transport | Complete | `SecureSMTPClient` now sends through implicit TLS with certificate validation enabled by default, rejects self-signed servers unless an explicit local-test override is used, and production SMTP factory wiring routes remote port 465 through TLS while keeping loopback harnesses on plaintext; focused TLS/factory/loopback E2Es, full core tests, full suite, release build, and diff check passed. |
| 103 | STARTTLS SMTP transport | Complete | `StartTLSSMTPClient` now upgrades port 587 SMTP sessions with STARTTLS before authentication or message submission, preserves default certificate validation with an explicit local-test override, and production SMTP factory wiring routes remote port 587 through STARTTLS; focused STARTTLS/factory/TLS/loopback E2Es, full core tests, full suite, release build, and diff check passed. |
| 104 | Implicit TLS IMAP transport | Complete | `SecureIMAPClient` now shares the IMAP command implementation with the plaintext harness client, connects to port 993 through implicit TLS with default certificate validation, rejects self-signed servers unless an explicit local-test override is used, and production IMAP factory wiring routes remote port 993 through TLS while keeping loopback harnesses on plaintext; focused TLS IMAP/factory/loopback E2Es, full core tests, full suite, release build, and diff check passed. |
| 105 | STARTTLS IMAP transport | Complete | `StartTLSIMAPClient` now upgrades port 143 IMAP sessions with STARTTLS before login or mailbox commands, preserves default certificate validation with an explicit local-test override, and production IMAP factory wiring routes remote port 143 through STARTTLS while keeping loopback harnesses on plaintext; focused STARTTLS IMAP/factory/loopback E2Es, full core tests, full suite, release build, and diff check passed. |
| 106 | TLS 1.2+ floor enforcement | Complete | Shared CFStream TLS settings now pin `kCFStreamSSLLevel` to `kCFStreamSocketSecurityLevelTLSv1_2` for implicit TLS and STARTTLS SMTP/IMAP, and a local TLS 1.0/1.1-only SMTP harness is rejected before delivery even with the explicit local-test certificate override; focused TLS/core tests, full suite, release build, and diff check passed. |
| 107 | MVP acceptance audit | Complete | Original acceptance criteria are mapped below to implemented stages and final verification; no remaining mocked-server MVP blocker is known after `rtk swift test`, release build, and diff check passed. |
| 108 | Apple Swift Temporal SDK integration | Superseded | The implementation was verified, then deliberately removed because it required a separate server and a heavyweight dependency/runtime footprint that did not fit Plainpost's local-native product requirements. |
| 109 | GRDB local workflows, historical sync, and private device wake | Partial | Temporal and its dependency tree are removed. GRDB 7.11.1 now owns compatible migrations, WAL storage, durable leased jobs, sync preferences/checkpoints/progress, UID-safe message identity, and FTS5. Recent-100 and resumable complete-history sync, selected mailbox settings, a persistent background agent, local operation adapters, opaque CloudKit private wake contracts, and macOS/iOS shared-target builds are implemented. Production IMAP IDLE/QRESYNC, signed helper installation, CloudKit container/entitlements, authenticated Bonjour/Tailscale application transport, and a real iOS app/physical-device notification test remain explicit platform work. |
| 110 | Inbox performance and background recovery | Verification in progress | Live diagnosis found 100% launch CPU, about 2.0 GiB peak footprint, about 1.7 GiB settled RSS, 1.124 GiB of `Swift.StringStorage`, and expired Smart Inbox work against an 8,342-message/7,769-thread/454 MiB store. The production launch now uses a body-free SQLite projection on an actor, publishes 200 rows at a time, fetches complete bodies only for one selected conversation, uses constant-size inbox equality, scopes mailbox/account/operation invalidation, coalesces incremental Smart Inbox requests, and recovers expired leases at worker startup. Automated focused verification is complete; signed-app live measurements remain pending below. |

## MVP Acceptance Audit

| Acceptance Criterion | Status | Evidence |
| --- | --- | --- |
| User can add one IMAP/SMTP account. | Complete | Stages 15, 17, 51, 57, 61, and 97 verify account setup through local IMAP/SMTP harnesses, SQLite account metadata, Keychain credentials, service bridge, and runtime wiring. |
| Credentials are stored in Keychain. | Complete | Stages 11, 15, 57-59, 87-99 verify Keychain-backed IMAP/SMTP credential storage and stored-credential service/UI operations without plaintext SQLite secrets. |
| App lists folders and messages. | Complete | Stages 2, 3, 27, 55, 60, and 97 verify IMAP sync, cached mailbox/message state, CLI/service sync, and runtime inbox wiring. |
| App has Classic Inbox and Smart Inbox. | Complete | Stages 3, 23, 41, and 50 verify Classic/Smart mode, command center, Pinned card, and Spark-like inbox chrome. |
| Smart Inbox groups Personal, Notifications, Newsletters and Seen. | Complete | Stages 3, 21, 40, 41, 50, 90, and 91 verify local categorization, Smart Inbox cards, Seen state, and batch actions. |
| User can read threads. | Complete | Stages 3, 24, 42, and 97 verify thread UI state, AI assistant panel, safe HTML/body rendering, and runtime app composition. |
| User can archive, delete, mark read and mark unread. | Complete | Stages 14, 40, 90-96, and 98 verify local IMAP mailbox actions, durable service-backed CLI/MCP actions, and GUI row actions with stored credentials. |
| User can create drafts. | Complete | Stages 4, 19, 26, 45-48, 86-89, and 97 verify draft lifecycle, UI composer, CLI/MCP draft mutation, durable SQLite state, and server Drafts sync. |
| Local AI can summarize a thread. | Complete | Stages 7, 13, 24, 71-76 verify local/deterministic and Ollama-compatible summaries through UI, CLI, service, and MCP surfaces. |
| Local AI can draft a reply as a draft. | Complete | Stages 7, 13, 24, 29, 77, and 78 verify local AI draft replies are review-required drafts and cannot send directly. |
| Local AI can classify messages into Smart Inbox categories. | Complete | Stages 7, 21, 37, 81, and 82 verify local classification, category mutation, permissions, service execution, and MCP routing. |
| CLI can search, read, create drafts, run AI summary, request send. | Complete | Stages 6, 13, 26-32, 34-38, 45, 63, 74, 75, and 77 verify process-level `plainpost` JSON surfaces and restricted-agent behavior. |
| MCP exposes safe tools with the same behavior. | Complete | Stages 9, 12, 16, 29-32, 46, 64, 70, 76, 78, 80, 82, 84, 88, 91, 93, and 95 verify MCP tools/resources, safe send-request wording, service bridge reuse, and forbidden direct-send rejection. |
| Agent cannot send email directly. | Complete | Stages 0, 5, 9, 12, 16, 18, 29, 35, 46, 64, and 70 verify no direct send/approval CLI or MCP path exists and send-related tools only create pending requests. |
| Agent can only create pending send request. | Complete | Stages 5, 18, 19, 35, 38, 45, 46, 62-65, and 70 verify pending send-request creation, status/cancel, and service-backed queue persistence. |
| GUI approval is required before SMTP send. | Complete | Stages 5, 18, 43, 56, 58, 99, and 100 verify GUI/local-user approval, high-risk authentication, service approval, stored SMTP credentials, and LaunchAgent packaging. |
| SMTP send validates approved draft hash. | Complete | Stages 4, 5, 43, 56, 58, and 99 verify hash mismatch blocks delivery before SMTP. |
| All sensitive actions are audited. | Complete | Stages 0, 20, 21, 38, 44, 48, 53, 90, 94, and 99 verify audit log persistence and UI visibility for agent, send, Sent-copy, warning, and mailbox mutation actions. |
| No passwords or tokens appear in logs or JSON output. | Complete | Stages 5, 11, 15, 34-37, 49, 54, 57-59, 71-72, 87-99, and 100 verify Keychain storage, secret-safe JSON, no plaintext SQLite secrets, and local-only provider configuration. |
| Remote AI is disabled by default. | Complete | Stages 7, 37, 71-74, and 85 verify disabled/deterministic defaults, loopback-only Ollama configuration, remote endpoint rejection, and local-only AI command execution. |

## E2E Harness Plan

Use a close-to-real local mail server setup for verification:

- IMAP server with real protocol login, mailbox listing, UID search/fetch/store/copy/append behavior, plus implicit TLS and STARTTLS harnesses with generated self-signed certificates.
- SMTP server with AUTH-capable loopback test path, recipient rejection cases, captured sent messages, implicit TLS plus STARTTLS harnesses with generated self-signed certificates, and TLS 1.0/1.1-only rejection validation.
- Seeded fixture accounts, mailboxes, flags, bodies, and threads.
- Black-box tests that exercise `plainpost` and service APIs rather than only unit-level mocks.

## Verification Log

- 2026-07-08 22:06: `rtk swift test` passed 18 tests with 0 failures.
- 2026-07-08 22:06: `rtk swift test --filter DraftAndSendPolicyTests/testRendererRejectsHeaderInjectionInSubject` passed after switching CR/LF detection to Unicode scalar checks.
- 2026-07-08 22:06: `rtk swift run plainpost send request --help` printed an approval-only send request help surface and no direct-send command.
- 2026-07-08 22:12: `rtk swift test --filter IMAPHarnessTests` passed 3 local TCP IMAP E2E tests.
- 2026-07-08 22:12: `rtk swift test --filter SMTPHarnessTests` passed 2 local TCP SMTP E2E tests.
- 2026-07-08 22:12: `rtk swift test` passed 23 tests with 0 failures.
- 2026-07-08 22:14: `rtk swift test --filter IMAPSyncCacheTests` passed local TCP IMAP sync/cache E2E.
- 2026-07-08 22:14: `rtk swift test` passed 24 tests with 0 failures.
- 2026-07-08 22:18: `rtk swift test --filter InboxViewModelTests` passed 4 UI state smoke tests.
- 2026-07-08 22:18: `rtk swift build --product PlainpostApp` passed.
- 2026-07-08 22:18: `rtk swift test` passed 28 tests with 0 failures.
- 2026-07-08 22:21: `rtk swift test --filter DraftLifecycleTests` passed local draft create/update/delete workflow.
- 2026-07-08 22:21: `rtk swift test --filter DraftAndSendPolicyTests` passed 6 draft/MIME/send-policy tests.
- 2026-07-08 22:21: `rtk swift build --product PlainpostApp` passed.
- 2026-07-08 22:21: `rtk swift test` passed 30 tests with 0 failures.
- 2026-07-08 22:23: `rtk swift test --filter ApprovalSMTPFlowTests` passed 4 approval-gated SMTP E2E tests against `LocalSMTPServer`.
- 2026-07-08 22:23: `rtk swift build --product PlainpostApp` passed.
- 2026-07-08 22:23: `rtk swift test` passed 34 tests with 0 failures.
- 2026-07-08 22:27: `rtk swift test --filter CLISurfaceTests` passed 7 process-level CLI JSON contract tests.
- 2026-07-08 22:27: `rtk swift test --filter PlainpostCLIHarnessTests` passed CLI E2E against local TCP IMAP/SMTP harnesses.
- 2026-07-08 22:27: `rtk swift build --product PlainpostApp` passed.
- 2026-07-08 22:27: `rtk swift test` passed 40 tests with 0 failures.
- 2026-07-08 22:31: `rtk swift test --filter AIServiceTests` passed 5 local AI workflow tests.
- 2026-07-08 22:31: `rtk swift test --filter AIProviderTests` passed disabled-provider safety baseline.
- 2026-07-08 22:31: `rtk swift test` passed 45 tests with 0 failures.
- 2026-07-08 22:31: `rtk swift build --product PlainpostApp` passed.
- 2026-07-08 22:33: `rtk swift test --filter AISearchIndexTests` passed deterministic embedding and local semantic-search ranking tests.
- 2026-07-08 22:33: `rtk swift test --filter CLISurfaceTests/testAISearchReturnsRankedLocalMessageJSON` passed process-level `plainpost ai search` JSON validation.
- 2026-07-08 22:33: `rtk swift test` passed 48 tests with 0 failures.
- 2026-07-08 22:33: `rtk swift build --product PlainpostApp` passed.
- 2026-07-08 22:35: `rtk swift test --filter MCPToolRegistryTests` passed 3 MCP safe-tool registry tests.
- 2026-07-08 22:35: `rtk swift run plainpost mcp serve --schema --json` returned safe MCP schema with no direct send or approval tool.
- 2026-07-08 22:35: `rtk swift test --filter CLISurfaceTests/testMCPSchemaListsSafeToolsOnly` passed process-level MCP schema validation.
- 2026-07-08 22:36: `rtk swift test` passed 52 tests with 0 failures after fixing deterministic search ranking noise.
- 2026-07-08 22:36: `rtk swift build --product PlainpostApp` passed.
- 2026-07-08 22:37: `rtk swift test --filter SharedCorePortabilityTests` passed package iOS-platform and shared import-boundary tests.
- 2026-07-08 22:37: `rtk swift build --target PlainpostCore --triple arm64-apple-ios17.0-simulator --sdk $(xcrun --sdk iphonesimulator --show-sdk-path)` passed.
- 2026-07-08 22:37: `rtk swift build --target PlainpostAI --triple arm64-apple-ios17.0-simulator --sdk $(xcrun --sdk iphonesimulator --show-sdk-path)` passed.
- 2026-07-08 22:37: `rtk swift build --target PlainpostDB --triple arm64-apple-ios17.0-simulator --sdk $(xcrun --sdk iphonesimulator --show-sdk-path)` passed.
- 2026-07-08 22:37: `rtk swift test` passed 54 tests with 0 failures.
- 2026-07-08 22:37: `rtk swift build --product PlainpostApp` passed.
- 2026-07-08 22:40: `rtk swift test --filter SQLiteMailStoreTests` passed durable SQLite cache migration and reload.
- 2026-07-08 22:40: `rtk swift test --filter KeychainCredentialStoreTests` passed save/read/overwrite/delete against local Keychain.
- 2026-07-08 22:41: `rtk swift build --target PlainpostSecrets --triple arm64-apple-ios17.0-simulator --sdk $(xcrun --sdk iphonesimulator --show-sdk-path)` passed.
- 2026-07-08 22:41: `rtk swift test` passed 56 tests with 0 failures.
- 2026-07-08 22:41: `rtk swift build --product PlainpostApp` passed.
- 2026-07-08 22:42: `rtk swift test --filter MCPToolRegistryTests` passed 4 MCP acceptance naming and send-warning tests.
- 2026-07-08 22:42: `rtk swift test --filter CLISurfaceTests/testMCPSchemaListsSafeToolsOnly` passed process-level MCP schema validation with required `email.*` tool names.
- 2026-07-08 22:43: `rtk swift test` passed 57 tests with 0 failures.
- 2026-07-08 22:43: `rtk swift build --product PlainpostApp` passed.
- 2026-07-08 22:44: `rtk swift test --filter CLISurfaceTests/testAICommandsReturnLocalJSONWithoutSending` passed process-level AI summarize/draft/classify CLI validation.
- 2026-07-08 22:44: `rtk swift test` passed 58 tests with 0 failures.
- 2026-07-08 22:45: `rtk swift build --product PlainpostApp` passed.
- 2026-07-08 22:51: `rtk swift test --filter IMAPHarnessTests/testMarkReadAndUnreadMutateSeenFlagOnServer` passed local TCP IMAP read/unread mutation.
- 2026-07-08 22:51: `rtk swift test --filter IMAPHarnessTests/testArchiveCopiesToArchiveAndExpungesInboxMessage` passed local TCP IMAP archive copy/delete/expunge flow.
- 2026-07-08 22:51: `rtk swift test --filter IMAPHarnessTests/testDeleteMarksDeletedAndExpungesMessage` passed local TCP IMAP delete/expunge flow.
- 2026-07-08 22:51: `rtk swift test --filter CLISurfaceTests/testMailActionCommandsReturnJSONWithoutSecrets` passed process-level mail action JSON validation.
- 2026-07-08 22:51: `rtk swift test` passed 62 tests with 0 failures.
- 2026-07-08 22:51: `rtk swift build --product PlainpostApp` passed.
- 2026-07-08 23:00: `rtk swift test --filter AccountSetupFlowTests` passed account add E2E against local IMAP/SMTP with SQLite reload and Keychain readback.
- 2026-07-08 23:00: `rtk swift test --filter PlainpostCLIHarnessTests/testAccountAddPersistsSQLiteAndKeychainViaLocalHarnesses` passed process-level `plainpost account add` against local IMAP/SMTP with SQLite plaintext-secret checks.
- 2026-07-08 23:00: `rtk swift test` passed 64 tests with 0 failures.
- 2026-07-08 23:00: `rtk swift build --product PlainpostApp` passed.
- 2026-07-08 23:00: `rtk swift build --target PlainpostAccounts --triple arm64-apple-ios17.0-simulator --sdk $(xcrun --sdk iphonesimulator --show-sdk-path)` passed.
- 2026-07-08 23:04: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioListsAndCallsSafeTools` passed process-level MCP stdio JSON-RPC tools/list, email.search, email.ai.semantic_search, and forbidden direct-send rejection.
- 2026-07-08 23:04: `rtk swift test` passed 65 tests with 0 failures.
- 2026-07-08 23:04: `rtk swift build --product PlainpostApp` passed.
- 2026-07-08 23:09: `rtk swift test --filter AccountSetupViewModelTests` passed 2 UI account setup tests, including local TCP IMAP/SMTP harness submission, SQLite reload, and Keychain readback.
- 2026-07-08 23:09: `rtk swift test --filter PlainpostUITests` passed 6 UI tests with 0 failures.
- 2026-07-08 23:09: `rtk swift build --product PlainpostApp` passed.
- 2026-07-08 23:10: `rtk swift test` passed 67 tests with 0 failures.
- 2026-07-08 23:10: `rtk swift build --product PlainpostApp` passed.
- 2026-07-08 23:14: `rtk swift test --filter ApprovalQueueViewModelTests` passed 3 UI approval queue tests, including local TCP SMTP approval/send and deny/no-send.
- 2026-07-08 23:14: `rtk swift test --filter PlainpostUITests` passed 9 UI tests with 0 failures.
- 2026-07-08 23:14: `rtk swift build --product PlainpostApp` passed.
- 2026-07-08 23:14: `rtk swift test` passed 70 tests with 0 failures.
- 2026-07-08 23:18: `rtk swift test --filter ComposerViewModelTests` passed 4 UI composer tests, including composer-created approval through local TCP SMTP and Bcc header exclusion.
- 2026-07-08 23:18: `rtk swift test --filter PlainpostUITests` passed 13 UI tests with 0 failures.
- 2026-07-08 23:18: `rtk swift build --product PlainpostApp` passed.
- 2026-07-08 23:19: `rtk swift test` passed 74 tests with 0 failures.
- 2026-07-08 23:22: `rtk swift test --filter AuditLogViewModelTests` passed 2 audit UI tests, including composer-created approval through local TCP SMTP before audit refresh.
- 2026-07-08 23:22: `rtk swift test --filter PlainpostUITests` passed 15 UI tests with 0 failures.
- 2026-07-08 23:22: `rtk swift build --product PlainpostApp` passed.
- 2026-07-08 23:22: `rtk swift test` passed 76 tests with 0 failures.
- 2026-07-08 23:27: `rtk swift test --filter LabelCategoryFlowTests` passed IMAP-synced local label/recategorization/audit E2E.
- 2026-07-08 23:27: `rtk swift test --filter CLISurfaceTests/testLabelAndRecategorizeCommandsReturnJSONWithoutSecrets` passed process-level CLI label and recategorize JSON validation.
- 2026-07-08 23:27: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioListsAndCallsSafeTools` passed MCP stdio label, recategorize, remove-label, and forbidden direct-send validation.
- 2026-07-08 23:30: `rtk swift test --filter AISearchIndexTests/testSemanticSearchRanksIndexedLocalMessages` passed after recompiling a stale test artifact that had produced one transient signal 11 during full-suite verification.
- 2026-07-08 23:31: `rtk swift test` passed 78 tests with 0 failures.
- 2026-07-08 23:31: `rtk swift build -c release --product PlainpostApp` passed.
- 2026-07-08 23:34: `rtk swift test --filter ComposerViewModelTests` passed 4 UI composer tests, including pending approval notification scheduling and local TCP SMTP approval delivery.
- 2026-07-08 23:35: `rtk swift test --filter PlainpostUITests` passed 15 UI tests with 0 failures.
- 2026-07-08 23:35: `rtk swift test` passed 78 tests with 0 failures.
- 2026-07-08 23:35: `rtk swift build -c release --product PlainpostApp` passed.
- 2026-07-08 23:37: `rtk swift test --filter CommandCenterViewModelTests` passed 3 command center UI state tests.
- 2026-07-08 23:37: `rtk swift test --filter PlainpostUITests` passed 18 UI tests with 0 failures.
- 2026-07-08 23:37: `rtk swift test` passed 81 tests with 0 failures.
- 2026-07-08 23:38: `rtk swift build -c release --product PlainpostApp` passed.
- 2026-07-08 23:40: `rtk swift test --filter ThreadAIAssistantViewModelTests` passed local AI assistant summary/provider/context UI-state validation.
- 2026-07-08 23:40: `rtk swift test --filter PlainpostUITests` passed 19 UI tests with 0 failures.
- 2026-07-08 23:40: `rtk swift test` passed 82 tests with 0 failures.
- 2026-07-08 23:41: `rtk swift build -c release --product PlainpostApp` passed.
- 2026-07-08 23:44: `rtk swift test --filter AIIndexStatusTests` passed local AI index stale/ready rebuild state validation.
- 2026-07-08 23:45: `rtk swift test --filter CLISurfaceTests/testAIIndexStatusAndRebuildReturnLocalJSONWithoutSecrets` passed process-level `plainpost ai index status/rebuild` validation.
- 2026-07-08 23:45: `rtk swift test --filter AIIndexStatusViewModelTests` passed AI Index Status sidebar warning validation.
- 2026-07-08 23:45: `rtk swift test` passed 85 tests with 0 failures.
- 2026-07-08 23:45: `rtk swift build -c release --product PlainpostApp` passed.
- 2026-07-08 23:47: `rtk swift test --filter CLISurfaceTests/testDraftUpdateAndDeleteCommandsReturnJSONWithoutSending` passed process-level CLI draft update/delete validation.
- 2026-07-08 23:47: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioListsAndCallsSafeTools` passed MCP stdio draft create/update/delete plus forbidden direct-send validation.
- 2026-07-08 23:48: `rtk swift test` passed 86 tests with 0 failures.
- 2026-07-08 23:48: `rtk swift build -c release --product PlainpostApp` passed.
- 2026-07-08 23:49: `rtk swift test --filter PlainpostCLIHarnessTests/testAccountSyncUsesLocalIMAPHarnessAndReturnsCachedMetadata` passed process-level account sync against `LocalIMAPServer`.
- 2026-07-08 23:49: `rtk swift test` passed 87 tests with 0 failures.
- 2026-07-08 23:50: `rtk swift build -c release --product PlainpostApp` passed.
- 2026-07-08 23:52: `rtk swift test --filter CLISurfaceTests/testAIRewriteDraftReturnsLocalRevisionWithoutMutatingOrSending` failed red before implementation on missing rewrite JSON fields.
- 2026-07-08 23:52: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioListsAndCallsSafeTools` failed red before implementation on missing MCP rewrite response fields.
- 2026-07-08 23:54: `rtk swift test --filter CLISurfaceTests/testAIRewriteDraftReturnsLocalRevisionWithoutMutatingOrSending` passed process-level `plainpost ai rewrite-draft` validation.
- 2026-07-08 23:54: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioListsAndCallsSafeTools` passed MCP stdio create/update/rewrite/delete plus forbidden direct-send validation.
- 2026-07-08 23:54: `rtk swift test` passed 88 tests with 0 failures.
- 2026-07-08 23:54: `rtk swift build -c release --product PlainpostApp` passed.
- 2026-07-08 23:55: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioAIDraftReplyCreatesReviewRequiredLocalDraft` failed red before implementation on missing MCP AI draft reply fields.
- 2026-07-08 23:56: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioAIDraftReplyCreatesReviewRequiredLocalDraft` passed MCP stdio `email.ai.draft_reply` review-required local draft validation.
- 2026-07-08 23:56: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioListsAndCallsSafeTools` passed broader MCP stdio safety flow.
- 2026-07-08 23:56: `rtk swift test` passed 89 tests with 0 failures.
- 2026-07-08 23:56: `rtk swift build -c release --product PlainpostApp` passed.
- 2026-07-08 23:57: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioListsAndCallsSafeTools` failed red before implementation on missing MCP `email.mark_seen` response.
- 2026-07-08 23:58: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioListsAndCallsSafeTools` passed MCP mark-seen plus broader stdio safety flow.
- 2026-07-08 23:58: `rtk swift test --filter SQLiteMailStoreTests` passed after adding `is_seen` cache persistence.
- 2026-07-08 23:58: `rtk swift test --filter InboxViewModelTests` passed after deriving unread state from cached seen state.
- 2026-07-08 23:59: `rtk swift test --filter SQLiteMailStoreTests/testMigratesCachesAndReloadsMailMetadata` passed explicit seen-state reload validation.
- 2026-07-08 23:59: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioListsAndCallsSafeTools` passed focused Stage 30 MCP validation.
- 2026-07-08 23:59: `rtk swift build -c release --product PlainpostApp` passed.
- 2026-07-08 23:59: full `rtk swift test` crashed with signal 11 in `AISearchIndexTests/testSemanticSearchRanksIndexedLocalMessages`; the single test reproduced the crash before any fix attempt.
- 2026-07-09 00:00: LLDB diagnostic run hung, and after interrupting related sessions the terminal runner stopped returning for trivial commands, blocking fresh full-suite verification.
- 2026-07-09 00:19: `rtk swift test --filter AISearchIndexTests/testSemanticSearchRanksIndexedLocalMessages` reproduced signal 11; crash report showed `EXC_BAD_ACCESS` while evaluating `results.hits[0].snippet.contains("Tuesday")`, consistent with a stale artifact after the `MessageSummary` layout change.
- 2026-07-09 00:20: `rtk swift package clean && rtk swift test --filter AISearchIndexTests/testSemanticSearchRanksIndexedLocalMessages` passed after rebuilding all SwiftPM artifacts.
- 2026-07-09 00:20: `rtk swift test` passed 89 tests with 0 failures.
- 2026-07-09 00:20: `rtk swift build -c release --product PlainpostApp` passed.
- 2026-07-09 00:22: `rtk swift test --filter CLISurfaceTests/testAICommandsSupportSpecPositionalForms` failed red before implementation on unsupported/missing positional AI command fields.
- 2026-07-09 00:22: `rtk swift test --filter CLISurfaceTests/testAICommandsSupportSpecPositionalForms` passed process-level documented positional AI command validation.
- 2026-07-09 00:22: `rtk swift test --filter CLISurfaceTests/testAICommandsReturnLocalJSONWithoutSending` passed existing flag-form AI command regression validation.
- 2026-07-09 00:22: `rtk swift test --filter CLISurfaceTests/testAISearchReturnsRankedLocalMessageJSON` passed existing `ai search --query` regression validation.
- 2026-07-09 00:23: `rtk swift test` passed 90 tests with 0 failures.
- 2026-07-09 00:23: `rtk swift build -c release --product PlainpostApp` passed.
- 2026-07-09 00:24: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioListsAndReadsSafeResources` failed red before implementation on unsupported MCP resources output.
- 2026-07-09 00:26: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioListsAndReadsSafeResources` passed MCP stdio `resources/list` and `resources/read` validation.
- 2026-07-09 00:26: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioListsAndCallsSafeTools` passed broader MCP tools regression validation.
- 2026-07-09 00:26: `rtk swift test --filter CLISurfaceTests/testAccountListReturnsJSONWithoutSecrets` passed shared JSON encoder regression validation.
- 2026-07-09 00:26: `rtk swift test` passed 91 tests with 0 failures.
- 2026-07-09 00:26: `rtk swift build -c release --product PlainpostApp` passed.
- 2026-07-09 00:32: `rtk swift test --filter DraftAndSendPolicyTests/testSendRequestFlagsDeterministicApprovalRisks` failed red before implementation on missing `attachment_present` and `suspicious_link` flags.
- 2026-07-09 00:32: `rtk swift test --filter DraftAndSendPolicyTests` passed 7 core draft/send policy tests with 0 failures.
- 2026-07-09 00:32: `rtk swift test` passed 92 tests with 0 failures.
- 2026-07-09 00:33: `rtk swift build -c release --product PlainpostApp` passed.
- 2026-07-09 00:36: `rtk swift test --filter PermissionPolicyTests/testBodyReadPolicyRequiresReadBodyPermission` failed red before implementation because `MessageReadPolicy` did not exist.
- 2026-07-09 00:36: `rtk swift test --filter CLISurfaceTests/testMailReadBodyHonorsRestrictedAgentPermission` failed red before enforcement because restricted CLI body reads still returned body text.
- 2026-07-09 00:36: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPBodyReadsHonorRestrictedAgentPermission` failed red before enforcement because restricted MCP body reads still returned body text.
- 2026-07-09 00:37: `rtk swift test --filter PermissionPolicyTests` passed 3 permission policy tests with 0 failures.
- 2026-07-09 00:38: `rtk swift test --filter CLISurfaceTests/testMailReadBodyHonorsRestrictedAgentPermission` passed process-level restricted CLI body-read denial validation.
- 2026-07-09 00:38: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPBodyReadsHonorRestrictedAgentPermission` passed process-level restricted MCP tool/resource body-read denial validation.
- 2026-07-09 00:38: `rtk swift test` passed 95 tests with 0 failures.
- 2026-07-09 00:38: `rtk swift build -c release --product PlainpostApp` passed.
- 2026-07-09 00:41: `rtk swift test --filter CLISurfaceTests/testDraftCreateHonorsRestrictedAgentPermission` failed red before enforcement because restricted CLI draft create still returned `drf_cli_1`.
- 2026-07-09 00:41: `rtk swift test --filter CLISurfaceTests/testSendRequestHonorsRestrictedAgentPermission` failed red before enforcement because restricted CLI send request still returned `srq_drf_reply_1`.
- 2026-07-09 00:41: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPMutationToolsHonorRestrictedAgentPermissions` failed red before enforcement because restricted MCP mutation tools still returned draft/request IDs.
- 2026-07-09 00:42: `rtk swift test --filter CLISurfaceTests/testDraftCreateHonorsRestrictedAgentPermission` passed process-level restricted CLI draft-create denial validation.
- 2026-07-09 00:42: `rtk swift test --filter CLISurfaceTests/testSendRequestHonorsRestrictedAgentPermission` passed process-level restricted CLI send-request denial validation.
- 2026-07-09 00:42: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPMutationToolsHonorRestrictedAgentPermissions` passed process-level restricted MCP mutation denial validation.
- 2026-07-09 00:42: `rtk swift test` passed 98 tests with 0 failures.
- 2026-07-09 00:43: `rtk swift build -c release --product PlainpostApp` passed.
- 2026-07-09 00:45: `rtk swift test --filter InMemoryMailStoreTests/testMessageMutationPermissionsRejectRestrictedAgents` failed red before implementation because `AgentPermissions.agentRequested` lacked label/category/seen permission fields.
- 2026-07-09 00:47: `rtk swift test --filter InMemoryMailStoreTests/testMessageMutationPermissionsRejectRestrictedAgents` passed store-level restricted label/category/seen mutation validation.
- 2026-07-09 00:47: `rtk swift test --filter CLISurfaceTests/testMessageMutationCommandsHonorRestrictedAgentPermissions` passed process-level restricted CLI label/recategorize/mark-read denial validation.
- 2026-07-09 00:47: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPMessageMutationToolsHonorRestrictedAgentPermissions` passed process-level restricted MCP label/recategorize/mark-seen denial validation.
- 2026-07-09 00:48: `rtk swift test` passed 101 tests with 0 failures.
- 2026-07-09 00:49: `rtk swift build -c release --product PlainpostApp` passed.
- 2026-07-09 00:55: `rtk swift test --filter AIServiceTests/testAIServiceRejectsRestrictedAgentAIUsage` failed red before implementation because `AgentPermissions.agentRequested` lacked AI permission fields.
- 2026-07-09 00:56: `rtk swift test --filter AIServiceTests/testAIServiceRejectsRestrictedAgentAIUsage` passed core restricted AI summary/draft-reply/rewrite/classification validation.
- 2026-07-09 00:56: `rtk swift test --filter AISearchIndexTests/testSemanticSearchRejectsRestrictedAgentPermission` passed restricted semantic-search validation.
- 2026-07-09 00:56: `rtk swift test --filter CLISurfaceTests/testAICommandsHonorRestrictedAgentPermissions` passed process-level restricted CLI AI denial validation.
- 2026-07-09 00:56: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPAIToolsHonorRestrictedAgentPermissions` passed process-level restricted MCP AI denial validation.
- 2026-07-09 00:56: `rtk swift test --filter AIServiceTests` passed 6 local AI service tests with 0 failures.
- 2026-07-09 00:56: `rtk swift test --filter AISearchIndexTests` passed 3 local AI search-index tests with 0 failures.
- 2026-07-09 00:56: full `rtk swift test` aborted with `EXC_BAD_ACCESS` in `ApprovalQueueViewModelTests/testRefreshShowsPendingAgentSendRequestWithRiskDetails`; the isolated test reproduced before fix.
- 2026-07-09 00:58: `rtk swift test --filter ApprovalQueueViewModelTests/testRefreshShowsPendingAgentSendRequestWithRiskDetails` passed after binding the test SMTP client lifetime across the async refresh boundary.
- 2026-07-09 00:58: `rtk swift test --filter ApprovalQueueViewModelTests` passed 3 tests with 0 failures.
- 2026-07-09 00:58: `rtk swift test` passed 105 tests with 0 failures.
- 2026-07-09 00:58: `rtk swift build -c release --product PlainpostApp` passed.
- 2026-07-09 01:03: `rtk swift test --filter InMemoryMailStoreTests/testCancelSendRequestUpdatesStateAndAudits` failed red before implementation because `InMemoryMailStore` had no `cancelSendRequest`.
- 2026-07-09 01:04: `rtk swift test --filter InMemoryMailStoreTests/testCancelSendRequestUpdatesStateAndAudits` passed store-level send cancel state/audit validation.
- 2026-07-09 01:04: `rtk swift test --filter CLISurfaceTests/testSendRequestStatusAndCancelReturnJSONWithoutDirectSend` passed process-level CLI status/cancel and missing-ID validation.
- 2026-07-09 01:04: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPSendStatusAndCancelUseStoredRequestState` passed process-level MCP request/status/cancel and missing-ID validation.
- 2026-07-09 01:04: first full `rtk swift test` run found a regression where restricted MCP request-send hit fixture draft seeding before request-send permission; `rtk swift test --filter PlainpostCLIHarnessTests/testMCPMutationToolsHonorRestrictedAgentPermissions` reproduced it.
- 2026-07-09 01:05: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPMutationToolsHonorRestrictedAgentPermissions` passed after seeding fixture drafts through a system fixture actor while preserving requester permissions for `requestSend`.
- 2026-07-09 01:05: `rtk swift test --filter CLISurfaceTests/testSendRequestStatusAndCancelReturnJSONWithoutDirectSend` passed after the fixture seeding fix.
- 2026-07-09 01:05: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPSendStatusAndCancelUseStoredRequestState` passed after the fixture seeding fix.
- 2026-07-09 01:05: `rtk swift test` passed 107 tests with 0 failures.
- 2026-07-09 01:05: `rtk swift build -c release --product PlainpostApp` passed.
- 2026-07-09 01:09: `rtk swift test --filter CLISurfaceTests/testSmartInboxAndDraftCommandsReturnJSON` failed red before implementation because `smart-inbox batch` did not return the required batch JSON fields.
- 2026-07-09 01:10: `rtk swift test --filter CLISurfaceTests/testSmartInboxAndDraftCommandsReturnJSON` passed process-level Smart Inbox newsletter batch JSON validation.
- 2026-07-09 01:11: `rtk swift test --filter CLISurfaceTests/testSmartInboxBatchValidatesInputsAndHonorsMarkSeenPermission` passed process-level unsupported input and restricted mark-seen denial validation.
- 2026-07-09 01:11: `rtk swift test --filter CLISurfaceTests` passed 22 tests with 0 failures.
- 2026-07-09 01:11: `rtk swift test` passed 108 tests with 0 failures.
- 2026-07-09 01:11: `rtk swift build -c release` passed.
- 2026-07-09 01:14: `rtk swift test --filter SmartInboxBatchServiceTests/testArchiveReadArchivesNewsletterThroughIMAPAndMarksLocalSeen` failed red before implementation because `SmartInboxBatchService` and `SmartInboxBatchRequest` did not exist.
- 2026-07-09 01:15: `rtk swift test --filter SmartInboxBatchServiceTests/testArchiveReadArchivesNewsletterThroughIMAPAndMarksLocalSeen` passed local TCP IMAP archive plus local seen-state validation.
- 2026-07-09 01:15: `rtk swift test --filter SmartInboxBatchServiceTests/testArchiveReadRejectsRestrictedActorBeforeIMAPArchive` passed restricted actor denial and no-IMAP-mutation validation.
- 2026-07-09 01:15: `rtk swift test --filter SmartInboxBatchServiceTests` passed 2 tests with 0 failures.
- 2026-07-09 01:15: `rtk swift test --filter CLISurfaceTests/testSmartInboxAndDraftCommandsReturnJSON` passed after refactoring CLI batch to the shared core service.
- 2026-07-09 01:15: `rtk swift test --filter CLISurfaceTests/testSmartInboxBatchValidatesInputsAndHonorsMarkSeenPermission` passed after the shared service refactor.
- 2026-07-09 01:16: `rtk swift test` passed 110 tests with 0 failures.
- 2026-07-09 01:16: `rtk swift build -c release` passed.
- 2026-07-09 01:17: `rtk swift test --filter InboxViewModelTests/testSmartInboxGroupsFixtureMailIntoCards` failed red before implementation because `MessageRowModel` had no `isPinned` state and the Smart Inbox card order lacked Pinned.
- 2026-07-09 01:18: `rtk swift test --filter InboxViewModelTests` passed 5 UI state tests with 0 failures after adding the Pinned card and row pin state.
- 2026-07-09 01:18: `rtk swift test` passed 111 tests with 0 failures.
- 2026-07-09 01:18: `rtk swift build -c release` passed.
- 2026-07-09 01:21: `rtk swift test --filter EmailBodyRendererTests` failed red before implementation because `EmailBodyRenderer` and related body-rendering types did not exist.
- 2026-07-09 01:21: `rtk swift test --filter InboxViewModelTests/testThreadDetailExposesSanitizedMessagesAndBlockedRemoteImages` failed red before implementation for the same missing core renderer and thread-message state.
- 2026-07-09 01:22: `rtk swift test --filter EmailBodyRendererTests` passed 2 core body-rendering tests with 0 failures.
- 2026-07-09 01:22: `rtk swift test --filter InboxViewModelTests/testThreadDetailExposesSanitizedMessagesAndBlockedRemoteImages` passed UI thread-message safe rendering validation.
- 2026-07-09 01:22: `rtk swift test --filter InboxViewModelTests` passed 6 UI state tests with 0 failures.
- 2026-07-09 01:22: `rtk swift test` passed 114 tests with 0 failures.
- 2026-07-09 01:22: `rtk swift build -c release` passed.
- 2026-07-09 01:25: `rtk swift test --filter ApprovalQueueViewModelTests/testHighRiskApprovalRequiresLocalAuthenticationBeforeSMTP` failed red before implementation because `LocalApprovalAuthenticating`, `requiresAuthentication`, the injected authenticator initializer, and `LocalApprovalAuthenticationError` did not exist.
- 2026-07-09 01:25: `rtk swift test --filter ApprovalQueueViewModelTests/testDeniedHighRiskAuthenticationDoesNotSendSMTP` failed red before implementation for the same missing authentication gate types and UI state.
- 2026-07-09 01:27: `rtk swift test --filter ApprovalQueueViewModelTests/testHighRiskApprovalRequiresLocalAuthenticationBeforeSMTP` passed high-risk auth-then-local-SMTP validation.
- 2026-07-09 01:27: `rtk swift test --filter ApprovalQueueViewModelTests/testDeniedHighRiskAuthenticationDoesNotSendSMTP` passed denied-auth no-SMTP validation.
- 2026-07-09 01:27: `rtk swift test --filter ApprovalQueueViewModelTests` passed 5 approval queue tests with 0 failures.
- 2026-07-09 01:27: `rtk swift test` passed 116 tests with 0 failures.
- 2026-07-09 01:27: `rtk swift build -c release` passed.
- 2026-07-09 01:31: `rtk swift test --filter SQLiteMailStoreTests/testPersistsDraftSendRequestAndAuditAcrossReopen` failed red before implementation because `SQLiteMailStore` had no draft, send-request, approval-queue, or audit APIs.
- 2026-07-09 01:31: `rtk swift test --filter SQLiteMailStoreTests/testPersistsApprovalSendStatusAcrossReopen` and `rtk swift test --filter SQLiteMailStoreTests/testPersistsSendCancellationAcrossReopen` failed red for the same missing durable send-workflow APIs.
- 2026-07-09 01:32: `rtk swift test --filter SQLiteMailStoreTests` passed 4 SQLite store tests with 0 failures, including durable draft/send-request/audit reopen checks.
- 2026-07-09 01:32: `rtk swift test --filter ApprovalQueueViewModelTests` passed 5 approval queue tests with 0 failures after adding SQLite approval-queue conformance.
- 2026-07-09 01:32: `rtk swift test --filter ApprovalSMTPFlowTests` passed 4 local SMTP approval-flow tests with 0 failures.
- 2026-07-09 01:32: `rtk swift test` passed 119 tests with 0 failures.
- 2026-07-09 01:32: `rtk swift build -c release` passed.
- 2026-07-09 01:32: `rtk git diff --check` passed with no output.
- 2026-07-09 01:34: `rtk swift test --filter CLISurfaceTests/testSendRequestStatusAndCancelPersistAcrossCLIInvocationsWithSQLite` failed red before implementation because `send request --db-path` still rejected `drf_cli_1` and status/cancel used fresh in-memory state.
- 2026-07-09 01:35: `rtk swift test --filter CLISurfaceTests/testSendRequestStatusAndCancelPersistAcrossCLIInvocationsWithSQLite` passed process-level SQLite draft/create, request, status, cancel, and status-after-cancel validation across separate `plainpost` invocations.
- 2026-07-09 01:35: `rtk swift test --filter CLISurfaceTests/testSendRequestStatusAndCancelReturnJSONWithoutDirectSend` passed the existing seeded in-memory send queue regression test.
- 2026-07-09 01:35: `rtk swift test` passed 120 tests with 0 failures.
- 2026-07-09 01:36: `rtk swift build -c release` passed.
- 2026-07-09 01:36: `rtk git diff --check` passed with no output.
- 2026-07-09 01:38: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioSendQueuePersistsAcrossSQLiteSessions` failed red before implementation because MCP send queue tools still used the per-process in-memory store and hard-coded `drf_reply_1` fixture path.
- 2026-07-09 01:39: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioSendQueuePersistsAcrossSQLiteSessions` passed cross-session MCP SQLite create-draft, request-send, status, cancel, and status-after-cancel validation.
- 2026-07-09 01:39: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPSendStatusAndCancelUseStoredRequestState` passed seeded in-memory MCP send queue regression validation.
- 2026-07-09 01:39: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPMutationToolsHonorRestrictedAgentPermissions` passed restricted MCP draft/send-request mutation denial validation.
- 2026-07-09 01:39: `rtk swift test` passed 121 tests with 0 failures.
- 2026-07-09 01:39: `rtk swift build -c release` passed.
- 2026-07-09 01:39: `rtk git diff --check` passed with no output.
- 2026-07-09 01:43: `rtk swift test --filter CLISurfaceTests/testSendQueueUsesDefaultDataDirectoryAcrossCLIInvocations` failed red before implementation because `PLAINPOST_DATA_DIR` was ignored and CLI send queue commands fell back to per-process in-memory state.
- 2026-07-09 01:43: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioSendQueueUsesDefaultDataDirectoryAcrossSessions` failed red before implementation because `PLAINPOST_DATA_DIR` was ignored and MCP send queue sessions fell back to per-process in-memory state.
- 2026-07-09 01:44: `rtk swift test --filter CLISurfaceTests/testSendQueueUsesDefaultDataDirectoryAcrossCLIInvocations` passed default data-directory CLI draft/create, request, status, cancel, and status-after-cancel validation across separate `plainpost` invocations.
- 2026-07-09 01:44: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioSendQueueUsesDefaultDataDirectoryAcrossSessions` passed default data-directory MCP create-draft, request-send, status, cancel, and status-after-cancel validation across separate stdio sessions.
- 2026-07-09 01:44: `rtk swift test --filter CLISurfaceTests/testSendRequestStatusAndCancelPersistAcrossCLIInvocationsWithSQLite` passed explicit `--db-path` CLI send queue regression validation.
- 2026-07-09 01:44: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioSendQueuePersistsAcrossSQLiteSessions` passed explicit `--db-path` MCP send queue regression validation.
- 2026-07-09 01:44: `rtk swift test` passed 123 tests with 0 failures.
- 2026-07-09 01:44: `rtk swift build -c release` passed.
- 2026-07-09 01:44: `rtk git diff --check` passed with no output.
- 2026-07-09 01:48: `rtk swift test --filter ApprovalSMTPFlowTests/testGuiApprovalSendsDraftThroughLocalSMTPMarksRequestSentAndRecordsSentCopy` and `rtk swift test --filter SQLiteMailStoreTests/testPersistsLocalSentCopyAcrossReopen` failed red before implementation because `SQLiteMailStore` had no `recordSentMessage` API and the approval flow recorded no local Sent copy.
- 2026-07-09 01:49: `rtk swift test --filter ApprovalSMTPFlowTests/testGuiApprovalSendsDraftThroughLocalSMTPMarksRequestSentAndRecordsSentCopy` passed local SMTP approval delivery plus local Sent mailbox/message/audit validation.
- 2026-07-09 01:49: `rtk swift test --filter SQLiteMailStoreTests/testPersistsLocalSentCopyAcrossReopen` passed SQLite Sent-copy persistence validation across reopen.
- 2026-07-09 01:49: `rtk swift test --filter ApprovalSMTPFlowTests` passed 4 local SMTP approval tests with 0 failures.
- 2026-07-09 01:49: `rtk swift test --filter SQLiteMailStoreTests` passed 5 SQLite store tests with 0 failures.
- 2026-07-09 01:49: `rtk swift test --filter AuditLogViewModelTests/testAuditLogShowsComposerAndApprovalEventsAfterLocalSMTPDelivery` passed after including the new `message.sent_copy` audit event in the UI timeline.
- 2026-07-09 01:49: `rtk swift test` passed 124 tests with 0 failures.
- 2026-07-09 01:49: `rtk swift build -c release` passed.
- 2026-07-09 01:49: `rtk git diff --check` passed with no output.
- 2026-07-09 01:52: `rtk swift test --filter PermissionPolicyTests/testAttachmentReadPolicyRequiresAttachmentPermission`, `rtk swift test --filter CLISurfaceTests/testMailReadAttachmentsHonorsRestrictedAgentPermission`, and `rtk swift test --filter PlainpostCLIHarnessTests/testMCPAttachmentReadsHonorRestrictedAgentPermission` failed red before implementation because `AgentPermissions.readAttachments` and `MessageReadPolicy.validateAttachmentRead` did not exist.
- 2026-07-09 01:53: `rtk swift test --filter PermissionPolicyTests/testAttachmentReadPolicyRequiresAttachmentPermission` passed after adding attachment-read permission and policy enforcement.
- 2026-07-09 01:54: `rtk swift test --filter CLISurfaceTests/testMailReadAttachmentsHonorsRestrictedAgentPermission` passed process-level CLI attachment-read denial validation.
- 2026-07-09 01:54: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPAttachmentReadsHonorRestrictedAgentPermission` passed process-level MCP attachment-read denial validation.
- 2026-07-09 01:54: `rtk swift test --filter CLISurfaceTests/testMailReadBodyHonorsRestrictedAgentPermission` and `rtk swift test --filter PlainpostCLIHarnessTests/testMCPBodyReadsHonorRestrictedAgentPermission` passed existing body-read permission regressions.
- 2026-07-09 01:54: `rtk swift test` passed 127 tests with 0 failures.
- 2026-07-09 01:54: `rtk swift build -c release` passed.
- 2026-07-09 01:54: `rtk git diff --check` passed with no output.
- 2026-07-09 02:00: `rtk swift test --filter InboxViewModelTests/testInboxChromeExposesSparkLikeMacToolbarState` and `rtk swift test --filter InboxViewModelTests/testSmartInboxGroupsFixtureMailIntoCards` failed red before implementation because `InboxViewModel.chrome` and Smart Inbox card symbol/summary/action metadata did not exist.
- 2026-07-09 02:00: `rtk swift test --filter InboxViewModelTests/testInboxChromeExposesSparkLikeMacToolbarState` passed inbox title/subtitle/search/mode/toolbar metadata validation.
- 2026-07-09 02:00: `rtk swift test --filter InboxViewModelTests/testSmartInboxGroupsFixtureMailIntoCards` passed Smart Inbox card metadata validation.
- 2026-07-09 02:00: `rtk swift test --filter InboxViewModelTests` passed 7 UI state tests with 0 failures.
- 2026-07-09 02:00: `rtk swift build --product PlainpostApp` passed.
- 2026-07-09 02:00: `rtk swift test` passed 128 tests with 0 failures.
- 2026-07-09 02:00: `rtk swift build -c release` passed.
- 2026-07-09 02:00: `rtk git diff --check` passed with no output.
- 2026-07-09 02:05: `rtk swift test --filter PlainpostCLIHarnessTests/testAccountAddUsesDefaultDataDirectoryWhenDbPathIsAbsent` failed red before implementation because `account add` still required `--db-path`, returned validation output, and did not create `PLAINPOST_DATA_DIR/Plainpost.sqlite`.
- 2026-07-09 02:05: `rtk swift test --filter PlainpostCLIHarnessTests/testAccountAddUsesDefaultDataDirectoryWhenDbPathIsAbsent` passed process-level account add validation against local IMAP/SMTP with default data directory SQLite reload and plaintext-secret checks.
- 2026-07-09 02:05: `rtk swift test --filter PlainpostCLIHarnessTests/testAccountAddPersistsSQLiteAndKeychainViaLocalHarnesses` passed explicit `--db-path` account add regression validation against local IMAP/SMTP.
- 2026-07-09 02:06: `rtk swift test` passed 129 tests with 0 failures.
- 2026-07-09 02:06: `rtk swift build -c release` passed.
- 2026-07-09 02:06: `rtk git diff --check` passed with no output.
- 2026-07-09 02:10: `rtk swift test --filter IMAPHarnessTests/testAppendMessageStoresRemoteSentMessage && rtk swift test --filter ApprovalSMTPFlowTests/testGuiApprovalAppendsRemoteSentCopyAfterSMTPDelivery` failed red before implementation because `PlaintextIMAPClient.appendMessage`, `LocalIMAPServer.appendedMessages`, `ApprovalSMTPService.sentAppendClient`, and `RemoteSentAppendConfiguration` did not exist.
- 2026-07-09 02:12: `rtk swift test --filter IMAPHarnessTests/testAppendMessageStoresRemoteSentMessage` passed local TCP IMAP literal `APPEND` validation with recorded remote Sent message data.
- 2026-07-09 02:12: `rtk swift test --filter ApprovalSMTPFlowTests/testGuiApprovalAppendsRemoteSentCopyAfterSMTPDelivery` passed approved SMTP delivery plus remote IMAP Sent append validation.
- 2026-07-09 02:12: `rtk swift test --filter ApprovalSMTPFlowTests/testGuiApprovalSendsDraftThroughLocalSMTPMarksRequestSentAndRecordsSentCopy` passed existing local Sent-copy regression validation.
- 2026-07-09 02:12: `rtk swift test` passed 131 tests with 0 failures.
- 2026-07-09 02:12: `rtk swift build -c release` passed.
- 2026-07-09 02:12: `rtk git diff --check` passed with no output.
- 2026-07-09 02:14: `rtk swift test --filter ApprovalSMTPFlowTests/testRemoteSentAppendFailureDoesNotUndoAcceptedSMTPDelivery && rtk swift test --filter SQLiteMailStoreTests/testPersistsRemoteSentAppendFailureWarningAcrossReopen` failed red before implementation because `SQLiteMailStore.recordSendWarning` did not exist.
- 2026-07-09 02:16: `rtk swift test --filter SQLiteMailStoreTests/testPersistsRemoteSentAppendFailureWarningAcrossReopen` passed SQLite audit warning persistence validation.
- 2026-07-09 02:16: `rtk swift test --filter ApprovalSMTPFlowTests/testRemoteSentAppendFailureDoesNotUndoAcceptedSMTPDelivery` failed red before approval-service implementation because IMAP authentication failure still threw after SMTP acceptance.
- 2026-07-09 02:17: `rtk swift test --filter ApprovalSMTPFlowTests/testRemoteSentAppendFailureDoesNotUndoAcceptedSMTPDelivery`, `rtk swift test --filter ApprovalSMTPFlowTests/testSMTPRecipientRejectionMarksRequestFailed`, and `rtk swift test --filter ApprovalSMTPFlowTests/testGuiApprovalAppendsRemoteSentCopyAfterSMTPDelivery` passed focused non-fatal append failure, fatal SMTP rejection, and successful remote append validation.
- 2026-07-09 02:17: `rtk swift test` passed 133 tests with 0 failures.
- 2026-07-09 02:17: `rtk swift build -c release` passed.
- 2026-07-09 02:17: `rtk git diff --check` passed with no output.
- 2026-07-09 02:22: `rtk swift test --filter CLISurfaceTests/testPlainpostServiceHealthReturnsSecretSafeJSON` failed red before implementation because `.build/arm64-apple-macosx/debug/PlainpostService` did not exist.
- 2026-07-09 02:22: `rtk swift test --filter CLISurfaceTests/testPlainpostServiceHealthReturnsSecretSafeJSON` passed process-level service health JSON validation, and `rtk swift build --product PlainpostService` passed.
- 2026-07-09 02:23: `rtk swift run PlainpostService --health --json` returned secret-safe readiness JSON for `sqlite_cache`, `keychain_credentials`, `imap_sync`, `smtp_approval_queue`, `mcp_bridge`, `audit_log`, and `local_ai`.
- 2026-07-09 02:23: `rtk swift test` passed 134 tests with 0 failures.
- 2026-07-09 02:23: `rtk swift build -c release` passed.
- 2026-07-09 02:23: `rtk git diff --check` passed with no output.
- 2026-07-09 02:26: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceSyncInboxUsesLocalIMAPAndPersistsSQLite` failed red before implementation because `PlainpostService` returned unsupported-command output and SQLite remained empty.
- 2026-07-09 02:28: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceSyncInboxUsesLocalIMAPAndPersistsSQLite` passed after `PlainpostService sync inbox` connected to `LocalIMAPServer`, persisted `INBOX` and `msg_uid_1` to SQLite, and omitted the IMAP password from output and database contents.
- 2026-07-09 02:28: `rtk swift build --product PlainpostService` passed.
- 2026-07-09 02:28: `rtk swift test` passed 135 tests with 0 failures.
- 2026-07-09 02:28: `rtk swift build -c release` passed.
- 2026-07-09 02:28: `rtk git diff --check` passed with no output.
- 2026-07-09 02:32: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceApprovalSendsPendingSQLiteRequestThroughLocalSMTP` initially crashed because the new RED test indexed an empty SMTP capture; the test was corrected to unwrap the first accepted message safely.
- 2026-07-09 02:32: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceApprovalSendsPendingSQLiteRequestThroughLocalSMTP` then failed red before implementation because `PlainpostService` returned unsupported-command output and SMTP received no message.
- 2026-07-09 02:33: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceApprovalSendsPendingSQLiteRequestThroughLocalSMTP` passed after `PlainpostService approval approve` delivered the pending SQLite send request through `LocalSMTPServer`, persisted `sent` approval state and local Sent copy, and omitted the SMTP password from output and database contents.
- 2026-07-09 02:33: `rtk swift build --product PlainpostService` passed.
- 2026-07-09 02:33: `rtk swift test` passed 136 tests with 0 failures.
- 2026-07-09 02:33: `rtk swift build -c release` passed.
- 2026-07-09 02:33: `rtk git diff --check` passed with no output.
- 2026-07-09 02:39: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceSyncInboxUsesSQLiteAccountAndKeychainPassword` failed red before implementation because `PlainpostService sync inbox` still required explicit IMAP host, port, username, and password instead of resolving account metadata plus Keychain credentials.
- 2026-07-09 02:41: Systematic debugging showed the service process timed out before any local IMAP login attempt when reading a Keychain item seeded by the test bundle, so Stage 57 shifted to service-owned account setup before service-owned sync.
- 2026-07-09 02:45: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceSyncInboxUsesSQLiteAccountAndKeychainPassword` passed after `PlainpostService account add` verified local IMAP/SMTP, stored credentials in Keychain, and `PlainpostService sync inbox` used SQLite account metadata plus Keychain IMAP password without `--password`.
- 2026-07-09 02:45: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceSyncInboxUsesLocalIMAPAndPersistsSQLite`, `rtk swift test --filter PlainpostCLIHarnessTests/testAccountAddPersistsSQLiteAndKeychainViaLocalHarnesses`, and `rtk swift test --filter IMAPSyncCacheTests` passed explicit service sync, CLI account setup, and mailbox-normalization regressions.
- 2026-07-09 02:47: `rtk swift test` passed 137 tests with 0 failures.
- 2026-07-09 02:47: `rtk swift build --product PlainpostService` passed.
- 2026-07-09 02:47: `rtk swift build -c release` passed.
- 2026-07-09 02:47: `rtk git diff --check` passed with no output.
- 2026-07-09 02:53: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceApprovalUsesSQLiteAccountAndKeychainSMTPPassword` failed red before implementation because `PlainpostService approval approve` still returned `VALIDATION_FAILED` without explicit SMTP host, port, username, and password arguments.
- 2026-07-09 02:53: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceApprovalUsesSQLiteAccountAndKeychainSMTPPassword` passed after service approval loaded the draft account from SQLite, read the SMTP password from Keychain, and delivered through `LocalSMTPServer` without `--password`.
- 2026-07-09 02:53: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceApprovalSendsPendingSQLiteRequestThroughLocalSMTP` passed explicit SMTP-argument approval regression validation.
- 2026-07-09 02:53: `rtk swift build --product PlainpostService` passed.
- 2026-07-09 02:54: `rtk swift test` passed 138 tests with 0 failures.
- 2026-07-09 02:54: `rtk swift build -c release` passed.
- 2026-07-09 02:54: `rtk git diff --check` passed with no output.
- 2026-07-09 02:57: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceApprovalAppendsRemoteSentCopyWithStoredIMAPCredential` failed red before implementation because service approval delivered SMTP but appended no remote IMAP `Sent` message.
- 2026-07-09 02:57: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceApprovalAppendsRemoteSentCopyWithStoredIMAPCredential` passed after stored-account service approval read the IMAP password from Keychain and appended the rendered message to remote `Sent`.
- 2026-07-09 02:58: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceApprovalUsesSQLiteAccountAndKeychainSMTPPassword` and `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceApprovalSendsPendingSQLiteRequestThroughLocalSMTP` passed stored SMTP and explicit SMTP service approval regressions.
- 2026-07-09 02:58: `rtk swift build --product PlainpostService` passed.
- 2026-07-09 02:58: `rtk swift test` passed 139 tests with 0 failures.
- 2026-07-09 02:58: `rtk swift build -c release` passed.
- 2026-07-09 02:58: `rtk git diff --check` passed with no output.
- 2026-07-09 03:02: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLIAccountSyncCanUsePlainpostServiceStoredCredentials` failed red before implementation because `plainpost account sync --use-service` still required direct IMAP credentials and returned `Missing account sync arguments.`
- 2026-07-09 03:03: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLIAccountSyncCanUsePlainpostServiceStoredCredentials` passed after `plainpost` invoked `PlainpostService sync inbox` and the service read stored SQLite account metadata plus Keychain IMAP credentials.
- 2026-07-09 03:03: `rtk swift test --filter PlainpostCLIHarnessTests/testAccountSyncUsesLocalIMAPHarnessAndReturnsCachedMetadata`, `rtk swift build --product plainpost`, and `rtk swift build --product PlainpostService` passed direct CLI sync regression and product builds.
- 2026-07-09 03:03: `rtk swift test` passed 140 tests with 0 failures.
- 2026-07-09 03:03: `rtk swift build -c release` passed.
- 2026-07-09 03:03: `rtk git diff --check` passed with no output.
- 2026-07-09 03:09: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLIAccountAddCanUsePlainpostService` failed red before implementation because `plainpost account add --use-service` still returned direct CLI account-add JSON without the `PlainpostService` marker.
- 2026-07-09 03:11: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLIAccountAddCanUsePlainpostService` passed after `plainpost` invoked `PlainpostService account add`, then proved stored IMAP credentials by running a service-backed sync without password arguments.
- 2026-07-09 03:11: `rtk swift test --filter PlainpostCLIHarnessTests/testAccountAddPersistsSQLiteAndKeychainViaLocalHarnesses`, `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLIAccountSyncCanUsePlainpostServiceStoredCredentials`, `rtk swift build --product plainpost`, and `rtk swift build --product PlainpostService` passed direct account-add regression, service sync bridge regression, and product builds.
- 2026-07-09 03:12: `rtk swift test` passed 141 tests with 0 failures.
- 2026-07-09 03:12: `rtk swift build -c release` passed.
- 2026-07-09 03:12: `rtk git diff --check` passed with no output.
- 2026-07-09 03:15: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceCreatesPendingSendRequestWithoutSMTP` failed red before implementation because `PlainpostService send request` returned unsupported-command JSON.
- 2026-07-09 03:16: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceCreatesPendingSendRequestWithoutSMTP` passed after `PlainpostService send request` created `drf_service_request_1` and pending `srq_drf_service_request_1` in SQLite without additional SMTP delivery.
- 2026-07-09 03:16: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceApprovalUsesSQLiteAccountAndKeychainSMTPPassword` and `rtk swift build --product PlainpostService` passed stored approval regression and service build.
- 2026-07-09 03:16: `rtk swift test` passed 142 tests with 0 failures.
- 2026-07-09 03:17: `rtk swift build -c release` passed.
- 2026-07-09 03:17: `rtk git diff --check` passed with no output.
- 2026-07-09 03:19: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLISendRequestCanUsePlainpostServiceWithoutSMTP` failed red before implementation because `plainpost send request --use-service` still took the direct path and returned `DRAFT_NOT_FOUND`.
- 2026-07-09 03:20: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLISendRequestCanUsePlainpostServiceWithoutSMTP` passed after `plainpost` invoked `PlainpostService send request` and persisted the service-owned draft/send request without additional SMTP delivery.
- 2026-07-09 03:20: `rtk swift test --filter CLISurfaceTests/testSendRequestStatusAndCancelPersistAcrossCLIInvocationsWithSQLite`, `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceCreatesPendingSendRequestWithoutSMTP`, `rtk swift build --product plainpost`, and `rtk swift build --product PlainpostService` passed direct send queue regression, service primitive regression, and product builds.
- 2026-07-09 03:20: `rtk swift test` passed 143 tests with 0 failures.
- 2026-07-09 03:21: `rtk swift build -c release` passed.
- 2026-07-09 03:21: `rtk git diff --check` passed with no output.
- 2026-07-09 03:25: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPRequestSendCanUsePlainpostServiceWithoutSMTP` failed red before implementation because MCP `email.request_send` stayed on the direct SQLite path and returned `Draft not found.`
- 2026-07-09 03:26: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPRequestSendCanUsePlainpostServiceWithoutSMTP` passed after `plainpost mcp serve --use-service --db-path ...` invoked `PlainpostService send request`, persisted `drf_service_request_1` and `srq_drf_service_request_1`, and performed no additional SMTP delivery.
- 2026-07-09 03:26: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioSendQueuePersistsAcrossSQLiteSessions`, `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLISendRequestCanUsePlainpostServiceWithoutSMTP`, `rtk swift build --product plainpost`, and `rtk swift build --product PlainpostService` passed direct MCP queue regression, CLI service bridge regression, and product builds.
- 2026-07-09 03:27: `rtk swift test` passed 144 tests with 0 failures.
- 2026-07-09 03:27: `rtk swift build -c release` passed.
- 2026-07-09 03:27: `rtk git diff --check` passed with no output.
- 2026-07-09 03:32: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceReadsAndCancelsSendRequestWithoutSMTP` failed red before implementation because `PlainpostService send status` and `send cancel` returned unsupported-command JSON and SQLite remained pending.
- 2026-07-09 03:32: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceReadsAndCancelsSendRequestWithoutSMTP` passed after `PlainpostService send status/cancel` returned service JSON, preserved no-SMTP behavior, and persisted cancellation.
- 2026-07-09 03:32: `rtk swift build --product PlainpostService` passed.
- 2026-07-09 03:33: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLISendStatusAndCancelCanUsePlainpostService` failed red because `plainpost send status --use-service` still returned direct SQLite JSON without the `PlainpostService` marker.
- 2026-07-09 03:33: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceSendStatusAndCancelUsePlainpostService` failed red because MCP service-mode status/cancel still used direct SQLite payloads without service action markers.
- 2026-07-09 03:34: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLISendStatusAndCancelCanUsePlainpostService` and `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceSendStatusAndCancelUsePlainpostService` passed after CLI/MCP service bridge routing was added.
- 2026-07-09 03:35: `rtk swift test --filter CLISurfaceTests/testSendRequestStatusAndCancelPersistAcrossCLIInvocationsWithSQLite`, `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioSendQueuePersistsAcrossSQLiteSessions`, `rtk swift build --product plainpost`, and `rtk swift build --product PlainpostService` passed direct queue regressions and product builds.
- 2026-07-09 03:35: `rtk swift test` passed 147 tests with 0 failures.
- 2026-07-09 03:35: `rtk swift build -c release` passed.
- 2026-07-09 03:35: `rtk git diff --check` passed with no output.
- 2026-07-09 03:39: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLIServiceBridgeUsesApplicationSupportStoreWhenDbPathIsAbsent` failed red before implementation because `plainpost account add --use-service` still required `--db-path` and returned `Missing account add service arguments.`
- 2026-07-09 03:40: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLIServiceBridgeUsesApplicationSupportStoreWhenDbPathIsAbsent` passed after service-mode `plainpost` resolved `PLAINPOST_APPLICATION_SUPPORT_DIR/Plainpost.sqlite` and reused it for service-backed account add and sync without extra SMTP delivery.
- 2026-07-09 03:41: `rtk swift test --filter PlainpostCLIHarnessTests/testAccountAddUsesDefaultDataDirectoryWhenDbPathIsAbsent`, `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLIAccountAddCanUsePlainpostService`, `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceSendStatusAndCancelUsePlainpostService`, `rtk swift build --product plainpost`, and `rtk swift build --product PlainpostService` passed default data-dir, explicit service bridge, MCP service queue, and product build regressions.
- 2026-07-09 03:41: `rtk swift test` passed 148 tests with 0 failures.
- 2026-07-09 03:42: `rtk swift build -c release` passed.
- 2026-07-09 03:42: `rtk git diff --check` passed with no output.
- 2026-07-09 03:46: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceStoredCredentialsUsePersistedLoginUsername` failed red before implementation because stored service sync and approval authenticated with `me@example.com` instead of the submitted `login-id` username.
- 2026-07-09 03:48: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceStoredCredentialsUsePersistedLoginUsername` passed after account setup persisted `Account.username`, SQLite stored/reloaded it, and service stored-credential IMAP/SMTP paths used it.
- 2026-07-09 03:48: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceSyncInboxUsesSQLiteAccountAndKeychainPassword`, `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceApprovalUsesSQLiteAccountAndKeychainSMTPPassword`, and `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceApprovalAppendsRemoteSentCopyWithStoredIMAPCredential` passed stored-credential regressions.
- 2026-07-09 03:48: `rtk swift build --product PlainpostService` and `rtk swift build --product plainpost` passed.
- 2026-07-09 03:49: `rtk swift test` initially exited with signal 11 in `AccountSetupViewModelTests/testSubmitAddsAccountThroughRealLocalIMAPAndSMTPHarnesses`; a focused rerun reproduced it, then `rtk swift package clean` plus the same focused test passed, identifying stale SwiftPM incremental build state after the `Account` initializer change rather than a code failure.
- 2026-07-09 03:50: `rtk swift test` passed 149 tests with 0 failures after the clean build.
- 2026-07-09 03:50: `rtk swift build -c release` passed.
- 2026-07-09 03:50: `rtk git diff --check` passed with no output.
- 2026-07-09 03:54: Code-quality review found two compatibility issues: old-style `AccountSetupRequest` calls without `username` no longer compiled, and legacy encoded `Account` payloads without `username` would not decode.
- 2026-07-09 03:54: `rtk swift test --filter ScaffoldTests/testAccountDecodesLegacyPayloadWithoutUsername` initially could not complete because the new old-style request initializer regression exposed the missing `username` argument compile break; after adding a defaulted username fallback and custom `Account` decoder, it passed.
- 2026-07-09 03:54: `rtk swift test --filter AccountSetupFlowTests/testAccountSetupRequestDefaultsMissingUsernameToEmail` passed request initializer compatibility validation.
- 2026-07-09 03:54: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceStoredCredentialsUsePersistedLoginUsername`, `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceSyncInboxUsesSQLiteAccountAndKeychainPassword`, `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceApprovalUsesSQLiteAccountAndKeychainSMTPPassword`, and `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceApprovalAppendsRemoteSentCopyWithStoredIMAPCredential` passed distinct-login and stored-credential service regressions.
- 2026-07-09 03:54: `rtk swift build --product PlainpostService` and `rtk swift build --product plainpost` passed.
- 2026-07-09 03:54: `rtk swift test` passed 151 tests with 0 failures.
- 2026-07-09 03:55: `rtk swift build -c release` passed.
- 2026-07-09 03:55: `rtk git diff --check` passed with no output.
- 2026-07-09 04:01: `rtk swift test --filter ScaffoldTests/testAccountDecodesLegacyPayloadWithoutSentMailbox` failed red before implementation because `Account.sentMailbox` did not exist.
- 2026-07-09 04:01: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceApprovalUsesConfiguredSentMailbox` failed red after initial persistence implementation because IMAP `APPEND Sent Items ...` was parsed as mailbox `Sent`, exposing missing quoted mailbox support.
- 2026-07-09 04:03: `rtk swift test --filter IMAPHarnessTests/testAppendMessageSupportsMailboxNamesWithSpaces` failed red because `PlaintextIMAPClient.appendMessage(to: "Sent Items", ...)` reached the local IMAP server as an unquoted mailbox and was captured as `Sent`.
- 2026-07-09 04:04: `rtk swift test --filter IMAPHarnessTests/testAppendMessageSupportsMailboxNamesWithSpaces` passed after `PlaintextIMAPClient` quoted APPEND mailbox names and `LocalIMAPServer` parsed quoted mailbox atoms.
- 2026-07-09 04:04: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceApprovalUsesConfiguredSentMailbox` passed service-owned account setup/approval E2E with `--sent-mailbox "Sent Items"`, remote IMAP append to `Sent Items`, and local cached Sent mailbox path `Sent Items`.
- 2026-07-09 04:04: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceApprovalAppendsRemoteSentCopyWithStoredIMAPCredential`, `rtk swift test --filter ApprovalSMTPFlowTests/testGuiApprovalSendsDraftThroughLocalSMTPMarksRequestSentAndRecordsSentCopy`, `rtk swift build --product PlainpostService`, and `rtk swift build --product plainpost` passed default Sent regressions and product builds.
- 2026-07-09 04:05: `rtk swift test` passed 155 tests with 0 failures.
- 2026-07-09 04:05: `rtk swift build -c release` passed.
- 2026-07-09 04:05: `rtk git diff --check` passed with no output.
- 2026-07-09 04:09: Code-quality review found one important issue and two minor gaps: APPEND mailbox names with control characters were not rejected client-side, legacy SQLite account migration lacked explicit test coverage, and in-memory Sent mailbox replacement diverged from SQLite.
- 2026-07-09 04:09: `rtk swift test --filter IMAPHarnessTests/testAppendMessageRejectsMailboxNamesWithControlCharacters` failed red because the invalid mailbox reached the server and returned `A002 BAD invalid APPEND` instead of being rejected before command write.
- 2026-07-09 04:09: `rtk swift test --filter SQLiteMailStoreTests/testMigratesLegacyAccountsTableWithoutSentMailbox` passed, proving the existing migration defaulted old rows to `Sent`.
- 2026-07-09 04:09: `rtk swift test --filter SQLiteMailStoreTests/testInMemorySentCopyUpdatesExistingSentMailboxPath` failed red because the in-memory store kept the existing `_sent` mailbox path as `Sent`.
- 2026-07-09 04:10: `rtk swift test --filter IMAPHarnessTests/testAppendMessageRejectsMailboxNamesWithControlCharacters`, `rtk swift test --filter SQLiteMailStoreTests/testInMemorySentCopyUpdatesExistingSentMailboxPath`, `rtk swift test --filter IMAPHarnessTests/testAppendMessageSupportsMailboxNamesWithSpaces`, and `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceApprovalUsesConfiguredSentMailbox` passed after client-side control-character rejection and in-memory mailbox replacement fixes.
- 2026-07-09 04:10: `rtk swift test` passed 158 tests with 0 failures.
- 2026-07-09 04:11: `rtk swift build -c release` passed.
- 2026-07-09 04:11: `rtk git diff --check` passed with no output.
- 2026-07-09 04:18: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceServeStdioHandlesMultipleRequestsInOneProcess` failed red before implementation because `PlainpostService serve --stdio --json` returned unsupported-command JSON and the SQLite send request remained pending.
- 2026-07-09 04:18: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceServeStdioRejectsInvalidRequestAndContinues` failed red before implementation because the service did not process stdio JSONL requests and returned only the unsupported-command response.
- 2026-07-09 04:18: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceServeStdioHandlesMultipleRequestsInOneProcess` and `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceServeStdioRejectsInvalidRequestAndContinues` passed after adding the persistent stdio service loop, shared dispatcher, JSON response envelopes, and non-fatal validation errors.
- 2026-07-09 04:19: `rtk swift test` passed 160 tests with 0 failures.
- 2026-07-09 04:19: `rtk swift build -c release` passed.
- 2026-07-09 04:19: `rtk git diff --check` passed with no output.
- 2026-07-09 04:21: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceServeStdioEscapesRequestIDAsValidJSON` failed red because client-supplied request IDs containing decoded control characters made the manual response envelope invalid JSON.
- 2026-07-09 04:22: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceServeStdio` passed all 3 persistent service-loop tests after switching response envelopes to structural `JSONSerialization` encoding and preserving embedded service response objects.
- 2026-07-09 04:22: `rtk swift test` passed 161 tests with 0 failures.
- 2026-07-09 04:22: `rtk swift build -c release` passed.
- 2026-07-09 04:22: `rtk git diff --check` passed with no output.
- 2026-07-09 04:27: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceSyncInboxReturnsValidJSONForControlCharacters` failed red because manually assembled service sync JSON emitted an unescaped tab in a synced message subject.
- 2026-07-09 04:27: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceSyncInboxReturnsValidJSONForControlCharacters` and `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceServeStdio` passed after converting PlainpostService payload builders to structural `JSONSerialization` output and replacing substring-only stdio assertions with ordered NDJSON parsing.
- 2026-07-09 04:28: `rtk swift test` passed 162 tests with 0 failures.
- 2026-07-09 04:28: `rtk swift build -c release` passed.
- 2026-07-09 04:28: `rtk git diff --check` passed with no output.
- 2026-07-09 04:31: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceBridgeUsesOnePersistentPlainpostServiceProcess` failed red because `plainpost mcp serve --use-service` spawned `PlainpostService` four times for request/status/cancel/status instead of one `serve --stdio --json` service loop.
- 2026-07-09 04:34: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceBridgeUsesOnePersistentPlainpostServiceProcess`, `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceSendStatusAndCancelUsePlainpostService`, and `rtk swift test --filter PlainpostCLIHarnessTests/testMCPRequestSendCanUsePlainpostServiceWithoutSMTP` passed after adding a session-scoped MCP service bridge and changing `PlainpostService serve` to write each response line directly to stdout.
- 2026-07-09 04:35: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceServeStdio`, `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceSyncInboxReturnsValidJSONForControlCharacters`, `rtk swift build --product plainpost`, and `rtk swift build --product PlainpostService` passed service-loop and product regressions.
- 2026-07-09 04:35: `rtk swift test` passed 163 tests with 0 failures.
- 2026-07-09 04:35: `rtk swift build -c release` passed.
- 2026-07-09 04:35: `rtk git diff --check` passed with no output.
- 2026-07-09 04:41: Code review found two critical Stage 70 issues: `plainpost mcp serve` still waited for stdin EOF before responding to live MCP clients, and the persistent service bridge could block indefinitely on a hung child response.
- 2026-07-09 04:41: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServeRespondsBeforeStdinCloses` failed red because no initialize response was emitted while stdin remained open.
- 2026-07-09 04:41: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceBridgeTimesOutHungServiceResponse` failed red by hitting the outer `plainpost` timeout instead of returning an MCP tool error.
- 2026-07-09 04:41: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceBridgeReportsStartupFailureWithoutOneShotFallback` failed red on the unnormalized service startup error surface.
- 2026-07-09 04:43: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServeRespondsBeforeStdinCloses`, `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceBridgeReportsStartupFailureWithoutOneShotFallback`, and `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceBridgeTimesOutHungServiceResponse` passed after streaming MCP stdin line-by-line, carrying service bridge startup failure explicitly, draining service stderr, and adding bounded response reads.
- 2026-07-09 04:44: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceBridgeUsesOnePersistentPlainpostServiceProcess`, `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceSendStatusAndCancelUsePlainpostService`, `rtk swift test --filter PlainpostCLIHarnessTests/testMCPRequestSendCanUsePlainpostServiceWithoutSMTP`, `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceServeStdio`, and `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostServiceSyncInboxReturnsValidJSONForControlCharacters` passed Stage 70 service bridge and service-loop regressions.
- 2026-07-09 04:45: `rtk swift test` passed 166 tests with 0 failures.
- 2026-07-09 04:45: `rtk swift build -c release` passed.
- 2026-07-09 04:45: `rtk git diff --check` passed with no output.
- 2026-07-09 04:50: `rtk swift test --filter AIProviderTests` failed red before implementation because `OllamaProviderConfiguration` did not accept model IDs and `OllamaProvider` did not exist.
- 2026-07-09 04:50: `rtk swift test --filter AIProviderTests` passed after adding loopback-only Ollama configuration, `/api/generate` generation, `/api/embeddings` vectors, JSON classification parsing, and a local TCP Ollama-compatible HTTP harness.
- 2026-07-09 04:51: `rtk swift test` passed 169 tests with 0 failures.
- 2026-07-09 04:51: `rtk swift build -c release` passed.
- 2026-07-09 04:51: `rtk git diff --check` passed with no output.
- 2026-07-09 04:57: `rtk swift test --filter CLISurfaceTests/testAIProviderStatus` failed red before implementation because `plainpost ai provider status` returned `Unsupported command.` and the local Ollama harness received no `/api/tags` request.
- 2026-07-09 04:58: `rtk swift test --filter CLISurfaceTests/testAIProviderStatus` passed after adding AI provider status DTOs, deterministic/disabled snapshots, loopback-only Ollama `/api/tags` probing, CLI routing, and secret-safe JSON output.
- 2026-07-09 05:01: `rtk swift test --filter AIProviderSettingsViewModelTests` failed red before implementation because `AIProviderSettingsViewModel` did not exist.
- 2026-07-09 05:01: `rtk swift test --filter AIProviderSettingsViewModelTests` and `rtk swift build --product PlainpostApp` passed after adding the Settings provider status model and compact SwiftUI provider panel.
- 2026-07-09 05:01: `rtk swift test --filter CLISurfaceTests/testPlainpostCLISurfaceDoesNotExposeUnsafeSendCommands`, `rtk swift test --filter CLISurfaceTests/testAIProviderStatus`, `rtk swift test --filter AIProviderSettingsViewModelTests`, and `rtk swift test --filter AIProviderTests` passed the Stage 72 focused cluster.
- 2026-07-09 05:01: `rtk swift test` passed 175 tests with 0 failures.
- 2026-07-09 05:02: `rtk swift build -c release` passed.
- 2026-07-09 05:02: `rtk git diff --check` passed with no output.
- 2026-07-09 05:05: `rtk swift test --filter AIProviderSettingsViewModelTests/testSelectingProviderUpdatesRowsAndPersistsAcrossReload` failed red because `UserDefaultsAIProviderPreferenceStore`, injectable preview settings, and provider selection APIs did not exist.
- 2026-07-09 05:06: `rtk swift test --filter AIProviderSettingsViewModelTests` passed 5 tests after adding persisted provider selection, row-state updates, and invalid-provider guarding.
- 2026-07-09 05:06: `rtk swift build --product PlainpostApp` passed.
- 2026-07-09 05:07: `rtk swift test` passed 177 tests with 0 failures.
- 2026-07-09 05:07: `rtk swift build -c release` passed.
- 2026-07-09 05:07: `rtk git diff --check` passed with no output.
- 2026-07-09 05:10: `rtk swift test --filter CLISurfaceTests/testAICommandExecutionCanUseSelectedLocalOllamaProvider` failed red because `plainpost ai summarize-thread` still returned `deterministic-local` and the local Ollama harness received no request.
- 2026-07-09 05:12: `rtk swift test --filter CLISurfaceTests/testAICommandExecutionCanUseSelectedLocalOllamaProvider` passed after adding the local provider resolver and routing CLI AI execution through selected local providers.
- 2026-07-09 05:12: `rtk swift test --filter CLISurfaceTests/testAI` and `rtk swift test --filter AIProviderTests` passed the focused Stage 74 AI cluster.
- 2026-07-09 05:12: `rtk swift test` passed 178 tests with 0 failures.
- 2026-07-09 05:13: `rtk swift build -c release` passed.
- 2026-07-09 05:13: `rtk git diff --check` passed with no output.
- 2026-07-09 05:15: `rtk swift test --filter CLISurfaceTests/testAISummaryCanUsePlainpostServiceWithSelectedLocalOllamaProvider` failed red because `plainpost ai summarize-thread --use-service` still returned direct CLI JSON without `PlainpostService` service/action fields.
- 2026-07-09 05:17: `rtk swift test --filter CLISurfaceTests/testAISummaryCanUsePlainpostServiceWithSelectedLocalOllamaProvider` passed after adding `PlainpostService ai summarize-thread`, selected provider resolution in the service, `SQLiteMailStore: LocalAIStore`, and the `plainpost --use-service` bridge.
- 2026-07-09 05:17: `rtk swift test --filter CLISurfaceTests/testAI` and `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostService` passed the focused Stage 75 AI/service cluster.
- 2026-07-09 05:17: `rtk swift test` passed 179 tests with 0 failures.
- 2026-07-09 05:18: `rtk swift build -c release` passed.
- 2026-07-09 05:18: `rtk git diff --check` passed with no output.
- 2026-07-09 05:20: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceBridgeAISummaryUsesPlainpostServiceAndSelectedOllamaProvider` failed red because MCP `email.ai.summarize_thread` still returned direct deterministic JSON and the local Ollama harness received no request.
- 2026-07-09 05:21: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceBridgeAISummaryUsesPlainpostServiceAndSelectedOllamaProvider` passed after routing MCP AI summary through the persistent service bridge when `--use-service` is active.
- 2026-07-09 05:21: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPService` passed the focused Stage 76 MCP service bridge cluster.
- 2026-07-09 05:21: `rtk swift test` passed 180 tests with 0 failures.
- 2026-07-09 05:22: `rtk swift build -c release` passed.
- 2026-07-09 05:22: `rtk git diff --check` passed with no output.
- 2026-07-09 05:25: `rtk swift test --filter CLISurfaceTests/testAIDraftReplyCanUsePlainpostServiceWithSelectedLocalOllamaProvider` failed red because `plainpost ai draft-reply --use-service` still returned direct CLI draft JSON without service/action/body/review fields.
- 2026-07-09 05:26: `rtk swift test --filter CLISurfaceTests/testAIDraftReplyCanUsePlainpostServiceWithSelectedLocalOllamaProvider` passed after adding `PlainpostService ai draft-reply` and the `plainpost --use-service` bridge.
- 2026-07-09 05:26: `rtk swift test --filter CLISurfaceTests/testAI` and `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostService` passed the focused Stage 77 AI/service cluster.
- 2026-07-09 05:26: `rtk swift test` passed 181 tests with 0 failures.
- 2026-07-09 05:27: `rtk swift build -c release` passed.
- 2026-07-09 05:27: `rtk git diff --check` passed with no output.
- 2026-07-09 05:30: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceBridgeAIDraftReplyUsesPlainpostServiceAndSelectedOllamaProvider` failed red because MCP `email.ai.draft_reply` still returned direct CLI draft JSON without service/action/body/review fields.
- 2026-07-09 05:30: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceBridgeAIDraftReplyUsesPlainpostServiceAndSelectedOllamaProvider` passed after routing MCP AI draft reply through the persistent service bridge when `--use-service` is active.
- 2026-07-09 05:30: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceBridgeAI` and `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostService` passed the focused Stage 78 MCP/service cluster.
- 2026-07-09 05:31: `rtk swift test` passed 182 tests with 0 failures.
- 2026-07-09 05:31: `rtk swift build -c release` passed.
- 2026-07-09 05:31: `rtk git diff --check` passed with no output.
- 2026-07-09 05:33: `rtk swift test --filter CLISurfaceTests/testAIRewriteDraftCanUsePlainpostServiceWithSelectedLocalOllamaProvider` failed red because `plainpost ai rewrite-draft --use-service` still returned direct CLI rewrite JSON without service/action fields.
- 2026-07-09 05:34: `rtk swift test --filter CLISurfaceTests/testAIRewriteDraftCanUsePlainpostServiceWithSelectedLocalOllamaProvider` then failed because the new service rewrite path used the Stage 0 seeded store without `drf_reply_1`.
- 2026-07-09 05:35: `rtk swift test --filter CLISurfaceTests/testAIRewriteDraftCanUsePlainpostServiceWithSelectedLocalOllamaProvider` passed after adding `PlainpostService ai rewrite-draft`, the `plainpost --use-service` bridge, and a service-side seeded reply draft fixture.
- 2026-07-09 05:35: `rtk swift test --filter CLISurfaceTests/testAI` and `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostService` passed the focused Stage 79 AI/service cluster.
- 2026-07-09 05:35: `rtk swift test` passed 183 tests with 0 failures.
- 2026-07-09 05:36: `rtk swift build -c release` passed.
- 2026-07-09 05:36: `rtk git diff --check` passed with no output.
- 2026-07-09 05:37: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceBridgeAIRewriteDraftUsesPlainpostServiceAndSelectedOllamaProvider` failed red because MCP `email.ai.rewrite_draft` still used the direct handler, returned `Draft not found.`, and did not call the local Ollama harness.
- 2026-07-09 05:38: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceBridgeAIRewriteDraftUsesPlainpostServiceAndSelectedOllamaProvider` passed after routing MCP AI rewrite through the persistent service bridge when `--use-service` is active.
- 2026-07-09 05:38: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceBridgeAI` and `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostService` passed the focused Stage 80 MCP/service cluster.
- 2026-07-09 05:38: `rtk swift test` passed 184 tests with 0 failures.
- 2026-07-09 05:39: `rtk swift build -c release` passed.
- 2026-07-09 05:39: `rtk git diff --check` passed with no output.
- 2026-07-09 05:40: `rtk swift test --filter CLISurfaceTests/testAIClassifyCanUsePlainpostServiceWithSelectedLocalOllamaProvider` failed red because `plainpost ai classify --use-service` still returned direct CLI classification JSON without service/action fields.
- 2026-07-09 05:41: `rtk swift test --filter CLISurfaceTests/testAIClassifyCanUsePlainpostServiceWithSelectedLocalOllamaProvider` passed after adding `PlainpostService ai classify` and the `plainpost --use-service` bridge.
- 2026-07-09 05:41: `rtk swift test --filter CLISurfaceTests/testAI` and `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostService` passed the focused Stage 81 AI/service cluster.
- 2026-07-09 05:41: `rtk swift test` passed 185 tests with 0 failures.
- 2026-07-09 05:42: `rtk swift build -c release` passed.
- 2026-07-09 05:42: `rtk git diff --check` passed with no output.
- 2026-07-09 05:44: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceBridgeAIClassifyUsesPlainpostServiceAndSelectedOllamaProvider` failed red because MCP `email.ai.classify` still returned direct deterministic classification JSON and the local Ollama harness received no request.
- 2026-07-09 05:45: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceBridgeAIClassifyUsesPlainpostServiceAndSelectedOllamaProvider` passed after routing MCP AI classification through the persistent service bridge when `--use-service` is active.
- 2026-07-09 05:45: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceBridgeAI` and `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostService` passed the focused Stage 82 MCP/service cluster.
- 2026-07-09 05:46: `rtk swift test` passed 186 tests with 0 failures.
- 2026-07-09 05:46: `rtk swift build -c release` passed.
- 2026-07-09 05:46: `rtk git diff --check` passed with no output.
- 2026-07-09 05:49: `rtk swift test --filter CLISurfaceTests/testAISemanticSearchCanUsePlainpostServiceWithSelectedLocalOllamaProvider` failed red because `plainpost ai semantic-search --use-service` still returned direct CLI search JSON without service/action fields.
- 2026-07-09 05:50: `rtk swift test --filter CLISurfaceTests/testAISemanticSearchCanUsePlainpostServiceWithSelectedLocalOllamaProvider` passed after adding `PlainpostService ai semantic-search` and the `plainpost --use-service` bridge.
- 2026-07-09 05:50: `rtk swift test --filter CLISurfaceTests/testAI` and `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostService` passed the focused Stage 83 AI/service cluster.
- 2026-07-09 05:51: `rtk swift test` passed 187 tests with 0 failures.
- 2026-07-09 05:51: `rtk swift build -c release` passed.
- 2026-07-09 05:51: `rtk git diff --check` passed with no output.
- 2026-07-09 05:56: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceBridgeAISemanticSearchUsesPlainpostServiceAndSelectedOllamaProvider` failed red because MCP `email.ai.semantic_search` still returned direct deterministic search JSON and the local Ollama harness received no embedding request.
- 2026-07-09 05:57: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceBridgeAISemanticSearchUsesPlainpostServiceAndSelectedOllamaProvider` passed after routing MCP AI semantic search through the persistent service bridge when `--use-service` is active.
- 2026-07-09 05:57: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPServiceBridgeAI`, `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostService`, and `rtk swift test --filter PlainpostCLIHarnessTests/testMCPAIToolsHonorRestrictedAgentPermissions` passed the focused Stage 84 MCP/service cluster.
- 2026-07-09 05:57: `rtk swift test` passed 188 tests with 0 failures.
- 2026-07-09 05:58: `rtk swift build -c release` passed.
- 2026-07-09 05:58: `rtk git diff --check` passed with no output.
- 2026-07-09 06:01: `rtk swift test --filter CLISurfaceTests/testAIIndexPauseAndResumeReturnLocalJSONWithoutSecrets` failed red because `plainpost ai index pause` and `resume` still returned unsupported-command output.
- 2026-07-09 06:03: first focused green attempt exposed the new `.paused` state as a non-exhaustive SwiftUI index-status switch; `AIIndexStatusViewModelTests/testPausedAIIndexStatusNeedsAttention` was added before mapping the paused UI state.
- 2026-07-09 06:03: `rtk swift test --filter CLISurfaceTests/testAIIndexPauseAndResumeReturnLocalJSONWithoutSecrets`, `rtk swift test --filter CLISurfaceTests/testAICommandsHonorRestrictedAgentPermissions`, `rtk swift test --filter CLISurfaceTests/testAIIndexStatusAndRebuildReturnLocalJSONWithoutSecrets`, `rtk swift test --filter AIIndexStatusTests`, and `rtk swift test --filter AIIndexStatusViewModelTests` passed.
- 2026-07-09 06:03: `rtk swift test` passed 190 tests with 0 failures.
- 2026-07-09 06:04: `rtk swift build -c release` passed.
- 2026-07-09 06:04: `rtk git diff --check` passed with no output.
- 2026-07-09 06:08: `rtk swift test --filter PlainpostCLIHarnessTests/testDraftSyncAppendsLocalDraftToRemoteDraftsMailbox` initially crashed because the new red test indexed an empty IMAP append capture; the test was corrected to unwrap the first remote draft safely.
- 2026-07-09 06:08: `rtk swift test --filter PlainpostCLIHarnessTests/testDraftSyncAppendsLocalDraftToRemoteDraftsMailbox` failed red because `plainpost draft sync` returned unsupported-command JSON and no IMAP `APPEND` was recorded.
- 2026-07-09 06:09: `rtk swift test --filter PlainpostCLIHarnessTests/testDraftSyncAppendsLocalDraftToRemoteDraftsMailbox` passed after adding direct CLI server draft sync through IMAP `APPEND`.
- 2026-07-09 06:09: `rtk swift test --filter CLISurfaceTests/testDraftUpdateAndDeleteCommandsReturnJSONWithoutSending`, `rtk swift test --filter IMAPHarnessTests/testAppendMessageStoresRemoteSentMessage`, and `rtk swift test --filter IMAPHarnessTests/testAppendMessageSupportsMailboxNamesWithSpaces` passed.
- 2026-07-09 06:11: `rtk swift test` passed 191 tests with 0 failures.
- 2026-07-09 06:11: `rtk swift build -c release` passed.
- 2026-07-09 06:11: `rtk git diff --check` passed with no output.
- 2026-07-09 06:15: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLIDraftSyncCanUsePlainpostServiceStoredCredentials` failed red because `plainpost draft sync --use-service` still used the direct CLI validator and required explicit IMAP connection arguments.
- 2026-07-09 06:16: the same focused test reached `PlainpostService` but returned `DRAFT_SYNC_FAILED`; root cause was `plainpost draft create` hard-coding `acc_personal` and `me@example.com` instead of preserving supplied `--account` and `--from`, leaving the service unable to resolve the stored account.
- 2026-07-09 06:17: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLIDraftSyncCanUsePlainpostServiceStoredCredentials` passed after adding `PlainpostService draft sync`, the `plainpost --use-service` bridge, and CLI draft account/from preservation.
- 2026-07-09 06:17: `rtk swift test --filter PlainpostCLIHarnessTests/testDraftSyncAppendsLocalDraftToRemoteDraftsMailbox`, `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLIAccountSyncCanUsePlainpostServiceStoredCredentials`, and `rtk swift test --filter CLISurfaceTests/testDraftUpdateAndDeleteCommandsReturnJSONWithoutSending` passed.
- 2026-07-09 06:17: `rtk swift test` passed 192 tests with 0 failures.
- 2026-07-09 06:18: `rtk swift build -c release` passed.
- 2026-07-09 06:18: `rtk git diff --check` passed with no output.
- 2026-07-09 06:22: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPSyncDraftUsesPlainpostServiceStoredCredentials` failed red because MCP `email.sync_draft` was unknown while the preceding MCP `email.create_draft` call succeeded.
- 2026-07-09 06:23: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPSyncDraftUsesPlainpostServiceStoredCredentials` passed after adding MCP `email.sync_draft`, routing it through the persistent `PlainpostService` bridge, and preserving optional `account`/`from` in MCP-created drafts.
- 2026-07-09 06:23: `rtk swift test --filter MCPToolRegistryTests`, `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioListsAndCallsSafeTools`, and `rtk swift test --filter PlainpostCLIHarnessTests/testMCPMutationToolsHonorRestrictedAgentPermissions` passed.
- 2026-07-09 06:23: `rtk swift test` passed 193 tests with 0 failures.
- 2026-07-09 06:24: `rtk swift build -c release` passed.
- 2026-07-09 06:24: `rtk git diff --check` passed with no output.
- 2026-07-09 06:30: `rtk swift test --filter IMAPHarnessTests/testAppendMessageStoresRemoteSentMessage` failed red at compile time because `appendMessage` returned `Void`, appended messages had no UID, and drafts had no server draft metadata fields.
- 2026-07-09 06:32: `rtk swift test --filter IMAPHarnessTests/testAppendMessageStoresRemoteSentMessage` passed after returning `IMAPAppendResult` and parsing local UIDPLUS APPENDUID metadata.
- 2026-07-09 06:32: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLIDraftSyncCanUsePlainpostServiceStoredCredentials` passed after service-backed draft sync persisted and returned server draft mailbox/UID metadata.
- 2026-07-09 06:32: `rtk swift test --filter PlainpostCLIHarnessTests/testDraftSyncAppendsLocalDraftToRemoteDraftsMailbox` passed with direct CLI server draft metadata output, local IMAP UID capture, and SQLite draft reload assertions.
- 2026-07-09 06:32: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPSyncDraftUsesPlainpostServiceStoredCredentials` passed with MCP service bridge server draft metadata output and persisted SQLite draft metadata.
- 2026-07-09 06:33: `rtk swift test` passed 193 tests with 0 failures.
- 2026-07-09 06:33: `rtk swift build -c release` passed.
- 2026-07-09 06:34: `rtk git diff --check` passed with no output.
- 2026-07-09 06:39: `rtk swift test --filter SQLiteMailStoreTests/testPersistsMessageMetadataMutationsAcrossReopen` failed red because `SQLiteMailStore` had no durable label/category/seen mutation methods.
- 2026-07-09 06:39: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLISmartInboxBatchCanUsePlainpostServiceStoredCredentials` failed red because `smart-inbox batch --use-service` still used the direct fixture path, returned `msg_newsletter_1`, and did not touch IMAP or SQLite.
- 2026-07-09 06:39: `rtk swift test --filter SQLiteMailStoreTests/testPersistsMessageMetadataMutationsAcrossReopen` passed after adding `SQLiteMailStore: MessageMetadataRepository` with durable message mutation auditing.
- 2026-07-09 06:41: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLISmartInboxBatchCanUsePlainpostServiceStoredCredentials` passed after routing Smart Inbox batch through `PlainpostService`, stored Keychain IMAP credentials, and the local IMAP archive flow.
- 2026-07-09 06:41: `rtk swift test --filter CLISurfaceTests/testSmartInboxAndDraftCommandsReturnJSON` and `rtk swift test --filter SmartInboxBatchServiceTests` passed direct CLI and shared core batch regressions.
- 2026-07-09 06:41: `rtk swift test` passed 195 tests with 0 failures.
- 2026-07-09 06:42: `rtk swift build -c release` passed.
- 2026-07-09 06:42: `rtk git diff --check` passed with no output.
- 2026-07-09 06:46: `rtk swift test --filter MCPToolRegistryTests` and `rtk swift test --filter CLISurfaceTests/testMCPSchemaListsSafeToolsOnly` failed red because `email.smart_inbox_batch` was missing from the MCP registry/schema.
- 2026-07-09 06:46: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPSmartInboxBatchUsesPlainpostServiceStoredCredentials` failed red with unknown MCP tool and no IMAP archive side effects.
- 2026-07-09 06:47: `rtk swift test --filter MCPToolRegistryTests`, `rtk swift test --filter CLISurfaceTests/testMCPSchemaListsSafeToolsOnly`, and `rtk swift test --filter PlainpostCLIHarnessTests/testMCPSmartInboxBatchUsesPlainpostServiceStoredCredentials` passed after adding `email.smart_inbox_batch` and routing it through the persistent service bridge.
- 2026-07-09 06:47: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLISmartInboxBatchCanUsePlainpostServiceStoredCredentials` passed the direct CLI service regression.
- 2026-07-09 06:47: `rtk swift test` passed 196 tests with 0 failures.
- 2026-07-09 06:48: `rtk swift build -c release` passed.
- 2026-07-09 06:48: `rtk git diff --check` passed with no output.
- 2026-07-09 06:54: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLIMailSeenActionsCanUsePlainpostServiceStoredCredentials` failed red because `plainpost mail mark-read --use-service` still returned direct in-memory `MESSAGE_NOT_FOUND` output and did not mutate IMAP or SQLite.
- 2026-07-09 06:54: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLIMailSeenActionsCanUsePlainpostServiceStoredCredentials` passed after routing `mail mark-read/mark-unread --use-service` through `PlainpostService`, stored Keychain IMAP credentials, IMAP `\Seen` mutation, and SQLite `isSeen` persistence.
- 2026-07-09 06:55: `rtk swift test --filter CLISurfaceTests/testMailActionCommandsReturnJSONWithoutSecrets` and `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLISmartInboxBatchCanUsePlainpostServiceStoredCredentials` passed direct CLI and Smart Inbox service regressions.
- 2026-07-09 06:55: `rtk swift test` passed 197 tests with 0 failures.
- 2026-07-09 06:55: `rtk swift build -c release` passed.
- 2026-07-09 06:55: `rtk git diff --check` passed with no output.
- 2026-07-09 06:58: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPMarkSeenUsesPlainpostServiceStoredCredentials` failed red because MCP `email.mark_seen` still used the direct local store and returned `Message not found` for synced `msg_uid_1`.
- 2026-07-09 06:59: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPMarkSeenUsesPlainpostServiceStoredCredentials` passed after routing account-backed service-mode `email.mark_seen` calls through `PlainpostService mail mark-read/mark-unread`.
- 2026-07-09 06:59: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioListsAndCallsSafeTools` and `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLIMailSeenActionsCanUsePlainpostServiceStoredCredentials` passed direct MCP and CLI service regressions.
- 2026-07-09 06:59: `rtk swift test` passed 198 tests with 0 failures.
- 2026-07-09 07:00: `rtk swift build -c release` passed.
- 2026-07-09 07:00: `rtk git diff --check` passed with no output.
- 2026-07-09 07:02: `rtk swift test --filter SQLiteMailStoreTests/testPersistsMessageMailboxAndDeletedStateAcrossReopen` failed red at compile time because `MessageSummary.mailboxPath`, `MessageSummary.isDeleted`, `SQLiteMailStore.moveMessage`, and `SQLiteMailStore.markDeleted` did not exist.
- 2026-07-09 07:06: `rtk swift test --filter SQLiteMailStoreTests/testPersistsMessageMailboxAndDeletedStateAcrossReopen` passed after adding mailbox/deleted message metadata and SQLite persistence.
- 2026-07-09 07:07: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLIMailArchiveCanUsePlainpostServiceStoredCredentials` passed after routing service-backed archive through stored Keychain IMAP credentials, IMAP UID COPY/delete/expunge, and SQLite mailbox persistence.
- 2026-07-09 07:07: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLIMailDeleteCanUsePlainpostServiceStoredCredentials` passed after routing service-backed delete through stored Keychain IMAP credentials, IMAP `\Deleted`/EXPUNGE, and SQLite deleted-state persistence.
- 2026-07-09 07:07: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLIMailSeenActionsCanUsePlainpostServiceStoredCredentials` and `rtk swift test --filter CLISurfaceTests/testMailActionCommandsReturnJSONWithoutSecrets` passed mark-read/unread and direct CLI regressions.
- 2026-07-09 07:07: first full `rtk swift test` attempt crashed in `AISearchIndexTests/testSemanticSearchRanksIndexedLocalMessages`; root cause was stale SwiftPM artifacts after the `MessageSummary` initializer change. `rtk swift package clean && rtk swift test --filter AISearchIndexTests/testSemanticSearchRanksIndexedLocalMessages` passed.
- 2026-07-09 07:08: `rtk swift test` passed 201 tests with 0 failures after the clean rebuild.
- 2026-07-09 07:08: `rtk swift build -c release` passed.
- 2026-07-09 07:08: `rtk git diff --check` passed with no output.
- 2026-07-09 07:14: `rtk swift test --filter MCPToolRegistryTests/testRegistryIncludesSafeMailAndSendRequestTools` failed red because MCP `email.archive` and `email.delete` were not yet registered.
- 2026-07-09 07:14: `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioListsAndCallsSafeTools` failed red because direct MCP `email.archive` and `email.delete` calls were unknown.
- 2026-07-09 07:15: `rtk swift test --filter MCPToolRegistryTests/testRegistryIncludesSafeMailAndSendRequestTools`, `rtk swift test --filter PlainpostCLIHarnessTests/testMCPStdioListsAndCallsSafeTools`, `rtk swift test --filter PlainpostCLIHarnessTests/testMCPArchiveUsesPlainpostServiceStoredCredentials`, and `rtk swift test --filter PlainpostCLIHarnessTests/testMCPDeleteUsesPlainpostServiceStoredCredentials` passed after adding safe MCP archive/delete tools and service bridge routing through stored Keychain IMAP credentials.
- 2026-07-09 07:15: `rtk swift test` passed 203 tests with 0 failures.
- 2026-07-09 07:15: `rtk swift build -c release` passed.
- 2026-07-09 07:15: `rtk git diff --check` passed with no output.
- 2026-07-09 07:20: `rtk swift test --filter InboxMailActionViewModelTests` failed red at compile time because `MessageRowModel.actions`, `InboxMailActionViewModel`, and `InboxMailActionService` did not exist.
- 2026-07-09 07:20: `rtk swift test --filter InboxMailActionViewModelTests` passed 3 UI/local IMAP tests after adding row action models, `InboxMailActionService`, `InboxMailActionViewModel`, and row action buttons.
- 2026-07-09 07:20: `rtk swift test --filter PlainpostUITests` passed 34 UI tests with 0 failures.
- 2026-07-09 07:20: `rtk swift build --product PlainpostApp` passed.
- 2026-07-09 07:21: `rtk swift test` passed 206 tests with 0 failures.
- 2026-07-09 07:21: `rtk swift build -c release` passed.
- 2026-07-09 07:21: `rtk git diff --check` passed with no output.
- 2026-07-09 07:27: `rtk swift test --filter PlainpostAppRuntimeTests` failed red because `PlainpostAppRuntime` and `PlainpostAppRuntimeConfiguration` did not exist.
- 2026-07-09 07:28: `rtk swift test --filter PlainpostAppRuntimeTests` passed after adding `PlainpostAppRuntime`, Application Support SQLite migration, Keychain-backed account setup composition, shared store-backed UI services, and notification scheduler injection for tests.
- 2026-07-09 07:28: `rtk swift build --product PlainpostApp` passed with the app entry point booting through the production runtime.
- 2026-07-09 07:28: `rtk swift test --filter PlainpostUITests` passed 36 UI tests with 0 failures.
- 2026-07-09 07:29: `rtk swift test` passed 208 tests with 0 failures.
- 2026-07-09 07:29: `rtk swift build -c release` passed.
- 2026-07-09 07:29: `rtk git diff --check` passed with no output.
- 2026-07-09 07:35: `rtk swift test --filter PlainpostAppRuntimeTests/testRuntimeInboxActionsUseStoredIMAPCredentials` failed red because runtime inbox actions only mutated SQLite and did not update local IMAP flags/archive/delete state.
- 2026-07-09 07:35: `rtk swift test --filter PlainpostAppRuntimeTests/testRuntimeInboxActionsUseStoredIMAPCredentials` passed after runtime inbox actions resolved the stored account plus Keychain IMAP password and delegated to the IMAP-backed action service.
- 2026-07-09 07:36: `rtk swift test --filter PlainpostAppRuntimeTests` passed 3 runtime tests with 0 failures.
- 2026-07-09 07:36: `rtk swift test --filter PlainpostUITests` passed 37 UI tests with 0 failures.
- 2026-07-09 07:36: `rtk swift build --product PlainpostApp` passed.
- 2026-07-09 07:36: `rtk swift test` passed 209 tests with 0 failures.
- 2026-07-09 07:37: `rtk swift build -c release` passed.
- 2026-07-09 07:37: `rtk git diff --check` passed with no output.
- 2026-07-09 07:41: `rtk swift test --filter PlainpostAppRuntimeTests/testRuntimeApprovalUsesStoredSMTPCredentials` failed red because runtime approval still used `UnconfiguredRuntimeSMTPClient`.
- 2026-07-09 07:43: `rtk swift test --filter PlainpostAppRuntimeTests/testRuntimeApprovalUsesStoredSMTPCredentials` passed after runtime approval resolved stored SMTP/IMAP credentials and fixed local Sent-copy mailbox paths.
- 2026-07-09 07:43: `rtk swift test --filter PlainpostAppRuntimeTests` passed 4 runtime tests with 0 failures.
- 2026-07-09 07:43: `rtk swift test --filter PlainpostUITests` passed 38 UI tests with 0 failures.
- 2026-07-09 07:43: `rtk swift build --product PlainpostApp` passed.
- 2026-07-09 07:43: `rtk swift test` passed 210 tests with 0 failures.
- 2026-07-09 07:44: `rtk swift build -c release` passed.
- 2026-07-09 07:44: `rtk git diff --check` passed with no output.
- 2026-07-09 07:50: `rtk swift test --filter LaunchAgentPlistTests/testLaunchAgentPlistRunsPersistentServiceWithoutSecrets` failed red because `PlainpostLaunchAgentConfiguration` and `PlainpostLaunchAgentPlist` did not exist.
- 2026-07-09 07:50: `rtk swift test --filter PlainpostCLIHarnessTests/testPlainpostCLILaunchAgentInstallWritesSecretSafePlistWithoutLoading` failed red at compile time for the same missing LaunchAgent plist API.
- 2026-07-09 07:50: both focused LaunchAgent tests passed after adding the shared plist generator and `plainpost service launch-agent install/status --json`.
- 2026-07-09 07:51: `rtk swift test --filter PlainpostCoreTests` passed 26 tests with 0 failures.
- 2026-07-09 07:51: `rtk swift test --filter PlainpostCLIHarnessTests` passed 56 tests with 0 failures.
- 2026-07-09 07:52: `rtk swift test` passed 212 tests with 0 failures.
- 2026-07-09 07:52: `rtk swift build -c release` passed.
- 2026-07-09 07:52: `rtk git diff --check` passed with no output.
- 2026-07-09 07:55: `rtk swift test --filter TransportSecurityPolicyTests` failed red because `MailTransportSecurityPolicy` did not exist.
- 2026-07-09 07:56: `rtk swift test --filter TransportSecurityPolicyTests` passed 4 security tests after adding loopback-only cleartext policy and wiring plaintext IMAP/SMTP clients through it.
- 2026-07-09 07:56: `rtk swift test --filter PlainpostCLIHarnessTests/testAccountTestUsesLocalIMAPAndSMTPHarnesses` passed, proving loopback IMAP/SMTP E2E still works.
- 2026-07-09 07:56: `rtk swift test --filter PlainpostCoreTests` passed 30 tests with 0 failures.
- 2026-07-09 07:57: `rtk swift test` passed 216 tests with 0 failures.
- 2026-07-09 07:57: `rtk swift build -c release` passed.
- 2026-07-09 07:57: `rtk git diff --check` passed with no output.
- 2026-07-09 08:04: `rtk swift test --filter TLSSMTPHarnessTests` failed red because `SecureSMTPClient`, `SMTPClientError.tlsFailed`, and the test-only certificate validation override did not exist.
- 2026-07-09 08:06: `rtk swift test --filter TransportSecurityPolicyTests/testSMTPFactoryUsesSecureClientForRemoteHostsAndPlaintextOnlyForLoopbackHarnesses` failed red because `MailTransportClientFactory` did not exist.
- 2026-07-09 08:06: `rtk swift test --filter TLSSMTPHarnessTests` passed after adding implicit TLS SMTP, default certificate validation, and an explicit local-test trust override.
- 2026-07-09 08:06: `rtk swift test --filter TransportSecurityPolicyTests/testSMTPFactoryUsesSecureClientForRemoteHostsAndPlaintextOnlyForLoopbackHarnesses` passed after adding SMTP transport factory selection.
- 2026-07-09 08:06: `rtk swift test --filter PlainpostCLIHarnessTests/testAccountTestUsesLocalIMAPAndSMTPHarnesses` passed after production SMTP factory wiring preserved loopback harness behavior.
- 2026-07-09 08:06: `rtk swift test --filter PlainpostCoreTests` passed 31 tests with 0 failures.
- 2026-07-09 08:07: `rtk swift test` passed 219 tests with 0 failures.
- 2026-07-09 08:07: `rtk swift build -c release` passed.
- 2026-07-09 08:07: `rtk git diff --check` passed with no output.
- 2026-07-09 08:12: `rtk swift test --filter TLSSMTPHarnessTests/testStartTLSClientUpgradesBeforeAuthenticationAndSendsThroughHarness` failed red because `StartTLSSMTPClient` did not exist.
- 2026-07-09 08:12: `rtk swift test --filter TransportSecurityPolicyTests/testSMTPFactoryUsesSecureClientsForRemoteSubmissionPortsAndPlaintextOnlyForLoopbackHarnesses` failed red because `StartTLSSMTPClient` did not exist and port 587 was not routed through STARTTLS.
- 2026-07-09 08:14: `rtk swift test --filter TLSSMTPHarnessTests/testStartTLSClientUpgradesBeforeAuthenticationAndSendsThroughHarness` passed after adding the STARTTLS upgrade client and local STARTTLS SMTP harness.
- 2026-07-09 08:14: `rtk swift test --filter TransportSecurityPolicyTests/testSMTPFactoryUsesSecureClientsForRemoteSubmissionPortsAndPlaintextOnlyForLoopbackHarnesses` passed after routing remote port 587 through `StartTLSSMTPClient`.
- 2026-07-09 08:14: `rtk swift test --filter TLSSMTPHarnessTests` passed 3 TLS SMTP harness tests with 0 failures.
- 2026-07-09 08:14: `rtk swift test --filter PlainpostCLIHarnessTests/testAccountTestUsesLocalIMAPAndSMTPHarnesses` passed after preserving loopback account-test routing.
- 2026-07-09 08:14: `rtk swift test --filter PlainpostCoreTests` passed 31 tests with 0 failures.
- 2026-07-09 08:15: `rtk swift test` passed 220 tests with 0 failures.
- 2026-07-09 08:15: `rtk swift build -c release` passed.
- 2026-07-09 08:15: `rtk git diff --check` passed with no output.
- 2026-07-09 08:20: `rtk swift test --filter IMAPHarnessTests/testSecureIMAPClientUsesImplicitTLSHarnessWithExplicitTestTrustOverride` failed red because `SecureIMAPClient` and IMAP factory routing did not exist.
- 2026-07-09 08:20: `rtk swift test --filter TransportSecurityPolicyTests/testIMAPFactoryUsesSecureClientForRemoteImplicitTLSPortAndPlaintextOnlyForLoopbackHarnesses` failed red because `SecureIMAPClient` and `MailTransportClientFactory.imapClient` did not exist.
- 2026-07-09 08:22: `rtk swift test --filter IMAPHarnessTests/testSecureIMAPClientUsesImplicitTLSHarnessWithExplicitTestTrustOverride` passed after adding the shared IMAP session, implicit TLS socket provider, and local TLS IMAP harness.
- 2026-07-09 08:22: `rtk swift test --filter IMAPHarnessTests/testSecureIMAPClientRejectsSelfSignedCertificateByDefault` passed, proving default certificate validation rejects the self-signed local TLS harness.
- 2026-07-09 08:22: `rtk swift test --filter TransportSecurityPolicyTests/testIMAPFactoryUsesSecureClientForRemoteImplicitTLSPortAndPlaintextOnlyForLoopbackHarnesses` passed after routing remote port 993 through `SecureIMAPClient`.
- 2026-07-09 08:22: `rtk swift test --filter IMAPHarnessTests` passed 11 IMAP harness tests with 0 failures.
- 2026-07-09 08:22: `rtk swift test --filter PlainpostCLIHarnessTests/testAccountTestUsesLocalIMAPAndSMTPHarnesses` passed after preserving loopback account-test routing.
- 2026-07-09 08:22: `rtk swift test --filter PlainpostCoreTests` passed 32 tests with 0 failures.
- 2026-07-09 08:23: `rtk swift test` passed 223 tests with 0 failures.
- 2026-07-09 08:23: `rtk swift build -c release` passed.
- 2026-07-09 08:23: `rtk git diff --check` passed with no output.
- 2026-07-09 08:26: `rtk swift test --filter IMAPHarnessTests/testStartTLSIMAPClientUpgradesBeforeLoginAndUsesHarness` failed red because `StartTLSIMAPClient` did not exist.
- 2026-07-09 08:26: `rtk swift test --filter TransportSecurityPolicyTests/testIMAPFactoryUsesSecureClientForRemoteImplicitTLSPortAndPlaintextOnlyForLoopbackHarnesses` failed red because remote port 143 was not routed through STARTTLS IMAP.
- 2026-07-09 08:27: `rtk swift test --filter IMAPHarnessTests/testStartTLSIMAPClientUpgradesBeforeLoginAndUsesHarness` passed after adding `StartTLSIMAPClient`, the STARTTLS socket provider, and the local STARTTLS IMAP harness.
- 2026-07-09 08:27: `rtk swift test --filter TransportSecurityPolicyTests/testIMAPFactoryUsesSecureClientForRemoteImplicitTLSPortAndPlaintextOnlyForLoopbackHarnesses` passed after routing remote port 143 through `StartTLSIMAPClient`.
- 2026-07-09 08:27: `rtk swift test --filter IMAPHarnessTests` passed 12 IMAP harness tests with 0 failures.
- 2026-07-09 08:27: `rtk swift test --filter PlainpostCLIHarnessTests/testAccountTestUsesLocalIMAPAndSMTPHarnesses` passed after preserving loopback account-test routing.
- 2026-07-09 08:27: `rtk swift test --filter PlainpostCoreTests` passed 32 tests with 0 failures.
- 2026-07-09 08:28: `rtk swift test` passed 224 tests with 0 failures.
- 2026-07-09 08:29: `rtk swift build -c release` passed.
- 2026-07-09 08:29: `rtk git diff --check` passed with no output.
- 2026-07-09 08:33: `rtk swift test --filter MailTLSSettingsTests/testSSLSettingsPinTLS12MinimumWithSystemTrust` failed red because `MailTLSSettings` did not exist.
- 2026-07-09 08:34: `rtk swift test --filter MailTLSSettingsTests` passed 2 TLS settings tests after adding the shared CFStream SSL settings helper.
- 2026-07-09 08:35: `rtk swift test --filter TLSSMTPHarnessTests/testSecureSMTPClientRejectsTLS11OnlyServerEvenWithLocalTrustOverride` passed after adding the TLS 1.0/1.1-only SMTP harness mode and applying the TLS 1.2 floor.
- 2026-07-09 08:35: `rtk swift test --filter TLSSMTPHarnessTests` passed 4 SMTP TLS harness tests with 0 failures.
- 2026-07-09 08:35: `rtk swift test --filter IMAPHarnessTests` passed 12 IMAP harness tests with 0 failures after the shared TLS settings refactor.
- 2026-07-09 08:35: `rtk swift test --filter PlainpostCoreTests` passed 34 tests with 0 failures.
- 2026-07-09 08:36: `rtk swift test` passed 227 tests with 0 failures.
- 2026-07-09 08:36: `rtk swift build -c release` passed.
- 2026-07-09 08:36: `rtk git diff --check` passed with no output.
- 2026-07-09 08:37: Stage 107 acceptance audit mapped every original MVP acceptance criterion to implemented stage evidence in `docs/progress.md`.
- 2026-07-09 08:37: final `rtk git diff --check` passed with no output after documentation updates.
- 2026-07-10 14:17: `rtk swift test --filter PlainpostTemporalContractTests` passed configuration, workflow ID, payload privacy, local artifact, and secret-safe LaunchAgent tests.
- 2026-07-10 14:25: with `temporal server start-dev --headless` running, `PLAINPOST_TEMPORAL_E2E=1 rtk swift test --filter PlainpostTemporalContractTests/localTemporalRoundTrip` passed a real typed AI workflow and an approval-send workflow; a repeated approval still produced exactly one accepted local SMTP message.
- 2026-07-10 14:31: `rtk swift build --triple arm64-apple-ios18.0-simulator --sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk --target PlainpostTemporal` passed.
- 2026-07-10 14:41: `rtk swift test --filter TemporalUIAdapterTests` passed durable composer routing and local AI artifact UI adapter coverage.
- 2026-07-10 14:45: `rtk swift test` passed 305 XCTest cases plus 7 Swift Testing cases with 0 failures.
- 2026-07-10 14:47: focused Temporal contract and SQLite artifact persistence tests passed after the final warning cleanup.
- 2026-07-10 14:48: `rtk swift build -c release` passed after all Stage 108 code and documentation changes.
- 2026-07-10 16:15: `rtk swift test --filter LocalOperationsTests` passed durable enqueue/idempotency, finite lease recovery, sync preference, and FTS coverage.
- 2026-07-10 16:15: `rtk swift test --filter WakeSignalTests` passed opaque-token validation, duplicate/coalesced wake handling, channel validation, and schema privacy coverage.
- 2026-07-10 16:19: `rtk swift test --filter IMAPSyncCacheTests` passed 16 tests including default recent-100 and complete-history downloads.
- 2026-07-10 16:26: focused approval, operation, LaunchAgent, runtime, and CLI/service compatibility suites passed after canonical-ID migration and local job routing.
- 2026-07-10 16:27: `PlainpostOperations` and `PlainpostDeviceSync` both compiled for `arm64-apple-ios18.0-simulator` against the iPhoneSimulator 26.5 SDK.
- 2026-07-10 16:27: `rtk swift build -c release`, debug app/agent product builds, and `rtk bash Scripts/package-app-bundle.sh` passed; the package contains both executables.
- 2026-07-10 16:27: an idle `PlainpostBackgroundAgent` smoke process measured 12,528 KB RSS and 0.0% CPU in a point-in-time `ps` snapshot. Debug binary sizes were 16.9 MB for `PlainpostApp` and 9.9 MB for the agent.
- 2026-07-10 16:36: `rtk swift test` passed 326 XCTest cases with 0 failures after the final compatibility and Keychain-harness rerun.
- 2026-07-10 16:46: after review hardening added lease heartbeats, non-spinning waiters, bounded server-side UID delta searches, active-sync overlap suppression, one-hour terminal-job pruning, reliable sync writes, and legacy-message FTS backfill, `rtk swift test` again passed all 326 tests; release and iOS shared-target builds plus `rtk git diff --check` also passed.
- 2026-07-10 17:31: focused IMAP/SQLite review suite passed 46 tests, including implicit TLS, STARTTLS, IDLE/DONE, cancellation interrupt, UIDVALIDITY replacement-baseline suppression, atomic incoming commits, flags, and expunges.
- 2026-07-10 17:37: transport/device/operation focused suite passed 14 tests after replacing custom channel encryption with TLS 1.3 PSK, adding 32-byte bearer pairing, Keychain-persistent identities/pairings, CloudKit subscription modes, and a durable wake outbox.
- 2026-07-10 17:38: the iPhone 17 Pro / iOS 26.5 simulator app target built successfully with its default Debug configuration and no signing; it produced an arm64 `Plainpost.app` using the local package products.
- 2026-07-10 17:38: the macOS app and proper embedded background-helper bundle were signed with the available Apple Development identity; `codesign --verify --deep --strict` passed and the embedded SMAppService LaunchAgent plist uses `BundleProgram`.
- 2026-07-10 17:38: the signed embedded helper measured 13,968 KB RSS and 0.0% CPU in a point-in-time `ps` snapshot after IDLE supervision and CloudKit outbox integration.
- 2026-07-10 17:41: final `rtk swift test` and `rtk git diff --check` both passed after review fixes; no test failures or whitespace errors remained.
- 2026-07-10 17:48: after final baseline-retry, atomic wake-token outbox, RFC Message-ID canonicalization, watcher-token, session-lock, and pairing-secret rotation fixes, the full Swift suite, release build, default iPhone 17 Pro simulator build, signed release bundle verification, and diff check all passed in one gate.
- 2026-07-10 18:54: completed the macOS 26 native redesign across the main mail workspace, reader, AI inspector, command center, approvals, compose, Settings, account setup, diagnostics, privacy, notifications, storage, and empty states. The app now requires macOS 26, uses native split views/lists/toolbars/search/scenes with selective Liquid Glass, and follows system light/dark appearance.
- 2026-07-10 18:54: final visual QA generated 132 Retina snapshots covering 22 states in light and dark appearance at 1600x1000, 1180x720, and 900x640 logical sizes under `output/macos26-redesign-final`.
- 2026-07-10 18:54: `rtk swift test` passed 339 tests, final `PlainpostUITests` passed 98 tests, debug and release app builds passed, `rtk git diff --check` passed, and the signed packaged `.build/Plainpost.app` passed strict deep codesign verification with minimum macOS 26.0.
- 2026-07-10 23:53: the reference-led macOS 26 refinement pass reorganized the sidebar into Favorites/Library/Agent sections with a privacy footer, moved inbox modes/sync/compose into a compact native list control strip, reserved the unified toolbar for message actions, tightened the reader hierarchy, and limited additional Liquid Glass to actionable or transient controls.
- 2026-07-10 23:53: fresh before/after visual evidence covers 132 states under `output/macos26-design-audit-2026-07-10`; the full suite passed 340 tests, the release build and signed package passed, `git diff --check` passed, and the relaunched app settled at 0.0% CPU after the reader performance fix.
- 2026-07-11 00:09: removed the remaining open-message hitch by preserving the HTML reader across mark-read/store refreshes, coalescing WebKit height reports, and making on-device summaries explicitly user-triggered instead of starting whenever a message opens.
- 2026-07-11 00:09: `rtk swift test` passed 341 tests with 0 failures; debug app/helper builds, app packaging, strict deep codesign verification, and `rtk git diff --check` passed. The relaunched packaged app (PID 21970) settled at 0.0% CPU and 69,200 KB RSS in a point-in-time idle sample.
- 2026-07-11 00:21: the next macOS 26 refinement pass renamed model-driven categories as Smart Mailboxes, made narrow reader headers truncate sender identity cleanly instead of wrapping it into unusable columns, and rebuilt the AI inspector as a selective-glass task surface with explicit context, provider, and privacy details.
- 2026-07-11 00:21: visual QA rendered and sampled all 138 states (23 screens across six light/dark sizes) under `output/macos26-continuation-2026-07-11/after-full`, including side-by-side reference, compact, and inspector comparisons. All 100 `PlainpostUITests` passed; app/helper builds, package signing, strict deep verification, and `git diff --check` passed. The full 341-test suite exposed one unrelated temporary-file cleanup race in the hanging-service harness; its service behavior and the neighboring persistent-service test passed independently.
- 2026-07-11 00:22: relaunched the packaged app after the refinement; PID 58265 settled at 0.0% CPU and 69,296 KB RSS in a point-in-time idle sample.
- 2026-07-11 00:37: refined the macOS 26 information architecture around a native expandable account hierarchy, widened the compact reader, removed a redundant toolbar action, and kept Liquid Glass on the system-owned sidebar/inspector layers while using standard content material inside the AI summary.
- 2026-07-11 00:37: removed the remaining large-HTML email opening stall by moving blocking IMAP mark-read socket work off the main actor, reducing selection refreshes to one SQLite snapshot per collection, and preparing newsletter HTML off the UI thread with stale-selection cancellation.
- 2026-07-11 00:37: visual QA completed all 144 states (24 screens across six light/dark sizes) under `output/macos26-structure-refinement-2026-07-11/after-full`. All 101 `PlainpostUITests` passed, including a new rapid-selection WebKit regression; debug app/helper builds, packaging, strict deep codesign verification, and `git diff --check` passed. The corrected packaged app was relaunched as PID 92196 and settled at 0.0% CPU and 69,104 KB RSS in a point-in-time sample.
- 2026-07-11 00:51: redesigned the thread reader as a native conversation surface: older messages collapse into sender/date rows, the selected message stays expanded, compact layouts drop secondary dates before truncating identity, reply remains available in the active message header and toolbar, and inactive HTML messages no longer instantiate WebKit renderers.
- 2026-07-11 00:51: current-run Product Design evidence compared the supplied mail and macOS 26 Liquid Glass references with the implemented app under `output/macos26-design-audit-2026-07-11`; final visual QA rendered 150 states (25 screens across six light/dark sizes) under `output/macos26-conversation-refinement-2026-07-11/after-full`. All 101 `PlainpostUITests`, app/helper builds, signed packaging, strict deep codesign verification, and `git diff --check` passed. The relaunched app (PID 20169) settled at 0.0% CPU and 69,040 KB RSS.
- 2026-07-11 01:03: simplified the composer around progressive disclosure: the default draft now shows only To and Subject, Cc/Bcc are one-click controls beside To, populated optional recipient fields remain expanded, and reveal motion respects Reduce Motion. The actual compose scene continues to use native macOS toolbar status, Save Draft, and Send actions.
- 2026-07-11 01:03: current-run compose and approval evidence is under `output/macos26-compose-approval-audit-2026-07-11`; final visual QA rendered 156 states (26 screens across six light/dark sizes) under `output/macos26-compose-refinement-2026-07-11/after-full`. All 102 `PlainpostUITests`, app/helper builds, signed packaging, strict deep codesign verification, and `git diff --check` passed. The relaunched app (PID 46648) measured 0.0% CPU and 69,232 KB RSS.
- 2026-07-11 01:22: refined Liquid Glass ownership using the supplied macOS 26 Control Center reference: Command Center keeps native `glassEffect` with only an ultra-thin system fallback for Reduce Transparency and offscreen rendering, the backdrop dim is lighter, and the remote-image privacy banner now uses a standard content control material instead of navigation-layer glass.
- 2026-07-11 01:22: current-run glass comparison evidence is under `output/macos26-liquid-glass-audit-2026-07-11`; final visual QA rendered all 156 states under `output/macos26-liquid-glass-refinement-2026-07-11/after-full`. All 102 `PlainpostUITests`, app/helper builds, signed packaging, strict deep codesign verification, and `git diff --check` passed. The relaunched app (PID 77795) measured 0.0% CPU and 69,088 KB RSS.
- 2026-07-11 01:43: removed the remaining full-mailbox work from the message-selection path. The runtime now reuses the already-grouped mailbox snapshot while the user moves between conversations, resolves only the selected thread, and invalidates that snapshot after sync, account setup, classification, store notifications, archive/delete, or other mailbox mutations.
- 2026-07-11 01:43: the new snapshot-invalidation regression passed, all 103 `PlainpostUITests` passed, and the complete Swift suite passed after correcting the public fresh-projection path exposed by the first E2E rerun. Visual QA rendered all 156 states under `output/macos26-selection-performance-2026-07-11/after-full`; app/helper builds, packaging, strict deep codesign verification, and `git diff --check` passed. The packaged app was relaunched as PID 29860 and measured 0.0% CPU and 69,104 KB RSS in a point-in-time sample.
- 2026-07-11 02:08: replaced the inbox list's permanent bright divider with a pinned control inset plus SwiftUI's native macOS 26 hard scroll-edge effect. The effect now appears only when scrolling content needs separation; the inbox mode, sync, compose, section header, and selection geometry remain unchanged. The rejected `safeAreaBar` experiment was removed after it logged layout recursion in the packaged app.
- 2026-07-11 02:08: assigned the main window a stable `main` scene ID and explicit presented launch behavior so future builds do not depend on compiler-generated restoration identifiers. Current-run before/after evidence is under `output/macos26-scroll-edge-audit-2026-07-11`, and the final 156-state matrix is under `output/macos26-scroll-edge-refinement-2026-07-11/after-full`. All 103 `PlainpostUITests`, app/helper builds, signed packaging, strict deep codesign verification, and `git diff --check` passed. The final packaged app was opened as PID 15076 with one verified on-screen layer-0 window; it settled to 0.0% CPU and 164,960 KB RSS with the WebKit reader loaded.
- 2026-07-11 02:22: removed the remaining first-open HTML hitch observed on the 49 KB Homegate message with 52 blocked images. Single-message selections now retain their reader slot so SwiftUI updates the existing `WKWebView`, reuse one non-persistent WebKit data session, and reset the previous document height before the replacement finishes. The new private-session regression and existing rapid-selection regression passed; the complete suite passed 345 tests with 0 failures. Full output is in `output/email-open-performance-2026-07-11/swift-test.log`; app/helper builds, signed packaging, strict deep codesign verification, and `git diff --check` passed.
- 2026-07-11 02:44: completed the macOS 26 accessibility appearance pass. Category badges now use semantic system colors with readable label text and stronger increased-contrast outlines; the Command Center preserves Liquid Glass normally but switches to an opaque, bordered surface for Reduce Transparency; conversation and overlay transitions honor Reduce Motion. The snapshot harness now covers standard, increased-contrast, and reduced-transparency/reduced-motion appearances in both light and dark themes. Current-run audit evidence is under `output/macos26-accessibility-audit-2026-07-11`, and the final matrix contains all 260 expected states under `output/macos26-accessibility-refinement-2026-07-11/after-full`. The complete suite passed 345 tests with 0 failures, release/debug builds passed, signed packaging and strict deep codesign verification passed, and `git diff --check` passed. The packaged process launched as PID 95633 and settled at 0.0% CPU; CoreGraphics reported no layer-0 on-screen window because this development account still has a stale AppKit restoration record, so visible-window launch is not claimed.
- 2026-07-11 03:26: traced the remaining Homegate open-message lag to its 13-message conversation: selection synchronously sanitized 625,139 bytes of HTML even though only one message was expanded. Runtime conversation models now keep bodies deferred, preserve lightweight remote-image privacy metadata, render only expanded bodies on a background actor, cancel stale view work, and cache the 64 most recently prepared bodies.
- 2026-07-11 03:26: the new 13-message/large-HTML regression completed its full setup and selection assertion in 0.020 seconds, the deferred-cache and complete WebKit reader suites passed, and the complete Swift suite passed with 0 failures. Release app/helper builds, signed packaging, strict deep code-sign verification, and `git diff --check` passed. The optimized package was relaunched as PID 81134; CoreGraphics verified one on-screen layer-0 window at 1296x811, and the settled process sampled at 0.0% CPU and 130,048 KB RSS.
- 2026-07-11 03:51: completed the native-shell refinement identified by the current-run macOS 26 comparison. Plainpost now has a checked-in Xcode macOS application target and shared scheme, packages the Xcode-produced app instead of wrapping a raw SwiftPM executable, uses a singleton SwiftUI mailbox scene plus native compose and Settings scenes, and recovers from the legacy invalid AppKit restoration record by invoking SwiftUI's own `Open Mailbox Window` command rather than creating a parallel AppKit-hosted window.
- 2026-07-11 03:51: stabilized the unified mailbox toolbar so Reply, Archive, Delete, More, and AI Summary keep consistent positions and disabled states when selection changes, while Command Center remains a secondary action. Current-run large, standard, and compact light/dark mailbox and conversation evidence is under `output/macos26-native-shell-refinement-2026-07-11/after`; comparison used the supplied Mail and macOS 26 references in the same inspection pass.
- 2026-07-11 03:51: the complete Swift suite passed with 0 failures, the focused root-view test passed, the native Xcode Debug and Release application builds passed, the release helper built, `git diff --check` passed, and the release package passed strict deep code-sign verification with the Apple Development identity. The signed 11.1 MB release app was relaunched as PID 80744; CoreGraphics verified one on-screen layer-0 mailbox window at 1296x810, and the settled process sampled at 0.0% CPU and 135,184 KB RSS.
- 2026-07-11 09:36: tightened the large-conversation selection path after live Homegate feedback. Native list selection now commits before reader projection work, mailbox snapshots retain a chronological thread index instead of filtering and regrouping every message on each click, remote-image detection reuses its compiled regex, and the AI session fingerprint uses bounded body samples instead of copying the full email body on the main actor.
- 2026-07-11 09:36: the 13-message/large-HTML runtime regression completed in 0.019 seconds, the focused runtime/view/renderer suites and complete Swift suite passed with 0 failures, the release helper and native Xcode app built, strict deep code-sign verification and `git diff --check` passed. The corrected signed package was reopened as PID 22427; CoreGraphics verified one on-screen layer-0 window at 1440x900, and the settled process sampled at 0.0% CPU and 133,808 KB RSS.
- 2026-07-11 09:48: continued the macOS 26 control-layer audit against the supplied Mail and Liquid Glass references plus current Apple guidance. Reply now has its own toolbar intent, Archive and Delete form one related native control group, and New Message, navigation, search, Command Center, mailbox-window, and Save Draft commands use SF Symbols so menus scan in one consistent icon column. No additional content-layer glass was introduced.
- 2026-07-11 09:48: the focused root-view regression, complete Swift suite, native Xcode Debug/Release app builds, release helper build, strict deep code-sign verification, and `git diff --check` passed. The signed package was reopened as PID 41485; CoreGraphics verified one on-screen layer-0 window at 1296x810, and the settled process sampled at 0.0% CPU and 135,344 KB RSS. Current comparison captures are under `output/macos26-continuation-audit-2026-07-11/current`. A layered macOS 26 app icon remains pending the user's selection from the three generated directions.
- 2026-07-11 10:01: the compact-window audit found and fixed a severe Agent Approval layout failure: the request title and authentication context previously collapsed into one-character columns and the decision controls truncated at 900x640. The detail header and review bar now use `ViewThatFits` to preserve the normal horizontal layout when space permits and switch to readable stacked status plus full-width Authenticate & Send / Don't Send controls at compact widths.
- 2026-07-11 10:01: inspected paired light/dark before-and-after approval captures under `output/macos26-compact-audit-2026-07-11`; the fixed compact states preserve the subject, requester, authentication badge, recipient/message context, safety explanation, and both decisions without shrinking type. The focused approval smoke regression and complete Swift suite passed with 0 failures; release app/helper builds, strict deep code-sign verification, and `git diff --check` passed. The signed package was reopened as PID 49374 with one verified 1296x810 on-screen layer-0 window and sampled at 0.0% CPU / 135,536 KB RSS.
- 2026-07-11 10:09: completed the keyboard-first interaction pass. Command Center already focuses search on open and supports arrows, Return, and Escape; the native mailbox Reply action now uses ⌘R, the Compose scene saves with ⌘S, and Send uses the standard Mail-style ⇧⌘D shortcut. Matching help text exposes each shortcut without adding visual controls. Approval Send/Deny deliberately remain explicit review actions with no global default shortcut.
- 2026-07-11 10:09: the focused root-view regression and complete Swift suite passed with 0 failures; native Xcode Debug/Release app builds, release helper build, strict deep code-sign verification, and `git diff --check` passed. The signed package was reopened as PID 56306 with one verified 1296x810 on-screen layer-0 window and sampled at 0.0% CPU / 135,312 KB RSS.
- 2026-07-11 10:29: removed the remaining main-actor work from live email selection. The cached mailbox snapshot is now projected into the selected 13-message conversation on a background executor, including remote-image metadata scanning, while the native list selection stays responsive. Generation and cancellation guards prevent an older large newsletter from replacing a newer rapid selection.
- 2026-07-11 10:29: the three focused async-selection/race regressions and the complete Swift suite passed with 0 failures; the native macOS 26 Release app and helper built, signed packaging passed strict deep code-sign verification, and `git diff --check` passed. The corrected package was reopened as PID 74834 with one verified 1296x810 on-screen layer-0 window and sampled at 0.0% CPU / 147,408 KB RSS with the WebKit reader loaded.
- 2026-07-11 10:48: the macOS 26 completion audit compared the three supplied references and fresh mailbox/reader/Command Center captures together, then closed three remaining P2 accessibility gaps: production message rows now expose complete read/selected/date/category/preview context, Command Center contains keyboard and VoiceOver interaction while open, and approval status changes post native accessibility announcements.
- 2026-07-11 10:48: generated and inspected 72 current audit states plus 16 post-fix states under `output/macos26-completion-audit-2026-07-11`; the complete Swift suite passed with 0 failures, the release app/helper and signed package built, strict deep code-sign verification and `git diff --check` passed. The final package was reopened as PID 96539 with one verified 1296x810 on-screen layer-0 window and sampled at 0.0% CPU / 147,216 KB RSS. `design-qa.md` remains blocked only on a user-selected production icon plus Screen Recording/real VoiceOver evidence.

## 2026-07-12 Current-State Audit and Forward Plan

### Verified Current State

- [x] The renamed Plainpost Swift package resolves successfully and exposes 17 library and executable products.
- [x] The codebase contains 148 Swift files, approximately 34,944 source lines, 15,557 test lines, and 443 XCTest methods.
- [x] `rtk swift test` passed all 443 tests with 0 failures in 50.8 seconds on 2026-07-12.
- [x] `rtk swift build -c release` passed on 2026-07-12.
- [x] The native macOS `PlainpostApp` Xcode Debug build passed with code signing disabled on 2026-07-12.
- [x] `rtk git diff --check` passed on 2026-07-12.
- [x] The current implementation includes a native macOS SwiftUI app, local IMAP/SMTP, SQLite/GRDB persistence, Keychain credentials, durable local operations, a background helper, local AI and retrieval, CLI and MCP surfaces, approval-gated agent sending, audit logs, and local protocol harnesses.
- [x] Cleartext remote mail transport is rejected, production IMAP/SMTP paths use implicit TLS or STARTTLS, and the TLS floor is 1.2 or newer.
- [x] The only resolved third-party Swift dependency, GRDB 7.11.1, is recorded at revision `b83108d10f42680d78f23fe4d4d80fc88dab3212` in `Package.resolved`.

### Findings and Risks

- [ ] **Finish the MailAgent-to-Plainpost Git migration.** The working tree currently represents the rename as 395 tracked deletions, 250 untracked paths, and 15 modified files. The renamed code builds and tests, but the repository state is difficult to review, merge, recover, or release until the moves are recorded cleanly.
- [ ] **Replace harness-only confidence with real-provider acceptance.** The local IMAP, SMTP, TLS, CLI, MCP, database, operation-runtime, AI, and UI coverage is extensive, but Gmail, iCloud Mail, Fastmail, and a generic standards-oriented IMAP server have not completed a repeatable production smoke matrix.
- [ ] **Add modern provider authentication.** SMTP currently uses `AUTH PLAIN`, IMAP uses `LOGIN`, and guided Gmail setup uses an app password. OAuth 2.0/XOAUTH2 is required before broad consumer distribution; app passwords can remain as an explicit manual fallback.
- [ ] **Add continuous integration.** No GitHub Actions, Forgejo Actions, or equivalent workflow is present. Tests, release compilation, native Xcode compilation, packaging checks, and diff validation currently depend on local execution. Every third-party CI action must be pinned to an immutable commit SHA rather than a tag or branch.
- [ ] **Reduce large-file maintenance hotspots.** The largest production files are `PlainpostCLI.swift` at 3,282 lines, `SQLiteMailStore.swift` at 2,465 lines, `PlainpostSettingsViews.swift` at 1,796 lines, `PlainpostSharedViews.swift` at 1,611 lines, `PlainpostInboxViews.swift` at 1,603 lines, `PlainpostService/main.swift` at 1,482 lines, and `PlainpostAI.swift` at 1,372 lines.
- [ ] **Consolidate app runtime ownership.** The mailbox window, composer window, and Settings scene each create an `PlainpostAppRuntime`, which opens the same database and constructs separate stores, Keychain adapters, and operation clients. GRDB supports concurrent access, but one process-level runtime/container would give clearer lifecycle, observation, cancellation, and helper ownership.
- [ ] **Clarify and harden the helper boundary.** CLI and MCP benefit from the existing stdio JSONL bridge, while the packaged macOS app would benefit from a typed, versioned XPC interface for helper communication, cancellation, reconnect, and authorization.
- [ ] **Persist per-agent permissions.** Agent permissions are enforced, but their production configuration is primarily process-environment based. Persisted per-agent grants, safe defaults, revocation, and an auditable Settings surface remain incomplete.
- [ ] **Complete multi-account behavior.** Account storage and account-aware replies exist, but richer account selection, unified-inbox filtering, per-account status, sender identity, signatures, and reliable action routing remain future work.
- [ ] **Complete inbound attachment handling.** MIME parsing and attachment metadata exist, and outgoing attachments are rendered safely, but inbound download, bounded storage, preview, open/save, cleanup, and optional AI indexing are incomplete.
- [ ] **Complete server draft reconciliation.** Server Drafts append and remote UID persistence exist through CLI/service/MCP paths, but GUI controls, conflict handling, update/delete propagation, and richer local-versus-server reconciliation remain incomplete.
- [ ] **Complete provider-aware mailbox semantics.** Archive and delete work, but richer Trash moves, mailbox-role discovery, folder moves, custom mailbox management, UIDVALIDITY recovery, and provider-specific behavior need production hardening.
- [ ] **Surface recoverable delivery warnings.** Remote Sent-copy append failure is preserved as a non-fatal warning, but the GUI still needs a clear warning, retry, and resolution workflow.
- [ ] **Complete context-aware approval risk.** `external_recipient`, `new_recipient`, and `reply_to_mismatch` require account, contact, and source-thread context before they can be scored accurately. Authentication thresholds and risk policy are not yet user-configurable.
- [ ] **Add database recovery and upgrade guarantees.** Migrations are tested, but release-grade backup, integrity checking, recovery from interrupted migration, and compatibility fixtures for every shipped schema version should be explicit gates.
- [ ] **Resolve compiler warnings.** Two integration-test warnings ignore the return value of `appendMessage(to:flags:data:)` in `IMAPHarnessTests`.
- [ ] **Refresh documentation.** The tracker header and several embedded verification milestones predate the current 443-test suite. A concise root README for architecture, development, testing, packaging, CLI, MCP, data paths, and release operations is also missing.
- [ ] **Make the mobile scope explicit.** Shared modules declare iOS 18 support and `Apps/PlainpostiOS` contains a CloudKit wake/pairing shell, but the Xcode project currently exposes only the macOS application target. The iOS source is not yet a buildable, provisioned mail-client product target.
- [ ] **Re-verify distribution artifacts after the rename.** The current SwiftPM release and unsigned native Debug app build pass, while signed hardened-runtime packaging, notarization, stapling, upgrade, and uninstall behavior were not re-verified during the 2026-07-12 audit.

### Prioritized Fix and Improvement Plan

#### Phase 0 - Repository Stabilization (1-2 days)

- [ ] Record the MailAgent-to-Plainpost migration as reviewable Git renames and intentional content changes.
- [ ] Remove obsolete MailAgent paths and references without deleting unrelated user work.
- [ ] Reconcile duplicated, renamed, or obsolete stage specifications and plans.
- [ ] Update current verification counts and dates throughout this tracker.
- [ ] Add a root README with supported platforms, architecture, prerequisites, local data paths, build/test commands, CLI/MCP setup, packaging, and troubleshooting.
- [ ] Fix the two ignored `appendMessage` return-value warnings.
- [ ] Run `rtk swift test`, `rtk swift build -c release`, native Xcode Debug and Release builds, `rtk git diff --check`, unsigned packaging, and signed packaging when credentials are available.
- [ ] Commit the completed migration using a Conventional Commit message.

**Phase 0 exit criteria:** the working tree is reviewable, the rename is recoverable as Git history, documentation matches the current product, and all local build and test gates pass.

#### Phase 1 - Production Mail Reliability (1-2 weeks)

- [ ] Create opt-in real-provider smoke tests for Gmail, iCloud Mail, Fastmail, and a generic Dovecot-compatible server.
- [ ] Verify account setup, mailbox discovery, initial and incremental sync, reconnect, IDLE wakeup, threading, seen state, archive, Trash, Drafts, Sent append, and SMTP delivery for every provider in the matrix.
- [ ] Implement OAuth 2.0/XOAUTH2, starting with Gmail, while retaining app-password/manual authentication as a fallback.
- [ ] Discover mailbox roles from server capabilities and provider metadata instead of relying only on conventional fixed paths.
- [ ] Handle UIDVALIDITY changes, partial sync interruption, expunges, duplicates, reconnect backoff, rate limits, and transient provider failures without data loss.
- [ ] Add a visible Sent-copy warning and retry workflow.
- [ ] Add database integrity checks, backups before migration, and a safe recovery path.
- [ ] Dogfood multiple real accounts for several days and capture sync/delivery diagnostics without secrets.

**Phase 1 exit criteria:** the supported provider matrix completes repeatable end-to-end scenarios without message loss, duplicate delivery, invisible sync failure, or secret leakage.

#### Phase 2 - Architecture and Delivery Pipeline (1-2 weeks)

- [ ] Introduce one shared process-level runtime/container for mailbox, composer, and Settings scenes.
- [ ] Keep stdio JSONL for CLI/MCP interoperability and introduce a typed, versioned macOS XPC boundary for the packaged helper.
- [ ] Split CLI code by command family and move shared request parsing and JSON response contracts into dedicated modules.
- [ ] Split SQLite storage into migrations, accounts/mailboxes, messages/threads, drafts/sends, durable jobs, AI index, and audit repositories while retaining transaction boundaries.
- [ ] Split large SwiftUI files into feature-owned views and reusable primitives with focused tests.
- [ ] Split IMAP transport, protocol parsing, response models, and mailbox operations into independently testable components.
- [ ] Persist per-agent permissions in SQLite with safe defaults, revocation, Settings controls, and audit entries.
- [ ] Add migration compatibility fixtures for every released schema version.
- [ ] Add CI gates for Swift tests, release builds, native Xcode builds, packaging validation, and `git diff --check`; pin every third-party action to an immutable commit SHA.

**Phase 2 exit criteria:** every branch receives reproducible automated verification, the app owns one runtime per process, helper contracts are versioned, and major feature areas no longer depend on multi-thousand-line files.

#### Phase 3 - Daily Mail Workflow Completeness (2-4 weeks)

- [ ] Add account switching, unified-inbox filtering, per-account error/sync state, sender identity, and signatures.
- [ ] Implement inbound attachment download, bounded cache storage, preview, open/save, cleanup, MIME/size policy, and explicit agent access controls.
- [ ] Keep attachment AI indexing disabled by default and require an explicit local-only opt-in.
- [ ] Add GUI server-draft controls and reconcile local/server create, update, conflict, and delete states.
- [ ] Add provider-aware Archive and Trash destinations, folder moves, custom mailbox management, and an offline action queue with visible retry state.
- [ ] Implement context-aware send risks for external, new, and reply-to-mismatch recipients.
- [ ] Make the approval authentication threshold and risk policy user-configurable within safe bounds.
- [ ] Add user-facing local diagnostic export with redaction and no credentials or message bodies by default.

**Phase 3 exit criteria:** Plainpost can reliably replace a conventional desktop mail client for normal multi-account reading, composing, attachments, drafts, organization, and offline recovery.

#### Phase 4 - macOS Distribution and Mobile Decision (2-4 weeks)

- [ ] Define semantic versioning, release notes, supported upgrade paths, and rollback expectations.
- [ ] Automate hardened-runtime signing, notarization, stapling, packaged-helper validation, and update distribution.
- [ ] Test first launch, upgrade from every released version, database migration, helper installation/restart, application relocation, and uninstall.
- [ ] Decide whether iOS belongs in the next product milestone.
- [ ] If iOS proceeds, add a real Xcode app target, provisioning, registered CloudKit container, promoted schema, physical-device pairing tests, authenticated Mac data-plane transport, and a clearly scoped mobile mail experience.
- [ ] If iOS is deferred, keep shared-module portability tests but remove mobile-product claims from the near-term release plan.

**Phase 4 exit criteria:** the macOS beta is reproducibly signed, notarized, installable, upgradeable, and supportable, and the mobile scope is an explicit committed decision rather than an implicit partial implementation.

### Recommended Execution Order

1. [ ] Finish and commit the Plainpost rename.
2. [ ] Add CI and refresh the developer/release documentation.
3. [ ] Run real-provider dogfooding and fix protocol or data-integrity failures first.
4. [ ] Add OAuth/XOAUTH2 and provider-aware mailbox behavior.
5. [ ] Consolidate runtime ownership and the packaged helper boundary.
6. [ ] Complete multi-account UX, inbound attachments, and draft reconciliation.
7. [ ] Produce and verify a signed, notarized macOS beta.
8. [ ] Reassess iOS investment after the macOS beta reliability targets are met.

### Development Focus

- [ ] Freeze broad feature expansion until Phases 0 and 1 are complete.
- [ ] Prefer reliability, provider compatibility, data integrity, recovery, and maintainability over adding more AI providers or automation surfaces.
- [ ] Keep direct human sends distinct from agent-generated send requests and preserve GUI approval as the only agent-send authorization path.
- [ ] Preserve local-first behavior, secret-safe diagnostics, remote-image blocking, auditable actions, and explicit AI/agent permission boundaries as non-negotiable product constraints.

## Decisions Pending

- Private device delivery: the iOS app target, APNs callback, durable opaque wake handling, Keychain pairing, and per-Mac self-issued P-256 certificate-pinned TLS 1.3 transport primitives are implemented. Production activation still requires the Apple-registered private CloudKit container, matching provisioning profiles, promoted schema, and physical-device tests; Bonjour and Tailscale physical-network discovery/reachability checks remain pending. CloudKit remains an opaque wake hint only; the authenticated mailbox data-plane API is not carried through CloudKit.

- Minimum macOS target: macOS 26.0 as of the completed native redesign on 2026-07-10; shared package modules retain iOS 18 support.
- Spark-like UX direction: use Smart Inbox grouping, quick actions, command center, AI assistant, and clean reading/composer workflows as workflow references without copying Spark branding, assets, exact layouts, or text.
- First AI provider: recommended Ollama adapter plus deterministic disabled/fake provider for tests.
- AI provider selection: Stage 71 adds the local Ollama-compatible provider, Stage 72 exposes CLI/Settings provider status, Stage 73 persists Settings provider selection, Stage 74 lets CLI AI commands execute through selected local providers, Stage 75 moves service-backed AI summary execution behind `PlainpostService`, Stage 76 routes MCP AI summary through that service bridge, Stage 77 moves service-backed AI draft reply behind `PlainpostService`, Stage 78 routes MCP AI draft reply through that service bridge, Stage 79 moves service-backed draft rewrite behind `PlainpostService`, Stage 80 routes MCP AI rewrite through that service bridge, Stage 81 moves service-backed classification behind `PlainpostService`, Stage 82 routes MCP AI classification through that service bridge, Stage 83 moves service-backed semantic search behind `PlainpostService`, and Stage 84 routes MCP AI semantic search through that service bridge; GUI-to-service provider preference sync, automatic fallback priority, streaming output, Foundation Models, llama.cpp, and MLX providers remain future work.
- AI attachment context: recommended off for v1.
- Server drafts: Stage 86 adds direct CLI server Drafts append through IMAP `APPEND`; Stage 87 moves the same behavior behind `PlainpostService` with stored account/Keychain IMAP credentials; Stage 88 exposes the service-backed path as safe MCP `email.sync_draft`; Stage 89 persists and returns remote Drafts mailbox/UID metadata from UIDPLUS APPENDUID. GUI server-draft controls and richer remote-draft reconciliation remain future work.
- Smart categories: recommended local-first categories, optional IMAP keyword sync later.
- MCP timing: recommended after CLI in the same MVP sequence.
- Context-dependent risk flags: `external_recipient`, `new_recipient`, and `reply_to_mismatch` need account/domain/contact or source-message context before they can be scored accurately.
- Production TLS transport: Stage 101 blocks remote cleartext use by limiting the existing plaintext IMAP/SMTP clients to loopback harnesses. Stage 102 adds implicit TLS SMTP with default certificate validation and routes remote port 465 through it. Stage 103 adds STARTTLS SMTP with default certificate validation and routes remote port 587 through it. Stage 104 adds implicit TLS IMAP with default certificate validation and routes remote port 993 through it. Stage 105 adds STARTTLS IMAP with default certificate validation and routes remote port 143 through it. Stage 106 pins the CFStream TLS minimum to TLS 1.2+ across implicit TLS and STARTTLS SMTP/IMAP and rejects a local TLS 1.0/1.1-only SMTP harness before delivery. Full real-provider smoke acceptance remains future work.
- Agent permission persistence: Stages 34-37 use `PLAINPOST_AGENT_READ_BODY=false`, `PLAINPOST_AGENT_CREATE_DRAFTS=false`, `PLAINPOST_AGENT_REQUEST_SEND=false`, `PLAINPOST_AGENT_ADD_LABELS=false`, `PLAINPOST_AGENT_RECATEGORIZE=false`, `PLAINPOST_AGENT_MARK_SEEN=false`, `PLAINPOST_AGENT_USE_AI_SUMMARY=false`, `PLAINPOST_AGENT_USE_AI_DRAFT_REPLY=false`, `PLAINPOST_AGENT_USE_AI_SEMANTIC_SEARCH=false`, and `PLAINPOST_AGENT_USE_AI_CLASSIFICATION=false` as process-level policy inputs for E2E validation; full persisted per-agent permission settings remain future work.
- Inbound attachment model: Stage 49 denies explicit attachment reads for restricted agents; cached inbound attachment metadata, download, storage, and indexing remain future work.
- Latest macOS design APIs: the app now builds against macOS 26, uses native SwiftUI toolbar/search/sidebar/split-view/Settings/window scenes, and applies direct `glassEffect` only to the transient command-center surface.
- 2026-07-11 14:20: selected and integrated the blue Liquid Glass envelope production app icon. The repo now includes a 1024px alpha master, four numbered 1024px depth-layer sources for Icon Composer, a complete ten-size `.iconset`, and compiled `AppIcon.icns`. Xcode copied the resource into the app bundle and emitted `CFBundleIconFile = AppIcon`; the native build, signed package, strict deep signature verification, 16/32/64px visual checks, and complete 349-test Swift suite passed. The signed package was reopened as PID 52490.
- UI mailbox actions: Stage 96 adds icon-backed row actions plus a protocol-backed action view model and local IMAP/metadata service; Stage 98 wires production runtime row actions through stored SQLite account metadata plus Keychain IMAP credentials. A long-running service-backed GUI action handler and richer multi-account UI selection remain future work.
- Configured local data directory persistence and service ownership: Stages 45-47 and 51 give CLI/MCP send queue flows and CLI account setup explicit `--db-path` plus `PLAINPOST_DATA_DIR/Plainpost.sqlite` durable SQLite paths; Stage 54 adds a `PlainpostService --health --json` process boundary, Stage 55 lets that service boundary sync local IMAP into SQLite, Stage 56 lets that service boundary perform GUI-approved SMTP delivery for pending SQLite send requests, Stage 57 lets the service verify account setup, store credentials in Keychain, then sync using SQLite account metadata plus Keychain IMAP credentials, Stage 58 lets service approval send through stored account SMTP metadata plus Keychain SMTP credentials, Stage 59 appends the approved outgoing message to remote IMAP `Sent` through stored account IMAP metadata plus Keychain IMAP credentials, Stage 60 lets `plainpost account sync --use-service` cross a deterministic service executable bridge for stored-credential sync, Stage 61 lets `plainpost account add --use-service` cross the same service bridge for account setup, Stage 62 lets the service create pending send requests without SMTP side effects, Stage 63 lets `plainpost send request --use-service` cross the service bridge for send-request creation, Stage 64 lets MCP `email.request_send` cross the service bridge for send-request creation, Stage 65 lets CLI/MCP send status/cancel cross the service bridge, Stage 66 gives service-mode bridges a production-style Application Support default store, Stage 67 persists distinct account login usernames for stored sync, SMTP approval, and remote Sent append, Stage 68 persists account Sent mailbox paths for local/remote Sent copies, Stage 69 adds a long-running stdio JSONL service loop over the existing service dispatcher, Stage 70 makes live MCP stdio sessions reuse one persistent service loop for service-backed send queue calls with bounded bridge failure handling, Stage 75 starts service-owned AI execution with thread summaries, Stage 76 routes MCP AI summary through the same persistent service bridge, Stage 77 adds service-owned AI draft reply, Stage 78 routes MCP AI draft reply through the same persistent service bridge, Stage 79 adds service-owned AI draft rewrite, Stage 80 routes MCP AI rewrite through the same persistent service bridge, Stage 81 adds service-owned AI classification, Stage 82 routes MCP AI classification through the same persistent service bridge, Stage 83 adds service-owned AI semantic search, Stage 84 routes MCP AI semantic search through the same persistent service bridge, Stage 97 wires `Plainpost.app` through a production runtime that opens Application Support SQLite and composes shared store-backed UI services, Stage 98 wires GUI mailbox row actions through stored Keychain IMAP credentials, Stage 99 wires GUI approval SMTP plus remote Sent append through stored Keychain credentials, and Stage 100 adds secret-safe LaunchAgent plist generation plus `plainpost service launch-agent` install/status packaging. OS XPC interface remains future work.
- Server-side Sent append integration: Stage 52 can append the rendered outgoing message to remote IMAP `Sent` after approved SMTP success when an append client/configuration is supplied; Stage 53 records non-fatal append failures in the audit log and preserves delivered send status; Stage 68 uses each account's configured Sent mailbox path and quotes mailbox names with spaces safely. Richer user-visible retry/warning UI remains future work.
- Durable Smart Inbox batch actions: Stage 40 validates reusable core service behavior against the local TCP IMAP archive flow; Stage 90 routes `plainpost smart-inbox batch ... --use-service` through durable SQLite state, stored Keychain IMAP credentials, and `PlainpostService`; Stage 91 exposes that service-backed path to MCP as safe `email.smart_inbox_batch`. Richer mailbox move persistence and additional batch actions remain future work.
- Durable mailbox actions: Stage 14 validates IMAP mark read/unread, archive, and delete against the local TCP IMAP harness, Stage 92 routes `plainpost mail mark-read/mark-unread ... --use-service` through durable SQLite state and stored Keychain IMAP credentials, Stage 93 exposes the same service-backed seen-state path to MCP `email.mark_seen` for account-backed calls, Stage 94 adds durable mailbox/deleted metadata plus service-backed CLI archive/delete, and Stage 95 exposes service-backed MCP `email.archive` and `email.delete`. Richer Trash move semantics remain future work.
- Local authentication policy: Stage 43 gates approval queue sends with `riskScore >= 45` through LocalAuthentication where available; persisted/user-configurable thresholds and Touch ID-specific policy tuning remain future work.
- 2026-07-12: verified the adaptive macOS System Settings-inspired redesign and fixed its accessibility appearance handling: Settings heroes and groups now honor system and preview reduce-transparency/increased-contrast values with opaque elevated surfaces and stronger high-contrast borders, and the remote-image privacy row uses a visible supported icon. After deleting stale output, the targeted six-screen by six-configuration rerender produced 36 PNGs. Visual inspection covered `dark-standard/02-settings-ai-providers.png`, `light-standard/07-connected-account.png`, `dark-compact/11-notifications.png`, `light-compact/12-local-storage.png`, `dark-increased-contrast/10-security-privacy.png`, and `light-reduced-transparency/13-diagnostics.png`; sidebar width and selection, centered heroes, compact groups, 900x640 control fit, clipping, appearance adaptation, stronger contrast outlines, opaque reduced-transparency surfaces, and the privacy icon were sound. SHA-256 comparison proved all six dark increased-contrast renders differed from their dark-standard peers and all six light reduced-transparency renders differed from their light-standard peers. Focused `swift test --filter PlainpostViewSmokeTests` passed 16 tests with 0 failures; full `swift test --filter PlainpostUITests` passed 152 tests with 0 failures; `swift build --product PlainpostApp`, `swift build --product PlainpostDesignSnapshot`, and `git diff --check` passed.

## 2026-07-14 Browser Extension End-to-End Verification (Automated Complete, Interactive Partial)

- [x] Built and inspected the Chrome MV3 artifact at `Apps/PlainpostBrowserExtension/.output/chrome-mv3` and Firefox/Zen MV2 artifact at `Apps/PlainpostBrowserExtension/.output/firefox-mv2`. Both generated manifests contain only `nativeMessaging` and `storage` permissions and omit host permissions, content scripts, and externally connectable origins.
- [x] `rtk swift test --filter BrowserExtensionLocalAPITests` passed 17 tests with 1 opt-in interactive skip and 0 failures. The suite includes the real native-frame local vertical slice plus regression coverage that preserves caller-owned coordination roots, rejects unsafe aliases and pre-existing fixture children, rolls back partially initialized credentials and servers, reports renamed/replaced owned paths, removes the owned `ready` marker only after identity/type validation with non-recursive `unlink`, leaves the externally created `done` marker untouched, and bounds native-bridge/MCP termination and reap on timeouts, truncated frames, and write failures even when a child ignores `SIGTERM`. Explicit teardown attempts every bridge, server, credential, marker, and owned-directory cleanup step; it reports deterministic path-free aggregates while setup rollback preserves both the primary failure and all cleanup failures. Process cleanup sends observable `SIGTERM`/`SIGKILL` through an injectable `Darwin.kill` wrapper, reports non-benign signal failures, continues to bounded reap, and treats an already-exited `ESRCH` race as success. The slice uses a temporary GRDB store plus only `LocalIMAPServer`, `LocalSMTPServer`, and `LocalOllamaServer`; it proves unread/open/durable remote `\\Seen`/summary/AI draft/send/idempotent replay. The additive MCP `email.read` wire field `message.seen` reports the cached snapshot without mutation; two reads in one MCP stdio session both return `false` for the seeded unread fixture.
- [x] `rtk swift test`, `rtk swift build -c release`, `rtk pnpm --dir Apps/PlainpostBrowserExtension test`, `rtk pnpm --dir Apps/PlainpostBrowserExtension typecheck`, `rtk pnpm --dir Apps/PlainpostBrowserExtension build`, `rtk pnpm --dir Apps/PlainpostBrowserExtension build:firefox`, `rtk pnpm --dir Apps/PlainpostBrowserExtension inspect:manifests`, signed `rtk env PLAINPOST_BUILD_CONFIGURATION=release PLAINPOST_CODESIGN_IDENTITY='Developer ID Application: Oleh Vdovenko (PCQG52JLF9)' bash Scripts/package-app-bundle.sh`, `rtk codesign --verify --deep --strict .build/Plainpost.app`, and `rtk git diff --check` passed. The package script also failed closed as designed when first run without an explicit release signing identity.
- [x] An isolated Chrome-for-Testing 151 MV3 popup smoke passed against the opt-in Swift fixture: cached unread mail rendered while refresh was active, opening persisted seen state, the selected local Ollama provider supplied the summary and AI reply, and one reply was delivered through `LocalSMTPServer`. The post-browser XCTest confirmed one SMTP acceptance containing `Friday`, two local Ollama requests, and durable seen state. No live SMTP server or recipient was contacted.
- [x] Zen 1.21.6b launched with a new temporary Gecko profile and loaded `quick-mail@plainpost.olhapi.com` from the Firefox MV2 artifact through `web-ext` temporary add-on installation. The exact Zen process and temporary profile were removed after the check.
- [x] Standalone Firefox is not installed, so a separate Firefox UI smoke was not run; its production artifact build and manifest inspection passed.
- [x] Recovery states and copy remain covered by extension UI/controller tests. Installed branded Google Chrome 150 accepted the unpacked-extension command-line flags but did not register the extension in its isolated profile, so branded-Chrome interaction and launch-when-closed are not claimed. The full popup workflow is verified in Chrome-for-Testing; Zen is verified through temporary add-on loading, not a second full popup workflow.
- [x] Store signing, store submission, and publication remain externally credentialed release work and are outside this local verification scope.
- [ ] Interactive acceptance remains incomplete until the full workflow, launch-when-closed, and recovery copy are exercised in installed branded Chrome and Zen (or those environments gain a documented supported automation/loading path).

## 2026-07-14 Broad-Review Hardening

- [x] `7573fd8` makes human-open IMAP `\Seen` intent durable: local state survives restart and stale remote-cache writes, matching server observations acknowledge the intent, contrary newer human actions supersede older work, and the production mailbox-flag worker drains/reconciles the durable operation.
- [x] `a89c580` keeps the native browser transport responsive under overlap: admitted requests execute concurrently within a bound, correlated response frames remain serialized, startup and method deadlines are independent and bounded, output failure stops queued forwarding, and accepted server connections/tasks are tracked through shutdown.
- [x] `ac8a40b` coalesces incremental sync per account across concurrent callers and durable job admission while allowing separate accounts to run independently; cancellation of one caller does not cancel the shared account execution, and terminal outcomes permit a fresh execution.
- [x] Coalesced sync waiters are cancellation-aware during Local API teardown: canceled waiter registrations drain immediately while the single per-account operation remains alive, a later waiter can join that operation, and `LocalAPIUnixServer.stop()` finishes promptly without canceling or duplicating the domain sync. The focused route/server/operation/native-bridge suite passed 120 tests with 1 existing opt-in interactive skip and 0 failures; full Swift passed 732 tests with the same skip and 0 failures; the release build and `git diff --check` passed. One fresh read-only reviewer found and closed one Important detached-observer lifecycle issue; final review was 0 Critical and 0 Important.
- [x] Browser-owned draft optimistic updates are atomic in SQLite: browser ownership, expected-hash comparison, draft mutation, and the `draft.update` audit row share one write transaction. Deterministic concurrent coverage proves two changed writes using one prior hash yield exactly one winner and one conflict with only the winner persisted/audited; concurrent no-op saves preserve the snapshot without false mutation audits; and a manual edit committed during AI generation wins while AI apply receives the existing conflict response. Focused DB/Local API/AI draft coverage passed 68 tests; full Swift passed 734 tests with 1 existing opt-in interactive skip and 0 failures; the release build and `git diff --check` passed. No Local API wire schema or InMemory-store behavior changed, so extension regression was not required. Exactly one fresh read-only reviewer found one Important no-op audit edge, which was reproduced and fixed test-first; final re-review was 0 Critical, 0 Important, and 0 Minor.
- [x] `94a7193` preserves a content-free interrupted-send lockout across MV3 worker/popup restarts: send authorization is persisted before native dispatch, sent attempts become terminal, explicit failures can return to the safe identifiers, and delivery-uncertain or receipt-less outcomes remain blocked without an automatic retry path.
- [x] The extension release gate now requires exactly one `nativeMessaging` and one `storage` permission, rejects missing, duplicate, or additional permissions, requires the fixed Chrome public key and derives Chrome ID `fjhlbghobimgnakkhigjmjejahjackfo` from it, requires Gecko ID `quick-mail@plainpost.olhapi.com`, and retains the no-host-permissions, no-content-scripts, and no-externally-connectable checks. Focused identity/permission regressions, all 109 extension tests, typecheck, Chrome MV3 build, Firefox/Zen MV2 build, generated-manifest inspection, and `git diff --check` passed.
- [ ] Existing browser acceptance boundaries remain: standalone Firefox UI was not exercised; branded Chrome did not register the isolated unpacked extension; Zen has temporary-add-on coverage rather than the second full workflow; store signing/submission/publication are externally credentialed; and installed branded Chrome plus Zen launch/recovery interactive acceptance is still incomplete.

## 2026-07-14 Inbox Performance and Reliability Hardening

- [x] Live pre-change diagnosis reproduced the freeze on the real Application Support store: the UI process held 100% CPU for roughly 45 seconds, peaked near 2.0 GiB physical memory, settled near 1.7 GiB RSS, and retained about 1.124 GiB across 221,983 `Swift.StringStorage` allocations. The 454 MiB database contained 8,342 messages and 7,769 threads; text/HTML bodies accounted for roughly 324 MiB. A main-thread sample showed synthesized `Equatable` comparisons walking complete row bodies and HTML.
- [x] List state is body-free. `SQLiteMailStore.mailboxListMessages` never selects `body_text` or `body_html`, `MessageRowModel` no longer stores them, and `messageSummaries(ids:)` performs bounded detail reads for the selected conversation only.
- [x] Production launch publishes a lightweight loading model immediately, constructs the body-free conversation index on `InboxProjectionRepository`, caps the first page at 200 conversations, preserves the page across selection, and exposes an accessible `Load more messages` control in 200-row increments.
- [x] Smart Inbox GUI preflight and queued work-set fingerprinting no longer materialize all bodies. Metadata decides eligibility; the background worker fetches one complete message at a time for provider classification.
- [x] Newest-first mailbox paging now uses the partial `messages_mailbox_list_page` index plus the covering `mailbox_messages_message_path` membership index. The real Application Support query plan no longer builds temporary `DISTINCT`/ordering B-trees or reads body overflow pages; the measured first-page query fell from roughly 2.6 seconds to milliseconds.
- [x] Local/distributed store notifications carry property-list-safe mailbox/account/operation scopes. Operation progress no longer rebuilds the mailbox projection. Missing or invalid legacy payloads safely invalidate all scopes.
- [x] Background startup transactionally requeues expired allowed-kind leases without discarding progress, restores exhausted retry admission, coalesces active incremental Smart Inbox requests, and cancels redundant queued incremental work while preserving explicit full reruns.
- [x] Production IMAP sync, historical sync, delivery, denial, mailbox flags, and AI work execute in the packaged background helper instead of the AppKit process. Incremental notification detection compares body-free message IDs and only fetches full summaries for at most five newly discovered messages. A live UI sample contains no `LocalOperationRuntime.syncInbox` or `IMAPSyncService.syncInbox` stack.
- [x] The production application model initializes after the first loading frame, the delegate promotes the app before default scene presentation, and runtime start is idempotent. The service bridge retains its explicit bounded timeout but now permits 20 seconds for legitimate local IMAP/keychain work under load; the 1-second hung-service regression still passes.
- [x] Focused verification passed for the database projection/indexes, scoped notifications, runtime queueing, deferred app model, delegate launch order, worker ownership, inbox paging, and queue recovery. Final `rtk swift test` passed 833 tests with 1 opt-in interactive skip and 0 failures.
- [x] The final clean single-instance signed release package passed `Scripts/measure-inbox-performance.sh` against the real mailbox: process-to-window 0.664 seconds, request-to-window 0.724 seconds, 160 MiB peak physical footprint during loading, and 100 MiB at the 12-second gate. After two minutes it was idle at 0% UI CPU with an 85.9 MiB physical footprint and 0.53 MiB retained `Swift.StringStorage`; the background helper had exited after draining the queue. The stale/duplicate sync backlog was recovered and no queued, running, or paused jobs remained.

### TLS 1.3 Pinned Mac Credential

- [x] Replaced static PSK with a per-Mac self-issued P-256 TLS identity pinned by QR certificate digest.
- [x] Retained signed device envelopes, replay protection, and paired-device authorization after TLS.
- [x] Verified matching and mismatched certificate pins, rotation invalidation, and framed-session lifecycle tests.
- [x] Verified focused transport tests (21 tests), the full Swift suite (894 listed tests), release build, and iOS Simulator compilation with 0 failures at 2026-07-15 12:39 Europe/Zurich.

### Paired-Mac Device Server and QR Pairing Workspace

- [x] `rtk swift test --filter 'DeviceRequestRouterTests|PlainpostDeviceServerTests|DevicePairingViewModelTests'` passed 9 tests with 0 failures at 2026-07-15 16:18 CEST.
- [x] `rtk swift test` passed 904 tests with 1 skipped and 0 failures at 2026-07-15 16:27 CEST.
- [x] `rtk swift build -c release` passed at 2026-07-15 16:28 CEST.
- [x] `rtk git diff --check` passed at 2026-07-15 16:28 CEST.
- [ ] Next plan: iOS target, pairing client, and encrypted cache.

### iOS Paired-Client Simulator E2E Foundation

- [x] The iOS target uses the real pinned-TLS pairing admission route against
  a Mac-hosted fixture; the simulator app receives only the short-lived
  invitation through its test launch environment and never reads a host path.
- [x] The focused mobile/server gate passed 61 tests with 0 failures in
  126.547 seconds at 2026-07-15 21:58 CEST. It covered the projection service
  and router, live pinned server, pairing store/coordinator, encrypted cache,
  and snapshot/delta/offline synchronization.
- [x] A fresh `rtk swift test` completed with observable exit status 0 at
  2026-07-15 22:05 CEST: 961 tests executed, 1 opt-in interactive-browser
  fixture skipped, and 0 failures in 423.761 seconds. This supersedes the
  earlier 18:54 run whose terminal adapter lost its final status and count.
- [x] `rtk swift build -c release` completed with exit status 0 in 5.86
  seconds at 2026-07-15 22:05 CEST.
- [x] The signed iPhone 17 Pro native gate used simulator
  `D17101C9-01EB-488D-AFE1-58E6C089B853`, `.build/ios-pairing`, and
  `-only-testing:PlainpostTests`; all 12 tests passed with 0 failures at
  2026-07-15 22:06 CEST. The log records `Sign to Run Locally`, and the
  Keychain write/read and revocation-marker accessibility tests executed
  rather than taking the unsigned missing-entitlement skip.
- [x] The same signed native gate passed all 12 tests with 0 failures on iPad
  (A16) `A22DF69A-3AE2-4839-9DF2-7775BC83A8F1` using
  `.build/ios-pairing-ipad` at 2026-07-15 22:09 CEST. Its first launch was
  rejected by SpringBoard as `Busy (Application failed preflight checks)`;
  `simctl bootstatus` confirmed incomplete simulator boot state, and the
  unchanged command passed after a non-destructive boot and explicit
  boot-complete wait.
- [x] `rtk zsh Scripts/test-ios-pairing-e2e.sh` completed with exit status 0
  at 2026-07-15 22:10 CEST. It built the signed iPhone test bundle and created
  a fresh real Mac-hosted pinned-TLS fixture for each named test.
  `testPairsWithHostFixtureWhenInvitationIsProvided` passed once with 0
  failures in 6.781 seconds. `testSyncsFixtureInboxKeepsItOfflineAndAppliesDelta`
  passed once with 0 failures in 13.216 seconds, proving revision-1 snapshot
  rendering, the same encrypted row while the host was stopped, and revision-2
  delta rendering after the host restarted.
- [x] The mobile cache uses a random 32-byte AES-GCM key stored as
  `WhenUnlockedThisDeviceOnly`, authenticates its format version as associated
  data, fsyncs and atomically publishes only validated whole documents, and
  rejects malformed ciphertext without replacing the key. Tests also prove
  fixture subject/preview plaintext is absent from the encrypted file,
  snapshot/delta revision and tombstone behavior, cache/key reset, and
  fail-closed cache-directory, parent-directory, cache-file, and reset symlink
  containment.
- [x] The mail-reading/mutation workspace through `9af0382` passed a fresh full
  `rtk swift test`: 1,039 tests executed, 1 intentional opt-in
  interactive-browser fixture skipped, and 0 failures in 726.8 seconds.
- [x] The final signed iPhone native gate passed 27 of 27 tests, and the
  independent final review observed the same 27-of-27 result. A fresh
  implementation `HEAD` (`306360a`) iPad (A16) native-only rerun completed at
  2026-07-16 05:32 CEST with 27 named tests passed, 0 failed, and 0 skipped.
  It freshly rebuilt the test bundle in the existing `.build/ios-pairing`
  derived-data tree, then used `test-without-building` with destination
  `A22DF69A-3AE2-4839-9DF2-7775BC83A8F1`, and
  `-only-testing:PlainpostTests`; no UI lane ran.
- [x] Real Mac-hosted pinned-TLS fixture UI E2E passed pairing and the complete
  mail lifecycle on both iPhone and iPad: mailbox/thread navigation, explicit
  safe body fetch, offline encrypted cached-body reading, restart, bounded
  search, an offline queued mutation, retry, and authoritative revision-3
  mutation/delta/body reconciliation markers. The lifecycle drives two actual
  fixture-listener stop/restart cycles rather than substituting synthetic
  offline state.
- [x] macOS Release and iOS Simulator Release builds passed. Release-binary
  inspection found no `PLAINPOST_E2E_` or `FIXTURE_` test-control strings.
- [ ] A signed simulator Keychain persistence-and-relaunch test remains
  pending; the signed native test proves entitled write/read in one test
  process, while package coverage proves store recreation on macOS. Neither is
  recorded as a simulator process-relaunch proof.
- [x] The iOS derived-data builds resolved the local `Plainpost` package and
  GRDB 7.11.1 without an additional package checkout. The iPhone and iPad
  paths above are intentionally separate to avoid cross-destination artifacts.
- [x] This remains deterministic local-fixture evidence. It now covers pairing,
  authenticated snapshot/delta projection, encrypted metadata and fetched-body
  cache, live/offline/listener-restart behavior, safe search/body presentation,
  and
  queued mailbox mutation retry/reconciliation. It does not exercise a live
  mail provider mutation, SMTP delivery, user contacts, CloudKit, Bonjour, or
  Tailscale service.
- [ ] Postconditions not covered by this local fixture: physical-device
  pairing, Bonjour and Tailscale discovery/reachability on a physical network,
  CloudKit provisioning and delivery, notification-extension
  delivery/decryption, live-provider mutation/SMTP delivery, and production
  signing/provisioning validation.

### iOS Compose and Send Slice

- [x] The implementation plan is tracked in
  `docs/superpowers/plans/2026-07-15-ios-compose-send.md`; current task status,
  commits, verification, review gates, and remaining work are recorded in
  `docs/superpowers/plans/2026-07-15-ios-compose-send-progress.md`.
- [x] Task 1 is complete and independently approved (`306360a`, `4e02736`):
  bounded attachment validation and MIME rendering, reply/reply-all/forward,
  exact RFC ancestry, and attachment-preserving composer restoration/undo.
- [x] Task 2 is complete and independently approved (`b7364e6`, `0c96ba6`):
  all 12 bounded `compose.*` methods, independent `.compose` authorization,
  fail-closed fallback routing, and signed-request budgeting under the shared
  4 MiB frame.
- [x] Task 3 is complete and independently approved (`e8bf47e`, `d13d09f`):
  all 12 compose routes, stable error mapping, fallback chains, strict
  malicious-provider result validation, 59 focused tests, and the release
  server build passed.
- [x] Task 4 is complete and independently approved (`8a22dc9`, `d1ad110`,
  `726ca19`, `56f8fd1`): device-owned drafts, encrypted recovery receipts,
  atomic review/send/job binding, delayed delivery, crash recovery, stable
  replay, and malformed-legacy fail-closed behavior passed the 151-test
  aggregate and all required release targets.
- [x] Task 5 is complete and independently approved (`0cc5e7c`, `b556518`,
  `06411b2`, `b9937ab`): the production paired-Mac runtime, projection history,
  fail-closed revocation, MIME-safe body projection, listener readiness, and
  settings workspace passed the broad, MIME, security, smoke, and release
  gates.
- [x] Task 6 is complete and independently approved (`86279ea`, `e880280`,
  `5378a58`, `f37da17`, `fefac74`): authenticated mobile cache v3 and separately
  encrypted attachment storage passed 65 storage tests, 12 compose-contract
  tests, release build, and path/secret scans.
- [x] Task 7 is complete and independently approved (`578cb46`, `4fe363e`,
  `ffb2723`, `f5a4e2c`, `199a411`): offline draft reconciliation, durable
  conflict handling, pre-dispatch send/undo intent, status-only recovery,
  terminal uncertainty, cleanup debt, and dependency-aware rollback passed
  54 lifecycle tests, 67 storage tests, 12 compose-model tests, release, and
  iOS build-for-testing.
- [x] Task 8 is complete (`f0125ee`, evidence `cd9b7dc`): adaptive iPhone/iPad
  compose, account selection, local-only Contacts suggestions, attachments,
  conflict resolution, LocalAuthentication gating, review, receipt, undo, and
  accessibility passed 43 signed native tests on each destination plus the
  focused pairing, compose, plist, privacy, and release gates.
- [x] Task 9 is complete (`9b88cdd`): the real certificate-pinned TLS 1.3
  fixture now proves offline draft persistence and later synchronization,
  dual-copy conflict handling, reply-all RFC ancestry, bounded encrypted
  attachment transfer, review/auth gating, undo with zero delivery,
  exactly-once delivery, lost-response status-only recovery, and terminal
  uncertainty on both signed simulator destinations. The wrapper also waits
  for explicit simulator boot completion, preventing the observed SpringBoard
  `Busy (Application failed preflight checks)` launch race.
- [x] Task 10 final verification completed on 2026-07-16 CEST:
  - focused package gate: 280 tests, 0 failures, 0 unexpected skips, in
    609.604 seconds;
  - complete `rtk swift test`: 1,237 tests, 1 intentional opt-in interactive
    browser fixture skip, 0 failures, in 1,385.390 seconds;
  - `rtk swift build -c release`: passed in 10.33 seconds;
  - `rtk zsh Scripts/test-ios-pairing-e2e.sh`: passed all eight labeled lanes
    from one uninterrupted run on iPhone 17 Pro
    `D17101C9-01EB-488D-AFE1-58E6C089B853` and iPad (A16)
    `A22DF69A-3AE2-4839-9DF2-7775BC83A8F1`. Both signed native lanes passed
    43/43 tests. Pairing completed in 5.901 seconds on iPhone and 9.147 seconds
    on iPad; the mail lifecycle lanes completed in 54.869 and 63.257 seconds,
    and the compose lifecycle lanes in 88.002 and 108.975 seconds,
    respectively;
  - final `git diff --check` and `plutil -lint` passed, and production
    `PlainpostApp`/`PlainpostBackgroundAgent` release binaries contained no
    `PLAINPOST_E2E_` or `FIXTURE_` markers.
- [x] Task 11 captured deterministic iOS 26 Mail redesign evidence on the same
  signed iPhone and iPad simulators. XCUITest now retains named screenshots for
  onboarding, mailbox/list/detail, live and cached reading, search, new/reply
  compose, review, undo, conflict, uncertainty, and iPad-specific layouts; the
  wrapper preserves stable `.xcresult` bundles only when explicitly requested.
- [x] Appearance evidence distinguishes real simulator state from test-only
  overrides. Xcode 26.6 `simctl ui` supplied light/dark appearance, AXXXL content
  size, and Increase Contrast, with light/large/contrast-disabled restored after
  capture. Because this toolchain exposes no Reduce Transparency or Reduce
  Motion toggle, those two states were exercised one at a time through the
  Task 9 DEBUG-only `PLAINPOST_VISUAL_*` launch environment; this is not evidence
  of a simulator system-setting toggle. RTL used a separate Arabic launch and
  forced writing direction, then returned to the normal launch environment.
- [x] Matched visual review found and fixed accessibility-size compose overlap,
  a wrapped standard-size Subject label, inherited iPad orientation, inactive
  RTL mirroring, and a DEBUG visual-wrapper conflict with system Increase
  Contrast. Focused signed lanes passed after each correction; the generated
  `.xcresult` and PNG evidence remains uncommitted under
  `output/ios26-mail-redesign-2026-07-17/`.
- [x] Task 11 review remediation completed on 2026-07-17 CEST. The AXXXL
  composer now exposes an explicit scroll container with stacked status,
  attachment, and action rows; the reader no longer adds a redundant custom
  back button or repeats the subject in navigation chrome; and XCUITest uses a
  visible-window coordinate drag plus explicit keyboard dismissal and scoped
  compose queries. `XCUIScreen` capture now supplies the single iPad
  new-compose/iPad-compose image: the final light pair shares SHA-256
  `ca3f7b29c83325c24f1c486f58c0de929039f59dfc55791fc77beb33fe0cd52c`,
  and the retained AXXXL pair shares
  `56a673ac47def7fa275a3eef0ef62fd0084c53cb2838b51601c893fc40a4e6f9`.
- [x] The five actual before/reference PNGs are copied into the ignored
  `output/ios26-mail-redesign-2026-07-17/comparisons/reference/` bundle.
  `comparisons/mapping.json` now separates strict same-viewport/state matches
  from semantic-only comparisons. The typed iPhone recipient reference has a
  real current-code `alice@example.com`/keyboard-open match; the old unpaired
  iPad split has one portrait split/empty-detail after and is explicitly
  semantic-only because current code reaches that surface after pairing.
- [x] All 18 packaged iPad landscape comparison PNGs were rebuilt from true
  xcresult attachments as upright 2360-by-1640 normalized copies. Raw sources
  and superseded mixed-orientation copies remain under `comparisons/raw/`;
  `mapping.json` records raw and normalized hashes, input/output dimensions,
  and the applied transform. Paired visual inspection confirmed direction for
  light, dark, and the source-padded AXXXL transform. The AXXXL reader copy is
  retained but excluded from the reader-chrome verdict because its raw
  XCUIScreen attachment contains padding.
- [x] The focused signed iPhone compose lane passed in 81.726 seconds after
  adding the exact typed-recipient checkpoint, and retained
  `compose-iphone-evidence-rereview.xcresult`. Mapping JSON syntax, every named
  file, strict/semantic hashes, all 18 raw/normalized hash pairs, all normalized
  dimensions, and both single-capture identities were revalidated with zero
  failures; the already-green eight-lane baseline was not rerun.
- [x] Fresh post-review signed lanes passed for Mail on iPhone and iPad in both
  light and dark appearance and for compose on both devices at normal large
  text. The first normal-large iPhone compose run correctly exposed an
  unconditional call to the AXXXL-only scroll helper; the call site was
  guarded, and the exact lane passed on rerun.
- [x] The final retained `final-remediation` baseline passed all eight lanes
  in one uninterrupted run: native, pairing, Mail, and compose on both iPhone
  17 Pro and iPad (A16). Both simulators were restored afterward and queried as
  light appearance, large content size, and Increase Contrast disabled.
- [x] The local SMTP integration suite passed both tests, including rendered
  delivery capture and typed recipient rejection. The compose simulator
  fixture intentionally models delivery locally; it does not claim live
  provider SMTP acceptance or Sent-copy behavior.
- [x] Fixture response loss and delivery uncertainty are deterministic local
  fault injection, not evidence of a live provider's SMTP ambiguity. The
  DEBUG authorizer proves that authentication success/cancellation gates
  network commit frames, but it does not evaluate physical Face ID or Touch ID.

Physical and production acceptance still pending:

- [ ] Physical iPhone/iPad Contacts permission and suggestion behavior
- [ ] Physical Face ID/Touch ID confirmation and cancellation behavior
- [ ] Bonjour and Tailscale reachability to the production Mac listener
- [ ] Live provider SMTP acceptance and provider-managed/non-provider-managed Sent copies
- [ ] Process relaunch during the Mac-hosted ten-second undo interval
- [ ] Production signing, provisioning, and App Store privacy declarations

### iOS 26 Mail Companion Redesign Completion Audit

- [x] Task 12 completion audit ran on 2026-07-17 through 2026-07-18 CEST
  against `main` at pre-audit `1dbd885`. All 12 approved design acceptance
  criteria were re-audited after review. Eleven are proven at their stated
  source/simulator scope; criterion 9 is partially proven, none is contradicted,
  and the remaining VoiceOver/keyboard automation boundary is explicit below.
  Physical and production follow-ups remain explicitly open below.
- [x] The implemented product surface is the approved Mail hierarchy:
  `MobileMailRootView.swift` owns adaptive Mailboxes/message/conversation
  navigation and the focused compose sheet; `MobileMailboxesView.swift`,
  `MobileMessageListView.swift`, `MobileConversationView.swift`, and
  `MobileComposeViews.swift` own the corresponding native surfaces. The
  retained light iPhone inbox, reader, and compose images and normalized iPad
  three-column image were inspected again during this audit.
- [x] iOS 26-only presentation remains availability-gated. The source scan
  found exactly three uses: minimized search and `glassProminent` primary
  action styling in `MobileDesignSystem.swift`, plus `ToolbarSpacer` in
  `MobileConversationView.swift`; all are inside `if #available(iOS 26.0, *)`.
  iOS 18 falls back to ordinary search, `.borderedProminent`, and the standard
  bottom-toolbar layout. No `glassEffect` decorative-content usage exists.
- [x] The production icon is compiled from the asset catalog: the source PNG is
  1024-by-1024, `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`, and the fresh
  Release app plist reports `CFBundleIconName = AppIcon` and
  `AppIcon60x60` as the primary compiled icon.
- [x] Security and authority boundaries are unchanged from the approved design
  baseline. `rtk git diff --quiet a0aeffa -- Sources
  ':(exclude)Sources/PlainpostIOSPairingFixture/**' Package.swift` exited 0 for
  production/shared sources and package configuration. The fixture target alone
  adds the signed-test-only `draft-persistence-count` counter used to prove that
  Save Draft and Close persisted exactly once; it is absent from the Release app
  executable. The only app configuration change is the app-icon catalog name.
  The complete regression suite and signed fixture lanes still prove pinned
  TLS, replay/idempotency, capability enforcement, encrypted cache and
  attachments, paired-Mac authority, DTO validation, and privacy-safe wake
  boundaries.

Acceptance-criterion audit:

| # | Status | Evidence |
|---|---|---|
| 1 | Proven | `MobileMailRootView.swift` selects the paired Mail workspace; signed iPhone pairing and Mail lanes passed; `comparisons/after/light/iphone-live-inbox.png` shows the paired inbox. |
| 2 | Proven | `MobileMailboxesView.swift`, `MobileMessageListView.swift`, and `MobileConversationView.swift` implement Mailboxes → list → conversation; account details and compose are focused sheets; signed iPhone UI lanes passed. |
| 3 | Proven | `NavigationSplitView` exposes `mailboxes.column`, `messages.column`, and `conversation.column`; the signed iPad Mail lane proved a 1180-by-820 landscape window and all three descendants; `comparisons/normalized/after/light/ipad-three-column.png` was inspected. |
| 4 | Proven | `MobileMessageRow` renders sender before subject/preview and gates mark-read, archive, and delete on actual capabilities/archive validity; native row/action tests and signed Mail lanes passed. |
| 5 | Proven | Search, toolbars, menus, sheets, dialogs, and transient states use native presentation; the three iOS 26 API hits are availability-gated and there is no decorative `glassEffect` usage. |
| 6 | Proven | `MobileComposeViews.swift` provides compact From/To/Cc/Bcc/Subject headers and a body-first editor; package compose/storage regressions and both signed compose lifecycle lanes prove drafts, contacts, attachments, review, authentication gating, send, undo, conflict, lost-response recovery, and uncertainty. |
| 7 | Proven | Pairing is isolated to onboarding and `MobilePairingViews.swift`; paired state becomes a quiet Mailboxes account row with a focused account-details sheet. Retained onboarding/Mailboxes images were inspected. |
| 8 | Proven | The 1024-pixel Plainpost envelope asset is wired through `AppIcon.appiconset`; fresh Release bundle metadata names `AppIcon`. |
| 9 | Partially proven | Native contracts and signed UI evidence now prove sender-first labels, unread/preview values, hints, one native List link per message, Apple accessibility audits, Search Return, fresh-compose To focus, actual To → Subject → Body Return traversal, real iPhone landscape, and representative 520/760-point iPad layouts. XCTest does not reliably dispatch Escape or global modifier shortcuts into the iOS/iPadOS simulator responder chain, and the retained evidence does not record VoiceOver speech or rotor gestures. Those claims remain open rather than inferred. |
| 10 | Proven | Production/shared `Sources` and `Package.swift` have no redesign diff when the fixture target is excluded. The fixture-only persistence counter is disclosed above and absent from the Release executable. Full package, pinned-TLS, cache, compose, native, Release, privacy, and release-marker gates passed. No physical/production behavior is inferred. |
| 11 | Proven | Fresh complete package, Release, signed native, and uninterrupted eight-lane E2E gates passed. Task 11's self-contained comparison bundle and current representative images were inspected against the approved direction. |
| 12 | Proven | Simulator evidence is separated from the eight physical/production-only follow-ups below. |

Fresh Task 12 verification evidence:

- [x] `rtk swift test`: exit 0; 1,237 tests, one documented opt-in
  interactive browser-smoke skip, zero failures; XCTest 1,470.403 seconds
  (1,470.508 seconds total runner time).
- [x] Composer correctness within that run: `MobileAttachmentStoreTests`
  19/19 in 34.414 seconds; `MobileCacheStoreTests` 48/48 in 240.891
  seconds; `MobileComposeClientTests` 31/31 in 238.605 seconds;
  `SQLiteDeviceComposeProviderTests` 14/14 in 22.898 seconds. All had zero
  failures.
- [x] `rtk swift build -c release`: exit 0 in 0.590 seconds.
- [x] The uninterrupted `rtk zsh Scripts/test-ios-pairing-e2e.sh` rerun exited
  0 and passed all eight labeled lanes. Durations below are Xcode's exact
  test-operation elapsed values from that run. The two native counts were
  confirmed immediately afterward from same-build fresh xcresult summaries:

  | Lane | Result | Test-operation duration |
  |---|---:|---:|
  | native iPhone 17 Pro / iOS 26.5 | 55/55, 0 failed, 0 skipped | 2.199 s |
  | native iPad (A16) / iOS 26.5 | 55/55, 0 failed, 0 skipped | 2.035 s |
  | pairing iPhone | 1/1 | 5.343 s |
  | Mail lifecycle iPhone | 1/1 | 64.802 s |
  | pairing iPad | 1/1 | 23.903 s |
  | Mail lifecycle iPad | 1/1 | 83.259 s |
  | compose lifecycle iPhone | 1/1 | 78.560 s |
  | compose lifecycle iPad | 1/1 | 93.763 s |

- [x] The first full-matrix attempt exposed stale CoreSimulator orientation
  state: iPad remained 820-by-1180 after a landscape request. Focused Mail and
  compose reproductions isolated the shared simulator state; a pre-launch test
  experiment did not fix it and was reverted. A clean shutdown/boot restored
  the interface transition, the unchanged focused Mail lane passed in 91.318
  seconds, and the uninterrupted full matrix above then passed. No source or
  test-harness change remained from the investigation.
- [x] Fresh iOS Simulator Release build: exit 0 in 65.670 seconds.
  The Release binary marker scan for `PLAINPOST_E2E_|FIXTURE_` exited 1 with no
  matches. The source privacy scan found two explanatory password-copy strings
  and six `PLAINPOST_E2E_` environment reads, all fixture reads inside DEBUG-only
  code; it found no credential value, private key, pairing secret, certificate
  pin, or `FIXTURE_` control in production source.
- [x] `rtk git diff --check` passed before documentation edits. Generated
  screenshot/xcresult output remains ignored and uncommitted.

Task 12 review remediation evidence (2026-07-18 CEST):

- [x] Four focused native tests were written red-first for sender-first message
  speech, mailbox unread/hint semantics, compose focus order, and accepted
  520/760-point adaptive test widths. The initial build failed on the four
  missing presentation/focus APIs; the implemented tests then passed, and the
  final post-fix complete iPhone native suite passed 59/59 with zero failures
  or skips in 2.039 seconds. A further red-first focus-policy regression failed
  while restored drafts still requested initial To focus, then passed in 1.743
  seconds after model initialization restricted that preference to fresh
  compose only. The native contract now proves fresh `true`, restored-draft
  `false`, and reply `false`.
- [x] Message and mailbox controls now expose explicit labels, values, and
  hints. Each message remains one native `List` link with custom accessibility
  actions, and sender precedes subject in the accessibility hierarchy. The
  signed iPhone lane passed Apple's description, detection, hit-region, and
  trait audit; it also proved native Search Return, fresh-compose To focus and
  input, Return traversal to Subject with input, Return traversal to Body with
  input, and an actual 874-by-402 landscape window in 42.255 seconds. Native
  `.onSubmit` is the sole owner of this Return traversal; no duplicate compose
  `.onKeyPress(.return)` handler remains.
- [x] The DEBUG-only adaptive viewport harness accepts only 520 or 760 points.
  Signed iPad lanes proved both exact runtime widths, visible intersecting Mail
  controls, the same accessibility audit, and retained screenshots: 520 points
  passed in 40.664 seconds and 760 points passed in 32.200 seconds. These are
  representative Split View and Stage Manager content widths, not a claim that
  XCTest manipulated the system window-management chrome.
- [x] The accessibility implementation initially exposed a compose regression:
  the reply field inherited new-message initial focus, and relinquishing that
  focus before Review dirtied the draft. A DEBUG probe captured the exact
  pre-tap state as `canPrepare=true draftNil=false hasUnsaved=false
  sync=synchronized error=none`; the failed path then reported `Draft could not
  be saved` before any `compose.sendPrepare` fixture request. Initial focus is
  now explicitly suppressed before presenting a reply, and restored drafts
  suppress it at model initialization. Signed affected lanes passed afterward:
  Mail iPhone 65.009 seconds and Mail iPad 84.398 seconds in the original
  remediation; the final narrow follow-up compose reruns passed on iPhone in
  81.446 seconds and iPad in 97.318 seconds.
- [x] A fresh final-source Release simulator build passed. Scanning its exact
  executable for `PLAINPOST_E2E_|FIXTURE_|debug.adaptive-viewport` exited 1 with
  no matches, so the width fixture and host controls remain absent from the
  shipped binary. Wrapper `zsh -n`, source fixture/privacy scans, and
  `git diff --check` also passed. The source scan also found no remaining
  compose `.onKeyPress(.return)` handler.
- [x] The second independent review found two valid close/recovery gaps. Four
  native policies were added red-first: dirty-compose close disposition,
  save-before-close success/failure, revoked/cleanup onboarding actions, and
  authorized-Mail-to-pairing workspace reset. The corrected red build failed
  only on the four missing production APIs; the focused six-test green run
  passed in 17.561 seconds. The final signed native suite passed 63/63 with
  zero failures or skips in 5.831 seconds.
- [x] Fresh compose now closes immediately only while pristine. Clean persisted
  drafts and terminal send states also close immediately. Dirty content blocks
  interactive swipe dismissal and every Cancel/Close/Escape source path enters
  the same model-backed request policy. Its native two-action alert offers only
  **Save Draft and Close** and **Keep Editing**; it never claims discard/delete.
  Save failure leaves the composer open with `Draft could not be saved`, while
  synchronized or locally queued persistence permits close.
- [x] The signed accessibility iPhone lane passed in 45.611 seconds after
  driving To → Subject → Body input, requesting close, proving both supported
  actions and that the dirty composer remained presented, then selecting Save
  Draft and Close. The paired-Mac fixture recorded exactly one additional
  draft-persistence operation before the composer dismissed. Clean/terminal
  close regressions passed in the complete compose lanes: iPhone 81.018 seconds
  and iPad 159.729 seconds.
- [x] Revoked and cleanup-required onboarding now show state-specific recovery
  copy plus a reachable, confirmed **Remove Pairing** action backed by the
  existing `removePairing()` cleanup. Normal unpaired/pairing/incompatible
  onboarding retains Pair with Mac. Leaving an authorized Mail destination for
  any pairing destination clears mailbox selection, opened message, search,
  and the composer. Pure native presentation/transition tests cover the
  otherwise hard-to-inject states; no new app Release hook was added. Normal
  signed regressions passed: pairing iPhone 23.997 seconds, pairing iPad 72.172
  seconds, Mail iPhone 74.307 seconds, and Mail iPad 98.266 seconds.
- [x] A new clean Release simulator build passed. Its exact executable scan for
  `PLAINPOST_E2E_|FIXTURE_|debug.adaptive-viewport|draft-persistence-count`
  returned no matches. Wrapper syntax, source fixture/privacy/credential scans,
  direct-close/discard scans, and `git diff --check` passed.
- [x] The final whole-redesign rereview of `87e8588..d2cdc21` approved the work
  with zero Critical and zero Important findings. Its one Minor finding was a
  stale plan sentence saying the expanded default wrapper still ran eight
  lanes; that wording now states the current eleven-lane matrix while retaining
  the accurate historical eight-lane evidence above.
- [x] Root completion verification reran the signed native suite: 63/63 passed,
  with zero failures or skips. A fresh unsigned Release iOS Simulator build
  ended with `** BUILD SUCCEEDED **`; its executable again contained no E2E,
  fixture, adaptive-viewport, or persistence-counter markers. Final wrapper
  syntax, production/shared-source pathspec, privacy/credential/fixture-scope,
  direct-close/discard, diff, and status checks passed.
- [ ] Escape and global modifier shortcuts remain implemented through native
  SwiftUI `cancelAction` and keyboard-shortcut APIs, but are not marked
  simulator-proven. The attempted XCTest calls were
  `app.typeKey(.escape, modifierFlags: [])`, `app.typeText("\\u{1B}")`,
  `toField.typeKey(.escape, modifierFlags: [])`,
  `app.typeKey("n", modifierFlags: .command)`,
  `app.typeKey("d", modifierFlags: [.command, .shift])`,
  `toField.typeKey("d", modifierFlags: [.command, .shift])`, and
  `app.typeKey("r", modifierFlags: .command)`. XCTest logged synthesized key
  events, but Escape left compose open; Command-N was therefore a false
  positive against the already-open composer; Shift-Command-D succeeded when
  targeted at the application but failed when targeted at the focused field;
  and Command-R was not stable enough to retain as proof. A clean iPad
  shutdown/boot still failed earlier because tapping toolbar Search did not
  expose a SearchField. The installed `simctl io`/`simctl ui` interfaces offer
  no supported keyboard-event injection; GUI automation such as AppleScript or
  CGEvent posting would be focus-dependent and require host Accessibility
  permission, so it is not a safe deterministic substitute. VoiceOver speech
  and rotor gestures likewise have no recorded runtime artifact. Source
  contracts, the accessibility tree, and Apple audits do not substitute for
  those claims.

Physical and production acceptance still pending after the redesign audit:

- [ ] Pairing and sustained Mail use on physical iPhone and iPad hardware
- [ ] Physical-device Contacts permission, denial, and recipient suggestions
- [ ] Physical Face ID/Touch ID confirmation and cancellation
- [ ] Bonjour and Tailscale reachability to the production paired-Mac listener
- [ ] CloudKit provisioning plus opaque wake and notification-extension delivery/decryption
- [ ] Live-provider mailbox mutation, SMTP acceptance, and provider-managed/non-provider-managed Sent copies
- [ ] Paired-Mac process relaunch during the Mac-hosted ten-second undo interval
- [ ] Production signing, provisioning, App Store privacy declarations, and distribution acceptance

### Automatic iOS Pairing, Inbox Entry, and Relaunch Recovery

- [x] The iOS onboarding now exposes one **Scan pairing code** action backed by
  VisionKit. A recognized QR payload is handed directly to the existing
  certificate-pinned TLS pairing coordinator, so pairing starts automatically
  without a second confirmation button. Camera and local-network privacy keys
  are present in the production iOS plist.
- [x] A successful initial snapshot now selects Inbox and advances compact
  navigation to the real message list. The former paired-state account/status
  placeholder is no longer the post-pairing destination. Valid existing
  mailbox selection remains stable; Inbox is preferred only when no valid
  selection exists.
- [x] App preparation now restores the durable Keychain pairing and encrypted
  cache, attempts coordinator reconnection, and refreshes the projection. A
  reachable Mac returns to the live Inbox; an unreachable Mac retains the
  authorized offline cache rather than stranding the user on pairing removal.
- [x] The macOS Paired Devices workspace uses a compact 640-point layout with a
  196-point QR code, clearer scan instructions, tighter spacing, improved
  paired-device rows, and a separated destructive trust-reset action. While
  the workspace is open it refreshes safe paired-device metadata every second,
  so a newly paired iPhone or iPad appears without reopening Settings.
- [x] Red-first coverage was added for the single scan action, automatic
  import-and-pair boundary, Inbox selection, durable launch reconnect, and Mac
  paired-device monitoring. Signed simulator coverage passed the native iPhone
  and iPad suites, automatic pairing plus terminate/relaunch reconnect on both
  device classes, the complete Mail and compose lifecycles, accessibility and
  landscape behavior, and representative 520/760-point adaptive widths. The
  complete current-source wrapper rerun finished uninterrupted with exit 0 at
  2026-07-18 13:34 CEST, and the focused Mac pairing suite passed 7/7 with zero
  failures.
- [x] The latest production-source iOS app built for generic physical arm64
  iOS with Personal Team `PCQG52JLF9`; the resulting bundle identifies
  `com.marynavdovenko.Plainpost.iOS`. The packaged Mac app is running and listening on
  TCP 60454 for the local certificate-pinned data plane.
- [ ] Physical-device installation and live-provider projection proof remain
  pending because Xcode currently reports `olhapi iphone` (`00008110-001458941E61401E`)
  offline/unavailable over Wi-Fi. When it reconnects, install the prepared
  `.build/ios-device/Build/Products/Debug-iphoneos/Plainpost.app`, pair by QR,
  verify a new production projection revision, terminate/relaunch, and verify
  automatic live Inbox recovery before closing the physical acceptance item.

## 2026-07-19 Unified Local Mail Search Completion

- [x] Added a release benchmark executable and reproducible wrapper for
  deterministic 10,000-, 50,000-, and 100,000-message datasets, plus a
  read-only production-source/disposable-copy migration lane. JSON artifacts
  include environment metadata, p50/p95 samples, cold start, cancellation,
  bounded 1 ms peak-operation RSS sampling with an explicit first-sample
  readiness handshake that fails closed if its window is exhausted, storage,
  migration integrity, source before/after fingerprints, and query plans.
- [x] The corrected final enforced 10,000-message budgets passed with no
  correctness or performance violations: structured p95 2.910 ms, message p95
  4.482 ms, conversation p95 10.939 ms, cold first page 6.264 ms,
  cancellation 0.067 ms, peak search-operation RSS delta 9,388,032 bytes, and
  search structures 7,700,480 bytes. The 50,000- and 100,000-message tracking
  runs completed with peak deltas of 14,811,136 and 20,103,168 bytes.
- [x] Root-cause profiling at 100,000 messages found repeated correlated
  `bm25()` FTS scans inside the canonical service query. Ranking is now
  materialized once in `fts_scores`; corrected authoritative 100,000-message
  p95 is 39.582 ms for common message search and 130.453 ms for common
  conversation search.
- [x] The read-only production source was backed up transactionally, then only
  the destination was rebuilt as a controlled production-shaped v21 database
  using all 9,378 real canonical rows and the real v21 legacy metadata/FTS
  schema. The registered migrator executed v22 and v23, ending at schema 23
  with 9,378 projection/FTS rows, SQLite/FTS integrity, legacy absence, and
  81,338,368 search-structure bytes under the 106,900,000-byte invariant. This
  is explicitly a controlled production-shaped reconstruction, not a naturally
  captured v21 production file. Source DB/WAL size, mtime, and SHA-256
  fingerprints were identical before and after; no migration or benchmark
  write touched the source.
- [x] Independent review's one Critical, five Important, and two Minor findings
  are fixed: exact/symlink/hard-link and sidecar alias rejection happens before
  source open/output creation; correctness is always fatal; SQLite/FTS
  integrity and migration execution are explicit; production storage is a
  correctness gate; synthetic counts/coverage are SQL-measured; violation
  classes are separate; and signal cleanup preserves status.
- [x] The final format-version-3 artifact set was generated at
  2026-07-19T20:07:35Z through 20:08:14Z. The production-copy artifact SHA-256
  is `3d8b454288081b4d21cc68a8c6deaceceb04950746076bc9b46f6587dd1dd171`;
  all four artifact digests are recorded in the performance report.
- [x] Legacy table creation/backfill/upgrade logic is centralized in
  `SQLiteMailSearchSchema`. The duplicate `SQLiteMailStore.searchMessages`
  implementation and its test-only callers are deleted in favor of
  `SQLiteMailSearchService`; cleanup scans find no superseded production search
  route and no query-text or message-content search telemetry.
- [x] Final-code focused verification passed: mail search 240/240 and benchmark
  support 22/22, including injected sampler success, exhaustion, invalid-read,
  and cancellation/await coverage. The final full Swift suite passed 1,469
  tests with one opt-in interactive skip and zero failures in 1,866.200
  seconds; the final Swift Release build also passed.
- [x] Swift release products, the macOS `PlainpostApp` Release Xcode build, and
  the generic iOS Simulator Release build passed. Two signed-wrapper attempts
  reproduced stale CoreSimulator state: the iPad window stayed at 1032x1376
  after both landscape requests, then a later run wedged in XCTest
  wait-for-quiescence between independent iPad UI fixtures. The wrapper now
  performs a scoped reboot only for focused iPad lanes and between independent
  iPad UI lanes in the full matrix. Its shell syntax gate passed, the focused
  signed iPad compose lane passed in 88.926 seconds, and the final complete
  uninterrupted wrapper exited 0 across all 11 native, pairing/relaunch, mail
  reading/offline/search/mutation, compose/draft/attachment/send,
  accessibility/focus, Split View-width, and Stage Manager-width lanes.
- [x] Detailed reproducibility, measurements, query-plan evidence, migration
  fingerprints, and acceptance boundaries are recorded in
  `docs/performance/2026-07-18-unified-local-mail-search.md`.
- [ ] Physical iPhone/iPad verification and human VoiceOver speech, rotor,
  gesture, biometric, live-provider, and production-network proof remain open.
  Automated and simulator evidence above does not close those items.

### Whole-branch high-priority re-review

- [x] The final whole-branch review found no Critical issues and three
  Important contract gaps. Authenticated cursor binding mismatches now return
  `staleCursor`; a signed nonempty device search with the canonical empty scope
  resolves to the provider's authorized accounts before search dispatch; and
  the macOS search workspace loads session recents on presentation, focus, and
  query clearing without issuing a search or writing history. Empty query plus
  empty scope remains invalid, while scoped-empty match-all remains supported.
- [x] Focused post-fix verification passed: the aggregate Mail Search lane
  passed 243/243, Device Mail Service passed 36/36, the production SQLite
  companion provider passed 23/23, and the Swift Release plus unsigned macOS
  `PlainpostApp` Release builds exited 0.
- [x] Fresh read-only high-priority re-review of `a65190e..3c27f7c` reported
  zero Critical and zero Important findings and assessed the branch ready at
  that boundary. Its focused regression check passed 7/7 and its diff/worktree
  checks were clean.
- [ ] The review's two Minor findings remain recorded for follow-up: macOS and
  iOS duplicate-page draining has a fixed eight-page cap, and device response
  validation requires nonempty mailbox IDs even though the Core model permits
  an empty mailbox list.
- [ ] A later full-suite rerun at `26521cf` executed 1,469 tests with one skip
  and ended with three failures, one unexpected. The PTY output was truncated
  before the failing test names and SwiftPM emitted no durable result bundle;
  exhaustive local log and transcript recovery retained only the aggregate.
  Per the high-priority-only review boundary, no second broad suite was run;
  the exact affected suites and builds above are the current post-fix evidence.

## 2026-07-29 iOS Functional Mobile Parity Task 5

- [x] Immutable code checkpoint: `6b17381e` (`fix(ios): separate send dispatch
  from reconciliation`). It keeps named E2E lanes fail closed, counts
  `compose.sendDirect` rather than the obsolete review commit route, and polls
  the delayed-body fixture counter. It also introduces `.dispatching` for an
  in-flight direct send: the delivery detail remains presented and automatic
  reconciliation is disabled until the request resolves. Only a direct-send
  `.unavailable` response becomes `.delivering`, which enables status-only
  reconciliation without a duplicate send.
- [x] Final gates on that checkpoint: `rtk zsh
  Scripts/test-ios-pairing-e2e-contract.sh`, `rtk zsh -n
  Scripts/test-ios-pairing-e2e.sh`, and `rtk cmp
  Scripts/test-ios-pairing-e2e.sh scripts/test-ios-pairing-e2e.sh` passed;
  `rtk swift test --filter
  MobileConnectionCoordinatorTests/testAuthenticatedDirectSendUsesCoordinatorAllowlist`,
  `rtk swift build --product PlainpostIOSPairingFixture`, and the focused native
  dispatch/reconciliation tests passed. Full `rtk swift test` passed 2,123
  XCTest cases with 7 explicit skips and 0 failures in 200.191 seconds, plus
  Swift Testing 73/73 in 0.420 seconds. `rtk swift build -c release` passed.
  The current native `PlainpostTests` iPhone target passed 127/127 in its
  retained result bundle.
- [x] All final named fixture lanes passed serially with
  `PLAINPOST_E2E_HOST=192.168.1.225`: `PLAINPOST_E2E_ONLY=compose-iphone`,
  `compose-ipad`, `functional-parity-iphone`, and `functional-parity-ipad`,
  each invoking `zsh Scripts/test-ios-pairing-e2e.sh`. The compose wrapper
  verified the exact direct-send/status-only reconciliation route without a
  duplicate direct send.
- [x] A fresh iOS Simulator Release build via `rtk xcodebuild -project
  Apps/PlainpostiOS/Plainpost.xcodeproj -scheme Plainpost -destination
  'platform=iOS Simulator,id=D17101C9-01EB-488D-AFE1-58E6C089B853'
  -derivedDataPath .build/ios-functional-release -configuration Release build`
  passed. Scanning its `Plainpost.app/Plainpost` executable for
  `PLAINPOST_E2E_`, `FIXTURE_`, `delay-next-body`, `release-delayed-body`,
  `drop-next-send-response`, and `compose.state.failure-reason` returned no
  matches.
- [ ] Physical-device proof remains separate: Face ID/Touch ID, push delivery
  and decryption, Bonjour/Tailscale reachability, process-relaunch Keychain,
  and live SMTP delivery have not been exercised on real iPhone/iPad hardware.

## 2026-07-29 iOS Functional Mobile Parity Final Completion

- [x] Final implementation checkpoint `386939e3`, plus packaged-acceptance
  correction `48b5b9ec`, completes cache-first reading and durable offline
  lifecycle controls; normal direct compose/reply/reply-all/forward and
  exactly-once send recovery; paired-Mac grounded AI; Smart Inbox; the approval
  queue; and secure received-attachment list, bounded download, encrypted
  cache, offline pin/remove, preview, cancellation, and sharing.
- [x] Pairing revocation is a publication barrier shared by every cache-store
  instance for the same physical path. Reset advances the authorization epoch
  before deletion, stale instances cannot recreate or mutate cache state, and
  unsolicited revocation/cleanup immediately clears authorized UI state.
  Approval decisions also discard late results after an authorization change.
- [x] `origin/main` at `97da2c63` is already an ancestor of the feature
  checkpoint, so merging refreshed `origin/main` was a verified no-op. The
  local `main` reference remains older and was not used as the integration
  source.
- [x] A fresh full `rtk swift test` passed every enabled XCTest suite and Swift
  Testing 73/73. Four real-Security acceptance cases were explicitly skipped
  because `PLAINPOST_RUN_SECURITY_ACCEPTANCE=1` was not set; ordinary tests
  remained on injected, in-memory, or disposable vault boundaries and did not
  use the login Keychain. The detector contract passed and the strict
  repository scan found zero ordinary-test uses of real Security storage.
- [x] The full native `PlainpostTests` run passed 152/152 with no failures or
  skips on iPhone 17 Pro Simulator running iOS 26.5.
- [x] Six signed pinned-TLS packaged lanes passed serially on the final branch:
  Mail, functional parity, and compose/draft/attachment/send on both iPhone and
  iPad. The mail lane now disconnects before revealing its offline swipe action
  so it tests durable queuing without relying on stale SwiftUI presentation
  state.
- [x] Fresh `rtk swift build -c release` and generic iOS Simulator Release
  builds passed. The Release app executable contains no `PLAINPOST_E2E_` or
  `FIXTURE_` strings; source fixture controls remain `#if DEBUG`-gated.
- [ ] Physical-device proof remains separate: Face ID/Touch ID, push delivery
  and decryption, Bonjour/Tailscale reachability and background wake timing,
  process-relaunch Keychain persistence, and live SMTP delivery have not been
  exercised on real iPhone/iPad hardware.

## 2026-07-31 iOS Companion Navigation Redesign Acceptance

- [x] Added a width-and-Dynamic-Type layout policy (`MobileLayoutDensity`) with
  distinct compact, standard, and accessibility states; filter controls retain
  44-point targets, reader actions scroll rather than clip at accessibility
  sizes, and the compose/status surfaces use opaque semantic fallback surfaces
  under Reduce Transparency. Recipient removal, status actions, and mail-row
  VoiceOver actions remain equivalent to their safe swipe/action controls.
- [x] The debug acceptance viewport now recognizes separate 375-, 393-, and
  430-point phone lanes. The existing 520- and 760-point lanes remain named
  iPad Split View/Stage Manager evidence and are not represented as phone
  acceptance. The fixture wrapper adds fail-closed named lanes for all three
  phone widths and preserves the compact-landscape keyboard lane separately.
- [x] Current focused iPhone 17 Pro Simulator evidence: seven production unit
  contracts passed in
  `.build/ios-companion-redesign/Logs/Test/Test-Plainpost-2026.07.31_22-45-36-+0200.xcresult`:
  `testAdaptiveLayoutPolicyUsesWidthAndDynamicTypeTogether`,
  `testVoiceOverRowActionsMatchSwipeActions`,
  `testMinimumInteractiveTargetPresentationIsFortyFourPoints`, and
  `testVoiceOverStatusAnnouncementsAndRecipientRemoval`,
  `testVisualAccessibilityOverridesAreAbsentWithoutEnvironmentKeys`,
  `testVisualAccessibilityOverridesParseOneAndZeroExactly`, and
  `testVisualAccessibilityOverridesAllowlistDynamicTypeAndDarkMode` (0.0026 s
  or less; 7/7 passed). Host-fixture evidence is recorded separately below,
  because the fixture lane requires its one-time invitation and must not be
  inferred from this direct focused unit run.
- [x] DEBUG-only visual acceptance now strictly allowlists `xxxl`,
  `accessibility3`, and `accessibility5` Dynamic Type overrides plus dark mode,
  forwards them through the generated fixture xctestrun, and exposes the
  applied SwiftUI environment through the queryable
  `debug.visual-environment` probe. The narrow-phone UI test asserts that probe
  and names screenshots by active visual mode; `PLAINPOST_E2E_RESULT_SUFFIX`
  keeps mode-specific fixture results distinct. Its executable shell contract
  rejects unsupported values. These debug controls remain outside Release.
- [x] Paired-host 375-point phone acceptance passed after the stale title
  expectation was corrected from `Inbox` to the selected authoritative
  destination, `All Inboxes`. The preserved result bundle
  `output/ios26-mail-redesign-2026-07-17/xcresults/adaptive-phone-375.xcresult`
  reports `testNarrowPhoneAcceptanceMatrixWithHostFixture` passed on iPhone 17
  Pro Simulator / iOS 26.5 at 2026-07-31 22:30 local time. It exercised the
  real pinned-TLS fixture, synchronized `mail.row.ios-fixture-message`, and
  retained the `iphone-375-matrix` screenshot attachment. The older preserved
  `adaptive-phone-375-failed.xcresult` records only the invalid title assertion,
  not a layout or product regression. The final execution evidence below
  supersedes the earlier safe-capacity-window status.
- [ ] Simulator evidence does not establish physical-iPhone keyboard/safe-area
  behavior, VoiceOver speech/rotor interaction, biometric approval,
  notification delivery/decryption, background reconnect, Keychain persistence,
  or live-provider send/uncertainty behavior.

### Task 9 final Simulator acceptance (2026-08-01)

- [x] Task 9 is complete for the Simulator commit boundary at `810d37dd`.
  The final commit only aligns a host source-contract assertion in
  `PlainpostDebugSyncAcceptanceTests`; it does not change application or
  fixture behavior, so the retained Simulator lane results remain applicable.
  The focused red/green regression
  `PlainpostDebugSyncAcceptanceTests/testPackagedRelaunchStopsRealMacAndRequiresOfflineEncryptedCache`
  first reproduced the stale assertion at line 348, then passed 1/1 with zero
  failures after `810d37dd`.
- [x] Fresh full `rtk swift test` at `810d37dd` exited 0: 2,515 tests, one
  skipped test, and zero failures in 303.666 seconds; Swift Testing passed
  74/74 in 0.432 seconds.
- [x] The generic iOS Simulator Release build exited 0. Its Release app binary
  marker scan for `PLAINPOST_E2E_|FIXTURE_` exited 1 with no matches.
- [x] Retained final-matrix-2 Simulator evidence from
  `output/ios26-mail-redesign-2026-07-17/xcresults` passed as follows. Times
  are each xcresult's test-operation elapsed duration:

  | Lane | Result | Duration |
  | --- | --- | ---: |
  | native iPhone 17 Pro / iOS 26.5 | 249/249, 0 failed, 0 skipped | 3.768 s |
  | native iPad Pro 13-inch (M5) / iOS 26.5 | 249/249, 0 failed, 0 skipped | 3.676 s |
  | pairing iPhone | 1/1 | 12.711 s |
  | pairing iPad | 1/1 | 32.204 s |
  | Mail lifecycle iPhone | 1/1 | 140.503 s |
  | Mail lifecycle iPad | 1/1 | 160.211 s |
  | functional parity iPhone | 1/1 | 202.110 s |
  | functional parity iPad | 1/1 | 226.357 s |
  | compose lifecycle iPhone | 1/1 | 125.910 s |
  | compose lifecycle iPad focused retry | 1/1 | 119.778 s |

  The full-script iPad compose invocation retained
  `compose-ipad-failed-final-matrix-2.xcresult` because CoreSimulator could
  not instantiate the test bundle, an infrastructure error rather than a
  product-test failure. Its focused retry at the same preceding HEAD passed as
  listed above. The later source-contract-only commit `810d37dd` has no
  behavioral effect on those completed lanes.
- [x] Visual inspection retained the latest Simulator attachments in
  `adaptive-phone-375.xcresult`, `adaptive-phone-393-final.xcresult`,
  `adaptive-phone-430-final.xcresult`,
  `adaptive-phone-393-{xxxl,accessibility3,accessibility5,dark,increased-contrast,reduce-transparency}.xcresult`,
  `adaptive-split-ipad-final.xcresult`, `adaptive-stage-ipad-final.xcresult`,
  and `accessibility-iphone-final.xcresult`. The inspected states had no
  duplicate Inbox title, Smart Inbox content presented as Inbox, clipped
  essential text, contradictory status, raw Message-ID, duplicate recipient,
  obscured final content, or destructive full-swipe Delete.
- [ ] This closes no physical-device or production-readiness requirement.
  Physical iPhone/iPad checks remain required for keyboard and safe-area
  behavior, VoiceOver speech and rotor interaction, Face ID/Touch ID approval,
  notification delivery/decryption, background reconnect, process-relaunch
  Keychain persistence, Bonjour/Tailscale reachability, and live-provider
  send/uncertainty behavior. They are production-readiness blockers, not
  Simulator commit blockers.

## 2026-08-02 Efficient Sync Diagnostics Verification

- [x] Verified the completed diagnostics chain at `45f0bccc`, `e616197a`,
  `1eed9f26`, `580e501b`, `8b62cf1e`, `30e20d56`, `25e2586e`, and
  `12d6f2bd`. The first sandboxed
  `swift test --filter PlainpostApplicationModelTests/testMailMonitoringRunsWithoutCreatingAWindowScene`
  exited 1 before discovery because Swift could not write its compiler module
  cache; its elevated rerun passed 1/1. The original red/green regression
  commands were otherwise re-run as fresh green acceptance (this verification
  task did not create an artificial red revision):
  `swift test --filter IMAPHarnessTests/testLoginClassifiesConnectionLimitWithoutRetainingRawResponse`,
  `swift test --filter InteractiveAIPreemptionTests/testSuccessfulSyncAutomaticallyResumesMailSyncFailedOrganizer`,
  and `swift test --filter AuditLogViewModelTests/testDiagnosticsPaginationLabelsAndNavigation`
  each passed 1/1 with zero failures.
- [x] Focused subsystem acceptance passed: `PlainpostOperationsTests` XCTest
  163/163 plus Swift Testing packaged suite 39/39, `PlainpostDBTests` 302/302,
  `PlainpostUITests` 700/700, and
  `PlainpostIntegrationTests` 256 tests with zero failures. Integration
  retained one documented opt-in interactive-browser fixture skip; it is not a
  product or unexpected test skip.
- [ ] The prescribed full gate `pnpm verify:pre-push` is blocked, not passed:
  the repository root has no `package.json`, and its only pnpm manifest
  (`Apps/PlainpostBrowserExtension/package.json`) defines no `verify:pre-push`
  script. Native audit found no configured or tracked pre-push hook and no
  authoritative repository-native replacement, so no substitute command was
  treated as the repository gate.
- [x] `git diff --check HEAD~5..HEAD` and the base-to-HEAD whitespace check
  were clean. The focused secret scan found only existing Keychain record-key
  labels (`imap-password`/`smtp-password`) in `PlainpostOperationRuntime`,
  not changed diagnostic persistence, `LOGIN` commands, or credential values.
  The worktree was clean and `.pnpm-store/` remained untouched.
- [ ] Live Gmail verification was not attempted because no configured live
  account/authentication was in this acceptance scope; it remains unverified.

### Final reviewed repair evidence

- [x] Subsequent review repairs landed in `7d68be67`, `51600533`, `570f17b7`,
  `d592c555`, `fddb8c9e`, `e3d3c558`, and `7aac2d6a`. They preserve scheduled
  reconciliation across queued, running, cancellation, recovery, and legacy
  scope-row boundaries; keep explicit manual work stronger; move complete
  Diagnostics snapshot construction off the main actor; and prevent automatic
  polling from superseding explicit navigation.
- [x] Fresh post-repair suites passed with zero failures: Operations 176
  XCTest plus 39 Swift Testing tests, DB 307 XCTest tests, and UI 712 XCTest
  tests. Focused cancellation/migration, reconciliation-generation,
  full-refresh ownership, actor-boundary, and navigation/poll race regressions
  also passed.
- [x] A final controlled
  `rtk proxy swift test --filter PlainpostIntegrationTests` exited 0: 256
  tests, one expected opt-in interactive-browser fixture skip, and zero
  failures in 215.701 seconds.
- [x] A subsequent complete `rtk swift test` on the reviewed repair tree also
  exited 0, covering the entire Swift package after the final navigation/poll
  race fix.
- [x] Sol scoped re-review found every load-bearing repair finding addressed
  with no new Critical or Important breakage. Native accessibility-tree
  automation and the pre-existing duplicate readiness predicates remain
  accepted non-load-bearing follow-ups.
- [ ] The missing root `pnpm verify:pre-push` command and live Gmail acceptance
  remain explicitly unverified as recorded above.

### Task 9 post-review verification (2026-08-02)

- [x] Sol's final two-axis review found 0 Standards findings and 2 Spec
  findings. Both are fixed at behavioral HEAD `8fe962e0`:
  `ad0b190b` makes account unread counts use the exact case-insensitive
  canonical `INBOX` per account, including a visible zero; `8fe962e0` makes
  adaptive surfaces measure their container width, with recipient tokens
  inheriting recipient-field width. No app Swift use of
  `UIScreen.main.bounds.width` remains.
- [x] Fresh post-review Simulator verification at `8fe962e0`: `rtk swift test`
  exited 0; the full `PlainpostTests` `xcodebuild` suite exited 0 on both the
  iPhone 17 Pro and iPad Pro 13-inch (M5) simulators, with each retained native
  xcresult recording 255 Passed test cases and no Failed or Skipped entries.
  `adaptive-phone-375-post-review.xcresult` passed the 375-point host-fixture
  lane 1/1 in 8.883 seconds, and `adaptive-split-ipad-post-review.xcresult`
  passed the 520-point iPad Split View lane 1/1 in 12.528 seconds.
- [x] The generic iOS Simulator Release build exited 0. Its Release binary
  marker scan for `PLAINPOST_E2E_|FIXTURE_` exited 1 with no matches.
  `rtk git diff --check` was clean.
- [ ] This remains Simulator-only evidence, not physical-device or production
  proof. Physical iPhone/iPad checks and the production-readiness boundaries
  above remain open, including real keyboard/safe-area and VoiceOver behavior,
  biometric approval, notification delivery/decryption, background reconnect,
  relaunch Keychain persistence, network reachability, and live-provider
  send/uncertainty behavior.

## 2026-08-03 Central account API Task 2 review repairs

- [x] Round-three hardening requires distinct `current_database()` names at
  readiness, even through different schemas/search paths or replica endpoints.
  Distinct databases on one server remain valid when backed up and restored
  separately; no physical-cluster failure-domain guarantee is claimed.
- [x] Bootstrap limiter storage is hard-capped at 65,536 secret-keyed buckets;
  IPv6 is canonicalized to `/64`, provider validity precedes limiter mutation,
  and cleanup records errors while draining at most four bounded batches/tick.
  Concurrent rotating-identity, no-provider/no-valid-manifest, outage, cleanup,
  and `/64` sharing tests passed.
- [x] Gapless journal allocation and replay now reject missing sequences.
  Concurrent append/replay, fresh-head readiness, append and replay rollback,
  conflicting-ledger, retry convergence, and explicit device/credential/lease
  revocation tests passed live without unsafe checkpoint movement.
- [x] Readiness rejects migration name/checksum/count/head drift. A live v3-to-v4
  upgrade proof preserves valid encrypted rows, rejects a preexisting 28-byte
  row without advancing the migration, and succeeds after operator repair.
- [x] Round-three full and race gates, vet/diff, and Compose config passed. A
  fresh independent rereview observed 69 passing tests across four packages;
  this supersedes the earlier RTK/report total of 71. Two starts over preserved
  volumes returned health and readiness 200 with account `5|5` and journal
  `3|3`. The recorded fix-round Compose build artifact was
  `sha256:735b0254c050e4ec00e888aaf3a7d77a14804e35e7e0d62904f047381748ead5`;
  local image tags are mutable, so this is not a claim about current local image
  identity.

- [x] The account database and deletion journal now use independent PostgreSQL
  pools, services, embedded forward-migration sets, and named volumes. Account
  schema head `5|5` contains no deletion-marker table; journal schema head
  `3|3` owns the durable marker journal without a cross-database foreign key.
  Deployment documentation excludes the journal volume from account snapshots
  and preserves restore order before readiness/account traffic.
- [x] Journal marker append advances a durable monotonic high-water in the same
  transaction. A replay controller records an account-side immutable marker
  ledger, performs deletion/revocation, and advances its checkpoint atomically;
  readiness fails closed until it equals the journal head. A live test against
  two different PostgreSQL databases proved a stale active account restore is
  blocked and then deleted by idempotent replay.
- [x] Wire UInt64 persistence uses checked `NUMERIC(20,0)` values bounded to
  `1...18446744073709551615`. Live PostgreSQL tests accepted UInt64 max and
  rejected max-plus-one and zero. The nullable account trust head is all-or-none
  and has a deferred composite foreign key to the exact unique trust commit.
- [x] Forward-only migrations use an advisory lock, ordered embedded SQL,
  per-version SHA-256 checksums, drift/ahead/non-contiguous history rejection,
  and exact required-version readiness. Live tests passed initial application,
  idempotency, ordering, drift rejection, ahead-schema rejection before
  mutation, synchronous checksum/name/head readiness, bounded retry, dual-head
  readiness, and controller shutdown. Encrypted record envelopes accept exactly
  `29...65536` bytes; live boundary tests reject 28 and 65537.
- [x] The bootstrap-key route now resolves source addresses only through an
  injected trusted-proxy policy and uses a PostgreSQL shared token bucket at
  30/minute with burst 5. It stores only required-pepper HMAC-SHA256 source
  digests, fails closed on database errors, and performs indexed bounded stale
  cleanup. Tests passed untrusted-header spoofing, direct/Tailscale peers,
  separately configured Cloudflare peers, right-to-left trusted hops,
  generic-proxy Cloudflare spoofing, malformed/duplicate/oversized headers,
  separate-pool shared state, exact concurrent burst enforcement, outage, and
  cleanup behavior.
- [x] Every unknown route and wrong method now returns bounded
  `application/problem+json`; method errors include `Allow`. Nil readiness is
  unavailable, every evaluation has an explicit deadline, and controller
  cancellation completed without leaked goroutines. Production requires an
  explicit environment, two PostgreSQL URLs each with exactly one
  `sslmode=verify-full`, and a rate-limit pepper of at least 32 bytes.
- [x] The runtime sets `MaxHeaderBytes` to 16 KiB. A real `net/http` server test
  sends a 64 KiB unrelated header, observes Go's parser-level 431 response, and
  proves the application handler is never called. Parser-generated responses
  are deliberately not claimed to use the handler's problem-JSON format.
- [x] Final verification passed: focused command/API/central tests;
  `go vet ./...`; serial `go test -race -v` with live disposable PostgreSQL
  (34 config/HTTP/command plus 22 PostgreSQL tests); Compose config;
  and a digest-pinned Docker build whose recorded fix-round artifact was
  `sha256:735b0254c050e4ec00e888aaf3a7d77a14804e35e7e0d62904f047381748ead5`.
  This historical build record does not assert the identity of any current
  mutable local image tag.
  An isolated two-start Compose test passed health/readiness on both starts and
  retained `5|5` account plus `3|3` journal heads and equal replay checkpoint/
  durable head (`0/0`) across the existing-volume restart. Its exact
  task-created containers, network, and volumes were removed afterward. An
  earlier race attempt failed with `ENOSPC`; only the 363 MiB task-created Go
  cache was cleared, storage was remeasured, and the complete gates were rerun.

## 2026-08-08 Account trust clean-break Task 8

- [x] Native macOS and iOS account roots now expose only sign-in-required,
  pending approval with a validated six-digit SAS, active, expiring cached
  read-only offline, suspended, and recovery-required states. Production
  active-owner and pending-device flows use the central rendezvous and install
  only the exact accepted trust history/package before activation.
- [x] Mailbox construction and side effects sit below the account gate. The
  Mac cached runtime is selected before construction, opens the existing mail
  database read-only without migration/audit writes, constructs no composer,
  pairing, operation, setup, credential, or action dependency, and exposes only
  cached mailbox navigation. iOS synchronously revokes live capabilities before
  any offline preparation await, uses cache-only reads, and suppresses direct
  cache, compose, AI, Smart Inbox, approval, pairing, wake, foreground, and
  network actions. Both roots close at the exact verified lease expiry.
- [x] Focused verification passed 88 macOS app/runtime tests and 109 account
  runtime tests. The iPhone 17 Pro Simulator `PlainpostTests` target passed
  264/264; the UI target's unpaired QR lane passed while its 12 host-fixture
  lanes skipped without the external Mac fixture. Unsigned macOS Debug and
  Release plus iOS Simulator Release builds succeeded; plist and diff checks
  were clean.
- [x] Debug and Release temporary macOS/iOS bundles inspected after ad-hoc
  signing contained `com.apple.developer.applesignin = [Default]`. QR/camera
  transport and permission copy remain intentionally present until Task 10.
- [ ] Production signing is not accepted: this machine has no Xcode developer
  account or Mac App Development provisioning profile for
  `com.marynavdovenko.Plainpost`. Real Sign in with Apple and biometric approval also
  remain physical signed-device acceptance items; simulator/ad-hoc evidence
  does not claim either production boundary.

## 2026-08-09 Account trust clean-break Task 9 complete

- [x] Account deletion and Sync Node erasure are now separate, explicit
  contracts. Native Account Settings owns `Delete Plainpost Account`; native
  node settings and a local operator CLI own `Erase Sync Node Data`. Provider
  accounts and provider-hosted mail are never deleted. Reachable Plainpost
  clients/nodes erase managed data by default, unreachable nodes remain
  `erasure_pending`, and independently controlled snapshots/keys remain
  `operator_action_required`. No browser dashboard or second node-admin
  identity was added.
- [x] The first closed lifecycle slice defines canonical deletion request/result
  and cleanup check/ack codecs plus schema. Tests reject duplicate, unknown,
  reordered, whitespace, noncanonical binary/integer, unsorted, duplicate, and
  over-16 cleanup-target inputs; result status keeps central, pending-node, and
  operator-action outcomes distinct without Apple token material.
- [x] The deletion service boundary re-locks the exact active actor and trust
  head, reuses the exact unconsumed step-up authorization, appends the external
  journal marker, closes the traffic barrier, and only then applies live
  disablement. A fault after journal append leaves the account transaction
  uncommitted and the barrier closed for replay repair.
- [x] Production account runtime now requires a third owner-only
  `recovery_authorization` scalar artifact. Bootstrap, pagination, and recovery
  rings are purpose-bound and pairwise separate; the offline root remains
  public-only. Focused account/config/runtime/lifecycle/trust/PostgreSQL/route
  packages and the localhost-binding command package pass; schema parse and
  diff checks are clean.
- [x] Recovery, revocation, suspension, add-device step-up, security history,
  deletion, cleanup registration/check/ack, and exact accepted-entry local
  installation are complete. Recovery uses a separate purpose-bound online
  authority, creates a fresh epoch/material set, and atomically suspends prior
  sessions and leases. Ordinary removal rotates both account keys and cannot
  publish a local fork before central acceptance.
- [x] PostgreSQL migration 0012 and deletion-journal migration 0004 persist
  one-time step-up/recovery authority, opaque 90-day security events, cleanup
  registrations/targets, purge outbox state, and versioned opaque deletion
  markers. Independent-pool tests cover competing lifecycle commits, refresh,
  metadata, deletion, cleanup and restore races; all six deletion persistence
  failpoints roll back exactly and retry idempotently.
- [x] Account deletion appends the independent anti-resurrection marker first,
  closes account traffic while replay lags, disables all central authority,
  and drives bounded client/node cleanup. Native clients purge Plainpost-managed
  caches, account authority, drafts/outbox/attachments and notification state;
  provider-hosted mail is never deleted. The Sync Node restore gate stops work,
  purges managed state, acknowledges, and refuses readiness after a restored
  snapshot until deletion is applied. Node-local decommission UI/CLI remains in
  the Sync Node implementation milestone because no node application exists yet.
- [x] Native Mac and iOS security surfaces expose only device platform, local
  labels, opaque security history and cleanup status. Apple identity tokens are
  method-local, nonces are fresh canonical 32-byte values, stale callbacks are
  generation-fenced, and LocalAuthentication is immediately before the exact
  lifecycle capability. Offline roots cannot invoke destructive operations.
- [x] Final automated evidence: live PostgreSQL 17 `go test ./...` passed 312
  tests across 13 packages; focused Go race-detector runs passed 39 in-memory
  and 25 live PostgreSQL tests; `go vet ./...` reported no issues. Full SwiftPM
  passed 2,915 XCTest cases (one expected skip) plus 74 Swift Testing cases.
  The final closed security-event status/cursor hardening reran the affected
  account protocol/runtime aggregate at 162/162.
  iPhone 17 Pro (iOS 26.5) `PlainpostTests` passed 268/268. Unsigned macOS Debug,
  macOS Release, and iOS Simulator Release builds passed. JSON parsing, AJV
  Draft 2020 schema compilation, plist/project lint, and `git diff --check`
  passed.
- [ ] Physical signed-device Sign in with Apple and Face ID/Touch ID acceptance
  remains explicitly unverified. The Apple identifiers and development profiles
  are now configured/downloaded, but this Docker gate did not perform the
  signed physical-device interaction. Simulator and unsigned build evidence do
  not claim that external boundary.

## 2026-08-09 Account trust clean-break Task 11 complete

- [x] A disposable four-service Docker Compose project now runs two independent
  PostgreSQL 17 databases, the real central API, and a public-HTTP acceptance
  runner. The synthetic Apple verifier requires both `PLAINPOST_ENV=acceptance`
  and its explicit switch; development and production reject it.
- [x] The public scenario passed 39 assertions covering two-device bootstrap,
  request proof, matching-code admission, opaque metadata, revocation, fresh
  recovery, deletion-journal ordering, central disablement, and client cleanup
  acknowledgement. Three clean implementation runs produced the same assertion
  base set; the strengthened final project left no containers, networks, or
  volumes.
- [x] Final broad evidence includes the live-PostgreSQL Go suite, `go vet`, the
  rendered Compose contract, a fresh SwiftPM pass of 2,916 XCTest cases (one
  expected skip) plus 74 Swift Testing cases, all account JSON parse checks,
  privacy/secret-boundary scans, and `git diff --check`. Exact Docker versions,
  image IDs, migration heads, scenario scope, and cleanup evidence are recorded
  in `docs/verification/account-trust-milestone.md`.
- [ ] Physical Apple/biometric, APNs, provider mail, production TLS/DNS,
  DigitalOcean, Unraid, real Sync Node application/wipe, and Remote MCP remain
  separate unverified gates. The Docker scenario does not fabricate Sync Node
  enrollment or claim provider-mail deletion.

## 2026-08-14 Sync Node admission clean-break Task 9 verification

- [x] The public-HTTP Swift acceptance lane passed in final disposable project
  `plainpost-account-e2e-77819`: it bootstraps an ordinary Apple owner, performs initial Sync
  Node enrollment and byte-identical replay, rejects ordinary second
  enrollment, proves a malformed replacement leaves the old refresh valid,
  proves a successful explicit replacement rejects both the old refresh and an
  already-issued old bearer at a signed authenticated route before the response
  is reused, and verifies replacement replay. The second enrollment inspects
  the exact HTTP 409 problem response rather than accepting an arbitrary throw.
  Separate Central regressions send otherwise-valid signed Node bootstrap and
  recovery requests through the real authorities and a validly re-signed Node
  successor through generic admission; all reject at the exact principal gate
  before persistence. The only
  direct claim fixture is an isolated disposable PostgreSQL seed because Central
  intentionally exposes no public claim-creation route.
- [x] Docker still did not publish the requested loopback port, so the harness
  used its tested fallback: resolve the exact project's API container, accept
  only canonical private IPv4, prove TCP and HTTP readiness, and pass the
  private endpoint to Swift without printing it. The complete Swift scenario,
  privacy/catalog audit, returned-value/error-body scan, and bounded real
  container-log scan passed. Exact-project teardown removed its containers,
  network, and named volumes, and a post-run check found no Compose resources
  or private temporary directory.
- [x] The acceptance harness now provisions a separate Node-enrollment replay
  key ring and enables the Node runtime only in the disposable API. Its
  post-Swift audit feeds 9 synthetic setup/verifier/matching/key/endpoint/
  credential/lease/identifier markers through the actual disposable inputs.
  A named test-only KDF derives format-valid setup codes, keys, UUIDs, nonces,
  endpoints, replay sealing, and session issuance material, with Swift/Go parity
  pinned independently. The audit rejects intentionally seeded database/log/
  error/config/returned sinks and bounded derived representations, scans at most
  8 rows per Node table through counts only, and examines PostgreSQL catalog
  table/column/index/constraint/function/view names for `pair*`,
  `device_projection*`, `device_compose*`, and `device_send_reviews*` residue.
  Mode-0600 private pattern files catch actual fixture setup data, verifier,
  private scalars, opaque endpoint bytes, IDs, and actual returned refresh/
  lease values in Compose logs/errors, evidence, and rendered configuration;
  they are not published. Before teardown the wrapper now appends at most 500
  lines of actual API, account/deletion-journal PostgreSQL, and baseline-runner
  logs from the exact disposable Compose project to its private log, and a
  separate private sink retains every observed non-success Swift HTTP body (up
  to 32 responses and 64 KiB each) for the same scans. Returned credential
  patterns include the exact unpadded base64url produced by
  `AccountWireCodec`, standard Base64, and hexadecimal. All harness artifacts
  are created under `umask 077`, log-collection failure still triggers the
  exact-project cleanup trap, and focused wrapper/Swift privacy contracts plus
  the 55-test coordinator/codec/vector/privacy lane passed with one expected
  live skip and zero failures.
- [x] Final privacy review now feeds one unambiguous canonical
  `refresh-credential-base64url` record per returned credential plus the
  credential/lease IDs from a separate mode-0600 typed file into the live
  database audit. Swift preserves one record for every returned session without
  set-based collapsing; Go rejects duplicate values or unequal credential,
  credential-ID, and lease-ID counts and strictly decodes unique canonical
  records to exactly 32 raw bytes. Count-only queries then scan those bytes plus canonical base64url,
  standard Base64, and hexadecimal across bounded `BYTEA` and converted text
  sinks in at most eight result rows and their referenced refresh/lease session
  rows. IDs are allowed only in their required
  columns; plaintext remains forbidden in opaque/ciphertext/hash/opposite-ID
  sinks. Each live audit transactionally injects the decoded raw credential
  bytes into a bounded wrong `BYTEA` sink, proves detection, and rolls it back
  before the zero-exposure scan. Project `plainpost-account-e2e-77819` passed
  this guard and left no Compose resources or private directory.
- [x] The discovered client-coordinator defect is fixed: Sync Node approval no
  longer submits its immutable stale trust head. It builds a canonical signed
  successor from the current coordinator state, binds the exact evidence/action/
  claim, and accepts it only after Central returns the exact response. Initial
  admission adds the exact Node record; replacement revokes the exact old Node
  and re-signs the successor inventory at the checked epoch/revision. Focused
  Swift codec/vector/coordinator coverage passed 51/51 after the repair.
- [x] Spec review found and the implementation fixed an action-domain mismatch:
  replacement approval now uses the dedicated replacement transcript in the
  live Swift client, shipping coordinator, and production Central verifier.
  A shared Swift/Go digest vector, a real Swift signature assertion, and the
  Central verifier regression prove the replacement signature is accepted only
  under that domain; the ordinary admission domain remains rejected.
- [x] Live execution found and TDD-fixed boundary defects in whole-second
  bootstrap/refresh timestamps, JSON media-type parameters, offline-lease key-ID
  binding, the obsolete auto-named lifecycle step-up target constraint, and
  trust-head storage. Initial and replacement commits had stored canonical
  binary bytes in `wire_commit`; both now persist the separately marshalled
  public JSON wire, with a focused regression covering both operations.
- [x] Migration 0017 also restores 0012's accidentally removed five-minute
  step-up TTL under the stable
  `lifecycle_step_up_authorizations_ttl_check` name using `NOT VALID` followed
  by validation. Live PostgreSQL 17 rejected equal, reversed, and
  five-minutes-plus-one-microsecond expiries and accepted the exact five-minute
  boundary; historical migration files remain unchanged.
- [x] Broad local Go verification passed with external live-PostgreSQL variables
  unset: `go test ./...`, the required five-package race gate, `go vet ./...`,
  `go mod tidy -diff`, and `go mod verify`. The Draft 2020 account schema
  compiled successfully with AJV (its standard unknown `date-time` format
  warnings are unchanged). Source/route/schema scans found no production legacy
  pairing name or `/v1/pair` route.
- [x] The full Swift gate reached a real terminal pass after TDD repairs to the
  local test harness. Three stale external-process probes had called an
  unavailable developer XPC service and inherited its intentional 300-second
  production deadline; equivalent injected-service/gate-unit coverage remains,
  and the CLI injected regression now covers all four mail actions. The
  remaining test-only process helper is bounded at 45 seconds and has a
  deterministic TERM/SIGKILL/reap regression. Stale legacy `Paired Devices`
  UI expectations and the sidebar source locator were also aligned with the
  current production model. A definitive fresh run passed 2,336 XCTest cases
  (2 skipped, 0 failures) and 73 Swift Testing cases (0 failures). No
  production XPC deadline or runtime behavior changed.
- [x] Focused follow-up review approved the private fallback, cleanup, live
  semantics, privacy scans, migrations, and trust-wire persistence with no
  Critical or Important findings. This follow-up completion commit records that
  evidence. No Noise transport/dependency/framing or Task 8 API was added or
  claimed.

## 2026-08-14 Sync Node admission response-loss repair

- [x] The shipping Apple coordinator now treats only a post-submit uncertain
  transport failure as replayable. It retains one bounded in-memory canonical
  admission request (including its original approval signatures and
  idempotency key), exposes an explicit retry action, and never cancels the
  claim on that path. Retry resends the same request; confirmed success or an
  explicit cancel overwrites and drops the replay arrays and setup verifier.
  Passive view disappearance/background navigation clears only presentation
  inputs and replacement consent; the uncertain request remains retryable and
  does not issue a claim cancellation.
  Deterministic non-5xx remote rejections retain the terminal failure path.
- [x] A fresh focused Swift run passed 17 XCTest cases with zero failures:
  the 9 coordinator cases, 3 response-verifier cases, 4 enrollment view-model
  cases, and a 503 classification regression. The response-loss fixture
  commits then drops its first response; retry reuses every signed field and
  the idempotency key, accepts Central's replay result, and records no cancel.
  A separate cancel fixture proves replay/setup material is removed and the
  claim cancellation is attempted. The focused Go Node-enrollment suite also
  passed with external live-PostgreSQL variables unset. This focused evidence
  complements the later successful full-Swift and public-HTTP acceptance gates
  recorded above.

## 2026-08-16 Sync Node private Swift transport (Task 6)

- [x] Review remediation completed and passed fresh independent Sol Standards
  and Spec review with 0 Critical and 0 Important findings. The accepted
  repair adds the purpose-separated Go V3
  bootstrap route, explicit endpoint-port parity, client-signed session sends,
  activation-before-metadata ordering, revision-aware account-record CAS
  convergence without pre-advancing local high water, authenticated restart
  reconstruction, manifest high-water use, and non-regressing Keychain
  sequence saves. The final repair keeps a signed exact pending request across
  transport ambiguity and completes metadata/Keychain publication as one
  resumable post-V3 workflow. A fresh disposable PostgreSQL 17 owner now validates V3
  atomic activation/replay/concurrency and privacy markers with the same
  current-authority readiness migration as production. It makes no Task 7,
  deployment, or Unraid claim.

- [x] Task 5 and Task 5A are accepted. Sol's final independent two-axis review
  closed at **0 Standards / 0 Spec** findings; their session-authority and
  cleanup-capability contracts are the only admission artifacts consumed here.
- [x] The production Apple runtime now verifies Central's closed V2 admission
  before decrypting the setup-code endpoint envelope or contacting the Node.
  It uses canonical `https://<label>.ts.net:<port>` URLSession TLS only, sends
  V3 activation, retains an uncertain request for byte-identical private retry,
  and stores only endpoint ciphertext, signed session documents, and a
  Keychain-CAS sequence owner. Canonical endpoints are published only inside
  existing `EncryptedAccountRecordV1` metadata; no Central endpoint plaintext
  path was added. Evidence: `docs/verification/sync-node-task-6-private-transport.md`.
- [x] Independent Sol review accepted the final Task 6 range through
  `d59e57ee`. The final full Swift gate passed locally. Review remediation
  authenticates restart journals with the
  canonical public claim proof, fails closed on corruption/substitution/bounds,
  scans setup-code raw/base64/hex absence, and has a deterministic in-flight
  cancel/reset successor fence. The PG17 harness has a private-container
  fallback for this host's broken loopback publication, but its fresh owner run
  is still pending; no deployment, Unraid, Cloudflare, or Task 7 live-harness
  result is claimed. Task 7 live acceptance remains separate and pending.

## 2026-08-16 Sync Node private transport local acceptance (Task 7)

- [x] Implementation is complete and independent Sol Standards and Spec reviews
  APPROVE (0 Critical, 0 Important). The disposable private harness passed
  Central admission/current
  authority/replacement/deletion PostgreSQL owners, Node V3/sequence/restart/
  readiness PostgreSQL owners, the production Go route/middleware composition,
  and the exact Swift private client boundary. Privacy scans found zero bounded
  private markers in actual logs, errors, rendered config, or database dumps.
  PostgreSQL had zero host-published ports; no public Node listener was created;
  exact cleanup left zero labeled Docker resources. Evidence:
  `docs/verification/sync-node-private-transport.md`.
- [x] Task 7 Spec repair removes the durable plaintext setup-code file.
  Inactive startup retains only encrypted pending installation state; the
  explicit local `enrollment-presentation` command re-derives bounded JSON to
  its invoking stdout, and the harness deletes its mode-0600 captures after
  decoding. Both production Node relays negotiated TLS 1.3 and rejected TLS
  1.2. File-backed curl problem/stderr surfaces were scanned; a deliberate
  private-marker copy was detected before the clean scan reported zero.

## 2026-08-28 Sync Node Unraid private-beta release gate (Task 6)

- [ ] The Task 6 release owner is implemented fail-closed but remains
  **INCOMPLETE**. It requires explicit `PLAINPOST_RUN_GMAIL_E2E=1`, two
  mounted mode-0600 Gmail JSON credential files, verifies the exact release
  artifacts and one-PostgreSQL/two-database production Compose shape, and invokes the
  repository-owned native-TLS owner when prerequisites exist. That owner stops
  after TLS healthz; the precise missing code-level owner for Gmail/two-client
  acceptance, mutations, recovery, backup/restore, replacement fencing,
  notification, erase, and privacy/network scans is reported rather than
  fabricated. The wrapper never trusts caller-supplied PASS evidence, emits
  stages only after owned operations, and proves exact disposable-tree
  cleanup. Evidence: `docs/verification/sync-node-unraid-private-beta.md`.

## 2026-09-28 iOS and macOS mail integration

- [x] The owner selected both `feat/ios-standalone-mail-polish` and
  `feat/macos-sync-node-mail-mode` for local `main`. Their changes are combined
  in an isolated integration worktree so the unrelated main checkout files
  remain untouched.
- [x] Merge conflicts are resolved; the combined Swift package manifest
  validates. Cross-branch schema, SMTP, Gmail, and Node broker API differences
  found during compilation are reconciled.
- [x] Review the full combined Swift test run. It found one stale Node
  admission fixture expectation; the corrected test passed its focused rerun.
  The initial full run therefore remains red, with no other reported test
  failures. Focused service routing, direct send, and journal tests passed.
- [x] Build the combined iOS Release app for a generic iPhone destination
  without signing.
- [x] Inspect the final merge diff, confirm there are no unresolved paths or
  whitespace errors, and preserve the unrelated untracked main files.
- [x] Advance local `main` to the integration commit and confirm both feature
  tips are ancestors. Unrelated site icon edits and `docs/design/` remain in
  the worktree outside this merge.


## 2026-09-30 — Architecture/performance baseline evidence (Task 1)

Source baseline `95e006094d62802cfa259a8b36b11de29f5392f3` in the isolated architecture worktree. Added shell-free iteration/provenance tooling, explicit search warmups and count-only signposts. Focused runner tests:11/11; benchmark support:26/26; native synthetic projection:1/1 with10 actual signpost rows. Collected45 required successful warm samples; raw results/compiler/link actions: `output/architecture-baseline/iteration/summary.json`.

Commands: `rtk proxy python3 Scripts/test-measure-dev-iteration.py`; `rtk swift test --filter MailSearchBenchmarkSupportTests`; runner-wrapped verbose Swift builds and Xcode `-showBuildTimingSummary`. Prescribed hyphenated unittest discovery exits5 with0 selected; direct invocation is the actual gate. Release synthetic search fails invalidQuery(empty) with0 and3 warmups; iOS execution attempt bounded at212.219 seconds without tests. No installed-device, controlled-cold, full-suite or speedup claim. Report: `docs/verification/2026-09-30-architecture-performance-baseline.md`. No production store, deployment or user-cache deletion.


### Task 1 review round 1 — mixed test engines and existing warnings

Corrected the iteration runner to combine independently recognized passing Swift Testing totals with authoritative XCTest totals. Failed, incomplete or unknown present Swift Testing summaries make counts unavailable; they never leave a partial, apparently failure-free XCTest inventory. Command: `rtk proxy python3 Scripts/test-measure-dev-iteration.py`. RED: 18 tests, 8 failure entries; GREEN: 18 tests, zero failures. Raw artifacts: `output/architecture-baseline/task-1/review-round1-red/` and `review-round1-green/`. Read-only reparse of the preserved final Swift log and five execution logs confirms 26 cases / zero failures in each; no Swift/Xcode rerun.

Existing warning follow-ups remain outside this source scope: missing-import/actor warning in `PlainpostSettingsViews.swift:289`; capture ownership in `BrowserNativeHostRegistration.swift:159`; isolated conformance in `PlainpostMenuBarMark.swift:152`; deprecated Security APIs in `MacVaultKeyProvider.swift:136`, `:141`, `:179`. Output is not pristine, but these unchanged sources do not invalidate the selected 26-case pass. Release search, iOS execution and installed-device gates remain explicitly unresolved.

## 2026-09-30 — Trustworthy local verification profiles (Task 2)

Source commits `6d641650e20c6a46f3f3c822c746bebd3646d1d5` and `3a98b27bd31a7f31e63f0256d35af7db642e88b4` establish six explicit verification profiles with current-build discovery, per-target typo guards, retained logs, mixed-engine inventories, nonzero/complete execution and structured Xcode summary requirements. Historical phone identifiers retain current-shell action reachability, both-account mutation ownership, grace Reply-draft routing, compact settings bounds/device copy and blank-body typing. Repaired stale assembly predicates preserve runtime/store/authority protections; no product redesign.

Commands and results: `rtk proxy python3 Scripts/test-verify-profile.py` final 15/0, zero skips; prescribed hyphenated unittest discover exit 5/zero tests remains failed. `rtk swift test --filter IOSMailProductAssemblyTests` reproduced 7 tests/2 assertion failures, then passed 7/0. One `verify-profile.py --profile NAME --output .build/task2-evidence/profiles/NAME` sample per tier: core 499/0 (original inventory reconciled from 463 to 499), db 530/0, UI 1500/0. Service and integration correctly fail: complete raw totals 1709 with 7 live/fixture skips and 422 with 1 interactive fixture skip, respectively. Task1's counter omitted their skipped XCTest footers and recorded partial1120/38 inventories; original artifacts and independent reconciliations are retained, and the controller assigned its fix back to Task1.

iOS is unavailable: QA simulator255CC905 readiness stalls (bounded30s profile prerequisite); direct xctestrun execution produced no tests in457.43s, terminated only its owned invocation with exit143. Final changed phone source freshly compiled with `xcodebuild build-for-testing ... ONLY_ACTIVE_ARCH=YES ARCHS=arm64`, exit0 in7.96s; exact arm64 bundle/xctestrun hashes are retained. Compilation is not simulator/device acceptance. No simulator reset or physical installation.

Bounded original-source95e006094 Release comparison and restored-current rebuild both throw identical invalidQuery(empty) for equivalent10k/1iteration/zero-warmup fixtures; Core/DB source diff is empty and current benchmark bytes restored exactly. This proves a pre-existing Release gate, not its parser/toolchain root cause; budgets remain unchanged/failed. Raw evidence: `.build/task2-evidence/`, including final-python, assembly-red-authorized/assembly-green, profiles, core/service/integration inventory reconciliations, original-comparison.json, original-release-run/current-release-run and ios-final-arm64-build-owner.json. Full report: `.superpowers/sdd/2026-09-30-architecture-performance/task-2-report.md`; usage: `docs/development-verification.md`. Full-suite/complete device/external live gates remain for controller integration. Disk remained above15GiB (final19GiB); no cache/data deletion, external mutation, deployment, push or merge.


### Task 1 review round 2 — skipped XCTest engine totals

Parser commit `d64e67b40ec04c6916e1c2fe61ae21e7b7e81282` corrects skipped-footer omission and fails closed for unknown/incomplete engine summaries. Count semantics: selected-case `executed` includes skips; `skipped` is disclosed separately; non-skipped equals executed minus skipped. No-skip recognized summaries now report zero; ambiguous Swift Testing skip events remain unavailable. Existing 18 contracts are preserved, with eight added regressions. Covering command: `rtk proxy python3 Scripts/test-measure-dev-iteration.py`; full RED 26 tests / 18 failure entries, final GREEN 26 / 0 failures / 0 skips. Raw runner-wrapped evidence: `output/architecture-baseline/task-1/review-round2-red-complete/` and `review-round2-green-final/`.

Preserved-log reparse: service 1709 including 7 skips (1702 non-skipped), integration 422 including 1 skip (421 non-skipped), both still failed. Six original focused Swift logs remain 26 / 0 / 0. Read-only raw/result/profile SHA-256 hashes and corrected counts: `output/architecture-baseline/task-1/review-round2-reparse-final/`. Original measurement status/timing metadata unchanged; no broad Swift/Xcode rerun. Existing warnings and unresolved Release/iOS/device gates remain recorded.

### Task 2 review round 1 — iOS execution SDK/cache provenance

Fix commit `093562f6e565e3f27b6b078f7f5cfd3b5b4affe1` supplies the simulator SDK and exact derived-data cache to iOS execution measurements, matching build/discovery. Swift measurement defaults remain unchanged. A synthetic passing iOS orchestration regression preserves real measurement argv construction and validates all five selections, structured counts, retained manifest and `.xctestrun` owner; a separate real-wrapper case checks Swift default provenance. Covering command: `rtk proxy python3 Scripts/test-verify-profile.py`. Valid RED: 17 tests / 1 failure / 0 skips; GREEN: 17 / 0 / 0. Raw runner-wrapped evidence: `.build/task2-evidence/review-round1-red-valid/` and `review-round1-green/`; initial fixture-schema probe is preserved separately. Report append: `.superpowers/sdd/2026-09-30-architecture-performance/task-2-report.md`.

No simulator/Swift build or test suite, broad acceptance gate or profile sample rerun was needed for this metadata fix. Original failing/unavailable artifacts, live/interactive skips, prescribed discovery failure and Release/device blockers remain unchanged; synthetic orchestration is not installed-device acceptance. Scoped independent re-review follows. The detailed SDD report remains preserved locally and ignored; only this plan's newly tracked report was removed from the index, without deleting its working file or changing other plans' reports.


### Task 2 Release gate — optimized lexer predicate

Fix commit `b5b08a41372cc9ea4ba4238a2929ccd0a1b76bed` replaces only the lexer's bound control-character membership reference with an explicit closure, preserving the same all-scalar predicate and Release optimization. Count-only diagnostics proved optimized Core discarded ordinary letters; a reduced Swift 6.4 whole-module counterexample reproduces the interaction with the module's contains(where:) bound reference, while Debug and the closure variant agree with direct scalar membership. New XCTest requires valid ASCII/Unicode/grapheme tokens, original UTF-16 ranges and unchanged control rejection.

Commands: `rtk proxy swift build -c release --scratch-path output/architecture-baseline/release-cache --product PlainpostSearchBenchmark` and matching existing-cache Debug build passed. Local `rtk proxy python3 .build/task2-release-evidence/validate.py release --regression` uses actual optimized Core products: original-source RED 1/1/0, final GREEN 1/0/0; `validate.py release` and `validate.py debug` execute the same 63 focused parser/scope/authentication tests, both 63/0/0. Nine indexed synthetic actual-Core XOAUTH2 framing cases pass before/after in Release and after in Debug. Same synthetic benchmark `--messages 10000 --iterations 1 --warmups 0` completes in Debug and Release with seven nonempty measured groups, exact dataset counts, observed cancellation, `passed=true` and no correctness/performance violations. Raw logs, exact argv/configurations/hashes and restored diagnostic sources: `.build/task2-release-evidence/`; ignored full report: `.superpowers/sdd/2026-09-30-architecture-performance/task-2-release-report.md`.

This repairs the previously blocked bounded Release workload; 30-iteration/50k/100k acceptance, broad package/integration gates and phone/live-provider verification remain controller-owned. No optimizer switch, swallowed failure, external mutation, install, push/merge or cleanup. Original failure evidence is retained. Disk stayed above15GiB (last16.676GiB); the underlying compiler defect is worked around, with independent review pending.

### Task 3 — shared fixture dependency slice

Removed the unused DB import/manifest dependency without changing any public fixture bytes. Starting source: `534293b418dbacbce61e1e21a1575910767907b8`. `rtk swift build --target PlainpostTestSupport` passed; `rtk swift test --filter PlainpostCoreTests` passed 240 tests / 0 failures / 0 skips. Manifest closure falls from eight nodes to four (Core, AccountProtocol, ComposeHash, TestSupport), excluding DB/GRDB. Raw artifacts: `output/architecture-baseline/task-3/fixture-target-build/`, `core-tests/`, `fixture-closure.json`. Initial sandbox-discovery failure and authorized retry remain retained.

Five matching fixture leaf samples before/after are a new workload, not comparable to Task1's UI leaf. Matching Task1 public Core API edits still compile 280 source labels and link twice per sample; the app dependency graph remains broad. No speedup claim. Evidence: `output/architecture-baseline/task-3/{before-fixture,after-fixture,after-core}/`. Test migration and profile ownership remain pending. Existing Debug cache only; disk floor15GiB, no cleanup or external mutation.

### Task 3 — storage, service and benchmark ownership

Fixture slice commit: `376b83978b4aa3cfc5d87c363fd36e62d9410923`. Two foreground account-deletion IPC tests now belong to ServiceTests; all 26 benchmark tests move byte-for-byte to SearchBenchmarkTests. Narrow test-only AccountDeletionTestSupport owns shared setup/audit assertions, with checked Sendable values and caller XCTest file/line reporting; only DBTests/ServiceTests depend on it. DBTests manifest closure shrinks23→14 nodes and excludes Service, ServiceIPC, ServiceRuntime and SearchBenchmark. CoreTests shrinks9→5; UI closure stays18, with no new fixture edge.

Current-source discovery preserves4661 exact identifiers after28 explicit target/class renames, with no added/lost tests and exactly one profile owner per discovered test. Counts: DB530→502, Service118→120, benchmark0→26. The DB profile owns the benchmark target and still requires a nonzero inventory. `rtk proxy python3 Scripts/test-verify-profile.py`: RED18/1/0, GREEN18/0/0. `rtk swift test --filter 'PlainpostDBTests|PlainpostServiceTests|PlainpostSearchBenchmarkTests'`:648/0/0 in273.415s; every discovered selected name actually passed, including migration/source-alias, RSS/warmup/provenance and IPC restart/no-remote-mutation protections.

Raw artifacts: `output/architecture-baseline/task-3/` (`test-inventory-comparison.json`, `execution-inventory.json`, `manifest-closure-comparison.json`, `source-preservation.json`, `fixture-assertion-parity.json`, `profile-{red,green}/`, `migration-tests/`, `after-discovery-sendable/`). Initial sandbox failure and two migration compiler failures are preserved; final source compiles. Verbose aggregate discovery still compiled135 source labels, including UI, and linked8 times after final fixture correction. Matching Task1 Core API edits retained the same cache/SDK/configuration identity and280/2 action counts; timing is contended, with no speedup claim. Existing compiler warnings/CoreData XPC noise remain. No full suite/profile/live/device/production gate rerun; Task2's wider live skips remain recorded. Worker made no cleanup, push, merge or external mutation; controller separately performed user-approved exact-cache cleanup after floor pressure.


### Task 7a — per-dispatch scheduling results

Fix commit `51ce7d085c4cc7093ee59bdd6763f7d11f39caa9` replaces the router's shared last-dispatch flags with a private result carrying the unchanged public dispatch plus its own pending reason. A continuation-controlled independent-account test pauses client lookup, interleaves target-blocked/transient work, and checks unavailable-head stop behavior plus row-local stall accounting. Original-source RED before repair:1 executed/9 assertion failures/0 skips; exact final-test RED:1/2/0. Final focused regression:1/0/0. The wrong-old target-wait behavior is reproduced; no speculative provider rewrite.

Commands: `rtk swift test --filter MailIntentRouterTests` passed54/0/0; sibling `--filter 'MailIntentRouter(FixRound|Deferral|Ordering)Tests'` passed29/0/0. Current-build `rtk proxy swift test list` discovered83 exact router identities; execution inventory confirms all83 passed once across the final gates, with no missing/unexpected/skipped cases. Lost-ack exact-byte replay, restart, same-row exclusion, per-target ordering, direct deferral and uncertainty protections pass. Raw runner logs/results, old/restored source hashes and inventories: `output/architecture-baseline/task-7a/`; ignored full report: `.superpowers/sdd/2026-09-30-architecture-performance/task-7a-report.md`.

Initial sandbox manifest-cache failure is preserved separately and is not RED evidence. Existing aggregate-build unused-result warnings in `IMAPHarnessTests.swift:1399,1425` remain; no warning originates in changed files. Existing worktree Debug/macOS cache only, latest disk16.159GiB above15GiB floor. No public/wire, gate admission, service shutdown, earlier-task ownership/profile/tooling changes, broad suite, external mutation or cleanup. Full integration/device/production acceptance remains controller-owned.

### Task 4 — owned and coalesced mail refresh work

Implementation commit `be5dd539b05547e247b53b411ee24bed4b51942b` replaces per-revision tasks with one attach-owned worker and one merged pending domain set. Synchronous subscriptions retain final revisions, selection/account publication guards reject obsolete results, and overlapping attachments wait for the prior cancelled owner to join. Directory visibility requests the same worker (including first show); hiding invalidates admitted loads. Bootstrap directory work remains a joined concurrent child so approvals load independently. Narrow search, snapshot, node-status, approval and Smart Inbox cancellation fences preserve cached rows/errors and admitted durable completion.

Prescribed command: `rtk swift test --filter 'MailActivityCoordinatorTests|MailSessionTests|MailboxDirectoryTests|MailStoreChangeMonitorTests'`; final current-source result68/0/0. Adjacent node/approval/search/host assembly gates and existing snapshot cache/error/paging probes bring the latest unique inventory to105/0/0, all expected identities present. Deterministic RED: baseline62/9 assertion failures/0 skips (21 admitted reads for20 revisions; early detach and late publication), generation2/4/0, owned directory/search3/12/0, approval1/2/0, Smart Inbox1/3/0, overlap1/1/0. Released barriers prove cancellation joins non-cancellable reads; no sleep-based ordering in new probes. Session deallocation and post-cancellation reattach pass.

Raw logs/results, per-run executed names, base/final source hashes and105-case coverage reconciliation: `output/architecture-baseline/task-4/`. Full ignored report: `.superpowers/sdd/2026-09-30-architecture-performance/task-4-report.md`. Initial manifest sandbox failure and authorized retry are retained. An intermediate build was stopped with exit130 after a mistakenly batched preflight showed14.76GiB free; it compiled but executed no tests. Controller-approved exact-cache cleanup restored headroom; worker deleted no data/caches. Later allocations passed the15GiB floor (last27.6GiB). Existing unrelated compiler warnings remain; no changed-line warning. No stale skip-build, broad suite, iOS compile/device execution, external provider, deployment, push or merge claim. Final iOS host evidence is source assembly/model tests; device/integration acceptance remains controller-owned.

### Task 4 review round 1 — cancelled activity observation

Fix commit `105227265ff835efd1f9c52da088ef4c3bfb6856` adds the missing post-await cancellation check before the coordinator recomputes activities. The actual coordinator regression establishes observation through its first published activity, synchronously changes Smart Inbox presentation and cancels attach in one MainActor turn, then joins attach and requires no second publication. Unchanged-source RED:1 executed/2 assertion failures/0 skips. GREEN: `rtk swift test --filter 'MailActivityCoordinatorTests|MailSessionTests|MailboxDirectoryTests|MailStoreChangeMonitorTests'` passes69/0/0 with the exact same test bytes.

Raw logs, old/fixed source bytes, unchanged test hashes, source-restoration check and selected inventories: `output/architecture-baseline/task-4/review-round1/`. Prior105-case artifacts remain unchanged; latest union106 expected/passing identities has no missing/extra/duplicate entries. Only the coordinator and its test changed. Existing unrelated compiler warnings remain recorded; no broad suite/device/provider rerun. Disk preflights27.6/28.3GiB, existing Debug cache only, no cleanup or external changes. Full fix append: `.superpowers/sdd/2026-09-30-architecture-performance/task-4-report.md`.


### Task 5 — actor-owned notification and inbox metadata reads

Implementation commit `cd59e4829b4f7db5bcb39cec78547e212921b6ea` adds body-free notification identity keyset batches (at most 256 IDs), hashes existing token rules on the projection actor, and returns waiting-intent state/source authority with inbox pages. The actor rechecks account/source authority after reads; the runtime checks its selected identity and request/invalidation generations after the final await. Source changes during page, waiting-journal or selected-thread reads reject old results. Existing mutation source checks and Task4's shared search loader/cancellation fences remain intact. Unknown tokens still require O(N) identities; there is no token index or process-RSS claim.

Prescribed `rtk swift test --filter 'NotificationNavigationTests|WaitingForSyncNodeProjectionTests|InboxProjectionRepositoryTests|PlainpostAppRuntimeTests'` passes 133/0/0. Final focused notification/waiting classes plus affected SQLite identity tests pass 20/0/0; latest inventory reconciles 135 unique passing identities with no missing/extra/skipped cases. Original-source notification RED observes one unbounded body query on MainActor at both 10k/100k; source-switch RED 2/4/0 and revision RED 1/2/0 reject neither stale rows nor main-thread journal reads. A bounded original-runtime probe also reproduces removed-account/read-error token resolution and post-detail stale publication: 3/4/0. Counts are executed/assertion failures/skipped; preliminary compile/fixture failures are separately retained.

Final synthetic traces: 10k/100k notification scans use 40/391 bounded identity queries, zero body queries and zero MainActor SQL. Each inbox projects 200 rows with one waiting query, zero body/MainActor SQL reads; an explicit held-query barrier lets a MainActor heartbeat complete. Database tests verify 256/256/88 keyset boundaries, deleted/ambiguous/legacy ownership and propagated read errors. Raw results, test inventories, synthetic counts, original/final sources and committed hashes: `output/architecture-baseline/task-5/`. Full ignored report: `.superpowers/sdd/2026-09-30-architecture-performance/task-5-report.md`.

One intermediate gate crashed after an existing accessibility test was converted to async: the captured stack proved an off-MainActor UI test call; marking that test MainActor fixed it, with no production workaround. Existing unrelated compiler warnings/CoreData XPC noise remain. Initial compiler-cache/Git-index sandbox denials were retried with authorization. Existing worktree Debug/macOS cache only; every build preflight stayed above 15 GiB (about 28 GiB), no user-data/cache cleanup, push, merge or external changes. These are local synthetic/model tests, not iOS/device/provider/production acceptance; wider integration remains controller-owned.


### Task 6 — shared mail-session lifecycle ownership

Implementation commit `b011ce2a6caafae21710415ee4bf14b140b08b52` strengthens the existing shared modifier: all host hooks are required, all three AI consumers configure on initial attachment, and account-search refreshes use Task 4's attach-owned worker. The existing reader operation now captures selection/account revision and fences late alerts and snapshot publication while still awaiting admitted work and reporting current failures. Both hosts retain their presentation behavior; mobile approvals explicitly have no selected row. The nine-owner behavioral table and unchanged Undo/account-switch/background assertion contracts are in `docs/verification/2026-09-30-mail-session-lifecycle.md`. Task 5 actor/source code is unchanged.

Prescribed `rtk swift test --filter 'MailSessionLifecycleTests|MailSessionTests|MessageActionControllerTests|ComposeCoordinatorTests|PlainpostRootViewTests'` passes126/0/0. Focused coordinator, attachment-state, mobile navigation, composer/root and iOS assembly checks pass66/0/0. Current-build `rtk proxy swift test list` reconciles192 unique passing selected identities with no missing/extra/duplicate/skipped cases. Hosted original-algorithm RED2/8/0 proves missing initial configuration and four concurrent search reads; reader RED4/8/0 proves stale errors/publication. Same regression bodies pass; final lifecycle class19/0/0. Counts are executed/assertion failures/skipped.

Raw logs, executed-name inventories, pre-run source snapshots/SHA-256, normalized preguard method-extraction equivalence, regression-body parity and committed-source hash reconciliation: `output/architecture-baseline/task-6/`. Full ignored report: `.superpowers/sdd/2026-09-30-architecture-performance/task-6-report.md`. Every admitted build stayed above15GiB (minimum27.54GiB), using only existing worktree Debug/macOS cache. Initial sandbox compiler-cache/Git-index denials and the first hosted render-timing probe are retained/reported; authorized retries passed. Existing unrelated settings compiler warning, StateObject/FocusState warnings and CoreData XPC noise remain.

These are current-source/model and Mac NSHostingView checks, not installed-app acceptance. No iOS cache was present; fresh iOS compilation/execution and installed Mac/`olhapi iphone` checks remain controller-owned integration gates requiring concrete candidate and installation approval. No device mutation, cache/data deletion, external change, push or merge.


### Task 6 review follow-up — actual iOS host compilation

Current source at `709e763fbed032f6109632b3c73e42011a3889d7` passes the focused generic iOS Simulator app build in 42.772 s, with no source changes. Exact command: `rtk proxy xcodebuild -project Apps/PlainpostiOS/Plainpost.xcodeproj -scheme Plainpost -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/ios-simulator-debug-build build ONLY_ACTIVE_ARCH=YES ARCHS=arm64 CODE_SIGNING_ALLOWED=NO`. This uses the repository's existing tracked app project and supported build workflow; its local package reference resolves to this worktree. No project regeneration or broader two-scheme/integration rerun.

Exit 0 / BUILD SUCCEEDED, iPhoneSimulator27.0 SDK, target arm64-apple-ios26.0-simulator. Actual compile records and fresh object hashes cover MobileMailShell, shared lifecycle/session, Task4 coordinator and Mac/shared root. Demangled MobileMailShell object defines its private hooks getter and references the full six-required-callback initializer. Explicit pre-run revision / 16 input hashes/bytes, raw logs, compiled-files/product manifests and symbols are retained at `output/architecture-baseline/task-6/review-round1-ios-build/`; same ignored Task6 report has details. All inputs remained unchanged, and Task 6's 192 passing-test source hashes still match.

The local iOS body compile gap is closed, including Task4's host-body compilation boundary. No tests executed, simulator boot requested or physical app installed; installed Mac/`olhapi iphone` and full integration gates remain pending. Existing unrelated compiler/deprecation/concurrency/headermap warnings are retained. Disk 27.53→26.53 GiB stayed above 15 GiB; only fresh worktree DerivedData allocated, no cleanup, foreign process action or external mutation.


### Task 7b — cancellation-aware runtime admission

Implementation commit `129ea57a8b0181e74301690bfcf8fd4bf4f2a263` makes private gate acquisition throwing with uniquely removable waiters. Cancellation/grant races settle one permit, and the owning runtime joins its heartbeat and returns any permit before exiting. Caller-specific pre-admission lease/refund policy and token ownership checks remain intact. A per-invocation provider-entry marker prevents the reproduced unsafe refund of an admitted approved delivery; existing sync/AI/mailbox policies and public APIs remain unchanged. Cancelling a foreground observer leaves admitted durable work alone.

Prescribed raw command `rtk proxy swift test --filter 'LocalOperationRuntimeLeaseFenceTests|LocalOperationRuntimeSelectedWaitTests|InteractiveAIPreemptionTests|LocalOperationsTests'` passes135/0/0. Fresh `rtk proxy swift test list` discovers4710 identities; all135 selected exact identities passed once, no gaps/extra/duplicates/skips. Original-source initial RED2/12/0 proves held cancelled waiters later enter the provider; race RED5/11/0 proves grant cancellation and unsafe delivery refund. Exact final-test old-source RED19/27/0 precedes byte-exact restoration and final GREEN; counts are executed/assertion failures/skips. Protections cover replacement lease CAS, one-shot refund/retry, later account progress, provider ambiguity, observer loss, selected/source/ABA fences, backoff and AI preemption. Real loopback SMTP DATA barriers preserve sent/completed or deliveryUncertain after owning-caller cancellation, each with one accepted message.

Raw logs/results, per-run admitted source/test bytes and SHA-256, final test parity, source restoration/extraction equivalence and committed-source reconciliation: `output/architecture-baseline/task-7b/`. Full local ignored report: `.superpowers/sdd/2026-09-30-architecture-performance/task-7b-report.md`. Preliminary fixture/compile/sandbox failures are retained separately from valid RED. Existing unrelated compiler warnings remain; no changed-file warning. Every allocation admission stayed above15GiB (minimum25.40GiB), existing worktree Debug/macOS cache only. No cleanup, foreign process/device action, provider redesign, XPC change, push/merge or external mutation. These are local runtime/store and loopback SMTP checks; broad integration, iOS/device and production acceptance remain controller-owned.


### Task 7c — joined service account-change lifetime

Implementation commit `83531c51a668d4680fc7ac387ae6283e91d5163a` retains one coalesced account-change flight and a shared shutdown join. Stop closes observer admission, cancels/joins the existing fallback, joins admitted startup and account work, then stops the supervisor. Notifications received during a suspended pass request one fresh account read; admitted durable signals settle without cancellation. The existing one-shot start contract, Direct/Node filtering and post-await state guards remain. Reproduced startup-vs-stop and overlapping-stop races are covered within this monitor; service/provider/runtime ownership is unchanged.

Prescribed raw command `rtk proxy swift test --filter 'ServiceMailMonitorTests|PlainpostServiceOperationsTests'` passes59/0/0; monitor-only gate passes12/0/0. Fresh `rtk proxy swift test list` discovers4714 identities, with all59 selected exact identities passing once and no gaps/extra/duplicates/skips. Unchanged-source RED executes4 tests/10 assertion failures/0 skips: observer work outlives stop,20 notifications start22 reconciliations, concurrent stop returns early, and suspended startup recreates a watcher after supervisor stop. Final test bytes match RED exactly. Held continuations establish admission/parked fallback;100ms inverted expectations bound noncompletion observations.

Raw results/logs, per-run admitted source/test bytes and SHA-256, discovery reconciliation and committed-source identity: `output/architecture-baseline/task-7c/`. Full ignored report: `.superpowers/sdd/2026-09-30-architecture-performance/task-7c-report.md`. Preliminary sandbox failure and an overfulfilled-expectation fixture crash are retained separately from valid RED. Existing unrelated IMAP harness warnings remain; no changed-file warning. Every build admission stayed above15GiB (minimum23.89GiB), existing worktree Debug/macOS cache only. No cleanup, foreign process/device action, provider/Go rewrite, external mutation, push or merge. These are local service/store tests; broad integration, iOS/device and production acceptance remain controller-owned.


### Task 8 — paging cursor deferred by scale evidence

Conditional evidence/design gate evaluated against unchanged production `a8cea456e5ef6e9aace28b40681a48e17f351700`. Test-only SQLite statement/result-row probes confirm both the repository actor and actual runtime hydrate 11,000 Inbox plus 11,000 Sent list messages across ten 200→2,000 requests: ten queries per list, twenty separate total-count queries, one separate unread-group aggregate query. Returned aggregate rows do not measure internal rows scanned. The repeated-prefix work is real; a cursor replacement has not been implemented.

A complete-group CTE prototype, preserving the actual newest `(date,id)` representative and visible date-descending/id-ascending group order, cost about 2.0s per ten pages versus 0.165s for existing Inbox prefix reads at 10k. Narrowing candidate columns did not remove that regression. A once-per-revision group-identity snapshot was also rejected at scale: paired 30-sample, matched-decoding synthetic tests yield ten-page p95 0.17738→0.20369s at 50k and 0.17157→0.37021s at 100k messages per mailbox. Both runs use identical source/test bytes, Debug/macOS/arm64/Swift6.4/Xcode27 and the existing cache; these are database-work timings, not installed scrolling or selection. The comparison omits existing repeated UI row grouping/formatting and does not establish an end-to-end regression or reject every cursor design. Same-process RSS observations are retained but do not establish an attributable memory comparison. Task1 installed selection/deep-scroll p95 and memory acceptance remains incomplete.

A bounded indexed anti-join feasibility check found native thread and recency indexes, but no index for the exact normalized-subject legacy conversation identity. The current indexes cannot bound complete legacy group discovery; no further prototype or schema redesign was attempted. This defers the tested designs, not every possible future indexed cursor. Independent Inbox/Sent destination routing remains a potential narrower follow-up. No production behavior or existing tests changed; only this evidence decision is committed.

Raw logs, per-admission copies/hashes, query/row counts, all timing samples, throwaway probe source/patch and byte-exact test restoration: `output/architecture-baseline/task-8/`. Full local report/design: `.superpowers/sdd/2026-09-30-architecture-performance/task-8-report.md` and `task-8-design.md`. Each valid probe executed one test with zero failures/skips; sandbox, fixture compile and missing-Direct-source attempts remain separately recorded. No behavioral RED/GREEN or mandatory cursor edge-case acceptance is claimed because the implementation gate failed. Product-source parity with the measured base is verified. Minimum admission free space23.50GiB; no cleanup, foreign-process action, provider/device/external mutation, push or merge.


### Task 9 — bound legacy conversation materialization without a migration

Implementation commit `bbed48f1d1b0e7a0762412429c20e564e8c1c798` replaces the legacy `Int.max` Inbox list read with an account-scoped matching-ID query. Its connection-local SQLite predicate calls exact Swift `MailThreading.normalizedSubject` and Swift String equality, preserving canonical Unicode equivalence, repeated reply prefixes and case behavior. Native/nil-thread matching messages, mailbox/rule/deletion filters, ownership checks and the selected Sent-copy exception remain intact. Task 5 authority/publication guards and Task 4 refresh ownership are unchanged.

The conditional index gate was narrowed by the controller: read-only aggregate counts in the current local macOS store found zero legacy messages among 1,124 total/833 active across 2 accounts. That is local prevalence, not an all-user claim. No normalized-key/index migration, backfill or persisted schema change was justified or performed. `EXPLAIN QUERY PLAN` uses the existing `messages_account_sent_at(account_id=?)` index and membership/rule indexes; exact subject evaluation remains O(N) in account candidates. No indexed-subject or controlled timing speedup claim is made.

On the 100k-unrelated-message fixture, original source returned 100,002 list metadata rows to find 2 members; final source returns 2 IDs, with the same 3 matching body result rows and no unrelated bodies on the membership-backed path. The unchanged membership-free ownership helper still reads 75 body result rows on the 14-message correctness fixture; that pre-existing fallback remains explicit. Exact final-test original-source RED 4/3/0 precedes GREEN 4/0/0. Final focused repository/runtime/authority/DB-compatibility gate passes 127/0/0, and fresh discovery yields 4,718 unique identities with all 127 selected passing once, no gaps/duplicates/skips. Counts are executed/assertion failures/skips; semantic tests pin normalization, Unicode, native/nil members, account rejection, Sent selection and membership-free fallback.

Raw commands/results, count-only population, actual query plan, per-run source/test bytes and hashes, final-test parity, discovery reconciliation and committed-source identity: `output/architecture-baseline/task-9/`; full ignored report: `.superpowers/sdd/2026-09-30-architecture-performance/task-9-report.md`. Existing Debug/macOS/arm64/Swift 6.4/Xcode 27 cache, no skip-build; minimum admission 23.075 GiB. Existing unrelated compiler warnings and host CoreData/NSXPC noise are retained; no changed-file warnings or final test failures. No user DB mutation, cache cleanup, external configuration, device/install/production action, push or merge. Installed acceptance remains controller-owned.


### Task 10 — bound reader document preparation work

Implementation `03cb201d76f480b6ad11dfa492d04992958783d5` retains one active HTML preparation and one latest pending request in the existing coordinator, with weak coordinator/WebView captures across preparation. Both platform dismantle hooks close admission, clear pending/cached HTML, detach WebKit callbacks and suppress late publication. Existing sanitizer, generation, remote-content and private WebKit session contracts remain. Admitted synchronous regex may finish; teardown does not synchronously join or interrupt it.

Deterministic tests exercise actual coordinator scheduling: initial request plus 20 selection/theme/policy changes starts 21 preparations on the instrumented original scheduler versus only first/latest with maximum one admitted unfinished preparation after the repair; only newest content/policy/theme loads. Teardown rejects pending/new work and permits coordinator and real WebView deallocation before held preparation finishes. Minimal injection-only baseline patch and normalized algorithm equivalence are retained; this is not byte-identical original production. Exact finalized test-byte RED is 3 tests / 10 assertion failures / 0 skips. `rtk proxy swift test --filter 'HTMLMessageViewTests|EmailBodyRendererTests|StoredEmailBodyRendererTests'` passes 31 / 0 / 0 in 15.938 s; fresh discovery finds 4,723 unique identities with exact 31 selected/passed parity. Earlier fixture/autorelease and harness-path failures remain recorded.

Public synthetic newsletter: 1,266,145 input bytes; five pure macOS preparation samples per policy yield blocked median 33.963 ms and allowed median 0.314 ms; real coordinator/WebKit load takes 291.014 ms in one sample. These Debug observations are not p95, RSS or installed performance. iOS Simulator readiness timed out once after 30 seconds; no iOS runtime/profile pass is claimed. Current iOS coordinator compiles and complete HTML test file typechecks in isolation with Swift 6 / Simulator 27 SDK after correcting the XCTest overlay search path. Full app, simulator execution and named-phone acceptance remain controller integration work.

Per-run admitted bytes/hashes, original seam equivalence, raw logs/counts/inventories, newsletter measurements, iOS readiness/compile evidence and committed-source parity: `output/architecture-baseline/task-10/`; full ignored report: `.superpowers/sdd/2026-09-30-architecture-performance/task-10-report.md`. Existing worktree Debug cache, no skip-build; admission space above 22 GiB. Final logs retain four unrelated compiler warning lines and six host CoreData NSXPC errors, with no changed-file warnings or test failures. No data/cache cleanup, external change, install, push or merge.


### Task 11 — isolated calendar model tests and current build artifacts

Implementation `f75e0b4b3b6d325b9bd691b12a6a56e51338d512` extracts the unchanged CalendarWeekLayout/CalendarEventPlacement algorithms into one package-visible CalendarPresentation target. The eight existing layout tests move intact to their own target and `calendar` profile; CalendarWeekViewModel and CalendarEventEditorViewModel remain real UI consumers. The child plan records exact types/imports before the move and local command ownership. No Session/transaction/runtime authority move, separate package or hosted CI was added.

The installed Swift 6.4 toolchain builds and executes a dedicated current-source XCTest bundle. Its actual linker response contains only five objects: test entry, layout tests, AccountProtocol, NodeTransport and CalendarPresentation; no UI/DB/runtime module. Original eight cases pass 8/0/0; final `rtk proxy python3 Scripts/verify-profile.py --profile calendar --output <new-directory>` discovers and passes the same eight exactly. Actual macOS adapter selection passes 48/0/0; actual Simulator 27 PlainpostUI compilation builds both production adapters and the new module. Fresh `rtk proxy swift test list` yields 4,723 unique identities, exactly prior inventory after only the eight namespace moves. Lower build/test closure is observed; elapsed timings are uncontrolled and do not establish speedup, p95 or RSS improvement.

The shared artifact utility keys compatibility by worktree/toolchain/SDK/configuration/signing/architecture, resolves dependencies before wrapped-build admission, hashes source/project/config/dependency bytes before and after successful builds, and binds exact product hashes. Four existing flow adapters use current Swift product paths/current SDK xctestrun discovery and verified receipts. Tests pin v1/v2 metadata, stale/source/product rejection, exact recovery-backup-bound environment injection, external caches, contained dependency/framework links and escaping-link rejection. Final artifact contracts pass17/0/0; profile contracts pass19/0/0; four shell syntax gates pass. The final calendar receipt remains valid after aggregate discovery. The direct UI simulator stage is retained because actual settings did not prove equivalence with the app stage.

Existing packaging structural/signer fixtures pass eight outcomes. Exact unchanged xctestrun recovery function passes its selected focused contract. Full pairing contract remains FAILED at a byte-identical BASE functional wait-counter assertion; required historical pairing/seeder products and corresponding functional UITest coverage are absent. Controller ruled this pre-existing unsupported gap out of Task11 repair scope: no assertion weakening, fake helper or full pairing pass claimed. No actual signed packaging, E2E execution, installation, device or provider acceptance was run. Broad final integration remains after Task12.

Raw logs/results, every admitted source/test snapshot and SHA-256, normalized source/test parity, actual object/link closure, exact discovery reconciliation and committed blob parity: `output/architecture-baseline/task-11/`. Full ignored report: `.superpowers/sdd/2026-09-30-architecture-performance/task-11-report.md`. Failed setup/API/usage/sandbox attempts are retained separately from valid assertions/passing gates. Existing Debug caches reused; admissions stayed above15GiB (final about21.68GiB). No data/cache cleanup, external configuration, push or merge. A direct unsupported XCTest help invocation exposed inherited credential-bearing environment values in the tool transcript; controller notified the user, report records keys only, and subsequent helpers use allowlisted nonsecret environments. No secret values are copied into this record.


### Task 12a — local read cancellation and owned XPC deadlines

Implementation `d005dd9ca2d85836d86a2ffe843661989f3d0c88` makes only status, nodeSessionIdentityReadiness, nodeMailModeStatus and serviceIdentity waits locally cancellable with standard CancellationError. Each cancellation unregisters only its UUID and preserves the connection/service work. Vault, AI, durable mutations, background and mixed Node request waits keep their existing policy. The committed lifetime matrix records owners, 5/120/300 deadlines, retry identities and the explicit send-admission boundary; cancellation after admission may still send owned work. Listener, wire/public protocol and Package.swift remain byte-identical to Task11 BASE.

Deadline fan-out remains unchanged for a still-owned RPC: timedOut for its waiter, serviceUnavailable for peers, connection invalidation. A stale timer must now win both pending membership and the shared once-completion under state→completion lock order. A deterministic timer.cancel hold proves protection even after completion has won but before unregister. Callbacks run outside locks. Pre-registration cancellation also skips/wakes connection-configuration condition waits without cancelling shared activation; this named edge received its own RED before repair.

Exact final-test byte-original RED executes9tests/31assertion failures/0skips; owned timeout policy and persisted durable-write preservation pass on both original/final source. Prescribed `rtk proxy swift test --filter 'PlainpostServiceIPCTests|PlainpostServiceRuntimeTests|NodeSessionXPCContractTests'` passes95/0/0 in21.720s on final source. Fresh `rtk proxy swift test list` yields4,732unique identities (exactly nine additions); all95selected identities pass once with no gaps/extra/duplicates/skips. Actual client/export plus disposable SQLite test preserves one admitted job's idempotency/lease/cancellation state and completes it once after caller cancellation; this is not provider-delivery proof. Explicit admissions, pre-cancel gates, held timer actions and repeated late replies pin the regressions; bounded completion expectations are not exhaustive race proof.

Per-run admitted bytes/hashes, raw failures/results, source restoration and exact RED/GREEN parity, full selected inventory and committed blob identity: `output/architecture-baseline/task-12a/`. Full ignored report: `.superpowers/sdd/2026-09-30-architecture-performance/task-12a-report.md`. Initial fixture compile failure and superseded gates remain separate. Existing unrelated compiler warnings retained, no changed-file warnings. Existing Debug/macOS cache only; minimum admission21.23GiB, explicit nonsecret helper environments. No ambient user DB/provider connections, data/cache cleanup, install, external configuration, push or merge. Real NSXPC process/signature, installed/provider acceptance and broad final integration remain after Task12b.

### Task 12b — retryable readiness owner close and drain-safe teardown

Implementation `97e86f4ec2698018eceb689d47f80ecf56f93c2b` adds a context-aware, joined readiness close while preserving legacy Close. Close permanently fences new Ready calls, joins admitted Ready work, and lets each joining caller cancel only its own wait. Private owner failure preserves dependent stores and allows retry; descriptor teardown runs once and retains irreversible errors. Actual runNode now requires safe HTTP/calendar/runtime drain and successful readiness cleanup before closing shared backends. Failed activation retains one cleanup owner and gates replacement assembly; detached cleanup is bounded to 10 seconds. No activation coordinator, operation manager, fixed drain sequence or publication rewrite.

Real alternate-manager tests use owned disposable PostgreSQL, encrypted V3 state, the actual account saga.Stop and a held runtime quiescer. They prove checkpoint/evidence/recovery/backend usability after owner failure, context cancellation and successful retry. Actual runNode tests cover unsafe HTTP/runtime/calendar drains and readiness failure; real activation-handler retries cannot replace a still-live failed owner. No-manager recovery now has an explicit closer. Shared-manager constructors retain the same first-adopted recovery pointer and reject retiring/mismatched authority; the two-constructor replacement bug received its own RED.

Exact final byte-original production RED: 58 events / 33 top-level tests, 44 pass / 14 fail / 0 skip (12 new top-level regressions plus two subtests). CloseContext cases compile through an interface assertion and fail missing-API requirements; they are not claimed original cancellation behavior. Identical final test/fixture bytes pass 58/58/0/0 via the prescribed cmd selector inside `Scripts/test-postgresql-18-live-matrix.sh --node-lifecycle --pass=normal` (35.63 s). Per-run source bytes/hash/admission, complete event inventories, original source restoration and exact committed blob parity are retained in `output/architecture-baseline/task-12b/`; full ignored report is `.superpowers/sdd/2026-09-30-architecture-performance/task-12b-report.md`. Superseded test-setup/expectation failures remain separate.

Fixture contract passes after an approved marker correction that includes an already-existing scoped-read test; exact BASE had the same stale-marker failure. Its internal required-live negative prerequisite probe is validated, not misreported as outer Go events. Fixture self-isolates environment, requires local Unix Docker and 15 GiB before allocation, preserves exact TLS/credential/resource ownership and cleans only its owned clusters. Go 1.26.2 / Docker 29.4.0 and the authorized pinned PostgreSQL 18.6 digest were verified; final free space 20.38 GiB. No ambient TEST_POSTGRES_URL/provider credentials, user DB, cache cleanup, install, external configuration, push or merge.

The new `--integration` mode is prepared for root's later full normal/race milestone, with every package assigned once and backup tests on separate restore-role authority; it has not been executed. Full Go/race, installed/device/provider acceptance remain pending integration. Synchronous descriptor close is not context-interruptible; legacy Close-only gates retain their contract. Constructor-private cleanup failure itself is inspection/shared-mechanism evidence, while actual alternate owner failure and failed activation handoff are exercised.

Task12b review fix round 1: `82c66ba40354b6e7e0cf7235845e4c71247f3035` repairs Important I1 in the concrete operation manager. The first implementation retained readiness descriptor errors but incorrectly assumed the manager also retained its descriptor errors. Manager Close now records the terminal descriptor result and keeps admission closed even on error; later Close returns that same error. The earlier saga contention/cancellation branch remains retryable. No readiness/caller/publication rewrite.

Two new regressions execute the actual alternate manager/saga and real journal close through a narrow private Close-only field wrapper that returns one error after retiring the journal. Instrumented-original RED changes only that field type (exact reversal to FIX_BASE verified), with the manager Close algorithm/default concrete assignments unchanged: 60 events / 58 pass / 2 fail / 0 skip. Actual activation replays reproduced replacement/runtime start and real backend closure after the lost error. Identical test/fixture bytes pass all 60 events / 35 top-level tests after the fix, including the existing required owner-contention and context-cancellation retry cases. Raw admissions, exact source bytes/hashes, inventory/parity and committed identity: `output/architecture-baseline/task-12b/fix-1*`; full report appends the correction and limits. Focused owned PostgreSQL only; exact resource cleanup verified, floor above 20 GiB. Full Go/race/integration and independent re-review remain pending; no Task11 implementation occurred.


### Task11 follow-up — explicit owned local fixture inputs

Implementation `b5a57fecfb6bd7be682f00cf87e4db7ffef33eb4` resolves Important I1: named profiles can now accept a closed private `--fixture-inputs` descriptor for service recovery preparation/fresh stream diagnostics or integration browser coordination. Inputs are admitted before discovery and revalidated at the final execution boundary; only that child receives the three fixed selectors. Shared tool-safe environment bytes, live enrollment/private owner flows, Gmail exclusion, profile inventories and skip/failure policies remain unchanged. Marker ownership, input hashes/private identities and output freshness are checked; post-execution validation failure overrides raw child exit0. Browser freshness is admission-only, with identity checked after legitimate child output; no completion marker is fabricated.

Final byte-original runner RED executes6boundary tests/5missing-admission assertions/0skips; it asserts the absent API rather than claiming original post-validation behavior. Identical final test bytes pass within88focused Python contracts (26fixture,19profile,26measurement,17artifact). The actual Swift recovery decoder passes1/1/0 through the fixed production boundary after current SwiftPM discovery of4,732identities, using the separately verified genuine Go-produced3,364byte fixture SHA256 `a2bf02340e803994b782683225ff52544db55aa4154436c8a43e074ba9c7a1bb`. No producer repeat or full service-profile pass. A hyphenated Python discovery attempt exits5/zero tests and remains separately failed.

Per-run admitted source bytes/hashes, raw results/nonzero inventories, original/final parity and committed identity: `output/architecture-baseline/task-11-fixture-fix/`. Original ignored task11 report links the full `task-11-fixture-fix-report.md`. Calendar dedicated-build and compatible iOS cache docs corrected; unrelated Release prose preserved. Existing Debug cache only, free space above19GiB at completion; no ambient credentials, data/cache cleanup, external changes, installation, push or merge. Cooperative ownership checks do not promise hostile same-UID race safety. Interactive browser/live-owner acceptance and full Swift/Go/race/device integration remain pending independent review and controller integration.


Task12b review fix round2: `27101edeb859f9348ced24022e1893ccadee48ce` repairs Important I1 found by final Go integration. Candidate570ee725 ran only1/56packages before Bash3.2 expanded an empty owner array, then EXIT cleanup returned false success. That retained run remains FAILED acceptance. Optional owners now use positional arguments; package-qualified event completion, existing required owners, declared/completed inventory and a default-incomplete completion latch govern success. Cleanup preserves nonzero child status and cannot bless incomplete execution. Stage remains unconditional; ordinary integration skips and explicit no-test-files remain supported. Existing declared attachment/calendar owners are now required in their integration package.

Same final9892-byte source-extracted Bash3.2 regression:24tests, original18fail/6pass → final24pass/0skip, exact BASE owner bytes and final test parity retained. Existing structural contract prefix passes; real required-live negative Go selector runs1test/1expected prerequisite FAIL/0SKIP with no DB URL, unchanged791Go source inputs and min15.684GiB free. Full unsplit contract is not claimed: its fresh cache allocation is blocked; controller approved split focused proof with standard cache. All860 tracked Apple source/project/package/config/tool inputs remain byte-identical to570ee725, so no broad Swift/Release/search/simulator repeat for this shell-only repair. `bash -n` and diff checks pass.

Evidence/admitted bytes/raw results/parity: `output/architecture-final/task-12b-fix-2/`; original task12b report appends full commands, hashes, extraction limits and self-review. Final integration at570ee725 separately passed4,728Swift cases with4actual skips, current synthetic search630samples, ReleaseApp and both simulator builds. QA readiness timed out once at30s; phone candidate allocation blocked and native Mac Service profile absent. Full Go normal/race requires independent fix review and adequate headroom; no failed/unavailable gate is waived. No cache deletion, ambient credentials, installation, push or merge.


## Final reader privacy repair

- Code commit `6c178dee98442ddcdf1c6980d269b37e92af8575` repairs pre-existing final-review I1: blocked consent now enforces CSP `img-src data: cid:`; explicit load-once retains remote images. Real leading head/html recognition respects quoted delimiters and inserts governing policy before content, including header/custom-tag fragments. Core renderer, scheduler, private store and navigation remain unchanged.
- Original-source owned IPv4 loopback/WKWebView RED:3 executed/3failed cases/11assertion failures; positive1GET and each blocked unquoted fragment/header/full/quoted-attribute input received1GET/decoded1image after acknowledged page/image completion. Identical test bytes GREEN:3/3, blocked0GET/0decoded images; data/quoted/CSS/srcset/load-once controls pass.
- Fresh discovery and prescribed `rtk proxy swift test --scratch-path .build --filter 'HTMLMessageViewTests|EmailBodyRendererTests|StoredEmailBodyRendererTests'` once:34selected/34unique exact terminal identities/34PASS/0FAIL/0SKIP/missing/extra/duplicates; source-before/after equal. No broad4,732-suite/search repeat. Apple Swift6.4/Xcode27.0/macOSSDK27.0build26A425 Debug evidence; changed Swift bytes still require controller-owned fresh Release/simulator/integration acceptance.
- Evidence `output/architecture-final/final-fix/acceptance.json`, raw commands/logs/results and retained final XCTest Mach-O hashes/copies. Final UI product SHA256 `a9f0c55d15adf2c9ff8a22423e99e17f646fa29b4a9aeab413b6dd277e61bbfe`. Original RED binary hash unavailable (not captured before GREEN relink); actual original source/test/build/runtime proof retained, controller declined a repeat solely for that hash. Floor refusals and sandbox manifest-cache failure retained as prerequisites, zero execution; admitted runs minimum40.226902GiB. Root alone removed approved simulator/module/Debug caches after exact idle/identity checks; worker deleted none, Debug now absent/no reuse claim.
- Final M1–M4 deferred: conditional Go JSON URL redaction; monitor-negative admission acknowledgement; generic profile count-vs-identity guard; existing compiler/runtime warnings (29retained compiler locations,0changed-HTML warnings). No opportunistic fixes or exhaustive HTML security audit claim. Installed Mac/named-phone/provider/production/historical performance gaps remain open. Full local report `.superpowers/sdd/2026-09-30-architecture-performance/final-fix-report.md`; independent scoped re-review is controller-owned.


## Final integration continuation — local attempts complete, race blocked

Source `60e629978a03b41f130d1a726277ae52fd486a28` (privacy `6c178dee98442ddcdf1c6980d269b37e92af8575`) received independent scoped approval; all continuation source admissions remained on that clean candidate. This documentation-only follow-up does not reattribute tests to a new source version.

- Fresh ReleaseApp passed100.178s with current receipt; both simulator stages passed103.371s using7,016-input post-resolution receipts. Outer simulator attribution remains FAILED for3,014added pinnedGRDB entries only; zero changed/removed source, tracked2,376file parity and actual products independently reconciled. Prior fullSwift4,732identities/4skips and search630samples remain their unchanged-input source evidence, with current privacy34/34 separately verified; no broad repeat solely for UI repair.
- Full owned PG normal passed56/56packages:5,413RUN=5,354PASS+59ordinarySKIP, all10mandatory live owners pass,394.029s, source unchanged/cleanup verified. Initial runner077 mode-fixture failure retained; approved private actual-Go-only022 wrapper restored the intended negative fixture and focused2/2control passed before fullnormal. Matrix/evidence/credentials retain077.
- Full race FAILED196.042s at BASE-identical attachment quiesce observer test:26/56packages accepted,1,704RUN=1,650PASS+53SKIP+1FAIL, noDATA RACE warning. Actual borrowed maintenance done precedes a later optional test hook; immediate default-select wrongly assumes hook delivery. Production drain defect not established, but fullrace remains blocked. No patch/skip/luckyrerun or second finalwave authorized; explicit user workflow-exception decision remains controller-owned.
- Full unsplit PG contract passed15.956s, including24dispatcher cases and actual required-live negative/nonSKIP probe. Both completed Go fixtures independently have no owned labeled containers/networks/volumes/temp root left.
- Generic iphoneos Debug build passed46.738s; app+extension strict signatures and actual exact certificate67D0B76B019381B32C7634776FDBBAB98FB35F4B verified against existing profiles/named-phone coverage/developmentAPS+AppAttest. Automatic+fingerprint initial command failed65; approved family-selector command accepted only after fixed actual identity validation. Candidate `.build/integration-60e62997-iphoneos-debug/Build/Products/Debug-iphoneos/Plainpost.app`; bundleSHA256df5e56fcee4030da7a33a907f4a55bc5e6de367272de47f285cb20f991a6392e, extension667543e8c516c49b2d6bc1c9a8e4bd30c85d1d9aa3841f513e897fc7aa2b8007. No install/launch/keychain/provisioning changes.
- Full evidence/commands/receipts/acceptance: `output/architecture-final/continuation-60e62997-20261001T092012Z/`; ignored integration-report.md and integration-race-failure-analysis.md retain failed attempts/attribution limits. Baseline verification document now appends actual final outcomes. Lowest continuation free37.038GiB; no further cleanup, source patch, merge/push or device/provider action. Remaining fullrace, optional/live/runtime/pairing/installed/performance gaps and missing exact current Mac Service profile are not waived. M1–M4 remain deferred.


## Approved race-test exception — full local race milestone passed

User approved one bounded test-only exception for the integration-discovered pre-existing observer-order assertion. Test commit `098f459965029c961fb04c27633c13a3c5917070` changes only `Services/PlainpostGo/internal/node/attachment/quiesce_test.go`: actual backend active count must be zero immediately after Quiesce, Ready remains coherent, and the later observation is explicitly released/acknowledged with a bounded wait. The first test observer is held deterministically; cleanup always releases it before Close. Existing lease refusal, resume and successful Close checks remain; no production or fixture-policy change.

- Original failed full race is retained. Test-only instrumented original assertion:1RUN/1expectedFAIL after backend/Ready checks and acknowledged held observer; corrected focused `go test -race ./internal/node/attachment -run '^TestRepository.*(Quiesce|Maintenance).*' -count=1 -json`:14/14PASS. Initial sandbox cache denial executed zero tests and is separate.
- ONE full owned `rtk proxy bash Scripts/test-postgresql-18-live-matrix.sh --integration --pass=race` passed on clean098f4599:56/56orderedpackages,5,413uniqueRUN=5,354PASS+59ordinarySKIP, all10mandatory live owners pass; no FAIL/duplicate/unsettled identity or DATA RACE warning.706.251s, source unchanged,minimum32.791GiB. Exact run/pass/skip identity sets match the previously accepted normal; no normal rerun or attribution to the changed test assertion.
- Established private actual-Go-only022 wrapper/explicit caches and pinned local PostgreSQL fixture retained. Exact completion/final markers and independently absent owned containers/networks/volumes/temp root verified. RawlogSHA256 `6a7c9b61809aff0a06c3b800eac4a29131cb885b762e0d9fc980823115e54b85`; full admissions/bytes/identities/reconciliation at `output/architecture-final/race-test-fix-70ff45fe-20261001T102423Z/`. Root independently recounted all events and required owners.
- 1,739source/config/test/script paths compared to prior60e62997: only this test differs. Prior normal, Swift, search, Release, simulator and exact-certificate phone-candidate evidence remains scoped to unchanged inputs; no broad repeats solely for the test fix. Earlier failed runs/provenance records remain historical failures. Full ignored report `race-test-fix-report.md`; independent scoped review follows this record, not yet claimed approved.

Remaining acceptance: four Swift optional owners and59ordinaryGo skips, unavailable simulator QA, no installed/provider/production or matched historical app-performance proof, and deferredM1–M4. Fresh read-only46publicprofile decode still finds no exact current-team Mac Service profile; namedphone is paired but disconnected. No installation/launch, signing/provider changes, cache deletion, merge/push or further source fix under this exception.


## Approved named-iPhone installation and process lifecycle

On clean `111c8609b714afe924943d54ccdb54f8cece18b2`, the user authorized installing/launching the exact prepared60e62997Apple candidate. Fresh named-only device info established an actual connection to `olhapi iphone` (UDID00008160-001C494A2280000A, iOS27.0/build24A437); the initially disconnected tunnel was idle, not an unavailable-device verdict. App/extension approved bundle hashes and strict signatures/exact67D0B76B019381B32C7634776FDBBAB98FB35F4B certificate, current embedded profiles, phone coverage and development entitlements all revalidated. No rebuild/re-sign; Apple source/project/package/script closure unchanged.

- Supported devicectl install passed3.116s, retaining data via install-only/no-uninstall/reset operation; exact `com.marynavdovenko.Plainpost.iOS` version0.1.0/build1 verified. Launch passed.462s asPID16582 at the installed bundle path. Verified exact own PID termination without SIGKILL, absence, same-bundle relaunch asPID16629 and presence. App remains launched. This establishes physical installation/launch/process lifecycle, not private-data content parity or internal graceful shutdown.
- Native Devices CUA failed `cgWindowNotFound` after339.241s; one bounded iPhone Mirroring attempt failed identically after16.450s. No UI actions; agent-device CLI absent. Inbox actionability, selection/account-switch during load, reader remote content, scroll and scene background/resume remain UNEXECUTED. Process relaunch does not substitute for those checks. No arbitrary provider send/notification operation or matched30-run p95/RSS claim.
- Exact commands, selected device/process/signing metadata, candidate hashes and acceptance: `output/architecture-final/installed-111c8609-20261001T105615Z/`; full ignored `installed-validation-report.md`. Initial broader single-device success metadata appeared in tool transcript; saved artifacts were minimized, later quiet tools emitted selected fields. No credential/private-mail content or complete profile/device inventory dump retained in these files. No source/cache/signing/keychain/provisioning changes, other-device install, merge/push. Fresh Mac Service profile prerequisite remains missing. Any later user UI observations must be labeled user-reported separately from agent verification.


## Settings redesign

Task 17 checks for `feat/settings-redesign`. Each check below names the head it ran on. The full suites ran at `efbc87ac` and again at the final head `779cd735`, after the whole-branch review fix wave (see the end of this entry).

Full suites at `efbc87ac`, run in the detached gate worktree `.worktrees/settings-redesign-gate`:

- `swift build`: pass.
- `scripts/swift-test-isolated.sh` (full): 4,852 passed, 8 skipped, 51 failed, all in PlainpostIntegrationTests. 50 are `PlainpostCLIHarnessTests` (known, also fail on main). `IMAPHarnessTests.testDisconnectedPeerWriteReturnsSocketErrorWithoutSIGPIPE` failed once under load and passed in isolation (`--filter IMAPHarnessTests`: 45/45).
- `scripts/test-ios-simulator-build.sh`: PlainpostUI and Plainpost schemes pass.
- `xcodebuild test -project Apps/PlainpostiOS/Plainpost.xcodeproj -scheme Plainpost -destination 'platform=iOS Simulator,id=D17101C9-01EB-488D-AFE1-58E6C089B853' -derivedDataPath .build/ios-settings-gate`: 171 passed, 3 failed. All three also fail on main: `testMailboxesLabelsGrowAtAccessibilitySizes` and `testDebugMailboxAcceptanceShowsRealMailRootAndPlainpostAccount` are known, and `testStandaloneDirectMailCleanInstallToRestart` needs the `PLAINPOST_MAIL_FIXTURE_*` env from its harness (re-run at main: same XCTUnwrap failure).
- Manual iPhone check (shared simulator, Direct fixture, driven by a throwaway XCUITest with `simctl io screenshot`):
  - Settings shows four groups: Accounts, Mail, Plainpost, and Troubleshooting.
  - The account page shows no account ID.
  - Smart Inbox set to "New mail only" shows only the cutoff footer ("Mail received before Oct 3 isn't sorted.").
  - Troubleshooting → Logs shows Share Audit Log.
- Mac ⌘, window: not checked visually, because no UI automation was available. `PlainpostRootViewTests.testSettingsWorkspaceRequiresRealRulesAndLabels` covers that the window gets real rules and labels.
- Design snapshots: `swift run PlainpostDesignSnapshot` can't capture windows here because Screen Recording isn't granted. The settings entries were inspected through a temporary AppKit `cacheDisplay` fallback; PNGs are not tracked.

Post-fix checks (no full suites):
- `c3bb39ec`, Mac `SettingsPage` changed to a grouped `Form`:
  - `swift build`: pass.
  - `scripts/swift-test-isolated.sh --filter 'SettingsNoRawIdentifierTests|PlainpostViewSmokeTests'`: 128 tests, 0 failures.
  - `scripts/test-ios-simulator-build.sh`: both schemes pass.
  - Settings pages checked through the temporary snapshot fallback.
- `3b29524a`, Mac page title announced as an accessibility heading:
  - `swift build`: pass.
  - `scripts/swift-test-isolated.sh --filter 'SettingsNoRawIdentifierTests|PlainpostViewSmokeTests|SettingsPageHeaderAccessibilityTests|AccountSecurityPresentationTests|NotificationsSettingsPageTests|SyncNodeSettingsPageTests'`: 156 tests, 0 failures.
  - `scripts/test-ios-simulator-build.sh`: both schemes pass.
- Not re-run at either head: the full `swift-test-isolated.sh` and the full iOS XCUITest suite (both re-run at `779cd735`, below).

Final head `779cd735`, after the whole-branch review fix wave (`f655e08b`..`779cd735`):
- Fixes: the keep-open warning is back on an uncertain Sync Node commit; Low Power Mode pauses a running Re-sort All (through the user pause intent) and resumes it afterwards, and the Mac ⌘, Settings window's Smart Inbox page follows Low Power Mode live, disables Re-sort All Mail during it, and says nothing about it when sorting is Off (correction: at this head the iOS Settings page, built by `MailSession`, was not wired to the power gate, and the pause lived only in memory; both fixed in the residual wave below); Share Audit Log is hidden where there is no export (Node route); the cutoff footer reads "Mail from before <date> isn't sorted."; one destination switch, no task narration; "Sign in again" on the reauthorization banner and in the failed-sync message; the Mac Node account footer; device renames save on Return, focus loss and leaving the page; "Downloading" without a "0 of 0" count; the notification detail picker says Full; unused `revokeNotifications` and `offersSyncNode` removed; deleting a label closes its editor; a v68 backfill test; `SyncNodeStatusText.connection` loses `isEnrolled`.
- `swift build`: pass.
- Focused filters for every touched area (Smart Inbox, power gate, maintenance, Sync Node enrollment and settings, audit log, account security and sync presentation, labels, v68 migration, `LocalOperationsTests`, `Settings`, calendar): all pass (185 + 98 + 69 tests and 12 Swift Testing tests, 0 failures).
- `scripts/test-ios-simulator-build.sh`: PlainpostUI and Plainpost schemes pass.
- `scripts/swift-test-isolated.sh` (full, detached gate worktree at `779cd735`): 4,867 passed, 8 skipped, 50 failed, all `PlainpostCLIHarnessTests` (known, also fail on main); 101 Swift Testing tests pass. No CLIServiceBoundary, VaultBoundaryAdversarial or IMAPHarness flake this run.
- Full iOS suite (`xcodebuild test ... -scheme Plainpost ... -derivedDataPath .build/ios-settings-gate`, shared simulator, gate worktree at `779cd735`): 168 passed, 6 failed. Three are the known main failures (`testMailboxesLabelsGrowAtAccessibilitySizes`, `testDebugMailboxAcceptanceShowsRealMailRootAndPlainpostAccount`, `testStandaloneDirectMailCleanInstallToRestart`). The other three ran while another project's UI tests (`com.olhapi.babytracker`) were using the shared simulator: `testReplyComposerBlankBodyTapAcceptsTyping` passed on rerun, and `testNotificationSettingsFitAtAccessibilityTextSizes` and `testPerMailboxNotificationDetailOpensFromNotificationSettings` failed again while BabyTracker held the simulator, passed at `d10ef747`, then passed at `779cd735` once the simulator was free.
- Not re-run at `779cd735`: the manual simulator checks and the Mac window check.

Residual fix wave (`e4266a07`..`07cd6ab3`, plus this docs commit), gates run at code head `07cd6ab3`:
- Fixes:
  - The runtime builds one `MailMaintenanceViewModel` (`makeMailMaintenanceViewModel`) and passes it into `MailSession`, so the iOS Settings page and the main Mac window follow the Low Power gate like the ⌘, window: "Paused in Low Power Mode" (not when sorting is Off), live updates, and Re-sort All Mail disabled during Low Power Mode.
  - Low Power Mode pauses a Re-sort with its own durable `low-power` pause reason. The worker honors it like a user pause and keeps the reason, and claims skip it. When Low Power Mode ends, and at every launch outside it, `resumeLowPowerPausedJobs` queues paused `low-power` jobs and clears a still-pending `low-power` pause on a running job. A user's own pause is never lifted. The activity view shows "Paused in Low Power Mode" with no Resume for such a job, and a Resume refused by Low Power Mode says "Paused in Low Power Mode".
  - iOS Rules & Labels opens on the list; only the Mac side-by-side layout selects the first label on load.
  - "Downloading" (not "0 of 0") for a folder sync with no total yet; the reauthorization banner body ends "until you sign in again."
- `swift build`: pass.
- `scripts/test-ios-simulator-build.sh`: PlainpostUI and Plainpost schemes pass.
- `scripts/swift-test-isolated.sh` (full, gate worktree detached at `07cd6ab3`): 4,880 passed, 8 skipped, 50 failed, all `PlainpostCLIHarnessTests` (known, also fail on main); 101 Swift Testing tests pass. No CLIServiceBoundary, VaultBoundaryAdversarial or IMAPHarness flake.
- Full iOS suite (`xcodebuild test ... -scheme Plainpost ... -derivedDataPath .build/ios-settings-gate`, shared simulator D17101C9, gate at `07cd6ab3`): 172 passed, 3 failed, all known main failures (`testMailboxesLabelsGrowAtAccessibilitySizes`, `testDebugMailboxAcceptanceShowsRealMailRootAndPlainpostAccount`, `testStandaloneDirectMailCleanInstallToRestart`). It includes the new `MobileMailUITests.testRulesAndLabelsOpensOnTheListWithLabelsPresent`, which fails at the pre-fix head `c735e5e2` (the editor is re-pushed after going back) and passes at `07cd6ab3`.
- Not checked: Low Power Mode on a real device or in the simulator (the gate is injected in tests), and the Mac window visually.

## Unified All Inboxes — phase 1 (iOS, Direct accounts)

Branch `feat/unified-all-inboxes`, spec `docs/superpowers/specs/2026-10-04-unified-all-inboxes-design.md`, plan `docs/superpowers/plans/2026-10-04-unified-all-inboxes-phase-1-ios-direct.md`. Checks below ran at code head `4cbd48ac`.

What shipped:
- The iPhone runs one mail runtime for every Direct account (no selected account). All Inboxes, Unread, Smart Inbox, Search, approvals, the audit log, notifications, background sync and history download cover every Direct account.
- Every action, message open, label change, AI request and send goes through the message's own account, and is refused when that account was removed or moved to a Sync Node after the list was read.
- New Message has a From picker (default: the last account sent from, else the first); replies and forwards use the original's account; a send is re-checked when Undo ends.
- Search started inside an account's folder stays in that account; mixed lists label each row with its account; Settings opens each account's page instead of switching; the Mailboxes account selector is gone.
- Phase 1 limit: a Sync Node account in the phone's catalog is not in the combined list yet (Phase 3). It still opens from Settings in its own runtime, and keeps its account switcher.

Checks:
- `scripts/swift-test-isolated.sh` (full): 5,051 passed, 8 skipped, 50 failed, all `PlainpostCLIHarnessTests` (known, also fail on main).
- iOS simulator build (`xcodebuild build ... -destination 'generic/platform=iOS Simulator'`): pass.
- `xcodebuild test -project Apps/PlainpostiOS/Plainpost.xcodeproj -scheme Plainpost -destination 'platform=iOS Simulator,id=D17101C9-01EB-488D-AFE1-58E6C089B853' -only-testing:PlainpostUITests -only-testing:PlainpostTests`: PlainpostTests 113/113, MobileMailUITests 59/59 (including four new two-account tests), PlainpostUITests class 20 passed, 2 failed — `testDebugMailboxAcceptanceShowsRealMailRootAndPlainpostAccount` and `testStandaloneDirectMailCleanInstallToRestart`, both known main failures.
- Not checked: a real device, or a manual walk-through on the simulator beyond the UI tests.

Follow-up at `feat/unified-all-inboxes` after the review (deferred minors):
- Each listed message (inbox, folder or search) is checked against the read that listed it, and per-row account lookups use that read instead of the store.
- Search suggestions, the mailbox limit, and "last synced" cover Direct accounts only.
- Drafts save at their account's current source; a From switch never leaves a draft behind; the end-of-Undo check compares against the source as of Send.
- A history download still running is shown again after relaunch.
- Smart Inbox and label re-sorting still run across all stored mail (Sync Node accounts' hidden leftover rows included) until Phase 3 makes that mail real.
- Gates: `scripts/swift-test-isolated.sh` 5,069 passed, 8 skipped, 50 failed (all `PlainpostCLIHarnessTests`, known); iOS PlainpostTests 113/113, MobileMailUITests 59/59, PlainpostUITests class 20 passed, 2 known main failures.

## Unified All Inboxes — phase 2 (Mac sidebar, From picker, footer)

Branch `feat/unified-all-inboxes-phase-2`, plan `docs/superpowers/plans/2026-10-05-unified-all-inboxes-phase-2-mac.md`. Checks below ran at code head `b08d361c`.

What shipped:
- With two or more accounts, the Mac sidebar lists a section for each account's folders after the shared sections; choosing one shows that account's folder in the mail list. All Inboxes stays the combined view.
- The sidebar footer reads "Mail stays on this device" and the account count.
- New Message on the Mac has a From row (default: the last account sent from, else the first); replies and forwards use the original's account; a blocked From says why.
- The iPhone and the Mac share one folder rows model: pending actions show in the folder, committed ones stay applied until it reloads, and list actions in a folder act on that folder's copy.
- Search started in a folder stays in its account; notifications treat only an open Inbox folder as that account's visible inbox; the Mac surfaces an uncertain send from any account.
- Moved to phase 3: a per-account sync failure in the section header, and closing a removed account's open draft.

Checks:
- `scripts/swift-test-isolated.sh` (full): 5,094 passed, 8 skipped, 50 failed, all `PlainpostCLIHarnessTests` (known, also fail on main).
- `xcodebuild test ... -scheme Plainpost -destination 'platform=iOS Simulator,id=D17101C9-01EB-488D-AFE1-58E6C089B853' -only-testing:PlainpostUITests -only-testing:PlainpostTests`: PlainpostTests 113/113, MobileMailUITests 59/59, PlainpostUITests class 2 known main failures (`testDebugMailboxAcceptanceShowsRealMailRootAndPlainpostAccount`, `testStandaloneDirectMailCleanInstallToRestart`).
- Design snapshot `25-account-sidebar-two-accounts` rendered.
- Not checked: the Mac app by hand with two real accounts.

## Unified All Inboxes — phase 3a (Sync Node accounts on the iPhone)

Branch `feat/unified-all-inboxes-phase-3`, plan `docs/superpowers/plans/2026-10-05-unified-all-inboxes-phase-3-sync-node-ios.md` (3a). Decisions taken 2026-10-05: a Node account with no provider sign-in on the phone offers sign-in while the Node is away (3c); the mirror keeps Direct's recent window; move, flag and labels for Node accounts (labels here, move and flag in 3b).

What shipped:
- The iPhone mirrors every Sync Node account into its database (one bridge: mirror loop plus intent router over the device's Node session), limited to the account's recent-message window unless complete history is on. The Node's accounts join the device's catalog on each start, so the Plainpost Account path's accounts become ordinary accounts; a phone with only Node accounts opens to mail.
- One combined list: Node accounts' mail is in All Inboxes, Unread, Smart Inbox, Search, approvals and notifications. Their read, archive, delete, opens and sends go through the Node's journal (waiting while the Node is away); labels stay local as for Direct accounts. Provider work (sync, monitor, history, rules, attachments, audit log, last sync) stays Direct-only.
- The account-mode mail root, the Node account header and the local account switcher are gone; the Plainpost Account's sign-in and prompts wrap the one mail root.
- Each account's section (iPhone Mailboxes, Mac sidebar) says when it needs sign-in, its Sync Node is unreachable, or its last sync failed (the Mac shows sign-in only: its service reports sync failures globally).
- A removed account's open draft closes (asking first when it has text; Keep leaves Send blocked with the reason) and its open conversation closes. Removing a Node account from the phone checks its source again at commit; the Node keeps the account.
- The router can no longer turn an unknown intent kind into a delete.

Checks (code head `ee8a10cc` plus the assembly-test update):
- `scripts/swift-test-isolated.sh`: 5,137 passed, 50 failed, all `PlainpostCLIHarnessTests` (known); `PlainpostAccountRuntimeTests` 589 passed after updating its source assertions for the removed switcher.
- iOS (`xcodebuild test-without-building ... -only-testing:PlainpostUITests -only-testing:PlainpostTests`, shared simulator D17101C9): PlainpostTests 109/109; UI failures only the two known main ones and `testRotationKeepsTheConversation`, which fails the same way on main (the window doesn't turn landscape on this simulator).
- Not checked: a real device with a real Sync Node; the Mac app by hand.

Known limits (next phases): Node drafts stay on the phone until Send; an account the Node stops listing stays on the phone; the unused account-switching APIs in `MobileAccountModel` remain until phase 4's cleanup; Settings labels a Node account by its provider, not "Via Sync Node".

## Unified All Inboxes — phase 3b (Move to folder and Flag, every account)

Branch `feat/unified-all-inboxes-phase-3b`, plan `docs/superpowers/plans/2026-10-05-unified-all-inboxes-phase-3-sync-node-ios.md` (3b). Decision 2026-10-05: neither app offered Move or Flag for any account, so 3b builds them for Direct and Sync Node accounts on both apps.

What shipped:
- iPhone: Flag on a row's leading swipe; Flag and Move to… in a row's menu and the conversation's More menu. Mac: Flag and Move to in a row's context menu and the reader toolbar. Rows show a flag. Move to… offers only the message's own account's other folders.
- Direct accounts flag and move over IMAP; the server confirms before anything changes locally. `messages.is_flagged` follows the copies' \Flagged through triggers (v69), so sync, the Node mirror and Flag all keep it.
- Sync Node: signed `set_flagged` and `move` mutations (protocol vector now nine variants, Go and Swift agree). A move names its folder by the path mirror coordinates publish; the Node resolves it only against its own active folders of that logical mailbox. Gmail: archive still drops the Inbox label; any other move is a real `UID MOVE`. Journal v4 carries flag, unflag and move. An older Node refusing them reads "Update your Sync Node to …"; a flag or move during fallback waits for the Node.
- The Mac reaches both through its service (new flag, unflag and move operations; the Objective-C kind enum grows at its end).
- 3a fix: a Sync Node account's folders on the phone now come from its mirrored mail's folders (the catalog's mailbox handles are opaque and never matched); rows an earlier build seeded from handles are removed.

Checks (head `710ae27a` plus the pinned-list test updates):
- `scripts/swift-test-isolated.sh`: 5,150 passed; 50 `PlainpostCLIHarnessTests` failures (known) and three tests that pinned the old context-menu order and journal kinds, updated and passing (69 + 7 tests).
- Go `go test ./...`: 4,660 passed in 56 packages. Live PostgreSQL 18 (throwaway container): the client-mutation resolution tests, including the new path resolution, pass.
- iOS on D17101C9: PlainpostTests 109/109; MobileMailUITests 59/60 (`testRotationKeepsTheConversation`, which fails on main too); PlainpostUITests class only the two known main failures. New UI tests: Flag from the swipe reaches the fixture Node; Move to… opens with the account's folders.
- Not checked: a real Gmail or IMAP server, a real Sync Node, or the Mac app by hand. No UI test performs an actual move (the fixture account has one folder); moves are covered by unit and service tests.

## Unified All Inboxes — phase 3c (the phone keeps a Sync Node account syncing)

Branch `feat/unified-all-inboxes-phase-3c`, plan `docs/superpowers/plans/2026-10-05-unified-all-inboxes-phase-3-sync-node-ios.md` (3c). Decision 2026-10-05: a Node account with no provider sign-in on the phone offers sign-in while the Node is away.

What shipped:
- The iPhone follows the Mac's fallback model. Its bridge runs the reachability supervisor. When the Node stays away, every Node account whose provider sign-in is on the phone falls back: it stays listed where it was, the phone syncs it with the provider, and its changes and sends still go through the Node journal, which now dispatches them directly (read, archive, delete, send; flag and move wait for the Node as on the Mac; drafts stay on the phone). An account without a sign-in stays with its Node, its changes waiting. When the Node is back, accounts return and unstarted direct changes go to the Node.
- The device scope, the store's sync, flag, archive, job-claim and confirmed-action fences, and the phone's operation runtime accept a fallback account at its own generation. Rules, the audit log and Direct settings stay Direct-only; rules leave a fallback account's new mail to the Node instead of failing (review fix).
- Sign in to keep syncing: a Gmail Sync Node account's settings offer Google sign-in on the phone, checked against the mailbox the Node serves; the account stays a Sync Node account. Other providers' settings say their changes wait for the Node (the Node's catalog gives no server settings). The Direct-only rows (password, server settings, Use Sync Node) are hidden for Node accounts. An unreachable account's Mailboxes section links to its settings.
- The Mac's direct-dispatch error rules move to a shared type; behaviour unchanged.

Checks (head `620a55d3`):
- `scripts/swift-test-isolated.sh`: 5,170 passed; 50 failed, all `PlainpostCLIHarnessTests` (known). After the review fix, `PlainpostOperationsTests` and `IOSDirectMailLifecycleTests` 342/342.
- iOS on D17101C9 (`-only-testing:PlainpostUITests -only-testing:PlainpostTests`): PlainpostTests 109/109; PlainpostUITests 76 passed, 3 failed, the three that fail on main (`testRotationKeepsTheConversation`, `testDebugMailboxAcceptanceShowsRealMailRootAndPlainpostAccount`, `testStandaloneDirectMailCleanInstallToRestart`). New UI test: a Sync Node account's settings offer sign-in to keep syncing.
- New tests: fallback store fences, the phone syncing a fallback account against a local IMAP server (and not in Node mode), the supervisor's sign-in gate, the bridge falling back and returning against the fake Node, the direct dispatcher's routing and error rules, sign-in presence, Google sign-in checked against the Node's mailbox.
- Code review: one blocker (rules silencing a fallback account's new mail), fixed with a regression test.
- Not checked: a real device with a real Sync Node going away, real Google sign-in on the phone, the Mac app by hand.

Known limits: Microsoft and IMAP Sync Node accounts can't add a sign-in on the phone yet; a fallback account's mark-read is confirmed once its durable flag job is queued (a mode change waits for that job); a mode change also waits for running global work such as Smart Inbox, retried each supervisor tick; the supervisor runs only while the app is in the foreground.

## Unified All Inboxes — phase 4 (notifications across accounts, and cleanup)

Branch `feat/unified-all-inboxes-phase-4`, plan `docs/superpowers/plans/2026-10-05-unified-all-inboxes-phase-4.md`. Found while planning: an iPhone push tap still switched the selected Sync Node account and waited up to 2 s for a per-account runtime the device-wide app no longer builds, so every tap landed on All Inboxes.

What shipped:
- A notification tap opens its message in place, whichever account it came to, with no account switch. The device-wide runtime matches the push token against its own messages (a Mac producer names its local ID) and the Node message IDs it mirrored (a Node producer names those), the envelope's mailbox first. When the push is ahead of the mirror it wakes the mirror and looks again for 3 s. A message the iPhone doesn't have reads "This message is no longer on this iPhone." on All Inboxes. The Mac's handling is unchanged (an unavailable message lands on All Inboxes).
- Settings lists a Sync Node account as "Via Sync Node".
- Use Sync Node for This Account no longer reports a failure after the switch has committed (with the device's Node session the shared runtime mirrors the account).
- An account the Sync Node stops listing reads "No longer on your Sync Node" in its Mailboxes section, linked to its settings; it stays, with its drafts and waiting changes, until the user removes it.
- Removed: the old notification owner switch and wait, the Settings switch rows and the host's local-account fields, the pending Settings landing, the iPhone account menu, the app's local account choices and the account model's unused read-only helpers (about 380 lines).

Checks (head `0ca7f569`):
- `scripts/swift-test-isolated.sh`: 5,167 passed; 50 failed, all `PlainpostCLIHarnessTests` (known).
- iOS on D17101C9: PlainpostTests 104/104 (six tests of the removed owner switch went, one attach test came); PlainpostUITests 78 passed, 3 failed, the three that fail on main. New UI tests: a tap opens the second Sync Node account's message in place; a tap for missing mail says so.
- Code review: its one blocker (Node message tokens not bound to an account) doesn't apply: the Node keeps message IDs unique across all accounts of a Plainpost account and the phone has one Node; recorded in the code.
- Not checked: a real push on a device, the Mac app by hand.

Left for later: the `PlainpostAppRuntime` selected-account branches only tests still use, `MobileAccountModel`'s per-account authority (push rows and Google onboarding still use it), Node draft sync, Microsoft/IMAP sign-in for Node accounts, Mac per-account sync failures.

## New-mail notifications that never fired (2026-10-06)

Branch `fix/new-mail-notifications`. Reported: no Plainpost notification ever, on the iPhone or the Mac, and no background updates.

Found (on the live install):
- The Mac app in /Applications was the Sep 17 `com.olhapi.Plainpost` build. Central and the iPhone moved to team 9XN7WN8JN2 on Sep 25, and the Mac sat on "Recovery required" ("Central could not prepare account recovery"). Its service was idle, with no IMAP connection since Sep 14. macOS notification permission had never been requested.
- An account with "Download complete history" never ran an incremental pass, so its Inbox arrivals never became new-mail alerts, on either platform.
- The iPhone synced only in the foreground. It never posted a local new-mail alert or asked for permission, and push registration needs a Sync Node.

What shipped:
- An account whose history download finished syncs incrementally again, and its new mail notifies.
- iPhone background refresh: a `BGAppRefreshTask` runs a real-time Inbox pass for every Direct account, then delivers alerts through the Mac's durable new-mail pipeline, which the device-wide iPhone runtime now owns. Mail found up to 24 hours after its arrival alerts. Mail already read doesn't. Alerts also run in the foreground as a quiet banner. A tap opens the message, even from a cold launch.
- Settings > Notifications on an iPhone without a Sync Node has Allow Notifications (Open Settings once denied). `MacNotificationPermissionModel` is now `NotificationPermissionModel`.
- Design for the Mac pushing to a Direct iPhone without a Sync Node: `docs/superpowers/specs/2026-10-06-mac-push-for-direct-iphone-design.md` (draft).

Then (same branch), the Mac pushes to the iPhone without a Sync Node:
- Both devices derive a Direct account's Inbox mailbox ID from the Plainpost Account's matching key, so they agree on it with no Sync Node.
- The Mac binds every account Central assigns to it (it used to bind only a lone account), and rebinds after the key rotates. Its producer follows the Plainpost Account session, so signing in after the service started no longer needs a restart.
- iPhone Settings > Notifications lists each Direct account with "Use Mac" (Apple sign-in, then Central's assignment), or "Instant alerts from Mac" once a Mac sends for it. Turn On no longer needs a Sync Node.
- A local alert is skipped when a push for the same message is already in Notification Center.
- Central (live) has the producer and registration routes mounted. Its APNs key and App Attest settings for team 9XN7WN8JN2 can only be proven by a real push.

Not checked: background refresh on a real iPhone (iOS schedules it, and the Simulator can't run it); the Mac reinstall, which is blocked because Xcode has no developer account signed in, so the service's provisioning profile can't be created.

## Slow message opening (2026-10-08)

Branch `perf/message-open-speed`. Reported: messages open slowly, especially on the iPhone, even one opened a second earlier.

Measured against a copy of the iPhone's live store (893 MB, pulled 2026-10-06), Mac debug build:
- Every open waited for a full mailbox projection rebuild (Inbox list, Sent list, unread counts, two COUNTs) before the thread could show: 1.4–2.4 s per open. Reading the thread alone takes ~5 ms. The open path invalidated the projection unconditionally, even for an already-read message.
- Going back on the iPhone dropped the thread, so reopening paid all of it again.
- First body sanitize: up to 237 ms. One event-handler pattern went quadratic on whitespace runs, and the merge-tag line pattern was slow on large bodies.
- A reopened message flashed its plain-text fallback and grew from a 180 pt placeholder while its cached HTML waited for an actor hop.

What changed:
- `markOpenedMessageRead` loads the conversation alone first (`InboxViewModelSnapshotStore.loadThread` → `PlainpostAppRuntime.selectedThreadDetailAsync`), then marks it read, then refreshes the list. The projection is invalidated only when the open changed read state. Tap to thread: ~5 ms.
- The snapshot store remembers the last 24 conversations shown. Opening one again shows it on the reader's first frame. They are forgotten when the account revision changes.
- Rendered bodies are readable synchronously from `DeferredEmailBodyRenderStore.cachedBody`. Each message's last measured HTML height is remembered.
- `EmailBodyRenderer` precompiles its passes, skips the comment and merge-tag passes when the body has none, and anchors the handler patterns at whitespace runs. The output matches the old renderer on 304 real bodies plus edge cases (`EmailBodyRendererEquivalenceTests`; `PP_RENDER_CORPUS` points it at a directory of bodies). That corpus renders 2.8× faster in a debug build.
- `HTMLMessageWebViewPool`: both apps prewarm one reader web view with its scripts, and its web content process, then keep one spare ready.

Not checked: timings on a physical iPhone; the web view prewarm's gain (only visible on a device). An unread message still triggers a full list rebuild (~0.5 s, off the main actor) after the thread shows. The two COUNT queries behind it (170–330 ms each) are the next list-side cost.

Follow-up the same night (branch `fix/open-marks-read`): on the iPhone a conversation's list row stayed unread after it was opened. The row stands for the whole conversation and is unread while any message in it is, but opening it marked only the newest message read (instrumented on the device: `changed=false` for a row whose two earlier replies were unread). This was not caused by the speed change. Opening a conversation now marks every message in it read (`PlainpostAppRuntime.openConversation`). Only the opened message's refusal fails the open.
