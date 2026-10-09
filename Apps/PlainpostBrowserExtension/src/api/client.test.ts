import { describe, expect, it, vi } from 'vitest';

import {
  BackgroundNativeClient,
  createBackgroundRequestHandler,
  PlainpostAPIError,
  RuntimePlainpostClient,
  type NativePort,
} from './client';
import type {
  LocalAPIFailure,
  LocalAPIRequest,
  LocalAPIResponse,
} from './contracts';

class FakeEvent<T extends (...args: never[]) => void> {
  private readonly listeners = new Set<T>();

  addListener(listener: T): void {
    this.listeners.add(listener);
  }

  removeListener(listener: T): void {
    this.listeners.delete(listener);
  }

  emit(...args: Parameters<T>): void {
    for (const listener of this.listeners) listener(...args);
  }
}

class FakeNativePort implements NativePort {
  readonly sent: LocalAPIRequest[] = [];
  readonly onMessage = new FakeEvent<(response: LocalAPIResponse) => void>();
  readonly onDisconnect = new FakeEvent<() => void>();
  throwOnPost = false;

  postMessage(request: LocalAPIRequest): void {
    if (this.throwOnPost) throw new Error('native post failed');
    this.sent.push(request);
  }

  emitSuccess(requestID: string, result: unknown): void {
    this.onMessage.emit({ apiVersion: 1, requestID, ok: true, result });
  }

  emitFailure(requestID: string, error: LocalAPIFailure['error']): void {
    this.onMessage.emit({ apiVersion: 1, requestID, ok: false, error });
  }

  disconnect(): void {
    this.onDisconnect.emit();
  }
}

describe('BackgroundNativeClient', () => {
  it('correlates out-of-order native responses by requestID', async () => {
    const native = new FakeNativePort();
    const client = new BackgroundNativeClient(native);
    const first = client.request('session.status', {});
    const second = client.request('mail.unreadList', { limit: 10 });

    native.emitSuccess(native.sent[1]!.requestID, { messages: [], lastSuccessfulSyncAt: null });
    native.emitSuccess(native.sent[0]!.requestID, { ready: true });

    await expect(second).resolves.toEqual({ messages: [], lastSuccessfulSyncAt: null });
    await expect(first).resolves.toEqual({ ready: true });
    expect(native.sent.map(({ apiVersion }) => apiVersion)).toEqual([1, 1]);
  });

  it('rejects every pending request on disconnect and reconnects only for the next request', async () => {
    const firstPort = new FakeNativePort();
    const secondPort = new FakeNativePort();
    const connect = vi.fn()
      .mockReturnValueOnce(firstPort)
      .mockReturnValueOnce(secondPort);
    const client = new BackgroundNativeClient(connect);

    expect(connect).not.toHaveBeenCalled();
    const first = client.request('session.status', {});
    const second = client.request('sync.incrementalAll', {});
    expect(connect).toHaveBeenCalledTimes(1);

    firstPort.disconnect();
    await expect(first).rejects.toMatchObject({ code: 'UNAVAILABLE' });
    await expect(second).rejects.toMatchObject({ code: 'UNAVAILABLE' });
    expect(connect).toHaveBeenCalledTimes(1);

    const retry = client.request('session.status', {});
    expect(connect).toHaveBeenCalledTimes(2);
    secondPort.emitSuccess(secondPort.sent[0]!.requestID, { ready: true });
    await expect(retry).resolves.toEqual({ ready: true });
  });

  it('surfaces structured Local API failures without leaking an untyped error', async () => {
    const native = new FakeNativePort();
    const client = new BackgroundNativeClient(native);
    const result = client.request('mail.open', { messageID: 'missing' });

    native.emitFailure(native.sent[0]!.requestID, {
      code: 'NOT_FOUND',
      message: 'Message not found.',
    });

    await expect(result).rejects.toEqual(
      new PlainpostAPIError('NOT_FOUND', 'Message not found.'),
    );
  });

  it('maps a native connection failure to UNAVAILABLE and tries again on the next request', async () => {
    const native = new FakeNativePort();
    const connect = vi.fn()
      .mockImplementationOnce(() => { throw new Error('sensitive native registration detail'); })
      .mockReturnValueOnce(native);
    const client = new BackgroundNativeClient(connect);

    await expect(client.request('session.status', {})).rejects.toEqual(
      new PlainpostAPIError('UNAVAILABLE', 'Plainpost is unavailable.'),
    );

    const retry = client.request('session.status', {});
    native.emitSuccess(native.sent[0]!.requestID, { ready: true });
    await expect(retry).resolves.toEqual({ ready: true });
    expect(connect).toHaveBeenCalledTimes(2);
  });

  it('invalidates the shared port and rejects all pending requests when postMessage throws', async () => {
    const firstPort = new FakeNativePort();
    const secondPort = new FakeNativePort();
    const connect = vi.fn()
      .mockReturnValueOnce(firstPort)
      .mockReturnValueOnce(secondPort);
    const client = new BackgroundNativeClient(connect);

    const first = client.request('session.status', {});
    const firstRejection = expect(first).rejects.toMatchObject({ code: 'UNAVAILABLE' });
    firstPort.throwOnPost = true;
    const second = client.request('sync.incrementalAll', {});
    const secondRejection = expect(second).rejects.toMatchObject({ code: 'UNAVAILABLE' });

    await Promise.all([firstRejection, secondRejection]);
    expect(connect).toHaveBeenCalledTimes(1);

    const retry = client.request('session.status', {});
    expect(connect).toHaveBeenCalledTimes(2);
    secondPort.emitSuccess(secondPort.sent[0]!.requestID, { ready: true });
    await expect(retry).resolves.toEqual({ ready: true });
  });
});

describe('RuntimePlainpostClient', () => {
  it('forwards typed popup requests through the background message contract', async () => {
    const sendMessage = vi.fn().mockResolvedValue({ ok: true, result: { ready: true } });
    const client = new RuntimePlainpostClient(sendMessage);

    await expect(client.sessionStatus()).resolves.toEqual({ ready: true });
    expect(sendMessage).toHaveBeenCalledWith({
      type: 'plainpost.request',
      method: 'session.status',
      parameters: {},
    });
  });

  it('reconstructs typed API failures from the serializable background response', async () => {
    const sendMessage = vi.fn().mockResolvedValue({
      ok: false,
      error: { code: 'CLIENT_UPDATE_REQUIRED', message: 'Update together.' },
    });
    const client = new RuntimePlainpostClient(sendMessage);

    await expect(client.sessionStatus()).rejects.toEqual(
      new PlainpostAPIError('CLIENT_UPDATE_REQUIRED', 'Update together.'),
    );
  });

  it('maps runtime transport rejection to a safe unavailable error', async () => {
    const sendMessage = vi.fn().mockRejectedValue(
      new Error('sensitive browser runtime diagnostic'),
    );
    const client = new RuntimePlainpostClient(sendMessage);

    await expect(client.sessionStatus()).rejects.toEqual(
      new PlainpostAPIError('UNAVAILABLE', 'Plainpost is unavailable.'),
    );
  });
});

describe('createBackgroundRequestHandler', () => {
  it('ignores unrelated messages and lazily shares one native port', async () => {
    const native = new FakeNativePort();
    const connect = vi.fn(() => native);
    const handle = createBackgroundRequestHandler(connect);

    expect(handle({ type: 'other' })).toBeUndefined();
    expect(connect).not.toHaveBeenCalled();

    const first = handle({
      type: 'plainpost.request',
      method: 'session.status',
      parameters: {},
    });
    const second = handle({
      type: 'plainpost.request',
      method: 'mail.unreadList',
      parameters: { limit: 10 },
    });
    expect(connect).toHaveBeenCalledTimes(1);

    native.emitSuccess(native.sent[0]!.requestID, { ready: true });
    native.emitSuccess(native.sent[1]!.requestID, { messages: [], lastSuccessfulSyncAt: null });
    await expect(first).resolves.toEqual({ ok: true, result: { ready: true } });
    await expect(second).resolves.toEqual({
      ok: true,
      result: { messages: [], lastSuccessfulSyncAt: null },
    });
  });

  it('returns a serializable failure response instead of rejecting across the runtime boundary', async () => {
    const native = new FakeNativePort();
    const handle = createBackgroundRequestHandler(() => native);
    const result = handle({
      type: 'plainpost.request',
      method: 'session.status',
      parameters: {},
    });

    native.emitFailure(native.sent[0]!.requestID, {
      code: 'SERVER_UPDATE_REQUIRED',
      message: 'Update together.',
    });

    await expect(result).resolves.toEqual({
      ok: false,
      error: { code: 'SERVER_UPDATE_REQUIRED', message: 'Update together.' },
    });
  });
});
