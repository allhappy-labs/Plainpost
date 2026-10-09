#import <Foundation/Foundation.h>
#import <bsm/audit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PlainpostVaultAvailability) {
    PlainpostVaultAvailabilityLocked,
    PlainpostVaultAvailabilityUnlocked,
    PlainpostVaultAvailabilityKeyMissing,
    PlainpostVaultAvailabilityKeyAmbiguous,
    PlainpostVaultAvailabilityCiphertextInvalid,
    PlainpostVaultAvailabilityUnsupportedVersion,
};

typedef NS_ENUM(NSInteger, PlainpostXPCErrorCode) {
    PlainpostXPCErrorCodeVaultLocked,
    PlainpostXPCErrorCodeAuthorizationCancelled,
    PlainpostXPCErrorCodeAuthorizationFailed,
    PlainpostXPCErrorCodeVaultKeyMissing,
    PlainpostXPCErrorCodeVaultKeyAmbiguous,
    PlainpostXPCErrorCodeCiphertextInvalid,
    PlainpostXPCErrorCodeUnsupportedVaultVersion,
    PlainpostXPCErrorCodeClientUnauthorized,
    PlainpostXPCErrorCodeInvalidRequest,
    /// `detail` 0 is a generic failure; a positive `detail` is a
    /// `MailActionRefusal` raw value (an archive or delete the service refused).
    PlainpostXPCErrorCodeOperationFailed,
    PlainpostXPCErrorCodeAccountDeletionCleanupPending,
    PlainpostXPCErrorCodeAccountDeletionCompensationFailed,
    /// A Node session broker failure; `detail` carries the positive
    /// `PlainpostNodeSessionFailure` raw value.
    PlainpostXPCErrorCodeNodeSessionFailed,
};

typedef NS_ENUM(NSInteger, PlainpostForegroundOperationKind) {
    PlainpostForegroundOperationKindInboxSync,
    PlainpostForegroundOperationKindHistoricalSync,
    PlainpostForegroundOperationKindAI,
    PlainpostForegroundOperationKindTranslateMessage,
    PlainpostForegroundOperationKindApproveSend,
    PlainpostForegroundOperationKindDenySend,
    PlainpostForegroundOperationKindAccountAdd,
    PlainpostForegroundOperationKindAccountTest,
    PlainpostForegroundOperationKindReplaceAccountCredentials,
    PlainpostForegroundOperationKindDeliverDirectDraft,
    PlainpostForegroundOperationKindDeliverBrowserReply,
    PlainpostForegroundOperationKindArchive,
    PlainpostForegroundOperationKindDelete,
    PlainpostForegroundOperationKindMarkRead,
    PlainpostForegroundOperationKindMarkUnread,
    PlainpostForegroundOperationKindAddLabel,
    PlainpostForegroundOperationKindRemoveLabel,
    PlainpostForegroundOperationKindLabelCommand,
    PlainpostForegroundOperationKindDeleteAccount,
    PlainpostForegroundOperationKindGoogleAccountAdd,
    PlainpostForegroundOperationKindReplaceGoogleAccountCredential,
    PlainpostForegroundOperationKindFlag,
    PlainpostForegroundOperationKindUnflag,
    PlainpostForegroundOperationKindMove,
};

@interface PlainpostVaultStatusDTO : NSObject <NSSecureCoding>
@property (nonatomic, readonly) NSInteger schemaVersion;
@property (nonatomic, readonly) PlainpostVaultAvailability availability;
@property (nonatomic, readonly) NSInteger matchingKeyItemCount;
@property (nonatomic, readonly) NSInteger detail;
- (nullable instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                                  availability:(PlainpostVaultAvailability)availability
                          matchingKeyItemCount:(NSInteger)matchingKeyItemCount
                                        detail:(NSInteger)detail;
@end

@interface PlainpostXPCErrorDTO : NSObject <NSSecureCoding>
@property (nonatomic, readonly) NSInteger schemaVersion;
@property (nonatomic, readonly) PlainpostXPCErrorCode code;
@property (nonatomic, readonly) NSInteger detail;
- (nullable instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                                           code:(PlainpostXPCErrorCode)code
                                         detail:(NSInteger)detail;
@end

@interface PlainpostBackgroundJobResultDTO : NSObject <NSSecureCoding>
@property (nonatomic, readonly) NSInteger schemaVersion;
@property (nonatomic, readonly) NSInteger recoveredJobCount;
@property (nonatomic, readonly) NSInteger processedJobCount;
- (nullable instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                             recoveredJobCount:(NSInteger)recoveredJobCount
                             processedJobCount:(NSInteger)processedJobCount;
@end

@interface PlainpostSmartInboxBatchRequestDTO : NSObject <NSSecureCoding>
@property (nonatomic, readonly) NSInteger schemaVersion;
@property (nonatomic, copy, readonly) NSString *accountID;
@property (nonatomic, copy, readonly) NSString *category;
@property (nonatomic, copy, readonly) NSString *action;
@property (nonatomic, copy, readonly) NSString *archiveMailbox;
- (nullable instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                                      accountID:(NSString *)accountID
                                       category:(NSString *)category
                                         action:(NSString *)action
                                 archiveMailbox:(NSString *)archiveMailbox;
@end

@interface PlainpostSmartInboxBatchResultDTO : NSObject <NSSecureCoding>
@property (nonatomic, readonly) NSInteger schemaVersion;
@property (nonatomic, copy, readonly) NSString *accountID;
@property (nonatomic, copy, readonly) NSString *category;
@property (nonatomic, copy, readonly) NSString *action;
@property (nonatomic, copy, readonly) NSArray<NSString *> *affectedMessageIDs;
@property (nonatomic, copy, readonly) NSString *archiveMailbox;
- (nullable instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                                      accountID:(NSString *)accountID
                                       category:(NSString *)category
                                         action:(NSString *)action
                             affectedMessageIDs:(NSArray<NSString *> *)affectedMessageIDs
                                 archiveMailbox:(NSString *)archiveMailbox;
@end

@interface PlainpostBrowserApprovedReplyRequestDTO : NSObject <NSSecureCoding>
@property (nonatomic, readonly) NSInteger schemaVersion;
@property (nonatomic, copy, readonly) NSString *jobID;
- (nullable instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                                          jobID:(NSString *)jobID;
@end

@interface PlainpostBrowserApprovedReplyResultDTO : NSObject <NSSecureCoding>
@property (nonatomic, readonly) NSInteger schemaVersion;
@property (nonatomic, copy, readonly) NSString *requestID;
@property (nonatomic, copy, readonly) NSString *jobID;
@property (nonatomic, copy, readonly) NSString *state;
- (nullable instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                                      requestID:(NSString *)requestID
                                          jobID:(NSString *)jobID
                                          state:(NSString *)state;
@end

@interface PlainpostDraftSyncRequestDTO : NSObject <NSSecureCoding>
@property (nonatomic, readonly) NSInteger schemaVersion;
@property (nonatomic, copy, readonly) NSString *draftID;
@property (nonatomic, copy, readonly) NSString *mailbox;
- (nullable instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                                       draftID:(NSString *)draftID
                                       mailbox:(NSString *)mailbox;
@end

@interface PlainpostDraftSyncResultDTO : NSObject <NSSecureCoding>
@property (nonatomic, readonly) NSInteger schemaVersion;
@property (nonatomic, copy, readonly) NSString *draftID;
@property (nonatomic, copy, readonly) NSString *mailbox;
@property (nonatomic, readonly) NSInteger serverDraftUID;
- (nullable instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                                       draftID:(NSString *)draftID
                                       mailbox:(NSString *)mailbox
                                serverDraftUID:(NSInteger)serverDraftUID;
@end

/// Closed semantic request envelope. `archivedPayload` is bounded and is never
/// included in the object's description or debug description.
@interface PlainpostForegroundOperationRequestDTO : NSObject <NSSecureCoding>
@property (nonatomic, readonly) NSInteger schemaVersion;
@property (nonatomic, readonly) PlainpostForegroundOperationKind kind;
@property (nonatomic, copy, readonly) NSData *archivedPayload;
- (nullable instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                                           kind:(PlainpostForegroundOperationKind)kind
                                archivedPayload:(NSData *)archivedPayload;
@end

/// Closed semantic result envelope. The payload is bounded and contains no
/// account password result fields.
@interface PlainpostForegroundOperationResultDTO : NSObject <NSSecureCoding>
@property (nonatomic, readonly) NSInteger schemaVersion;
@property (nonatomic, readonly) PlainpostForegroundOperationKind kind;
@property (nonatomic, copy, readonly) NSData *archivedPayload;
- (nullable instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                                           kind:(PlainpostForegroundOperationKind)kind
                                archivedPayload:(NSData *)archivedPayload;
@end

/// One Node session request the app asks the service broker to send. The
/// body is bounded and is never included in the description.
@interface PlainpostNodeSessionRequestDTO : NSObject <NSSecureCoding>
@property (nonatomic, readonly) NSInteger schemaVersion;
@property (nonatomic, copy, readonly) NSString *method;
@property (nonatomic, copy, readonly) NSString *path;
@property (nonatomic, copy, readonly) NSData *body;
- (nullable instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                                         method:(NSString *)method
                                           path:(NSString *)path
                                           body:(NSData *)body;
@end

/// The Node's response bytes relayed to the app. Bounded; the body is never
/// included in the description.
@interface PlainpostNodeSessionResponseDTO : NSObject <NSSecureCoding>
@property (nonatomic, readonly) NSInteger schemaVersion;
@property (nonatomic, readonly) NSInteger statusCode;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, copy, readonly) NSData *body;
- (nullable instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                                     statusCode:(NSInteger)statusCode
                                        headers:(NSDictionary<NSString *, NSString *> *)headers
                                           body:(NSData *)body;
@end

/// The service's Sync Node mail-mode status. It carries a closed state
/// (`PlainpostNodeMailModeStatus.State` raw value) and two bounded counts;
/// no credential, identity, address or path.
@interface PlainpostNodeMailModeStatusDTO : NSObject <NSSecureCoding>
@property (nonatomic, readonly) NSInteger schemaVersion;
@property (nonatomic, copy, readonly) NSString *state;
@property (nonatomic, readonly) NSInteger nodeBackedAccountCount;
@property (nonatomic, readonly) NSInteger waitingIntentCount;
- (nullable instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                                         state:(NSString *)state
                        nodeBackedAccountCount:(NSInteger)nodeBackedAccountCount
                            waitingIntentCount:(NSInteger)waitingIntentCount;
@end

@protocol PlainpostServiceXPCProtocol
- (void)statusWithReply:(void (^)(PlainpostVaultStatusDTO *_Nullable status,
                                  PlainpostXPCErrorDTO *_Nullable error))reply
    NS_SWIFT_NAME(status(reply:));
- (void)unlockWithReason:(NSString *)reason
                    reply:(void (^)(PlainpostXPCErrorDTO *_Nullable error))reply
    NS_SWIFT_NAME(unlock(reason:reply:));
- (void)lockWithReply:(void (^)(PlainpostXPCErrorDTO *_Nullable error))reply
    NS_SWIFT_NAME(lock(reply:));
- (void)processBackgroundJobsWithReply:
    (void (^)(PlainpostBackgroundJobResultDTO *_Nullable result,
              PlainpostXPCErrorDTO *_Nullable error))reply
    NS_SWIFT_NAME(processBackgroundJobs(reply:));
- (void)performSmartInboxBatch:
    (PlainpostSmartInboxBatchRequestDTO *)request
                            reply:
    (void (^)(PlainpostSmartInboxBatchResultDTO *_Nullable result,
              PlainpostXPCErrorDTO *_Nullable error))reply
    NS_SWIFT_NAME(performSmartInboxBatch(_:reply:));
- (void)sendBrowserApprovedReply:
    (PlainpostBrowserApprovedReplyRequestDTO *)request
                              reply:
    (void (^)(PlainpostBrowserApprovedReplyResultDTO *_Nullable result,
              PlainpostXPCErrorDTO *_Nullable error))reply
    NS_SWIFT_NAME(sendBrowserApprovedReply(_:reply:));
- (void)syncDraftToServer:
    (PlainpostDraftSyncRequestDTO *)request
                       reply:
    (void (^)(PlainpostDraftSyncResultDTO *_Nullable result,
              PlainpostXPCErrorDTO *_Nullable error))reply
    NS_SWIFT_NAME(syncDraftToServer(_:reply:));
- (void)performForegroundOperation:
    (PlainpostForegroundOperationRequestDTO *)request
                                  reply:
    (void (^)(PlainpostForegroundOperationResultDTO *_Nullable result,
              PlainpostXPCErrorDTO *_Nullable error))reply
    NS_SWIFT_NAME(performForegroundOperation(_:reply:));
- (void)performNodeSessionRequest:
    (PlainpostNodeSessionRequestDTO *)request
                            reply:
    (void (^)(PlainpostNodeSessionResponseDTO *_Nullable response,
              PlainpostXPCErrorDTO *_Nullable error))reply
    NS_SWIFT_NAME(performNodeSessionRequest(_:reply:));
- (void)invalidateNodeSessionWithReply:
    (void (^)(PlainpostXPCErrorDTO *_Nullable error))reply
    NS_SWIFT_NAME(invalidateNodeSession(reply:));
/// Replies with a `PlainpostNodeSessionIdentityReadiness` raw value.
- (void)nodeSessionIdentityReadinessWithReply:
    (void (^)(NSString *_Nullable readiness,
              PlainpostXPCErrorDTO *_Nullable error))reply
    NS_SWIFT_NAME(nodeSessionIdentityReadiness(reply:));
/// The service's Sync Node mail-mode status (app only).
- (void)nodeMailModeStatusWithReply:
    (void (^)(PlainpostNodeMailModeStatusDTO *_Nullable status,
              PlainpostXPCErrorDTO *_Nullable error))reply
    NS_SWIFT_NAME(nodeMailModeStatus(reply:));
/// The service's own bundle path and build stamp, captured when it
/// launched (app only). Lets the app tell its own service from another
/// installation's, or from a stale build still running replaced files.
- (void)serviceIdentityWithReply:
    (void (^)(NSString *_Nullable bundlePath,
              NSString *_Nullable buildStamp,
              PlainpostXPCErrorDTO *_Nullable error))reply
    NS_SWIFT_NAME(serviceIdentity(reply:));
/// "Start Over with Saved Sign-ins" (app only): when the vault key is gone
/// for good, archives the saved sign-ins it can no longer open and unlocks a
/// fresh vault. Refused unless no vault key item exists.
- (void)startOverAfterVaultKeyLossWithReason:(NSString *)reason
                                        reply:(void (^)(PlainpostXPCErrorDTO *_Nullable error))reply
    NS_SWIFT_NAME(startOverAfterVaultKeyLoss(reason:reply:));
@end

/// Defensive Objective-C bridge for the private audit-token KVC surface.
@interface PlainpostXPCConnectionAuditTokenBridge : NSObject
+ (nullable NSData *)auditTokenDataForConnection:(NSXPCConnection *)connection;
+ (nullable NSData *)auditTokenDataForObject:(id)object;
+ (NSUInteger)auditTokenSize;
@end

/// Configures class objects at the Objective-C NSXPC boundary.
@interface PlainpostXPCInterfaceConfiguration : NSObject
+ (void)configureServiceInterface:(NSXPCInterface *)interface;
@end

NS_ASSUME_NONNULL_END
