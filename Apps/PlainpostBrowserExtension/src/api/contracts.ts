export const LOCAL_API_VERSION = 1 as const;

export const localAPIMethods = [
  'session.status',
  'mail.unreadList',
  'mail.open',
  'sync.incrementalAll',
  'ai.summarize',
  'reply.begin',
  'draft.read',
  'draft.update',
  'ai.draftReply',
  'reply.send',
] as const;

export type LocalAPIMethod = (typeof localAPIMethods)[number];

export const localAPIErrorCodes = [
  'INVALID_REQUEST',
  'PERMISSION_DENIED',
  'NOT_FOUND',
  'CONFLICT',
  'UNAVAILABLE',
  'CLIENT_UPDATE_REQUIRED',
  'SERVER_UPDATE_REQUIRED',
  'DELIVERY_UNCERTAIN',
  'OPERATION_FAILED',
] as const;

export type LocalAPIErrorCode = (typeof localAPIErrorCodes)[number];

export interface SessionStatus {
  ready: boolean;
}

export interface UnreadMessage {
  id: string;
  sender: string;
  senderName?: string | null;
  subject: string;
  preview: string;
  sentAt?: string | null;
}

export interface UnreadListResult {
  messages: UnreadMessage[];
  lastSuccessfulSyncAt?: string | null;
}

export interface MessageDetail {
  id: string;
  threadID?: string | null;
  sender: string;
  senderName?: string | null;
  subject: string;
  bodyPlain: string;
  isSeen: boolean;
}

export interface SyncResult {
  completedAccountIDs: string[];
  failedAccountIDs: string[];
  newMessageCount: number;
}

export interface SummaryResult {
  summary: string;
}

export interface DraftResult {
  id: string;
  subject: string;
  to: string[];
  body: string;
  contentHash: string;
  aiGenerated: boolean;
}

export type DeliveryState = 'sent' | 'failed' | 'deliveryUncertain';

export interface DeliveryResult {
  requestID: string;
  jobID: string;
  state: DeliveryState;
}

export interface LocalAPIParameterMap {
  'session.status': Record<string, never>;
  'mail.unreadList': { limit: number };
  'mail.open': { messageID: string };
  'sync.incrementalAll': Record<string, never>;
  'ai.summarize': { messageID: string };
  'reply.begin': { messageID: string };
  'draft.read': { draftID: string };
  'draft.update': { draftID: string; body: string; expectedHash: string };
  'ai.draftReply': {
    draftID: string;
    messageID: string;
    instruction: string;
    expectedHash: string;
  };
  'reply.send': { draftID: string; expectedHash: string; idempotencyKey: string };
}

export interface LocalAPIResultMap {
  'session.status': SessionStatus;
  'mail.unreadList': UnreadListResult;
  'mail.open': MessageDetail;
  'sync.incrementalAll': SyncResult;
  'ai.summarize': SummaryResult;
  'reply.begin': DraftResult;
  'draft.read': DraftResult;
  'draft.update': DraftResult;
  'ai.draftReply': DraftResult;
  'reply.send': DeliveryResult;
}

export interface LocalAPIRequest<M extends LocalAPIMethod = LocalAPIMethod> {
  apiVersion: typeof LOCAL_API_VERSION;
  requestID: string;
  method: M;
  parameters: LocalAPIParameterMap[M];
}

export interface LocalAPISuccess<Result = unknown> {
  apiVersion: number;
  requestID: string;
  ok: true;
  result: Result;
}

export interface LocalAPIFailure {
  apiVersion: number;
  requestID?: string | null;
  ok: false;
  error: {
    code: LocalAPIErrorCode;
    message: string;
  };
}

export type LocalAPIResponse = LocalAPISuccess | LocalAPIFailure;

export interface PlainpostBackgroundError {
  code: LocalAPIErrorCode;
  message: string;
}

export type PlainpostBackgroundResponse<Result = unknown> =
  | { ok: true; result: Result }
  | { ok: false; error: PlainpostBackgroundError };

export type PlainpostPopupRequest<M extends LocalAPIMethod = LocalAPIMethod> = {
  type: 'plainpost.request';
  method: M;
  parameters: LocalAPIParameterMap[M];
};

export interface PlainpostClient {
  sessionStatus(): Promise<SessionStatus>;
  unreadList(limit?: number): Promise<UnreadListResult>;
  openMessage(messageID: string): Promise<MessageDetail>;
  incrementalSync(): Promise<SyncResult>;
  summarize(messageID: string): Promise<SummaryResult>;
  beginReply(messageID: string): Promise<DraftResult>;
  readDraft(draftID: string): Promise<DraftResult>;
  updateDraft(draftID: string, body: string, expectedHash: string): Promise<DraftResult>;
  draftReply(
    draftID: string,
    messageID: string,
    instruction: string,
    expectedHash: string,
  ): Promise<DraftResult>;
  sendReply(draftID: string, expectedHash: string, idempotencyKey: string): Promise<DeliveryResult>;
}
