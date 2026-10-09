import XCTest
@testable import PlainpostCore
import PlainpostTestSupport

final class XOAUTH2TransportTests: XCTestCase {
    func testIMAPAndSMTPAuthenticateWithXOAUTH2AndRejectRevokedToken() async throws {
        let fixture = try await XOAUTH2MailFixture.start(username: "ada@example.test", acceptedToken: "access-1")
        defer { fixture.stop() }
        let imap = MailTransportClientFactory.imapClient(host: "127.0.0.1", port: fixture.imapPort)
        try await imap.authenticate(username: "ada@example.test", authentication: .xoauth2(accessToken: "access-1"))
        _ = try await imap.selectMailbox("INBOX")
        await imap.disconnect()

        let revoked = MailTransportClientFactory.imapClient(host: "127.0.0.1", port: fixture.imapPort)
        do {
            try await revoked.authenticate(username: "ada@example.test", authentication: .xoauth2(accessToken: "revoked"))
            XCTFail("revoked token authenticated")
        } catch MailAuthenticationError.rejected {}
        await revoked.disconnect()

        let smtp = MailTransportClientFactory.smtpClient(host: "127.0.0.1", port: fixture.smtpPort)
        try await smtp.send(username: "ada@example.test", authentication: .xoauth2(accessToken: "access-1"),
                            from: EmailAddress("ada@example.test"), to: [EmailAddress("fixture@example.test")],
                            data: "Subject: t\r\n\r\nbody")
        XCTAssertFalse(fixture.transcript.contains("LOGIN "))
        XCTAssertFalse(fixture.transcript.contains("AUTH PLAIN"))
        XCTAssertEqual(fixture.acceptedAuthenticationCount, 2)
    }

    func testSMTPRejectsRevokedTokenBeforeAnyEnvelope() async throws {
        let fixture = try await XOAUTH2MailFixture.start(username: "ada@example.test", acceptedToken: "access-1")
        defer { fixture.stop() }
        let smtp = MailTransportClientFactory.smtpClient(host: "127.0.0.1", port: fixture.smtpPort)
        do {
            try await smtp.send(username: "ada@example.test", authentication: .xoauth2(accessToken: "revoked"),
                                from: EmailAddress("ada@example.test"), to: [EmailAddress("fixture@example.test")],
                                data: "Subject: t\r\n\r\nbody")
            XCTFail("revoked token sent mail")
        } catch MailAuthenticationError.rejected {}
        XCTAssertEqual(fixture.acceptedAuthenticationCount, 0)
        XCTAssertEqual(fixture.acceptedMessageCount, 0)
        XCTAssertFalse(fixture.transcript.contains("MAIL FROM"))
        XCTAssertTrue(fixture.transcript.contains("AUTH XOAUTH2 <xoauth2>"))
    }

    func testMissingXOAUTH2CapabilityFailsWithoutSendingToken() async throws {
        let fixture = try await XOAUTH2MailFixture.start(
            username: "ada@example.test", acceptedToken: "access-1", advertisesXOAUTH2: false)
        defer { fixture.stop() }
        let imap = MailTransportClientFactory.imapClient(host: "127.0.0.1", port: fixture.imapPort)
        do {
            try await imap.authenticate(username: "ada@example.test", authentication: .xoauth2(accessToken: "access-1"))
            XCTFail("IMAP authenticated without XOAUTH2 capability")
        } catch MailAuthenticationError.mechanismUnavailable {}
        await imap.disconnect()

        let smtp = MailTransportClientFactory.smtpClient(host: "127.0.0.1", port: fixture.smtpPort)
        do {
            try await smtp.send(username: "ada@example.test", authentication: .xoauth2(accessToken: "access-1"),
                                from: EmailAddress("ada@example.test"), to: [EmailAddress("fixture@example.test")],
                                data: "Subject: t\r\n\r\nbody")
            XCTFail("SMTP authenticated without XOAUTH2 capability")
        } catch MailAuthenticationError.mechanismUnavailable {}
        XCTAssertFalse(fixture.transcript.contains("AUTHENTICATE"))
        XCTAssertFalse(fixture.transcript.contains("AUTH "))
        XCTAssertEqual(fixture.acceptedAuthenticationCount, 0)
    }

    func testIMAPWithoutSASLIRSendsPayloadAfterContinuation() async throws {
        let fixture = try await XOAUTH2MailFixture.start(
            username: "ada@example.test", acceptedToken: "access-1", advertisesSASLIR: false)
        defer { fixture.stop() }
        let imap = MailTransportClientFactory.imapClient(host: "127.0.0.1", port: fixture.imapPort)
        try await imap.authenticate(username: "ada@example.test", authentication: .xoauth2(accessToken: "access-1"))
        _ = try await imap.selectMailbox("INBOX")
        await imap.disconnect()
        XCTAssertEqual(fixture.acceptedAuthenticationCount, 1)
        XCTAssertTrue(fixture.transcript.contains("AUTHENTICATE XOAUTH2\n<xoauth2>"))
    }

    func testIMAPTemporaryRefusalIsNotACredentialRejection() async throws {
        let fixture = try await XOAUTH2MailFixture.start(
            username: "ada@example.test", acceptedToken: "access-1", imapRefusalResponseCode: "UNAVAILABLE")
        defer { fixture.stop() }
        let imap = MailTransportClientFactory.imapClient(host: "127.0.0.1", port: fixture.imapPort)
        do {
            try await imap.authenticate(username: "ada@example.test", authentication: .xoauth2(accessToken: "access-1"))
            XCTFail("temporary refusal authenticated")
        } catch MailAuthenticationError.rejected {
            XCTFail("a temporary server refusal must not drive token refresh or reauthorization")
        } catch IMAPClientError.throttled {}
        await imap.disconnect()
    }

    func testPasswordAuthenticationStillUsesLoginThroughTheNewRequirement() async throws {
        let server = LocalIMAPServer(username: "me@example.com", password: "secret", message: PlainpostFixtures.aliceMessage)
        try await server.start()
        defer { server.stop() }
        let imap = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await imap.authenticate(username: "me@example.com", authentication: .password("secret"))
        _ = try await imap.selectMailbox("INBOX")
        await imap.disconnect()
        XCTAssertEqual(server.loginCommandCount, 1)
    }

    func testTranscriptNeverRetainsTokenOrPayload() async throws {
        let fixture = try await XOAUTH2MailFixture.start(username: "ada@example.test", acceptedToken: "access-1")
        defer { fixture.stop() }
        let imap = MailTransportClientFactory.imapClient(host: "127.0.0.1", port: fixture.imapPort)
        try await imap.authenticate(username: "ada@example.test", authentication: .xoauth2(accessToken: "access-1"))
        await imap.disconnect()
        let payload = try XOAUTH2.initialClientResponse(username: "ada@example.test", accessToken: "access-1")
        XCTAssertFalse(fixture.transcript.contains("access-1"))
        XCTAssertFalse(fixture.transcript.contains(payload))
    }

    // MARK: Refusal classification (only credential refusals drive refresh and reauthorization)

    private func imapOutcome(_ refusals: XOAUTH2MailFixture.Refusals) async throws -> Error? {
        let fixture = try await XOAUTH2MailFixture.start(
            username: "ada@example.test", acceptedToken: "access-1", refusals: refusals)
        defer { fixture.stop() }
        let imap = MailTransportClientFactory.imapClient(host: "127.0.0.1", port: fixture.imapPort)
        var outcome: Error?
        do {
            try await imap.authenticate(username: "ada@example.test", authentication: .xoauth2(accessToken: "stale"))
        } catch {
            outcome = error
        }
        await imap.disconnect()
        return outcome
    }

    private func smtpOutcome(_ refusals: XOAUTH2MailFixture.Refusals) async throws -> (Error?, String) {
        let fixture = try await XOAUTH2MailFixture.start(
            username: "ada@example.test", acceptedToken: "access-1", refusals: refusals)
        defer { fixture.stop() }
        let smtp = MailTransportClientFactory.smtpClient(host: "127.0.0.1", port: fixture.smtpPort)
        do {
            try await smtp.send(username: "ada@example.test", authentication: .xoauth2(accessToken: "stale"),
                                from: EmailAddress("ada@example.test"), to: [EmailAddress("fixture@example.test")],
                                data: "Subject: t\r\n\r\nbody")
            return (nil, fixture.transcript)
        } catch {
            return (error, fixture.transcript)
        }
    }

    func testGmailAlertLimitRefusalsWithoutChallengeAreThrottledNotRejected() async throws {
        for alert in [
            "NO [ALERT] Too many simultaneous connections. (Failure)",
            "NO [ALERT] Account exceeded command or bandwidth limits. (Failure)",
            "NO Temporary server failure",
        ] {
            let error = try await imapOutcome(.init(imapWithoutChallenge: alert))
            XCTAssertEqual(error as? IMAPClientError, .throttled, alert)
            XCTAssertNil(error as? MailAuthenticationError, alert)
        }
        let limit = try await imapOutcome(.init(imapWithoutChallenge: "NO [LIMIT] Too many connections"))
        XCTAssertEqual(limit as? IMAPClientError, .connectionLimit)
    }

    /// Gmail refuses a grant it wants the user to re-approve in a browser with
    /// a web-login alert and no SASL error challenge. That is a durable
    /// credential refusal: retrying it to the attempt limit and reporting a
    /// temporary limit would never show Reauthorize Gmail.
    func testIMAPWebLoginAlertsWithoutChallengeAreCredentialRefusals() async throws {
        for alert in [
            "NO [ALERT] Please log in via your web browser: "
                + "https://support.google.com/mail/accounts/answer/78754 (Failure)",
            "NO [WEBALERT https://accounts.google.com/signin/continue] Web login required. (Failure)",
            "NO [webalert https://accounts.google.com/signin/continue] Web login required.",
            "NO Please log in via your web browser.",
        ] {
            let error = try await imapOutcome(.init(imapWithoutChallenge: alert))
            XCTAssertEqual(error as? MailAuthenticationError, .rejected, alert)
        }
    }

    /// A connection-limit refusal stays a limit even when Gmail attaches a
    /// web-login hint: the limit code is the more specific signal.
    func testIMAPConnectionLimitStillWinsOverAWebLoginAlert() async throws {
        let error = try await imapOutcome(
            .init(imapWithoutChallenge: "NO [LIMIT] Too many simultaneous connections; log in via your web browser"))
        XCTAssertEqual(error as? IMAPClientError, .connectionLimit)
        XCTAssertNil(error as? MailAuthenticationError)
    }

    func testIMAPErrorChallengeFollowedByAnyNoIsRejected() async throws {
        for refusal in [
            "NO [ALERT] Invalid credentials (Failure)",
            "NO Invalid credentials (Failure)",
            "NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)",
        ] {
            let error = try await imapOutcome(.init(imapAfterChallenge: refusal))
            XCTAssertEqual(error as? MailAuthenticationError, .rejected, refusal)
        }
    }

    /// A connection-limit refusal must drive a retry-with-backoff, not
    /// reauthorization, even when Google's SASL error challenge preceded it:
    /// the challenge alone does not make a `[LIMIT]`/`[INUSE]` refusal a
    /// credential refusal.
    func testIMAPErrorChallengeFollowedByConnectionLimitIsThrottledNotRejected() async throws {
        for refusal in [
            "NO [LIMIT] Too many simultaneous connections",
            "NO [INUSE] Mailbox in use, try again later",
        ] {
            let error = try await imapOutcome(.init(imapAfterChallenge: refusal))
            XCTAssertEqual(error as? IMAPClientError, .connectionLimit, refusal)
            XCTAssertNil(error as? MailAuthenticationError, refusal)
        }
    }

    func testIMAPCredentialResponseCodesWithoutChallengeAreRejected() async throws {
        for refusal in [
            "NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)",
            "NO [AUTHORIZATIONFAILED] Not authorized",
            "NO [EXPIRED] Token expired",
            "NO [authenticationfailed] lower-case code",
        ] {
            let error = try await imapOutcome(.init(imapWithoutChallenge: refusal))
            XCTAssertEqual(error as? MailAuthenticationError, .rejected, refusal)
        }
    }

    func testSMTPTemporaryAuthenticationRefusalsAreNotRejected() async throws {
        for lines in [
            ["454 4.7.0 Too many login attempts, please try again later."],
            ["421 4.7.0 Try again later, closing connection."],
            ["432 4.7.12 A password transition is needed"],
        ] {
            let (error, transcript) = try await smtpOutcome(.init(smtpWithoutChallenge: lines))
            XCTAssertEqual(error as? MailAuthenticationError, .temporarilyRefused, lines[0])
            XCTAssertFalse(transcript.contains("MAIL FROM"))
        }
        let (afterChallenge, _) = try await smtpOutcome(.init(smtpAfterChallenge: ["454 4.7.0 Temporary authentication failure"]))
        XCTAssertEqual(afterChallenge as? MailAuthenticationError, .temporarilyRefused)
    }

    func testSMTPCredentialRefusalNeedsTheChallengeOr578() async throws {
        let (withoutChallenge, transcript) = try await smtpOutcome(.init(smtpWithoutChallenge: [
            "535-5.7.8 Username and Password not accepted.",
            "535 5.7.8 https://support.google.com/mail/?p=BadCredentials",
        ]))
        XCTAssertEqual(withoutChallenge as? MailAuthenticationError, .rejected)
        XCTAssertFalse(transcript.contains("MAIL FROM"))

        let (challenged, _) = try await smtpOutcome(.init(smtpAfterChallenge: ["535 5.7.1 Credentials rejected"]))
        XCTAssertEqual(challenged as? MailAuthenticationError, .rejected)

        let (other535, _) = try await smtpOutcome(.init(smtpWithoutChallenge: ["535 5.7.0 Something else"]))
        XCTAssertNotEqual(other535 as? MailAuthenticationError, .rejected)
    }

    /// `534 5.7.14` is Gmail's "log in via your web browser" refusal. Like its
    /// IMAP twin it arrives without a SASL error challenge and never clears by
    /// itself, so it must reach Reauthorize Gmail instead of a retry loop.
    func testSMTPWebLoginRefusalIsACredentialRefusal() async throws {
        for lines in [
            ["534-5.7.14 <https://accounts.google.com/signin/continue> Please log in via",
             "534 5.7.14 your web browser. For more information, go to"],
            ["534 5.7.14 Please log in via your web browser"],
        ] {
            let (error, transcript) = try await smtpOutcome(.init(smtpWithoutChallenge: lines))
            XCTAssertEqual(error as? MailAuthenticationError, .rejected, lines[0])
            XCTAssertFalse(transcript.contains("MAIL FROM"))
        }
        // Other 534 replies carry no durable-refusal marker and stay transient.
        let (other534, _) = try await smtpOutcome(.init(smtpWithoutChallenge: ["534 5.7.9 Application-specific password required"]))
        XCTAssertNotEqual(other534 as? MailAuthenticationError, .rejected)
    }
}
