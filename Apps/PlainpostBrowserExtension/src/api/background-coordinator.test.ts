import { describe, expect, it, vi } from 'vitest';

import {
  createBackgroundMessageHandler,
  POPUP_RECOVERY_STORAGE_KEY,
  type BackgroundStorageArea,
} from './background-coordinator';
import type { NativePort } from './client';
import type { LocalAPIRequest, LocalAPIResponse } from './contracts';

class Deferred<T> {
  readonly promise: Promise<T>;
  resolve!: (value: T) => void;

  constructor() {
    this.promise = new Promise(resolve => { this.resolve = resolve; });
  }
}

class FakeEvent<T extends (...args: never[]) => void> {
  private readonly listeners = new Set<T>();
  addListener(listener: T): void { this.listeners.add(listener); }
  removeListener(listener: T): void { this.listeners.delete(listener); }
  emit(...args: Parameters<T>): void {
    for (const listener of this.listeners) listener(...args);
  }
}

class FakeNativePort implements NativePort {
  readonly sent: LocalAPIRequest[] = [];
  readonly onMessage = new FakeEvent<(response: LocalAPIResponse) => void>();
  readonly onDisconnect = new FakeEvent<() => void>();

  postMessage(request: LocalAPIRequest): void { this.sent.push(request); }
  succeed(index: number, result: unknown): void {
    this.onMessage.emit({ apiVersion: 1, requestID: this.sent[index]!.requestID, ok: true, result });
  }
  fail(index: number, code: 'CONFLICT' | 'UNAVAILABLE'): void {
    this.onMessage.emit({
      apiVersion: 1,
      requestID: this.sent[index]!.requestID,
      ok: false,
      error: { code, message: 'Conflict.' },
    });
  }
}

function memoryStorage(): BackgroundStorageArea & { values: Record<string, unknown> } {
  const values: Record<string, unknown> = {};
  return {
    values,
    get: vi.fn(async () => ({ ...values })),
    set: vi.fn(async entries => { Object.assign(values, entries); }),
    remove: vi.fn(async keys => {
      for (const key of typeof keys === 'string' ? [keys] : keys) delete values[key];
    }),
  };
}

describe('background popup coordinator', () => {
  it('holds a teardown body in background memory and updates with the AI result hash', async () => {
    const native = new FakeNativePort();
    const handle = createBackgroundMessageHandler(() => native, memoryStorage());

    const ai = handle({
      type: 'plainpost.request',
      method: 'ai.draftReply',
      parameters: {
        draftID: 'd1',
        messageID: 'm1',
        instruction: 'Confirm Friday',
        expectedHash: 'hash-1',
      },
    });
    expect(native.sent).toHaveLength(1);

    const handoff = handle({
      type: 'plainpost.draft.handoff',
      messageID: 'm1',
      draftID: 'd1',
      body: 'Latest manual edit',
      expectedHash: 'hash-1',
    });
    expect(handoff).toBeInstanceOf(Promise);
    expect(native.sent).toHaveLength(1);

    native.succeed(0, {
      id: 'd1', subject: 'Re: Trip', to: ['maya@example.com'], body: 'AI body',
      contentHash: 'hash-ai', aiGenerated: true,
    });
    await vi.waitFor(() => expect(native.sent).toHaveLength(2));
    expect(native.sent[1]).toMatchObject({
      method: 'draft.update',
      parameters: {
        draftID: 'd1',
        body: 'Latest manual edit',
        expectedHash: 'hash-ai',
      },
    });
    native.succeed(1, {
      id: 'd1', subject: 'Re: Trip', to: ['maya@example.com'], body: 'Latest manual edit',
      contentHash: 'hash-latest', aiGenerated: false,
    });

    await expect(ai).resolves.toMatchObject({ ok: true });
    await expect(handoff).resolves.toMatchObject({ ok: true });
  });

  it('does not poison later handoffs when an earlier draft operation fails', async () => {
    const native = new FakeNativePort();
    const handle = createBackgroundMessageHandler(() => native, memoryStorage());

    const first = handle({
      type: 'plainpost.draft.handoff', messageID: 'm1',
      draftID: 'd1', body: 'First', expectedHash: 'hash-1',
    });
    await vi.waitFor(() => expect(native.sent).toHaveLength(1));
    native.fail(0, 'UNAVAILABLE');
    await expect(first).resolves.toMatchObject({ ok: false, error: { code: 'UNAVAILABLE' } });

    const second = handle({
      type: 'plainpost.draft.handoff', messageID: 'm1',
      draftID: 'd1', body: 'Second', expectedHash: 'hash-2',
    });
    await vi.waitFor(() => expect(native.sent).toHaveLength(2));
    expect(native.sent[1]).toMatchObject({
      method: 'draft.update',
      parameters: { body: 'Second', expectedHash: 'hash-2' },
    });
    native.succeed(1, {
      id: 'd1', subject: 'Re: Trip', to: [], body: 'Second',
      contentHash: 'hash-3', aiGenerated: false,
    });
    await expect(second).resolves.toMatchObject({ ok: true });
  });

  it('serializes a blocked recovery marker after a delayed safe write', async () => {
    const native = new FakeNativePort();
    const storage = memoryStorage();
    const firstWrite = new Deferred<void>();
    vi.mocked(storage.set)
      .mockImplementationOnce(async entries => {
        await firstWrite.promise;
        Object.assign(storage.values, entries);
      })
      .mockImplementation(async entries => { Object.assign(storage.values, entries); });
    const handle = createBackgroundMessageHandler(() => native, storage);

    const safe = handle({
      type: 'plainpost.recovery.safe', messageID: 'm1', draftID: 'd1',
    });
    const blocked = handle({ type: 'plainpost.recovery.block' });
    const read = handle({ type: 'plainpost.recovery.read' });
    await vi.waitFor(() => expect(storage.set).toHaveBeenCalledTimes(1));

    firstWrite.resolve();
    await expect(safe).resolves.toMatchObject({ ok: true });
    await expect(blocked).resolves.toMatchObject({ ok: true });
    await expect(read).resolves.toEqual({
      ok: true,
      result: { status: 'blocked' },
    });
    expect(storage.values[POPUP_RECOVERY_STORAGE_KEY]).toEqual({ status: 'blocked' });
  });

  it('republishes recovery after a failed receipt arrives post-teardown', async () => {
    const native = new FakeNativePort();
    const storage = memoryStorage();
    const handle = createBackgroundMessageHandler(() => native, storage);
    await handle({ type: 'plainpost.recovery.safe', messageID: 'm1', draftID: 'd1' });
    await handle({
      type: 'plainpost.recovery.sending', messageID: 'm1', draftID: 'd1', attemptID: 'send-1',
    });
    const send = handle({
      type: 'plainpost.request', method: 'reply.send',
      parameters: { draftID: 'd1', expectedHash: 'hash-1', idempotencyKey: 'send-1' },
    });
    await vi.waitFor(() => expect(native.sent).toHaveLength(1));
    expect(storage.values[POPUP_RECOVERY_STORAGE_KEY]).toEqual({
      status: 'sending', messageID: 'm1', draftID: 'd1',
    });
    native.succeed(0, { requestID: 's1', jobID: 'j1', state: 'failed' });
    await expect(send).resolves.toMatchObject({ ok: true, result: { state: 'failed' } });
    await expect(handle({ type: 'plainpost.recovery.read' })).resolves.toEqual({
      ok: true,
      result: { status: 'safe', messageID: 'm1', draftID: 'd1' },
    });
    expect(native.sent).toHaveLength(1);
  });

  it('persists only safe identifiers before dispatch and restores them after a worker restart', async () => {
    const storage = memoryStorage();
    const firstNative = new FakeNativePort();
    const first = createBackgroundMessageHandler(() => firstNative, storage);
    await first({ type: 'plainpost.recovery.safe', messageID: 'm1', draftID: 'd1' });

    await expect(first({
      type: 'plainpost.recovery.sending', messageID: 'm1', draftID: 'd1', attemptID: 'send-1',
    })).resolves.toMatchObject({ ok: true });
    const send = first({
      type: 'plainpost.request', method: 'reply.send',
      parameters: { draftID: 'd1', expectedHash: 'hash-1', idempotencyKey: 'send-1' },
    });
    await vi.waitFor(() => expect(firstNative.sent).toHaveLength(1));

    expect(storage.values[POPUP_RECOVERY_STORAGE_KEY]).toEqual({
      status: 'sending', messageID: 'm1', draftID: 'd1',
    });
    expect(JSON.stringify(storage.values)).not.toMatch(/body|hash|idempotency|recipient|subject/i);

    const restartedNative = new FakeNativePort();
    const restarted = createBackgroundMessageHandler(() => restartedNative, storage);
    await expect(restarted({ type: 'plainpost.recovery.read' })).resolves.toEqual({
      ok: true,
      result: { status: 'sending', messageID: 'm1', draftID: 'd1' },
    });
    expect(restartedNative.sent).toHaveLength(0);
    firstNative.succeed(0, { requestID: 's1', jobID: 'j1', state: 'deliveryUncertain' });
    await expect(send).resolves.toMatchObject({ ok: true });
  });

  it('rejects send in a fresh worker even when an earlier unresolved record exists', async () => {
    const storage = memoryStorage();
    const firstNative = new FakeNativePort();
    const first = createBackgroundMessageHandler(() => firstNative, storage);
    await first({ type: 'plainpost.recovery.safe', messageID: 'm1', draftID: 'd1' });
    await first({
      type: 'plainpost.recovery.sending', messageID: 'm1', draftID: 'd1', attemptID: 'send-1',
    });
    const firstSend = first({
      type: 'plainpost.request', method: 'reply.send',
      parameters: { draftID: 'd1', expectedHash: 'hash-1', idempotencyKey: 'send-1' },
    });
    await vi.waitFor(() => expect(firstNative.sent).toHaveLength(1));

    const restartedNative = new FakeNativePort();
    const restarted = createBackgroundMessageHandler(() => restartedNative, storage);
    await expect(restarted({
      type: 'plainpost.request', method: 'reply.send',
      parameters: { draftID: 'd1', expectedHash: 'hash-1', idempotencyKey: 'send-1' },
    })).resolves.toMatchObject({ ok: false, error: { code: 'UNAVAILABLE' } });
    expect(restartedNative.sent).toHaveLength(0);
    firstNative.succeed(0, { requestID: 's1', jobID: 'j1', state: 'deliveryUncertain' });
    await expect(firstSend).resolves.toMatchObject({ ok: true });
  });

  it('does not dispatch send until unresolved recovery persistence succeeds', async () => {
    const native = new FakeNativePort();
    const storage = memoryStorage();
    const handle = createBackgroundMessageHandler(() => native, storage);
    await handle({ type: 'plainpost.recovery.safe', messageID: 'm1', draftID: 'd1' });
    const write = new Deferred<void>();
    vi.mocked(storage.set).mockImplementationOnce(async entries => {
      await write.promise;
      Object.assign(storage.values, entries);
    });

    const sending = handle({
      type: 'plainpost.recovery.sending', messageID: 'm1', draftID: 'd1', attemptID: 'send-1',
    });
    await expect(sending).resolves.toMatchObject({ ok: true });
    const send = handle({
      type: 'plainpost.request', method: 'reply.send',
      parameters: { draftID: 'd1', expectedHash: 'hash-1', idempotencyKey: 'send-1' },
    });
    await Promise.resolve();
    expect(native.sent).toHaveLength(0);

    write.resolve();
    await vi.waitFor(() => expect(native.sent).toHaveLength(1));
    native.succeed(0, { requestID: 's1', jobID: 'j1', state: 'sent' });
    await expect(send).resolves.toMatchObject({ ok: true });
  });

  it('prevents native send when unresolved recovery persistence fails', async () => {
    const native = new FakeNativePort();
    const storage = memoryStorage();
    const handle = createBackgroundMessageHandler(() => native, storage);
    await handle({ type: 'plainpost.recovery.safe', messageID: 'm1', draftID: 'd1' });
    vi.mocked(storage.set).mockRejectedValueOnce(new Error('Storage write failed.'));

    const sending = handle({
      type: 'plainpost.recovery.sending', messageID: 'm1', draftID: 'd1', attemptID: 'send-1',
    });
    const send = handle({
      type: 'plainpost.request', method: 'reply.send',
      parameters: { draftID: 'd1', expectedHash: 'hash-1', idempotencyKey: 'send-1' },
    });

    await expect(sending).resolves.toMatchObject({ ok: true });
    await expect(send).resolves.toMatchObject({ ok: false, error: { code: 'UNAVAILABLE' } });
    expect(native.sent).toHaveLength(0);
  });

  it('keeps delivery-uncertain identifiers unresolved across worker restart', async () => {
    const native = new FakeNativePort();
    const storage = memoryStorage();
    const handle = createBackgroundMessageHandler(() => native, storage);
    await handle({ type: 'plainpost.recovery.safe', messageID: 'm1', draftID: 'd1' });
    await handle({
      type: 'plainpost.recovery.sending', messageID: 'm1', draftID: 'd1', attemptID: 'send-1',
    });
    const send = handle({
      type: 'plainpost.request', method: 'reply.send',
      parameters: { draftID: 'd1', expectedHash: 'hash-1', idempotencyKey: 'send-1' },
    });
    await vi.waitFor(() => expect(native.sent).toHaveLength(1));
    native.succeed(0, { requestID: 's1', jobID: 'j1', state: 'deliveryUncertain' });
    await expect(send).resolves.toMatchObject({ ok: true });

    const restarted = createBackgroundMessageHandler(() => new FakeNativePort(), storage);
    await expect(restarted({ type: 'plainpost.recovery.read' })).resolves.toEqual({
      ok: true,
      result: { status: 'sending', messageID: 'm1', draftID: 'd1' },
    });
  });

  it('replaces a confirmed sent recovery with a non-restorable terminal record', async () => {
    const native = new FakeNativePort();
    const storage = memoryStorage();
    const handle = createBackgroundMessageHandler(() => native, storage);
    await handle({ type: 'plainpost.recovery.safe', messageID: 'm1', draftID: 'd1' });
    await handle({
      type: 'plainpost.recovery.sending', messageID: 'm1', draftID: 'd1', attemptID: 'send-1',
    });
    const send = handle({
      type: 'plainpost.request', method: 'reply.send',
      parameters: { draftID: 'd1', expectedHash: 'hash-1', idempotencyKey: 'send-1' },
    });
    await vi.waitFor(() => expect(native.sent).toHaveLength(1));
    native.succeed(0, { requestID: 's1', jobID: 'j1', state: 'sent' });
    await expect(send).resolves.toMatchObject({ ok: true });

    expect(storage.values[POPUP_RECOVERY_STORAGE_KEY]).toEqual({
      status: 'terminal', messageID: 'm1', draftID: 'd1',
    });
  });

  it.each([
    ['sent', { status: 'terminal', messageID: 'm1', draftID: 'd1' }],
    ['failed', { status: 'safe', messageID: 'm1', draftID: 'd1' }],
  ] as const)('ignores a late sending marker after a confirmed %s receipt', async (state, expected) => {
    const native = new FakeNativePort();
    const storage = memoryStorage();
    const handle = createBackgroundMessageHandler(() => native, storage);
    await handle({ type: 'plainpost.recovery.safe', messageID: 'm1', draftID: 'd1' });
    await handle({
      type: 'plainpost.recovery.sending', messageID: 'm1', draftID: 'd1', attemptID: 'send-1',
    });
    const send = handle({
      type: 'plainpost.request', method: 'reply.send',
      parameters: { draftID: 'd1', expectedHash: 'hash-1', idempotencyKey: 'send-1' },
    });
    await vi.waitFor(() => expect(native.sent).toHaveLength(1));
    native.succeed(0, { requestID: 's1', jobID: 'j1', state });
    await expect(send).resolves.toMatchObject({ ok: true });

    const restarted = createBackgroundMessageHandler(() => new FakeNativePort(), storage);
    await restarted({
      type: 'plainpost.recovery.sending', messageID: 'm1', draftID: 'd1', attemptID: 'send-1',
    });

    expect(storage.values[POPUP_RECOVERY_STORAGE_KEY]).toEqual(expected);
  });

  it.each(['safe', 'block'] as const)(
    'ignores a delayed recovery.%s marker while native send is in flight',
    async marker => {
      const native = new FakeNativePort();
      const storage = memoryStorage();
      const handle = createBackgroundMessageHandler(() => native, storage);
      await handle({ type: 'plainpost.recovery.safe', messageID: 'm1', draftID: 'd1' });
      await handle({
        type: 'plainpost.recovery.sending', messageID: 'm1', draftID: 'd1', attemptID: 'send-1',
      });
      const send = handle({
        type: 'plainpost.request', method: 'reply.send',
        parameters: { draftID: 'd1', expectedHash: 'hash-1', idempotencyKey: 'send-1' },
      });
      await vi.waitFor(() => expect(native.sent).toHaveLength(1));

      await handle(marker === 'safe'
        ? { type: 'plainpost.recovery.safe', messageID: 'm1', draftID: 'd1' }
        : { type: 'plainpost.recovery.block' });

      expect(storage.values[POPUP_RECOVERY_STORAGE_KEY]).toEqual({
        status: 'sending', messageID: 'm1', draftID: 'd1',
      });
      native.succeed(0, { requestID: 's1', jobID: 'j1', state: 'deliveryUncertain' });
      await expect(send).resolves.toMatchObject({ ok: true });
    },
  );

  it.each(['safe', 'block'] as const)(
    'keeps durable sending locked when a fresh worker receives delayed recovery.%s',
    async marker => {
      const native = new FakeNativePort();
      const storage = memoryStorage();
      const first = createBackgroundMessageHandler(() => native, storage);
      await first({ type: 'plainpost.recovery.safe', messageID: 'm1', draftID: 'd1' });
      await first({
        type: 'plainpost.recovery.sending', messageID: 'm1', draftID: 'd1', attemptID: 'send-1',
      });
      const send = first({
        type: 'plainpost.request', method: 'reply.send',
        parameters: { draftID: 'd1', expectedHash: 'hash-1', idempotencyKey: 'send-1' },
      });
      await vi.waitFor(() => expect(native.sent).toHaveLength(1));

      const restarted = createBackgroundMessageHandler(() => new FakeNativePort(), storage);
      await restarted(marker === 'safe'
        ? { type: 'plainpost.recovery.safe', messageID: 'm1', draftID: 'd1' }
        : { type: 'plainpost.recovery.block' });

      expect(storage.values[POPUP_RECOVERY_STORAGE_KEY]).toEqual({
        status: 'sending', messageID: 'm1', draftID: 'd1',
      });
      native.succeed(0, { requestID: 's1', jobID: 'j1', state: 'deliveryUncertain' });
      await expect(send).resolves.toMatchObject({ ok: true });
    },
  );

  it('retries a failed teardown handoff before reporting recovery safe', async () => {
    const native = new FakeNativePort();
    const handle = createBackgroundMessageHandler(() => native, memoryStorage());
    await handle({ type: 'plainpost.recovery.safe', messageID: 'm1', draftID: 'd1' });

    const handoff = handle({
      type: 'plainpost.draft.handoff', messageID: 'm1',
      draftID: 'd1', body: 'Latest', expectedHash: 'hash-1',
    });
    await vi.waitFor(() => expect(native.sent).toHaveLength(1));
    native.fail(0, 'UNAVAILABLE');
    await expect(handoff).resolves.toMatchObject({ ok: false, error: { code: 'UNAVAILABLE' } });

    const firstRead = handle({ type: 'plainpost.recovery.read' });
    await vi.waitFor(() => expect(native.sent).toHaveLength(2));
    expect(native.sent[1]).toMatchObject({
      method: 'draft.update',
      parameters: { body: 'Latest', expectedHash: 'hash-1' },
    });
    native.fail(1, 'UNAVAILABLE');
    await expect(firstRead).resolves.toMatchObject({ ok: false, error: { code: 'UNAVAILABLE' } });

    const secondRead = handle({ type: 'plainpost.recovery.read' });
    await vi.waitFor(() => expect(native.sent).toHaveLength(3));
    native.succeed(2, {
      id: 'd1', subject: 'Re: Trip', to: [], body: 'Latest',
      contentHash: 'hash-latest', aiGenerated: false,
    });
    await expect(secondRead).resolves.toEqual({
      ok: true,
      result: { status: 'safe', messageID: 'm1', draftID: 'd1' },
    });
  });

  it('keeps durable recovery blocked when a failed handoff outlives its worker', async () => {
    const storage = memoryStorage();
    const firstNative = new FakeNativePort();
    const first = createBackgroundMessageHandler(() => firstNative, storage);
    await first({ type: 'plainpost.recovery.safe', messageID: 'm1', draftID: 'd1' });

    const handoff = first({
      type: 'plainpost.draft.handoff', messageID: 'm1',
      draftID: 'd1', body: 'Latest', expectedHash: 'hash-1',
    });
    await vi.waitFor(() => expect(firstNative.sent).toHaveLength(1));
    expect(storage.values[POPUP_RECOVERY_STORAGE_KEY]).toEqual({ status: 'blocked' });
    firstNative.fail(0, 'UNAVAILABLE');
    await expect(handoff).resolves.toMatchObject({ ok: false, error: { code: 'UNAVAILABLE' } });

    const secondNative = new FakeNativePort();
    const second = createBackgroundMessageHandler(() => secondNative, storage);
    await expect(second({ type: 'plainpost.recovery.read' })).resolves.toEqual({
      ok: true,
      result: { status: 'blocked' },
    });
    expect(secondNative.sent).toHaveLength(0);
    expect(JSON.stringify(storage.values)).not.toContain('Latest');
    expect(JSON.stringify(storage.values)).not.toContain('hash-1');
  });

  it('ignores a late safe marker while a teardown handoff is unresolved', async () => {
    const storage = memoryStorage();
    const native = new FakeNativePort();
    const first = createBackgroundMessageHandler(() => native, storage);
    await first({ type: 'plainpost.recovery.safe', messageID: 'm1', draftID: 'd1' });
    const handoff = first({
      type: 'plainpost.draft.handoff', messageID: 'm1',
      draftID: 'd1', body: 'Latest', expectedHash: 'hash-1',
    });
    await vi.waitFor(() => expect(native.sent).toHaveLength(1));

    await expect(first({
      type: 'plainpost.recovery.safe', messageID: 'm1', draftID: 'd1',
    })).resolves.toMatchObject({ ok: true });
    expect(storage.values[POPUP_RECOVERY_STORAGE_KEY]).toEqual({ status: 'blocked' });
    native.fail(0, 'UNAVAILABLE');
    await expect(handoff).resolves.toMatchObject({ ok: false });

    const restarted = createBackgroundMessageHandler(() => new FakeNativePort(), storage);
    await expect(restarted({ type: 'plainpost.recovery.read' })).resolves.toEqual({
      ok: true, result: { status: 'blocked' },
    });
  });

  it('coalesces an overlapping newer handoff and resolves only after latest body is saved', async () => {
    const storage = memoryStorage();
    const native = new FakeNativePort();
    const handle = createBackgroundMessageHandler(() => native, storage);
    await handle({ type: 'plainpost.recovery.safe', messageID: 'm1', draftID: 'd1' });
    const first = handle({
      type: 'plainpost.draft.handoff', messageID: 'm1',
      draftID: 'd1', body: 'First body', expectedHash: 'hash-1',
    });
    await vi.waitFor(() => expect(native.sent).toHaveLength(1));
    const second = handle({
      type: 'plainpost.draft.handoff', messageID: 'm1',
      draftID: 'd1', body: 'Newest body', expectedHash: 'hash-1',
    });

    native.succeed(0, {
      id: 'd1', subject: 'Re: Trip', to: [], body: 'First body',
      contentHash: 'hash-first', aiGenerated: false,
    });
    await vi.waitFor(() => expect(native.sent).toHaveLength(2));
    expect(native.sent[1]).toMatchObject({
      method: 'draft.update',
      parameters: { body: 'Newest body', expectedHash: 'hash-first' },
    });
    expect(storage.values[POPUP_RECOVERY_STORAGE_KEY]).toEqual({ status: 'blocked' });
    native.succeed(1, {
      id: 'd1', subject: 'Re: Trip', to: [], body: 'Newest body',
      contentHash: 'hash-newest', aiGenerated: false,
    });

    await expect(first).resolves.toMatchObject({ ok: true, result: { body: 'Newest body' } });
    await expect(second).resolves.toMatchObject({ ok: true, result: { body: 'Newest body' } });
    expect(storage.values[POPUP_RECOVERY_STORAGE_KEY]).toEqual({
      status: 'safe', messageID: 'm1', draftID: 'd1',
    });
  });

  it('refreshes the server draft once after conflict and reapplies latest manual intent', async () => {
    const native = new FakeNativePort();
    const storage = memoryStorage();
    const handle = createBackgroundMessageHandler(() => native, storage);
    await handle({ type: 'plainpost.recovery.safe', messageID: 'm1', draftID: 'd1' });

    const handoff = handle({
      type: 'plainpost.draft.handoff', messageID: 'm1',
      draftID: 'd1', body: 'Latest manual intent', expectedHash: 'hash-old',
    });
    await vi.waitFor(() => expect(native.sent).toHaveLength(1));
    native.fail(0, 'CONFLICT');
    await vi.waitFor(() => expect(native.sent).toHaveLength(2));
    expect(native.sent[1]).toMatchObject({ method: 'draft.read', parameters: { draftID: 'd1' } });
    native.succeed(1, {
      id: 'd1', subject: 'Re: Trip', to: [], body: 'Server body',
      contentHash: 'hash-current', aiGenerated: true,
    });
    await vi.waitFor(() => expect(native.sent).toHaveLength(3));
    expect(native.sent[2]).toMatchObject({
      method: 'draft.update',
      parameters: {
        draftID: 'd1', body: 'Latest manual intent', expectedHash: 'hash-current',
      },
    });
    native.succeed(2, {
      id: 'd1', subject: 'Re: Trip', to: [], body: 'Latest manual intent',
      contentHash: 'hash-latest', aiGenerated: false,
    });

    await expect(handoff).resolves.toMatchObject({ ok: true });
    expect(storage.values[POPUP_RECOVERY_STORAGE_KEY]).toEqual({
      status: 'safe', messageID: 'm1', draftID: 'd1',
    });
  });

  it('bounds repeated handoff conflicts and remains blocked across worker restart', async () => {
    const native = new FakeNativePort();
    const storage = memoryStorage();
    const first = createBackgroundMessageHandler(() => native, storage);
    await first({ type: 'plainpost.recovery.safe', messageID: 'm1', draftID: 'd1' });
    const handoff = first({
      type: 'plainpost.draft.handoff', messageID: 'm1',
      draftID: 'd1', body: 'Latest', expectedHash: 'hash-old',
    });
    await vi.waitFor(() => expect(native.sent).toHaveLength(1));
    native.fail(0, 'CONFLICT');
    await vi.waitFor(() => expect(native.sent).toHaveLength(2));
    native.succeed(1, {
      id: 'd1', subject: 'Re: Trip', to: [], body: 'Server',
      contentHash: 'hash-current', aiGenerated: false,
    });
    await vi.waitFor(() => expect(native.sent).toHaveLength(3));
    native.fail(2, 'CONFLICT');
    await expect(handoff).resolves.toMatchObject({ ok: false, error: { code: 'CONFLICT' } });
    expect(native.sent).toHaveLength(3);
    expect(storage.values[POPUP_RECOVERY_STORAGE_KEY]).toEqual({ status: 'blocked' });

    await expect(first({ type: 'plainpost.recovery.read' })).resolves.toEqual({
      ok: true, result: { status: 'blocked' },
    });
    expect(native.sent).toHaveLength(3);

    const restarted = createBackgroundMessageHandler(() => new FakeNativePort(), storage);
    await expect(restarted({ type: 'plainpost.recovery.read' })).resolves.toEqual({
      ok: true, result: { status: 'blocked' },
    });
  });

  it('erases safe identifiers if blocked persistence fails before handoff', async () => {
    const native = new FakeNativePort();
    const storage = memoryStorage();
    vi.mocked(storage.set)
      .mockImplementationOnce(async entries => { Object.assign(storage.values, entries); })
      .mockRejectedValueOnce(new Error('Storage write failed.'));
    const handle = createBackgroundMessageHandler(() => native, storage);
    await handle({ type: 'plainpost.recovery.safe', messageID: 'm1', draftID: 'd1' });

    await expect(handle({
      type: 'plainpost.draft.handoff', messageID: 'm1',
      draftID: 'd1', body: 'Latest', expectedHash: 'hash-1',
    })).resolves.toMatchObject({ ok: false, error: { code: 'UNAVAILABLE' } });

    expect(native.sent).toHaveLength(0);
    expect(storage.remove).toHaveBeenCalledWith(POPUP_RECOVERY_STORAGE_KEY);
    const restarted = createBackgroundMessageHandler(() => new FakeNativePort(), storage);
    await expect(restarted({ type: 'plainpost.recovery.read' })).resolves.toEqual({
      ok: true, result: { status: 'blocked' },
    });
  });
});
