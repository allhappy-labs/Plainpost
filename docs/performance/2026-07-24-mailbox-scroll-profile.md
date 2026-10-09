# Mailbox scroll profile — 2026-07-24

## Reproduction fixture

- Packaged Debug application: `.build/Plainpost.app` (`0.1.0 (2)`).
- Fixture flags: `PLAINPOST_MAILBOX_UI_ACCEPTANCE=1` and
  `PLAINPOST_MAILBOX_SCROLL_PROFILE=1`.
- The profile flag selects the existing deterministic mailbox UI-acceptance
  root. That root uses the fixed `2026-07-22T10:00:00Z` design time, focused
  Inbox mode, and no Smart Inbox display bundle.
- Accessibility reported a packaged app window of **1440 × 900 points**.

```sh
rtk ./scripts/package-app-bundle.sh
rtk env PLAINPOST_MAILBOX_UI_ACCEPTANCE=1 PLAINPOST_MAILBOX_SCROLL_PROFILE=1 open .build/Plainpost.app
rtk xcrun xctrace record \
  --template 'Time Profiler' \
  --time-limit 15s \
  --output .build/performance/mailbox-scroll-before.trace \
  --attach PlainpostApp
```

## Before trace

- Trace: `.build/performance/mailbox-scroll-before.trace` (generated, not
  source controlled).
- Time Profiler run: **15.658 seconds**, from `22:21:26.326` to
  `22:21:41.984` local time, ending at its 15-second limit; attached to the
  packaged `PlainpostApp` process.
- Interaction: CoreGraphics moved the pointer to the mailbox-list point
  `(1000, 500)` and posted 11 cycles of real pixel-wheel events. Each cycle
  sent eight `wheel1: -8` events followed by eight `wheel1: 8` events with
  60 ms spacing, so the list was continuously scrolled in both directions for
  roughly 12 seconds inside the capture.
- Direct movement proof: the generated before/after screenshots
  `.build/performance/mailbox-scroll-wheel-before.png` and
  `.build/performance/mailbox-scroll-wheel-after.png` show the Smart Inbox
  list content moved upward after the wheel events (the `Today` section and
  message rows changed viewport position). This is wheel movement, not
  keyboard-selection navigation.

### Exported main-thread samples

`xctrace export` of the `time-profile` table produced these named-function
sample counts:

| Path | Main-thread samples |
| --- | ---: |
| `MailMessageListColumn.handleVisibleFrame` | 4 |
| Sorting `visibleRowFrames` | 1 |
| `reportCurrentScrollLocation` | 1 |

The sort sample is `Sequence.sorted(by:)` beneath
`MailMessageListColumn.handleVisibleFrame(_:_)` on the main thread. The same
main-thread backtrace also samples `handleScrollOffset(_:)` once above
`reportCurrentScrollLocation(for:)`. Static inspection describes the work
represented by these samples:

- `handleScrollOffset` writes `currentContentOffsetY` and reports the current
  scroll location for every offset callback.
- `handleVisibleFrame` writes the `visibleRowFrames` dictionary, filters it,
  sorts every candidate by `minY`, writes anchor state, and reports the current
  scroll location for every row-frame callback.
- `reportCurrentScrollLocation` constructs and reports a full
  `MailboxScrollLocation` value.

## Observed behavior

Direct visual run: a local 14.99-second screen recording of the packaged
1440 × 900 Smart Inbox is retained at
`.build/performance/mailbox-scroll-wheel-observation.mov`. It recorded the
same real pixel-wheel workload. I inspected frames from that recording at
0.5-second intervals: the list stayed in Smart Inbox while the viewport and
right-hand scrollbar moved in both directions. No persistent visual pause or
stall was visible in those samples. Because this visual inspection samples at
2 fps, it cannot judge micro-stutters shorter than 0.5 seconds; this is not a
claim that the interaction is perfectly smooth.

Separately, the profiler's `potential-hangs` export contains no rows for this
capture (no reported hang event at the profiler threshold). Future comparisons
should repeat this exact wheel workload and compare the three named sample
counts alongside a fresh visual run.

## After trace — 2026-07-25

- Trace: `.build/performance/mailbox-scroll-after.trace` (generated, not
  source controlled).
- Time Profiler run: **15.855 seconds**, from `02:55:34.610` to
  `02:55:50.465` local time, ending at its 15-second limit; attached to PID
  `89314` from this worktree's freshly packaged application.
- Interaction: the same mailbox-list point `(1000, 500)`, 11 bidirectional
  real pixel-wheel cycles, eight `-8` events and eight `+8` events per cycle,
  and 60 ms spacing. The roughly 12-second wheel workload left an idle tail in
  the trace so the settled, one-shot anchor measurement could retire.
- Exported sample span: `00:00.253.435` through `00:15.642.438`.
- The `potential-hangs` export again contains **zero rows**.

### Before/after comparison

| Evidence | Before | After |
| --- | ---: | ---: |
| All Time Profiler samples | 542 | 553 |
| Main-thread samples | 527 | 499 |
| `MailMessageListColumn.handleVisibleFrame` samples | 4 | 0 |
| `Sequence.sorted(by:)` beneath `handleVisibleFrame` | 1 | 0 |
| `reportCurrentScrollLocation` samples | 1 | 0 |
| Potential Hangs rows | 0 | 0 |

The after capture has **28 fewer main-thread samples (5.3%)** despite a
slightly longer sampled span. More importantly, it contains no
`handleVisibleFrame`, no `TrackedMailboxScrollItem`, no
`visibleRowFrames`, and no per-row `Sequence.sorted(by:)` backtrace. The
continuous callback now updates only the scalar scroll offset. Scroll-location
reporting is requested by the settled idle callback or an explicit navigation
boundary; the settled measurement clears its requested anchor before reporting,
so row geometry is not observed continuously. The 1 ms statistical sampler did
not catch that brief one-shot callback, which is consistent with the observer
retiring rather than remaining hot.

I watched the packaged mailbox throughout the after workload. The content and
scrollbar moved continuously in both directions with no visible persistent
pause or hitch. This remains a manual observation rather than a frame-time
guarantee; the zero-row Potential Hangs export adds bounded profiler evidence.

## Native acceptance evidence

- Fresh package and strict signature verification passed for
  `.build/Plainpost.app`; the running acceptance PID resolved to this
  worktree's exact bundle.
- `.build/verification/mailbox-wide.png` verifies aligned Today summaries and
  ordinary subjects, the Focused/Simple/Unread icon picker, Compose → Ask Mail
  → Command Center toolbar order, and the absence of a redundant app title or
  mailbox-header Sync/Rerun controls.
- The initial packaged run exposed a visible `Inbox view` picker title wrapping
  into three lines. The native `.labelsHidden()` correction removes that visual
  title while the fresh accessibility tree retains an `Inbox view` radio group
  and labeled Focused, Simple, and Unread radio buttons.
- `.build/verification/mailbox-narrow.png` verifies the minimum 900 × 760
  window: rows and bundles stack cleanly, subjects/previews truncate without an
  empty column, and bundle summaries remain legible.
- The packaged accessibility tree exposes Compose, Ask Mail, and Command Center
  buttons in visual order, plus the three picker segment labels.

### Bounded interaction limitations

The same-window reader and Back control were exercised in the packaged
acceptance app and retained in
`.build/verification/navigation-before.png`,
`.build/verification/navigation-reader.png`, and
`.build/verification/navigation-after.png`. External CG wheel input drove the
matched profiling workload, but a later attempt to establish a deterministic
deep offset for an exact frame comparison only rubber-banded the SwiftUI list.
Its AX page actions returned unsupported, and directly setting the exposed
scrollbar value moved only the AX thumb rather than the list. A final
viewport-focus + hardware Page Down fallback was stopped after the bounded
helper chain failed to return. Therefore this run does **not** claim packaged
proof of exact deep-offset Back restoration. The focused navigation suite does
cover unchanged rows, inserted rows above, removed anchors, and independent
mailbox/bundle contexts.

The acceptance fixture deliberately does not start the production runtime, so
its Settings scene reports unavailable. A second exact-bundle normal-runtime
launch reached the Keychain credential lock and likewise could not construct
Settings without user authentication. No credential prompt, Sync, or Smart
Inbox rerun was started. `.build/verification/mail-maintenance.png` is therefore
the shipped dark Diagnostics design snapshot rather than packaged-runtime
acceptance. It confirms the native Mail maintenance layout and action labels;
the focused `MailMaintenanceViewModelTests` provide active/completed,
confirmation, duplicate-request, and disabled-state behavior coverage.

## Test status

- Focused mailbox/Settings suite: **150 passed, 0 failed**.
- Full suite rerun: **1,736 XCTest tests, 1 skipped, 2 failed**; all 73 Swift
  Testing tests passed. The two failures were load-sensitive pre-existing timing
  assertions:
  `MobileSyncClientTests.testCancelledJoinerReturnsCancellationWithoutCancellingInterestedOwner`
  and
  `SmartInboxLabelReconciliationTests.testCompletionAuditMarkerSurvivesDrainReopenAndConcurrentRetry`.
- Each failing test passed in isolation, the mobile-sync test passed 10/10
  repetitions, the Smart Inbox audit test passed 20/20, and both passed together
  for 10 rounds (20/20). Neither test nor its direct production dependency
  differs from `main`, so no unrelated timing change was made in this task.

## Final reviewed-HEAD verification — 2026-07-25

This final pass reviewed source HEAD
`c39b81d98bc286f31548426853efcb03f6a1ff45`. The freshly packaged Debug
application completed strict/deep code-signature verification and ran from this
worktree's exact `.build/Plainpost.app` bundle as acceptance PID `76558`.

- Refreshed fixed-size captures:
  `.build/verification/mailbox-wide.png` at **1440 × 900 points** and
  `.build/verification/mailbox-narrow.png` at **900 × 760 points**, with
  matching `mailbox-wide-ax.txt` and `mailbox-narrow-ax.txt` accessibility
  trees.
- Visual and AX inspection found the expected native Smart Inbox hierarchy,
  toolbar order, labeled view picker, compact reflow, readable grouped rows,
  truncation, and row actions. No clipping, overlap, empty trailing column, or
  redundant title/Sync/Rerun controls were observed.
- Final trace:
  `.build/performance/mailbox-scroll-after-final.trace` (generated, not source
  controlled). It ran **15.854417 seconds**, attached to PID `76558`, with
  exported samples spanning `00:00.822.443` through `00:14.689.446`.
- Interaction exactly repeated the mailbox-list point `(1000, 500)`, 11
  bidirectional real pixel-wheel cycles, eight `-8` events and eight `+8`
  events per cycle, and 60 ms spacing.
- Exported result: **578** Time Profiler samples, **528** main-thread samples,
  **0** sample rows containing `handleVisibleFrame`, `visibleRowFrames`,
  `TrackedMailboxScrollItem`, `reportCurrentScrollLocation`, or
  `Sequence.sorted`, and **0** Potential Hangs rows.
- A separate **14.988-second** recording at
  `.build/performance/mailbox-scroll-after-final-observation.mov` repeated the
  same wheel workload. Frames sampled at 2 fps show bidirectional viewport
  movement with no persistent pause or stall. This remains bounded visual
  evidence and does not rule out micro-stutters shorter than 0.5 seconds.

Final test evidence:

- Focused mailbox/Settings suite: **195 passed, 0 failed**.
- Full XCTest suite: **1,753 tests, 1 skipped, 1 failed, 0 unexpected** in
  **2,645.572 seconds**. The single failure was the known load-sensitive
  five-second group-wait assertion in
  `SmartInboxLabelReconciliationTests.testCompletionAuditMarkerSurvivesDrainReopenAndConcurrentRetry`
  (`timedOut` versus `success`, line 944). All **73** Swift Testing tests passed.
- A fresh isolated rerun passed **1/1** in 0.048 seconds, followed by **5/5**
  passing bounded repetitions. No production code, test, or timeout was
  changed.
- Durable artifacts:
  `.build/verification/final-full-suite.log`,
  `.build/verification/final-full-suite-swift-testing.xml`,
  `.build/verification/final-known-flake-isolated.log`, and
  `.build/verification/final-known-flake-repeat-5.log`.

The prior bounded-interaction limitation still applies: this final pass does
not claim deterministic packaged proof of exact deep-offset Back restoration.
