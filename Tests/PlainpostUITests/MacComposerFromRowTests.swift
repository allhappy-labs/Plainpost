import XCTest
import PlainpostCore
@testable import PlainpostUI
#if os(macOS)
import AppKit
import SwiftUI

/// The Mac composer's From row: a picker for a new message when there is more than one
/// account, the fixed address for a reply, nothing with one account.
@MainActor
final class MacComposerFromRowTests: XCTestCase {
    private func account(_ id: String) -> Account {
        Account(id: AccountID(id), displayName: id, email: EmailAddress("\(id)@example.com"),
                imapHost: "imap.example.com", smtpHost: "smtp.example.com")
    }

    private func composer(_ accounts: [Account]) -> ComposerViewModel {
        ComposerViewModel(
            composer: UnavailableComposerDraftHandler(),
            fromAccounts: ComposerFromAccounts(
                accounts: { accounts },
                defaultAccountID: { accounts.first?.id },
                owner: { _ in accounts.last?.id },
                makeComposer: { _ in UnavailableComposerDraftHandler() }
            )
        )
    }

    private func host(_ composer: ComposerViewModel) -> AcceptanceHost {
        AcceptanceHost(ComposerFromRow(viewModel: composer).frame(width: 520), size: NSSize(width: 560, height: 120))
    }

    func testNewMessageWithTwoAccountsShowsAFromPicker() async throws {
        let model = composer([account("home"), account("work")])
        model.prepareNewMessage()
        let host = host(model)
        defer { host.close() }
        let picker = await host.waitFor { elements in
            elements.contains { HostedAX.identifier($0) == "compose.from-picker" }
        }
        XCTAssertTrue(picker, host.axDump().joined(separator: "\n"))
    }

    func testAReplyShowsItsFixedFromAddress() async throws {
        let model = composer([account("home"), account("work")])
        model.prepareReply(context: ComposerReplyContext(
            sourceThreadID: nil, sourceMessageID: MessageID("m1"), rfcMessageID: nil, sourceInReplyTo: nil,
            references: [], recipient: "someone@example.com", subject: "Hi", senderName: "Someone",
            dateLabel: "Today", quotedBody: "Hi"
        ))
        let host = host(model)
        defer { host.close() }
        let shown = await host.waitFor { elements in
            elements.flatMap(HostedAX.texts).contains("work@example.com")
        }
        XCTAssertTrue(shown, host.axDump().joined(separator: "\n"))
        XCTAssertFalse(host.axDump().contains { $0.contains("compose.from-picker") })
    }

    func testOneAccountShowsNoFromRow() async throws {
        let model = composer([account("home")])
        model.prepareNewMessage()
        let host = host(model)
        defer { host.close() }
        await host.settle()
        XCTAssertFalse(host.allTexts().contains("From"), host.axDump().joined(separator: "\n"))
        XCTAssertFalse(host.axDump().contains { $0.contains("compose.from-picker") })
    }

    /// A reply whose original's account is gone says why it can't be sent.
    func testABlockedReplySaysWhy() async throws {
        let model = ComposerViewModel(
            composer: UnavailableComposerDraftHandler(),
            fromAccounts: ComposerFromAccounts(
                accounts: { [self.account("home"), self.account("work")] },
                defaultAccountID: { AccountID("home") },
                owner: { _ in AccountID("gone") },
                makeComposer: { _ in UnavailableComposerDraftHandler() }
            )
        )
        model.prepareReply(context: ComposerReplyContext(
            sourceThreadID: nil, sourceMessageID: MessageID("m1"), rfcMessageID: nil, sourceInReplyTo: nil,
            references: [], recipient: "someone@example.com", subject: "Hi", senderName: "Someone",
            dateLabel: "Today", quotedBody: "Hi"
        ))
        let host = host(model)
        defer { host.close() }
        let shown = await host.waitFor { elements in
            elements.flatMap(HostedAX.texts).contains(ComposerViewModel.missingFromAccountReason)
        }
        XCTAssertTrue(shown, host.axDump().joined(separator: "\n"))
    }
}
#endif
