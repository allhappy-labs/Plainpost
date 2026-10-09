import { PlainpostAPIError } from '../api/client';
import type { LocalAPIErrorCode } from '../api/contracts';
import type { PopupState } from '../state/popup-controller';
import { PopupController } from '../state/popup-controller';

export type PopupRecoveryRecord =
  | { status: 'blocked' }
  | { status: 'terminal'; messageID: string; draftID: string }
  | { status: 'sending'; messageID: string; draftID: string }
  | { status: 'safe'; messageID: string; draftID: string };

export interface PopupRecoveryStore {
  read(): Promise<PopupRecoveryRecord>;
  markSafe(messageID: string, draftID: string): Promise<void>;
  markSending(messageID: string, draftID: string, attemptID: string): Promise<void>;
  block(): Promise<void>;
}

export interface DraftHandoffPayload {
  messageID: string;
  draftID: string;
  body: string;
  expectedHash: string;
}

export type DraftHandoff = (payload: DraftHandoffPayload) => void | Promise<void>;

interface PopupLifecycleOptions {
  visibilityTarget?: Document;
  handoffDraft?: DraftHandoff;
}

type SendRuntimeMessage = (message: unknown) => Promise<unknown>;

export class RuntimePopupLifecycleClient implements PopupRecoveryStore {
  constructor(private readonly sendMessage: SendRuntimeMessage) {}

  async read(): Promise<PopupRecoveryRecord> {
    const result = await this.request({ type: 'plainpost.recovery.read' });
    if (
      isRecord(result)
      && (result.status === 'safe' || result.status === 'sending')
      && isIdentifier(result.messageID)
      && isIdentifier(result.draftID)
    ) {
      return { status: result.status, messageID: result.messageID, draftID: result.draftID };
    }
    if (
      isRecord(result)
      && result.status === 'terminal'
      && isIdentifier(result.messageID)
      && isIdentifier(result.draftID)
    ) {
      return { status: 'terminal', messageID: result.messageID, draftID: result.draftID };
    }
    return { status: 'blocked' };
  }

  async markSafe(messageID: string, draftID: string): Promise<void> {
    await this.request({ type: 'plainpost.recovery.safe', messageID, draftID });
  }

  async block(): Promise<void> {
    await this.request({ type: 'plainpost.recovery.block' });
  }

  async markSending(messageID: string, draftID: string, attemptID: string): Promise<void> {
    await this.request({ type: 'plainpost.recovery.sending', messageID, draftID, attemptID });
  }

  async handoffDraft(payload: DraftHandoffPayload): Promise<void> {
    await this.request({ type: 'plainpost.draft.handoff', ...payload });
  }

  private async request(message: unknown): Promise<unknown> {
    let response: unknown;
    try {
      response = await this.sendMessage(message);
    } catch {
      throw new PlainpostAPIError('UNAVAILABLE', 'Plainpost is unavailable.');
    }
    if (!isRecord(response) || typeof response.ok !== 'boolean') {
      throw new PlainpostAPIError('UNAVAILABLE', 'Plainpost is unavailable.');
    }
    if (response.ok) return response.result;
    const error = response.error;
    if (!isRecord(error) || typeof error.code !== 'string' || typeof error.message !== 'string') {
      throw new PlainpostAPIError('UNAVAILABLE', 'Plainpost is unavailable.');
    }
    throw new PlainpostAPIError(error.code as LocalAPIErrorCode, error.message);
  }
}

export async function restoreOrOpen(
  controller: PopupController,
  store: PopupRecoveryStore,
): Promise<void> {
  let recovery: PopupRecoveryRecord;
  try {
    recovery = await store.read();
  } catch {
    controller.recoveryUnavailable();
    return;
  }

  if (recovery.status === 'safe') {
    const result = await controller.restoreReply(recovery.messageID, recovery.draftID);
    if (result !== 'stale') return;
    await safelyBlock(store);
  }
  if (recovery.status === 'sending') {
    controller.recoverInterruptedSend(recovery.messageID, recovery.draftID);
    return;
  }
  await controller.open();
}

export function installPopupLifecycle(
  controller: PopupController,
  store: PopupRecoveryStore,
  lifecycleTarget: EventTarget,
  options: PopupLifecycleOptions = {},
): () => void {
  let lastHandoffSignature: string | undefined;
  const persist = (state: PopupState): void => {
    if (state.kind === 'reply' && state.recoverySafety === 'safe') {
      void store.markSafe(state.message.id, state.draft.id).catch(() => undefined);
      return;
    }
    if (state.kind === 'reply' && (
      state.deliveryState === 'sending' || state.deliveryState === 'deliveryUncertain'
    )) {
      const attemptID = controller.currentSendAttemptID();
      if (attemptID) {
        void store.markSending(state.message.id, state.draft.id, attemptID).catch(() => undefined);
      }
      return;
    }
    if (shouldBlockRecovery(state)) void store.block().catch(() => undefined);
  };

  const handoff = (): void => {
    const state = controller.state;
    if (
      state.kind === 'reply'
      && state.recoverySafety === 'safe'
      && (state.isSaving || state.saveError !== null)
    ) {
      const signature = JSON.stringify([
        state.draft.id,
        state.draft.body,
        state.draft.contentHash,
      ]);
      if (signature === lastHandoffSignature) return;
      lastHandoffSignature = signature;
      const completion = options.handoffDraft?.({
        messageID: state.message.id,
        draftID: state.draft.id,
        body: state.draft.body,
        expectedHash: state.draft.contentHash,
      });
      void completion?.catch(() => undefined);
      return;
    }
    if (state.kind === 'reply' && (
      state.deliveryState === 'sending' || state.deliveryState === 'deliveryUncertain'
    )) {
      const attemptID = controller.currentSendAttemptID();
      if (attemptID) {
        void store.markSending(state.message.id, state.draft.id, attemptID).catch(() => undefined);
      }
      return;
    }
    if (shouldBlockRecovery(state)) void store.block().catch(() => undefined);
  };
  const handoffWhenHidden = (): void => {
    if (options.visibilityTarget?.visibilityState === 'hidden') handoff();
  };

  const unsubscribe = controller.subscribe(persist);
  persist(controller.state);
  lifecycleTarget.addEventListener('pagehide', handoff);
  options.visibilityTarget?.addEventListener('visibilitychange', handoffWhenHidden);

  return () => {
    unsubscribe();
    lifecycleTarget.removeEventListener('pagehide', handoff);
    options.visibilityTarget?.removeEventListener('visibilitychange', handoffWhenHidden);
  };
}

function shouldBlockRecovery(state: PopupState): boolean {
  return state.kind === 'list'
    || state.kind === 'reader'
    || (state.kind === 'reply' && state.recoverySafety === 'blocked');
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isIdentifier(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0;
}

async function safelyBlock(store: PopupRecoveryStore): Promise<void> {
  try {
    await store.block();
  } catch {
    // Recovery cleanup must not prevent the user from returning to unread mail.
  }
}
