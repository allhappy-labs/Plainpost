/** @jsxImportSource preact */

import { cleanup, render, screen, waitFor, within } from '@testing-library/preact';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { PlainpostAPIError } from '../api/client';
import type {
  DeliveryResult,
  DraftResult,
  PlainpostClient,
  MessageDetail,
  UnreadMessage,
} from '../api/contracts';
import { PopupController } from '../state/popup-controller';
import { App } from './App';

function unreadMessage(id = 'm1', overrides: Partial<UnreadMessage> = {}): UnreadMessage {
  return {
    id,
    sender: 'maya@example.com',
    senderName: 'Maya Chen',
    subject: 'Trip schedule',
    preview: 'Are we still on for Friday?',
    sentAt: '2026-07-14T08:00:00Z',
    ...overrides,
  };
}

function messageDetail(id = 'm1'): MessageDetail {
  return {
    id,
    threadID: 't1',
    sender: 'maya@example.com',
    senderName: 'Maya Chen',
    subject: 'Trip schedule',
    bodyPlain: 'Are we still on for Friday?\n\nMaya',
    isSeen: true,
  };
}

function draft(overrides: Partial<DraftResult> = {}): DraftResult {
  return {
    id: 'd1',
    subject: 'Re: Trip schedule',
    to: ['maya@example.com'],
    body: 'Manual reply',
    contentHash: 'hash-1',
    aiGenerated: false,
    ...overrides,
  };
}

function fakeClient(overrides: Partial<PlainpostClient> = {}): PlainpostClient {
  return {
    sessionStatus: vi.fn().mockResolvedValue({ ready: true }),
    unreadList: vi.fn().mockResolvedValue({
      messages: [unreadMessage()],
      lastSuccessfulSyncAt: '2026-07-14T09:30:00Z',
    }),
    openMessage: vi.fn().mockResolvedValue(messageDetail()),
    incrementalSync: vi.fn().mockResolvedValue({
      completedAccountIDs: ['a1'],
      failedAccountIDs: [],
      newMessageCount: 0,
    }),
    summarize: vi.fn().mockResolvedValue({ summary: 'Friday is confirmed.' }),
    beginReply: vi.fn().mockResolvedValue(draft()),
    readDraft: vi.fn().mockResolvedValue(draft()),
    updateDraft: vi.fn().mockImplementation(
      async (_draftID: string, body: string) => draft({ body, contentHash: `hash-${body}` }),
    ),
    draftReply: vi.fn().mockResolvedValue(
      draft({ body: 'AI reply', contentHash: 'hash-ai', aiGenerated: true }),
    ),
    sendReply: vi.fn().mockResolvedValue({ requestID: 's1', jobID: 'j1', state: 'sent' }),
    ...overrides,
  };
}

async function controllerInListState(
  messages: UnreadMessage[] = [unreadMessage()],
  overrides: Partial<PlainpostClient> = {},
): Promise<{ controller: PopupController; api: PlainpostClient }> {
  const api = fakeClient({
    unreadList: vi.fn().mockResolvedValue({
      messages,
      lastSuccessfulSyncAt: '2026-07-14T09:30:00Z',
    }),
    ...overrides,
  });
  const controller = new PopupController(api, { debounceMilliseconds: 0, uuid: () => 'send-key' });
  await controller.open();
  await controller.refreshCompletion;
  return { controller, api };
}

async function controllerInReaderState(
  overrides: Partial<PlainpostClient> = {},
): Promise<{ controller: PopupController; api: PlainpostClient }> {
  const result = await controllerInListState([unreadMessage()], overrides);
  await result.controller.openMessage('m1');
  return result;
}

async function controllerInReplyState(
  overrides: Partial<PlainpostClient> = {},
): Promise<{ controller: PopupController; api: PlainpostClient }> {
  const result = await controllerInReaderState(overrides);
  await result.controller.beginReply();
  return result;
}

beforeEach(() => {
  vi.setSystemTime(new Date('2026-07-14T10:00:00Z'));
});

afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

describe('popup connection and list states', () => {
  it('announces the connecting state', () => {
    render(<App controller={new PopupController(fakeClient())} />);

    expect(screen.getByRole('status')).toHaveTextContent('Connecting to Plainpost…');
  });

  it('shows unread rows with a complete accessible name and opens the selected message', async () => {
    const { controller, api } = await controllerInListState();
    render(<App controller={controller} />);

    await userEvent.click(screen.getByRole('button', {
      name: 'Maya Chen, Trip schedule, 2 hours ago',
    }));

    expect(api.openMessage).toHaveBeenCalledWith('m1');
    const heading = screen.getByRole('heading', { name: 'Trip schedule' });
    expect(heading).toBeVisible();
    await waitFor(() => expect(heading).toHaveFocus());
  });

  it('uses native time markup for message timestamps', async () => {
    const { controller } = await controllerInListState();
    const { container } = render(<App controller={controller} />);

    const time = container.querySelector('time');
    expect(time).toHaveAttribute('datetime', '2026-07-14T08:00:00Z');
    expect(time).toHaveTextContent('2 hours ago');
  });

  it('shows the exact empty-state recovery copy', async () => {
    const { controller } = await controllerInListState([]);
    render(<App controller={controller} />);

    expect(screen.getByRole('status')).toHaveTextContent("You're caught up");
  });

  it('keeps cached rows and shows the exact stale-cache copy after refresh failure', async () => {
    const { controller } = await controllerInListState([unreadMessage()], {
      incrementalSync: vi.fn().mockRejectedValue(new Error('Offline')),
    });
    render(<App controller={controller} />);

    expect(screen.getByRole('button', { name: /Maya Chen, Trip schedule/ })).toBeVisible();
    expect(screen.getByRole('status')).toHaveTextContent(
      'Couldn’t refresh — showing mail from 30 minutes ago',
    );
    expect(screen.getByRole('button', { name: 'Retry refresh' })).toBeEnabled();
  });

  it('renders unavailable recovery actions and retries through the controller', async () => {
    const api = fakeClient({
      unreadList: vi.fn()
        .mockRejectedValueOnce(new PlainpostAPIError('UNAVAILABLE', 'Bridge unavailable.'))
        .mockResolvedValue({ messages: [], lastSuccessfulSyncAt: null }),
    });
    const controller = new PopupController(api);
    await controller.open();
    render(<App controller={controller} />);

    expect(screen.getByText('Open Plainpost and try again')).toBeVisible();
    expect(screen.queryByRole('link', { name: 'Open Plainpost and try again' })).toBeNull();
    await userEvent.click(screen.getByRole('button', { name: 'Retry connection' }));
    await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent("You're caught up"));
    expect(api.unreadList).toHaveBeenCalledTimes(3);
  });

  it('uses the supplied restore-aware connection retry when one is available', async () => {
    const controller = new PopupController(fakeClient({
      unreadList: vi.fn().mockRejectedValue(new PlainpostAPIError('UNAVAILABLE', 'Unavailable.')),
    }));
    await controller.open();
    const retryConnection = vi.fn().mockResolvedValue(undefined);
    render(<App controller={controller} onRetryConnection={retryConnection} />);

    await userEvent.click(screen.getByRole('button', { name: 'Retry connection' }));

    expect(retryConnection).toHaveBeenCalledOnce();
  });

  it('fails closed with the exact version-mismatch copy', async () => {
    const controller = new PopupController(fakeClient({
      unreadList: vi.fn().mockRejectedValue(
        new PlainpostAPIError('CLIENT_UPDATE_REQUIRED', 'Update required.'),
      ),
    }));
    await controller.open();
    render(<App controller={controller} />);

    expect(screen.getByRole('alert')).toHaveTextContent(
      'Plainpost and this extension must be updated together',
    );
    expect(screen.queryByRole('button')).toBeNull();
  });
});

describe('reader and summary states', () => {
  it('shows safe plain text with semantic reader actions', async () => {
    const { controller } = await controllerInReaderState();
    render(<App controller={controller} />);

    expect(screen.getByText('Maya Chen')).toBeVisible();
    expect(screen.getByText(/Are we still on for Friday/)).toBeVisible();
    expect(screen.getByRole('button', { name: 'Summarize' })).toBeEnabled();
    expect(screen.getByRole('button', { name: 'Reply' })).toBeEnabled();
    expect(screen.getByRole('button', { name: 'Back to unread mail' })).toBeEnabled();
  });

  it('requests and renders a summary only after the user asks', async () => {
    const { controller, api } = await controllerInReaderState();
    render(<App controller={controller} />);

    expect(api.summarize).not.toHaveBeenCalled();
    await userEvent.click(screen.getByRole('button', { name: 'Summarize' }));

    expect(api.summarize).toHaveBeenCalledWith('m1');
    expect(await screen.findByText('Friday is confirmed.')).toBeVisible();
  });

  it('keeps summary errors local to the summary panel', async () => {
    const { controller } = await controllerInReaderState({
      summarize: vi.fn().mockRejectedValue(new Error('AI is unavailable.')),
    });
    render(<App controller={controller} />);

    await userEvent.click(screen.getByRole('button', { name: 'Summarize' }));

    const panel = screen.getByLabelText('AI summary');
    expect(within(panel).getByRole('status')).toHaveTextContent('AI is unavailable.');
    expect(screen.getByRole('button', { name: 'Reply' })).toBeEnabled();
  });

  it('opens the server-owned reply draft and returns to the reader', async () => {
    const { controller, api } = await controllerInReaderState();
    render(<App controller={controller} />);

    await userEvent.click(screen.getByRole('button', { name: 'Reply' }));
    expect(api.beginReply).toHaveBeenCalledWith('m1');
    expect(await screen.findByRole('textbox', { name: 'Reply' })).toHaveValue('Manual reply');
    await waitFor(() => expect(screen.getByRole('heading', { name: 'Re: Trip schedule' })).toHaveFocus());

    await userEvent.click(screen.getByRole('button', { name: 'Back to message' }));
    expect(await screen.findByRole('heading', { name: 'Trip schedule' })).toBeVisible();
  });
});

describe('reply, AI, and delivery states', () => {
  it('edits and saves the server-owned manual draft', async () => {
    const { controller, api } = await controllerInReplyState();
    render(<App controller={controller} />);
    const reply = screen.getByRole('textbox', { name: 'Reply' });

    await userEvent.clear(reply);
    await userEvent.type(reply, 'See you Friday.');
    await controller.flush();

    expect(api.updateDraft).toHaveBeenLastCalledWith('d1', 'See you Friday.', expect.any(String));
    expect(screen.getByRole('status', { name: 'Draft status' })).toHaveTextContent('Saved in Plainpost');
  });

  it('drafts with AI from the labelled instruction field', async () => {
    const { controller, api } = await controllerInReplyState();
    render(<App controller={controller} />);

    await userEvent.type(
      screen.getByRole('textbox', { name: 'AI instruction' }),
      'Confirm Friday and thank Maya',
    );
    await userEvent.click(screen.getByRole('button', { name: 'Draft with AI' }));

    expect(api.draftReply).toHaveBeenCalledWith(
      'd1',
      'm1',
      'Confirm Friday and thank Maya',
      'hash-1',
    );
    expect(await screen.findByRole('textbox', { name: 'Reply' })).toHaveValue('AI reply');
  });

  it('keeps manual reply usable when AI fails and contains the error in the AI panel', async () => {
    const { controller } = await controllerInReplyState({
      draftReply: vi.fn().mockRejectedValue(new Error('AI is unavailable.')),
    });
    render(<App controller={controller} />);

    await userEvent.click(screen.getByRole('button', { name: 'Draft with AI' }));

    expect(screen.getByRole('textbox', { name: 'Reply' })).toHaveValue('Manual reply');
    expect(screen.getByRole('textbox', { name: 'Reply' })).toBeEnabled();
    expect(screen.getByRole('button', { name: 'Send reply' })).toBeEnabled();
    expect(within(screen.getByLabelText('AI reply assistant')).getByRole('status'))
      .toHaveTextContent('AI is unavailable.');
  });

  it('suppresses a second send while delivery is in flight', async () => {
    let resolveDelivery!: (delivery: DeliveryResult) => void;
    const delivery = new Promise<DeliveryResult>(resolve => { resolveDelivery = resolve; });
    const { controller, api } = await controllerInReplyState({
      sendReply: vi.fn(() => delivery),
    });
    render(<App controller={controller} />);

    await userEvent.click(screen.getByRole('button', { name: 'Send reply' }));
    expect(screen.getByRole('button', { name: 'Sending reply…' })).toBeDisabled();
    expect(screen.getByRole('textbox', { name: 'Reply' })).toBeDisabled();
    expect(api.sendReply).toHaveBeenCalledTimes(1);

    resolveDelivery({ requestID: 's1', jobID: 'j1', state: 'sent' });
    await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent('Reply sent'));
  });

  it('locks a receipt-less send failure without exposing resend or editing', async () => {
    const { controller } = await controllerInReplyState({
      sendReply: vi.fn().mockRejectedValue(new Error('The reply was not sent.')),
    });
    render(<App controller={controller} />);

    await userEvent.click(screen.getByRole('button', { name: 'Send reply' }));

    expect(await screen.findByRole('alert')).toHaveTextContent(
      'Delivery status uncertain — check Sent in Plainpost before taking another action',
    );
    expect(screen.queryByRole('button', { name: 'Send reply' })).toBeNull();
    expect(screen.getByRole('textbox', { name: 'Reply' })).toBeDisabled();
  });

  it('disables resend and manual editing for uncertain delivery', async () => {
    const { controller } = await controllerInReplyState({
      sendReply: vi.fn().mockResolvedValue({
        requestID: 's1',
        jobID: 'j1',
        state: 'deliveryUncertain',
      }),
    });
    render(<App controller={controller} />);

    await userEvent.click(screen.getByRole('button', { name: 'Send reply' }));

    expect(await screen.findByRole('alert')).toHaveTextContent(
      'Delivery status uncertain — check Sent in Plainpost before taking another action',
    );
    expect(screen.queryByRole('button', { name: 'Send reply' })).toBeNull();
    expect(screen.getByRole('textbox', { name: 'Reply' })).toBeDisabled();
  });

  it('renders interrupted send as content-free lockout with no action path', () => {
    const controller = new PopupController(fakeClient());
    controller.state = {
      kind: 'interruptedSend',
      messageID: 'm1',
      draftID: 'd1',
    };

    render(<App controller={controller} />);

    expect(screen.getByRole('alert')).toHaveTextContent(
      'Delivery status uncertain — check Sent in Plainpost before taking another action',
    );
    expect(screen.queryByRole('button')).toBeNull();
    expect(screen.queryByRole('textbox')).toBeNull();
    expect(screen.queryByText('Manual reply')).toBeNull();
  });
});
