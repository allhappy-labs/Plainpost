import { afterEach, describe, expect, it, vi } from 'vitest';

import { PlainpostAPIError } from '../api/client';
import type { DeliveryResult, DraftResult, PlainpostClient } from '../api/contracts';
import { PopupController } from '../state/popup-controller';
import {
  installPopupLifecycle,
  restoreOrOpen,
  type DraftHandoff,
  type PopupRecoveryRecord,
  type PopupRecoveryStore,
} from './popup-lifecycle';

class Deferred<T> {
  readonly promise: Promise<T>;
  resolve!: (value: T) => void;

  constructor() {
    this.promise = new Promise(resolve => { this.resolve = resolve; });
  }
}

function recoveryStore(initial: PopupRecoveryRecord = { status: 'blocked' }):
PopupRecoveryStore & { record: PopupRecoveryRecord } {
  return {
    record: initial,
    read: vi.fn(async function(this: { record: PopupRecoveryRecord }) { return this.record; }),
    markSafe: vi.fn(async function(
      this: { record: PopupRecoveryRecord },
      messageID: string,
      draftID: string,
    ) { this.record = { status: 'safe', messageID, draftID }; }),
    markSending: vi.fn(async function(
      this: { record: PopupRecoveryRecord },
      messageID: string,
      draftID: string,
      _attemptID: string,
    ) {
      this.record = {
        status: 'sending', messageID, draftID,
      };
    }),
    block: vi.fn(async function(this: { record: PopupRecoveryRecord }) {
      this.record = { status: 'blocked' };
    }),
  };
}

function initialDraft(body = 'Original', contentHash = 'hash-1'): DraftResult {
  return {
    id: 'd1',
    subject: 'Re: Trip schedule',
    to: ['maya@example.com'],
    body,
    contentHash,
    aiGenerated: false,
  };
}

function fakeClient(
  server: { draft: DraftResult },
  overrides: Partial<PlainpostClient> = {},
): PlainpostClient {
  return {
    sessionStatus: vi.fn().mockResolvedValue({ ready: true }),
    unreadList: vi.fn().mockResolvedValue({
      messages: [{
        id: 'm1', sender: 'maya@example.com', senderName: 'Maya Chen',
        subject: 'Trip schedule', preview: 'Friday?', sentAt: '2026-07-14T08:00:00Z',
      }],
      lastSuccessfulSyncAt: null,
    }),
    openMessage: vi.fn().mockResolvedValue({
      id: 'm1', sender: 'maya@example.com', senderName: 'Maya Chen',
      subject: 'Trip schedule', bodyPlain: 'Friday?', isSeen: true,
    }),
    incrementalSync: vi.fn().mockResolvedValue({
      completedAccountIDs: [], failedAccountIDs: [], newMessageCount: 0,
    }),
    summarize: vi.fn().mockResolvedValue({ summary: 'Friday.' }),
    beginReply: vi.fn(async () => server.draft),
    readDraft: vi.fn(async () => server.draft),
    updateDraft: vi.fn(async (_draftID, body) => {
      server.draft = { ...server.draft, body, contentHash: `hash-${body}` };
      return server.draft;
    }),
    draftReply: vi.fn(async () => server.draft),
    sendReply: vi.fn().mockResolvedValue({ requestID: 's1', jobID: 'j1', state: 'sent' }),
    ...overrides,
  };
}

async function replyController(api: PlainpostClient): Promise<PopupController> {
  const controller = new PopupController(api, {
    debounceMilliseconds: 60_000,
    uuid: () => 'send-1',
  });
  await controller.open();
  await controller.refreshCompletion;
  await controller.openMessage('m1');
  await controller.beginReply();
  return controller;
}

afterEach(() => {
  vi.clearAllTimers();
  vi.useRealTimers();
});

describe('popup lifecycle', () => {
  it('preserves unknown recovery after a transient read failure and restores on retry', async () => {
    const server = { draft: initialDraft() };
    const api = fakeClient(server);
    const store = recoveryStore({ status: 'safe', messageID: 'm1', draftID: 'd1' });
    vi.mocked(store.read)
      .mockRejectedValueOnce(new Error('Storage temporarily unavailable.'))
      .mockImplementation(async () => store.record);
    const controller = new PopupController(api);
    installPopupLifecycle(controller, store, new EventTarget());

    await restoreOrOpen(controller, store);
    expect(controller.state.kind).toBe('unavailable');
    expect(store.record).toEqual({ status: 'safe', messageID: 'm1', draftID: 'd1' });

    await restoreOrOpen(controller, store);
    expect(controller.state.kind).toBe('reply');
    expect(api.readDraft).toHaveBeenCalledWith('d1');
  });

  it('does not overwrite safe recovery while the popup is still connecting', async () => {
    const server = { draft: initialDraft() };
    const api = fakeClient(server);
    const store = recoveryStore({ status: 'safe', messageID: 'm1', draftID: 'd1' });
    const controller = new PopupController(api);
    installPopupLifecycle(controller, store, new EventTarget());

    await restoreOrOpen(controller, store);

    expect(controller.state.kind).toBe('reply');
    expect(api.readDraft).toHaveBeenCalledWith('d1');
  });

  it('preserves safe recovery when an installed lifecycle enters a retryable outage', async () => {
    const server = { draft: initialDraft() };
    const api = fakeClient(server, {
      readDraft: vi.fn().mockRejectedValue(new PlainpostAPIError('UNAVAILABLE', 'Try again.')),
    });
    const store = recoveryStore({ status: 'safe', messageID: 'm1', draftID: 'd1' });
    const target = new EventTarget();
    const controller = new PopupController(api);
    installPopupLifecycle(controller, store, target);

    await restoreOrOpen(controller, store);
    target.dispatchEvent(new Event('pagehide'));

    expect(controller.state.kind).toBe('unavailable');
    expect(store.record).toEqual({ status: 'safe', messageID: 'm1', draftID: 'd1' });
  });

  it('hands the latest manual body to background synchronously on pagehide and restores it', async () => {
    const server = { draft: initialDraft() };
    const api = fakeClient(server);
    const store = recoveryStore();
    const target = new EventTarget();
    const controller = await replyController(api);
    let handoffCompletion = Promise.resolve();
    const handoff: DraftHandoff = vi.fn(payload => {
      handoffCompletion = api.updateDraft(payload.draftID, payload.body, payload.expectedHash)
        .then(() => undefined);
      return handoffCompletion;
    });
    const dispose = installPopupLifecycle(controller, store, target, { handoffDraft: handoff });

    void controller.updateDraft('Latest manual edit');
    target.dispatchEvent(new Event('pagehide'));
    expect(handoff).toHaveBeenCalledWith({
      messageID: 'm1', draftID: 'd1', body: 'Latest manual edit', expectedHash: 'hash-1',
    });
    await handoffCompletion;
    dispose();

    const reopened = new PopupController(api);
    await restoreOrOpen(reopened, store);
    expect(reopened.state.kind).toBe('reply');
    if (reopened.state.kind !== 'reply') throw new Error('Expected restored reply.');
    expect(reopened.state.draft.body).toBe('Latest manual edit');
  });

  it('contains an asynchronous background handoff failure after teardown dispatch', async () => {
    const server = { draft: initialDraft() };
    const store = recoveryStore();
    const target = new EventTarget();
    const controller = await replyController(fakeClient(server));
    const failed = Promise.reject(new Error('Background stopped.'));
    failed.catch(() => undefined);
    const catchFailure = vi.spyOn(failed, 'catch');
    installPopupLifecycle(controller, store, target, {
      handoffDraft: () => failed,
    });

    void controller.updateDraft('Pending edit');
    target.dispatchEvent(new Event('pagehide'));

    expect(catchFailure).toHaveBeenCalled();
  });

  it('dispatches the same pending edit only once across hidden and pagehide events', async () => {
    const server = { draft: initialDraft() };
    const store = recoveryStore();
    const target = new EventTarget();
    const visibilityTarget = Object.assign(new EventTarget(), {
      visibilityState: 'hidden',
    }) as unknown as Document;
    const controller = await replyController(fakeClient(server));
    const handoff: DraftHandoff = vi.fn();
    installPopupLifecycle(controller, store, target, { visibilityTarget, handoffDraft: handoff });

    void controller.updateDraft('Pending edit');
    visibilityTarget.dispatchEvent(new Event('visibilitychange'));
    target.dispatchEvent(new Event('pagehide'));

    expect(handoff).toHaveBeenCalledTimes(1);
  });

  it('does not overwrite an in-flight AI result when there is no manual edit to hand off', async () => {
    const ai = new Deferred<DraftResult>();
    const server = { draft: initialDraft() };
    const api = fakeClient(server, { draftReply: vi.fn(() => ai.promise) });
    const store = recoveryStore();
    const target = new EventTarget();
    const controller = await replyController(api);
    const handoff: DraftHandoff = vi.fn();
    installPopupLifecycle(controller, store, target, { handoffDraft: handoff });

    void controller.draftWithAI('Confirm Friday');
    await vi.waitFor(() => expect(api.draftReply).toHaveBeenCalled());
    target.dispatchEvent(new Event('pagehide'));

    expect(handoff).not.toHaveBeenCalled();
    ai.resolve({ ...initialDraft('AI body', 'hash-ai'), aiGenerated: true });
  });

  it('hands off an edit during deferred AI and restore waits for background ordering', async () => {
    const ai = new Deferred<DraftResult>();
    const server = { draft: initialDraft() };
    const api = fakeClient(server, { draftReply: vi.fn(() => ai.promise) });
    const store = recoveryStore();
    const target = new EventTarget();
    const controller = await replyController(api);
    let backgroundTail = Promise.resolve();
    const handoff: DraftHandoff = vi.fn(payload => {
      backgroundTail = ai.promise
        .then(result => {
          server.draft = result;
          return api.updateDraft(payload.draftID, payload.body, result.contentHash);
        })
        .then(() => undefined);
      return backgroundTail;
    });
    vi.mocked(store.read).mockImplementation(async () => {
      await backgroundTail;
      return store.record;
    });
    installPopupLifecycle(controller, store, target, { handoffDraft: handoff });

    void controller.draftWithAI('Confirm Friday');
    await vi.waitFor(() => expect(api.draftReply).toHaveBeenCalled());
    void controller.updateDraft('Typed while AI runs');
    target.dispatchEvent(new Event('pagehide'));
    expect(handoff).toHaveBeenCalledWith({
      messageID: 'm1', draftID: 'd1', body: 'Typed while AI runs', expectedHash: 'hash-1',
    });

    const reopened = new PopupController(api);
    const restoring = restoreOrOpen(reopened, store);
    ai.resolve({ ...initialDraft('AI body', 'hash-ai'), aiGenerated: true });
    await restoring;
    expect(reopened.state.kind).toBe('reply');
    if (reopened.state.kind !== 'reply') throw new Error('Expected restored reply.');
    expect(reopened.state.draft.body).toBe('Typed while AI runs');
  });

  it('restores a locked uncertain surface while sending and after delivery becomes uncertain', async () => {
    const delivery = new Deferred<DeliveryResult>();
    const server = { draft: initialDraft() };
    const api = fakeClient(server, { sendReply: vi.fn(() => delivery.promise) });
    const store = recoveryStore();
    const target = new EventTarget();
    const controller = await replyController(api);
    installPopupLifecycle(controller, store, target, { handoffDraft: vi.fn() });
    await vi.waitFor(() => expect(store.record.status).toBe('safe'));

    const sending = controller.sendReply();
    expect(store.markSending).toHaveBeenCalledWith('m1', 'd1', 'send-1');
    expect(store.record).toEqual({ status: 'sending', messageID: 'm1', draftID: 'd1' });
    target.dispatchEvent(new Event('pagehide'));
    expect(store.markSending).toHaveBeenCalledTimes(2);

    const reopenedDuringSend = new PopupController(api);
    await restoreOrOpen(reopenedDuringSend, store);
    expect(reopenedDuringSend.state.kind).toBe('interruptedSend');
    expect(api.readDraft).not.toHaveBeenCalled();
    expect(api.openMessage).toHaveBeenCalledTimes(1);

    delivery.resolve({ requestID: 's1', jobID: 'j1', state: 'deliveryUncertain' });
    await sending;
    expect(store.record).toEqual({ status: 'sending', messageID: 'm1', draftID: 'd1' });
    const reopenedUncertain = new PopupController(api);
    await restoreOrOpen(reopenedUncertain, store);
    expect(reopenedUncertain.state.kind).toBe('interruptedSend');
    expect(api.sendReply).toHaveBeenCalledTimes(1);
  });

  it('keeps interrupted-send recovery content-free without depending on draft fetch', async () => {
    const server = { draft: initialDraft() };
    const api = fakeClient(server);
    const store = recoveryStore({
      status: 'sending', messageID: 'm1', draftID: 'd1',
    });
    const controller = new PopupController(api);

    await restoreOrOpen(controller, store);

    expect(controller.state.kind).toBe('interruptedSend');
    expect(store.record).toEqual({ status: 'sending', messageID: 'm1', draftID: 'd1' });
    expect(api.readDraft).not.toHaveBeenCalled();
    expect(api.sendReply).not.toHaveBeenCalled();
  });

  it('republishes safe recovery only after a server-confirmed failed receipt', async () => {
    const server = { draft: initialDraft() };
    const api = fakeClient(server, {
      sendReply: vi.fn().mockResolvedValue({ requestID: 's1', jobID: 'j1', state: 'failed' }),
    });
    const store = recoveryStore();
    const controller = await replyController(api);
    installPopupLifecycle(controller, store, new EventTarget(), { handoffDraft: vi.fn() });
    vi.mocked(store.markSafe).mockClear();

    await controller.sendReply();

    expect(controller.state.kind).toBe('reply');
    expect(store.markSafe).toHaveBeenCalledWith('m1', 'd1');
    expect(store.record).toEqual({ status: 'safe', messageID: 'm1', draftID: 'd1' });
  });

  it('keeps recovery blocked after an API failure without a delivery receipt', async () => {
    const server = { draft: initialDraft() };
    const api = fakeClient(server, {
      sendReply: vi.fn().mockRejectedValue(
        new PlainpostAPIError('OPERATION_FAILED', 'No delivery receipt.'),
      ),
    });
    const store = recoveryStore();
    const controller = await replyController(api);
    installPopupLifecycle(controller, store, new EventTarget());

    await controller.sendReply();

    expect(controller.state.kind).toBe('reply');
    if (controller.state.kind !== 'reply') throw new Error('Expected reply state.');
    expect(controller.state.deliveryState).toBe('deliveryUncertain');
    expect(store.record).toEqual({ status: 'sending', messageID: 'm1', draftID: 'd1' });
    await controller.retry();
    expect(api.sendReply).toHaveBeenCalledTimes(1);
  });

  it('clears irrecoverably stale identifiers and opens unread mail', async () => {
    const server = { draft: initialDraft() };
    const api = fakeClient(server, {
      readDraft: vi.fn().mockRejectedValue(new PlainpostAPIError('NOT_FOUND', 'Draft not found.')),
    });
    const store = recoveryStore({ status: 'safe', messageID: 'm1', draftID: 'missing' });
    const controller = new PopupController(api);

    await restoreOrOpen(controller, store);

    expect(store.record).toEqual({ status: 'blocked' });
    expect(controller.state.kind).toBe('list');
  });

  it.each(['UNAVAILABLE', 'CLIENT_UPDATE_REQUIRED', 'PERMISSION_DENIED'] as const)(
    'retains safe identifiers for retryable restore error %s',
    async code => {
      const server = { draft: initialDraft() };
      const api = fakeClient(server, {
        readDraft: vi.fn().mockRejectedValue(new PlainpostAPIError(code, 'Try again.')),
      });
      const store = recoveryStore({ status: 'safe', messageID: 'm1', draftID: 'd1' });
      const controller = new PopupController(api);

      await restoreOrOpen(controller, store);

      expect(store.block).not.toHaveBeenCalled();
      expect(store.record).toEqual({ status: 'safe', messageID: 'm1', draftID: 'd1' });
      expect(controller.state.kind).toBe(code === 'CLIENT_UPDATE_REQUIRED' ? 'versionMismatch' : 'unavailable');
    },
  );

  it('opens unread mail when recovery is blocked', async () => {
    const server = { draft: initialDraft() };
    const api = fakeClient(server);
    const store = recoveryStore();
    const controller = new PopupController(api);

    await restoreOrOpen(controller, store);

    expect(controller.state.kind).toBe('list');
  });
});
