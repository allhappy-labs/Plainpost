import Foundation

enum MailboxScrollCaptureReason {
    case continuousOffset
    case visibilityChanged
    case scrollSettled
    case navigationBoundary

    var requestsPersistence: Bool {
        self == .scrollSettled || self == .navigationBoundary
    }
}

enum MailboxOrderedItemsUpdate: Equatable {
    case unchanged
    case initial
    case appendOnly
    case disruptive

    var requestsRestoration: Bool {
        self == .disruptive
    }
}

enum MailboxScrollActivity: Equatable {
    case idle
    case active
}

enum MailboxOrderedItemsUpdateResolution: Equatable {
    case none
    case restoreCurrentLocation
    case deferUntilSettled
}

struct MailboxOrderedItemsUpdatePlan: Equatable {
    let update: MailboxOrderedItemsUpdate
    let resolution: MailboxOrderedItemsUpdateResolution

    var capturesCurrentLocation: Bool {
        resolution == .restoreCurrentLocation
    }

    var requestsRestoration: Bool {
        resolution == .restoreCurrentLocation
    }
}

struct MailboxSettledAnchorMeasurementToken: Equatable, Hashable, Sendable {
    fileprivate let generation: UInt64
}

struct MailboxSettledAnchorMeasurementRequest: Equatable, Hashable, Sendable {
    let token: MailboxSettledAnchorMeasurementToken
    let anchorID: String
    let context: MailboxListContext
}

struct MailboxScrollContextToken: Equatable, Hashable, Sendable {
    fileprivate let generation: UInt64
    let context: MailboxListContext
}

struct MailboxVisibleIDsUpdate: Equatable {
    let topChanged: Bool
    let measurementRequest: MailboxSettledAnchorMeasurementRequest?
}

@MainActor
final class MailboxScrollRuntime {
    private(set) var contentOffsetY: Double = 0
    private(set) var topVisibleID: String?
    private(set) var anchorViewportOffset: Double = 0
    private(set) var orderedItems: [MailboxScrollItem] = []
    private(set) var orderedMessageIDs: [String] = []
    private(set) var persistenceRequestCount = 0
    private(set) var scrollActivity: MailboxScrollActivity = .idle
    private(set) var hasSettledAnchorMeasurement = false
    private(set) var settledAnchorMeasurementRequest:
        MailboxSettledAnchorMeasurementRequest?
    private(set) var measurementContext: MailboxListContext?
    private(set) var installedScrollContextToken: MailboxScrollContextToken?
    private(set) var requiresSettledAnchorMeasurement = false

    private var lastSettledLocation: MailboxScrollLocation?
    private var scrollContextGeneration: UInt64 = 0
    private var measurementGeneration: UInt64 = 0

    var hasPendingSettledAnchorMeasurement: Bool {
        requiresSettledAnchorMeasurement
            || settledAnchorMeasurementRequest != nil
    }

    func updateContentOffset(_ value: Double) {
        contentOffsetY = value
    }

    @discardableResult
    func updateContentOffset(
        _ value: Double,
        using token: MailboxScrollContextToken
    ) -> Bool {
        guard token == installedScrollContextToken else { return false }
        updateContentOffset(value)
        return true
    }

    @discardableResult
    func updateVisibleIDs(_ ids: [String]) -> Bool {
        let changed = replaceVisibleIDs(ids)
        if changed {
            rearmSettledAnchorMeasurement()
        }
        return changed
    }

    func updateVisibleIDs(
        _ ids: [String],
        using token: MailboxScrollContextToken
    ) -> MailboxVisibleIDsUpdate? {
        guard token == installedScrollContextToken else { return nil }
        let topChanged = replaceVisibleIDs(ids)
        return MailboxVisibleIDsUpdate(
            topChanged: topChanged,
            measurementRequest: topChanged
                ? rearmSettledAnchorMeasurement()
                : nil
        )
    }

    private func replaceVisibleIDs(_ ids: [String]) -> Bool {
        let newTop = ids.first
        guard newTop != topVisibleID else { return false }
        topVisibleID = newTop
        anchorViewportOffset = 0
        hasSettledAnchorMeasurement = false
        requiresSettledAnchorMeasurement = true
        return true
    }

    @discardableResult
    func updateAnchorViewportOffset(_ value: Double, for id: String) -> Bool {
        guard id == topVisibleID else { return false }
        anchorViewportOffset = value
        hasSettledAnchorMeasurement = true
        return true
    }

    func updateScrollActivity(
        _ activity: MailboxScrollActivity,
        using token: MailboxScrollContextToken
    ) -> Bool {
        guard token == installedScrollContextToken else { return false }
        scrollActivity = activity
        if activity == .active {
            hasSettledAnchorMeasurement = false
            requiresSettledAnchorMeasurement = true
            invalidateSettledAnchorMeasurementRequest()
        }
        return true
    }

    func orderedItemsUpdate(
        to items: [MailboxScrollItem]
    ) -> MailboxOrderedItemsUpdate {
        guard items != orderedItems else { return .unchanged }
        guard !orderedItems.isEmpty else { return .initial }
        guard items.count >= orderedItems.count,
              Array(items.prefix(orderedItems.count)) == orderedItems
        else {
            return .disruptive
        }
        return .appendOnly
    }

    func orderedItemsUpdatePlan(
        to items: [MailboxScrollItem]
    ) -> MailboxOrderedItemsUpdatePlan {
        let update = orderedItemsUpdate(to: items)
        let resolution: MailboxOrderedItemsUpdateResolution
        if !update.requestsRestoration {
            resolution = .none
        } else if scrollActivity == .idle && hasSettledAnchorMeasurement {
            resolution = .restoreCurrentLocation
        } else {
            resolution = .deferUntilSettled
        }
        return MailboxOrderedItemsUpdatePlan(
            update: update,
            resolution: resolution
        )
    }

    @discardableResult
    func applyOrderedItemsUpdate(
        _ items: [MailboxScrollItem],
        plan: MailboxOrderedItemsUpdatePlan,
        using token: MailboxScrollContextToken
    ) -> MailboxSettledAnchorMeasurementRequest? {
        guard token == installedScrollContextToken else { return nil }
        updateOrderedItems(items)
        if plan.resolution == .deferUntilSettled {
            requiresSettledAnchorMeasurement = true
            return rearmSettledAnchorMeasurement()
        }
        return nil
    }

    func installScrollContext(
        _ context: MailboxListContext
    ) -> MailboxScrollContextToken {
        scrollContextGeneration &+= 1
        let token = MailboxScrollContextToken(
            generation: scrollContextGeneration,
            context: context
        )
        installedScrollContextToken = token
        measurementContext = context
        scrollActivity = .idle
        topVisibleID = nil
        anchorViewportOffset = 0
        hasSettledAnchorMeasurement = false
        requiresSettledAnchorMeasurement = true
        invalidateSettledAnchorMeasurementRequest()
        return token
    }

    func requestSettledAnchorMeasurement(
        using token: MailboxScrollContextToken
    ) -> MailboxSettledAnchorMeasurementRequest? {
        guard token == installedScrollContextToken else { return nil }
        requiresSettledAnchorMeasurement = true
        return rearmSettledAnchorMeasurement()
    }

    func acceptSettledAnchorMeasurement(
        _ request: MailboxSettledAnchorMeasurementRequest,
        using token: MailboxScrollContextToken,
        anchorViewportOffset: Double
    ) -> Bool {
        guard token == installedScrollContextToken,
              scrollActivity == .idle,
              measurementContext == token.context,
              request.context == token.context,
              settledAnchorMeasurementRequest == request,
              request.anchorID == topVisibleID
        else {
            return false
        }
        self.anchorViewportOffset = anchorViewportOffset
        hasSettledAnchorMeasurement = true
        requiresSettledAnchorMeasurement = false
        settledAnchorMeasurementRequest = nil
        return true
    }

    func authoritativeSettledAnchorMeasurementRequest()
        -> MailboxSettledAnchorMeasurementRequest?
    {
        guard scrollActivity == .idle else { return nil }
        if let request = settledAnchorMeasurementRequest,
           request.context == measurementContext,
           request.anchorID == topVisibleID {
            return request
        }
        guard requiresSettledAnchorMeasurement else { return nil }
        return rearmSettledAnchorMeasurement()
    }

    func updateOrderedItems(_ items: [MailboxScrollItem]) {
        orderedItems = items
        orderedMessageIDs = items.compactMap { item in
            Self.messageID(from: item.id)
        }
        if let topVisibleID,
           !items.contains(where: { $0.id == topVisibleID }) {
            self.topVisibleID = nil
            anchorViewportOffset = 0
            hasSettledAnchorMeasurement = false
            requiresSettledAnchorMeasurement = true
            rearmSettledAnchorMeasurement()
        }
    }

    func capture(
        reason: MailboxScrollCaptureReason,
        selectedMessageID: String? = nil
    ) -> MailboxScrollLocation? {
        guard reason.requestsPersistence else { return nil }

        let location = MailboxScrollLocation(
            anchorID: topVisibleID,
            anchorViewportOffset: anchorViewportOffset,
            contentOffsetY: contentOffsetY,
            orderedItems: orderedItems,
            selectedMessageID: selectedMessageID
        )
        if reason == .scrollSettled {
            guard location != lastSettledLocation else { return nil }
            lastSettledLocation = location
        }

        persistenceRequestCount += 1
        return location
    }

    @discardableResult
    private func rearmSettledAnchorMeasurement()
        -> MailboxSettledAnchorMeasurementRequest?
    {
        invalidateSettledAnchorMeasurementRequest()
        guard requiresSettledAnchorMeasurement,
              scrollActivity == .idle,
              let anchorID = topVisibleID,
              let context = measurementContext
        else {
            return nil
        }
        let request = MailboxSettledAnchorMeasurementRequest(
            token: MailboxSettledAnchorMeasurementToken(
                generation: measurementGeneration
            ),
            anchorID: anchorID,
            context: context
        )
        settledAnchorMeasurementRequest = request
        return request
    }

    private func invalidateSettledAnchorMeasurementRequest() {
        measurementGeneration &+= 1
        settledAnchorMeasurementRequest = nil
    }

    private static func messageID(from scrollID: String) -> String? {
        let prefix = "message-"
        guard scrollID.hasPrefix(prefix) else { return nil }
        return String(scrollID.dropFirst(prefix.count))
    }
}
