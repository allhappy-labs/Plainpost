import Darwin
import Foundation
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime

final class AccountOperationFenceTests: XCTestCase {
    func testTwoProviderInstancesSerializeTheCompleteAccountOperation() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let first = try FileAccountOperationFence(lockRoot: root)
        let second = try FileAccountOperationFence(lockRoot: root)
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()

        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            try? first.withLock(accountID: accountID) {
                firstEntered.signal()
                releaseFirst.wait()
            }
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 2), .success)

        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            _ = try? second.withLock(accountID: accountID) { secondEntered.signal() }
        }
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 0.1), .timedOut)
        releaseFirst.signal()
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
    }

    func testFenceIsReentrantAndDoesNotRetainOneProcessLockPerAccountForever() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fence = try FileAccountOperationFence(lockRoot: root)
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        var nested = false
        try fence.withLock(accountID: accountID) {
            try fence.withLock(accountID: accountID) { nested = true }
        }
        XCTAssertTrue(nested)

        for index in 0..<128 {
            let id = try PlainpostAccountID(String(format: "00000000-0000-4000-8000-%012x", index))
            try fence.withLock(accountID: id) {}
        }
        FileAccountOperationFence.pruneProcessLocksForTesting()
        XCTAssertEqual(FileAccountOperationFence.processLockCountForTesting, 0)
    }

    func testChildProcessCannotEnterUntilSwiftFenceReleasesKernelLock() throws {
        let python = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("python3 is unavailable for the child-process fcntl interoperability check")
        }
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fence = try FileAccountOperationFence(lockRoot: root)
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let lock = root.appendingPathComponent(accountID.rawValue + ".lock")
        let ready = root.appendingPathComponent("child-ready")
        let marker = root.appendingPathComponent("child-entered")
        let child = Process()
        child.executableURL = python
        child.arguments = [
            "-c",
            "import fcntl, os, sys; fd=os.open(sys.argv[1], os.O_RDWR); open(sys.argv[2], 'wb').close(); fcntl.lockf(fd, fcntl.LOCK_EX); open(sys.argv[3], 'wb').close(); os.close(fd)",
            lock.path,
            ready.path,
            marker.path,
        ]

        try fence.withLock(accountID: accountID) {
            try child.run()
            let deadline = Date().addingTimeInterval(2)
            while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
                usleep(10_000)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testExistingLockMustBeRegularOwned0600AndSingleLink() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fence = try FileAccountOperationFence(lockRoot: root)
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let lock = root.appendingPathComponent(accountID.rawValue + ".lock")
        XCTAssertTrue(FileManager.default.createFile(atPath: lock.path, contents: Data()))
        XCTAssertEqual(chmod(lock.path, 0o644), 0)
        XCTAssertThrowsError(try fence.withLock(accountID: accountID) {})
        XCTAssertEqual(chmod(lock.path, 0o600), 0)

        let secondLink = root.appendingPathComponent("second-link")
        XCTAssertEqual(link(lock.path, secondLink.path), 0)
        XCTAssertThrowsError(try fence.withLock(accountID: accountID) {})
    }

    func testSymlinkLockAndUnsafeDirectoryFailClosed() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let fence = try FileAccountOperationFence(lockRoot: root)
        let target = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: target) }
        let lock = root.appendingPathComponent(accountID.rawValue + ".lock")
        XCTAssertEqual(symlink(target.path, lock.path), 0)
        XCTAssertThrowsError(try fence.withLock(accountID: accountID) {})

        try FileManager.default.removeItem(at: lock)
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        XCTAssertThrowsError(try FileAccountOperationFence(lockRoot: root))
    }

    private func temporaryRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("plainpost-account-fence-\(UUID().uuidString)", isDirectory: true)
    }
}
