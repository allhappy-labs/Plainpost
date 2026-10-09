# Plainpost App Design PRD

Date: 2026-07-09
Owner: Product/design handoff
Status: Draft for redesign implementation

## 0. Implementation Tracker

Use this section as the redesign progress tracker. A checkbox is complete only when the current code and verification evidence support it.

- [x] App shell uses persistent rail, list column, and switchable work area.
- [x] Smart Inbox matches the reference density, grouping, row states, and reader composition.
- [x] Settings mode keeps the message list visible and presents settings navigation plus AI provider/index panels.
- [x] Approval Queue mode has filters, request list, request detail, risk assessment, attachments, audit history, and approve/deny controls.
- [x] Composer supports floating expanded reply/new-message panel with fields, AI action chips, attachment row, draft state, and Request Send CTA.
- [x] First-run account setup is a dedicated work-area screen, not buried under thread content.
- [x] Command Center is keyboard-first and reachable from the rail.
- [x] Audit Log exists as a dedicated screen and contextual request history.
- [x] AI Provider Settings and AI Index Status are dedicated, readable surfaces.
- [x] Empty, loading, and error states exist for major workflows.
- [x] Icon-only controls have labels/tooltips and keyboard focus behavior.
- [x] Root SwiftUI view is decomposed into maintainable components.
- [x] SwiftPM launch works without crashing.
- [x] Local automated tests pass.
- [x] Visual verification against the provided reference images is performed.

Verification evidence:
- `rtk swift run PlainpostDesignSnapshot output/design-verification`
- `output/design-verification/01-smart-inbox.png`
- `output/design-verification/02-settings-ai-providers.png`
- `output/design-verification/03-approval-queue.png`
- `output/design-verification/04-compose.png`
- `rtk swift test`
- `rtk swift run PlainpostApp`

## 1. Purpose

Plainpost is a local-first desktop mail client for macOS that combines a fast personal inbox, human approval for outbound mail, local AI assistance, and an auditable agent workflow.

The design goal is not to clone Spark Mail literally. The goal is to achieve the same level of polish, density, clarity, and desktop-native confidence while preserving Plainpost's distinct product needs: local storage, explicit send approval, AI provider control, and auditability.

## 2. Product Principles

1. **People-first scanning**
   The inbox must make real human mail obvious before automation, newsletters, receipts, and system mail.

2. **Fast desktop triage**
   Common operations must be visible, keyboard-accessible, and possible without navigating through full-page settings or modal-heavy flows.

3. **Trust before automation**
   AI and agent actions must be useful, but visibly bounded. The user must always understand when mail was drafted by an agent, when approval is required, and what will be sent.

4. **Local-first confidence**
   The UI must communicate that mail, credentials, approval state, and AI defaults are local unless explicitly configured otherwise.

5. **Audit without clutter**
   Audit information must be available in context, but it must not dominate the reading or composing experience.

## 3. Target Platforms

Primary:
- macOS desktop app, SwiftUI.
- Windowed experience optimized for 1180px and wider.

Secondary:
- Narrow desktop widths down to 900px.
- Future iPad adaptation may reuse navigation concepts, but this PRD targets macOS first.

Not in scope for this PRD:
- Mobile phone layout.
- Web app.
- Marketing site.

## 4. Visual Direction

### 4.1 Reference Direction

Use Spark Mail as the visual quality bar:
- Dark, low-noise desktop surface.
- Thin persistent icon rail.
- Dense message rows.
- Rounded selected-row highlight.
- Avatar or sender mark per conversation.
- Subtle action chrome.
- Floating AI/composer affordances.
- Sparse reader view with plenty of horizontal breathing room.

Do not copy Spark's brand, exact icons, or exact colors. The app must feel Plainpost-specific.

### 4.2 Design Tone

Plainpost should feel:
- Quiet.
- Fast.
- Technical but not developer-only.
- Trustworthy.
- Desktop-native.
- Slightly premium, not playful.

Avoid:
- Marketing-page styling.
- Big cards everywhere.
- Nested cards.
- Oversized headings.
- Purple-gradient AI tropes.
- Low-contrast gray soup.
- Decorative blobs, orbs, or generic AI art.
- In-app instructional prose that explains obvious controls.

### 4.3 Visual System Requirements

The implementation must define reusable design tokens:

- Background layers:
  - App background.
  - Navigation rail background.
  - Inbox/list background.
  - Reader background.
  - Floating panel background.
  - Input/control background.

- Text colors:
  - Primary.
  - Secondary.
  - Tertiary.
  - Disabled.
  - Destructive.
  - Success.
  - Warning.

- Accent colors:
  - Primary selection blue.
  - Unread indicator blue.
  - AI accent.
  - Approval/risk accent.

- Border and separator tokens:
  - Hairline separator.
  - Focus ring.
  - Panel stroke.
  - Destructive stroke.

- Radius:
  - Icon rail selected item: 10-12px equivalent.
  - Message row: 16-22px equivalent.
  - Floating composer: 12-16px equivalent.
  - Panels: 10-14px equivalent.

- Typography:
  - Use native macOS system typography unless a full brand typography system is introduced.
  - Message rows must use compact sizes.
  - Reader body must be comfortable at 14-16pt equivalent.
  - No viewport-scaled typography.
  - Letter spacing must remain normal.

## 5. Information Architecture

### 5.1 Primary App Regions

The app has three persistent desktop regions:

1. **Navigation rail**
   Thin icon-only rail for top-level destinations and utility actions.

2. **Mailbox/list column**
   Inbox, mailbox, search, smart category, and folder lists.

3. **Reading/work area**
   Thread reader, composer, approval flow, settings panels, and contextual tools.

### 5.2 Top-Level Destinations

The navigation system must support:

- Smart Inbox.
- All Inboxes.
- Personal.
- Notifications.
- Newsletters.
- Drafts.
- Sent.
- Archive.
- Trash.
- Approval Queue.
- Labels.
- AI Index Status.
- Settings.

The rail may show the most important destinations directly and move less-used ones into a "More" menu, but every destination must remain reachable without search.

### 5.3 Command Center

Command Center is a universal overlay reachable from:
- `Cmd+K`.
- Rail utility button.
- Search/command affordance when appropriate.

It must support commands for:
- Search mail.
- Go to Smart Inbox.
- Go to Drafts.
- Summarize current thread.
- Draft reply.
- Archive selected.
- Delete selected.
- Mark unread.
- Apply label.
- Open approval queue.
- Create new draft.
- Rebuild AI index.

## 6. Core User Flows

### 6.1 First Run And Account Setup

Goal:
Connect the first email account without making the user understand internal storage or service setup.

Flow:
1. User opens Plainpost.
2. If no account exists, the reading area shows an account setup screen.
3. User enters display name, email, IMAP host/port, SMTP host/port, username, IMAP password, SMTP password.
4. User clicks Connect.
5. App validates ports locally.
6. App validates IMAP and SMTP connectivity.
7. On success, account is stored locally and inbox is shown.
8. On failure, user receives a specific recovery message.

Requirements:
- The setup screen must be a real first-run surface, not a cramped panel hidden below the thread.
- Passwords must use secure fields.
- The connect button must be disabled until required fields are present.
- Validation state must show progress.
- Error copy must distinguish invalid port, authentication failure, network failure, TLS/security failure, and unknown failure when backend supports it.
- Successful setup must show the connected account and next action.

### 6.2 Inbox Triage

Goal:
Let the user scan, prioritize, and act on messages quickly.

Flow:
1. User opens Smart Inbox.
2. Messages are grouped by smart categories.
3. User scans unread people-first mail.
4. User selects a row.
5. Thread opens in reader area.
6. User can archive, mark read/unread, delete, pin/unpin, label, or reply.

Requirements:
- Smart Inbox groups must include Personal, Notifications, Newsletters, Pinned, Seen.
- Rows must expose sender, subject, preview, date/time, unread state, category, pinned state, and primary actions.
- Unread state must be visible through both weight and a dot/indicator.
- Selected row must be visually unmistakable.
- Row height must be compact enough for high-volume scanning.
- Row hover must reveal actions without causing layout shift.
- Empty groups must collapse or show a subtle empty state.
- "Show all" behavior must exist for collapsed groups.
- List position must not jump when actions are revealed.

### 6.3 Search

Goal:
Find mail quickly without leaving the current workflow.

Flow:
1. User focuses search via visible control or keyboard shortcut.
2. User types query.
3. Results update in the list column.
4. User selects a result.
5. Thread opens in reader area.

Requirements:
- Search field must be available in the mailbox/list column.
- Search must support sender, subject, preview/body metadata, label/category, and commands where applicable.
- Empty query returns normal mailbox view.
- No results state must offer clear next action.
- Search results must preserve row affordances.
- Command Center search and mailbox search may share query behavior, but their UI roles must remain distinct.

### 6.4 Thread Reading

Goal:
Read a conversation comfortably and act without visual clutter.

Flow:
1. User selects a message row.
2. Thread reader shows subject, participants, messages, and actions.
3. User can reply, reply all, forward, archive, delete, mark unread/read, pin, or ask AI.
4. If remote images were blocked, user sees the protection status.

Requirements:
- Thread reader must have a top action strip.
- The subject must be clear but not oversized.
- Participant identity must be visible.
- Each message must show sender, recipients when expanded, timestamp, remote image blocking status, and body.
- Sanitized body rendering must preserve readable formatting.
- Remote image blocking must be visible but not alarming.
- Long threads must support collapsing older messages.
- The latest message should be easy to find.
- Reply actions must be near message bottom/right or in toolbar.

### 6.5 Compose And Reply

Goal:
Create, edit, save, and request sending of drafts without losing reading context.

Flow:
1. User clicks compose or reply.
2. Composer opens as a floating panel or dedicated compose surface depending on context.
3. User edits recipients, subject, and body.
4. User can save draft.
5. User can request send.
6. If request send succeeds, approval queue receives a pending send request.

Requirements:
- Composer must support To, Cc, Bcc, Subject, and body.
- Reply composer must inherit thread subject and likely recipient.
- Full compose must be possible outside a thread.
- Draft state must be visible.
- Save Draft and Request Send must be distinct actions.
- Request Send must not imply immediate delivery.
- Disabled state must explain missing required content where possible.
- Body editor must support multiline content and preserve line breaks.
- Composer must support attachments in the UI even if attachment backend is staged separately.
- Composer must expose AI writing actions as bounded tools, not magic text replacement.
- Composer must be resizable or expandable on desktop.
- User must be able to close composer with unsaved-change handling.

### 6.6 Approval Queue

Goal:
Review outbound send requests before any agent-generated or app-mediated email leaves the machine.

Flow:
1. Send request is created.
2. Approval Queue badge increments.
3. User opens Approval Queue.
4. User reviews subject, recipients, sender/agent, risk flags, attachments, and status.
5. User approves or denies.
6. High-risk approvals require local authentication.
7. Approved messages are sent through configured SMTP and written to Sent.
8. Denied messages remain auditable.

Requirements:
- Approval Queue must be a top-level destination.
- Each request row/card must show:
  - Subject.
  - Recipient summary.
  - Requesting actor or agent.
  - Risk flags.
  - Attachment indicator.
  - Authentication requirement.
  - Current status.
  - Draft preview.
- Approve and Deny must be visually distinct.
- Approve must require confirmation when risk is high, recipients are external, attachments exist, or body was AI-generated.
- Deny must allow optional reason.
- Status updates must be immediate after action.
- Failed send state must show retry and failure reason.

### 6.7 AI Assistant

Goal:
Provide local, explainable assistance for reading and drafting without obscuring privacy boundaries.

Flow:
1. User opens thread.
2. User invokes AI summarize or draft reply.
3. AI panel shows provider, model, locality, context, warning, summary, and action items.
4. User may use summary or insert generated draft into composer.

Requirements:
- AI must visibly identify provider and model.
- Local-only status must be visible.
- Remote-disabled state must be explicit.
- User must see what thread/context the AI used.
- AI summary must not auto-send.
- AI draft must create editable draft content only.
- AI errors must be recoverable and non-blocking.
- AI panel must be collapsible.
- AI prompt pill must not overlap composer controls.

### 6.8 AI Provider Settings

Goal:
Allow the user to understand and select available AI providers.

Flow:
1. User opens AI Provider Settings.
2. User sees provider rows.
3. User selects a supported provider.
4. Selection persists.

Requirements:
- Providers must show display name, status, locality, chat model, embedding model, detail, and selected state.
- Deterministic local provider must be available by default.
- Ollama Local must show unavailable until checked or configured.
- Remote AI must be shown as disabled for MVP.
- Selecting unsupported provider must be ignored.
- Settings must persist via user defaults or equivalent local store.

### 6.9 Audit Log

Goal:
Make sensitive actions reviewable without turning the app into an admin console.

Flow:
1. User opens Audit Log from Settings, thread context, or approval detail.
2. User sees recent actions.
3. User filters by actor, action, target, result, or time.
4. User can inspect details when needed.

Requirements:
- Audit row must show action, actor, target summary, result, and timestamp.
- Audit log must never expose secrets.
- Send approval, denial, draft creation, sent copy, and mail mutations must be auditable.
- Default view should show recent events.
- Contextual audit snippets may appear in approval/thread detail, but full audit belongs in a dedicated surface.

### 6.10 Mail Actions

Goal:
Support common mailbox actions with clear local/remote effects.

Actions:
- Mark read.
- Mark unread.
- Archive.
- Delete.
- Pin.
- Unpin.
- Apply label.
- Remove label.
- Move to mailbox.

Requirements:
- Actions must show immediate optimistic feedback only when safe.
- Failed remote mutation must revert or show retry.
- Destructive actions must be undoable where possible.
- Keyboard shortcuts must exist for common triage actions.

## 7. Screen Requirements

### 7.1 App Shell

Purpose:
Persistent desktop frame for navigation and work.

Required regions:
- Thin left rail.
- Inbox/list column.
- Detail/work area.
- Floating command/AI affordance.

Required behavior:
- Window minimum size: 1180x720 recommended; must degrade gracefully to 900x640.
- Columns must be resizable or use sensible breakpoints.
- No content may be hidden under floating controls.
- App must remember selected mailbox, column widths, and last selected account where supported.

Acceptance criteria:
- At least 12 message rows are visible in a 1440x900 window when Smart Inbox has enough data.
- Top-level navigation is usable without text labels, with tooltips.
- Selected nav item and selected message row are unambiguous.

### 7.2 Navigation Rail

Purpose:
Fast destination switching with minimal horizontal footprint.

Required elements:
- Inbox/Smart Inbox.
- Pinned/Personal or priority mail.
- Drafts.
- Sent.
- Archive.
- Trash.
- Approval Queue.
- Command Center.
- Settings/account.

Required states:
- Default.
- Hover.
- Selected.
- Disabled.
- Badge present.
- Badge overflow.

Acceptance criteria:
- Every icon has a tooltip.
- Badges do not resize the rail.
- Rail remains fixed while inbox/detail scroll.

### 7.3 Smart Inbox Screen

Purpose:
Default work screen for daily triage.

Required sections:
- People/Personal.
- Notifications.
- Newsletters.
- Pinned.
- Seen/read collapsed group.

Required row content:
- Unread indicator.
- Avatar/sender mark.
- Sender.
- Subject.
- Preview.
- Attachment indicator.
- Category indicator.
- Date/time.
- Actions on hover.

Acceptance criteria:
- People-first mail is above automated mail.
- Row text truncates cleanly.
- Hover actions do not move text.
- Empty state is calm and compact.

### 7.4 Classic Inbox / Mailbox Screen

Purpose:
Full chronological mailbox view.

Requirements:
- Same row component as Smart Inbox.
- Sorting by received date descending by default.
- Optional filters for unread, pinned, attachments, category, account.
- Mailbox title and account/subtitle visible.

Acceptance criteria:
- Switching Smart/Classic does not lose selected thread where possible.
- Classic mode must not use large card layout.

### 7.5 Thread Reader Screen

Purpose:
Read selected conversation and act.

Required regions:
- Top toolbar.
- Subject and participants.
- Message stack.
- Inline AI summary collapsed by default or compact.
- Reply composer dock.

Required toolbar actions:
- Back.
- Done/archive.
- Delete.
- Mark read/unread.
- Pin.
- Move/archive.
- Attach/link where applicable.
- Snooze/remind where applicable.
- AI.
- More.
- Assign/share only if those workflows exist; otherwise omit.

Acceptance criteria:
- Toolbar is visually light.
- Message card width is readable and does not span extreme widths without constraints.
- Thread body is selectable.
- Blocked remote images are indicated.

### 7.6 Composer Screen / Floating Composer

Purpose:
Draft and request send.

Required modes:
- New message.
- Reply.
- Reply all.
- Forward.
- Expanded/full composer.
- Minimized draft.

Required controls:
- To.
- Cc.
- Bcc.
- Subject.
- Body.
- Attach.
- AI assist.
- Save draft.
- Request send.
- Close.
- Expand/pop out.

Required states:
- Empty.
- Dirty unsaved.
- Saving.
- Saved.
- Send request pending.
- Validation error.
- Send request created.

Acceptance criteria:
- Request Send cannot be confused with immediate Send.
- Composer does not overlap AI pill or important thread content.
- Unsaved close prompts or autosaves.

### 7.7 Approval Queue Screen

Purpose:
Human review of outbound sends.

Required layout:
- Queue list.
- Detail preview.
- Risk/metadata panel.
- Actions.

Required filters:
- Pending.
- Approved/sent.
- Denied.
- Failed.
- High risk.
- Agent/requester.

Acceptance criteria:
- User can approve/deny from list for low-risk simple requests.
- User must open detail or confirmation for high-risk requests.
- Risk flags are readable, not raw snake_case only.

### 7.8 Approval Detail Screen

Purpose:
Inspect one send request before deciding.

Required content:
- Draft subject.
- From account.
- To/Cc/Bcc recipients.
- Requesting actor.
- Risk score and flags.
- Attachment list.
- Full body preview.
- Diff from original draft if available.
- Audit history for this request.
- Approve.
- Deny.
- Edit draft.

Acceptance criteria:
- Bcc recipients are visible to approver but never leaked into SMTP headers.
- High-risk approval invokes local authentication.
- Failed send shows actionable error.

### 7.9 Account Setup Screen

Purpose:
Add and validate mail account.

Required sections:
- Identity.
- Incoming mail.
- Outgoing mail.
- Security/credential note.
- Validation result.

Required fields:
- Display name.
- Email.
- IMAP host.
- IMAP port.
- SMTP host.
- SMTP port.
- Username.
- IMAP password.
- SMTP password.

Acceptance criteria:
- First-run version uses the main work area.
- Settings version can be a panel.
- Invalid fields are indicated inline.
- Passwords are never logged or displayed.

### 7.10 Settings Screen

Purpose:
Configure app behavior.

Required sections:
- Accounts.
- AI Providers.
- Security and Privacy.
- Notifications.
- Mail Rules.
- Local Storage.
- Advanced/Diagnostics.

Requirements:
- Settings must not be mixed into thread reader by default.
- AI provider settings must be a dedicated subsection.
- Account credentials management must be separate from account display metadata.
- Local storage path and index state must be visible in diagnostics.

Mail Rules requirements:
- The All Accounts selection lists every rule and creates global rules.
- A single-account selection lists that account's rules plus global rules and creates account-specific rules.
- Conditions support From, To/Cc, and Subject matching, including exact email, whole-domain (with subdomains), and subject-contains rules.
- Actions can be combined: Skip Inbox (server archive), Mark as Read, and Suppress Notification.
- New messages are evaluated automatically before notification delivery.
- Applying a rule to existing mail requires a counted, per-account preview and explicit confirmation against a stable message snapshot.

### 7.11 AI Provider Settings Screen

Purpose:
Provider selection and status.

Required provider row content:
- Provider name.
- Status.
- Locality.
- Chat model.
- Embedding model.
- Detail.
- Selected indicator.
- Check/test action where applicable.

Acceptance criteria:
- Remote providers are clearly disabled for MVP.
- User can select deterministic local or available Ollama provider.
- Provider status refresh is available.

### 7.12 AI Index Status Screen

Purpose:
Show semantic-search/index health.

Required content:
- State: not built, paused, rebuilding, ready, failed.
- Indexed message count.
- Provider.
- Model.
- Staleness.
- Last rebuild time when available.
- Rebuild action.
- Pause/resume action.

Acceptance criteria:
- Warning badge appears when stale, paused, failed, or not built.
- Rebuild action is explicit and shows progress.

### 7.13 Command Center Overlay

Purpose:
Keyboard-first navigation and actions.

Required behavior:
- Opens with `Cmd+K`.
- Query field is focused on open.
- Results filter by title and category.
- Keyboard selection with arrow keys.
- Enter executes.
- Escape closes.

Required result content:
- Icon.
- Command title.
- Category.
- Keyboard shortcut.

Acceptance criteria:
- Empty query shows useful defaults.
- Unknown query shows no-results state.
- Execution closes overlay and updates status where relevant.

### 7.14 Audit Log Screen

Purpose:
Review system and agent actions.

Required table columns:
- Timestamp.
- Action.
- Actor.
- Target.
- Result.
- Summary.

Required filters:
- Actor.
- Action.
- Result.
- Date range.
- Target type.

Acceptance criteria:
- No secrets appear in UI.
- Rows are newest-first by default.
- Detail drawer shows structured metadata without exposing credentials.

### 7.15 Empty And Error Screens

Required empty states:
- No accounts.
- No messages.
- No search results.
- No pending approvals.
- No audit events.
- AI provider unavailable.
- AI index not built.

Requirements:
- Empty states must be compact and action-oriented.
- Error states must include recovery action.
- Errors must not expose secrets or raw stack traces.

## 8. Interaction Requirements

### 8.1 Keyboard

Required shortcuts:
- `Cmd+K`: Command Center.
- `Cmd+N`: New message.
- `Cmd+R`: Reply.
- `Shift+Cmd+R`: Reply all.
- `Cmd+F`: Search current mailbox.
- `E`: Archive selected.
- `Delete`: Delete selected.
- `U`: Mark unread/read toggle.
- `P`: Pin/unpin.
- `Esc`: Close overlay/composer when safe.

Keyboard shortcuts must be discoverable through tooltips, menus, or command center.

### 8.2 Pointer

Requirements:
- Hover states for rows, rail icons, toolbar icons, and floating controls.
- Row actions appear on hover without layout shift.
- Tooltips for icon-only controls.
- Click target minimum 28x28pt for compact controls, larger where space allows.

### 8.3 Focus

Requirements:
- Focus ring visible for keyboard navigation.
- Overlay open must trap focus until closed.
- Composer fields must have predictable tab order.
- Approval confirmation must return focus to originating row after close.

## 9. Data And State Requirements

### 9.1 Core Data Models Exposed To UI

Inbox row:
- id.
- sender.
- subject.
- preview.
- category.
- category label.
- unread state.
- pinned state.
- date label.
- available actions.

Thread:
- subject.
- participants.
- summary status.
- action items.
- available actions.
- messages.

Thread message:
- id.
- sender.
- safe body text.
- body kind.
- blocked remote image URLs/count/status.

Composer:
- to.
- cc.
- bcc.
- subject.
- body plain.
- working state.
- status message.
- last draft id.
- last send request id.

Approval queue item:
- id.
- agent name.
- subject.
- recipient summary.
- risk flags.
- attachment presence.
- authentication requirement.
- status.

AI provider row:
- id.
- title.
- status label.
- locality label.
- model summary.
- detail.
- icon.
- selected state.

Audit row:
- id.
- action.
- actor id.
- target summary.
- result.

### 9.2 Loading States

Every async operation must expose:
- Idle.
- Working.
- Success.
- Recoverable failure.

Operations:
- Account connect.
- Mail sync.
- Inbox action.
- Draft save.
- Send request.
- Approval approve/deny.
- AI summarize.
- AI provider check.
- AI index rebuild.
- Audit refresh.

### 9.3 Error Handling

Errors must be mapped to user-facing categories:
- Validation.
- Authentication.
- Network.
- TLS/security.
- Permission denied.
- Missing credentials.
- Provider unavailable.
- Local storage unavailable.
- Unknown.

Raw errors may be logged locally but not displayed in primary UI unless safe.

## 10. Security And Privacy Requirements

1. Passwords and tokens must never be displayed after entry.
2. Passwords must never appear in audit log, local logs, status messages, or crash reports generated by app code.
3. Remote images must be blocked by default unless user opts in.
4. AI context must be local by default.
5. Remote AI must be disabled for MVP.
6. Agent-requested sends must always require approval.
7. High-risk approval must require local authentication.
8. Bcc must never be emitted in outbound message headers.
9. Destructive mail actions must be auditable.
10. The app must distinguish local draft save from outbound send request.

## 11. Accessibility Requirements

Requirements:
- All icon-only controls need accessibility labels and tooltips.
- Text contrast must meet WCAG AA for normal text.
- Focus state must be visible.
- Dynamic type should not break controls where SwiftUI supports it.
- Color cannot be the only indicator for unread, selected, risk, or error state.
- VoiceOver labels must include unread state, sender, subject, date, and action availability for message rows.
- Modal and overlay focus must be contained.
- Approval actions must announce result.

## 12. Performance Requirements

Targets:
- App shell appears within 1 second after runtime initialization.
- Inbox row scrolling remains smooth with 5,000 messages loaded.
- Search result update target under 150ms for local indexed metadata.
- Opening Command Center under 100ms.
- Composer input latency imperceptible.

Implementation requirements:
- Use lazy lists for message rows.
- Avoid nested expensive SwiftUI layout in rows.
- Do not render full thread body for every row.
- Defer heavy AI/provider checks until requested.
- Do not initialize UserNotifications in non-bundled local SwiftPM runs.

## 13. Technical Architecture Requirements

### 13.1 SwiftUI Structure

The UI should be decomposed into reusable components:

- AppShellView.
- NavigationRail.
- MailboxColumn.
- InboxHeader.
- MessageRow.
- SmartInboxSection.
- ThreadReader.
- ThreadToolbar.
- ThreadMessage.
- FloatingComposer.
- ApprovalQueueView.
- ApprovalDetailView.
- AccountSetupView.
- SettingsView.
- AIProviderSettingsView.
- AIIndexStatusView.
- CommandCenterOverlay.
- AuditLogView.
- EmptyStateView.
- ErrorBanner.

The root view must not contain every screen in one file.

### 13.2 View Model Boundaries

View models should expose plain UI state and commands. Views should not perform business logic.

Required improvements:
- Introduce selected mailbox/thread/message state.
- Model full screen navigation explicitly.
- Separate inbox actions from row rendering.
- Add UI state for composer open/minimized/expanded.
- Add approval detail selection state.
- Add settings navigation state.
- Add explicit loading/error models.

### 13.3 Design Tokens

Create a single design token source:
- Colors.
- Radii.
- Spacing.
- Typography.
- Shadows.
- Control sizes.
- Separator styles.

No hard-coded colors should appear in feature views except one-off semantic exceptions.

### 13.4 Component Requirements

MessageRow must support:
- Dense and relaxed density.
- Selected state.
- Hover action state.
- Unread/read.
- Pinned.
- Attachment.
- Category.
- Multi-account indicator.
- Accessibility label.

FloatingComposer must support:
- New/reply/forward modes.
- Dirty state.
- Expanded state.
- Minimized state.
- Validation state.

ApprovalRequestCard must support:
- Risk levels.
- Status.
- Inline approve/deny.
- Detail open.
- Retry failed send.

## 14. Acceptance Criteria For Redesign

The redesign is acceptable when:

1. All required screens in section 7 exist as distinct UI surfaces or intentionally grouped surfaces.
2. First-run account setup is not buried beneath thread content.
3. Smart Inbox visually prioritizes people-first mail and supports dense scanning.
4. Thread reader and composer can be used simultaneously without overlap.
5. Approval Queue is a first-class workflow with detail review.
6. AI Provider Settings and AI Index Status are understandable without reading code.
7. Command Center is keyboard usable.
8. Audit Log is available and secret-safe.
9. Empty/error/loading states exist for all async workflows.
10. Icon-only controls have labels/tooltips.
11. The root SwiftUI view is decomposed into maintainable components.
12. The app can run from SwiftPM without crashing.

## 15. Non-Goals

This PRD does not require:
- Pixel-perfect Spark clone.
- Team collaboration, assign, or share workflows unless they are backed by product functionality.
- Calendar integration.
- Snooze/remind backend, unless already implemented.
- Remote AI provider enablement.
- Mobile app.
- Full rich-text composer.
- Third-party plugin marketplace.

## 16. Open Product Decisions

Resolve before implementation:

1. Should Smart Inbox be the default for all users or only after account setup completes?
2. Should Approval Queue be visible to non-agent users when empty?
3. Should new compose be floating by default or full-height detail area?
4. Should AI summary live in thread header, side panel, or floating pill?
5. Should deleted messages move to Trash or issue immediate remote delete?
6. Should user-authenticated approvals be required for all sends or only high-risk sends?
7. Should settings be a full screen, sheet, or separate window?

## 17. Recommended Implementation Phases

### Phase 1: Structure And Navigation
- Split root view into shell, rail, inbox, reader, composer, settings, overlays.
- Add app navigation state.
- Add design tokens.
- Add first-run account setup screen.

### Phase 2: Inbox And Reader
- Build dense MessageRow component.
- Build Smart Inbox sections.
- Build Classic Inbox.
- Build Thread Reader and toolbar.

### Phase 3: Composer And Approval
- Build floating composer states.
- Build Approval Queue and Approval Detail.
- Add confirmation and authentication states.

### Phase 4: AI And Audit
- Build AI Assistant panel.
- Build AI Provider Settings.
- Build AI Index Status.
- Build Audit Log.

### Phase 5: Polish And QA
- Keyboard shortcuts.
- Accessibility labels.
- Empty/error/loading states.
- Visual QA against reference screenshots.
- Performance pass for large inboxes.

## 18. Required QA Checklist

Before shipping redesigned UI:

- Launch from SwiftPM.
- Launch as bundled app if packaging exists.
- First-run no account.
- Existing account with empty inbox.
- Existing account with many messages.
- Smart Inbox grouped messages.
- Classic Inbox.
- Search no results.
- Search with results.
- Thread with plain text.
- Thread with sanitized HTML.
- Thread with blocked remote images.
- New compose.
- Reply compose.
- Save draft.
- Request send.
- Approval queue empty.
- Approval queue pending.
- High-risk approval.
- Deny request.
- Failed send.
- AI provider unavailable.
- AI summary success.
- AI summary failure.
- Audit log empty.
- Audit log populated.
- Keyboard-only navigation.
- VoiceOver smoke test.
- Narrow window.
- Wide window.
