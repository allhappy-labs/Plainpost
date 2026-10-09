import CryptoKit
import Foundation
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import PlainpostCore
import PlainpostDB
import PlainpostIOSRuntime
import PlainpostNodeTransport
import PlainpostUI

/// Connects one selected provider account's Node send authority to the same
/// protected database used by Direct mail and source transitions.
struct MobileNodeSendJournal: NodeSendJournal {
    let databaseURL: URL
    let accountID: AccountID
    let plainpostAccountID: PlainpostAccountID
    let source: AccountMailSource

    func requireCurrentSource() throws {
        _ = try openStore()
    }

    func unresolvedSendOperations(accountID requested: AccountID) throws -> [Data] {
        guard requested == accountID else { throw NodeSendIntentError.operationMismatch }
        let operations = try openStore().unresolvedNodeSends(accountID: accountID)
        for operation in operations { _ = try requireScopedSend(operation) }
        return operations
    }

    func reserveSend(canonicalOperation: Data) throws {
        let operation = try requireScopedSend(canonicalOperation)
        try openStore().reserveNodeSend(
            accountID: accountID, expectedGeneration: source.generation,
            nodeID: operation.unsigned.nodeID,
            logicalMailboxID: try NodeSyncCodec.encodeLogicalMailboxID(operation.unsigned.logicalMailboxID),
            idempotencyKey: operation.unsigned.idempotencyKey,
            canonicalOperationSHA256: Data(SHA256.hash(data: canonicalOperation)),
            canonicalOperation: canonicalOperation
        )
    }

    func settleSend(canonicalOperation: Data, state: NodeSendOutcome) throws {
        let operation = try requireScopedSend(canonicalOperation)
        let settlement: NodeSendSettlement = switch state {
        case .pending: .pending
        case .applied: .applied
        case .rejected: .rejected
        case .conflicted: .conflicted
        case .deliveryUncertain: .deliveryUncertain
        }
        try openStore().settleNodeSend(
            accountID: accountID, expectedGeneration: source.generation,
            idempotencyKey: operation.unsigned.idempotencyKey,
            canonicalOperationSHA256: Data(SHA256.hash(data: canonicalOperation)),
            state: settlement
        )
    }

    private func openStore() throws -> SQLiteMailStore {
        try IOSLocalDatabaseProtection.prepare(url: databaseURL)
        let store = try SQLiteMailStore(path: databaseURL.path)
        try IOSLocalDatabaseProtection.verify(url: databaseURL)
        guard try store.mailSource(accountID: accountID) == source else {
            throw NodeMailModeStoreError.generationConflict
        }
        return store
    }

    private func requireScopedSend(_ bytes: Data) throws -> NodeSyncOperation {
        guard source.accountID == accountID, source.kind == .nodeBacked,
              source.mode == .node,
              let operation = try? NodeSyncCodec.decodeOperation(bytes),
              operation.unsigned.accountID == plainpostAccountID.rawValue,
              operation.unsigned.nodeID == source.nodeID,
              (try? NodeSyncCodec.encodeLogicalMailboxID(operation.unsigned.logicalMailboxID)) == source.logicalMailboxID
        else { throw NodeSendIntentError.operationMismatch }
        guard case .send = operation.unsigned.operation else {
            throw NodeSendIntentError.operationMismatch
        }
        return operation
    }
}
