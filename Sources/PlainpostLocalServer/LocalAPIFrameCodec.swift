import Foundation
import PlainpostLocalAPI

public enum LocalAPIFrameCodecError: Error, Equatable {
    case invalidHeader
    case invalidLength(Int)
}

public enum LocalAPIFrameCodec {
    public static let headerSize = 4

    public static func encode(_ payload: Data) throws -> Data {
        guard (1...LocalAPIProtocol.maximumFrameSize).contains(payload.count) else {
            throw LocalAPIFrameCodecError.invalidLength(payload.count)
        }
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        return frame
    }

    public static func decodeLength(_ header: Data) throws -> Int {
        guard header.count == headerSize else {
            throw LocalAPIFrameCodecError.invalidHeader
        }
        let value = header.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        let length = Int(value)
        guard (1...LocalAPIProtocol.maximumFrameSize).contains(length) else {
            throw LocalAPIFrameCodecError.invalidLength(length)
        }
        return length
    }
}
