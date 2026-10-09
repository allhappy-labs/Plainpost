import Foundation
import XCTest
@testable import PlainpostSecrets
@testable import PlainpostServiceIPC
@testable import PlainpostServiceRuntime

final class NodeSessionXPCContractTests: XCTestCase {
    func testNodeSessionDTOsRoundTripWithoutFormattingBodies() throws {
        let request = try PlainpostNodeSessionRequest(method: "POST", path: "/v1/calendar/connections/configure", body: Data(#"{"password":"caldav-secret"}"#.utf8))
        let decoded = try PlainpostNodeSessionRequest(dto: request.dto())
        XCTAssertEqual(decoded, request)
        XCTAssertFalse(String(describing: request).contains("caldav-secret"))
        XCTAssertFalse(String(reflecting: request).contains("caldav-secret"))
        XCTAssertFalse(String(describing: try request.dto()).contains("caldav-secret"))
        XCTAssertFalse(PlainpostClientValidator.permits(.performNodeSessionRequest, for: .cli))
        XCTAssertTrue(PlainpostClientValidator.permits(.performNodeSessionRequest, for: .app))
        XCTAssertFalse(PlainpostClientValidator.permits(.nodeSessionIdentityReadiness, for: .cli))
        XCTAssertTrue(PlainpostClientValidator.permits(.nodeSessionIdentityReadiness, for: .app))
        XCTAssertEqual(try PlainpostNodeSessionIdentityReadiness(dtoString: PlainpostNodeSessionIdentityReadiness.needsMigration.rawValue), .needsMigration)
        XCTAssertThrowsError(try PlainpostNodeSessionIdentityReadiness(dtoString: "unknown"))
    }

    func testOnlyTheAppMayCallAnyNodeSessionMethod() {
        for method in PlainpostServiceMethod.allCases {
            for capability in PlainpostClientCapability.allCases {
                XCTAssertEqual(PlainpostClientValidator.permits(method, for: capability), capability == .app, "\(method) for \(capability)")
            }
        }
    }

    func testDTOsSurviveSecureCodingAndRejectOutOfBoundValues() throws {
        let request = try PlainpostNodeSessionRequest(method: "PUT", path: "/v1/notifications/policy", body: Data(repeating: 7, count: 32))
        let archived = try NSKeyedArchiver.archivedData(withRootObject: request.dto(), requiringSecureCoding: true)
        let unarchived = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: PlainpostNodeSessionRequestDTO.self, from: archived))
        XCTAssertEqual(try PlainpostNodeSessionRequest(dto: unarchived), request)

        let response = try PlainpostNodeSessionResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        let responseArchive = try NSKeyedArchiver.archivedData(withRootObject: response.dto(), requiringSecureCoding: true)
        let responseDTO = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: PlainpostNodeSessionResponseDTO.self, from: responseArchive))
        XCTAssertEqual(try PlainpostNodeSessionResponse(dto: responseDTO), response)
        XCTAssertFalse(String(describing: response).contains("{}"))

        XCTAssertThrowsError(try PlainpostNodeSessionRequest(method: "POST", path: "/v1/x", body: Data(count: PlainpostNodeSessionLimits.maximumRequestBodyBytes + 1)))
        XCTAssertThrowsError(try PlainpostNodeSessionRequest(method: "get", path: "/v1/status", body: Data()))
        XCTAssertThrowsError(try PlainpostNodeSessionRequest(method: "GET", path: "v1/status", body: Data()))
        XCTAssertThrowsError(try PlainpostNodeSessionRequest(method: "GET", path: "/" + String(repeating: "a", count: 2_048), body: Data()))
        XCTAssertThrowsError(try PlainpostNodeSessionRequest(method: "GET", path: "/v1/status with space", body: Data()))
        XCTAssertNil(PlainpostNodeSessionRequestDTO(schemaVersion: 1, method: "POST", path: "/v1/x", body: Data(count: PlainpostNodeSessionLimits.maximumRequestBodyBytes + 1)))
        XCTAssertNil(PlainpostNodeSessionRequestDTO(schemaVersion: 2, method: "GET", path: "/v1/status", body: Data()))
        XCTAssertNil(PlainpostNodeSessionResponseDTO(schemaVersion: 1, statusCode: 200, headers: [:], body: Data(count: PlainpostNodeSessionLimits.maximumResponseBodyBytes + 1)))
        XCTAssertNil(PlainpostNodeSessionResponseDTO(schemaVersion: 1, statusCode: 99, headers: [:], body: Data()))
        let tooManyHeaders = Dictionary(uniqueKeysWithValues: (0...PlainpostNodeSessionLimits.maximumResponseHeaderCount).map { ("h\($0)", "v") })
        XCTAssertNil(PlainpostNodeSessionResponseDTO(schemaVersion: 1, statusCode: 200, headers: tooManyHeaders, body: Data()))
        XCTAssertNotNil(PlainpostNodeSessionResponseDTO(schemaVersion: 1, statusCode: 200, headers: [:], body: Data(count: PlainpostNodeSessionLimits.maximumResponseBodyBytes)))
    }

    func testNodeSessionFailuresRemainTypedAcrossXPC() throws {
        for failure in PlainpostNodeSessionFailure.allCases {
            let dto = PlainpostServiceErrorMapper.dto(from: PlainpostServiceClientError.nodeSession(failure))
            XCTAssertEqual(dto.code, .nodeSessionFailed)
            XCTAssertEqual(dto.detail, failure.rawValue)
            let archived = try NSKeyedArchiver.archivedData(withRootObject: dto, requiringSecureCoding: true)
            let decoded = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: PlainpostXPCErrorDTO.self, from: archived))
            XCTAssertEqual(PlainpostServiceClientError(dto: decoded), .nodeSession(failure))
        }
        XCTAssertNil(PlainpostXPCErrorDTO(schemaVersion: 1, code: .nodeSessionFailed, detail: 0))
        let unknown = try XCTUnwrap(PlainpostXPCErrorDTO(schemaVersion: 1, code: .nodeSessionFailed, detail: 999))
        XCTAssertEqual(PlainpostServiceClientError(dto: unknown), .nodeSession(.unavailable))
    }

    func testInterfaceAdmitsTheNodeSessionDTOClasses() {
        let interface = PlainpostServiceXPCInterface.make()
        let requestClasses = interface.classes(for: #selector(PlainpostServiceXPCProtocol.performNodeSessionRequest(_:reply:)), argumentIndex: 0, ofReply: false)
        XCTAssertTrue(requestClasses.contains { ($0 as? AnyClass) == PlainpostNodeSessionRequestDTO.self })
        let replyClasses = interface.classes(for: #selector(PlainpostServiceXPCProtocol.performNodeSessionRequest(_:reply:)), argumentIndex: 0, ofReply: true)
        XCTAssertTrue(replyClasses.contains { ($0 as? AnyClass) == PlainpostNodeSessionResponseDTO.self })
    }

    func testListenerRejectsEveryCallerOtherThanTheApp() async throws {
        let recorder = NodeSessionHandlerRecorder()
        let listener = PlainpostServiceListener(lifecycleCoordinator: makeCoordinator(), nodeSession: recorder.handlers)
        let request = try PlainpostNodeSessionRequest(method: "GET", path: "/v1/status", body: Data()).dto()
        for capability in PlainpostClientCapability.allCases where capability != .app {
            let service = listener.exportedService(for: capability)
            let performed = await perform(service, request)
            XCTAssertNil(performed.response)
            XCTAssertEqual(performed.error?.code, .clientUnauthorized)
            let invalidated = await invalidate(service)
            XCTAssertEqual(invalidated?.code, .clientUnauthorized)
            let readiness = await identityReadiness(service)
            XCTAssertNil(readiness.value)
            XCTAssertEqual(readiness.error?.code, .clientUnauthorized)
        }
        let calls = await recorder.calls
        XCTAssertEqual(calls, [], "a rejected caller never reaches the broker")
    }

    func testListenerForwardsAppCallsWithoutRequiringAnUnlockedVault() async throws {
        let recorder = NodeSessionHandlerRecorder()
        let listener = PlainpostServiceListener(lifecycleCoordinator: makeCoordinator(), nodeSession: recorder.handlers)
        let app = listener.exportedService(for: .app)
        let performed = await perform(app, try PlainpostNodeSessionRequest(method: "GET", path: "/v1/status", body: Data()).dto())
        XCTAssertNil(performed.error)
        XCTAssertEqual(try PlainpostNodeSessionResponse(dto: XCTUnwrap(performed.response)).body, Data("status".utf8))
        let invalidated = await invalidate(app)
        XCTAssertNil(invalidated)
        let readiness = await identityReadiness(app)
        XCTAssertEqual(readiness.value, "ready")
        let calls = await recorder.calls
        XCTAssertEqual(calls, ["perform:GET /v1/status", "invalidate", "readiness"])

        await recorder.fail(with: PlainpostServiceClientError.nodeSession(.pathNotAllowed))
        let refused = await perform(app, try PlainpostNodeSessionRequest(method: "POST", path: "/v1/mutations", body: Data()).dto())
        XCTAssertEqual(refused.error.map(PlainpostServiceClientError.init(dto:)), .nodeSession(.pathNotAllowed))
    }

    func testListenerWithoutABrokerFailsClosed() async throws {
        let listener = PlainpostServiceListener(lifecycleCoordinator: makeCoordinator())
        let app = listener.exportedService(for: .app)
        let performed = await perform(app, try PlainpostNodeSessionRequest(method: "GET", path: "/v1/status", body: Data()).dto())
        XCTAssertEqual(performed.error.map(PlainpostServiceClientError.init(dto:)), .nodeSession(.unavailable))
        let readiness = await identityReadiness(app)
        XCTAssertEqual(readiness.value, PlainpostNodeSessionIdentityReadiness.noSession.rawValue)
    }

    private func makeCoordinator() -> PlainpostServiceLifecycleCoordinator {
        PlainpostServiceLifecycleCoordinator(
            vaultSession: VaultSession(provider: LockedVaultKeyProvider()),
            prepareForegroundUnlock: {},
            beginVaultLockdown: {},
            confirmVaultLocked: {},
            reopenRuntimeConstruction: {}
        )
    }

    private func perform(_ service: PlainpostServiceXPCProtocol, _ request: PlainpostNodeSessionRequestDTO) async -> (response: PlainpostNodeSessionResponseDTO?, error: PlainpostXPCErrorDTO?) {
        await withCheckedContinuation { continuation in
            service.performNodeSessionRequest(request) { continuation.resume(returning: ($0, $1)) }
        }
    }

    private func invalidate(_ service: PlainpostServiceXPCProtocol) async -> PlainpostXPCErrorDTO? {
        await withCheckedContinuation { continuation in
            service.invalidateNodeSession { continuation.resume(returning: $0) }
        }
    }

    private func identityReadiness(_ service: PlainpostServiceXPCProtocol) async -> (value: String?, error: PlainpostXPCErrorDTO?) {
        await withCheckedContinuation { continuation in
            service.nodeSessionIdentityReadiness { continuation.resume(returning: ($0, $1)) }
        }
    }
}

private actor NodeSessionHandlerRecorder {
    private(set) var calls: [String] = []
    private var failure: Error?

    func fail(with error: Error) { failure = error }

    nonisolated var handlers: PlainpostNodeSessionHandlers {
        PlainpostNodeSessionHandlers(
            perform: { request in try await self.perform(request) },
            invalidate: { await self.record("invalidate") },
            identityReadiness: { await self.record("readiness"); return .ready }
        )
    }

    private func perform(_ request: PlainpostNodeSessionRequest) throws -> PlainpostNodeSessionResponse {
        calls.append("perform:\(request.method) \(request.path)")
        if let failure { throw failure }
        return try PlainpostNodeSessionResponse(statusCode: 200, headers: [:], body: Data("status".utf8))
    }

    private func record(_ call: String) { calls.append(call) }
}

private struct LockedVaultKeyProvider: VaultKeyProvider {
    func createIfMissing() async throws {}
    func load(interactive: Bool, prompt: String?) async throws -> Data? { nil }
    func countMatchingItems() async throws -> Int { 1 }
}
