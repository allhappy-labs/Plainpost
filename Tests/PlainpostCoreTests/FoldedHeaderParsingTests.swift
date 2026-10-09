import XCTest
@testable import PlainpostCore

final class FoldedHeaderParsingTests: XCTestCase {
    /// GitHub, Helsana and many others fold the DKIM `h=` tag so a continuation
    /// line reads `Date:From:…`. Only an unfolded line starts a header field.
    func testFoldedContinuationThatLooksLikeAFieldIsNotThatField() throws {
        let header = """
        DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed; d=github.com;\r
        \ts=pf2023; t=1791300000; bh=abc=; h=\r
        \tDate:From:Reply-To:To:Cc:In-Reply-To:References:Subject:List-ID:\r
        \t List-Archive:List-Post:List-Unsubscribe:From;\r
        \tb=xyz\r
        Date: Mon, 06 Oct 2026 07:12:34 -0700\r
        From: Ada <notifications@github.com>\r
        Subject: Re: [olhapi/mvphoto] fix: a srcset rung\r
        Message-ID: <a@github.com>\r
        \r

        """
        let parsed = try IMAPMessageParser.parseForSync(header: header, bodyData: Data("Body".utf8))
        XCTAssertEqual(parsed.sentAt, Date(timeIntervalSince1970: 1_791_295_954))
        XCTAssertEqual(parsed.from.rawValue, "notifications@github.com")
        XCTAssertEqual(parsed.subject, "Re: [olhapi/mvphoto] fix: a srcset rung")
    }

    /// `IMAPClient` splices the header literal straight after the FETCH
    /// prefix, so the first field shares a line with `* 5 FETCH (…`. Helsana's
    /// Outlook puts From first; reading it as a loose `From:` scan made the
    /// sender `o@olhapi.com` and a reply went back to the account itself.
    func testFirstFieldOfAFetchedHeaderLiteralIsRead() throws {
        let header = "* 5 FETCH (UID 2268 FLAGS (\\Seen) INTERNALDATE \"05-Oct-2026 10:26:21 +0000\" "
            + "BODY[HEADER.FIELDS (FROM REPLY-TO TO CC BCC SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES CONTENT-TYPE CONTENT-DISPOSITION X-PLAINPOST-ACCOUNT-VERIFICATION)] "
            + "From: Furrer Jeremy Shawn <jeremyshawn.furrer@helsana.ch>\r\n"
            + "To: Oleh Vdovenko <o@olhapi.com>\r\n"
            + "Subject: RE: FW: Med. Kundenrueckfrage\r\n"
            + "Date: Mon, 5 Oct 2026 10:26:21 +0000\r\n"
            + "Message-ID: <BR0PR08MB5926@eurprd08.prod.outlook.com>\r\n"
            + "Content-Type: multipart/related; boundary=\"b\"\r\n"
            + "\r\n"
            + " RFC822.SIZE 45691)"
        let parsed = try IMAPMessageParser.parseForSync(header: header, bodyData: Data("Body".utf8))
        XCTAssertEqual(parsed.from.rawValue, "jeremyshawn.furrer@helsana.ch")
        XCTAssertEqual(parsed.fromDisplayName, "Furrer Jeremy Shawn")
        XCTAssertEqual(parsed.to.map(\.rawValue), ["o@olhapi.com"])
        XCTAssertEqual(parsed.messageID, "<BR0PR08MB5926@eurprd08.prod.outlook.com>")
    }

    /// A first field other than From was silently dropped the same way.
    func testFirstFieldOtherThanFromIsNotDropped() throws {
        let header = "* 9 FETCH (UID 9 BODY[HEADER.FIELDS (FROM TO MESSAGE-ID)] "
            + "Message-ID: <first@example.com>\r\n"
            + "From: Ada <ada@example.com>\r\n"
            + "\r\n"
            + ")"
        let parsed = try IMAPMessageParser.parseForSync(header: header, bodyData: Data("Body".utf8))
        XCTAssertEqual(parsed.messageID, "<first@example.com>")
        XCTAssertEqual(parsed.from.rawValue, "ada@example.com")
    }
}
