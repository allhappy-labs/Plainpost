@preconcurrency import CryptoKit
import Foundation

/// The only failure exposed by the notification-envelope boundary. Callers
/// must fall back to their fixed notification text instead of diagnosing
/// untrusted ciphertext or authority material.
public enum RichNotificationEnvelopeError: Error, Equatable, Sendable {
    case invalidEnvelope
}

/// Parser, verifier, and recipient-side opener for the closed `PPN2` wire
/// protocol. It owns no key persistence, APNs integration, or UI behavior.
public enum RichNotificationEnvelope {
    public struct Authority: Sendable {
        public let recipientDeviceID: AccountDeviceID
        public let producerDeviceID: AccountDeviceID
        fileprivate let producerSigningPublicKey: Data

        // Source-level labels remain local to the existing Sync Node adapter;
        // the wire and verification authority are producer-neutral.
        public var nodeID: AccountDeviceID { producerDeviceID }

        public init(recipientDeviceID: AccountDeviceID, producerDeviceID: AccountDeviceID, producerSigningPublicKey: Data) throws {
            guard AccountP256SEC1Validator.isValidUncompressedPoint(producerSigningPublicKey) else {
                throw RichNotificationEnvelopeError.invalidEnvelope
            }
            self.recipientDeviceID = recipientDeviceID
            self.producerDeviceID = producerDeviceID
            self.producerSigningPublicKey = producerSigningPublicKey
        }

        public init(recipientDeviceID: AccountDeviceID, nodeID: AccountDeviceID, nodeSigningPublicKey: Data) throws {
            try self.init(recipientDeviceID: recipientDeviceID, producerDeviceID: nodeID, producerSigningPublicKey: nodeSigningPublicKey)
        }
    }

    public struct Header: Hashable, Sendable {
        public let recipientRoutingHandle: Data
        public let recipientDeviceID: AccountDeviceID
        public let producerDeviceID: AccountDeviceID
        public let logicalMailboxID: Data
        public let producerAssignmentGeneration: UInt64
        public var nodeID: AccountDeviceID { producerDeviceID }
        public let trustEpoch: UInt64
        public let trustRevision: UInt64
        public let trustHead: Data
        public let policyVersion: UInt16
        public let messageDigest: Data
        public let replayID: Data
        public let issuedAtUnixSeconds: Int64
        public let expiresAtUnixSeconds: Int64
        public let collapseDigest: Data
    }

    public struct Content: Hashable, Sendable {
        public let mailboxToken: String
        public let threadToken: String
        public let messageToken: String
        public let sender: String
        public let subject: String
        public let preview: String
        public let badge: UInt16
    }

    public struct Opened: Hashable, Sendable {
        public let header: Header
        public let content: Content
    }

    /// Authenticates and decrypts one v1 envelope using only the authority
    /// currently supplied by the caller. `recipientAgreementPrivateKey` is a
    /// raw P-256 scalar and is never retained by this API.
    public static func open(
        _ wire: Data,
        recipientAgreementPrivateKey: Data,
        authority: Authority,
        now: Date = Date()
    ) throws -> Opened {
        do {
            let parsed = try parse(wire)
            guard parsed.header.recipientDeviceID == authority.recipientDeviceID,
                  parsed.header.producerDeviceID == authority.producerDeviceID,
                  validNow(now, issuedAt: parsed.header.issuedAtUnixSeconds, expiresAt: parsed.header.expiresAtUnixSeconds)
            else { throw RichNotificationEnvelopeError.invalidEnvelope }

            let nodeKey = try P256.Signing.PublicKey(x963Representation: authority.producerSigningPublicKey)
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: parsed.signature)
            // CryptoKit's P-256 signing API hashes its input with SHA-256,
            // so pass the exact Go transcript, not its already-computed hash.
            guard nodeKey.isValidSignature(signature, for: signatureTranscript(parsed.unsigned)) else {
                throw RichNotificationEnvelopeError.invalidEnvelope
            }

            let recipient = try P256.KeyAgreement.PrivateKey(rawRepresentation: recipientAgreementPrivateKey)
            let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: parsed.ephemeralPublicKey)
            let shared = try recipient.sharedSecretFromKeyAgreement(with: ephemeral)
            let key = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: parsed.salt,
                sharedInfo: kdfInfo(parsed.aad),
                outputByteCount: 32
            )
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: parsed.nonce),
                ciphertext: parsed.ciphertext.dropLast(gcmTagBytes),
                tag: parsed.ciphertext.suffix(gcmTagBytes)
            )
            let plaintext = try AES.GCM.open(box, using: key, authenticating: parsed.aad)
            let decoded = try parseContent(plaintext)
            guard decoded.replayID == parsed.header.replayID,
                  decoded.issuedAtUnixSeconds == parsed.header.issuedAtUnixSeconds,
                  decoded.expiresAtUnixSeconds == parsed.header.expiresAtUnixSeconds
            else { throw RichNotificationEnvelopeError.invalidEnvelope }
            return Opened(header: parsed.header, content: decoded.content)
        } catch {
            throw RichNotificationEnvelopeError.invalidEnvelope
        }
    }

    /// Returns only the opaque mailbox coordinate from a bounded wire. This
    /// is a selector hint for shared extension state; callers must still call
    /// `open`, which authenticates the complete header and ciphertext.
    public static func mailboxID(in wire: Data) throws -> Data {
        try parse(wire).header.logicalMailboxID
    }

    /// Creates a producer-side PPN2 envelope. The signing closure is supplied
    /// by AccountRuntime so this protocol module never owns producer private
    /// key material. All bytes returned here are final wire bytes suitable for
    /// freezing in the local notification outbox.
    public static func seal(
        recipientRoutingHandle: Data,
        recipientAgreementPublicKey: Data,
        recipientDeviceID: AccountDeviceID,
        producerDeviceID: AccountDeviceID,
        logicalMailboxID: Data,
        trustEpoch: UInt64,
        trustRevision: UInt64,
        producerAssignmentGeneration: UInt64,
        trustHead: Data,
        policyVersion: UInt16,
        messageDigest: Data,
        replayID: Data,
        collapseDigest: Data,
        mailboxToken: String,
        threadToken: String,
        messageToken: String,
        sender: String,
        subject: String,
        preview: String,
        badge: UInt16,
        now: Date = Date(),
        producerSigningPublicKey: Data,
        sign: @escaping @Sendable (Data) throws -> Data,
        random: @escaping @Sendable (Int) throws -> Data = { count in
            var generator = SystemRandomNumberGenerator()
            return Data((0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) })
        }
    ) throws -> Data {
        guard recipientRoutingHandle.count == routingHandleBytes, !isZero(recipientRoutingHandle),
              recipientAgreementPublicKey.count == p256PublicKeyBytes, AccountP256SEC1Validator.isValidUncompressedPoint(recipientAgreementPublicKey),
              logicalMailboxID.count == digestBytes, !isZero(logicalMailboxID),
              trustEpoch > 0, trustEpoch <= UInt64(Int64.max), trustRevision > 0, trustRevision <= UInt64(Int64.max),
              producerAssignmentGeneration > 0, trustHead.count == digestBytes, !isZero(trustHead),
              policyVersion > 0, messageDigest.count == digestBytes, !isZero(messageDigest),
              replayID.count == digestBytes, !isZero(replayID), collapseDigest.count == digestBytes, !isZero(collapseDigest),
              AccountP256SEC1Validator.isValidUncompressedPoint(producerSigningPublicKey),
              validText(mailboxToken, maximum: maxDeepLinkBytes, permitsEmpty: false),
              validText(threadToken, maximum: maxDeepLinkBytes, permitsEmpty: false),
              validText(messageToken, maximum: maxDeepLinkBytes, permitsEmpty: false),
              validText(sender, maximum: maxSenderBytes, permitsEmpty: false),
              validText(subject, maximum: maxSubjectBytes, permitsEmpty: false),
              validText(preview, maximum: maxPreviewBytes, permitsEmpty: true), badge <= maxBadge
        else { throw RichNotificationEnvelopeError.invalidEnvelope }
        let issuedAt = now.timeIntervalSince1970
        guard issuedAt.isFinite, issuedAt > 0, issuedAt < Double(Int64.max) else { throw RichNotificationEnvelopeError.invalidEnvelope }
        let issued = Int64(issuedAt.rounded(.down))
        guard issued > 0, issued <= Int64.max - envelopeLifetime else { throw RichNotificationEnvelopeError.invalidEnvelope }
        let expires = issued + envelopeLifetime
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let salt = try random(saltBytes)
        let nonceData = try random(nonceBytes)
        guard salt.count == saltBytes, nonceData.count == nonceBytes, !isZero(salt) else { throw RichNotificationEnvelopeError.invalidEnvelope }
        var aad = magic + Data([version])
        aad.append(recipientRoutingHandle)
        aad.append(uuidBytes(recipientDeviceID))
        aad.append(uuidBytes(producerDeviceID))
        aad.append(logicalMailboxID)
        appendUInt64(trustEpoch, to: &aad); appendUInt64(trustRevision, to: &aad); appendUInt64(producerAssignmentGeneration, to: &aad)
        aad.append(trustHead); appendUInt16(policyVersion, to: &aad); aad.append(messageDigest); aad.append(replayID)
        appendUInt64(UInt64(issued), to: &aad); appendUInt64(UInt64(expires), to: &aad); aad.append(collapseDigest)
        aad.append(ephemeral.publicKey.x963Representation); aad.append(salt); aad.append(nonceData)
        guard aad.count == fixedHeaderBytes else { throw RichNotificationEnvelopeError.invalidEnvelope }

        var plaintext = Data([plaintextVersion, contentFormatV2])
        for (value, maximum, permitsEmpty) in [(mailboxToken, maxDeepLinkBytes, false), (threadToken, maxDeepLinkBytes, false), (messageToken, maxDeepLinkBytes, false), (sender, maxSenderBytes, false), (subject, maxSubjectBytes, false), (preview, maxPreviewBytes, true)] {
            try appendText(value, maximum: maximum, permitsEmpty: permitsEmpty, to: &plaintext)
        }
        appendUInt16(badge, to: &plaintext); plaintext.append(replayID); appendUInt64(UInt64(issued), to: &plaintext); appendUInt64(UInt64(expires), to: &plaintext)
        guard plaintext.count <= maxPlaintextBytes else { throw RichNotificationEnvelopeError.invalidEnvelope }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: recipientAgreementPublicKey))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: kdfInfo(aad), outputByteCount: 32)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonceData), authenticating: aad)
        let ciphertext = sealed.ciphertext + sealed.tag
        guard ciphertext.count <= maxCiphertextBytes else { throw RichNotificationEnvelopeError.invalidEnvelope }
        var unsigned = aad; appendUInt16(UInt16(ciphertext.count), to: &unsigned); unsigned.append(ciphertext)
        let signature = try normalizedLowS(try sign(signatureTranscript(unsigned)))
        guard signature.count == signatureBytes else { throw RichNotificationEnvelopeError.invalidEnvelope }
        try AccountWireCodec.validateLowSSignature(signature)
        let wire = unsigned + signature
        guard wire.count <= maxEnvelopeBytes else { throw RichNotificationEnvelopeError.invalidEnvelope }
        return wire
    }

    private static let magic = Data("PPN2".utf8)
    // PPN2 uses version 2 for both the signed outer header and encrypted
    // plaintext. The content framing marker remains independently 0xA2.
    private static let version: UInt8 = 2
    private static let plaintextVersion: UInt8 = 2
    private static let contentFormatV2: UInt8 = 0xA2
    private static let envelopeLifetime: Int64 = 15 * 60
    private static let routingHandleBytes = 32
    private static let digestBytes = 32
    private static let p256PublicKeyBytes = 65
    private static let saltBytes = 32
    private static let nonceBytes = 12
    private static let gcmTagBytes = 16
    private static let signatureBytes = 64
    private static let fixedHeaderBytes = 380
    private static let maxDeepLinkBytes = 256
    private static let maxSenderBytes = 160
    private static let maxSubjectBytes = 200
    private static let maxPreviewBytes = 240
    private static let maxPlaintextBytes = 1024
    private static let maxCiphertextBytes = 2048
    private static let maxEnvelopeBytes = 4096
    private static let maxBadge: UInt16 = 999
    private static let signatureDomain = Data("Plainpost.ProducerNotification.v2.signature\0".utf8)
    private static let kdfDomain = Data("Plainpost.ProducerNotification.v2.content-key\0".utf8)

    private struct Parsed {
        let header: Header
        let ephemeralPublicKey: Data
        let salt: Data
        let nonce: Data
        let ciphertext: Data
        let signature: Data
        let aad: Data
        let unsigned: Data
    }

    private struct DecodedContent {
        let content: Content
        let replayID: Data
        let issuedAtUnixSeconds: Int64
        let expiresAtUnixSeconds: Int64
    }

    private static func parse(_ wire: Data) throws -> Parsed {
        guard wire.count >= fixedHeaderBytes + 2 + gcmTagBytes + signatureBytes,
              wire.count <= maxEnvelopeBytes
        else { throw RichNotificationEnvelopeError.invalidEnvelope }

        let signatureOffset = wire.count - signatureBytes
        let unsigned = Data(wire[..<signatureOffset])
        let signature = Data(wire[signatureOffset...])
        let aad = Data(unsigned[..<fixedHeaderBytes])
        guard aad.prefix(magic.count) == magic, aad[4] == version else {
            throw RichNotificationEnvelopeError.invalidEnvelope
        }

        var offset = 5
        let routingHandle = try readData(aad, offset: &offset, count: routingHandleBytes)
        let recipientDeviceID = try deviceID(try readData(aad, offset: &offset, count: 16))
        let producerDeviceID = try deviceID(try readData(aad, offset: &offset, count: 16))
        let logicalMailboxID = try readData(aad, offset: &offset, count: 32)
        let trustEpoch = try readUInt64(aad, offset: &offset)
        let trustRevision = try readUInt64(aad, offset: &offset)
        let producerAssignmentGeneration = try readUInt64(aad, offset: &offset)
        let trustHead = try readData(aad, offset: &offset, count: digestBytes)
        let policyVersion = try readUInt16(aad, offset: &offset)
        let messageDigest = try readData(aad, offset: &offset, count: digestBytes)
        let replayID = try readData(aad, offset: &offset, count: digestBytes)
        let issuedAtUnixSeconds = try signedUnixSeconds(try readUInt64(aad, offset: &offset))
        let expiresAtUnixSeconds = try signedUnixSeconds(try readUInt64(aad, offset: &offset))
        let collapseDigest = try readData(aad, offset: &offset, count: digestBytes)
        let ephemeralPublicKey = try readData(aad, offset: &offset, count: p256PublicKeyBytes)
        let salt = try readData(aad, offset: &offset, count: saltBytes)
        let nonce = try readData(aad, offset: &offset, count: nonceBytes)
        guard offset == fixedHeaderBytes,
              !isZero(routingHandle), trustEpoch > 0, trustEpoch <= UInt64(Int64.max),
              trustRevision > 0, trustRevision <= UInt64(Int64.max), policyVersion > 0,
              !isZero(logicalMailboxID), producerAssignmentGeneration > 0,
              !isZero(trustHead), !isZero(messageDigest), !isZero(replayID), !isZero(collapseDigest),
              issuedAtUnixSeconds > 0, expiresAtUnixSeconds > 0,
              expiresAtUnixSeconds - issuedAtUnixSeconds == envelopeLifetime,
              AccountP256SEC1Validator.isValidUncompressedPoint(ephemeralPublicKey)
        else { throw RichNotificationEnvelopeError.invalidEnvelope }

        var lengthOffset = fixedHeaderBytes
        let ciphertextLength = Int(try readUInt16(unsigned, offset: &lengthOffset))
        guard ciphertextLength >= gcmTagBytes, ciphertextLength <= maxCiphertextBytes,
              unsigned.count == fixedHeaderBytes + 2 + ciphertextLength
        else { throw RichNotificationEnvelopeError.invalidEnvelope }
        let ciphertext = Data(unsigned[lengthOffset...])
        try AccountWireCodec.validateLowSSignature(signature)
        return Parsed(
            header: Header(
                recipientRoutingHandle: routingHandle,
                recipientDeviceID: recipientDeviceID,
                producerDeviceID: producerDeviceID,
                logicalMailboxID: logicalMailboxID,
                producerAssignmentGeneration: producerAssignmentGeneration,
                trustEpoch: trustEpoch,
                trustRevision: trustRevision,
                trustHead: trustHead,
                policyVersion: policyVersion,
                messageDigest: messageDigest,
                replayID: replayID,
                issuedAtUnixSeconds: issuedAtUnixSeconds,
                expiresAtUnixSeconds: expiresAtUnixSeconds,
                collapseDigest: collapseDigest
            ),
            ephemeralPublicKey: ephemeralPublicKey,
            salt: salt,
            nonce: nonce,
            ciphertext: ciphertext,
            signature: signature,
            aad: aad,
            unsigned: unsigned
        )
    }

    private static func parseContent(_ plaintext: Data) throws -> DecodedContent {
        guard plaintext.count >= 1 + 4 * 2 + 2 + digestBytes + 8 + 8,
              plaintext.count <= maxPlaintextBytes,
              plaintext.first == plaintextVersion
        else { throw RichNotificationEnvelopeError.invalidEnvelope }
        var offset = 1
        guard plaintext[plaintext.index(plaintext.startIndex, offsetBy: offset)] == contentFormatV2 else { throw RichNotificationEnvelopeError.invalidEnvelope }
        offset += 1
        let limits = [maxDeepLinkBytes, maxDeepLinkBytes, maxDeepLinkBytes, maxSenderBytes, maxSubjectBytes, maxPreviewBytes]
        let fields = try limits.enumerated().map { index, maximum in
            let bytes = try lengthPrefixedUTF8(plaintext, offset: &offset, maximum: maximum, permitsEmpty: index == 5)
            return bytes
        }
        guard offset + 2 + digestBytes + 8 + 8 == plaintext.count else {
            throw RichNotificationEnvelopeError.invalidEnvelope
        }
        let badge = try readUInt16(plaintext, offset: &offset)
        let replayID = try readData(plaintext, offset: &offset, count: digestBytes)
        let issuedAtUnixSeconds = try signedUnixSeconds(try readUInt64(plaintext, offset: &offset))
        let expiresAtUnixSeconds = try signedUnixSeconds(try readUInt64(plaintext, offset: &offset))
        guard offset == plaintext.count, badge <= maxBadge,
              issuedAtUnixSeconds > 0, expiresAtUnixSeconds > 0,
              expiresAtUnixSeconds - issuedAtUnixSeconds == envelopeLifetime
        else { throw RichNotificationEnvelopeError.invalidEnvelope }
        let content: Content
        guard !fields[0].isEmpty, !fields[1].isEmpty, !fields[2].isEmpty else { throw RichNotificationEnvelopeError.invalidEnvelope }
        content = Content(mailboxToken: fields[0], threadToken: fields[1], messageToken: fields[2], sender: fields[3], subject: fields[4], preview: fields[5], badge: badge)
        return DecodedContent(
            content: content,
            replayID: replayID,
            issuedAtUnixSeconds: issuedAtUnixSeconds,
            expiresAtUnixSeconds: expiresAtUnixSeconds
        )
    }

    private static func lengthPrefixedUTF8(_ data: Data, offset: inout Int, maximum: Int, permitsEmpty: Bool) throws -> String {
        let length = Int(try readUInt16(data, offset: &offset))
        guard (permitsEmpty || length > 0) else { throw RichNotificationEnvelopeError.invalidEnvelope }
        let bytes = try readData(data, offset: &offset, count: length)
        guard let string = String(data: bytes, encoding: .utf8), string.utf8.count <= maximum, !containsUnsafeControl(string) else {
            throw RichNotificationEnvelopeError.invalidEnvelope
        }
        return string
    }

    private static func containsUnsafeControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) && scalar.value != 0x200C && scalar.value != 0x200D
        }
    }

    private static func signatureTranscript(_ unsigned: Data) -> Data {
        signatureDomain + unsigned
    }

    private static func kdfInfo(_ aad: Data) -> Data {
        Data(SHA256.hash(data: kdfDomain + aad))
    }

    private static func validText(_ value: String, maximum: Int, permitsEmpty: Bool) -> Bool {
        guard (permitsEmpty || !value.isEmpty), value.utf8.count <= maximum else { return false }
        return !containsUnsafeControl(value)
    }

    private static func appendText(_ value: String, maximum: Int, permitsEmpty: Bool, to data: inout Data) throws {
        guard validText(value, maximum: maximum, permitsEmpty: permitsEmpty), value.utf8.count <= Int(UInt16.max) else { throw RichNotificationEnvelopeError.invalidEnvelope }
        appendUInt16(UInt16(value.utf8.count), to: &data); data.append(contentsOf: value.utf8)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var value = value.bigEndian; data.append(Data(bytes: &value, count: 2))
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        var value = value.bigEndian; data.append(Data(bytes: &value, count: 8))
    }

    private static func uuidBytes(_ value: AccountDeviceID) -> Data {
        guard let uuid = UUID(uuidString: value.rawValue) else { return Data() }
        var tuple = uuid.uuid
        return withUnsafeBytes(of: &tuple) { Data($0) }
    }

    private static func normalizedLowS(_ signature: Data) throws -> Data {
        guard signature.count == signatureBytes else { throw RichNotificationEnvelopeError.invalidEnvelope }
        let r = Data(signature.prefix(32)); let s = Data(signature.suffix(32))
        let order = Data(hex: "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551")
        let half = Data(hex: "7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8")
        guard !r.allSatisfy({ $0 == 0 }), !s.allSatisfy({ $0 == 0 }), r.lexicographicallyPrecedes(order), s.lexicographicallyPrecedes(order) else { throw RichNotificationEnvelopeError.invalidEnvelope }
        guard half.lexicographicallyPrecedes(s), s != half else { return signature }
        var result = Array(order); let source = Array(s); var borrow = 0
        for index in stride(from: 31, through: 0, by: -1) {
            let difference = Int(result[index]) - Int(source[index]) - borrow
            if difference < 0 { result[index] = UInt8(difference + 256); borrow = 1 } else { result[index] = UInt8(difference); borrow = 0 }
        }
        return r + Data(result)
    }

    private static func validNow(_ now: Date, issuedAt: Int64, expiresAt: Int64) -> Bool {
        let interval = now.timeIntervalSince1970
        // `Double(Int64.max)` rounds up to 2^63, which cannot be converted
        // back to Int64. Keep this strict upper bound before conversion so an
        // untrusted caller-supplied Date can only fail closed, never trap.
        guard interval.isFinite, interval >= 0, interval < Double(Int64.max) else { return false }
        let currentSecond = Int64(interval.rounded(.down))
        return currentSecond >= issuedAt && currentSecond < expiresAt
    }

    private static func signedUnixSeconds(_ value: UInt64) throws -> Int64 {
        guard value <= UInt64(Int64.max) else { throw RichNotificationEnvelopeError.invalidEnvelope }
        return Int64(value)
    }

    private static func readUInt16(_ data: Data, offset: inout Int) throws -> UInt16 {
        let bytes = try readData(data, offset: &offset, count: 2)
        return UInt16(bytes[bytes.startIndex]) << 8 | UInt16(bytes[bytes.index(after: bytes.startIndex)])
    }

    private static func readUInt64(_ data: Data, offset: inout Int) throws -> UInt64 {
        let bytes = try readData(data, offset: &offset, count: 8)
        return bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    private static func readData(_ data: Data, offset: inout Int, count: Int) throws -> Data {
        guard count >= 0, offset >= 0, count <= data.count - offset else {
            throw RichNotificationEnvelopeError.invalidEnvelope
        }
        defer { offset += count }
        return Data(data[offset..<(offset + count)])
    }

    private static func deviceID(_ data: Data) throws -> AccountDeviceID {
        guard data.count == 16, !isZero(data) else { throw RichNotificationEnvelopeError.invalidEnvelope }
        let bytes = Array(data)
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return try AccountDeviceID(uuid.uuidString.lowercased())
    }

    private static func isZero(_ data: Data) -> Bool {
        data.allSatisfy { $0 == 0 }
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []; bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
