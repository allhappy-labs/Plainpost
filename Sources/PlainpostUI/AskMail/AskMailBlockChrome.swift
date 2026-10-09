import PlainpostCore
import SwiftUI

extension AskMailTint {
    var color: Color {
        switch self {
        case .blue: .blue
        case .teal: .teal
        case .purple: .purple
        case .green: .green
        case .orange: .orange
        case .pink: .pink
        case .gray: .gray
        }
    }
}

extension AskMailIcon {
    var systemImage: String {
        switch self {
        case .tray: "tray"
        case .person: "person.fill"
        case .bell: "bell.fill"
        case .newspaper: "newspaper.fill"
        case .receipt: "doc.text.fill"
        case .airplane: "airplane"
        case .calendar: "calendar"
        case .creditCard: "creditcard.fill"
        case .shippingBox: "shippingbox.fill"
        case .quote: "quote.opening"
        case .draft: "square.and.pencil"
        case .magnifier: "magnifyingglass"
        case .shield: "lock.shield.fill"
        case .sparkles: "sparkles"
        }
    }
}

extension AskMailCardKind {
    var icon: AskMailIcon {
        switch self {
        case .flight: .airplane
        case .invoice: .receipt
        case .event, .booking: .calendar
        case .delivery: .shippingBox
        case .other: .sparkles
        }
    }

    var tint: AskMailTint {
        switch self {
        case .flight: .blue
        case .invoice: .green
        case .event: .purple
        case .delivery: .orange
        case .booking: .teal
        case .other: .gray
        }
    }

    var label: String {
        switch self {
        case .flight: "Flight"
        case .invoice: "Invoice"
        case .event: "Event"
        case .delivery: "Delivery"
        case .booking: "Booking"
        case .other: "Details"
        }
    }
}

/// Lock-popover copy: "this device" wording only for providers known to run locally
/// (`localOnly == true`); remote or not-yet-known providers get the neutral wording.
enum AskMailPrivacyCopy {
    static func title(localOnly: Bool?) -> String {
        localOnly == true ? "Private to this device" : "About your data"
    }

    static func body(providerName: String, localOnly: Bool?) -> String {
        if localOnly == false {
            return "Your question and the mail used to answer it are sent to \(providerName)."
        }
        guard localOnly == true else { return "Answers use \(providerName)." }
        if providerName.localizedCaseInsensitiveContains("ollama") {
            return "Questions and answers are processed with Ollama on this Mac. Nothing is sent to a server."
        }
        return "Questions and answers are processed on this device with \(providerName). Nothing is sent to a server."
    }
}

enum AskMailFill {
    /// Soft fill for question bubbles, token and citation capsules. macOS `controlColor` is white in
    /// light mode, which would make these disappear on the white inspector, so use a tinted primary.
    static var soft: Color {
        #if os(macOS)
        Color.primary.opacity(0.08)
        #else
        MailDesign.control
        #endif
    }
}

/// Rounded container shared by every Ask Mail block.
struct AskMailBlockContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MailDesign.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(MailDesign.stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Block header: tinted icon square, title, secondary detail (count or card title), trailing badge.
struct AskMailBlockHeader: View {
    let icon: AskMailIcon
    let tint: AskMailTint
    let title: String
    var detail: String?
    var badge: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(tint.color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MailDesign.secondaryText)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(MailDesign.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let badge {
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Selection check circle: all / some / none → filled check, filled minus, empty circle.
struct AskMailCheckCircle: View {
    let state: AskMailSectionCheckState

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18))
            .foregroundStyle(state == .none ? AnyShapeStyle(MailDesign.tertiaryText) : AnyShapeStyle(Color.accentColor))
            .frame(width: 22, height: 22)
    }

    private var symbol: String {
        switch state {
        case .all: "checkmark.circle.fill"
        case .some: "minus.circle.fill"
        case .none: "circle"
        }
    }
}

/// Small accent "soft" button used for Reply and Open links inside blocks.
struct AskMailSoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(MailDesign.selectionSoft, in: Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension Date {
    /// Short relative-ish stamp for Ask Mail rows: time today, weekday this week, else day + month.
    var askMailShortStamp: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if let days = calendar.dateComponents([.day], from: self, to: .now).day, days < 7 {
            return formatted(.dateTime.weekday(.abbreviated))
        }
        return formatted(.dateTime.day().month(.abbreviated))
    }
}
