import XCTest
@testable import PlainpostUI

@MainActor
final class NotificationPermissionModelTests: XCTestCase {
    func testRefreshReadsStatusWithoutRequestingAuthorization() async throws {
        let fixture = PermissionFixture(status: .authorized)

        await fixture.model.refresh()

        XCTAssertEqual(fixture.model.status, .authorized)
        let calls = await fixture.center.calls()
        XCTAssertEqual(calls.status, 1)
        XCTAssertEqual(calls.requests, 0)
        XCTAssertEqual(calls.adds, 0)
    }

    func testExplicitEnableRequestsAuthorizationAndEnablesFutureNewMail() async throws {
        let fixture = PermissionFixture(status: .notDetermined, requestResult: .authorized)
        fixture.defaults.set(false, forKey: PlainpostNotificationPreference.newMailKey)

        await fixture.model.enable()

        XCTAssertEqual(fixture.model.status, .authorized)
        XCTAssertTrue(fixture.defaults.bool(forKey: PlainpostNotificationPreference.newMailKey))
        let calls = await fixture.center.calls()
        XCTAssertEqual(calls.requests, 1)
        XCTAssertEqual(calls.adds, 0, "Permission enablement must not replay prior arrivals.")
    }

    func testDeniedEnableDoesNotTurnOnNewMailPreference() async throws {
        let fixture = PermissionFixture(status: .notDetermined, requestResult: .denied)
        fixture.defaults.set(false, forKey: PlainpostNotificationPreference.newMailKey)

        await fixture.model.enable()

        XCTAssertEqual(fixture.model.status, .denied)
        XCTAssertFalse(fixture.defaults.bool(forKey: PlainpostNotificationPreference.newMailKey))
    }

    func testExistingEnabledUserSeesOneTimeCalloutUntilDismissed() async throws {
        let fixture = PermissionFixture(status: .notDetermined)
        await fixture.model.refresh()

        XCTAssertTrue(fixture.model.shouldShowEnablementCallout)

        fixture.model.dismissCallout()

        XCTAssertFalse(fixture.model.shouldShowEnablementCallout)
        let replacement = NotificationPermissionModel(
            center: fixture.center,
            defaults: fixture.defaults
        )
        await replacement.refresh()
        XCTAssertFalse(replacement.shouldShowEnablementCallout)
        XCTAssertTrue(
            fixture.defaults.object(forKey: PlainpostNotificationPreference.newMailKey) == nil,
            "Not Now must preserve the existing default-on preference."
        )
    }

    func testCalloutRequiresEnabledPreferenceAndNotDeterminedStatus() async throws {
        let disabled = PermissionFixture(status: .notDetermined)
        disabled.defaults.set(false, forKey: PlainpostNotificationPreference.newMailKey)
        await disabled.model.refresh()
        XCTAssertFalse(disabled.model.shouldShowEnablementCallout)

        let denied = PermissionFixture(status: .denied)
        await denied.model.refresh()
        XCTAssertFalse(denied.model.shouldShowEnablementCallout)
    }
}

@MainActor
private final class PermissionFixture {
    let defaults: UserDefaults
    let center: PermissionRecordingCenter
    let model: NotificationPermissionModel

    init(
        status: LocalNotificationAuthorization,
        requestResult: LocalNotificationAuthorization? = nil
    ) {
        let suiteName = "Plainpost.PermissionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        center = PermissionRecordingCenter(
            status: status,
            requestResult: requestResult ?? status
        )
        model = NotificationPermissionModel(center: center, defaults: defaults)
    }
}

private actor PermissionRecordingCenter: SystemNotificationCenterAdapting {
    private let statusValue: LocalNotificationAuthorization
    private let requestResult: LocalNotificationAuthorization
    private var statusCount = 0
    private var requestCount = 0
    private var addCount = 0

    init(
        status: LocalNotificationAuthorization,
        requestResult: LocalNotificationAuthorization
    ) {
        statusValue = status
        self.requestResult = requestResult
    }

    func authorizationStatus() async -> LocalNotificationAuthorization {
        statusCount += 1
        return statusValue
    }

    func requestAuthorization() async throws -> LocalNotificationAuthorization {
        requestCount += 1
        return requestResult
    }

    func add(_ notification: PlainpostNotification) async throws {
        addCount += 1
    }

    func calls() -> (status: Int, requests: Int, adds: Int) {
        (statusCount, requestCount, addCount)
    }
}
