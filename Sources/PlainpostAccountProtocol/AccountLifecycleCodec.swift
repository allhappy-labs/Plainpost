import Foundation

public extension AccountWireCodec {
    static func encodeStepUpRequest(_ value: AccountStepUpRequestV1) throws -> Data {
        try LifecycleWire.encode([
            "kind": "account.step-up-request.v1", "accountID": value.accountID.rawValue,
            "actorDeviceID": value.actorDeviceID.rawValue, "targetDeviceID": value.targetDeviceID.map { $0.rawValue as Any } ?? NSNull(),
            "action": value.action.rawValue, "currentCommitDigest": encodeBase64URL(value.currentCommitDigest),
            "requestNonce": encodeBase64URL(value.requestNonce), "appleNonce": encodeBase64URL(value.appleNonce),
            "identityToken": value.identityToken,
        ])
    }

    static func decodeStepUpRequest(_ data: Data) throws -> AccountStepUpRequestV1 {
        let object = try LifecycleWire.object(data, exact: ["kind", "accountID", "actorDeviceID", "targetDeviceID", "action", "currentCommitDigest", "requestNonce", "appleNonce", "identityToken"])
        guard try LifecycleWire.string(object, "kind") == "account.step-up-request.v1", let action = AccountLifecycleAction(rawValue: try LifecycleWire.string(object, "action")) else { throw AccountProtocolError.malformedWire }
        let value = try AccountStepUpRequestV1(accountID: PlainpostAccountID(try LifecycleWire.string(object, "accountID")), actorDeviceID: AccountDeviceID(try LifecycleWire.string(object, "actorDeviceID")), targetDeviceID: try LifecycleWire.optionalID(object, "targetDeviceID"), action: action, currentCommitDigest: decodeBase64URL(try LifecycleWire.string(object, "currentCommitDigest"), exactBytes: 32), requestNonce: decodeBase64URL(try LifecycleWire.string(object, "requestNonce"), exactBytes: 32), appleNonce: decodeBase64URL(try LifecycleWire.string(object, "appleNonce"), exactBytes: 32), identityToken: try LifecycleWire.string(object, "identityToken"))
        try LifecycleWire.requireCanonical(data, encodeStepUpRequest(value))
        return value
    }

    static func encodeStepUpAuthorization(_ value: AccountStepUpAuthorizationV1) throws -> Data { try LifecycleWire.encode(stepUpAuthorizationObject(value)) }
    static func decodeStepUpAuthorization(_ data: Data) throws -> AccountStepUpAuthorizationV1 {
        let value = try decodeStepUpAuthorizationObject(LifecycleWire.object(data, exact: LifecycleWire.stepUpFields))
        try LifecycleWire.requireCanonical(data, encodeStepUpAuthorization(value)); return value
    }

    static func encodeLifecycleSubmission(_ value: AccountLifecycleSubmissionV1) throws -> Data {
        let submission = try submissionObject(value.entry)
        return try LifecycleWire.encode(["kind": "account.lifecycle-submission.v1", "authorization": stepUpAuthorizationObject(value.authorization), "submission": submission])
    }
    static func decodeLifecycleSubmission(_ data: Data) throws -> AccountLifecycleSubmissionV1 {
        let object = try LifecycleWire.object(data, exact: ["kind", "authorization", "submission"])
        guard try LifecycleWire.string(object, "kind") == "account.lifecycle-submission.v1" else { throw AccountProtocolError.malformedWire }
        let authorization = try decodeStepUpAuthorizationObject(LifecycleWire.nested(object, "authorization", exact: LifecycleWire.stepUpFields))
        let entry = try decodeSubmissionObject(LifecycleWire.nested(object, "submission", exact: ["kind", "commit", "evidence"]))
        let value = try AccountLifecycleSubmissionV1(authorization: authorization, entry: entry)
        try LifecycleWire.requireCanonical(data, encodeLifecycleSubmission(value)); return value
    }

    static func encodeDeletionRequest(_ value: AccountDeletionRequestV1) throws -> Data {
        try LifecycleWire.encode(["kind": "account.deletion-request.v1", "accountID": value.accountID.rawValue, "headCommitDigest": encodeBase64URL(value.headCommitDigest), "authorization": stepUpAuthorizationObject(value.authorization)])
    }
    static func decodeDeletionRequest(_ data: Data) throws -> AccountDeletionRequestV1 {
        let object = try LifecycleWire.object(data, exact: ["kind", "accountID", "headCommitDigest", "authorization"])
        guard try LifecycleWire.string(object, "kind") == "account.deletion-request.v1" else { throw AccountProtocolError.malformedWire }
        let value = try AccountDeletionRequestV1(accountID: PlainpostAccountID(try LifecycleWire.string(object, "accountID")), headCommitDigest: decodeBase64URL(try LifecycleWire.string(object, "headCommitDigest"), exactBytes: 32), authorization: decodeStepUpAuthorizationObject(LifecycleWire.nested(object, "authorization", exact: LifecycleWire.stepUpFields)))
        try LifecycleWire.requireCanonical(data, encodeDeletionRequest(value)); return value
    }

    static func decodeDeletionResult(_ data: Data) throws -> AccountDeletionResultV1 {
        let object = try LifecycleWire.object(data, exact: ["kind", "accountID", "deletionGeneration", "centralStatus", "centralBackupExpiresAt", "targets", "deletedAt"])
        guard try LifecycleWire.string(object, "kind") == "account.deletion-result.v1", try LifecycleWire.string(object, "centralStatus") == "deleted" else { throw AccountProtocolError.malformedWire }
        let rawTargets = try LifecycleWire.array(object, "targets", maximumCount: 16)
        let targets = try rawTargets.map { item -> AccountCleanupTargetStatusV1 in
            let target = try LifecycleWire.object(item, exact: ["handle", "kind", "status"])
            guard let kind = AccountCleanupTargetKind(rawValue: try LifecycleWire.string(target, "kind")), let status = AccountCleanupStatus(rawValue: try LifecycleWire.string(target, "status")) else { throw AccountProtocolError.malformedWire }
            return try AccountCleanupTargetStatusV1(handle: decodeBase64URL(try LifecycleWire.string(target, "handle"), exactBytes: 32), kind: kind, status: status)
        }
        let value = try AccountDeletionResultV1(accountID: PlainpostAccountID(try LifecycleWire.string(object, "accountID")), deletionGeneration: PositiveUInt64(wire: try LifecycleWire.string(object, "deletionGeneration")), centralBackupExpiresAt: try LifecycleWire.string(object, "centralBackupExpiresAt"), targets: targets, deletedAt: try LifecycleWire.string(object, "deletedAt"))
        try LifecycleWire.requireCanonical(data, encodeDeletionResult(value)); return value
    }
    static func encodeDeletionResult(_ value: AccountDeletionResultV1) throws -> Data {
        try LifecycleWire.encode(["kind": "account.deletion-result.v1", "accountID": value.accountID.rawValue, "deletionGeneration": value.deletionGeneration.wireValue, "centralStatus": "deleted", "centralBackupExpiresAt": value.centralBackupExpiresAt, "targets": value.targets.map { ["handle": encodeBase64URL($0.handle), "kind": $0.kind.rawValue, "status": $0.status.rawValue] }, "deletedAt": value.deletedAt])
    }

    static func encodeCleanupCheck(_ value: AccountCleanupCheckV1) throws -> Data { try LifecycleWire.encode(["kind": "account.cleanup-check.v1", "targetHandle": encodeBase64URL(value.targetHandle), "deletionGeneration": value.deletionGeneration.wireValue, "cleanupCredential": encodeBase64URL(value.cleanupCredential)]) }
    static func encodeCleanupRegistration(_ value: AccountCleanupRegistrationV1) throws -> Data { try LifecycleWire.encode(["kind": "account.cleanup-registration.v1", "targetHandle": encodeBase64URL(value.targetHandle), "targetKind": value.targetKind.rawValue, "cleanupCredentialDigest": encodeBase64URL(value.cleanupCredentialDigest)]) }
    static func decodeCleanupRegistration(_ data: Data) throws -> AccountCleanupRegistrationV1 {
        let object = try LifecycleWire.object(data, exact: ["kind", "targetHandle", "targetKind", "cleanupCredentialDigest"])
        guard try LifecycleWire.string(object, "kind") == "account.cleanup-registration.v1",
              let kind = AccountCleanupTargetKind(rawValue: try LifecycleWire.string(object, "targetKind"))
        else { throw AccountProtocolError.malformedWire }
        let value = try AccountCleanupRegistrationV1(targetHandle: decodeBase64URL(try LifecycleWire.string(object, "targetHandle"), exactBytes: 32), targetKind: kind, cleanupCredentialDigest: decodeBase64URL(try LifecycleWire.string(object, "cleanupCredentialDigest"), exactBytes: 32))
        try LifecycleWire.requireCanonical(data, encodeCleanupRegistration(value)); return value
    }
    static func encodeCleanupRegistrationReceipt(_ value: AccountCleanupRegistrationReceiptV1) throws -> Data { try LifecycleWire.encode(["kind": "account.cleanup-registration-receipt.v1", "targetHandle": encodeBase64URL(value.targetHandle), "nextDeletionGeneration": value.nextDeletionGeneration.wireValue]) }
    static func decodeCleanupRegistrationReceipt(_ data: Data) throws -> AccountCleanupRegistrationReceiptV1 {
        let object = try LifecycleWire.object(data, exact: ["kind", "targetHandle", "nextDeletionGeneration"])
        guard try LifecycleWire.string(object, "kind") == "account.cleanup-registration-receipt.v1" else { throw AccountProtocolError.malformedWire }
        let value = try AccountCleanupRegistrationReceiptV1(targetHandle: decodeBase64URL(try LifecycleWire.string(object, "targetHandle"), exactBytes: 32), nextDeletionGeneration: PositiveUInt64(wire: try LifecycleWire.string(object, "nextDeletionGeneration")))
        try LifecycleWire.requireCanonical(data, encodeCleanupRegistrationReceipt(value)); return value
    }
    static func decodeCleanupDirective(_ data: Data) throws -> AccountCleanupDirectiveV1 {
        let object = try LifecycleWire.object(data, exact: ["kind", "targetHandle", "deletionGeneration", "targetKind", "status", "centralBackupExpiresAt"])
        guard try LifecycleWire.string(object, "kind") == "account.cleanup-directive.v1", let kind = AccountCleanupTargetKind(rawValue: try LifecycleWire.string(object, "targetKind")), let status = AccountCleanupStatus(rawValue: try LifecycleWire.string(object, "status")) else { throw AccountProtocolError.malformedWire }
        let value = try AccountCleanupDirectiveV1(targetHandle: decodeBase64URL(try LifecycleWire.string(object, "targetHandle"), exactBytes: 32), deletionGeneration: PositiveUInt64(wire: try LifecycleWire.string(object, "deletionGeneration")), targetKind: kind, status: status, centralBackupExpiresAt: try LifecycleWire.string(object, "centralBackupExpiresAt"))
        try LifecycleWire.requireCanonical(data, encodeCleanupDirective(value)); return value
    }
    static func encodeCleanupDirective(_ value: AccountCleanupDirectiveV1) throws -> Data { try LifecycleWire.encode(["kind": "account.cleanup-directive.v1", "targetHandle": encodeBase64URL(value.targetHandle), "deletionGeneration": value.deletionGeneration.wireValue, "targetKind": value.targetKind.rawValue, "status": value.status.rawValue, "centralBackupExpiresAt": value.centralBackupExpiresAt]) }
    static func encodeCleanupAcknowledgement(_ value: AccountCleanupAcknowledgementV1) throws -> Data { try LifecycleWire.encode(["kind": "account.cleanup-ack.v1", "targetHandle": encodeBase64URL(value.targetHandle), "deletionGeneration": value.deletionGeneration.wireValue, "resultDigest": encodeBase64URL(value.resultDigest)]) }

    static func decodeSecurityEventPage(_ data: Data) throws -> AccountSecurityEventPageV1 {
        let object = try LifecycleWire.object(data, exact: ["kind", "events", "nextCursor"], arrayLimits: ["events": 32])
        guard try LifecycleWire.string(object, "kind") == "account.security-event-page.v1" else { throw AccountProtocolError.malformedWire }
        let events = try LifecycleWire.array(object, "events", maximumCount: 32).map { item -> AccountSecurityEventV1 in
            let event = try LifecycleWire.object(item, exact: ["kind", "handle", "category", "actorHandle", "targetHandle", "platform", "status", "occurredAt"])
            guard try LifecycleWire.string(event, "kind") == "account.security-event.v1", let category = AccountSecurityEventCategory(rawValue: try LifecycleWire.string(event, "category")) else { throw AccountProtocolError.malformedWire }
            let platformText = try LifecycleWire.string(event, "platform")
            let platform = platformText.isEmpty ? nil : AccountPlatform(rawValue: platformText)
            guard platformText.isEmpty || platform != nil else { throw AccountProtocolError.malformedWire }
            return try AccountSecurityEventV1(handle: decodeBase64URL(try LifecycleWire.string(event, "handle"), exactBytes: 32), category: category, actorHandle: decodeBase64URL(try LifecycleWire.string(event, "actorHandle"), exactBytes: 32), targetHandle: try LifecycleWire.optionalData(event, "targetHandle", bytes: 32), platform: platform, status: try LifecycleWire.string(event, "status"), occurredAt: try LifecycleWire.string(event, "occurredAt"))
        }
        let value = try AccountSecurityEventPageV1(events: events, nextCursor: try LifecycleWire.optionalString(object, "nextCursor"))
        try LifecycleWire.requireCanonical(data, encodeSecurityEventPage(value)); return value
    }
    static func encodeSecurityEventPage(_ value: AccountSecurityEventPageV1) throws -> Data {
        let events: [[String: Any]] = value.events.map { ["kind": "account.security-event.v1", "handle": encodeBase64URL($0.handle), "category": $0.category.rawValue, "actorHandle": encodeBase64URL($0.actorHandle), "targetHandle": $0.targetHandle.map(encodeBase64URL) ?? NSNull(), "platform": $0.platform?.rawValue ?? "", "status": $0.status, "occurredAt": $0.occurredAt] }
        return try LifecycleWire.encode(["kind": "account.security-event-page.v1", "events": events, "nextCursor": value.nextCursor.map { $0 as Any } ?? NSNull()])
    }

    static func encodeRecoveryRequest(_ value: AccountRecoveryRequestV1) throws -> Data { try LifecycleWire.encode(["kind": "account.recovery-request.v1", "identityToken": value.identityToken, "appleNonce": encodeBase64URL(value.appleNonce), "publicBundle": ["signingKey": encodeBase64URL(value.publicBundle.signingKey), "agreementKey": encodeBase64URL(value.publicBundle.agreementKey)], "deviceProof": encodeBase64URL(value.deviceProof)]) }
    static func decodeRecoveryPreparation(_ data: Data) throws -> AccountRecoveryPreparationV1 {
        let object = try LifecycleWire.object(data, exact: ["kind", "authorization", "historicalManifest", "priorHistory"], maximumBytes: 16 * 1024 * 1024, arrayLimits: ["priorHistory": 352])
        guard try LifecycleWire.string(object, "kind") == "account.recovery-preparation.v1" else { throw AccountProtocolError.malformedWire }
        let authorizationData = try LifecycleWire.encode(try LifecycleWire.dictionary(object, "authorization"))
        let authorization = try decodeRecoveryAuthorization(authorizationData)
        let manifestObject = try LifecycleWire.dictionary(object, "historicalManifest")
        let response = try LifecycleWire.encode(["kind": "central.bootstrap-key-manifest-response.v1", "current": manifestObject, "overlap": []])
        let manifest = try decodeManifestResponse(response).current
        let priorHistory = try LifecycleWire.array(object, "priorHistory", maximumCount: 352).map { try decodeTrustHistoryEntry(LifecycleWire.encode(try LifecycleWire.dictionary($0))) }
        let value = try AccountRecoveryPreparationV1(authorization: authorization, historicalManifest: manifest, priorHistory: priorHistory)
        try LifecycleWire.requireCanonical(data, encodeRecoveryPreparation(value)); return value
    }
    static func encodeRecoveryPreparation(_ value: AccountRecoveryPreparationV1) throws -> Data {
        let history = try value.priorHistory.map { try LifecycleWire.dictionary(JSONSerialization.jsonObject(with: encodeTrustHistoryEntry($0))) }
        return try LifecycleWire.encode(["kind": "account.recovery-preparation.v1", "authorization": try LifecycleWire.dictionary(JSONSerialization.jsonObject(with: encodeRecoveryAuthorizationForLifecycle(value.authorization))), "historicalManifest": try LifecycleWire.dictionary(JSONSerialization.jsonObject(with: encodeManifest(value.historicalManifest))), "priorHistory": history])
    }

    static func encodeRecoveryCommitRequest(_ value: AccountRecoveryCommitRequestV1) throws -> Data { try LifecycleWire.encode(["kind": "account.recovery-commit-request.v1", "authorizationID": value.authorizationID.rawValue, "requestNonce": encodeBase64URL(value.requestNonce), "submission": try submissionObject(value.entry), "deviceProof": encodeBase64URL(value.deviceProof)]) }
    static func decodeRecoveryActivation(_ data: Data) throws -> AccountRecoveryActivationV1 {
        let object = try LifecycleWire.object(data, exact: ["kind", "acceptedEntry", "accessToken", "accessExpiresAt", "refreshCredential", "offlineLease", "offlineLeaseExpiresAt"], maximumBytes: 640 * 1024)
        guard try LifecycleWire.string(object, "kind") == "account.recovery-activation.v1" else { throw AccountProtocolError.malformedWire }
        let entryData = try LifecycleWire.encode(try LifecycleWire.dictionary(object, "acceptedEntry"))
        let value = try AccountRecoveryActivationV1(acceptedEntry: decodeTrustHistoryEntry(entryData), accessToken: try LifecycleWire.string(object, "accessToken"), accessExpiresAt: try LifecycleWire.string(object, "accessExpiresAt"), refreshCredential: decodeBase64URL(try LifecycleWire.string(object, "refreshCredential"), exactBytes: 32), offlineLease: try LifecycleWire.string(object, "offlineLease"), offlineLeaseExpiresAt: try LifecycleWire.string(object, "offlineLeaseExpiresAt"))
        try LifecycleWire.requireCanonical(data, encodeRecoveryActivation(value)); return value
    }
    static func encodeRecoveryActivation(_ value: AccountRecoveryActivationV1) throws -> Data { try LifecycleWire.encode(["kind": "account.recovery-activation.v1", "acceptedEntry": try LifecycleWire.dictionary(JSONSerialization.jsonObject(with: encodeTrustHistoryEntry(value.acceptedEntry))), "accessToken": value.accessToken, "accessExpiresAt": value.accessExpiresAt, "refreshCredential": encodeBase64URL(value.refreshCredential), "offlineLease": value.offlineLease, "offlineLeaseExpiresAt": value.offlineLeaseExpiresAt]) }

    static func encodeRecoveryAuthorizationForLifecycle(_ value: AccountRecoveryAuthorization) throws -> Data {
        try LifecycleWire.encode(["kind": "account.recovery-authorization.v1", "authorizationID": value.authorizationID.rawValue, "accountID": value.accountID.rawValue, "epoch": value.epoch.wireValue, "deviceID": value.deviceID.rawValue, "platform": value.platform.rawValue, "publicBundle": ["signingKey": encodeBase64URL(value.publicBundle.signingKey), "agreementKey": encodeBase64URL(value.publicBundle.agreementKey)], "priorCommitDigest": encodeBase64URL(value.priorCommitDigest), "exchangeRequestDigest": encodeBase64URL(value.exchangeRequestDigest), "issuedAt": value.issuedAt, "expiresAt": value.expiresAt, "serverKeyID": value.serverKeyID, "serverSignature": encodeBase64URL(value.serverSignature)])
    }

    private static func stepUpAuthorizationObject(_ value: AccountStepUpAuthorizationV1) -> [String: Any] { ["kind": "account.step-up-authorization.v1", "authorizationID": value.authorizationID.rawValue, "accountID": value.accountID.rawValue, "actorDeviceID": value.actorDeviceID.rawValue, "targetDeviceID": value.targetDeviceID?.rawValue ?? NSNull(), "action": value.action.rawValue, "currentCommitDigest": encodeBase64URL(value.currentCommitDigest), "requestDigest": encodeBase64URL(value.requestDigest), "issuedAt": value.issuedAt, "expiresAt": value.expiresAt, "serverKeyID": value.serverKeyID, "serverSignature": encodeBase64URL(value.serverSignature)] }
    private static func decodeStepUpAuthorizationObject(_ object: [String: Any]) throws -> AccountStepUpAuthorizationV1 {
        guard try LifecycleWire.string(object, "kind") == "account.step-up-authorization.v1", let action = AccountLifecycleAction(rawValue: try LifecycleWire.string(object, "action")) else { throw AccountProtocolError.malformedWire }
        return try AccountStepUpAuthorizationV1(authorizationID: AccountAuthorizationID(try LifecycleWire.string(object, "authorizationID")), accountID: PlainpostAccountID(try LifecycleWire.string(object, "accountID")), actorDeviceID: AccountDeviceID(try LifecycleWire.string(object, "actorDeviceID")), targetDeviceID: try LifecycleWire.optionalID(object, "targetDeviceID"), action: action, currentCommitDigest: decodeBase64URL(try LifecycleWire.string(object, "currentCommitDigest"), exactBytes: 32), requestDigest: decodeBase64URL(try LifecycleWire.string(object, "requestDigest"), exactBytes: 32), issuedAt: try LifecycleWire.string(object, "issuedAt"), expiresAt: try LifecycleWire.string(object, "expiresAt"), serverKeyID: try LifecycleWire.string(object, "serverKeyID"), serverSignature: decodeBase64URL(try LifecycleWire.string(object, "serverSignature"), exactBytes: 64))
    }
    private static func submissionObject(_ entry: AccountTrustHistoryEntryV1) throws -> [String: Any] {
        var object = try LifecycleWire.dictionary(JSONSerialization.jsonObject(with: encodeTrustHistoryEntry(entry)))
        object["kind"] = "account.trust-commit-submission.v1"
        return object
    }
    private static func decodeSubmissionObject(_ object: [String: Any]) throws -> AccountTrustHistoryEntryV1 {
        guard try LifecycleWire.string(object, "kind") == "account.trust-commit-submission.v1" else { throw AccountProtocolError.malformedWire }
        var history = object; history["kind"] = "account.trust-history-entry.v1"
        return try decodeTrustHistoryEntry(LifecycleWire.encode(history))
    }
}

private enum LifecycleWire {
    static let stepUpFields = ["kind", "authorizationID", "accountID", "actorDeviceID", "targetDeviceID", "action", "currentCommitDigest", "requestDigest", "issuedAt", "expiresAt", "serverKeyID", "serverSignature"]
    static func encode(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) }
    static func object(_ data: Data, exact fields: [String], maximumBytes: Int = AccountWireCodec.maxBodyBytes, arrayLimits: [String: Int] = [:]) throws -> [String: Any] {
        try AccountWireCodec.validateUniqueJSONKeys(data, maximumBytes: maximumBytes, arrayLimits: arrayLimits)
        return try object(JSONSerialization.jsonObject(with: data), exact: fields)
    }
    static func object(_ value: Any, exact fields: [String]) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys) == Set(fields) else { throw AccountProtocolError.malformedWire }; return object
    }
    static func nested(_ object: [String: Any], _ key: String, exact fields: [String]) throws -> [String: Any] { try self.object(object[key] as Any, exact: fields) }
    static func dictionary(_ object: [String: Any], _ key: String) throws -> [String: Any] { try dictionary(object[key] as Any) }
    static func dictionary(_ value: Any) throws -> [String: Any] { guard let result = value as? [String: Any] else { throw AccountProtocolError.malformedWire }; return result }
    static func string(_ object: [String: Any], _ key: String) throws -> String { guard let value = object[key] as? String else { throw AccountProtocolError.malformedWire }; return value }
    static func optionalString(_ object: [String: Any], _ key: String) throws -> String? { if object[key] is NSNull { return nil }; return try string(object, key) }
    static func optionalID(_ object: [String: Any], _ key: String) throws -> AccountDeviceID? { if object[key] is NSNull { return nil }; return try AccountDeviceID(string(object, key)) }
    static func optionalData(_ object: [String: Any], _ key: String, bytes: Int) throws -> Data? { if object[key] is NSNull { return nil }; return try AccountWireCodec.decodeBase64URL(string(object, key), exactBytes: bytes) }
    static func array(_ object: [String: Any], _ key: String, maximumCount: Int) throws -> [Any] { guard let value = object[key] as? [Any], value.count <= maximumCount else { throw AccountProtocolError.malformedWire }; return value }
    static func requireCanonical(_ original: Data, _ canonical: Data) throws { guard original == canonical else { throw AccountProtocolError.nonCanonicalValue } }
}
