/** @jsxImportSource preact */

import { useEffect, useRef, useState } from 'preact/hooks';

import type { UnreadMessage } from '../api/contracts';
import { PopupController, type PopupState, type ReplyState } from '../state/popup-controller';

export interface AppProps {
  controller: PopupController;
  onRetryConnection?: () => void | Promise<void>;
}

export function App({ controller, onRetryConnection }: AppProps) {
  const [state, setState] = useState<PopupState>(controller.state);
  const surfaceRef = useRef<HTMLElement>(null);

  useEffect(() => {
    const unsubscribe = controller.subscribe(setState);
    setState(controller.state);
    return unsubscribe;
  }, [controller]);

  useEffect(() => {
    surfaceRef.current
      ?.querySelector<HTMLElement>('[data-route-heading]')
      ?.focus({ preventScroll: true });
  }, [state.kind]);

  return (
    <main class="popup-shell" ref={surfaceRef}>
      {renderState(state, controller, onRetryConnection)}
    </main>
  );
}

function renderState(
  state: PopupState,
  controller: PopupController,
  onRetryConnection?: () => void | Promise<void>,
) {
  switch (state.kind) {
  case 'connecting':
    return (
      <CenteredState eyebrow="Local mail" title="Plainpost">
        <p class="state-message" role="status">Connecting to Plainpost…</p>
        <span class="connection-pulse" aria-hidden="true" />
      </CenteredState>
    );
  case 'list':
    return (
      <section class="surface surface-list" aria-labelledby="unread-title">
        <header class="topbar list-topbar">
          <div>
            <p class="eyebrow">Quick mail</p>
            <h1 id="unread-title" tabIndex={-1} data-route-heading>Unread</h1>
          </div>
          <span class="count" aria-label={`${state.messages.length} unread messages`}>
            {state.messages.length.toString().padStart(2, '0')}
          </span>
        </header>

        {state.refreshError ? (
          <div class="notice notice-stale">
            <p role="status">
              Couldn’t refresh — showing mail from {relativeTime(state.lastSuccessfulSyncAt)}
            </p>
            <button class="text-action" type="button" onClick={() => void controller.retry()}>
              Retry refresh
            </button>
          </div>
        ) : state.isRefreshing ? (
          <p class="sync-line" role="status">Refreshing…</p>
        ) : (
          <p class="sync-line">
            Updated {relativeTime(state.lastSuccessfulSyncAt)}
          </p>
        )}

        {state.actionError && <p class="notice notice-error" role="alert">{state.actionError}</p>}

        {state.messages.length === 0 ? (
          <div class="empty-state">
            <span class="empty-mark" aria-hidden="true">✓</span>
            <p role="status">You're caught up</p>
            <small>Nothing unread on this Mac.</small>
          </div>
        ) : (
          <ol class="message-list" aria-label="Unread messages">
            {state.messages.map(message => (
              <UnreadRow
                key={message.id}
                message={message}
                onOpen={() => void controller.openMessage(message.id)}
              />
            ))}
          </ol>
        )}
      </section>
    );
  case 'reader':
    return (
      <section class="surface reader" aria-labelledby="message-subject">
        <NavigationHeader
          label="Back to unread mail"
          eyebrow="From"
          onBack={() => controller.back()}
        />
        <div class="reader-heading">
          <p class="sender-line">
            <strong>{displaySender(state.message.senderName, state.message.sender)}</strong>
            <span>{state.message.sender}</span>
          </p>
          <h1 id="message-subject" tabIndex={-1} data-route-heading>{state.message.subject}</h1>
        </div>
        <article class="message-body">{state.message.bodyPlain}</article>

        <section class="ai-panel" aria-label="AI summary">
          <div class="panel-heading">
            <div>
              <p class="eyebrow">On demand</p>
              <h2>AI summary</h2>
            </div>
            <button
              class="secondary-action compact-action"
              type="button"
              disabled={state.isSummarizing}
              onClick={() => void controller.summarize()}
            >
              {state.isSummarizing ? 'Summarizing…' : 'Summarize'}
            </button>
          </div>
          {state.summary && <p class="summary-copy">{state.summary}</p>}
          {state.summaryError && <p class="inline-error" role="status">{state.summaryError}</p>}
        </section>

        {state.actionError && <p class="notice notice-error" role="alert">{state.actionError}</p>}
        <footer class="action-footer">
          <button class="primary-action" type="button" onClick={() => void controller.beginReply()}>
            Reply
            <ArrowIcon />
          </button>
        </footer>
      </section>
    );
  case 'reply':
    return <ReplySurface state={state} controller={controller} />;
  case 'sent':
    return (
      <CenteredState eyebrow="Delivery" title="Delivered">
        <p class="success-message" role="status">Reply sent</p>
        <p class="state-detail">Your reply to {displaySender(state.message.senderName, state.message.sender)} is on its way.</p>
        <button class="primary-action" type="button" onClick={() => controller.back()}>
          Back to unread mail
        </button>
      </CenteredState>
    );
  case 'interruptedSend':
    return (
      <CenteredState eyebrow="Delivery" title="Delivery status uncertain">
        <p class="notice notice-uncertain" role="alert">
          Delivery status uncertain — check Sent in Plainpost before taking another action
        </p>
      </CenteredState>
    );
  case 'unavailable':
    return (
      <CenteredState eyebrow="Connection needed" title="Plainpost is unavailable">
        <p class="state-detail">The local mail bridge could not be reached.</p>
        <p class="state-message">Open Plainpost and try again</p>
        <div class="stacked-actions">
          <button
            class="primary-action"
            type="button"
            onClick={() => {
              if (onRetryConnection) void onRetryConnection();
              else void controller.retry();
            }}
          >
            Retry connection
          </button>
        </div>
      </CenteredState>
    );
  case 'versionMismatch':
    return (
      <CenteredState eyebrow="Update required" title="Versions don’t match">
        <p class="state-message" role="alert">
          Plainpost and this extension must be updated together
        </p>
      </CenteredState>
    );
  }
}

function ReplySurface({ state, controller }: { state: ReplyState; controller: PopupController }) {
  const [instruction, setInstruction] = useState('');
  const isLocked = state.deliveryState === 'sending' || state.deliveryState === 'deliveryUncertain';
  const canGoBack = !isLocked && !state.isDraftingWithAI;

  return (
    <section class="surface reply" aria-labelledby="reply-title">
      <NavigationHeader
        label="Back to message"
        eyebrow="Replying to"
        disabled={!canGoBack}
        onBack={() => controller.back()}
      />
      <div class="reply-heading">
        <p class="recipient">To {state.draft.to.join(', ')}</p>
        <h1 id="reply-title" tabIndex={-1} data-route-heading>{state.draft.subject}</h1>
      </div>

      <div class="field-group reply-field">
        <label for="reply-body">Reply</label>
        <textarea
          id="reply-body"
          rows={8}
          value={state.draft.body}
          disabled={isLocked}
          onInput={event => {
            void controller.updateDraft(event.currentTarget.value).catch(() => undefined);
          }}
        />
        <p
          class={`draft-status${state.saveError ? ' has-error' : ''}`}
          role="status"
          aria-label="Draft status"
        >
          {state.isSaving
            ? 'Saving…'
            : state.saveError
              ? `Couldn’t save — ${state.saveError}`
              : 'Saved in Plainpost'}
        </p>
      </div>

      <section class="ai-panel reply-ai" aria-label="AI reply assistant">
        <label for="ai-instruction">AI instruction</label>
        <div class="instruction-row">
          <input
            id="ai-instruction"
            type="text"
            value={instruction}
            disabled={isLocked}
            placeholder="Confirm Friday and thank Maya"
            onInput={event => setInstruction(event.currentTarget.value)}
          />
          <button
            class="secondary-action"
            type="button"
            disabled={isLocked || state.isDraftingWithAI}
            onClick={() => void controller.draftWithAI(instruction)}
          >
            {state.isDraftingWithAI ? 'Drafting…' : 'Draft with AI'}
          </button>
        </div>
        {state.aiError && <p class="inline-error" role="status">{state.aiError}</p>}
      </section>

      {state.deliveryState === 'deliveryUncertain' ? (
        <p class="notice notice-uncertain" role="alert">
          Delivery status uncertain — check Sent in Plainpost before taking another action
        </p>
      ) : (
        <>
          {state.sendError && <p class="notice notice-error" role="alert">{state.sendError}</p>}
          <footer class="action-footer">
            <button
              class="primary-action"
              type="button"
              disabled={state.deliveryState === 'sending' || state.isDraftingWithAI}
              onClick={() => void controller.sendReply()}
            >
              {state.deliveryState === 'sending' ? 'Sending reply…' : 'Send reply'}
              {state.deliveryState !== 'sending' && <ArrowIcon />}
            </button>
          </footer>
        </>
      )}
    </section>
  );
}

function UnreadRow({ message, onOpen }: { message: UnreadMessage; onOpen: () => void }) {
  const sender = displaySender(message.senderName, message.sender);
  const when = relativeTime(message.sentAt ?? null);
  return (
    <li>
      <button
        class="message-row"
        type="button"
        aria-label={`${sender}, ${message.subject}, ${when}`}
        onClick={onOpen}
      >
        <span class="unread-dot" aria-hidden="true" />
        <span class="row-copy">
          <span class="row-meta">
            <strong>{sender}</strong>
            <time dateTime={message.sentAt ?? undefined} aria-hidden="true">{when}</time>
          </span>
          <span class="row-subject">{message.subject}</span>
          <span class="row-preview">{message.preview}</span>
        </span>
        <ArrowIcon />
      </button>
    </li>
  );
}

function NavigationHeader({
  label,
  eyebrow,
  disabled = false,
  onBack,
}: {
  label: string;
  eyebrow: string;
  disabled?: boolean;
  onBack: () => void;
}) {
  return (
    <header class="topbar navigation-bar">
      <button class="icon-action" type="button" aria-label={label} disabled={disabled} onClick={onBack}>
        <BackIcon />
      </button>
      <p class="eyebrow">{eyebrow}</p>
    </header>
  );
}

function CenteredState({
  eyebrow,
  title,
  children,
}: {
  eyebrow: string;
  title: string;
  children: preact.ComponentChildren;
}) {
  return (
    <section class="surface centered-state" aria-labelledby="state-title">
      <div class="state-monogram" aria-hidden="true">E</div>
      <p class="eyebrow">{eyebrow}</p>
      <h1 id="state-title" tabIndex={-1} data-route-heading>{title}</h1>
      {children}
    </section>
  );
}

function displaySender(name: string | null | undefined, address: string): string {
  return name?.trim() || address;
}

export function relativeTime(value: string | null, now = Date.now()): string {
  if (!value) return 'an unknown time';
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) return 'an unknown time';
  const seconds = Math.round((timestamp - now) / 1_000);
  const absolute = Math.abs(seconds);
  const formatter = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' });
  if (absolute < 60) return formatter.format(seconds, 'second');
  if (absolute < 3_600) return formatter.format(Math.round(seconds / 60), 'minute');
  if (absolute < 86_400) return formatter.format(Math.round(seconds / 3_600), 'hour');
  if (absolute < 604_800) return formatter.format(Math.round(seconds / 86_400), 'day');
  if (absolute < 2_629_746) return formatter.format(Math.round(seconds / 604_800), 'week');
  if (absolute < 31_556_952) return formatter.format(Math.round(seconds / 2_629_746), 'month');
  return formatter.format(Math.round(seconds / 31_556_952), 'year');
}

function ArrowIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true" focusable="false">
      <path d="M3 8h9M8.5 4.5 12 8l-3.5 3.5" />
    </svg>
  );
}

function BackIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true" focusable="false">
      <path d="m10.5 3.5-4.5 4.5 4.5 4.5M6.5 8H14" />
    </svg>
  );
}
