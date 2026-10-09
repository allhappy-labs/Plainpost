import {
  BackgroundNativeClient,
  PlainpostAPIError,
  type NativePort,
} from './client';
import {
  localAPIMethods,
  type DeliveryResult,
  type DraftResult,
  type PlainpostBackgroundError,
  type PlainpostBackgroundResponse,
  type LocalAPIMethod,
  type LocalAPIParameterMap,
  type LocalAPIResultMap,
} from './contracts';

export const POPUP_RECOVERY_STORAGE_KEY = 'plainpostPopupRecovery';

export interface BackgroundStorageArea {
  get(keys: string | string[]): Promise<Record<string, unknown>>;
  set(entries: Record<string, unknown>): Promise<void>;
  remove(keys: string | string[]): Promise<void>;
}

type PopupRecoveryRecord =
  | { status: 'blocked' }
  | { status: 'terminal'; messageID: string; draftID: string }
  | { status: 'sending'; messageID: string; draftID: string }
  | { status: 'safe'; messageID: string; draftID: string };

interface DraftLane {
  tail: Promise<void>;
  latestHash?: string;
}

interface DraftHandoffPayload {
  messageID: string;
  draftID: string;
  body: string;
  expectedHash: string;
}

interface HandoffRecovery {
  payload: DraftHandoffPayload;
  revision: number;
  terminal: boolean;
  blocked: Promise<void>;
  completion?: Promise<DraftResult>;
}

interface PendingSendRecovery {
  messageID: string;
  draftID: string;
  attemptID: string;
  blocked: Promise<void>;
}

type BackgroundMessageHandler =
  (message: unknown) => Promise<PlainpostBackgroundResponse> | undefined;

export function createBackgroundMessageHandler(
  connect: () => NativePort,
  storage: BackgroundStorageArea,
): BackgroundMessageHandler {
  const coordinator = new BackgroundPopupCoordinator(
    new BackgroundNativeClient(connect),
    storage,
  );
  return message => coordinator.handle(message);
}

class BackgroundPopupCoordinator {
  private readonly methods = new Set<LocalAPIMethod>(localAPIMethods);
  private readonly draftLanes = new Map<string, DraftLane>();
  private readonly handoffRecoveries = new Map<string, HandoffRecovery>();
  private readonly pendingSendRecovery = new Map<string, PendingSendRecovery>();
  private recoveryTail: Promise<void> | undefined;

  constructor(
    private readonly client: BackgroundNativeClient,
    private readonly storage: BackgroundStorageArea,
  ) {}

  handle(message: unknown): Promise<PlainpostBackgroundResponse> | undefined {
    if (!isRecord(message) || typeof message.type !== 'string') return undefined;

    switch (message.type) {
    case 'plainpost.recovery.safe':
      if (!isIdentifier(message.messageID) || !isIdentifier(message.draftID)) return undefined;
      return this.respond(this.publishSafeRecovery(message.messageID, message.draftID));
    case 'plainpost.recovery.sending': {
      if (
        !isIdentifier(message.messageID)
        || !isIdentifier(message.draftID)
        || !isIdentifier(message.attemptID)
      ) return undefined;
      const messageID = message.messageID;
      const draftID = message.draftID;
      const attemptID = message.attemptID;
      const existing = this.pendingSendRecovery.get(draftID);
      if (
        existing?.messageID === messageID
        && existing.attemptID === attemptID
      ) {
        return this.respond(existing.blocked.then(() => undefined));
      }
      const blocked = this.authorizeSendRecovery(messageID, draftID);
      this.pendingSendRecovery.set(draftID, {
        messageID,
        draftID,
        attemptID,
        blocked,
      });
      void blocked.catch(() => {
        if (this.pendingSendRecovery.get(draftID)?.blocked === blocked) {
          this.pendingSendRecovery.delete(draftID);
        }
      });
      return this.respond(blocked.then(() => undefined));
    }
    case 'plainpost.recovery.block':
      return this.respond(this.publishBlockedRecovery());
    case 'plainpost.recovery.read':
      return this.readRecovery();
    case 'plainpost.draft.handoff':
      if (
        !isIdentifier(message.messageID)
        || !isIdentifier(message.draftID)
        || typeof message.body !== 'string'
        || !isIdentifier(message.expectedHash)
      ) return undefined;
      return this.respond(this.startHandoff({
        messageID: message.messageID,
        draftID: message.draftID,
        body: message.body,
        expectedHash: message.expectedHash,
      }));
    case 'plainpost.request':
      return this.handleAPIRequest(message);
    default:
      return undefined;
    }
  }

  private handleAPIRequest(message: Record<string, unknown>): Promise<PlainpostBackgroundResponse> | undefined {
    if (
      typeof message.method !== 'string'
      || !this.methods.has(message.method as LocalAPIMethod)
      || !isRecord(message.parameters)
    ) return undefined;

    const method = message.method as LocalAPIMethod;
    const parameters = message.parameters as LocalAPIParameterMap[LocalAPIMethod];
    const draftID = 'draftID' in parameters ? parameters.draftID : undefined;
    const expectedHash = 'expectedHash' in parameters ? parameters.expectedHash : undefined;
    if (
      (method === 'draft.update' || method === 'ai.draftReply' || method === 'reply.send')
      && isIdentifier(draftID)
      && isIdentifier(expectedHash)
    ) {
      const operation = this.enqueueDraft(
        draftID,
        expectedHash,
        async currentHash => {
          if (method === 'reply.send') {
            await this.requirePersistedSendRecovery(
              draftID,
              (parameters as LocalAPIParameterMap['reply.send']).idempotencyKey,
            );
          }
          return this.client.request(method, {
            ...parameters,
            expectedHash: currentHash,
          } as LocalAPIParameterMap[typeof method]);
        },
      );
      if (method === 'reply.send') {
        return this.respond(operation.then(
          async result => {
            await this.finishSendRecovery(
              draftID,
              (parameters as LocalAPIParameterMap['reply.send']).idempotencyKey,
              result as DeliveryResult,
            );
            return result;
          },
          error => {
            this.settleSendRecovery(
              draftID,
              (parameters as LocalAPIParameterMap['reply.send']).idempotencyKey,
            );
            throw error;
          },
        ));
      }
      return this.respond(operation);
    }

    return this.respond(this.client.request(method, parameters));
  }

  private startHandoff(payload: DraftHandoffPayload): Promise<DraftResult> {
    let recovery = this.handoffRecoveries.get(payload.draftID);
    const blocked = this.blockRecoveryForHandoff();
    if (recovery) {
      recovery.payload = payload;
      recovery.revision += 1;
      recovery.terminal = false;
      recovery.blocked = blocked;
    } else {
      recovery = { payload, revision: 1, terminal: false, blocked };
      this.handoffRecoveries.set(payload.draftID, recovery);
    }
    if (recovery.completion) return recovery.completion;

    return this.resumeHandoff(recovery);
  }

  private resumeHandoff(recovery: HandoffRecovery): Promise<DraftResult> {
    const completion = this.drainHandoffs(recovery);
    recovery.completion = completion;
    void completion.then(
      () => {
        if (this.handoffRecoveries.get(recovery.payload.draftID)?.completion === completion) {
          this.handoffRecoveries.delete(recovery.payload.draftID);
        }
      },
      () => {
        const current = this.handoffRecoveries.get(recovery.payload.draftID);
        if (current?.completion === completion) delete current.completion;
      },
    );
    return completion;
  }

  private async drainHandoffs(recovery: HandoffRecovery): Promise<DraftResult> {
    let latestHash: string | undefined;
    while (true) {
      const revision = recovery.revision;
      const payload = recovery.payload;
      await recovery.blocked;
      let result: DraftResult;
      try {
        result = await this.enqueueDraft<'draft.update'>(
          payload.draftID,
          latestHash ?? payload.expectedHash,
          expectedHash => this.updateHandoffWithConflictRefresh(payload, expectedHash),
        );
      } catch (error) {
        if (error instanceof TerminalHandoffConflict) recovery.terminal = true;
        throw error;
      }
      latestHash = result.contentHash;
      if (recovery.revision !== revision) continue;
      await this.queueRecoveryWrite({
        status: 'safe',
        messageID: payload.messageID,
        draftID: payload.draftID,
      });
      if (recovery.revision === revision) return result;
    }
  }

  private async updateHandoffWithConflictRefresh(
    payload: DraftHandoffPayload,
    expectedHash: string,
  ): Promise<DraftResult> {
    try {
      return await this.client.request('draft.update', {
        draftID: payload.draftID,
        body: payload.body,
        expectedHash,
      });
    } catch (error) {
      if (!(error instanceof PlainpostAPIError) || error.code !== 'CONFLICT') throw error;
      const current = await this.client.request('draft.read', { draftID: payload.draftID });
      try {
        return await this.client.request('draft.update', {
          draftID: payload.draftID,
          body: payload.body,
          expectedHash: current.contentHash,
        });
      } catch (retryError) {
        if (retryError instanceof PlainpostAPIError && retryError.code === 'CONFLICT') {
          throw new TerminalHandoffConflict(retryError.message);
        }
        throw retryError;
      }
    }
  }

  private async blockRecoveryForHandoff(): Promise<void> {
    try {
      await this.queueRecoveryWrite({ status: 'blocked' });
    } catch (error) {
      try {
        await this.queueRecoveryErase();
      } catch {
        // The original write error is the actionable failure; neither path may proceed to native.
      }
      throw error;
    }
  }

  private async requirePersistedSendRecovery(draftID: string, attemptID: string): Promise<void> {
    const recovery = this.pendingSendRecovery.get(draftID);
    if (!recovery || recovery.attemptID !== attemptID) {
      throw new PlainpostAPIError('UNAVAILABLE', 'Send recovery is unavailable.');
    }
    await recovery.blocked;
    await this.recoveryTail;
    const current = await this.storedRecovery();
    if (
      current.status !== 'safe'
      || current.messageID !== recovery.messageID
      || current.draftID !== recovery.draftID
    ) {
      throw new PlainpostAPIError('UNAVAILABLE', 'Send recovery is unavailable.');
    }
    await this.queueRecoveryWrite({
      status: 'sending',
      messageID: recovery.messageID,
      draftID: recovery.draftID,
    });
    const stored = await this.storedRecovery();
    if (
      stored.status !== 'sending'
      || stored.messageID !== recovery.messageID
      || stored.draftID !== recovery.draftID
    ) {
      throw new PlainpostAPIError('UNAVAILABLE', 'Send recovery is unavailable.');
    }
  }

  private async authorizeSendRecovery(messageID: string, draftID: string): Promise<void> {
    await this.recoveryTail;
    const stored = await this.storedRecovery();
    if (
      stored.status !== 'safe'
      || stored.messageID !== messageID
      || stored.draftID !== draftID
    ) {
      throw new PlainpostAPIError('UNAVAILABLE', 'Send recovery is unavailable.');
    }
  }

  private async finishSendRecovery(
    draftID: string,
    attemptID: string,
    result: DeliveryResult,
  ): Promise<void> {
    const recovery = this.pendingSendRecovery.get(draftID);
    this.settleSendRecovery(draftID, attemptID);
    if (result.state === 'failed' && recovery?.attemptID === attemptID) {
      await this.queueRecoveryWrite({
        status: 'safe',
        messageID: recovery.messageID,
        draftID: recovery.draftID,
      });
      return;
    }
    if (result.state === 'sent' && recovery?.attemptID === attemptID) {
      await this.queueRecoveryWrite({
        status: 'terminal',
        messageID: recovery.messageID,
        draftID: recovery.draftID,
      });
      return;
    }
    await this.recoveryTail;
  }

  private settleSendRecovery(draftID: string, attemptID: string): void {
    if (this.pendingSendRecovery.get(draftID)?.attemptID === attemptID) {
      this.pendingSendRecovery.delete(draftID);
    }
  }

  private async publishSafeRecovery(messageID: string, draftID: string): Promise<void> {
    if (this.handoffRecoveries.has(draftID)) {
      await this.recoveryTail;
      return;
    }
    await this.recoveryTail;
    if (this.pendingSendRecovery.has(draftID)) return;
    const stored = await this.storedRecovery();
    if (stored.status === 'sending') return;
    if (
      stored.status === 'terminal'
      && stored.messageID === messageID
      && stored.draftID === draftID
    ) return;
    await this.queueRecoveryWrite({ status: 'safe', messageID, draftID });
  }

  private async publishBlockedRecovery(): Promise<void> {
    await this.recoveryTail;
    if (this.pendingSendRecovery.size > 0) return;
    const stored = await this.storedRecovery();
    if (stored.status === 'sending' || stored.status === 'terminal') return;
    await this.queueRecoveryWrite({ status: 'blocked' });
  }

  private enqueueDraft<M extends LocalAPIMethod>(
    draftID: string,
    expectedHash: string,
    operation: (expectedHash: string) => Promise<LocalAPIResultMap[M]>,
  ): Promise<LocalAPIResultMap[M]> {
    const existing = this.draftLanes.get(draftID);
    const lane = existing ?? { tail: Promise.resolve() };
    this.draftLanes.set(draftID, lane);
    const run = existing
      ? lane.tail.then(() => operation(lane.latestHash ?? expectedHash))
      : operation(expectedHash);
    const settled = run.then(
      result => {
        if (isDraftResult(result)) lane.latestHash = result.contentHash;
      },
      () => undefined,
    );
    lane.tail = settled;
    void settled.finally(() => {
      if (this.draftLanes.get(draftID)?.tail === settled) this.draftLanes.delete(draftID);
    });
    return run;
  }

  private queueRecoveryWrite(record: PopupRecoveryRecord): Promise<void> {
    return this.queueRecoveryMutation(() => this.storage.set({
      [POPUP_RECOVERY_STORAGE_KEY]: record,
    }));
  }

  private queueRecoveryErase(): Promise<void> {
    return this.queueRecoveryMutation(() => this.storage.remove(POPUP_RECOVERY_STORAGE_KEY));
  }

  private queueRecoveryMutation(mutation: () => Promise<void>): Promise<void> {
    const operation = this.recoveryTail ? this.recoveryTail.then(mutation) : mutation();
    const settled = operation.catch(() => undefined);
    this.recoveryTail = settled;
    void settled.finally(() => {
      if (this.recoveryTail === settled) this.recoveryTail = undefined;
    });
    return operation;
  }

  private async readRecovery(): Promise<PlainpostBackgroundResponse> {
    try {
      await this.recoveryTail;
      let record = await this.storedRecovery();
      if (this.handoffRecoveries.size > 0) {
        for (const recovery of [...this.handoffRecoveries.values()]) {
          if (recovery.terminal) continue;
          if (recovery.completion) {
            await recovery.completion;
          } else {
            recovery.blocked = this.blockRecoveryForHandoff();
            await this.resumeHandoff(recovery);
          }
        }
        await this.recoveryTail;
        record = await this.storedRecovery();
      }
      return { ok: true, result: record };
    } catch (error) {
      return { ok: false, error: serializableError(error) };
    }
  }

  private async storedRecovery(): Promise<PopupRecoveryRecord> {
    const values = await this.storage.get(POPUP_RECOVERY_STORAGE_KEY);
    const value = values[POPUP_RECOVERY_STORAGE_KEY];
    if (
      isRecord(value)
      && (value.status === 'safe' || value.status === 'sending')
      && isIdentifier(value.messageID)
      && isIdentifier(value.draftID)
    ) {
      return { status: value.status, messageID: value.messageID, draftID: value.draftID };
    }
    if (
      isRecord(value)
      && value.status === 'terminal'
      && isIdentifier(value.messageID)
      && isIdentifier(value.draftID)
    ) {
      return { status: 'terminal', messageID: value.messageID, draftID: value.draftID };
    }
    return { status: 'blocked' };
  }

  private respond<Result>(operation: Promise<Result>): Promise<PlainpostBackgroundResponse<Result>> {
    return operation.then<PlainpostBackgroundResponse<Result>, PlainpostBackgroundResponse<Result>>(
      result => ({ ok: true, result }),
      error => ({ ok: false, error: serializableError(error) }),
    );
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isIdentifier(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0;
}

function isDraftResult(value: unknown): value is DraftResult {
  return isRecord(value) && typeof value.contentHash === 'string';
}

class TerminalHandoffConflict extends PlainpostAPIError {
  constructor(message: string) {
    super('CONFLICT', message);
  }
}

function serializableError(error: unknown): PlainpostBackgroundError {
  if (error instanceof PlainpostAPIError) return { code: error.code, message: error.message };
  return { code: 'UNAVAILABLE', message: 'Plainpost is unavailable.' };
}
