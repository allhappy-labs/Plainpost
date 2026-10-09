import CryptoKit
import Foundation

/// The digest identity used by the local SMTP/IMAP acceptance seam.  Source
/// bytes are normalized without parsing MIME so the Swift authority and the
/// Python fixture can independently prove the same wire identity.
public enum CanonicalMailSource {
    public static func normalize(_ source: Data) -> Data {
        var result = Data(capacity: source.count + 2)
        var index = source.startIndex
        while index < source.endIndex {
            let byte = source[index]
            if byte == 0x0D {
                result.append(0x0D)
                result.append(0x0A)
                index = source.index(after: index)
                if index < source.endIndex, source[index] == 0x0A {
                    index = source.index(after: index)
                }
            } else if byte == 0x0A {
                result.append(0x0D)
                result.append(0x0A)
                index = source.index(after: index)
            } else {
                result.append(byte)
                index = source.index(after: index)
            }
        }
        let hasTerminalCRLF = result.count >= 2 && result[result.count - 2] == 0x0D && result[result.count - 1] == 0x0A
        if !result.isEmpty, !hasTerminalCRLF {
            result.append(contentsOf: [0x0D, 0x0A])
        } else if result.isEmpty {
            result.append(contentsOf: [0x0D, 0x0A])
        }
        return result
    }

    public static func digestHex(_ source: Data) -> String {
        SHA256.hash(data: normalize(source)).map { String(format: "%02x", $0) }.joined()
    }
}
