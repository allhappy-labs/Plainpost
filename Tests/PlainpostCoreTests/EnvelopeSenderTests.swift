import XCTest
@testable import PlainpostCore

final class EnvelopeSenderTests: XCTestCase {
    func testFromHeaderWinsOverEnvelopeAndSenderHeaders() throws {
        let header = """
        Return-Path: <0100019a-bounces@amazonses.com>\r
        Received: from a8-30.smtp-out.amazonses.com (a8-30.smtp-out.amazonses.com [54.240.8.30])\r
        Sender: bounces@amazonses.com\r
        From: Vercel <notifications@vercel.com>\r
        Subject: Deployment ready\r
        \r

        """
        let parsed = try IMAPMessageParser.parseForSync(header: header, bodyData: Data("Body".utf8))
        XCTAssertEqual(parsed.from.rawValue, "notifications@vercel.com")
        XCTAssertEqual(parsed.fromDisplayName, "Vercel")
    }
}
