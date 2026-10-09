import XCTest
@testable import PlainpostAccountRuntime
@testable import PlainpostUI

@MainActor
final class CentralServerSetupViewModelTests: XCTestCase {
    func testInvalidOriginShowsCorrectiveErrorWithoutSaving() async {
        var saves = 0
        let model = CentralServerSetupViewModel(originText: "http://central.example") { _ in
            saves += 1
            return .repairRequired(CentralServerRepair(reason: .storageUnavailable))
        }

        await model.continueSetup()

        XCTAssertEqual(saves, 0)
        XCTAssertEqual(model.errorMessage, "Use an HTTPS server address.")
        XCTAssertFalse(model.isBusy)
    }

    func testValidOriginInvokesSaveWithCanonicalValue() async {
        var saved: String?
        let expected = try! CentralServerConfiguration(originText: "https://central.example")
        let model = CentralServerSetupViewModel(originText: "https://CENTRAL.example/") { origin in
            saved = origin
            return .configured(expected)
        }

        await model.continueSetup()

        XCTAssertEqual(saved, "https://central.example")
        XCTAssertNil(model.errorMessage)
    }

    func testBoundRepairPrefillsOnlyAcceptedOrigin() throws {
        let model = CentralServerSetupViewModel(originText: "https://wrong.example") { _ in .setupRequired }
        let bound = try CentralServerConfiguration(originText: "https://bound.example")
        model.apply(repair: CentralServerRepair(reason: .originMismatch, boundOrigin: bound.origin))
        XCTAssertEqual(model.originText, "https://bound.example")
    }

    func testShutdownPermanentlyRejectsNewAndLateAppleAttempts() async throws {
        let recorder = BootstrapCallRecorder()
        let model = AccountSessionViewModel(
            prepareSession: { _ in .signInRequired },
            bootstrapAppleCredential: { _, _ in
                await recorder.record()
                return .signInRequired
            }
        )
        let attempt = try model.beginAppleSignIn()
        await model.shutdownForServerChange()
        model.submitAppleIdentityToken(Data("late-token".utf8), for: attempt.id)
        await Task.yield()
        let bootstrapCalls = await recorder.count
        XCTAssertEqual(bootstrapCalls, 0)
        XCTAssertThrowsError(try model.beginAppleSignIn())
    }
}

private actor BootstrapCallRecorder {
    private(set) var count = 0
    func record() { count += 1 }
}
