import Foundation
import XCTest
@testable import PlainpostLocalAPI

private struct TestStatusRoute: LocalAPIRoute {
    let method = LocalAPIMethod.sessionStatus

    func handle(requestData: Data, requestID: String) async throws -> Data {
        try JSONEncoder().encode(
            LocalAPISuccess(requestID: requestID, result: LocalAPIEmptyParameters())
        )
    }
}

private struct TestThrowingRoute: LocalAPIRoute {
    let method = LocalAPIMethod.sessionStatus
    let failure: TestRouteFailure

    func handle(requestData: Data, requestID: String) async throws -> Data {
        switch failure {
        case .safe(let error):
            throw error
        case .unexpected(let error):
            throw error
        }
    }
}

private enum TestRouteFailure: Sendable {
    case safe(LocalAPIRouteError)
    case unexpected(PrivateRouteError)
}

private struct PrivateRouteError: Error, Sendable {
    let detail: String
}

final class LocalAPIRouterTests: XCTestCase {
    func testRouterDispatchesRegisteredRoute() async throws {
        let router = LocalAPIRouter(routes: [TestStatusRoute()])
        let request = LocalAPIRequest(
            requestID: "req-ok",
            method: .sessionStatus,
            parameters: LocalAPIEmptyParameters()
        )

        let data = await router.handle(
            try JSONEncoder().encode(request),
            caller: .browserExtension
        )
        let success = try JSONDecoder().decode(
            LocalAPISuccess<LocalAPIEmptyParameters>.self,
            from: data
        )

        XCTAssertTrue(success.ok)
        XCTAssertEqual(success.requestID, "req-ok")
    }

    func testRouterRejectsMethodOutsideCallerCapabilities() async throws {
        let router = LocalAPIRouter(routes: [TestStatusRoute()])
        let request = LocalAPIRequest(
            requestID: "req-denied",
            method: .sessionStatus,
            parameters: LocalAPIEmptyParameters()
        )
        let data = await router.handle(
            try JSONEncoder().encode(request),
            caller: LocalAPICaller(id: "test", allowedMethods: [])
        )
        let failure = try JSONDecoder().decode(LocalAPIFailure.self, from: data)
        XCTAssertEqual(failure.error.code, .permissionDenied)
    }

    func testRouterRejectsNewerClientVersion() async throws {
        let raw = #"{"apiVersion":2,"requestID":"req-v2","method":"session.status","parameters":{}}"#
        let data = await LocalAPIRouter(routes: []).handle(
            Data(raw.utf8),
            caller: .browserExtension
        )
        let failure = try JSONDecoder().decode(LocalAPIFailure.self, from: data)
        XCTAssertEqual(failure.error.code, .serverUpdateRequired)
    }

    func testRouterRejectsNewerClientVersionWithUnknownMethod() async throws {
        let raw = #"{"apiVersion":2,"requestID":"req-v2-new","method":"mail.future","parameters":{}}"#
        let data = await LocalAPIRouter(routes: []).handle(
            Data(raw.utf8),
            caller: .browserExtension
        )
        let failure = try JSONDecoder().decode(LocalAPIFailure.self, from: data)

        XCTAssertEqual(failure.requestID, "req-v2-new")
        XCTAssertEqual(failure.error.code, .serverUpdateRequired)
    }

    func testRouterRejectsOlderClientVersion() async throws {
        let raw = #"{"apiVersion":0,"requestID":"req-v0","method":"session.status","parameters":{}}"#
        let data = await LocalAPIRouter(routes: []).handle(
            Data(raw.utf8),
            caller: .browserExtension
        )
        let failure = try JSONDecoder().decode(LocalAPIFailure.self, from: data)
        XCTAssertEqual(failure.error.code, .clientUpdateRequired)
    }

    func testRouterRejectsOlderClientVersionWithUnknownMethod() async throws {
        let raw = #"{"apiVersion":0,"requestID":"req-v0-old","method":"mail.legacy","parameters":{}}"#
        let data = await LocalAPIRouter(routes: []).handle(
            Data(raw.utf8),
            caller: .browserExtension
        )
        let failure = try JSONDecoder().decode(LocalAPIFailure.self, from: data)

        XCTAssertEqual(failure.requestID, "req-v0-old")
        XCTAssertEqual(failure.error.code, .clientUpdateRequired)
    }

    func testRouterRejectsMissingRoute() async throws {
        let request = LocalAPIRequest(
            requestID: "req-missing",
            method: .sessionStatus,
            parameters: LocalAPIEmptyParameters()
        )

        let data = await LocalAPIRouter(routes: []).handle(
            try JSONEncoder().encode(request),
            caller: .browserExtension
        )
        let failure = try JSONDecoder().decode(LocalAPIFailure.self, from: data)

        XCTAssertEqual(failure.requestID, "req-missing")
        XCTAssertEqual(failure.error.code, .invalidRequest)
    }

    func testRouterRejectsMalformedFrame() async throws {
        let data = await LocalAPIRouter(routes: []).handle(
            Data("not-json".utf8),
            caller: .browserExtension
        )
        let failure = try JSONDecoder().decode(LocalAPIFailure.self, from: data)

        XCTAssertNil(failure.requestID)
        XCTAssertEqual(failure.error.code, .invalidRequest)
    }

    func testRouterRejectsOversizedFrame() async throws {
        let data = await LocalAPIRouter(routes: []).handle(
            Data(repeating: 0, count: LocalAPIProtocol.maximumFrameSize + 1),
            caller: .browserExtension
        )
        let failure = try JSONDecoder().decode(LocalAPIFailure.self, from: data)

        XCTAssertNil(failure.requestID)
        XCTAssertEqual(failure.error.code, .invalidRequest)
    }

    func testRouterReturnsSafeRouteError() async throws {
        let routeError = LocalAPIRouteError(code: .conflict, safeMessage: "The draft changed.")
        let router = LocalAPIRouter(routes: [TestThrowingRoute(failure: .safe(routeError))])
        let request = LocalAPIRequest(
            requestID: "req-conflict",
            method: .sessionStatus,
            parameters: LocalAPIEmptyParameters()
        )

        let data = await router.handle(
            try JSONEncoder().encode(request),
            caller: .browserExtension
        )
        let failure = try JSONDecoder().decode(LocalAPIFailure.self, from: data)

        XCTAssertEqual(failure.error.code, .conflict)
        XCTAssertEqual(failure.error.message, "The draft changed.")
    }

    func testRouterRedactsUnexpectedRouteError() async throws {
        let privateError = PrivateRouteError(detail: "private-route-details")
        let router = LocalAPIRouter(routes: [TestThrowingRoute(failure: .unexpected(privateError))])
        let request = LocalAPIRequest(
            requestID: "req-failed",
            method: .sessionStatus,
            parameters: LocalAPIEmptyParameters()
        )

        let data = await router.handle(
            try JSONEncoder().encode(request),
            caller: .browserExtension
        )
        let failure = try JSONDecoder().decode(LocalAPIFailure.self, from: data)

        XCTAssertEqual(failure.error.code, .operationFailed)
        XCTAssertEqual(failure.error.message, "The local operation failed.")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-route-details"))
    }
}
