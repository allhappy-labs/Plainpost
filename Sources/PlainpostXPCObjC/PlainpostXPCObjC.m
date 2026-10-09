#import "PlainpostXPCObjC.h"
#import <math.h>

static const NSInteger PlainpostXPCSchemaVersion = 1;
static const NSUInteger PlainpostXPCPayloadLimit = 262144;
static const NSUInteger PlainpostXPCCollectionLimit = 1024;
static const NSUInteger PlainpostNodeSessionMethodLimit = 16;
static const NSUInteger PlainpostNodeSessionPathLimit = 2048;
static const NSUInteger PlainpostNodeSessionRequestBodyLimit = 1048576;
static const NSUInteger PlainpostNodeSessionResponseBodyLimit = 8 * 1048576;
static const NSUInteger PlainpostNodeSessionHeaderCountLimit = 64;
static const NSUInteger PlainpostNodeSessionHeaderFieldLimit = 8192;

static BOOL PlainpostValidSchemaVersion(NSInteger schemaVersion) {
    return schemaVersion == PlainpostXPCSchemaVersion;
}

static BOOL PlainpostValidAvailability(PlainpostVaultAvailability availability) {
    switch (availability) {
        case PlainpostVaultAvailabilityLocked:
        case PlainpostVaultAvailabilityUnlocked:
        case PlainpostVaultAvailabilityKeyMissing:
        case PlainpostVaultAvailabilityKeyAmbiguous:
        case PlainpostVaultAvailabilityCiphertextInvalid:
        case PlainpostVaultAvailabilityUnsupportedVersion:
            return YES;
    }
    return NO;
}

static BOOL PlainpostValidErrorCode(PlainpostXPCErrorCode code) {
    switch (code) {
        case PlainpostXPCErrorCodeVaultLocked:
        case PlainpostXPCErrorCodeAuthorizationCancelled:
        case PlainpostXPCErrorCodeAuthorizationFailed:
        case PlainpostXPCErrorCodeVaultKeyMissing:
        case PlainpostXPCErrorCodeVaultKeyAmbiguous:
        case PlainpostXPCErrorCodeCiphertextInvalid:
        case PlainpostXPCErrorCodeUnsupportedVaultVersion:
        case PlainpostXPCErrorCodeClientUnauthorized:
        case PlainpostXPCErrorCodeInvalidRequest:
        case PlainpostXPCErrorCodeOperationFailed:
        case PlainpostXPCErrorCodeAccountDeletionCleanupPending:
        case PlainpostXPCErrorCodeAccountDeletionCompensationFailed:
        case PlainpostXPCErrorCodeNodeSessionFailed:
            return YES;
    }
    return NO;
}

static BOOL PlainpostValidForegroundOperationKind(
    PlainpostForegroundOperationKind kind
) {
    switch (kind) {
        case PlainpostForegroundOperationKindInboxSync:
        case PlainpostForegroundOperationKindHistoricalSync:
        case PlainpostForegroundOperationKindAI:
        case PlainpostForegroundOperationKindTranslateMessage:
        case PlainpostForegroundOperationKindApproveSend:
        case PlainpostForegroundOperationKindDenySend:
        case PlainpostForegroundOperationKindAccountAdd:
        case PlainpostForegroundOperationKindAccountTest:
        case PlainpostForegroundOperationKindReplaceAccountCredentials:
        case PlainpostForegroundOperationKindDeliverDirectDraft:
        case PlainpostForegroundOperationKindDeliverBrowserReply:
        case PlainpostForegroundOperationKindArchive:
        case PlainpostForegroundOperationKindDelete:
        case PlainpostForegroundOperationKindMarkRead:
        case PlainpostForegroundOperationKindMarkUnread:
        case PlainpostForegroundOperationKindAddLabel:
        case PlainpostForegroundOperationKindRemoveLabel:
        case PlainpostForegroundOperationKindLabelCommand:
        case PlainpostForegroundOperationKindDeleteAccount:
        case PlainpostForegroundOperationKindGoogleAccountAdd:
        case PlainpostForegroundOperationKindFlag:
        case PlainpostForegroundOperationKindUnflag:
        case PlainpostForegroundOperationKindMove:
        case PlainpostForegroundOperationKindReplaceGoogleAccountCredential:
            return YES;
    }
    return NO;
}

static BOOL PlainpostValidDetail(NSInteger detail, BOOL requiresDetail) {
    return requiresDetail ? detail > 0 : detail == 0;
}

static BOOL PlainpostAddPayloadSize(NSUInteger *total, NSUInteger value) {
    if (value > PlainpostXPCPayloadLimit || *total > PlainpostXPCPayloadLimit - value) {
        return NO;
    }
    *total += value;
    return YES;
}

static BOOL PlainpostAddStringPayloadSize(
    NSUInteger *total,
    NSString *value,
    BOOL required
) {
    if (!value) {
        return !required;
    }
    NSUInteger length = [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (required && length == 0) {
        return NO;
    }
    return PlainpostAddPayloadSize(total, length);
}

static BOOL PlainpostValidStableIdentifier(NSString *value) {
    NSUInteger payloadSize = 0;
    if (!PlainpostAddStringPayloadSize(&payloadSize, value, YES) ||
        payloadSize > 1024 ||
        ![value isEqualToString:
            [value stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet]]) {
        return NO;
    }
    return [value rangeOfCharacterFromSet:
        NSCharacterSet.controlCharacterSet].location == NSNotFound;
}

@implementation PlainpostVaultStatusDTO

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                         availability:(PlainpostVaultAvailability)availability
                 matchingKeyItemCount:(NSInteger)matchingKeyItemCount
                               detail:(NSInteger)detail {
    if (!PlainpostValidSchemaVersion(schemaVersion) ||
        !PlainpostValidAvailability(availability) ||
        matchingKeyItemCount < 0 ||
        !PlainpostValidDetail(
            detail,
            availability == PlainpostVaultAvailabilityUnsupportedVersion
        )) {
        return nil;
    }
    self = [super init];
    if (self) {
        _schemaVersion = schemaVersion;
        _availability = availability;
        _matchingKeyItemCount = matchingKeyItemCount;
        _detail = detail;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (![coder containsValueForKey:@"schemaVersion"] ||
        ![coder containsValueForKey:@"availability"] ||
        ![coder containsValueForKey:@"matchingKeyItemCount"] ||
        ![coder containsValueForKey:@"detail"]) {
        return nil;
    }
    return [self
        initWithSchemaVersion:[coder decodeIntegerForKey:@"schemaVersion"]
        availability:[coder decodeIntegerForKey:@"availability"]
        matchingKeyItemCount:[coder decodeIntegerForKey:@"matchingKeyItemCount"]
        detail:[coder decodeIntegerForKey:@"detail"]];
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:_schemaVersion forKey:@"schemaVersion"];
    [coder encodeInteger:_availability forKey:@"availability"];
    [coder encodeInteger:_matchingKeyItemCount forKey:@"matchingKeyItemCount"];
    [coder encodeInteger:_detail forKey:@"detail"];
}

@end

@implementation PlainpostXPCErrorDTO

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                                  code:(PlainpostXPCErrorCode)code
                                detail:(NSInteger)detail {
    // OperationFailed may name a mail-action refusal (no Trash, not in Trash,
    // ...) in `detail`; 0 stays the generic failure.
    BOOL detailAllowed = code == PlainpostXPCErrorCodeOperationFailed
        ? detail >= 0
        : PlainpostValidDetail(
            detail,
            code == PlainpostXPCErrorCodeUnsupportedVaultVersion ||
                code == PlainpostXPCErrorCodeNodeSessionFailed
        );
    if (!PlainpostValidSchemaVersion(schemaVersion) ||
        !PlainpostValidErrorCode(code) ||
        !detailAllowed) {
        return nil;
    }
    self = [super init];
    if (self) {
        _schemaVersion = schemaVersion;
        _code = code;
        _detail = detail;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (![coder containsValueForKey:@"schemaVersion"] ||
        ![coder containsValueForKey:@"code"] ||
        ![coder containsValueForKey:@"detail"]) {
        return nil;
    }
    return [self
        initWithSchemaVersion:[coder decodeIntegerForKey:@"schemaVersion"]
        code:[coder decodeIntegerForKey:@"code"]
        detail:[coder decodeIntegerForKey:@"detail"]];
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:_schemaVersion forKey:@"schemaVersion"];
    [coder encodeInteger:_code forKey:@"code"];
    [coder encodeInteger:_detail forKey:@"detail"];
}

@end

@implementation PlainpostBackgroundJobResultDTO

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                    recoveredJobCount:(NSInteger)recoveredJobCount
                    processedJobCount:(NSInteger)processedJobCount {
    if (!PlainpostValidSchemaVersion(schemaVersion) ||
        recoveredJobCount < 0 ||
        processedJobCount < 0) {
        return nil;
    }
    self = [super init];
    if (self) {
        _schemaVersion = schemaVersion;
        _recoveredJobCount = recoveredJobCount;
        _processedJobCount = processedJobCount;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (![coder containsValueForKey:@"schemaVersion"] ||
        ![coder containsValueForKey:@"recoveredJobCount"] ||
        ![coder containsValueForKey:@"processedJobCount"]) {
        return nil;
    }
    return [self
        initWithSchemaVersion:[coder decodeIntegerForKey:@"schemaVersion"]
        recoveredJobCount:[coder decodeIntegerForKey:@"recoveredJobCount"]
        processedJobCount:[coder decodeIntegerForKey:@"processedJobCount"]];
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:_schemaVersion forKey:@"schemaVersion"];
    [coder encodeInteger:_recoveredJobCount forKey:@"recoveredJobCount"];
    [coder encodeInteger:_processedJobCount forKey:@"processedJobCount"];
}

@end

@implementation PlainpostSmartInboxBatchRequestDTO

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                             accountID:(NSString *)accountID
                              category:(NSString *)category
                                action:(NSString *)action
                        archiveMailbox:(NSString *)archiveMailbox {
    NSString *immutableAccountID = [accountID copy];
    NSString *immutableCategory = [category copy];
    NSString *immutableAction = [action copy];
    NSString *immutableArchiveMailbox = [archiveMailbox copy];
    NSUInteger payloadSize = 0;
    if (!PlainpostValidSchemaVersion(schemaVersion) ||
        !PlainpostValidStableIdentifier(immutableAccountID) ||
        !PlainpostValidStableIdentifier(immutableCategory) ||
        !PlainpostValidStableIdentifier(immutableAction) ||
        !PlainpostValidStableIdentifier(immutableArchiveMailbox) ||
        !PlainpostAddStringPayloadSize(
            &payloadSize,
            immutableAccountID,
            YES
        ) ||
        !PlainpostAddStringPayloadSize(
            &payloadSize,
            immutableCategory,
            YES
        ) ||
        !PlainpostAddStringPayloadSize(
            &payloadSize,
            immutableAction,
            YES
        ) ||
        !PlainpostAddStringPayloadSize(
            &payloadSize,
            immutableArchiveMailbox,
            YES
        )) {
        return nil;
    }
    self = [super init];
    if (self) {
        _schemaVersion = schemaVersion;
        _accountID = immutableAccountID;
        _category = immutableCategory;
        _action = immutableAction;
        _archiveMailbox = immutableArchiveMailbox;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (![coder containsValueForKey:@"schemaVersion"]) {
        return nil;
    }
    NSString *accountID = [coder decodeObjectOfClass:NSString.class
                                              forKey:@"accountID"];
    NSString *category = [coder decodeObjectOfClass:NSString.class
                                             forKey:@"category"];
    NSString *action = [coder decodeObjectOfClass:NSString.class
                                           forKey:@"action"];
    NSString *archiveMailbox = [coder decodeObjectOfClass:NSString.class
                                                   forKey:@"archiveMailbox"];
    if (!accountID || !category || !action || !archiveMailbox) {
        return nil;
    }
    return [self
        initWithSchemaVersion:[coder decodeIntegerForKey:@"schemaVersion"]
        accountID:accountID
        category:category
        action:action
        archiveMailbox:archiveMailbox];
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:_schemaVersion forKey:@"schemaVersion"];
    [coder encodeObject:_accountID forKey:@"accountID"];
    [coder encodeObject:_category forKey:@"category"];
    [coder encodeObject:_action forKey:@"action"];
    [coder encodeObject:_archiveMailbox forKey:@"archiveMailbox"];
}

@end

@implementation PlainpostSmartInboxBatchResultDTO

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                             accountID:(NSString *)accountID
                              category:(NSString *)category
                                action:(NSString *)action
                    affectedMessageIDs:(NSArray<NSString *> *)affectedMessageIDs
                        archiveMailbox:(NSString *)archiveMailbox {
    NSString *immutableAccountID = [accountID copy];
    NSString *immutableCategory = [category copy];
    NSString *immutableAction = [action copy];
    NSString *immutableArchiveMailbox = [archiveMailbox copy];
    NSArray *sourceMessageIDs = [affectedMessageIDs copy];
    NSMutableArray<NSString *> *immutableMessageIDs = [NSMutableArray array];
    NSUInteger payloadSize = 0;
    if (!PlainpostValidSchemaVersion(schemaVersion) ||
        !PlainpostValidStableIdentifier(immutableAccountID) ||
        !PlainpostValidStableIdentifier(immutableCategory) ||
        !PlainpostValidStableIdentifier(immutableAction) ||
        !PlainpostValidStableIdentifier(immutableArchiveMailbox) ||
        ![sourceMessageIDs isKindOfClass:NSArray.class] ||
        sourceMessageIDs.count > PlainpostXPCCollectionLimit ||
        !PlainpostAddStringPayloadSize(
            &payloadSize,
            immutableAccountID,
            YES
        ) ||
        !PlainpostAddStringPayloadSize(
            &payloadSize,
            immutableCategory,
            YES
        ) ||
        !PlainpostAddStringPayloadSize(
            &payloadSize,
            immutableAction,
            YES
        ) ||
        !PlainpostAddStringPayloadSize(
            &payloadSize,
            immutableArchiveMailbox,
            YES
        )) {
        return nil;
    }
    for (id value in sourceMessageIDs) {
        if (![value isKindOfClass:NSString.class]) {
            return nil;
        }
        NSString *immutableValue = [value copy];
        if (!PlainpostValidStableIdentifier(immutableValue) ||
            !PlainpostAddStringPayloadSize(
                &payloadSize,
                immutableValue,
                YES
            )) {
            return nil;
        }
        [immutableMessageIDs addObject:immutableValue];
    }
    self = [super init];
    if (self) {
        _schemaVersion = schemaVersion;
        _accountID = immutableAccountID;
        _category = immutableCategory;
        _action = immutableAction;
        _affectedMessageIDs = [immutableMessageIDs copy];
        _archiveMailbox = immutableArchiveMailbox;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (![coder containsValueForKey:@"schemaVersion"]) {
        return nil;
    }
    NSString *accountID = [coder decodeObjectOfClass:NSString.class
                                              forKey:@"accountID"];
    NSString *category = [coder decodeObjectOfClass:NSString.class
                                             forKey:@"category"];
    NSString *action = [coder decodeObjectOfClass:NSString.class
                                           forKey:@"action"];
    NSString *archiveMailbox = [coder decodeObjectOfClass:NSString.class
                                                   forKey:@"archiveMailbox"];
    NSSet *classes = [NSSet setWithObjects:NSArray.class, NSString.class, nil];
    NSArray<NSString *> *affectedMessageIDs =
        [coder decodeObjectOfClasses:classes forKey:@"affectedMessageIDs"];
    if (!accountID || !category || !action || !archiveMailbox ||
        !affectedMessageIDs ||
        ![affectedMessageIDs isKindOfClass:NSArray.class]) {
        return nil;
    }
    return [self
        initWithSchemaVersion:[coder decodeIntegerForKey:@"schemaVersion"]
        accountID:accountID
        category:category
        action:action
        affectedMessageIDs:affectedMessageIDs
        archiveMailbox:archiveMailbox];
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:_schemaVersion forKey:@"schemaVersion"];
    [coder encodeObject:_accountID forKey:@"accountID"];
    [coder encodeObject:_category forKey:@"category"];
    [coder encodeObject:_action forKey:@"action"];
    [coder encodeObject:_affectedMessageIDs forKey:@"affectedMessageIDs"];
    [coder encodeObject:_archiveMailbox forKey:@"archiveMailbox"];
}

@end

@implementation PlainpostBrowserApprovedReplyRequestDTO

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                                 jobID:(NSString *)jobID {
    NSString *immutableJobID = [jobID copy];
    if (!PlainpostValidSchemaVersion(schemaVersion) ||
        !PlainpostValidStableIdentifier(immutableJobID)) {
        return nil;
    }
    self = [super init];
    if (self) {
        _schemaVersion = schemaVersion;
        _jobID = immutableJobID;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (![coder containsValueForKey:@"schemaVersion"]) {
        return nil;
    }
    NSString *jobID = [coder decodeObjectOfClass:NSString.class
                                           forKey:@"jobID"];
    if (!jobID) {
        return nil;
    }
    return [self
        initWithSchemaVersion:[coder decodeIntegerForKey:@"schemaVersion"]
        jobID:jobID];
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:_schemaVersion forKey:@"schemaVersion"];
    [coder encodeObject:_jobID forKey:@"jobID"];
}

@end

@implementation PlainpostBrowserApprovedReplyResultDTO

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                             requestID:(NSString *)requestID
                                 jobID:(NSString *)jobID
                                 state:(NSString *)state {
    NSString *immutableRequestID = [requestID copy];
    NSString *immutableJobID = [jobID copy];
    NSString *immutableState = [state copy];
    if (!PlainpostValidSchemaVersion(schemaVersion) ||
        !PlainpostValidStableIdentifier(immutableRequestID) ||
        !PlainpostValidStableIdentifier(immutableJobID) ||
        !PlainpostValidStableIdentifier(immutableState)) {
        return nil;
    }
    self = [super init];
    if (self) {
        _schemaVersion = schemaVersion;
        _requestID = immutableRequestID;
        _jobID = immutableJobID;
        _state = immutableState;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (![coder containsValueForKey:@"schemaVersion"]) {
        return nil;
    }
    NSString *requestID = [coder decodeObjectOfClass:NSString.class
                                               forKey:@"requestID"];
    NSString *jobID = [coder decodeObjectOfClass:NSString.class
                                           forKey:@"jobID"];
    NSString *state = [coder decodeObjectOfClass:NSString.class
                                           forKey:@"state"];
    if (!requestID || !jobID || !state) {
        return nil;
    }
    return [self
        initWithSchemaVersion:[coder decodeIntegerForKey:@"schemaVersion"]
        requestID:requestID
        jobID:jobID
        state:state];
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:_schemaVersion forKey:@"schemaVersion"];
    [coder encodeObject:_requestID forKey:@"requestID"];
    [coder encodeObject:_jobID forKey:@"jobID"];
    [coder encodeObject:_state forKey:@"state"];
}

@end

@implementation PlainpostDraftSyncRequestDTO

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                              draftID:(NSString *)draftID
                              mailbox:(NSString *)mailbox {
    NSString *immutableDraftID = [draftID copy];
    NSString *immutableMailbox = [mailbox copy];
    if (!PlainpostValidSchemaVersion(schemaVersion) ||
        !PlainpostValidStableIdentifier(immutableDraftID) ||
        !PlainpostValidStableIdentifier(immutableMailbox)) {
        return nil;
    }
    self = [super init];
    if (self) {
        _schemaVersion = schemaVersion;
        _draftID = immutableDraftID;
        _mailbox = immutableMailbox;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (![coder containsValueForKey:@"schemaVersion"]) {
        return nil;
    }
    NSString *draftID = [coder decodeObjectOfClass:NSString.class
                                             forKey:@"draftID"];
    NSString *mailbox = [coder decodeObjectOfClass:NSString.class
                                             forKey:@"mailbox"];
    if (!draftID || !mailbox) {
        return nil;
    }
    return [self
        initWithSchemaVersion:[coder decodeIntegerForKey:@"schemaVersion"]
        draftID:draftID
        mailbox:mailbox];
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:_schemaVersion forKey:@"schemaVersion"];
    [coder encodeObject:_draftID forKey:@"draftID"];
    [coder encodeObject:_mailbox forKey:@"mailbox"];
}

@end

@implementation PlainpostDraftSyncResultDTO

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                              draftID:(NSString *)draftID
                              mailbox:(NSString *)mailbox
                       serverDraftUID:(NSInteger)serverDraftUID {
    NSString *immutableDraftID = [draftID copy];
    NSString *immutableMailbox = [mailbox copy];
    if (!PlainpostValidSchemaVersion(schemaVersion) ||
        !PlainpostValidStableIdentifier(immutableDraftID) ||
        !PlainpostValidStableIdentifier(immutableMailbox) ||
        serverDraftUID < 0) {
        return nil;
    }
    self = [super init];
    if (self) {
        _schemaVersion = schemaVersion;
        _draftID = immutableDraftID;
        _mailbox = immutableMailbox;
        _serverDraftUID = serverDraftUID;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (![coder containsValueForKey:@"schemaVersion"] ||
        ![coder containsValueForKey:@"serverDraftUID"]) {
        return nil;
    }
    NSString *draftID = [coder decodeObjectOfClass:NSString.class
                                             forKey:@"draftID"];
    NSString *mailbox = [coder decodeObjectOfClass:NSString.class
                                             forKey:@"mailbox"];
    if (!draftID || !mailbox) {
        return nil;
    }
    return [self
        initWithSchemaVersion:[coder decodeIntegerForKey:@"schemaVersion"]
        draftID:draftID
        mailbox:mailbox
        serverDraftUID:[coder decodeIntegerForKey:@"serverDraftUID"]];
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:_schemaVersion forKey:@"schemaVersion"];
    [coder encodeObject:_draftID forKey:@"draftID"];
    [coder encodeObject:_mailbox forKey:@"mailbox"];
    [coder encodeInteger:_serverDraftUID forKey:@"serverDraftUID"];
}

@end

@implementation PlainpostForegroundOperationRequestDTO

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                                  kind:(PlainpostForegroundOperationKind)kind
                       archivedPayload:(NSData *)archivedPayload {
    NSData *immutablePayload = [archivedPayload copy];
    if (!PlainpostValidSchemaVersion(schemaVersion) ||
        !PlainpostValidForegroundOperationKind(kind) ||
        !immutablePayload ||
        immutablePayload.length == 0 ||
        immutablePayload.length > PlainpostXPCPayloadLimit) {
        return nil;
    }
    self = [super init];
    if (self) {
        _schemaVersion = schemaVersion;
        _kind = kind;
        _archivedPayload = immutablePayload;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (![coder containsValueForKey:@"schemaVersion"] ||
        ![coder containsValueForKey:@"kind"]) {
        return nil;
    }
    NSData *payload = [coder decodeObjectOfClass:NSData.class
                                          forKey:@"archivedPayload"];
    if (!payload) {
        return nil;
    }
    return [self
        initWithSchemaVersion:[coder decodeIntegerForKey:@"schemaVersion"]
        kind:[coder decodeIntegerForKey:@"kind"]
        archivedPayload:payload];
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:_schemaVersion forKey:@"schemaVersion"];
    [coder encodeInteger:_kind forKey:@"kind"];
    [coder encodeObject:_archivedPayload forKey:@"archivedPayload"];
}

- (NSString *)description {
    return [NSString stringWithFormat:
        @"<PlainpostForegroundOperationRequestDTO kind=%ld payload=<redacted>>",
        (long)_kind];
}

- (NSString *)debugDescription {
    return self.description;
}

@end

@implementation PlainpostForegroundOperationResultDTO

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                                  kind:(PlainpostForegroundOperationKind)kind
                       archivedPayload:(NSData *)archivedPayload {
    NSData *immutablePayload = [archivedPayload copy];
    if (!PlainpostValidSchemaVersion(schemaVersion) ||
        !PlainpostValidForegroundOperationKind(kind) ||
        !immutablePayload ||
        immutablePayload.length == 0 ||
        immutablePayload.length > PlainpostXPCPayloadLimit) {
        return nil;
    }
    self = [super init];
    if (self) {
        _schemaVersion = schemaVersion;
        _kind = kind;
        _archivedPayload = immutablePayload;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (![coder containsValueForKey:@"schemaVersion"] ||
        ![coder containsValueForKey:@"kind"]) {
        return nil;
    }
    NSData *payload = [coder decodeObjectOfClass:NSData.class
                                          forKey:@"archivedPayload"];
    if (!payload) {
        return nil;
    }
    return [self
        initWithSchemaVersion:[coder decodeIntegerForKey:@"schemaVersion"]
        kind:[coder decodeIntegerForKey:@"kind"]
        archivedPayload:payload];
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:_schemaVersion forKey:@"schemaVersion"];
    [coder encodeInteger:_kind forKey:@"kind"];
    [coder encodeObject:_archivedPayload forKey:@"archivedPayload"];
}

- (NSString *)description {
    return [NSString stringWithFormat:
        @"<PlainpostForegroundOperationResultDTO kind=%ld payload=<redacted>>",
        (long)_kind];
}

- (NSString *)debugDescription {
    return self.description;
}

@end

static BOOL PlainpostValidNodeSessionMethod(NSString *value) {
    if (!value) {
        return NO;
    }
    NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (bytes.length == 0 || bytes.length > PlainpostNodeSessionMethodLimit) {
        return NO;
    }
    const uint8_t *raw = bytes.bytes;
    for (NSUInteger index = 0; index < bytes.length; index++) {
        if (raw[index] < 'A' || raw[index] > 'Z') {
            return NO;
        }
    }
    return YES;
}

static BOOL PlainpostValidNodeSessionPath(NSString *value) {
    if (!value) {
        return NO;
    }
    NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (bytes.length == 0 || bytes.length > PlainpostNodeSessionPathLimit) {
        return NO;
    }
    const uint8_t *raw = bytes.bytes;
    if (raw[0] != '/') {
        return NO;
    }
    for (NSUInteger index = 0; index < bytes.length; index++) {
        if (raw[index] <= 32 || raw[index] >= 127) {
            return NO;
        }
    }
    return YES;
}

static BOOL PlainpostValidNodeSessionHeaders(NSDictionary *headers) {
    if (![headers isKindOfClass:NSDictionary.class] ||
        headers.count > PlainpostNodeSessionHeaderCountLimit) {
        return NO;
    }
    __block BOOL valid = YES;
    [headers enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if (![key isKindOfClass:NSString.class] ||
            ![value isKindOfClass:NSString.class]) {
            valid = NO;
            *stop = YES;
            return;
        }
        NSUInteger keyLength = [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        NSUInteger valueLength = [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (keyLength == 0 ||
            keyLength > PlainpostNodeSessionHeaderFieldLimit ||
            valueLength > PlainpostNodeSessionHeaderFieldLimit) {
            valid = NO;
            *stop = YES;
        }
    }];
    return valid;
}

@implementation PlainpostNodeSessionRequestDTO

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                               method:(NSString *)method
                                 path:(NSString *)path
                                 body:(NSData *)body {
    NSString *immutableMethod = [method copy];
    NSString *immutablePath = [path copy];
    NSData *immutableBody = [body copy];
    if (!PlainpostValidSchemaVersion(schemaVersion) ||
        !PlainpostValidNodeSessionMethod(immutableMethod) ||
        !PlainpostValidNodeSessionPath(immutablePath) ||
        !immutableBody ||
        immutableBody.length > PlainpostNodeSessionRequestBodyLimit) {
        return nil;
    }
    self = [super init];
    if (self) {
        _schemaVersion = schemaVersion;
        _method = immutableMethod;
        _path = immutablePath;
        _body = immutableBody;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (![coder containsValueForKey:@"schemaVersion"]) {
        return nil;
    }
    NSString *method = [coder decodeObjectOfClass:NSString.class forKey:@"method"];
    NSString *path = [coder decodeObjectOfClass:NSString.class forKey:@"path"];
    NSData *body = [coder decodeObjectOfClass:NSData.class forKey:@"body"];
    if (!method || !path || !body) {
        return nil;
    }
    return [self
        initWithSchemaVersion:[coder decodeIntegerForKey:@"schemaVersion"]
        method:method
        path:path
        body:body];
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:_schemaVersion forKey:@"schemaVersion"];
    [coder encodeObject:_method forKey:@"method"];
    [coder encodeObject:_path forKey:@"path"];
    [coder encodeObject:_body forKey:@"body"];
}

- (NSString *)description {
    return [NSString stringWithFormat:
        @"<PlainpostNodeSessionRequestDTO method=%@ path=%@ body=<redacted>>",
        _method, _path];
}

- (NSString *)debugDescription {
    return self.description;
}

@end

@implementation PlainpostNodeSessionResponseDTO

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                           statusCode:(NSInteger)statusCode
                              headers:(NSDictionary<NSString *, NSString *> *)headers
                                 body:(NSData *)body {
    NSDictionary *immutableHeaders = [headers copy];
    NSData *immutableBody = [body copy];
    if (!PlainpostValidSchemaVersion(schemaVersion) ||
        statusCode < 100 || statusCode > 599 ||
        !PlainpostValidNodeSessionHeaders(immutableHeaders) ||
        !immutableBody ||
        immutableBody.length > PlainpostNodeSessionResponseBodyLimit) {
        return nil;
    }
    self = [super init];
    if (self) {
        _schemaVersion = schemaVersion;
        _statusCode = statusCode;
        _headers = immutableHeaders;
        _body = immutableBody;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (![coder containsValueForKey:@"schemaVersion"] ||
        ![coder containsValueForKey:@"statusCode"]) {
        return nil;
    }
    NSDictionary *headers = [coder
        decodeObjectOfClasses:[NSSet setWithObjects:NSDictionary.class, NSString.class, nil]
        forKey:@"headers"];
    NSData *body = [coder decodeObjectOfClass:NSData.class forKey:@"body"];
    if (!headers || !body) {
        return nil;
    }
    return [self
        initWithSchemaVersion:[coder decodeIntegerForKey:@"schemaVersion"]
        statusCode:[coder decodeIntegerForKey:@"statusCode"]
        headers:headers
        body:body];
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:_schemaVersion forKey:@"schemaVersion"];
    [coder encodeInteger:_statusCode forKey:@"statusCode"];
    [coder encodeObject:_headers forKey:@"headers"];
    [coder encodeObject:_body forKey:@"body"];
}

- (NSString *)description {
    return [NSString stringWithFormat:
        @"<PlainpostNodeSessionResponseDTO status=%ld body=<redacted>>",
        (long)_statusCode];
}

- (NSString *)debugDescription {
    return self.description;
}

@end

@implementation PlainpostNodeMailModeStatusDTO

static const NSInteger PlainpostNodeMailModeCountLimit = 1000000;

static BOOL PlainpostValidNodeMailModeState(NSString *state) {
    return [state isEqualToString:@"no_node"] ||
        [state isEqualToString:@"connected"] ||
        [state isEqualToString:@"connected_directly"] ||
        [state isEqualToString:@"update_required"] ||
        [state isEqualToString:@"reconnect_required"];
}

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithSchemaVersion:(NSInteger)schemaVersion
                                state:(NSString *)state
               nodeBackedAccountCount:(NSInteger)nodeBackedAccountCount
                   waitingIntentCount:(NSInteger)waitingIntentCount {
    NSString *immutableState = [state copy];
    if (!PlainpostValidSchemaVersion(schemaVersion) ||
        !immutableState ||
        !PlainpostValidNodeMailModeState(immutableState) ||
        nodeBackedAccountCount < 0 ||
        nodeBackedAccountCount > PlainpostNodeMailModeCountLimit ||
        waitingIntentCount < 0 ||
        waitingIntentCount > PlainpostNodeMailModeCountLimit) {
        return nil;
    }
    self = [super init];
    if (self) {
        _schemaVersion = schemaVersion;
        _state = immutableState;
        _nodeBackedAccountCount = nodeBackedAccountCount;
        _waitingIntentCount = waitingIntentCount;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (![coder containsValueForKey:@"schemaVersion"] ||
        ![coder containsValueForKey:@"nodeBackedAccountCount"] ||
        ![coder containsValueForKey:@"waitingIntentCount"]) {
        return nil;
    }
    NSString *state = [coder decodeObjectOfClass:NSString.class forKey:@"state"];
    if (!state) {
        return nil;
    }
    return [self
        initWithSchemaVersion:[coder decodeIntegerForKey:@"schemaVersion"]
        state:state
        nodeBackedAccountCount:[coder decodeIntegerForKey:@"nodeBackedAccountCount"]
        waitingIntentCount:[coder decodeIntegerForKey:@"waitingIntentCount"]];
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:_schemaVersion forKey:@"schemaVersion"];
    [coder encodeObject:_state forKey:@"state"];
    [coder encodeInteger:_nodeBackedAccountCount forKey:@"nodeBackedAccountCount"];
    [coder encodeInteger:_waitingIntentCount forKey:@"waitingIntentCount"];
}

- (NSString *)description {
    return [NSString stringWithFormat:
        @"<PlainpostNodeMailModeStatusDTO state=%@ nodeBackedAccountCount=%ld waitingIntentCount=%ld>",
        _state, (long)_nodeBackedAccountCount, (long)_waitingIntentCount];
}

- (NSString *)debugDescription {
    return self.description;
}

@end

@implementation PlainpostXPCConnectionAuditTokenBridge

+ (NSUInteger)auditTokenSize {
    return sizeof(audit_token_t);
}

+ (NSData *)auditTokenDataForConnection:(NSXPCConnection *)connection {
    return [self auditTokenDataForObject:connection];
}

+ (NSData *)auditTokenDataForObject:(id)object {
    @try {
        SEL selector = NSSelectorFromString(@"auditToken");
        if (![object respondsToSelector:selector]) {
            return nil;
        }
        id value = [object valueForKey:@"auditToken"];
        if (![value isKindOfClass:NSValue.class]) {
            return nil;
        }
        NSValue *tokenValue = value;
        if (strcmp(tokenValue.objCType, @encode(audit_token_t)) != 0) {
            return nil;
        }
        audit_token_t token;
        [tokenValue getValue:&token];
        return [NSData dataWithBytes:&token length:sizeof(token)];
    } @catch (NSException *exception) {
        return nil;
    }
}

@end

@implementation PlainpostXPCInterfaceConfiguration

+ (void)configureServiceInterface:(NSXPCInterface *)interface {
    [interface
        setClasses:[NSSet setWithObject:PlainpostBackgroundJobResultDTO.class]
        forSelector:@selector(processBackgroundJobsWithReply:)
        argumentIndex:0
        ofReply:YES];
    [interface
        setClasses:[NSSet setWithObject:PlainpostSmartInboxBatchRequestDTO.class]
        forSelector:@selector(performSmartInboxBatch:reply:)
        argumentIndex:0
        ofReply:NO];
    [interface
        setClasses:[NSSet setWithObjects:
            NSArray.class,
            NSString.class,
            PlainpostSmartInboxBatchResultDTO.class,
            nil]
        forSelector:@selector(performSmartInboxBatch:reply:)
        argumentIndex:0
        ofReply:YES];
    [interface
        setClasses:[NSSet setWithObject:PlainpostBrowserApprovedReplyRequestDTO.class]
        forSelector:@selector(sendBrowserApprovedReply:reply:)
        argumentIndex:0
        ofReply:NO];
    [interface
        setClasses:[NSSet setWithObject:PlainpostBrowserApprovedReplyResultDTO.class]
        forSelector:@selector(sendBrowserApprovedReply:reply:)
        argumentIndex:0
        ofReply:YES];
    [interface
        setClasses:[NSSet setWithObject:PlainpostDraftSyncRequestDTO.class]
        forSelector:@selector(syncDraftToServer:reply:)
        argumentIndex:0
        ofReply:NO];
    [interface
        setClasses:[NSSet setWithObject:PlainpostDraftSyncResultDTO.class]
        forSelector:@selector(syncDraftToServer:reply:)
        argumentIndex:0
        ofReply:YES];
    [interface
        setClasses:[NSSet setWithObject:PlainpostForegroundOperationRequestDTO.class]
        forSelector:@selector(performForegroundOperation:reply:)
        argumentIndex:0
        ofReply:NO];
    [interface
        setClasses:[NSSet setWithObject:PlainpostForegroundOperationResultDTO.class]
        forSelector:@selector(performForegroundOperation:reply:)
        argumentIndex:0
        ofReply:YES];
    [interface
        setClasses:[NSSet setWithObjects:
            NSData.class,
            NSString.class,
            PlainpostNodeSessionRequestDTO.class,
            nil]
        forSelector:@selector(performNodeSessionRequest:reply:)
        argumentIndex:0
        ofReply:NO];
    [interface
        setClasses:[NSSet setWithObjects:
            NSData.class,
            NSDictionary.class,
            NSString.class,
            PlainpostNodeSessionResponseDTO.class,
            nil]
        forSelector:@selector(performNodeSessionRequest:reply:)
        argumentIndex:0
        ofReply:YES];
    [interface
        setClasses:[NSSet setWithObject:NSString.class]
        forSelector:@selector(nodeSessionIdentityReadinessWithReply:)
        argumentIndex:0
        ofReply:YES];
    [interface
        setClasses:[NSSet setWithObjects:
            NSString.class,
            PlainpostNodeMailModeStatusDTO.class,
            nil]
        forSelector:@selector(nodeMailModeStatusWithReply:)
        argumentIndex:0
        ofReply:YES];
    [interface
        setClasses:[NSSet setWithObject:NSString.class]
        forSelector:@selector(serviceIdentityWithReply:)
        argumentIndex:0
        ofReply:YES];
    [interface
        setClasses:[NSSet setWithObject:NSString.class]
        forSelector:@selector(serviceIdentityWithReply:)
        argumentIndex:1
        ofReply:YES];
}

@end
