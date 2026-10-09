# Account Deletion with Self-Hosted Sync Nodes

Date: 2026-08-09
Status: Research and architecture recommendation; not an implementation spec
Scope: Plainpost account deletion when a user-controlled Sync Node or client may be offline

## Executive recommendation

Plainpost should **not add a separate Sync Node web dashboard or a second node
administrator identity**. Account-wide deletion belongs in the existing native
Plainpost account settings on macOS and iOS. The existing planned native Sync
Node settings should also expose a node-scoped `Erase Sync Node Data…` action,
and the node deployment should have a local operator CLI for cases where no
trusted app can reach it.

The product needs four distinct operations with unambiguous names:

1. **Remove Mail Account from Plainpost** — removes one provider account and its
   Plainpost-managed data; does not delete the Gmail/Microsoft/iCloud/IMAP
   account or provider mail.
2. **Remove This Device** — revokes that Plainpost device and erases its local
   Plainpost cache and credentials when the device is reachable.
3. **Erase Sync Node Data** — stops the node and purges its provider
   credentials, mail projection, search index, attachments, operations, keys,
   and managed backups for this Plainpost account.
4. **Delete Plainpost Account** — the account-wide operation. It immediately
   disables central account use, deletes central live data, and requests erasure
   of Plainpost-managed data on every known app and Sync Node. Provider accounts
   and provider-hosted mail are never deleted.

`Delete Plainpost Account` should default to erasing Plainpost-managed local
data; it should not silently preserve Mac or Sync Node mail archives. If a
future product supports an archive, that should be a separate, explicit export
or detach operation performed before deletion.

An offline or operator-modified node cannot be remotely erased. Plainpost must
say `Sync Node erasure pending` rather than claim that all data is gone. The
user must be able to finish the purge by reconnecting the node or running the
local wipe command.

## Why this is the best fit for Plainpost

The approved architecture already assigns different data to different owners:

- the official central service owns account identity, device sessions, trust
  coordination, leases, entitlements, APNs routing, and deletion markers, but
  never mail content or provider credentials;
- a Sync Node is a full user-controlled mail data plane with PostgreSQL,
  provider credentials, bodies, drafts, indexes, attachments, and operation
  journals;
- native apps administer the node, and the approved v1 design explicitly has no
  browser dashboard or second admin login;
- Sync Node backups and their keys are operator-controlled.

Therefore central deletion cannot truthfully mean that the central service
physically deleted bytes on an offline Unraid server, VPS snapshot, or S3
bucket. The control plane can own the **decision, revocation, durable deletion
intent, and status**. Each data plane must own the **physical purge of the data
it stores**.

This also corrects the current Task 9 wording. Preserving Mac/node data unless
explicitly removed is a surprising default for an operation called `Delete
Plainpost Account`, conflicts with the existing local-only deletion behavior,
and weakens the privacy promise. Preservation should require an explicit action
before deletion.

## Primary-source findings

### Store-policy UX

Apple requires account deletion to be easy to find, to cover the entire account
record and associated personal data, and not merely deactivate an account.
Apple permits additional options and deliberate reauthentication, and accepts
deletion that takes time if the app states the timing and confirms completion.
Sign in with Apple apps should revoke the user's Apple tokens. See [Apple,
Offering account deletion in your
app](https://developer.apple.com/support/offering-account-deletion-in-your-app/).

Google Play similarly requires an in-app deletion path and a web route for a
user who no longer has the app, and says associated account data is in scope.
It allows justified retention only when disclosed. See [Google Play, account
deletion requirements](https://support.google.com/googleplay/android-developer/answer/13327111?hl=en).

Implication: Plainpost may offer node-local controls in addition to account
deletion, but cannot replace `Delete Plainpost Account` with `Deactivate`,
`Unlink`, or an operator-only server command. The account action belongs in
native Account Settings and should use the already planned recent Apple plus
local-biometric step-up.

### Revocation is not the same as local erasure

Signal's official instructions distinguish unlinking a device from deleting
the message history stored by Signal Desktop; the desktop's own `Delete Data`
flow removes its local history while the phone remains registered. See [Signal,
Unlinking devices](https://support.signal.org/hc/en-us/articles/360007321111-Unlinking-devices).

Nextcloud implements remote wipe as a client protocol: after authentication
fails with 401/403, a client checks wipe status using its dedicated token,
deletes the account, caches, and offline files locally, and acknowledges
completion. See [Nextcloud, Remote
wipe](https://docs.nextcloud.com/server/latest/developer_manual/client_apis/RemoteWipe/index.html).

Implication: revoking a Plainpost node session must not be reported as erasing
the node. Plainpost should retain a narrow cleanup credential or signed wipe
ticket that remains usable only for `wipe/check` and `wipe/ack` after ordinary
account authorization has been disabled. The node performs and acknowledges
its local purge.

### “Erase” must describe its limits

Matrix demonstrates why vague terminology is dangerous. Its account
deactivation removes login ability, while the optional `erase` flag only asks
for as much server-side erasure as possible. Previously visible room events may
remain visible, erasure is not federated, and other servers may retain
unredacted copies. See [Matrix Client-Server API,
`/account/deactivate`](https://spec.matrix.org/v1.19/client-server-api/#post_matrixclientv3accountdeactivate)
and [Synapse User Admin API, Deactivate
Account](https://element-hq.github.io/synapse/latest/admin_api/user_admin_api.html#deactivate-account).

Proton can use the simple promise that an account and all its data are
permanently deleted from Proton's systems because Proton controls those
systems. It separately exposes session revocation. See [Proton account
deletion](https://proton.me/support/delete-account) and [Proton session
management](https://proton.me/support/log-out-all-other-sessions).

Implication: Plainpost can promise complete deletion from the official central
service, but must qualify self-hosted storage as a tracked remote cleanup. It
cannot promise deletion from independently retained snapshots, copied keys, or
a node that never reconnects.

### Erasure, recipients, and backups

GDPR Article 17 requires applicable erasure without undue delay. Article 19
requires communication of erasure to recipients unless impossible or
disproportionate. See the [official GDPR text on
EUR-Lex](https://eur-lex.europa.eu/eli/reg/2016/679/oj/eng).

The UK ICO's official guidance says valid erasure requests require steps for
backups as well as live systems. A backup may age out under an established
schedule, but the data must be beyond use in the meantime and the user must be
told what happens. See [ICO, Right to
erasure](https://ico.org.uk/for-organisations/uk-gdpr-guidance-and-resources/individual-rights/individual-rights/right-to-erasure/).

Implication: deletion status needs separate, honest rows for central live data,
central backups, each known device, the Sync Node, node attachments/S3, and
node backups. A stale restore must replay deletion before readiness and must not
make restored data available first.

### Cryptographic erasure is conditional

NIST SP 800-88 Rev. 2 describes cryptographic erase as sanitizing keys so that
recovery of encrypted target data is infeasible. It emphasizes prerequisites,
including strong encryption from the beginning and the ability to sanitize all
copies of target keys. See [NIST SP 800-88 Rev.
2](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-88r2.pdf),
especially sections 3.2 and 3.2.2.

Implication: Plainpost may claim cryptographic erasure only for data whose
complete encryption/key hierarchy it controls. Destroying the account key does
not erase a node database that can still be decrypted with its mounted master
key. PostgreSQL search rows, WAL, temporary files, S3 versions, volume
snapshots, copied backup keys, and cached unwrapped keys must be handled.
Cryptographic erasure is not a blanket substitute for row/blob purge.

## Recommended architecture

### 1. Central account lifecycle

Use an explicit lifecycle such as:

```text
active -> deletion_requested -> central_deleted
                                  + cleanup_pending
                                  + cleanup_complete
```

At `deletion_requested`, atomically:

- invalidate ordinary access, refresh, offline-lease renewal, producer,
  writer-lease, push, MCP, and trust mutation paths;
- revoke the Sign in with Apple refresh/token relationship;
- append the minimal deletion marker to a journal outside the restorable
  account snapshot;
- issue device/node-specific, purpose-bound cleanup tickets;
- enqueue central live-data purge and remote wipe tracking.

The cleanup plane accepts only a device-bound `wipe/check` and `wipe/ack`.
It cannot read mail, restore a session, or perform any other account action.
This follows Nextcloud's useful pattern without keeping a general account alive.

The central account record and live data should be deleted without waiting for
an offline node. The product should then report central deletion separately
from node/device cleanup.

### 2. Sync Node purge ownership

When the node receives a wipe ticket, it must perform one idempotent local saga:

1. enter `erasing`; reject client reads and writes and stop provider workers;
2. quiesce or cancel operations, preserving only the minimum evidence needed to
   resolve any provider-accepted uncertain send before erasure if the user
   explicitly asks for that report;
3. delete provider credentials and OAuth refresh tokens;
4. purge PostgreSQL account/mail/search/audit data and WAL/temporary artifacts
   according to the supported storage design;
5. delete filesystem and S3 attachment objects, including managed versions;
6. destroy every Plainpost-managed node/account data key and managed backup
   key copy;
7. write a small local wipe receipt outside normal restorable data;
8. acknowledge completion to the central cleanup plane, then remove the cleanup
   credential itself.

The user-controlled deployment may include external snapshots, immutable object
retention, or copied keys that Plainpost cannot delete. The node should surface
those as operator actions, not silently report success.

### 3. Offline and restored nodes

- A node checks deletion status at startup, after any 401/403, and before
  accepting traffic after restore.
- A disconnected node is `pending`, never `erased`.
- Ordinary node authority remains bounded by its signed offline/lease rules;
  after expiry it must fail closed even if it cannot check deletion.
- Restore first loads the backup into quarantine, then checks the central
  deletion high-water and the node-local wipe receipt. It applies deletion
  before readiness can succeed.
- An explicit operator-only offline restore override cannot be marketed as
  respecting current account deletion state. It should remain unavailable in
  normal product mode or require a conspicuous data-controller warning.
- A node that never reconnects, runs modified software, or is restored with
  copied keys is outside any enforceable remote-erasure guarantee.

### 4. Deletion marker design

The independent durable journal should contain no mail, Apple subject, device
label, endpoint, or profile. Retain only what is necessary to prevent
resurrection and match cleanup acknowledgements, for example a keyed opaque
deletion handle, deletion epoch/high-water, known cleanup-target handles, and
completion bits.

Retention should be explicit:

- central deleted account snapshots: existing maximum 30 days;
- central anti-resurrection marker: at least until every central backup capable
  of reintroducing the account has expired, plus a documented safety margin;
- offline-node cleanup target: until acknowledged or until the user explicitly
  accepts responsibility for the unreachable self-hosted node.

A long-lived minimized marker is preferable to silently resurrecting personal
data. It must be disclosed as a security record and cannot be usable to log in,
recover the account, or identify mail.

## Recommended UX

### Account Settings: Delete Plainpost Account

Before confirmation, show:

- `Deletes your Plainpost account and data stored by Plainpost.`
- `Also requests erasure from your Macs, iPhone/iPad devices, and Sync Node.`
- `Does not delete your email account or mail stored by your email provider.`
- a list of known cleanup targets with `Online`, `Offline`, or `Last seen`;
- a warning for unsent drafts, pending operations, or delivery-uncertain sends;
- a link to export anything the user wants to keep before proceeding.

Suggested confirmation copy:

> Delete Plainpost Account?
>
> Plainpost will permanently delete your central account, revoke every device,
> and erase Plainpost-managed mail data from devices and the Sync Node when they
> connect. Your email accounts and mail at Gmail, Microsoft, iCloud, or another
> provider will not be deleted.
>
> Offline self-hosted nodes and operator-managed backups cannot be erased until
> they reconnect or you erase them on the server.

Use `Delete Account` as the destructive button after fresh Apple authorization
and local biometric confirmation.

### Completion/status

Do not use one undifferentiated green check. Show, for example:

```text
Plainpost account                 Deleted
Official central live data       Deleted
Official encrypted backups       Expires by 8 Sep 2026
This iPhone                       Erased
MacBook Pro                       Pending - offline
Home Sync Node                    Pending - last seen 3 days ago
Node backups/S3 snapshots         Operator action required
```

Provide exact recovery instructions for the node:

- reconnect it so it can receive the wipe request; or
- run a local, interactively confirmed command such as
  `plainpost-sync-node erase-account-data` using the documented container
  command.

The command name is illustrative; its exact interface belongs in the Sync Node
implementation plan.

### Sync Node Settings: Erase Sync Node Data

This is a node-scoped control in the existing native admin surface, not a new
dashboard. It is useful for decommissioning or moving a node without deleting
the Plainpost account. It should state that the node will stop, provider mail is
unchanged, and clients will fall back or require a new node enrollment.

The local operator CLI is mandatory as a recovery path because account deletion
can intentionally remove the credentials required by the native app to
administer the node.

## Required plan corrections

Before implementing Task 9, update the architecture/spec/plan so that:

- `preservation of Mac/node local data unless explicitly removed` becomes
  default erasure of Plainpost-managed client/node data, with truthful pending
  status for unreachable targets;
- the deletion journal is defined as a minimal anti-resurrection/control record,
  not retained account or mail data;
- central account deletion and node-local erasure are separate outcomes in one
  user flow;
- node cleanup has purpose-bound post-revocation check/ack authorization;
- the Sync Node plan adds the native danger action, local operator CLI, purge
  saga, managed-key destruction, restore quarantine, and cleanup acceptance
  tests;
- acceptance covers an online node, an offline node that later reconnects, a
  stale database restore, a stale full-node backup, S3 versioning, copied backup
  key limitations, repeated wipe, crash at every purge step, and a node that is
  never reachable;
- product copy never claims provider-mail deletion, universal remote wipe, or
  cryptographic erasure of storage whose full key hierarchy Plainpost does not
  control.

## Bottom line

The Sync Node does not need its own web UI. It needs a node-scoped wipe control
inside the planned native administration UI and a local operator CLI. The
account-wide deletion decision remains in normal Plainpost Account Settings.
The central service coordinates and records the decision; the node owns its
physical purge. The default should be privacy-forward erasure, while offline
and operator-controlled storage is reported as pending or operator action
required rather than hidden behind an impossible guarantee.
