import Foundation

public actor NodeCalendarClient {
    private let sender: any NodeSessionRequestSending
    private var busy = false
    public init(sender: any NodeSessionRequestSending) { self.sender = sender }

    public func capabilities() async throws -> NodeCalendarCapabilities {
        let response = try await execute(method: "GET", path: "/v1/calendar/capabilities", body: Data(), capability: true)
        let result: NodeCalendarCapabilities = try NodeCalendarCodec.decodeFamily(response.body, kind: "capabilities")
        guard result.version == 1 else { throw NodeCalendarError.unsupported }
        return result
    }
    public func connections() async throws -> [NodeCalendarConnection] {
        let body = try NodeCalendarCodec.encodeFamily(NodeCalendarConnectionsRequest(), kind: "connections-request")
        let response = try await execute(method: "POST", path: "/v1/calendar/connections/read", body: body)
        let result: NodeCalendarConnectionsResult = try NodeCalendarCodec.decodeFamily(response.body, kind: "connections-result")
        return result.connections
    }
    public func configure(_ command: NodeCalendarConnectionCommand) async throws -> NodeCalendarConnectionResult {
        try await call(NodeCalendarConnectionRequest(command: command), path: "connections/configure", requestKind: "connection-command", resultKind: "connection-result", limit: NodeCalendarCodec.connectionBodyLimit)
    }
    public func disconnect(_ command: NodeCalendarDisconnectCommand) async throws -> NodeCalendarConnectionResult {
        try await call(command, path: "connections/disconnect", requestKind: "disconnect-command", resultKind: "connection-result", limit: NodeCalendarCodec.connectionBodyLimit)
    }
    public func window(_ request: NodeCalendarWindowRequest) async throws -> NodeCalendarWindowSnapshot {
        // A snapshot that changes between pages restarts from the first page, as a
        // read of the just-refreshed projection; restarts are bounded.
        var first = request
        for _ in 0..<3 {
            do { return try await windowPages(first) } catch NodeCalendarError.snapshotChanged {
                first = .init(window: request.window, cursor: request.cursor)
            }
        }
        throw NodeCalendarError.conflict
    }
    private func windowPages(_ request: NodeCalendarWindowRequest) async throws -> NodeCalendarWindowSnapshot {
        var next = request
        var cursors: Set<String> = [request.cursor]
        var eventIDs: Set<String> = []
        var accumulated: NodeCalendarWindowSnapshot?
        for _ in 0..<128 {
            let page: NodeCalendarWindowSnapshot = try await call(next, path: "window", requestKind: "window-request", resultKind: "window-result", responseLimit: NodeCalendarCodec.windowResponseLimit)
            guard page.window == request.window, page.events.allSatisfy({ eventIDs.insert($0.id).inserted }) else { throw NodeCalendarError.invalidResponse }
            if var previous = accumulated {
                // The cursor pins the event snapshot; the first page's refresh
                // metadata describes the whole result.
                previous.events += page.events; previous.nextCursor = page.nextCursor; accumulated = previous
            } else { accumulated = page }
            guard let result = accumulated, result.events.count <= 100_000 else { throw NodeCalendarError.invalidResponse }
            if page.nextCursor.isEmpty { return result }
            guard !page.events.isEmpty, cursors.insert(page.nextCursor).inserted else { throw NodeCalendarError.invalidResponse }
            next = .init(window: request.window, cursor: page.nextCursor)
        }
        throw NodeCalendarError.invalidResponse
    }
    public func event(id: String) async throws -> NodeCalendarEvent {
        try NodeCalendarCodec.validateIDs([id])
        let result: NodeCalendarEventResult = try await call(NodeCalendarEventRequest(eventID: id), path: "event", requestKind: "event-request", resultKind: "event-result")
        return result.event
    }
    public func invitations(messageIDs: [String]) async throws -> [NodeCalendarInvitation] {
        try NodeCalendarCodec.validateIDs(messageIDs)
        let result: NodeCalendarInvitationReadResult = try await call(NodeCalendarInvitationReadRequest(messageIDs: messageIDs), path: "invitations", requestKind: "invitation-read-request", resultKind: "invitation-read-result")
        return result.invitations
    }
    public func submit(_ command: NodeCalendarCommand) async throws -> NodeCalendarReceipt {
        guard command.generation > 0, command.generation <= 9_007_199_254_740_991,
              !command.revision.isEmpty, (command.edit == nil) != (command.response == nil) else { throw NodeCalendarError.invalidResponse }
        let result: NodeCalendarCommandResult = try await call(NodeCalendarCommandRequest(command: command), path: "commands", requestKind: "command-request", resultKind: "command-result")
        return result.receipt
    }
    public func receipts(operationIDs: [String]) async throws -> [NodeCalendarReceipt] {
        let body = try NodeCalendarCodec.encodeOperationRead(operationIDs)
        let response = try await execute(method: "POST", path: "/v1/calendar/operations/read", body: body, maximumResponseBytes: 1_048_576)
        return try NodeCalendarCodec.decodeOperationReadResponse(response, requested: operationIDs)
    }
    private func call<Q: Encodable, R: Codable>(_ request: Q, path: String, requestKind: String, resultKind: String, limit: Int = NodeCalendarCodec.commandBodyLimit, responseLimit: Int = 1_048_576) async throws -> R {
        let body = try NodeCalendarCodec.encodeFamily(request, kind: requestKind, limit: limit)
        let response = try await execute(method: "POST", path: "/v1/calendar/" + path, body: body, maximumResponseBytes: responseLimit)
        return try NodeCalendarCodec.decodeFamily(response.body, kind: resultKind)
    }
    private func execute(method: String, path: String, body: Data, maximumResponseBytes: Int = 1_048_576, capability: Bool = false) async throws -> NodeHTTPResponse {
        guard !busy else { throw NodeCalendarError.unavailable }
        busy = true; defer { busy = false }
        try Task.checkCancellation()
        do {
            if let reconciler = sender as? any NodePendingRequestReconciling {
                // The sender retains the exact signed sequence/body. A different
                // request is admitted only after that record has been settled.
                _ = try await reconciler.reconcilePendingRequest()
            }
            let response: NodeHTTPResponse
            do {
                response = try await sender.send(method: method, path: path, body: body, maximumResponseBytes: maximumResponseBytes)
            } catch let error as NodeSessionError where error == .transportFailureAfterDispatch || error == .transportCancellationAfterDispatch {
                do {
                    guard let reconciler = sender as? any NodePendingRequestReconciling,
                          let retained = try await reconciler.reconcilePendingRequest() else { throw NodeCalendarError.deliveryUncertain }
                    response = retained
                } catch let error as NodeSessionError where error == .authenticationRejected {
                    throw NodeCalendarError.unauthorized
                } catch {
                    throw NodeCalendarError.deliveryUncertain
                }
            }
            try NodeCalendarCodec.validateStatus(response, capability: capability)
            guard response.body.count <= maximumResponseBytes else { throw NodeCalendarError.invalidResponse }
            return response
        } catch is CancellationError { throw CancellationError() }
        catch let error as NodeCalendarError { throw error }
        catch let error as NodeSessionError {
            switch error {
            case .authenticationRejected: throw NodeCalendarError.unauthorized
            case .applicationResultUncertain, .transportFailureAfterDispatch, .transportCancellationAfterDispatch: throw NodeCalendarError.deliveryUncertain
            default: throw NodeCalendarError.unavailable
            }
        } catch { throw NodeCalendarError.unavailable }
    }
}
