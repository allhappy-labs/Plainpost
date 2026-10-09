import Foundation
import XCTest
@testable import PlainpostUI

final class PlainpostAttachmentArtifactWriterTests: XCTestCase {
    private enum TestError: Error, Equatable {
        case write
        case permissions
        case createDirectory
    }

    func testWriteFailureRemovesOwnedDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var writtenURL: URL?

        XCTAssertThrowsError(
            try writeNodeAttachmentArtifact(
                bytes: Data("bytes".utf8),
                filename: "file.txt",
                temporaryRoot: fixture.root,
                write: { _, url in
                    writtenURL = url
                    throw TestError.write
                },
                setFilePermissions: { _ in }
            )
        ) { error in
            XCTAssertEqual(error as? TestError, .write)
        }

        XCTAssertNotNil(writtenURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writtenURL!.deletingLastPathComponent().path))
        XCTAssertEqual(try String(contentsOf: fixture.sentinel, encoding: .utf8), "sentinel")
    }

    func testPermissionFailureRemovesOwnedDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var writtenURL: URL?

        XCTAssertThrowsError(
            try writeNodeAttachmentArtifact(
                bytes: Data("bytes".utf8),
                filename: "file.txt",
                temporaryRoot: fixture.root,
                write: { bytes, url in
                    writtenURL = url
                    try bytes.write(to: url)
                },
                setFilePermissions: { _ in throw TestError.permissions }
            )
        ) { error in
            XCTAssertEqual(error as? TestError, .permissions)
        }

        XCTAssertNotNil(writtenURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writtenURL!.deletingLastPathComponent().path))
        XCTAssertEqual(try String(contentsOf: fixture.sentinel, encoding: .utf8), "sentinel")
    }

    func testSuccessTransfersCleanupToArtifact() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bytes = Data("bytes".utf8)

        let artifact = try writeNodeAttachmentArtifact(
            bytes: bytes,
            filename: "file.txt",
            temporaryRoot: fixture.root,
            write: { bytes, url in try bytes.write(to: url) },
            setFilePermissions: { url in
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        )

        XCTAssertEqual(try Data(contentsOf: artifact.url), bytes)
        XCTAssertEqual(try permissions(at: artifact.url.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try permissions(at: artifact.url), 0o600)
        let directory = artifact.url.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        try artifact.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sentinel.path))
    }

    func testCreateDirectoryFailurePreservesRootAndSentinel() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        XCTAssertThrowsError(
            try writeNodeAttachmentArtifact(
                bytes: Data("bytes".utf8),
                filename: "file.txt",
                temporaryRoot: fixture.sentinel,
                write: { _, _ in XCTFail("write must not run") },
                setFilePermissions: { _ in XCTFail("permissions must not run") }
            )
        ) { error in
            XCTAssertNotNil(error)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.path))
        XCTAssertEqual(try String(contentsOf: fixture.sentinel, encoding: .utf8), "sentinel")
    }

    private struct Fixture {
        let root: URL
        let sentinel: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("plainpost-writer-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            sentinel = root.appendingPathComponent("sentinel.txt")
            try Data("sentinel".utf8).write(to: sentinel)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

}
