import Foundation
import PlainpostLocalAPI

public enum NativeMessagingFrameCodecError: Error, Equatable {
    case invalidHeader
    case invalidLength(Int)
    case truncatedFrame
}

public enum NativeMessagingFrameCodec {
    public static let headerSize = MemoryLayout<UInt32>.size

    public static func encode(_ payload: Data) throws -> Data {
        guard (1...LocalAPIProtocol.maximumFrameSize).contains(payload.count) else {
            throw NativeMessagingFrameCodecError.invalidLength(payload.count)
        }
        var length = UInt32(payload.count)
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        return frame
    }

    public static func decodeLength(_ header: Data) throws -> Int {
        guard header.count == headerSize else {
            throw NativeMessagingFrameCodecError.invalidHeader
        }
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { header.copyBytes(to: $0) }
        let length = Int(value)
        guard (1...LocalAPIProtocol.maximumFrameSize).contains(length) else {
            throw NativeMessagingFrameCodecError.invalidLength(length)
        }
        return length
    }

    public static func readFrame(
        read: (Int) throws -> Data
    ) throws -> Data? {
        guard let header = try readExactly(count: headerSize, allowCleanEOF: true, read: read) else {
            return nil
        }
        let length = try decodeLength(header)
        return try readExactly(count: length, allowCleanEOF: false, read: read)
    }

    private static func readExactly(
        count: Int,
        allowCleanEOF: Bool,
        read: (Int) throws -> Data
    ) throws -> Data? {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            let chunk = try read(count - data.count)
            guard !chunk.isEmpty else {
                if allowCleanEOF, data.isEmpty { return nil }
                throw NativeMessagingFrameCodecError.truncatedFrame
            }
            guard chunk.count <= count - data.count else {
                throw NativeMessagingFrameCodecError.invalidHeader
            }
            data.append(chunk)
        }
        return data
    }
}
