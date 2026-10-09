import type {
  DeliveryResult,
  DraftResult,
  PlainpostClient,
  MessageDetail,
  UnreadMessage,
} from '../api/contracts';
import { PlainpostAPIError } from '../api/client';

export interface ConnectingState {
  kind: 'connecting';
}

export interface ListState {
  kind: 'list';
  messages: UnreadMessage[];
  lastSuccessfulSyncAt: string | null;
  isRefreshing: boolean;
  refreshError: string | null;
  actionError: string | null;
}

export interface ReaderState {
  kind: 'reader';
  message: MessageDetail;
  summary: string | null;
  isSummarizing: boolean;
  summaryError: string | null;
  actionError: string | null;
}

export type ReplyDeliveryState = 'idle' | 'sending' | 'failed' | 'deliveryUncertain';

export interface ReplyState {
  kind: 'reply';
  message: MessageDetail;
  summary: string | null;
  draft: DraftResult;
  isSaving: boolean;
  saveError: string | null;
  isDraftingWithAI: boolean;
  aiError: string | null;
  recoverySafety: 'safe' | 'blocked';
  deliveryState: ReplyDeliveryState;
  sendError: string | null;
}

export type RestoreReplyResult = 'restored' | 'stale' | 'retryableFailure' | 'ignored';

export interface SentState {
  kind: 'sent';
  message: MessageDetail;
  delivery: DeliveryResult;
}

export interface InterruptedSendState {
  kind: 'interruptedSend';
  messageID: string;
  draftID: string;
}

export interface UnavailableState {
  kind: 'unavailable';
  message: string;
}

export interface VersionMismatchState {
  kind: 'versionMismatch';
  message: string;
}

export type PopupState =
  | ConnectingState
  | ListState
  | ReaderState
  | ReplyState
  | SentState
  | InterruptedSendState
  | UnavailableState
  | VersionMismatchState;

interface PopupControllerOptions {
  debounceMilliseconds?: number;
  uuid?: () => string;
}

interface PendingEdit {
  body: string;
  sequence: number;
}

interface SaveWaiter {
  sequence: number;
  resolve: () => void;
  reject: (reason: unknown) => void;
}

interface TrackedOperation {
  generation: number;
  completion: Promise<void>;
}

interface SendContext {
  generation: number;
  draftGeneration: number;
  draftID: string;
  key: string;
}

type StateListener = (state: PopupState) => void;

export class PopupController {
  state: PopupState = { kind: 'connecting' };
  refreshCompletion: Promise<void> = Promise.resolve();

  private readonly debounceMilliseconds: number;
  private readonly uuid: () => string;
  private readonly listeners = new Set<StateListener>();
  private readonly openedMessageIDs = new Set<string>();
  private listSnapshot: ListState | undefined;
  private openGeneration = 0;
  private openMessageGeneration = 0;
  private replyIntentGeneration = 0;
  private beginReplyOperation: {
    messageID: string;
    generation: number;
    completion: Promise<void>;
  } | undefined;

  private draftSessionGeneration = 0;
  private editSequence = 0;
  private pendingEdit: PendingEdit | undefined;
  private pendingEditReady = false;
  private saveTimer: ReturnType<typeof setTimeout> | undefined;
  private saveDrain: Promise<void> | undefined;
  private readonly saveWaiters: SaveWaiter[] = [];
  private serverDraft: DraftResult | undefined;
  private aiCallingGeneration: number | undefined;
  private activeAI: TrackedOperation | undefined;

  private sendAttemptKey: string | undefined;
  private sendAttemptGeneration = 0;
  private activeSendContext: SendContext | undefined;
  private sendInFlight = false;
  private sendCompletion: Promise<void> | undefined;

  constructor(
    private readonly api: PlainpostClient,
    options: PopupControllerOptions = {},
  ) {
    this.debounceMilliseconds = options.debounceMilliseconds ?? 250;
    this.uuid = options.uuid ?? (() => globalThis.crypto.randomUUID());
  }

  subscribe(listener: StateListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  recoveryUnavailable(): void {
    this.setConnectionFailure(
      new PlainpostAPIError('UNAVAILABLE', 'Plainpost recovery is temporarily unavailable.'),
    );
  }

  recoverInterruptedSend(messageID: string, draftID: string): void {
    this.setState({ kind: 'interruptedSend', messageID, draftID });
  }

  currentSendAttemptID(): string | undefined {
    return this.sendAttemptKey;
  }

  async open(): Promise<void> {
    if (this.state.kind === 'reply' && (
      this.state.deliveryState === 'sending' || this.state.deliveryState === 'deliveryUncertain'
    )) return;
    const generation = ++this.openGeneration;
    this.setState({ kind: 'connecting' });
    try {
      const cached = await this.api.unreadList(10);
      if (generation !== this.openGeneration) return;
      const list: ListState = {
        kind: 'list',
        messages: cached.messages.filter(message => !this.openedMessageIDs.has(message.id)),
        lastSuccessfulSyncAt: cached.lastSuccessfulSyncAt ?? null,
        isRefreshing: true,
        refreshError: null,
        actionError: null,
      };
      this.listSnapshot = list;
      this.setState(list);
      this.refreshCompletion = this.refresh(generation);
    } catch (error) {
      if (generation !== this.openGeneration) return;
      this.refreshCompletion = Promise.resolve();
      this.setConnectionFailure(error);
    }
  }

  async openMessage(messageID: string): Promise<void> {
    if (this.state.kind === 'reply' && (
      this.state.deliveryState === 'sending' || this.state.deliveryState === 'deliveryUncertain'
    )) return;
    const list = this.listSnapshot;
    if (!list || !list.messages.some(message => message.id === messageID)) return;
    const generation = ++this.openMessageGeneration;
    const intentGeneration = ++this.replyIntentGeneration;

    try {
      const message = await this.api.openMessage(messageID);
      this.openedMessageIDs.add(messageID);
      const currentList = this.listSnapshot ?? list;
      const updatedList: ListState = {
        ...currentList,
        messages: currentList.messages.filter(candidate => candidate.id !== messageID),
        actionError: null,
      };
      this.listSnapshot = updatedList;
      if (
        generation !== this.openMessageGeneration
        || intentGeneration !== this.replyIntentGeneration
      ) return;
      this.setState({
        kind: 'reader',
        message,
        summary: null,
        isSummarizing: false,
        summaryError: null,
        actionError: null,
      });
    } catch (error) {
      if (
        generation !== this.openMessageGeneration
        || intentGeneration !== this.replyIntentGeneration
      ) return;
      const updatedList = {
        ...(this.listSnapshot ?? list),
        actionError: errorMessage(error),
      };
      this.listSnapshot = updatedList;
      if (this.state.kind === 'list') this.setState(updatedList);
    }
  }

  async summarize(): Promise<void> {
    if (this.state.kind !== 'reader' || this.state.isSummarizing) return;
    const reader = this.state;
    this.setState({ ...reader, isSummarizing: true, summaryError: null });
    try {
      const result = await this.api.summarize(reader.message.id);
      if (this.state.kind === 'reader' && this.state.message.id === reader.message.id) {
        this.setState({
          ...this.state,
          summary: result.summary,
          isSummarizing: false,
          summaryError: null,
        });
      }
    } catch (error) {
      if (this.state.kind === 'reader' && this.state.message.id === reader.message.id) {
        this.setState({
          ...this.state,
          isSummarizing: false,
          summaryError: errorMessage(error),
        });
      }
    }
  }

  beginReply(): Promise<void> {
    if (this.state.kind !== 'reader') return Promise.resolve();
    const reader = this.state;
    if (
      this.beginReplyOperation?.messageID === reader.message.id
      && this.beginReplyOperation.generation === this.replyIntentGeneration
    ) {
      return this.beginReplyOperation.completion;
    }
    const generation = ++this.replyIntentGeneration;
    this.setState({ ...reader, actionError: null });
    const operation = this.runBeginReply(reader, generation);
    const completion = operation.finally(() => {
      if (this.beginReplyOperation?.completion === completion) {
        this.beginReplyOperation = undefined;
      }
    });
    this.beginReplyOperation = { messageID: reader.message.id, generation, completion };
    return completion;
  }

  private async runBeginReply(reader: ReaderState, generation: number): Promise<void> {
    try {
      const draft = await this.api.beginReply(reader.message.id);
      if (generation !== this.replyIntentGeneration) return;
      if (this.state.kind !== 'reader' || this.state.message.id !== reader.message.id) return;
      this.resetDraftPipeline(draft);
      this.setState({
        kind: 'reply',
        message: reader.message,
        summary: reader.summary,
        draft,
        isSaving: false,
        saveError: null,
        isDraftingWithAI: false,
        aiError: null,
        recoverySafety: 'safe',
        deliveryState: 'idle',
        sendError: null,
      });
    } catch (error) {
      if (generation !== this.replyIntentGeneration) return;
      if (this.state.kind === 'reader' && this.state.message.id === reader.message.id) {
        this.setState({ ...this.state, actionError: errorMessage(error) });
      }
    }
  }

  updateDraft(body: string): Promise<void> {
    if (this.state.kind !== 'reply') return Promise.resolve();
    if (this.state.deliveryState === 'deliveryUncertain' || this.state.deliveryState === 'sending') {
      return Promise.resolve();
    }

    const generation = this.draftSessionGeneration;
    const sequence = ++this.editSequence;
    this.pendingEdit = { body, sequence };
    this.pendingEditReady = false;
    if (this.saveTimer) clearTimeout(this.saveTimer);
    this.saveTimer = setTimeout(() => {
      if (generation !== this.draftSessionGeneration) return;
      this.saveTimer = undefined;
      this.pendingEditReady = true;
      void this.ensureSaveDrain(generation).catch(() => undefined);
    }, this.debounceMilliseconds);

    this.sendAttemptKey = undefined;
    this.setState({
      ...this.state,
      draft: { ...this.state.draft, body },
      isSaving: true,
      saveError: null,
      deliveryState: 'idle',
      sendError: null,
    });

    return new Promise<void>((resolve, reject) => {
      this.saveWaiters.push({ sequence, resolve, reject });
    });
  }

  async flush(): Promise<void> {
    const generation = this.draftSessionGeneration;
    const ai = this.activeAI;
    if (ai?.generation === generation) await ai.completion;
    if (generation !== this.draftSessionGeneration) return;
    await this.flushDraftEdits(generation);
  }

  async restoreReply(messageID: string, draftID: string): Promise<RestoreReplyResult> {
    if (this.state.kind === 'reply' && (
      this.state.deliveryState === 'sending' || this.state.deliveryState === 'deliveryUncertain'
    )) return 'ignored';
    const generation = ++this.replyIntentGeneration;
    try {
      const [message, draft] = await Promise.all([
        this.api.openMessage(messageID),
        this.api.readDraft(draftID),
      ]);
      if (generation !== this.replyIntentGeneration) return 'ignored';
      if (this.state.kind === 'reply' && (
        this.state.deliveryState === 'sending' || this.state.deliveryState === 'deliveryUncertain'
      )) return 'ignored';
      this.openedMessageIDs.add(messageID);
      if (this.listSnapshot) {
        this.listSnapshot = {
          ...this.listSnapshot,
          messages: this.listSnapshot.messages.filter(candidate => candidate.id !== messageID),
        };
      }
      this.resetDraftPipeline(draft);
      this.setState({
        kind: 'reply',
        message,
        summary: null,
        draft,
        isSaving: false,
        saveError: null,
        isDraftingWithAI: false,
        aiError: null,
        recoverySafety: 'safe',
        deliveryState: 'idle',
        sendError: null,
      });
      return 'restored';
    } catch (error) {
      if (generation !== this.replyIntentGeneration) return 'ignored';
      if (isStaleRecoveryError(error)) return 'stale';
      this.setConnectionFailure(error);
      return 'retryableFailure';
    }
  }

  draftWithAI(instruction: string): Promise<void> {
    if (this.state.kind !== 'reply' || this.state.isDraftingWithAI) return Promise.resolve();
    if (this.state.deliveryState === 'deliveryUncertain' || this.state.deliveryState === 'sending') {
      return Promise.resolve();
    }

    const generation = this.draftSessionGeneration;
    this.setState({ ...this.state, isDraftingWithAI: true, aiError: null });
    const operation = this.runDraftWithAI(instruction, generation);
    const completion = operation.finally(() => {
      if (this.activeAI?.completion === completion) this.activeAI = undefined;
    });
    this.activeAI = { generation, completion };
    return completion;
  }

  private async runDraftWithAI(instruction: string, generation: number): Promise<void> {
    let aiResultReceived = false;
    try {
      await this.flushDraftEdits(generation);
      if (!this.isCurrentDraftSession(generation)) return;
      const current = this.state;
      this.aiCallingGeneration = generation;
      let generated: DraftResult;
      try {
        generated = await this.api.draftReply(
          current.draft.id,
          current.message.id,
          instruction,
          current.draft.contentHash,
        );
      } finally {
        if (this.aiCallingGeneration === generation) this.aiCallingGeneration = undefined;
      }
      if (!this.isCurrentDraftSession(generation)) return;
      aiResultReceived = true;
      this.serverDraft = generated;
      this.sendAttemptKey = undefined;
      const visibleBody = this.pendingBody() ?? generated.body;
      this.setState({
        ...this.state,
        draft: { ...generated, body: visibleBody },
        isSaving: this.pendingEdit !== undefined || this.saveWaiters.length > 0,
        aiError: null,
        deliveryState: 'idle',
        sendError: null,
      });
      if (this.pendingEditReady && this.pendingEdit) await this.ensureSaveDrain(generation);
      if (this.isCurrentDraftSession(generation)) {
        this.setState({ ...this.state, isDraftingWithAI: false });
      }
    } catch (error) {
      if (this.aiCallingGeneration === generation) this.aiCallingGeneration = undefined;
      if (!this.isCurrentDraftSession(generation)) return;
      this.setState({
        ...this.state,
        isDraftingWithAI: false,
        aiError: aiResultReceived ? this.state.aiError : errorMessage(error),
      });
      if (this.pendingEditReady && this.pendingEdit) {
        try {
          await this.ensureSaveDrain(generation);
        } catch {
          // The draft-save state already contains the safe failure.
        }
      }
    }
  }

  sendReply(): Promise<void> {
    if (this.state.kind !== 'reply') return Promise.resolve();
    if (this.state.isDraftingWithAI) return Promise.resolve();
    if (this.state.deliveryState === 'deliveryUncertain') return Promise.resolve();
    if (this.sendInFlight) return this.sendCompletion ?? Promise.resolve();

    this.sendAttemptKey ??= this.uuid();
    const key = this.sendAttemptKey;
    const context: SendContext = {
      generation: ++this.sendAttemptGeneration,
      draftGeneration: this.draftSessionGeneration,
      draftID: this.state.draft.id,
      key,
    };
    this.sendInFlight = true;
    this.activeSendContext = context;
    this.setState({
      ...this.state,
      recoverySafety: 'blocked',
      deliveryState: 'sending',
      sendError: null,
    });
    const completion = this.performSend(context).finally(() => {
      if (this.activeSendContext?.generation !== context.generation) return;
      this.sendInFlight = false;
      this.activeSendContext = undefined;
      if (this.sendCompletion === completion) this.sendCompletion = undefined;
    });
    this.sendCompletion = completion;
    return completion;
  }

  back(): void {
    switch (this.state.kind) {
    case 'reader':
      if (this.listSnapshot) this.setState(this.listSnapshot);
      break;
    case 'reply':
      if (
        this.state.isDraftingWithAI
        || this.state.deliveryState === 'sending'
        || this.state.deliveryState === 'deliveryUncertain'
      ) break;
      {
        const generation = this.draftSessionGeneration;
        void this.flushDraftEdits(generation).then(() => {
          if (!this.isCurrentDraftSession(generation)) return;
          if (
            this.state.isDraftingWithAI
            || this.state.deliveryState === 'sending'
            || this.state.deliveryState === 'deliveryUncertain'
          ) return;
          this.setState({
            kind: 'reader',
            message: this.state.message,
            summary: this.state.summary,
            isSummarizing: false,
            summaryError: null,
            actionError: null,
          });
        }).catch(() => undefined);
      }
      break;
    case 'sent':
      if (this.listSnapshot) this.setState(this.listSnapshot);
      break;
    default:
      break;
    }
  }

  async retry(): Promise<void> {
    if (this.state.kind === 'unavailable' || this.state.kind === 'versionMismatch') {
      await this.open();
      return;
    }
    if (this.state.kind === 'reply' && this.state.deliveryState === 'failed') {
      await this.sendReply();
      return;
    }
    if (this.state.kind === 'list' && this.state.refreshError) {
      const generation = this.openGeneration;
      const refreshing = { ...this.state, isRefreshing: true, refreshError: null };
      this.listSnapshot = refreshing;
      this.setState(refreshing);
      this.refreshCompletion = this.refresh(generation);
      await this.refreshCompletion;
    }
  }

  private async refresh(generation: number): Promise<void> {
    try {
      const sync = await this.api.incrementalSync();
      const refreshed = await this.api.unreadList(10);
      if (generation !== this.openGeneration) return;
      this.updateListSnapshot({
        kind: 'list',
        messages: refreshed.messages.filter(message => !this.openedMessageIDs.has(message.id)),
        lastSuccessfulSyncAt: refreshed.lastSuccessfulSyncAt ?? null,
        isRefreshing: false,
        refreshError: sync.failedAccountIDs.length > 0
          ? 'Some accounts could not refresh.'
          : null,
        actionError: null,
      });
    } catch (error) {
      if (generation !== this.openGeneration || !this.listSnapshot) return;
      this.updateListSnapshot({
        ...this.listSnapshot,
        isRefreshing: false,
        refreshError: errorMessage(error),
      });
    }
  }

  private updateListSnapshot(list: ListState): void {
    this.listSnapshot = list;
    if (this.state.kind === 'list') this.setState(list);
  }

  private resetDraftPipeline(draft: DraftResult): void {
    this.draftSessionGeneration += 1;
    if (this.saveTimer) clearTimeout(this.saveTimer);
    this.saveTimer = undefined;
    this.pendingEdit = undefined;
    this.pendingEditReady = false;
    this.saveDrain = undefined;
    this.serverDraft = draft;
    this.aiCallingGeneration = undefined;
    this.activeAI = undefined;
    this.sendAttemptKey = undefined;
    this.sendInFlight = false;
    this.activeSendContext = undefined;
    this.sendCompletion = undefined;
    this.settleAllSaveWaiters(new Error('Draft changed.'));
  }

  private async flushDraftEdits(generation = this.draftSessionGeneration): Promise<void> {
    if (generation !== this.draftSessionGeneration) return;
    if (this.saveTimer) {
      clearTimeout(this.saveTimer);
      this.saveTimer = undefined;
    }
    if (this.pendingEdit) this.pendingEditReady = true;
    await this.ensureSaveDrain(generation);
    if (generation !== this.draftSessionGeneration) return;
    if (this.pendingEdit) {
      this.pendingEditReady = true;
      await this.ensureSaveDrain(generation);
    }
  }

  private async ensureSaveDrain(generation = this.draftSessionGeneration): Promise<void> {
    if (generation !== this.draftSessionGeneration) return;
    if (this.aiCallingGeneration === generation) return;
    if (this.saveDrain) {
      await this.saveDrain;
      if (generation !== this.draftSessionGeneration) return;
      if (this.pendingEditReady && this.pendingEdit) await this.ensureSaveDrain(generation);
      return;
    }
    if (!this.pendingEditReady || !this.pendingEdit) return;

    const drain = this.drainReadyEdits(generation);
    this.saveDrain = drain;
    try {
      await drain;
    } finally {
      if (this.saveDrain === drain) this.saveDrain = undefined;
    }
    if (generation !== this.draftSessionGeneration) return;
    if (this.pendingEditReady && this.pendingEdit) await this.ensureSaveDrain(generation);
  }

  private async drainReadyEdits(generation: number): Promise<void> {
    while (
      generation === this.draftSessionGeneration
      && this.pendingEditReady
      && this.pendingEdit
    ) {
      const edit = this.pendingEdit;
      this.pendingEdit = undefined;
      this.pendingEditReady = false;
      const draft = this.serverDraft;
      if (!draft) {
        const error = new Error('Draft is unavailable.');
        this.failDraftSaves(error, edit, generation);
        throw error;
      }

      try {
        const saved = await this.api.updateDraft(
          draft.id,
          edit.body,
          draft.contentHash,
        );
        if (generation !== this.draftSessionGeneration) return;
        this.serverDraft = saved;
        this.resolveSaveWaitersThrough(edit.sequence);
        if (this.state.kind === 'reply' && this.state.draft.id === saved.id) {
          const visibleBody = this.pendingBody() ?? saved.body;
          this.setState({
            ...this.state,
            draft: { ...saved, body: visibleBody },
            isSaving: this.pendingEdit !== undefined || this.saveWaiters.length > 0,
            saveError: null,
          });
        }
      } catch (error) {
        if (generation !== this.draftSessionGeneration) return;
        this.failDraftSaves(error, edit, generation);
        throw error;
      }
    }
  }

  private resolveSaveWaitersThrough(sequence: number): void {
    for (let index = this.saveWaiters.length - 1; index >= 0; index -= 1) {
      const waiter = this.saveWaiters[index]!;
      if (waiter.sequence <= sequence) {
        this.saveWaiters.splice(index, 1);
        waiter.resolve();
      }
    }
  }

  private pendingBody(): string | undefined {
    return this.pendingEdit?.body;
  }

  private failDraftSaves(
    reason: unknown,
    failedEdit: PendingEdit | undefined,
    generation: number,
  ): void {
    if (generation !== this.draftSessionGeneration) return;
    if (this.saveTimer) clearTimeout(this.saveTimer);
    this.saveTimer = undefined;
    this.pendingEdit ??= failedEdit;
    this.pendingEditReady = false;
    this.settleAllSaveWaiters(reason);
    if (this.state.kind === 'reply') {
      this.setState({
        ...this.state,
        isSaving: false,
        saveError: errorMessage(reason),
      });
    }
  }

  private settleAllSaveWaiters(reason: unknown): void {
    for (const waiter of this.saveWaiters.splice(0)) waiter.reject(reason);
  }

  private async performSend(context: SendContext): Promise<void> {
    let dispatchStarted = false;
    try {
      await this.flushDraftEdits(context.draftGeneration);
      if (!this.isCurrentSend(context)) return;
      dispatchStarted = true;
      const result = await this.api.sendReply(
        context.draftID,
        this.state.draft.contentHash,
        context.key,
      );
      this.applyDeliveryResult(context, result);
    } catch (error) {
      if (!this.isCurrentSend(context)) return;
      if (dispatchStarted) {
        this.setState({
          ...this.state,
          recoverySafety: 'blocked',
          deliveryState: 'deliveryUncertain',
          sendError: errorMessage(error),
        });
      } else {
        this.setState({
          ...this.state,
          recoverySafety: 'safe',
          deliveryState: 'failed',
          sendError: errorMessage(error),
        });
      }
    }
  }

  private applyDeliveryResult(context: SendContext, result: DeliveryResult): void {
    if (!this.isCurrentSend(context)) return;
    switch (result.state) {
    case 'sent':
      this.sendAttemptKey = undefined;
      this.setState({ kind: 'sent', message: this.state.message, delivery: result });
      break;
    case 'failed':
      // Swift maps both failed and cancelled terminal jobs to this receipt.
      this.sendAttemptKey = undefined;
      this.setState({
        ...this.state,
        recoverySafety: 'safe',
        deliveryState: 'failed',
        sendError: 'The reply was not sent.',
      });
      break;
    case 'deliveryUncertain':
      this.setState({
        ...this.state,
        recoverySafety: 'blocked',
        deliveryState: 'deliveryUncertain',
        sendError: 'Delivery status is uncertain.',
      });
      break;
    }
  }

  private setConnectionFailure(error: unknown): void {
    const message = errorMessage(error);
    if (error instanceof PlainpostAPIError && (
      error.code === 'CLIENT_UPDATE_REQUIRED' || error.code === 'SERVER_UPDATE_REQUIRED'
    )) {
      this.setState({ kind: 'versionMismatch', message });
      return;
    }
    this.setState({ kind: 'unavailable', message });
  }

  private isCurrentDraftSession(generation: number): this is this & { state: ReplyState } {
    return generation === this.draftSessionGeneration && this.state.kind === 'reply';
  }

  private isCurrentSend(context: SendContext): this is this & { state: ReplyState } {
    return this.activeSendContext?.generation === context.generation
      && this.draftSessionGeneration === context.draftGeneration
      && this.state.kind === 'reply'
      && this.state.draft.id === context.draftID
      && this.sendAttemptKey === context.key;
  }

  private setState(state: PopupState): void {
    this.state = state;
    for (const listener of this.listeners) listener(state);
  }
}

function errorMessage(error: unknown): string {
  if (error instanceof Error && error.message) return error.message;
  return 'Plainpost is unavailable.';
}

function isStaleRecoveryError(error: unknown): boolean {
  return error instanceof PlainpostAPIError && (
    error.code === 'NOT_FOUND'
    || error.code === 'INVALID_REQUEST'
    || error.code === 'CONFLICT'
  );
}
