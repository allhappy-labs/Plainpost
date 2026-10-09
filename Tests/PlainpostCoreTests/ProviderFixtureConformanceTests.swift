import Foundation
import XCTest
@testable import PlainpostCore
@testable import PlainpostTestSupport

// Core owns direct production MIME ingress assertions. IMAP/SMTP semantic
// transport behavior is owned by the Integration target, but every shared
// fixture is decoded through the same strict TestSupport module first.
final class ProviderFixtureConformanceTests: XCTestCase {
    func testSharedFixtureDocumentDecoderRejectsUnknownCaseKey() throws {
        let source = Data("""
        {"schemaVersion":1,"cases":[{"id":"fixture","provider":"generic","transport":"loopback_fixture","authentication":"password","script":[{"kind":"message"}],"expected":{"result":"normalized","normalized":{}},"unexpected":true}]}
        """.utf8)
        XCTAssertThrowsError(
            try ProviderFixtureDocumentDecoder.decode(source, named: "mime-corpus.json")
        )
    }

    func testSharedFixtureDocumentDecoderDecodesEveryFullUnion() throws {
        for name in Self.documents {
            let document = try ProviderFixtureDocumentDecoder.load(name)
            XCTAssertEqual(document.schemaVersion, 1, name)
            XCTAssertEqual(document.caseIDs.count, document.cases.count, name)
            switch document.kind {
            case .imap:
                XCTAssertEqual(
                    Set(try ProviderFixtureDocumentDecoder.imapOperations(document).map(\.id)),
                    document.caseIDs,
                    name
                )
            case .smtp:
                XCTAssertEqual(
                    Set(try ProviderFixtureDocumentDecoder.smtpOperations(document).map(\.id)),
                    document.caseIDs,
                    name
                )
            case .mime:
                let fixtures = try ProviderFixtureDocumentDecoder.mimeFixtures(document)
                XCTAssertEqual(Set(fixtures.map(\.id)), document.caseIDs, name)
            }
        }
    }

    func testMIMENormalizedExpectations() throws {
        let document = try ProviderFixtureDocumentDecoder.load("mime-corpus.json")
        let fixtures = try ProviderFixtureDocumentDecoder.mimeFixtures(document)
        let literals = fixtures.filter { $0.input != nil }
        XCTAssertEqual(literals.count, 13)
        for fixture in literals {
            let input = try XCTUnwrap(fixture.input, fixture.id)
            let expectation = try XCTUnwrap(fixture.expectation, fixture.id)
            XCTAssertEqual(
                try ProviderFixtureDocumentDecoder.mimeProjection(from: input),
                expectation.projection,
                fixture.id
            )
            if expectation.attachments.contains(where: { $0.bytesError == "protocol" }) {
                XCTAssertThrowsError(try MIMEMessageDecoder.decodedAttachments(from: input), fixture.id) { error in
                    XCTAssertEqual(error as? MIMEAttachmentDecodingError, .malformedMessage, fixture.id)
                }
            } else {
                XCTAssertEqual(
                    try MIMEMessageDecoder.decodedAttachments(from: input),
                    try ProviderFixtureDocumentDecoder.hydratedAttachmentPayloads(for: expectation),
                    fixture.id
                )
            }
        }
    }

    func testGeneratedLimitCasesExecuteProductionMIMEDecoder() throws {
        let document = try ProviderFixtureDocumentDecoder.load("mime-corpus.json")
        let fixtures = try ProviderFixtureDocumentDecoder.mimeFixtures(document)
        let generated = fixtures.filter { $0.generator != nil }
        XCTAssertEqual(generated.count, 7)
        for fixture in generated {
            for generator in fixture.generator?.boundaryCases ?? [] {
                let accepted = try ProviderFixtureMIMEFixtures.generated(generator, amount: generator.accepted)
                let acceptedProjection = try ProviderFixtureDocumentDecoder.mimeProjection(from: accepted)
                if generator.dimension == "body_bytes" {
                    XCTAssertEqual(acceptedProjection.textBody, .complete(String(repeating: "b", count: generator.accepted)), fixture.id)
                }
                if ["attachment_bytes", "aggregate_attachment_bytes", "attachment_count", "attachment_metadata_bytes"].contains(generator.dimension) {
                    _ = try MIMEMessageDecoder.decodedAttachments(from: accepted)
                }

                let rejected = try ProviderFixtureMIMEFixtures.generated(generator, amount: generator.rejected)
                if generator.dimension == "body_bytes" {
                    XCTAssertEqual(
                        try ProviderFixtureDocumentDecoder.mimeProjection(from: rejected).textBody,
                        .omittedOversized,
                        fixture.id
                    )
                } else if ["attachment_bytes", "aggregate_attachment_bytes", "attachment_count", "attachment_metadata_bytes"].contains(generator.dimension) {
                    XCTAssertThrowsError(try MIMEMessageDecoder.decodedAttachments(from: rejected), fixture.id)
                } else {
                    XCTAssertThrowsError(try ProviderFixtureDocumentDecoder.mimeProjection(from: rejected), fixture.id)
                }
            }
        }
    }

    func testFixtureDocumentsContainNoCredentialValues() throws {
        let forbidden = ["accesstoken", "refreshtoken", "\\\"password\\\"", "authorization", "imap.gmail.com", "smtp.gmail.com"]
        for name in Self.documents {
            let value = try String(contentsOf: Self.fixtureURL(name), encoding: .utf8).lowercased()
            for token in forbidden {
                XCTAssertFalse(value.contains(token.lowercased()), name)
            }
        }
    }

    private static let documents = ["imap-transcripts.json", "smtp-transcripts.json", "mime-corpus.json"]

    private static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Protocol/provider-fixtures/\(name)")
    }

}
