# Local verification profiles

Run `rtk proxy python3 Scripts/verify-profile.py --profile NAME --output DIRECTORY`
from the repository. The output directory must be new. Exit codes are 0 passed,
1 failed, and 2 unavailable. An unavailable prerequisite is an acceptance blocker,
not a passing test. The calendar profile builds a dedicated source-bound test
bundle. Other Swift profiles select execution within the aggregate build graph.
No profile alone establishes a green release.

| Profile | Selected test targets or cases | Prerequisites |
| --- | --- | --- |
| `calendar` | Eight PlainpostCalendarPresentationTests methods in its dedicated target bundle | Swift 6.4 target-bundle support, Xcode, xcrun; no UI, database or service build dependency |
| `core` | PlainpostCoreTests, PlainpostAITests, PlainpostAccountProtocolTests | rtk, Swift, Xcode; macOS package toolchain |
| `db` | PlainpostDBTests, PlainpostSearchBenchmarkTests | same; synthetic local SQLite fixtures and benchmark process acceptance |
| `ui` | PlainpostUITests, PlainpostAppTests | same; macOS UI/WebKit/rendering environment |
| `service` | PlainpostServiceTests, PlainpostServiceIPCTests, PlainpostOperationsTests, PlainpostAccountRuntimeTests, PlainpostNotificationRuntimeTests, PlainpostNodeTransportTests, PlainpostNodeMailModeTests, PlainpostLocalAPITests, PlainpostBrowserBridgeTests, PlainpostSecretsTests, PlainpostRootAuthorityTests | same; local service/Keychain fixtures and repository-owned live/Go fixture harnesses; absent live fixtures remain skipped/failed gates |
| `ios` | The five historical iPhone regressions listed below | xcodebuild, xcrun, rtk; QA iPhone simulator 255CC905-D572-4265-BC8D-8AA213092084 boot readiness; at least 15 GiB free |
| `integration` | PlainpostIntegrationTests, PlainpostCLITests | macOS package toolchain; local process/CLI fixtures |

The calendar profile builds `PlainpostCalendarPresentationTests`, records a
source/product receipt, discovers that exact bundle, and verifies the receipt
before and after its execution. It fails if executed methods differ from its
nonzero discovery.

The other Swift profiles first run `rtk proxy swift test --scratch-path .build list`
without skip-build. The current-build inventory includes XCTest specifiers and
Swift Testing dotted identifiers. Every configured target must contribute tests;
a typo cannot silently drop one target from a nonzero group. The profile then
executes `rtk proxy swift test --scratch-path .build --filter REGEX` with its
anchored target expression. The Debug cache is shared by these tiers, and retained
metadata identifies configuration, SDK, machine, source SHA and dirty paths.
Release measurements use a separate scratch root.

The iOS prerequisite is a bounded 30-second `xcrun simctl bootstatus` check. It
does not boot, reset, erase or shut down devices. Once ready, the profile builds
for testing in `.build/verification-ios-debug`, obtains that build's unique
`.xctestrun`, and enumerates its flat test identifiers. All five selections must
exist before execution. Execution uses `test-without-building -xctestrun`, never
a stale build from another source checkout. `xcresulttool get test-results summary`
supplies structured executed, failed and skipped counts from `tests.xcresult`.
The raw summary is retained alongside parsed JSON. Missing/invalid summaries,
expected failures, skipped tests, zero execution and incomplete selections fail.

| Historical iPhone regression | Current acceptance behavior |
| --- | --- |
| `testDebugMailboxAcceptanceShowsRealMailRootAndAccountSecurity` | Authorized local setup displays Connect an account and Account Security without requiring a Node. Its original assertion remains. |
| `testMultiAccountHeaderLeavesNavigationBarActionsReachableForEachAccount` | Both accounts expose Compose in Smart Inbox and removal, Reply and Compose in the phone conversation toolbar; each removal reaches its own runtime and Compose opens. The account switch lives in Settings. |
| `testMultiAccountSwitchShowsNewAccountInboxAndRoutesActionsToIt` | Switching to grace replaces ada's inbox, opens Reply, accepts text, and saves that draft through grace's runtime. |
| `testNotificationSettingsUseDeviceCopyOnCompactIPhone` | Mailboxes → Settings → Notifications displays the device copy and excludes the macOS notification-access copy. |
| `testReplyComposerBlankBodyTapAcceptsTyping` | Reply opens from the conversation menu, a blank-body tap accepts text, and Close/Send remain hittable. |

These cases retain their historical identifiers. They exercise the existing
MobileMailShell contract; desktop toolbar expectations are not imposed on phones.
The phone cases skip only on iPad, where the split-view cases remain separate.
No phone skip is used to hide a historical failure.

Each discovery, build and execution command goes through
`Scripts/measure-dev-iteration.py`. It retains `command.log` and `result.json`;
`profile.json` records the selection and verdict. Mixed XCTest/Swift Testing
counts must be complete. Individual skipped-case output also fails a Swift
profile because XCTest aggregate totals can include skipped tests. Failed child
commands keep their logs. Output uses synthetic fixtures; the runner does not
redact arbitrary child logs, so do not put credentials in arguments or fixtures.

`Scripts/test-ios-simulator-build.sh` keeps separate PlainpostUI/Plainpost build
logs rather than deleting a temporary log. Set `PLAINPOST_IOS_BUILD_OUTPUT` to a
new evidence directory and `PLAINPOST_IOS_DERIVED_DATA` to an explicit Debug
cache. Defaults are worktree-local `.build/ios-simulator-build-logs/...` and
`.build/compatible/ios-build-<identity>`. The identity includes the owning worktree,
toolchain, SDK, configuration, signing mode and architecture; explicit cache
overrides still require matching current-source build receipts.


Optional local fixture inputs use an explicit descriptor, never ambient environment
forwarding:

```sh
rtk proxy python3 Scripts/verify-profile.py --profile service --output NEW_OUTPUT --fixture-inputs /private/tmp/owned-fixture/fixtures.json
```

The descriptor is a UTF-8 JSON file (at most 64 KiB), current-user-owned, mode
`0600`, with one hard link, inside its canonical, non-symlink, mode `0700` root.
For example, after a genuine Go fixture producer has created `recovery.json`:

```json
{"version":1,"profile":"service","root":"/private/tmp/owned-fixture","fixtures":{"recoveryPreparation":{"file":"recovery.json","sha256":"REPLACE_WITH_64_LOWERCASE_HEX_SHA256"},"streamDiagnostics":{"output":"stream.log"}}}
```

Either service slot may be omitted. The recovery input must be nonempty, private,
at most 16 MiB, and match its declared digest. Diagnostic output must not exist;
the runner reserves a new private file and retains it after execution. The
integration profile instead accepts only
`"fixtures":{"browserSmoke":{"coordinationRoot":"browser"}}`: that child
directory must already be private and empty. The runner never fabricates browser
completion; the interactive browser owner must perform the existing test protocol.
Created child outputs are allowed after execution, while directory identity stays
bound. All slot names are single relative leaves, unique within the root.

Unknown or duplicate keys, arbitrary environment entries, other profiles,
symlinks, hardlinked files, reused outputs and concurrent root use are rejected.
Admission binds descriptor/input hashes and identities before discovery. Only the
final test command receives the three documented fixture selectors; build,
discovery and tool probes retain the tool-safe environment. Inputs are checked
again before and after execution, and only the runner's own private use marker is
removed. Validation failure overrides a successful child exit; raw child status
remains recorded. Hashes establish byte identity, not producer authenticity. These
path checks coordinate cooperating local runners, not hostile same-UID mutation.

Live enrollment/private transport owner scripts keep their existing lifetimes and
audit outputs. Their selectors, provider credentials and Gmail allowance are not
supported by this descriptor. Named service/integration profiles still fail when
required live cases skip or fixture inventories are missing; a decoder or plumbing
case alone is not full-profile acceptance. Run the focused boundary/file contracts
with `rtk proxy python3 Scripts/test-profile-fixtures.py`.

Validate runner behavior with `rtk proxy python3 Scripts/test-verify-profile.py`.
The prescribed `rtk proxy python3 -m unittest discover -s Scripts -p
test-verify-profile.py` is retained as a separate gate: the installed Python
rejects hyphenated discovery filenames (exit 5, zero tests). The direct invocation
provides the nonzero behavioral gate; the discovery failure is not relabeled.

At integration, run the full Swift suite and relevant complete simulator suites,
plus the project's service/Go/Docker and Release benchmark gates as required by
the release scope. UI rendering remains in the UI tier. A previously failing
baseline, missing environment or unavailable structured result continues to block
release acceptance until investigated and rerun successfully.

Task 2 evidence is under `.build/task2-evidence/`. The original and restored
current benchmark source both fail Release search with `Query is empty`; the
budget gate remains failed. The dedicated QA simulator's launch/readiness stalled,
so compiled phone tests have no current execution acceptance. See the task report
for counts, exact commands and retained artifacts.
