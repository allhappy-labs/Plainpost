import {
  LOCAL_API_VERSION,
  localAPIErrorCodes,
  localAPIMethods,
  type DeliveryResult,
  type DraftResult,
  type PlainpostBackgroundError,
  type PlainpostBackgroundResponse,
  type PlainpostClient,
  type PlainpostPopupRequest,
  type LocalAPIErrorCode,
  type LocalAPIMethod,
  type LocalAPIParameterMap,
  type LocalAPIRequest,
  type LocalAPIResponse,
  type LocalAPIResultMap,
  type MessageDetail,
  type SessionStatus,
  type SummaryResult,
  type SyncResult,
  type UnreadListResult,
} from './contracts';

interface NativeEvent<Listener extends (...args: never[]) => void> {
  addListener(listener: Listener): void;
  removeListener(listener: Listener): void;
}

export interface NativePort {
  postMessage(message: LocalAPIRequest): void;
  onMessage: NativeEvent<(response: LocalAPIResponse) => void>;
  onDisconnect: NativeEvent<() => void>;
}

interface PendingRequest {
  resolve: (result: unknown) => void;
  reject: (error: PlainpostAPIError) => void;
}

export class PlainpostAPIError extends Error {
  constructor(
    readonly code: LocalAPIErrorCode,
    message: string,
  ) {
    super(message);
    this.name = 'PlainpostAPIError';
  }
}

export class BackgroundNativeClient {
  private port: NativePort | undefined;
  private portListeners: {
    port: NativePort;
    onMessage: (response: LocalAPIResponse) => void;
    onDisconnect: () => void;
  } | undefined;
  private readonly connect: () => NativePort;
  private readonly pending = new Map<string, PendingRequest>();

  constructor(portOrConnect: NativePort | (() => NativePort)) {
    this.connect = typeof portOrConnect === 'function'
      ? portOrConnect
      : () => portOrConnect;
  }

  request<M extends LocalAPIMethod>(
    method: M,
    parameters: LocalAPIParameterMap[M],
  ): Promise<LocalAPIResultMap[M]> {
    let port: NativePort;
    try {
      port = this.connectedPort();
    } catch {
      return Promise.reject(new PlainpostAPIError('UNAVAILABLE', 'Plainpost is unavailable.'));
    }
    const requestID = globalThis.crypto.randomUUID();
    const request: LocalAPIRequest<M> = {
      apiVersion: LOCAL_API_VERSION,
      requestID,
      method,
      parameters,
    };

    const result = new Promise<LocalAPIResultMap[M]>((resolve, reject) => {
      this.pending.set(requestID, {
        resolve: value => resolve(value as LocalAPIResultMap[M]),
        reject,
      });
    });

    try {
      port.postMessage(request);
    } catch {
      this.invalidatePort(port);
      return result;
    }
    return result;
  }

  private connectedPort(): NativePort {
    if (this.port) return this.port;

    const port = this.connect();
    const onMessage = (response: LocalAPIResponse): void => {
      if (this.port !== port) return;
      const pending = this.pending.get(response.requestID ?? '');
      if (!pending) return;
      this.pending.delete(response.requestID ?? '');
      if (response.ok) {
        pending.resolve(response.result);
      } else {
        pending.reject(new PlainpostAPIError(response.error.code, response.error.message));
      }
    };
    const onDisconnect = (): void => {
      this.invalidatePort(port);
    };
    port.onMessage.addListener(onMessage);
    port.onDisconnect.addListener(onDisconnect);
    this.port = port;
    this.portListeners = { port, onMessage, onDisconnect };
    return port;
  }

  private invalidatePort(port: NativePort): void {
    if (this.port !== port) return;
    const listeners = this.portListeners;
    if (listeners?.port === port) {
      port.onMessage.removeListener(listeners.onMessage);
      port.onDisconnect.removeListener(listeners.onDisconnect);
    }
    this.port = undefined;
    this.portListeners = undefined;
    const error = new PlainpostAPIError('UNAVAILABLE', 'Plainpost is unavailable.');
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }
}

export function createBackgroundRequestHandler(
  connect: () => NativePort,
): (message: unknown) => Promise<PlainpostBackgroundResponse> | undefined {
  const client = new BackgroundNativeClient(connect);
  const methods = new Set<LocalAPIMethod>(localAPIMethods);

  return (message: unknown): Promise<PlainpostBackgroundResponse> | undefined => {
    if (!isRecord(message) || message.type !== 'plainpost.request') return undefined;
    if (typeof message.method !== 'string' || !methods.has(message.method as LocalAPIMethod)) {
      return undefined;
    }
    if (!isRecord(message.parameters)) return undefined;
    const method = message.method as LocalAPIMethod;
    return client.request(method, message.parameters as LocalAPIParameterMap[LocalAPIMethod]).then<
      PlainpostBackgroundResponse,
      PlainpostBackgroundResponse
    >(
      result => ({ ok: true, result }),
      error => ({ ok: false, error: serializableError(error) }),
    );
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function serializableError(error: unknown): PlainpostBackgroundError {
  if (error instanceof PlainpostAPIError) return { code: error.code, message: error.message };
  return { code: 'UNAVAILABLE', message: 'Plainpost is unavailable.' };
}

type SendRuntimeMessage = (message: PlainpostPopupRequest) => Promise<unknown>;

export class RuntimePlainpostClient implements PlainpostClient {
  constructor(private readonly sendMessage: SendRuntimeMessage) {}

  sessionStatus(): Promise<SessionStatus> {
    return this.request('session.status', {});
  }

  unreadList(limit = 10): Promise<UnreadListResult> {
    return this.request('mail.unreadList', { limit });
  }

  openMessage(messageID: string): Promise<MessageDetail> {
    return this.request('mail.open', { messageID });
  }

  incrementalSync(): Promise<SyncResult> {
    return this.request('sync.incrementalAll', {});
  }

  summarize(messageID: string): Promise<SummaryResult> {
    return this.request('ai.summarize', { messageID });
  }

  beginReply(messageID: string): Promise<DraftResult> {
    return this.request('reply.begin', { messageID });
  }

  readDraft(draftID: string): Promise<DraftResult> {
    return this.request('draft.read', { draftID });
  }

  updateDraft(draftID: string, body: string, expectedHash: string): Promise<DraftResult> {
    return this.request('draft.update', { draftID, body, expectedHash });
  }

  draftReply(
    draftID: string,
    messageID: string,
    instruction: string,
    expectedHash: string,
  ): Promise<DraftResult> {
    return this.request('ai.draftReply', { draftID, messageID, instruction, expectedHash });
  }

  sendReply(
    draftID: string,
    expectedHash: string,
    idempotencyKey: string,
  ): Promise<DeliveryResult> {
    return this.request('reply.send', { draftID, expectedHash, idempotencyKey });
  }

  private request<M extends LocalAPIMethod>(
    method: M,
    parameters: LocalAPIParameterMap[M],
  ): Promise<LocalAPIResultMap[M]> {
    return this.requestThroughBackground(method, parameters);
  }

  private async requestThroughBackground<M extends LocalAPIMethod>(
    method: M,
    parameters: LocalAPIParameterMap[M],
  ): Promise<LocalAPIResultMap[M]> {
    let response: unknown;
    try {
      response = await this.sendMessage({
        type: 'plainpost.request',
        method,
        parameters,
      } as PlainpostPopupRequest<M>);
    } catch {
      throw new PlainpostAPIError('UNAVAILABLE', 'Plainpost is unavailable.');
    }
    if (!isRecord(response) || typeof response.ok !== 'boolean') {
      throw new PlainpostAPIError('UNAVAILABLE', 'Plainpost is unavailable.');
    }
    if (response.ok) return response.result as LocalAPIResultMap[M];

    const error = response.error;
    if (!isRecord(error) || typeof error.code !== 'string' || typeof error.message !== 'string') {
      throw new PlainpostAPIError('UNAVAILABLE', 'Plainpost is unavailable.');
    }
    const codes = new Set<string>(localAPIErrorCodes);
    if (!codes.has(error.code)) {
      throw new PlainpostAPIError('OPERATION_FAILED', 'The local operation failed.');
    }
    throw new PlainpostAPIError(error.code as LocalAPIErrorCode, error.message);
  }
}

export type { PlainpostClient } from './contracts';
