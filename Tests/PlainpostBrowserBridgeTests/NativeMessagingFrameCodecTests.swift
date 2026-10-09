import Foundation
import XCTest
@testable import PlainpostBrowserIntegration
import PlainpostLocalAPI

final class NativeMessagingFrameCodecTests: XCTestCase {
    func testNativeFrameUsesHostEndianLength() throws {
        let encoded = try NativeMessagingFrameCodec.encode(Data("{}".utf8))

        XCTAssertEqual(Array(encoded.prefix(4)), [2, 0, 0, 0])
        XCTAssertEqual(Data(encoded.dropFirst(4)), Data("{}".utf8))
    }

    func testReadFrameAssemblesPartialHeaderAndPayloadReads() throws {
        var chunks = [
            Data([2]),
            Data([0, 0]),
            Data([0]),
            Data([UInt8(ascii: "{")]),
            Data([UInt8(ascii: "}")]),
        ]

        let payload = try NativeMessagingFrameCodec.readFrame { _ in
            chunks.removeFirst()
        }

        XCTAssertEqual(payload, Data("{}".utf8))
        XCTAssertTrue(chunks.isEmpty)
    }

    func testReadFrameReturnsNilForCleanEndOfInput() throws {
        let payload = try NativeMessagingFrameCodec.readFrame { _ in Data() }

        XCTAssertNil(payload)
    }

    func testReadFrameRejectsZeroLengthBeforeReadingPayload() throws {
        var readCounts: [Int] = []

        XCTAssertThrowsError(
            try NativeMessagingFrameCodec.readFrame { count in
                readCounts.append(count)
                return Data(repeating: 0, count: count)
            }
        ) { error in
            XCTAssertEqual(error as? NativeMessagingFrameCodecError, .invalidLength(0))
        }
        XCTAssertEqual(readCounts, [4])
    }

    func testReadFrameRejectsOversizeLengthBeforeReadingPayload() throws {
        var length = UInt32(LocalAPIProtocol.maximumFrameSize + 1)
        let header = withUnsafeBytes(of: &length) { Data($0) }
        var readCounts: [Int] = []

        XCTAssertThrowsError(
            try NativeMessagingFrameCodec.readFrame { count in
                readCounts.append(count)
                return header
            }
        ) { error in
            XCTAssertEqual(
                error as? NativeMessagingFrameCodecError,
                .invalidLength(LocalAPIProtocol.maximumFrameSize + 1)
            )
        }
        XCTAssertEqual(readCounts, [4])
    }

    func testEncodeRejectsEmptyAndOversizePayloads() {
        XCTAssertThrowsError(try NativeMessagingFrameCodec.encode(Data()))
        XCTAssertThrowsError(
            try NativeMessagingFrameCodec.encode(
                Data(repeating: 0, count: LocalAPIProtocol.maximumFrameSize + 1)
            )
        )
    }
}
