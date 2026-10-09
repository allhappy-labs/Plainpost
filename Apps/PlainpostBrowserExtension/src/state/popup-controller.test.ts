import { afterEach, describe, expect, it, vi } from 'vitest';

import type {
  DeliveryResult,
  DraftResult,
  PlainpostClient,
  MessageDetail,
  UnreadMessage,
} from '../api/contracts';
import { PlainpostAPIError } from '../api/client';
import { PopupController, type PopupState } from './popup-controller';

class Deferred<T> {
  readonly promise: Promise<T>;
  resolve!: (value: T) => void;
  reject!: (reason: unknown) => void;

  constructor() {
    this.promise = new Promise<T>((resolve, reject) => {
      this.resolve = resolve;
      this.reject = reject;
    });
  }
}

function unreadMessage(id: string): UnreadMessage {
  return {
    id,
    sender: 'maya@example.com',
    senderName: 'Maya Chen',
    subject: 'Trip schedule',
    preview: 'Are we still on for Friday?',
    sentAt: '2026-07-13T09:00:00Z',
  };
}

function messageDetail(id = 'm1'): MessageDetail {
  return {
    id,
    threadID: 't1',
    sender: 'maya@example.com',
    senderName: 'Maya Chen',
    subject: 'Trip schedule',
    bodyPlain: 'Are we still on for Friday?',
    isSeen: true,
  };
}

function draft(body = '', contentHash = 'hash-1', id = 'd1'): DraftResult {
  return {
    id,
    subject: 'Re: Trip schedule',
    to: ['maya@example.com'],
    body,
    contentHash,
    aiGenerated: false,
  };
}

function fakeClient(overrides: Partial<PlainpostClient> = {}): PlainpostClient {
  return {
    sessionStatus: vi.fn().mockResolvedValue({ ready: true }),
    unreadList: vi.fn().mockResolvedValue({ messages: [], lastSuccessfulSyncAt: null }),
    openMessage: vi.fn().mockResolvedValue(messageDetail()),
    incrementalSync: vi.fn().mockResolvedValue({
      completedAccountIDs: [],
      failedAccountIDs: [],
      newMessageCount: 0,
    }),
    summarize: vi.fn().mockResolvedValue({ summary: 'Summary' }),
    beginReply: vi.fn().mockResolvedValue(draft()),
    readDraft: vi.fn().mockResolvedValue(draft()),
    updateDraft: vi.fn().mockImplementation(
      async (_draftID: string, body: string) => draft(body, `hash-${body}`),
    ),
    draftReply: vi.fn().mockResolvedValue({ ...draft('AI reply', 'hash-ai'), aiGenerated: true }),
    sendReply: vi.fn().mockResolvedValue({ requestID: 'send-1', jobID: 'job-1', state: 'sent' }),
    ...overrides,
  };
}

async function controllerInReader(
  api: PlainpostClient,
  uuid: () => string = () => 'uuid-1',
): Promise<PopupController> {
  vi.mocked(api.unreadList).mockResolvedValue({
    messages: [unreadMessage('m1')],
    lastSuccessfulSyncAt: null,
  });
  const controller = new PopupController(api, { uuid });
  await controller.open();
  await controller.refreshCompletion;
  await controller.openMessage('m1');
  return controller;
}

async function controllerInReply(
  api: PlainpostClient,
  uuid: () => string = () => 'uuid-1',
): Promise<PopupController> {
  const controller = await controllerInReader(api, uuid);
  await controller.beginReply();
  return controller;
}

afterEach(() => {
  vi.useRealTimers();
});

describe('PopupController opening and reading', () => {
  it('renders cache before awaiting incremental sync', async () => {
    const sync = new Deferred<{ completedAccountIDs: string[]; failedAccountIDs: string[]; newMessageCount: number }>();
    const api = fakeClient({
      unreadList: vi.fn()
        .mockResolvedValueOnce({ messages: [unreadMessage('m1')], lastSuccessfulSyncAt: null })
        .mockResolvedValueOnce({
          messages: [unreadMessage('m2')],
          lastSuccessfulSyncAt: '2026-07-13T10:00:00Z',
        }),
      incrementalSync: vi.fn(() => sync.promise),
    });
    const controller = new PopupController(api);

    await controller.open();

    expect(controller.state.kind).toBe('list');
    if (controller.state.kind !== 'list') throw new Error('Expected list state');
    expect(controller.state.messages.map(message => message.id)).toEqual(['m1']);
    expect(controller.state.isRefreshing).toBe(true);

    sync.resolve({ completedAccountIDs: ['a'], failedAccountIDs: [], newMessageCount: 1 });
    await controller.refreshCompletion;
    expect(controller.state.kind).toBe('list');
    if (controller.state.kind !== 'list') throw new Error('Expected list state');
    expect(controller.state.messages.map(message => message.id)).toEqual(['m2']);
    expect(controller.state.isRefreshing).toBe(false);
  });

  it('keeps cached rows when incremental sync fails', async () => {
    const api = fakeClient({
      unreadList: vi.fn().mockResolvedValue({
        messages: [unreadMessage('m1')],
        lastSuccessfulSyncAt: '2026-07-13T08:00:00Z',
      }),
      incrementalSync: vi.fn().mockRejectedValue(new PlainpostAPIError('UNAVAILABLE', 'Sync unavailable.')),
    });
    const controller = new PopupController(api);

    await controller.open();
    await controller.refreshCompletion;

    expect(controller.state.kind).toBe('list');
    if (controller.state.kind !== 'list') throw new Error('Expected list state');
    expect(controller.state.messages.map(message => message.id)).toEqual(['m1']);
    expect(controller.state.isRefreshing).toBe(false);
    expect(controller.state.refreshError).toBe('Sync unavailable.');
  });

  it('removes unread only after mail.open succeeds', async () => {
    const opened = new Deferred<MessageDetail>();
    const api = fakeClient({
      unreadList: vi.fn().mockResolvedValue({
        messages: [unreadMessage('m1'), unreadMessage('m2')],
        lastSuccessfulSyncAt: null,
      }),
      openMessage: vi.fn(() => opened.promise),
    });
    const controller = new PopupController(api);
    await controller.open();
    await controller.refreshCompletion;

    const opening = controller.openMessage('m1');
    expect(controller.state.kind).toBe('list');
    if (controller.state.kind !== 'list') throw new Error('Expected list state');
    expect(controller.state.messages.map(message => message.id)).toEqual(['m1', 'm2']);

    opened.resolve(messageDetail('m1'));
    await opening;
    expect(controller.state.kind).toBe('reader');
    controller.back();
    expect(controller.state.kind).toBe('list');
    if (controller.state.kind !== 'list') throw new Error('Expected list state');
    expect(controller.state.messages.map(message => message.id)).toEqual(['m2']);
  });

  it('does not reintroduce an opened message when an older refresh finishes later', async () => {
    const sync = new Deferred<{ completedAccountIDs: string[]; failedAccountIDs: string[]; newMessageCount: number }>();
    const api = fakeClient({
      unreadList: vi.fn()
        .mockResolvedValueOnce({
          messages: [unreadMessage('m1'), unreadMessage('m2')],
          lastSuccessfulSyncAt: null,
        })
        .mockResolvedValueOnce({
          messages: [unreadMessage('m1'), unreadMessage('m2')],
          lastSuccessfulSyncAt: '2026-07-13T10:00:00Z',
        }),
      incrementalSync: vi.fn(() => sync.promise),
    });
    const controller = new PopupController(api);
    await controller.open();

    await controller.openMessage('m1');
    sync.resolve({ completedAccountIDs: ['a'], failedAccountIDs: [], newMessageCount: 0 });
    await controller.refreshCompletion;
    controller.back();

    expect(controller.state.kind).toBe('list');
    if (controller.state.kind !== 'list') throw new Error('Expected list state');
    expect(controller.state.messages.map(message => message.id)).toEqual(['m2']);
  });

  it('keeps newly refreshed mail when an older open request finishes later', async () => {
    const opened = new Deferred<MessageDetail>();
    const sync = new Deferred<{ completedAccountIDs: string[]; failedAccountIDs: string[]; newMessageCount: number }>();
    const api = fakeClient({
      unreadList: vi.fn()
        .mockResolvedValueOnce({ messages: [unreadMessage('m1')], lastSuccessfulSyncAt: null })
        .mockResolvedValueOnce({
          messages: [unreadMessage('m1'), unreadMessage('m2')],
          lastSuccessfulSyncAt: '2026-07-13T10:00:00Z',
        }),
      incrementalSync: vi.fn(() => sync.promise),
      openMessage: vi.fn(() => opened.promise),
    });
    const controller = new PopupController(api);
    await controller.open();

    const opening = controller.openMessage('m1');
    sync.resolve({ completedAccountIDs: ['a'], failedAccountIDs: [], newMessageCount: 1 });
    await controller.refreshCompletion;
    opened.resolve(messageDetail('m1'));
    await opening;
    controller.back();

    expect(controller.state.kind).toBe('list');
    if (controller.state.kind !== 'list') throw new Error('Expected list state');
    expect(controller.state.messages.map(message => message.id)).toEqual(['m2']);
  });

  it('maps API version failures to the closed version-mismatch state', async () => {
    const api = fakeClient({
      unreadList: vi.fn().mockRejectedValue(
        new PlainpostAPIError('CLIENT_UPDATE_REQUIRED', 'Update required.'),
      ),
    });
    const controller = new PopupController(api);

    await controller.open();

    expect(controller.state).toEqual({ kind: 'versionMismatch', message: 'Update required.' });
  });

  it('uses last-intent-wins when two message opens resolve out of order', async () => {
    const first = new Deferred<MessageDetail>();
    const second = new Deferred<MessageDetail>();
    const api = fakeClient({
      unreadList: vi.fn().mockResolvedValue({
        messages: [unreadMessage('m1'), unreadMessage('m2')],
        lastSuccessfulSyncAt: null,
      }),
      openMessage: vi.fn((messageID: string) => messageID === 'm1' ? first.promise : second.promise),
    });
    const controller = new PopupController(api);
    await controller.open();
    await controller.refreshCompletion;

    const openingFirst = controller.openMessage('m1');
    const openingSecond = controller.openMessage('m2');
    second.resolve(messageDetail('m2'));
    await openingSecond;
    first.resolve(messageDetail('m1'));
    await openingFirst;

    expect(controller.state.kind).toBe('reader');
    if (controller.state.kind !== 'reader') throw new Error('Expected reader state');
    expect(controller.state.message.id).toBe('m2');
    controller.back();
    const listState = controller.state as PopupState;
    expect(listState.kind).toBe('list');
    if (listState.kind !== 'list') throw new Error('Expected list state');
    expect(listState.messages).toEqual([]);
  });

  it('does not let an older message open replace a restored reply', async () => {
    const staleOpen = new Deferred<MessageDetail>();
    const api = fakeClient({
      unreadList: vi.fn().mockResolvedValue({
        messages: [unreadMessage('m1')],
        lastSuccessfulSyncAt: null,
      }),
      openMessage: vi.fn((messageID: string) => (
        messageID === 'm1' ? staleOpen.promise : Promise.resolve(messageDetail('m2'))
      )),
      readDraft: vi.fn().mockResolvedValue(draft('Restored reply', 'hash-d2', 'd2')),
    });
    const controller = new PopupController(api);
    await controller.open();
    await controller.refreshCompletion;

    const opening = controller.openMessage('m1');
    await controller.restoreReply('m2', 'd2');
    staleOpen.resolve(messageDetail('m1'));
    await opening;

    expect(controller.state.kind).toBe('reply');
    if (controller.state.kind !== 'reply') throw new Error('Expected reply state');
    expect(controller.state.message.id).toBe('m2');
    expect(controller.state.draft.id).toBe('d2');
  });

  it('single-flights repeated beginReply calls', async () => {
    const beginning = new Deferred<DraftResult>();
    const api = fakeClient({ beginReply: vi.fn(() => beginning.promise) });
    const controller = await controllerInReader(api);

    const first = controller.beginReply();
    const second = controller.beginReply();
    expect(api.beginReply).toHaveBeenCalledTimes(1);
    beginning.resolve(draft());
    await Promise.all([first, second]);

    expect(controller.state.kind).toBe('reply');
  });

  it('starts a fresh beginReply after an older same-message operation is superseded', async () => {
    const staleBeginning = new Deferred<DraftResult>();
    const renewedBeginning = new Deferred<DraftResult>();
    const api = fakeClient({
      beginReply: vi.fn()
        .mockImplementationOnce(() => staleBeginning.promise)
        .mockImplementationOnce(() => renewedBeginning.promise),
      readDraft: vi.fn().mockResolvedValue(draft('Restored', 'hash-restored', 'restored')),
    });
    const controller = await controllerInReader(api);

    const stale = controller.beginReply();
    await controller.restoreReply('m1', 'restored');
    controller.back();
    await vi.waitFor(() => expect(controller.state.kind).toBe('reader'));

    const renewed = controller.beginReply();
    expect(api.beginReply).toHaveBeenCalledTimes(2);
    renewedBeginning.resolve(draft('Renewed', 'hash-renewed', 'renewed'));
    await renewed;
    staleBeginning.resolve(draft('Stale', 'hash-stale', 'stale'));
    await stale;

    expect(controller.state.kind).toBe('reply');
    if (controller.state.kind !== 'reply') throw new Error('Expected reply state');
    expect(controller.state.draft.id).toBe('renewed');
  });
});

describe('PopupController drafts', () => {
  it('flushes a pending edit on explicit popup lifecycle handoff', async () => {
    vi.useFakeTimers();
    const api = fakeClient();
    const controller = await controllerInReply(api);

    const saving = controller.updateDraft('Closing edit');
    await controller.flush();
    await saving;

    expect(api.updateDraft).toHaveBeenCalledWith('d1', 'Closing edit', 'hash-1');
  });

  it('keeps the reply visible until Back finishes saving, then navigates', async () => {
    const saved = new Deferred<DraftResult>();
    const api = fakeClient({ updateDraft: vi.fn(() => saved.promise) });
    const controller = await controllerInReply(api);

    const saving = controller.updateDraft('Closing edit');
    controller.back();
    await vi.waitFor(() => expect(api.updateDraft).toHaveBeenCalledTimes(1));
    expect(controller.state.kind).toBe('reply');

    saved.resolve(draft('Closing edit', 'hash-saved'));
    await saving;
    await vi.waitFor(() => expect(controller.state.kind).toBe('reader'));
  });

  it('keeps the reply and editable failure state when Back cannot save', async () => {
    const failed = new Deferred<DraftResult>();
    const api = fakeClient({ updateDraft: vi.fn(() => failed.promise) });
    const controller = await controllerInReply(api);

    const saving = controller.updateDraft('Unsaved closing edit');
    const rejection = expect(saving).rejects.toMatchObject({ code: 'CONFLICT' });
    controller.back();
    await vi.waitFor(() => expect(api.updateDraft).toHaveBeenCalledTimes(1));
    failed.reject(new PlainpostAPIError('CONFLICT', 'The draft changed in Plainpost.'));
    await rejection;

    expect(controller.state.kind).toBe('reply');
    if (controller.state.kind !== 'reply') throw new Error('Expected reply state');
    expect(controller.state.draft.body).toBe('Unsaved closing edit');
    expect(controller.state.saveError).toBe('The draft changed in Plainpost.');
  });

  it('restores a server-owned draft from non-sensitive identifiers', async () => {
    const api = fakeClient({
      unreadList: vi.fn().mockResolvedValue({
        messages: [unreadMessage('m1')],
        lastSuccessfulSyncAt: null,
      }),
      readDraft: vi.fn().mockResolvedValue(draft('Persisted reply', 'hash-persisted')),
    });
    const controller = new PopupController(api);
    await controller.open();
    await controller.refreshCompletion;

    await controller.restoreReply('m1', 'd1');

    expect(api.openMessage).toHaveBeenCalledWith('m1');
    expect(api.readDraft).toHaveBeenCalledWith('d1');
    expect(controller.state.kind).toBe('reply');
    if (controller.state.kind !== 'reply') throw new Error('Expected reply state');
    expect(controller.state.draft.body).toBe('Persisted reply');
  });

  it('ignores a late failure from a superseded draft restoration', async () => {
    const staleMessage = new Deferred<MessageDetail>();
    const api = fakeClient({
      openMessage: vi.fn((messageID: string) => (
        messageID === 'm1' ? staleMessage.promise : Promise.resolve(messageDetail('m2'))
      )),
      readDraft: vi.fn((draftID: string) => Promise.resolve(
        draft(draftID === 'd1' ? 'Old draft' : 'Current draft', `hash-${draftID}`, draftID),
      )),
    });
    const controller = new PopupController(api);

    const staleRestore = controller.restoreReply('m1', 'd1');
    await controller.restoreReply('m2', 'd2');
    staleMessage.reject(new PlainpostAPIError('UNAVAILABLE', 'Old restore unavailable.'));
    await staleRestore;

    expect(controller.state.kind).toBe('reply');
    if (controller.state.kind !== 'reply') throw new Error('Expected reply state');
    expect(controller.state.message.id).toBe('m2');
    expect(controller.state.draft.id).toBe('d2');
  });

  it('debounces edits for 250 ms and persists only the latest body', async () => {
    vi.useFakeTimers();
    const api = fakeClient();
    const controller = await controllerInReply(api);

    const first = controller.updateDraft('First');
    const latest = controller.updateDraft('Latest');
    await vi.advanceTimersByTimeAsync(249);
    expect(api.updateDraft).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    await Promise.all([first, latest]);

    expect(api.updateDraft).toHaveBeenCalledTimes(1);
    expect(api.updateDraft).toHaveBeenCalledWith('d1', 'Latest', 'hash-1');
  });

  it('serializes saves and uses the returned hash for the next edit', async () => {
    vi.useFakeTimers();
    const firstSave = new Deferred<DraftResult>();
    const api = fakeClient({
      updateDraft: vi.fn()
        .mockImplementationOnce(() => firstSave.promise)
        .mockResolvedValueOnce(draft('Second', 'hash-3')),
    });
    const controller = await controllerInReply(api);

    const first = controller.updateDraft('First');
    await vi.advanceTimersByTimeAsync(250);
    const second = controller.updateDraft('Second');
    await vi.advanceTimersByTimeAsync(250);
    expect(api.updateDraft).toHaveBeenCalledTimes(1);

    firstSave.resolve(draft('First', 'hash-2'));
    await Promise.all([first, second]);

    expect(api.updateDraft).toHaveBeenNthCalledWith(2, 'd1', 'Second', 'hash-2');
  });

  it('flushes the latest edit before invoking AI with its new hash', async () => {
    vi.useFakeTimers();
    const calls: string[] = [];
    const api = fakeClient({
      updateDraft: vi.fn().mockImplementation(async (_id, body) => {
        calls.push(`save:${body}`);
        return draft(body, 'hash-saved');
      }),
      draftReply: vi.fn().mockImplementation(async (_draftID, _messageID, instruction, hash) => {
        calls.push(`ai:${instruction}:${hash}`);
        return { ...draft('AI reply', 'hash-ai'), aiGenerated: true };
      }),
    });
    const controller = await controllerInReply(api);

    void controller.updateDraft('Manual edit');
    await controller.draftWithAI('Confirm Friday');

    expect(calls).toEqual(['save:Manual edit', 'ai:Confirm Friday:hash-saved']);
    expect(controller.state.kind).toBe('reply');
    if (controller.state.kind !== 'reply') throw new Error('Expected reply state');
    expect(controller.state.draft.body).toBe('AI reply');
  });

  it('keeps a failed manual save editable and reports the safe error', async () => {
    vi.useFakeTimers();
    const api = fakeClient({
      updateDraft: vi.fn().mockRejectedValue(
        new PlainpostAPIError('CONFLICT', 'The draft changed in Plainpost.'),
      ),
    });
    const controller = await controllerInReply(api);

    const saving = controller.updateDraft('Manual edit');
    const rejection = expect(saving).rejects.toMatchObject({ code: 'CONFLICT' });
    await vi.advanceTimersByTimeAsync(250);
    await rejection;

    expect(controller.state.kind).toBe('reply');
    if (controller.state.kind !== 'reply') throw new Error('Expected reply state');
    expect(controller.state.draft.body).toBe('Manual edit');
    expect(controller.state.isSaving).toBe(false);
    expect(controller.state.saveError).toBe('The draft changed in Plainpost.');
  });

  it('preserves an edit made while AI is running and saves it against the AI draft hash', async () => {
    vi.useFakeTimers();
    const generated = new Deferred<DraftResult>();
    const api = fakeClient({ draftReply: vi.fn(() => generated.promise) });
    const controller = await controllerInReply(api);

    const ai = controller.draftWithAI('Confirm Friday');
    await vi.waitFor(() => expect(api.draftReply).toHaveBeenCalledTimes(1));
    const saving = controller.updateDraft('Manual while AI runs');
    await vi.advanceTimersByTimeAsync(250);
    expect(api.updateDraft).not.toHaveBeenCalled();

    generated.resolve({ ...draft('AI reply', 'hash-ai'), aiGenerated: true });
    await Promise.all([ai, saving]);

    expect(api.updateDraft).toHaveBeenCalledWith('d1', 'Manual while AI runs', 'hash-ai');
    expect(controller.state.kind).toBe('reply');
    if (controller.state.kind !== 'reply') throw new Error('Expected reply state');
    expect(controller.state.draft.body).toBe('Manual while AI runs');
  });

  it('resumes saving a manual edit after AI fails', async () => {
    vi.useFakeTimers();
    const generated = new Deferred<DraftResult>();
    const api = fakeClient({ draftReply: vi.fn(() => generated.promise) });
    const controller = await controllerInReply(api);

    const ai = controller.draftWithAI('Confirm Friday');
    await vi.waitFor(() => expect(api.draftReply).toHaveBeenCalledTimes(1));
    const saving = controller.updateDraft('Manual survives');
    await vi.advanceTimersByTimeAsync(250);
    generated.reject(new PlainpostAPIError('UNAVAILABLE', 'AI unavailable.'));
    await ai;

    expect(api.updateDraft).toHaveBeenCalledWith('d1', 'Manual survives', 'hash-1');
    await saving;
    expect(controller.state.kind).toBe('reply');
    if (controller.state.kind !== 'reply') throw new Error('Expected reply state');
    expect(controller.state.draft.body).toBe('Manual survives');
    expect(controller.state.aiError).toBe('AI unavailable.');
  });

  it('waits for active AI and drains the latest edit before lifecycle flush resolves', async () => {
    vi.useFakeTimers();
    const generated = new Deferred<DraftResult>();
    const api = fakeClient({ draftReply: vi.fn(() => generated.promise) });
    const controller = await controllerInReply(api);

    const ai = controller.draftWithAI('Confirm Friday');
    await vi.waitFor(() => expect(api.draftReply).toHaveBeenCalledTimes(1));
    const saving = controller.updateDraft('Last popup edit');
    await vi.advanceTimersByTimeAsync(250);
    let flushed = false;
    const flush = controller.flush().then(() => { flushed = true; });
    await vi.advanceTimersByTimeAsync(0);
    await Promise.resolve();
    expect(flushed).toBe(false);

    generated.resolve({ ...draft('AI reply', 'hash-ai'), aiGenerated: true });
    await Promise.all([ai, flush, saving]);
    expect(api.updateDraft).toHaveBeenCalledWith('d1', 'Last popup edit', 'hash-ai');
    expect(flushed).toBe(true);
  });

  it('blocks Back during active AI so an edit made during generation is persisted', async () => {
    vi.useFakeTimers();
    const generated = new Deferred<DraftResult>();
    const api = fakeClient({ draftReply: vi.fn(() => generated.promise) });
    const controller = await controllerInReply(api);

    const ai = controller.draftWithAI('Confirm Friday');
    await vi.waitFor(() => expect(api.draftReply).toHaveBeenCalledTimes(1));
    const saving = controller.updateDraft('Manual while AI runs');
    await vi.advanceTimersByTimeAsync(250);

    controller.back();
    expect(controller.state.kind).toBe('reply');

    generated.resolve({ ...draft('AI reply', 'hash-ai'), aiGenerated: true });
    await Promise.all([ai, saving]);
    expect(api.updateDraft).toHaveBeenCalledWith('d1', 'Manual while AI runs', 'hash-ai');

    controller.back();
    await vi.waitFor(() => expect(controller.state.kind).toBe('reader'));
  });

  it('isolates a new draft from an older deferred save completion', async () => {
    vi.useFakeTimers();
    const oldSave = new Deferred<DraftResult>();
    const api = fakeClient({
      beginReply: vi.fn().mockResolvedValue(draft('', 'hash-d1', 'd1')),
      openMessage: vi.fn((messageID: string) => Promise.resolve(messageDetail(messageID))),
      readDraft: vi.fn().mockResolvedValue(draft('D2 body', 'hash-d2', 'd2')),
      updateDraft: vi.fn()
        .mockImplementationOnce(() => oldSave.promise)
        .mockImplementationOnce(async (draftID: string, body: string) => (
          draft(body, 'hash-d2-saved', draftID)
        )),
    });
    const controller = await controllerInReply(api);

    const staleSaving = controller.updateDraft('D1 edit');
    void staleSaving.catch(() => undefined);
    await vi.advanceTimersByTimeAsync(250);
    await controller.restoreReply('m2', 'd2');
    const currentSaving = controller.updateDraft('D2 edit');
    await vi.advanceTimersByTimeAsync(250);

    oldSave.resolve(draft('D1 edit', 'hash-d1-saved', 'd1'));
    await currentSaving;
    expect(api.updateDraft).toHaveBeenNthCalledWith(2, 'd2', 'D2 edit', 'hash-d2');

    await controller.sendReply();
    expect(api.sendReply).toHaveBeenCalledWith('d2', 'hash-d2-saved', 'uuid-1');
  });

  it('isolates a new draft from an older deferred AI completion', async () => {
    vi.useFakeTimers();
    const oldAI = new Deferred<DraftResult>();
    const api = fakeClient({
      beginReply: vi.fn().mockResolvedValue(draft('', 'hash-d1', 'd1')),
      openMessage: vi.fn((messageID: string) => Promise.resolve(messageDetail(messageID))),
      readDraft: vi.fn().mockResolvedValue(draft('D2 body', 'hash-d2', 'd2')),
      draftReply: vi.fn(() => oldAI.promise),
      updateDraft: vi.fn().mockImplementation(async (draftID: string, body: string) => (
        draft(body, 'hash-d2-saved', draftID)
      )),
    });
    const controller = await controllerInReply(api);

    const generating = controller.draftWithAI('Old draft AI');
    await vi.waitFor(() => expect(api.draftReply).toHaveBeenCalledTimes(1));
    await controller.restoreReply('m2', 'd2');
    oldAI.resolve({ ...draft('Old AI body', 'hash-d1-ai', 'd1'), aiGenerated: true });
    await generating;

    expect(controller.state.kind).toBe('reply');
    if (controller.state.kind !== 'reply') throw new Error('Expected reply state');
    expect(controller.state.draft.id).toBe('d2');
    expect(controller.state.draft.body).toBe('D2 body');
    const saving = controller.updateDraft('D2 edit');
    await vi.advanceTimersByTimeAsync(250);
    await saving;
    expect(api.updateDraft).toHaveBeenCalledWith('d2', 'D2 edit', 'hash-d2');
    await controller.sendReply();
    expect(api.sendReply).toHaveBeenCalledWith('d2', 'hash-d2-saved', 'uuid-1');
  });
});

describe('PopupController delivery', () => {
  it('flushes the latest edit before sending', async () => {
    vi.useFakeTimers();
    const calls: string[] = [];
    const api = fakeClient({
      updateDraft: vi.fn().mockImplementation(async (_id, body) => {
        calls.push(`save:${body}`);
        return draft(body, 'hash-saved');
      }),
      sendReply: vi.fn().mockImplementation(async (_draftID, hash, key) => {
        calls.push(`send:${hash}:${key}`);
        return { requestID: 'send-1', jobID: 'job-1', state: 'sent' };
      }),
    });
    const controller = await controllerInReply(api);

    void controller.updateDraft('Latest');
    await controller.sendReply();

    expect(calls).toEqual(['save:Latest', 'send:hash-saved:uuid-1']);
    expect(controller.state.kind).toBe('sent');
  });

  it('locks an unavailable transport outcome without retrying', async () => {
    const api = fakeClient({
      sendReply: vi.fn()
        .mockRejectedValueOnce(new PlainpostAPIError('UNAVAILABLE', 'Connection lost.'))
        .mockResolvedValueOnce({ requestID: 'send-1', jobID: 'job-1', state: 'sent' }),
    });
    const controller = await controllerInReply(api);

    await controller.sendReply();
    expect(controller.state.kind).toBe('reply');
    if (controller.state.kind !== 'reply') throw new Error('Expected reply state');
    expect(controller.state.deliveryState).toBe('deliveryUncertain');
    await controller.retry();

    expect(api.sendReply).toHaveBeenCalledTimes(1);
    expect(vi.mocked(api.sendReply).mock.calls.map(call => call[2])).toEqual(['uuid-1']);
    expect(controller.state.kind).toBe('reply');
  });

  it('locks a receipt-less transport outcome without retrying', async () => {
    const api = fakeClient({
      sendReply: vi.fn()
        .mockRejectedValueOnce(new Error('transport ended without a receipt'))
        .mockResolvedValueOnce({ requestID: 'send-1', jobID: 'job-1', state: 'sent' }),
    });
    const uuid = vi.fn()
      .mockReturnValueOnce('uuid-1')
      .mockReturnValueOnce('uuid-2');
    const controller = await controllerInReply(api, uuid);

    await controller.sendReply();
    await controller.retry();

    expect(vi.mocked(api.sendReply).mock.calls.map(call => call[2])).toEqual(['uuid-1']);
    expect(controller.state.kind).toBe('reply');
    if (controller.state.kind !== 'reply') throw new Error('Expected reply state');
    expect(controller.state.deliveryState).toBe('deliveryUncertain');
  });

  it('mints a new idempotency key for explicit retry after terminal failed receipt', async () => {
    const results: DeliveryResult[] = [
      { requestID: 'send-1', jobID: 'job-1', state: 'failed' },
      { requestID: 'send-2', jobID: 'job-2', state: 'sent' },
    ];
    const api = fakeClient({ sendReply: vi.fn().mockImplementation(async () => results.shift()!) });
    const uuid = vi.fn()
      .mockReturnValueOnce('uuid-1')
      .mockReturnValueOnce('uuid-2');
    const controller = await controllerInReply(api, uuid);

    await controller.sendReply();
    expect(controller.state.kind).toBe('reply');
    if (controller.state.kind !== 'reply') throw new Error('Expected reply state');
    expect(controller.state.deliveryState).toBe('failed');
    await controller.retry();

    expect(vi.mocked(api.sendReply).mock.calls.map(call => call[2])).toEqual(['uuid-1', 'uuid-2']);
    expect(controller.state.kind).toBe('sent');
  });

  it('does not send a stale draft when the pre-send flush fails', async () => {
    const api = fakeClient({
      updateDraft: vi.fn()
        .mockRejectedValueOnce(new PlainpostAPIError('UNAVAILABLE', 'Save unavailable.'))
        .mockResolvedValueOnce(draft('Latest', 'hash-latest')),
    });
    const controller = await controllerInReply(api);

    const saving = controller.updateDraft('Latest');
    void saving.catch(() => undefined);
    await controller.sendReply();
    expect(api.sendReply).not.toHaveBeenCalled();
    expect(controller.state.kind).toBe('reply');
    if (controller.state.kind !== 'reply') throw new Error('Expected reply state');
    expect(controller.state.deliveryState).toBe('failed');

    await controller.retry();

    expect(api.updateDraft).toHaveBeenCalledTimes(2);
    expect(api.sendReply).toHaveBeenCalledWith('d1', 'hash-latest', 'uuid-1');
    expect(controller.state.kind).toBe('sent');
  });

  it('suppresses concurrent double-click sends', async () => {
    const delivery = new Deferred<DeliveryResult>();
    const api = fakeClient({ sendReply: vi.fn(() => delivery.promise) });
    const controller = await controllerInReply(api);

    const first = controller.sendReply();
    const second = controller.sendReply();
    await vi.waitFor(() => expect(api.sendReply).toHaveBeenCalledTimes(1));

    delivery.resolve({ requestID: 'send-1', jobID: 'job-1', state: 'sent' });
    await Promise.all([first, second]);
  });

  it('blocks navigation while sending and preserves a late uncertain result fail-closed', async () => {
    const delivery = new Deferred<DeliveryResult>();
    const api = fakeClient({ sendReply: vi.fn(() => delivery.promise) });
    const controller = await controllerInReply(api);

    const sending = controller.sendReply();
    await vi.waitFor(() => expect(api.sendReply).toHaveBeenCalledTimes(1));
    controller.back();
    expect(controller.state.kind).toBe('reply');
    if (controller.state.kind !== 'reply') throw new Error('Expected reply state');
    expect(controller.state.deliveryState).toBe('sending');
    await controller.restoreReply('m2', 'd2');
    expect(api.openMessage).not.toHaveBeenCalledWith('m2');
    expect(api.readDraft).not.toHaveBeenCalled();

    delivery.resolve({ requestID: 'send-1', jobID: 'job-1', state: 'deliveryUncertain' });
    await sending;
    expect(controller.state.kind).toBe('reply');
    if (controller.state.kind !== 'reply') throw new Error('Expected reply state');
    expect(controller.state.deliveryState).toBe('deliveryUncertain');
    controller.back();
    await controller.sendReply();
    expect(api.sendReply).toHaveBeenCalledTimes(1);
  });

  it('ignores an old send receipt after the reply state is replaced', async () => {
    const delivery = new Deferred<DeliveryResult>();
    const api = fakeClient({ sendReply: vi.fn(() => delivery.promise) });
    const controller = await controllerInReply(api);
    const sending = controller.sendReply();
    await vi.waitFor(() => expect(api.sendReply).toHaveBeenCalledTimes(1));
    if (controller.state.kind !== 'reply') throw new Error('Expected reply state');

    controller.state = {
      ...controller.state,
      draft: draft('New reply', 'hash-d2', 'd2'),
      deliveryState: 'idle',
    };
    delivery.resolve({ requestID: 'send-1', jobID: 'job-1', state: 'deliveryUncertain' });
    await sending;

    expect(controller.state.kind).toBe('reply');
    if (controller.state.kind !== 'reply') throw new Error('Expected reply state');
    expect(controller.state.draft.id).toBe('d2');
    expect(controller.state.deliveryState).toBe('idle');
    expect(api.sendReply).toHaveBeenCalledTimes(1);
  });

  it('never resends after delivery becomes uncertain', async () => {
    const api = fakeClient({
      sendReply: vi.fn().mockResolvedValue({
        requestID: 'send-1',
        jobID: 'job-1',
        state: 'deliveryUncertain',
      }),
    });
    const controller = await controllerInReply(api);

    await controller.sendReply();
    expect(controller.state.kind).toBe('reply');
    if (controller.state.kind !== 'reply') throw new Error('Expected reply state');
    expect(controller.state.deliveryState).toBe('deliveryUncertain');
    controller.back();
    expect(controller.state.kind).toBe('reply');
    await controller.sendReply();
    await controller.retry();

    expect(api.sendReply).toHaveBeenCalledTimes(1);
  });
});
