import Foundation
import PlainpostOperations

enum SmartInboxActivityControl: Equatable {
    case pause
    case pausing
    case resume
}

public struct SmartInboxActivityPresentation: Equatable, Identifiable {
    public let id: String
    let title: String
    let detail: String?
    let compactDetail: String?
    let errorDetail: String?
    let processed: Int
    let total: Int?
    let remaining: Int?
    let fraction: Double?
    let control: SmartInboxActivityControl?
    let accessibilityLabel: String

    /// `lowPowerAllowsWork`: Low Power Mode no longer blocks Smart Inbox, so a job still
    /// paused for it (its automatic lift failed) offers Resume.
    init?(job: PlainpostDurableJob?, lowPowerAllowsWork: Bool = false, locale: Locale = .current) {
        guard let job else { return nil }
        guard job.state != .completed,
              job.state != .cancelled,
              job.state != .deliveryUncertain else {
            return nil
        }

        let processed = max(job.progress?.current ?? 0, 0)
        let total = job.progress?.total.map { max($0, 0) }
        let remaining = total.map { max($0 - processed, 0) }
        let fraction = total.flatMap {
            $0 > 0 ? min(max(Double(processed) / Double($0), 0), 1) : nil
        }
        let title: String
        let control: SmartInboxActivityControl?
        let errorDetail: String?

        switch job.state {
        case .queued:
            title = total == nil ? "Preparing Smart Inbox..." : "Waiting to organize"
            control = .pause
            errorDetail = nil
        case .running where job.pauseRequested || job.progress?.phase == "pausing":
            title = "Pausing Smart Inbox..."
            control = .pausing
            errorDetail = nil
        case .running:
            title = "Organizing Smart Inbox"
            control = .pause
            errorDetail = nil
        case .paused where job.pauseReason == "low-power" && lowPowerAllowsWork:
            title = "Smart Inbox paused"
            control = .resume
            errorDetail = nil
        case .paused where job.pauseReason == "low-power":
            // Sorting resumes by itself when Low Power Mode ends.
            title = "Paused in Low Power Mode"
            control = nil
            errorDetail = nil
        case .paused where job.pauseReason == "user-requested":
            title = "Smart Inbox paused"
            control = .resume
            errorDetail = nil
        case .paused:
            title = Self.automaticPauseTitle(reason: job.pauseReason)
            control = nil
            errorDetail = nil
        case .failed:
            title = "Smart Inbox stopped"
            control = nil
            errorDetail = "Smart Inbox couldn't finish. Try again."
        case .completed, .cancelled, .deliveryUncertain:
            return nil
        }

        let detail: String?
        let compactDetail: String?
        let progressAccessibility: String?
        if job.state == .failed {
            let count = Self.formatted(processed, locale: locale)
            detail = processed > 0 ? "\(count) processed before stopping" : nil
            compactDetail = processed > 0 ? "\(count) processed" : nil
            progressAccessibility = detail
        } else {
            detail = Self.progressDetail(
                processed: processed,
                total: total,
                remaining: remaining,
                locale: locale
            )
            compactDetail = Self.compactProgressDetail(
                processed: processed,
                total: total,
                locale: locale
            )
            progressAccessibility = Self.progressAccessibility(
                processed: processed,
                total: total,
                remaining: remaining,
                locale: locale
            )
        }

        self.id = job.id
        self.title = title
        self.detail = detail
        self.compactDetail = compactDetail
        self.errorDetail = errorDetail
        self.processed = processed
        self.total = total
        self.remaining = remaining
        self.fraction = fraction
        self.control = control
        self.accessibilityLabel = ([title, progressAccessibility, errorDetail]
            .compactMap { $0 })
            .joined(separator: ", ")
    }

    /// Every field as given, for tests and previews that need a presentation no job produces.
    init(
        id: String,
        title: String,
        detail: String?,
        compactDetail: String?,
        errorDetail: String?,
        processed: Int,
        total: Int?,
        remaining: Int?,
        fraction: Double?,
        control: SmartInboxActivityControl?,
        accessibilityLabel: String
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.compactDetail = compactDetail
        self.errorDetail = errorDetail
        self.processed = processed
        self.total = total
        self.remaining = remaining
        self.fraction = fraction
        self.control = control
        self.accessibilityLabel = accessibilityLabel
    }

    @_spi(DesignPreview)
    public init?(
        designPreviewJob job: PlainpostDurableJob?,
        locale: Locale = .current
    ) {
        self.init(job: job, locale: locale)
    }

    private static func automaticPauseTitle(reason: String?) -> String {
        switch reason {
        case "thread-summary":
            return "Paused for a thread summary"
        case "message-translation":
            return "Paused for message translation"
        case "thread-question":
            return "Paused for a thread question"
        case "mailbox-question":
            return "Paused for a mailbox question"
        case "ai-draft":
            return "Paused for an AI draft"
        case "draft-rewrite":
            return "Paused for an AI draft rewrite"
        case "message-classification":
            return "Paused for message classification"
        case "interactive-ai":
            return "Paused for interactive AI work"
        case "mail-sync":
            return "Waiting for mail sync"
        case "mail-sync-failed":
            return "Waiting for successful mail sync"
        case "credentials-unavailable":
            return "Waiting for Mail Keychain"
        default:
            return "Paused for interactive AI work"
        }
    }

    private static func progressDetail(
        processed: Int,
        total: Int?,
        remaining: Int?,
        locale: Locale
    ) -> String? {
        if let remaining {
            return "\(formatted(processed, locale: locale)) processed · \(formatted(remaining, locale: locale)) left"
        }
        return processed > 0 ? "\(formatted(processed, locale: locale)) processed" : nil
    }

    private static func progressAccessibility(
        processed: Int,
        total: Int?,
        remaining: Int?,
        locale: Locale
    ) -> String? {
        if let total, let remaining {
            return "\(formatted(processed, locale: locale)) of \(formatted(total, locale: locale)) processed, \(formatted(remaining, locale: locale)) left"
        }
        return processed > 0 ? "\(formatted(processed, locale: locale)) processed" : nil
    }

    private static func compactProgressDetail(
        processed: Int,
        total: Int?,
        locale: Locale
    ) -> String? {
        guard let total else { return nil }
        return "\(formatted(processed, locale: locale))/\(formatted(total, locale: locale))"
    }

    private static func formatted(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
