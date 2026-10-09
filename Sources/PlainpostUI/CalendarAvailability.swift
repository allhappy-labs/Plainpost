import Foundation
import PlainpostAccountRuntime
import PlainpostNodeTransport

/// What the Sync Node's calendar capability probe established. Calendar UI is
/// shown only for an enabled Node; a Node without the calendar routes needs an
/// update, and a Node that has not assembled every calendar owner (`disabled`)
/// has no calendar UI at all.
public enum CalendarAvailability: Equatable, Sendable {
    case unknown, enabled, disabled, updateRequired

    public var showsCalendar: Bool { self == .enabled }

    /// A transient probe failure keeps the last capability this account's Node
    /// reported, so cached calendars stay reachable while offline.
    static func probe(_ service: any CalendarServing, lastKnownEnabled: Bool?) async -> CalendarAvailability {
        await probeSetup(service, lastKnownEnabled: lastKnownEnabled).availability
    }

    /// The capability probe together with the Node's Google client availability.
    /// Google is `unknown` whenever the Node's capability could not be read.
    static func probeSetup(_ service: any CalendarServing, lastKnownEnabled: Bool?) async -> (availability: CalendarAvailability, google: CalendarGoogleSetup) {
        do {
            let capabilities = try await service.capabilities()
            guard capabilities.enabled else { return (.disabled, .unknown) }
            return (.enabled, CalendarGoogleSetup(capabilities.google))
        } catch NodeCalendarError.unsupported {
            return (.updateRequired, .unknown)
        } catch {
            return (lastKnownEnabled == true ? .enabled : .unknown, .unknown)
        }
    }

    /// Settings explain a Node that offers no calendar; the week view and mail
    /// threads show nothing for it.
    var settingsMessage: String? {
        switch self {
        case .disabled: "Calendar isn’t available on this Sync Node."
        case .updateRequired: "Calendar unavailable. Update your Sync Node to use Calendar."
        case .unknown, .enabled: nil
        }
    }

    /// Leaving a calendar destination that the Node no longer offers.
    static func destination(_ selected: PlainpostDestination, availability: CalendarAvailability) -> PlainpostDestination {
        #if os(macOS)
        if selected == .calendar, availability == .disabled || availability == .updateRequired { return .allInboxes }
        #endif
        return selected
    }
}

/// Whether the Sync Node can complete Google Calendar consent. The client ID
/// comes from the Node; the user never types it.
public enum CalendarGoogleSetup: Equatable, Sendable {
    case unknown, notConfigured, configured(clientID: String)

    init(_ availability: NodeCalendarGoogleAvailability) {
        if availability.configured, let clientID = availability.clientID, !clientID.isEmpty {
            self = .configured(clientID: clientID)
        } else {
            self = .notConfigured
        }
    }

    var clientID: String? {
        if case .configured(let clientID) = self { return clientID }
        return nil
    }

    var settingsMessage: String? {
        self == .notConfigured ? "Your Sync Node has no Google Calendar client configured." : nil
    }
}

extension CalendarSnapshotCache {
    func loadAvailability() -> Bool? { try? read("availability.json") }
    func saveAvailability(_ enabled: Bool) { try? write(enabled, name: "availability.json") }
}
