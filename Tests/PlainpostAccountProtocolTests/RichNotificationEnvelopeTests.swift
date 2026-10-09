import CryptoKit
import Foundation
import XCTest
@testable import PlainpostAccountProtocol

final class RichNotificationEnvelopeTests: XCTestCase {
    func testOpensPinnedRichFixture() throws {
        let fixture = try notificationFixture()
        let authority = try RichNotificationEnvelope.Authority(
            recipientDeviceID: try AccountDeviceID("20000000-0000-4000-8000-000000000002"),
            nodeID: try AccountDeviceID("30000000-0000-4000-8000-000000000003"),
            nodeSigningPublicKey: try P256.Signing.PrivateKey(rawRepresentation: scalar(3)).publicKey.x963Representation
        )

        let opened = try RichNotificationEnvelope.open(
            fixture.richWire,
            recipientAgreementPrivateKey: scalar(2),
            authority: authority,
            now: openedAt
        )

        XCTAssertEqual(opened.content.messageToken, "message")
        XCTAssertEqual(opened.content.sender, "sender")
        XCTAssertEqual(opened.content.subject, "subject")
        XCTAssertEqual(opened.content.preview, "preview")
        XCTAssertEqual(opened.content.badge, 1)
        XCTAssertEqual(opened.header.producerDeviceID, try AccountDeviceID("30000000-0000-4000-8000-000000000003"))
        XCTAssertEqual(opened.header.logicalMailboxID, Data(repeating: 4, count: 32))
        XCTAssertEqual(opened.header.producerAssignmentGeneration, 1)
    }

    func testRejectsLegacyPPN2WireWithoutCompatibilityPath() throws {
        var legacy = try notificationFixture().richWire
        legacy.replaceSubrange(0..<4, with: Data("PPN1".utf8))
        XCTAssertThrowsError(try open(legacy))
    }

    func testOpensPinnedSenderAndSubjectFixtureWithoutPreview() throws {
        let fixture = try notificationFixture()
        let opened = try open(fixture.noPreviewWire)

        XCTAssertEqual(opened.content.messageToken, "message")
        XCTAssertEqual(opened.content.sender, "sender")
        XCTAssertEqual(opened.content.subject, "subject")
        XCTAssertEqual(opened.content.preview, "")
        XCTAssertEqual(opened.content.badge, 1)
    }

    func testContentBoundsUseUTF8BytesAcrossGoAndSwift() throws {
        let sender = String(repeating: "é", count: 80)
        let plaintext = try notificationContent(fields: [
            Data("mailbox".utf8), Data("thread".utf8), Data("message".utf8), Data(sender.utf8), Data("subject".utf8), Data("preview".utf8)
        ])
        let wire = try cryptoValidEnvelope(plaintext)

        XCTAssertNoThrow(try outerPlaintext(wire))
        let opened = try open(wire)
        XCTAssertEqual(opened.content.sender, sender)
        XCTAssertEqual(opened.content.sender.utf8.count, 160)

        let overLimit = try notificationContent(fields: [
            Data("mailbox".utf8), Data("thread".utf8), Data("message".utf8), Data(String(repeating: "é", count: 81).utf8), Data("subject".utf8), Data("preview".utf8)
        ])
        XCTAssertThrowsError(try open(try cryptoValidEnvelope(overLimit)))
    }

    func testOpaqueIdentityCoordinatesAreIndependentAndStable() {
        let identities = NotificationOpaqueIdentities.derive(
            mailboxBytes: Data(repeating: 4, count: 32), messageID: "message-1", threadID: "thread-1"
        )
        let repeated = NotificationOpaqueIdentities.derive(
            mailboxBytes: Data(repeating: 4, count: 32), messageID: "message-1", threadID: "thread-1"
        )
        XCTAssertEqual(identities, repeated)
        XCTAssertFalse(identities.mailboxToken.isEmpty)
        XCTAssertFalse(identities.threadToken.isEmpty)
        XCTAssertFalse(identities.messageToken.isEmpty)
        XCTAssertNotEqual(identities.mailboxToken, identities.threadToken)
        XCTAssertNotEqual(identities.threadToken, identities.messageToken)
        XCTAssertNotEqual(identities.messageToken, "message-1")
    }

    func testAccountInboxIdentityIsStableOpaqueAndDomainSeparated() {
        let token = NotificationOpaqueIdentities.accountInboxToken(for: "account-1")

        XCTAssertFalse(token.isEmpty)
        XCTAssertNotEqual(token, "account-1")
        XCTAssertEqual(
            token,
            NotificationOpaqueIdentities.accountInboxToken(for: "account-1")
        )
        XCTAssertNotEqual(
            token,
            NotificationOpaqueIdentities.messageToken(for: "account-1")
        )
    }

    func testMessageIdentityCannotCrossAccountOrSourceEpoch() {
        let direct = NotificationOpaqueIdentities.messageToken(
            for: "same-message", accountID: "account-a", sourceKind: "direct", sourceGeneration: 0
        )
        XCTAssertEqual(direct, NotificationOpaqueIdentities.messageToken(
            for: "same-message", accountID: "account-a", sourceKind: "direct", sourceGeneration: 0
        ))
        XCTAssertNotEqual(direct, NotificationOpaqueIdentities.messageToken(
            for: "same-message", accountID: "account-b", sourceKind: "direct", sourceGeneration: 0
        ))
        XCTAssertNotEqual(direct, NotificationOpaqueIdentities.messageToken(
            for: "same-message", accountID: "account-a", sourceKind: "node_backed", sourceGeneration: 0
        ))
        XCTAssertNotEqual(direct, NotificationOpaqueIdentities.messageToken(
            for: "same-message", accountID: "account-a", sourceKind: "direct", sourceGeneration: 1
        ))
        XCTAssertNotEqual(direct, NotificationOpaqueIdentities.messageToken(for: "same-message"))
    }

    func testOpensEnvelopeWithIndependentIdentityCoordinates() throws {
        let identities = NotificationOpaqueIdentities.derive(
            mailboxBytes: Data(repeating: 4, count: 32), messageID: "message-1", threadID: "thread-1"
        )
        let plaintext = try notificationContent(fields: [
            Data(identities.mailboxToken.utf8), Data(identities.threadToken.utf8),
            Data(identities.messageToken.utf8), Data("sender".utf8),
            Data("subject".utf8), Data("preview".utf8)
        ])
        let opened = try open(try cryptoValidEnvelope(plaintext))
        XCTAssertEqual(opened.content.mailboxToken, identities.mailboxToken)
        XCTAssertEqual(opened.content.threadToken, identities.threadToken)
        XCTAssertEqual(opened.content.messageToken, identities.messageToken)
        XCTAssertNotEqual(opened.content.messageToken, "message-1")
    }

    func testPinnedFixtureCryptographyUsesTheGoDomainsAndAAD() throws {
        let fixture = try notificationFixture()
        let wire = fixture.richWire
        let signatureOffset = wire.count - 64
        let unsigned = Data(wire[..<signatureOffset])
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: Data(wire[signatureOffset...]))
        let nodeKey = try P256.Signing.PrivateKey(rawRepresentation: scalar(3)).publicKey
        let signatureDomain = Data("Plainpost.ProducerNotification.v2.signature\0".utf8)
        XCTAssertTrue(nodeKey.isValidSignature(signature, for: signatureDomain + unsigned))

        let aad = Data(unsigned[..<380])
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: Data(aad[271..<336]))
        let recipient = try P256.KeyAgreement.PrivateKey(rawRepresentation: scalar(2))
        let shared = try recipient.sharedSecretFromKeyAgreement(with: ephemeral)
        let kdfDomain = Data("Plainpost.ProducerNotification.v2.content-key\0".utf8)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(aad[336..<368]),
            sharedInfo: Data(SHA256.hash(data: kdfDomain + aad)),
            outputByteCount: 32
        )
        let ciphertext = Data(unsigned[382...])
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(aad[368..<380])),
            ciphertext: Data(ciphertext.dropLast(16)),
            tag: Data(ciphertext.suffix(16))
        )
        let plaintext = try AES.GCM.open(box, using: key, authenticating: aad)
        XCTAssertFalse(plaintext.isEmpty)
        XCTAssertEqual(plaintext.first, 2, "PPN2 plaintext uses the authoritative version 2")
    }

    func testRejectsEverySignedAndAADCoordinateAndFramingMutation() throws {
        let fixture = try notificationFixture()
        let wire = fixture.richWire
        let signatureOffset = wire.count - 64
        let ciphertextOffset = 382
        let now = openedAt
        let aadCoordinates: [(String, Int)] = [
            ("magic", 0), ("version", 4), ("route", 5), ("recipient", 37), ("node", 53),
            ("mailbox", 69), ("generation", 117), ("epoch", 101), ("revision", 109), ("trust-head", 125), ("policy", 157),
            ("message", 159), ("replay", 191), ("issued", 223), ("expires", 231),
            ("collapse", 239), ("ephemeral", 271), ("salt", 336), ("nonce", 368),
            ("ciphertext-length", 380), ("ciphertext", ciphertextOffset), ("tag", signatureOffset - 1),
            ("signature", signatureOffset),
        ]

        for (name, offset) in aadCoordinates {
            var mutated = wire
            mutated[offset] ^= 0x01
            XCTAssertThrowsError(try open(mutated, now: now), name)
        }

        var malformedPoint = wire
        // The ephemeral SEC1 point starts at byte 271 (231 is the first byte
        // of expiresAt and is already zero in this fixture). Re-sign the
        // altered unsigned transcript so this assertion reaches point
        // validation instead of merely failing the signature check.
        malformedPoint[271] = 0
        let malformedUnsigned = Data(malformedPoint[..<signatureOffset])
        let malformedSignature = try normalizedLowS(
            P256.Signing.PrivateKey(rawRepresentation: scalar(3))
                .signature(for: Data("Plainpost.ProducerNotification.v2.signature\0".utf8) + malformedUnsigned)
                .rawRepresentation
        )
        malformedPoint.replaceSubrange(signatureOffset..<wire.count, with: malformedSignature)
        XCTAssertThrowsError(try open(malformedPoint, now: now))

        var shortCiphertext = wire
        shortCiphertext[380] = 0
        shortCiphertext[381] = 15
        XCTAssertThrowsError(try open(shortCiphertext, now: now))

        var oversizedCiphertext = wire
        oversizedCiphertext[380] = 0x08
        oversizedCiphertext[381] = 0x01
        XCTAssertThrowsError(try open(oversizedCiphertext, now: now))

        XCTAssertThrowsError(try open(Data(wire.dropLast()), now: now))
        XCTAssertThrowsError(try open(wire + Data([0]), now: now))
    }

    func testRejectsWrongKeysNoncanonicalSignatureAndExpiredEnvelope() throws {
        let fixture = try notificationFixture()
        let authority = try authority()
        let now = openedAt

        XCTAssertThrowsError(try RichNotificationEnvelope.open(
            fixture.richWire,
            recipientAgreementPrivateKey: scalar(8),
            authority: authority,
            now: now
        ))
        let wrongNodeAuthority = try RichNotificationEnvelope.Authority(
            recipientDeviceID: try AccountDeviceID("20000000-0000-4000-8000-000000000002"),
            nodeID: try AccountDeviceID("30000000-0000-4000-8000-000000000003"),
            nodeSigningPublicKey: try P256.Signing.PrivateKey(rawRepresentation: scalar(9)).publicKey.x963Representation
        )
        XCTAssertThrowsError(try RichNotificationEnvelope.open(
            fixture.richWire,
            recipientAgreementPrivateKey: scalar(2),
            authority: wrongNodeAuthority,
            now: now
        ))

        var highS = fixture.richWire
        let signatureOffset = highS.count - 64
        let order = try Data(hex: "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551")
        highS.replaceSubrange((signatureOffset + 32)..<highS.count, with: subtract(order, Data(highS[(signatureOffset + 32)..<highS.count])))
        XCTAssertThrowsError(try open(highS, now: now))

        var zeroR = fixture.richWire
        zeroR.replaceSubrange(signatureOffset..<(signatureOffset + 32), with: Data(repeating: 0, count: 32))
        XCTAssertThrowsError(try open(zeroR, now: now))
        XCTAssertThrowsError(try open(fixture.richWire, now: expiresAt))
    }

    func testWireAndErrorsDoNotExposePrivateContentOrKeyMaterial() throws {
        let fixture = try notificationFixture()
        for canary in ["SENDER-CANARY", "SUBJECT-CANARY", "PREVIEW-CANARY", "RECIPIENT-KEY-CANARY"] {
            XCTAssertFalse(fixture.richWire.range(of: Data(canary.utf8)) != nil)
        }
        var malformed = fixture.richWire
        malformed[0] ^= 0x01
        XCTAssertThrowsError(try open(malformed)) { error in
            let text = String(describing: error).lowercased()
            for prohibited in ["cipher", "sender", "subject", "preview", "route", "key", "identifier"] {
                XCTAssertFalse(text.contains(prohibited))
            }
        }
    }

    func testRejectsCryptoValidMalformedPlaintextAndBindingOwners() throws {
        let base = try notificationContent()
        let normalFields = [Data("mailbox".utf8), Data("thread".utf8), Data("message".utf8), Data("sender".utf8), Data("subject".utf8), Data("preview".utf8)]
        let aad = Data((try notificationFixture()).richWire[..<380])
        let issued = try readUInt64(aad, offset: 223)
        let expires = try readUInt64(aad, offset: 231)
        let malformed: [(String, Data)] = [
            ("replay mismatch", try notificationContent(replay: Data(repeating: 0x5a, count: 32))),
            ("issued mismatch", try notificationContent(issuedAt: issued + 1, expiresAtUnixSeconds: expires + 1)),
            ("expiry mismatch", try notificationContent(issuedAt: issued - 1, expiresAtUnixSeconds: expires - 1)),
            ("content version", try notificationContent(version: 1)),
            ("content framing", Data([1, 0])),
            ("content length", Data([1, 0, 5]) + Data("x".utf8)),
            ("content truncation", Data(base.dropLast())),
            ("content trailing", base + Data([0])),
            ("empty mailbox", try notificationContent(fields: [Data(), normalFields[1], normalFields[2], normalFields[3], normalFields[4], normalFields[5]])),
            ("empty sender", try notificationContent(fields: [normalFields[0], normalFields[1], normalFields[2], Data(), normalFields[4], normalFields[5]])),
            ("empty subject", try notificationContent(fields: [normalFields[0], normalFields[1], normalFields[2], normalFields[3], Data(), normalFields[5]])),
            ("message over bound", try notificationContent(fields: [normalFields[0], normalFields[1], Data(repeating: 0x61, count: 257), normalFields[3], normalFields[4], normalFields[5]])),
            ("sender over bound", try notificationContent(fields: [normalFields[0], normalFields[1], normalFields[2], Data(repeating: 0x61, count: 161), normalFields[4], normalFields[5]])),
            ("subject over bound", try notificationContent(fields: [normalFields[0], normalFields[1], normalFields[2], normalFields[3], Data(repeating: 0x61, count: 201), normalFields[5]])),
            ("preview over bound", try notificationContent(fields: [normalFields[0], normalFields[1], normalFields[2], normalFields[3], normalFields[4], Data(repeating: 0x61, count: 241)])),
            ("invalid utf8", try notificationContent(fields: [normalFields[0], normalFields[1], normalFields[2], Data([0xff]), normalFields[4], normalFields[5]])),
            ("nul", try notificationContent(fields: [normalFields[0], normalFields[1], normalFields[2], normalFields[3], Data("subject\0CANARY".utf8), normalFields[5]])),
            ("badge over bound", try notificationContent(badge: 1_000)),
        ]

        for (name, plaintext) in malformed {
            let wire = try cryptoValidEnvelope(plaintext)
            XCTAssertEqual(try outerPlaintext(wire), plaintext, name)
            XCTAssertThrowsError(try open(wire), name)
        }
    }

    func testRejectsWrongExpectedAuthorityIDs() throws {
        let fixture = try notificationFixture()
        let nodeSigningPublicKey = try P256.Signing.PrivateKey(rawRepresentation: scalar(3)).publicKey.x963Representation
        let wrongRecipient = try RichNotificationEnvelope.Authority(
            recipientDeviceID: AccountDeviceID("40000000-0000-4000-8000-000000000004"),
            nodeID: AccountDeviceID("30000000-0000-4000-8000-000000000003"),
            nodeSigningPublicKey: nodeSigningPublicKey
        )
        let wrongNode = try RichNotificationEnvelope.Authority(
            recipientDeviceID: AccountDeviceID("20000000-0000-4000-8000-000000000002"),
            nodeID: AccountDeviceID("50000000-0000-4000-8000-000000000005"),
            nodeSigningPublicKey: nodeSigningPublicKey
        )

        XCTAssertThrowsError(try RichNotificationEnvelope.open(fixture.richWire, recipientAgreementPrivateKey: scalar(2), authority: wrongRecipient, now: openedAt))
        XCTAssertThrowsError(try RichNotificationEnvelope.open(fixture.richWire, recipientAgreementPrivateKey: scalar(2), authority: wrongNode, now: openedAt))
    }

    func testRejectsExtremeCurrentTimeWithoutTrapping() throws {
        let fixture = try notificationFixture()
        XCTAssertThrowsError(try open(fixture.richWire, now: Date(timeIntervalSince1970: Double(Int64.max))))
    }

    func testCryptoValidCanariesRemainOpaqueAndErrorsStayGeneric() throws {
        let canaries = ["LINK-CANARY", "SENDER-CANARY", "SUBJECT-CANARY", "PREVIEW-CANARY", "RECIPIENT-KEY-CANARY"]
        let plaintext = try notificationContent(fields: [
            Data("mailbox".utf8), Data("thread".utf8), Data((canaries[0] + "|" + canaries[4]).utf8),
            Data(canaries[1].utf8), Data(canaries[2].utf8), Data(canaries[3].utf8),
        ])
        let wire = try cryptoValidEnvelope(plaintext)
        XCTAssertEqual(try outerPlaintext(wire), plaintext)
        for canary in canaries {
            XCTAssertNil(wire.range(of: Data(canary.utf8)), canary)
        }
        let opened = try open(wire)
        XCTAssertEqual(opened.content.sender, canaries[1])
        XCTAssertEqual(opened.content.subject, canaries[2])
        XCTAssertEqual(opened.content.preview, canaries[3])

        let malformed = try cryptoValidEnvelope(try notificationContent(fields: [
            Data("mailbox".utf8), Data("thread".utf8), Data(canaries[0].utf8),
            Data(canaries[1].utf8), Data(canaries[2].utf8), Data([0]) + Data(canaries[3].utf8),
        ]))
        XCTAssertEqual(try outerPlaintext(malformed), try notificationContent(fields: [
            Data("mailbox".utf8), Data("thread".utf8), Data(canaries[0].utf8),
            Data(canaries[1].utf8), Data(canaries[2].utf8), Data([0]) + Data(canaries[3].utf8),
        ]))
        XCTAssertThrowsError(try open(malformed)) { error in
            XCTAssertEqual(error as? RichNotificationEnvelopeError, .invalidEnvelope)
            let text = String(describing: error).lowercased()
            for prohibited in canaries + ["cipher", "route", "key", "identifier"] {
                XCTAssertFalse(text.contains(prohibited.lowercased()))
            }
        }
    }

    /// Test-only constructor: it preserves the fixture's fixed AAD, derives
    /// the fixture recipient's ECDH key, AES-GCM encrypts arbitrary inner
    /// bytes, and re-signs the resulting outer PPN2 envelope with low-S P-256.
    private func cryptoValidEnvelope(_ plaintext: Data) throws -> Data {
        guard plaintext.count <= 915 else { throw AccountProtocolError.oversized }
        let fixture = try notificationFixture()
        let aad = Data(fixture.richWire[..<380])
        let key = try outerKey(aad)
        let box = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: AES.GCM.Nonce(data: Data(aad[368..<380])),
            authenticating: aad
        )
        let ciphertext = box.ciphertext + box.tag
        guard ciphertext.count <= 2_048 else { throw AccountProtocolError.oversized }
        var unsigned = aad
        appendUInt16(UInt16(ciphertext.count), to: &unsigned)
        unsigned.append(ciphertext)
        let signer = try P256.Signing.PrivateKey(rawRepresentation: scalar(3))
        let signature = try normalizedLowS(signer.signature(for: Data("Plainpost.ProducerNotification.v2.signature\0".utf8) + unsigned).rawRepresentation)
        try AccountWireCodec.validateLowSSignature(signature)
        return unsigned + signature
    }

    /// Verifies only the outer signature/AES-GCM layers, deliberately leaving
    /// malformed inner plaintext for the system under test to reject.
    private func outerPlaintext(_ wire: Data) throws -> Data {
        guard wire.count >= 382 + 64 else { throw AccountProtocolError.malformedWire }
        let signatureOffset = wire.count - 64
        let unsigned = Data(wire[..<signatureOffset])
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: Data(wire[signatureOffset...]))
        let node = try P256.Signing.PrivateKey(rawRepresentation: scalar(3)).publicKey
        guard node.isValidSignature(signature, for: Data("Plainpost.ProducerNotification.v2.signature\0".utf8) + unsigned) else {
            throw AccountProtocolError.invalidSignature
        }
        let aad = Data(unsigned[..<380])
        let ciphertextLength = Int(UInt16(unsigned[380]) << 8 | UInt16(unsigned[381]))
        guard unsigned.count == 382 + ciphertextLength, ciphertextLength >= 16 else { throw AccountProtocolError.malformedWire }
        let ciphertext = Data(unsigned[382...])
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(aad[368..<380])),
            ciphertext: ciphertext.dropLast(16),
            tag: ciphertext.suffix(16)
        )
        return try AES.GCM.open(box, using: try outerKey(aad), authenticating: aad)
    }

    private func notificationContent(
        version: UInt8 = 2,
        fields: [Data] = [Data("mailbox".utf8), Data("thread".utf8), Data("message".utf8), Data("sender".utf8), Data("subject".utf8), Data("preview".utf8)],
        badge: UInt16 = 1,
        replay: Data? = nil,
        issuedAt: UInt64? = nil,
        expiresAtUnixSeconds: UInt64? = nil
    ) throws -> Data {
        guard fields.count == 6, fields.allSatisfy({ $0.count <= Int(UInt16.max) }) else { throw AccountProtocolError.malformedWire }
        let fixture = try notificationFixture()
        let aad = Data(fixture.richWire[..<380])
        var result = Data([version])
        result.append(0xA2)
        for field in fields {
            appendUInt16(UInt16(field.count), to: &result)
            result.append(field)
        }
        appendUInt16(badge, to: &result)
        result.append(replay ?? Data(aad[191..<223]))
        let headerIssuedAt = try readUInt64(aad, offset: 223)
        let headerExpiresAt = try readUInt64(aad, offset: 231)
        appendUInt64(issuedAt ?? headerIssuedAt, to: &result)
        appendUInt64(expiresAtUnixSeconds ?? headerExpiresAt, to: &result)
        return result
    }

    private func outerKey(_ aad: Data) throws -> SymmetricKey {
        let recipient = try P256.KeyAgreement.PrivateKey(rawRepresentation: scalar(2))
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: Data(aad[271..<336]))
        let shared = try recipient.sharedSecretFromKeyAgreement(with: ephemeral)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(aad[336..<368]),
            sharedInfo: Data(SHA256.hash(data: Data("Plainpost.ProducerNotification.v2.content-key\0".utf8) + aad)),
            outputByteCount: 32
        )
    }

    private func normalizedLowS(_ signature: Data) throws -> Data {
        guard signature.count == 64 else { throw AccountProtocolError.invalidSignature }
        let order = try Data(hex: "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551")
        let halfOrder = try Data(hex: "7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8")
        let r = Data(signature.prefix(32))
        let s = Data(signature.suffix(32))
        return halfOrder.lexicographicallyPrecedes(s) && s != halfOrder ? r + subtract(order, s) : signature
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xff))
    }

    private func appendUInt64(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    private func readUInt64(_ data: Data, offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { throw AccountProtocolError.malformedWire }
        return data[offset..<(offset + 8)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    private func notificationFixture() throws -> (richWire: Data, noPreviewWire: Data) {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Protocol/node-notification-v1/fixtures/envelope-v1.json")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rich = try XCTUnwrap(object["wire_base64"] as? String)
        _ = try XCTUnwrap(object["sender_subject_no_preview_wire_base64"] as? String)
        let rawRich = try XCTUnwrap(Data(base64Encoded: rich))
        // Rebuild the two checked-in vectors from their fixed AAD. This keeps
        // tests stable while the shared vector transitions outer/inner v1 to
        // v2 (and tolerates an incomplete no-preview base64 edit).
        var base = Data(rawRich[..<380]); base[4] = 2
        let richFields = ["mailbox", "thread", "message", "sender", "subject", "preview"].map { Data($0.utf8) }
        let noPreviewFields = ["mailbox", "thread", "message", "sender", "subject", ""].map { Data($0.utf8) }
        return (try rewrapPlaintext(fixtureContent(fields: richFields, base: base), base: base),
                try rewrapPlaintext(fixtureContent(fields: noPreviewFields, base: base), base: base))
    }

    private func fixtureContent(fields: [Data], base: Data) -> Data {
        var result = Data([2, 0xA2])
        for field in fields { appendUInt16(UInt16(field.count), to: &result); result.append(field) }
        appendUInt16(1, to: &result)
        result.append(Data(base[191..<223])); result.append(Data(base[223..<231])); result.append(Data(base[231..<239]))
        return result
    }

    /// The checked-in vector predates the v2 outer/inner version bump. Keep
    /// this protocol test fixture self-contained until the shared vector is
    /// regenerated: decrypt once, rewrite both version bytes, and reseal with
    /// the same fixed key material and deterministic nonce/salt.
    private func rewrapPlaintext(_ plaintext: Data, base: Data) throws -> Data {
        var aad = Data(base[..<380])
        aad[4] = 2
        let key = try outerKey(aad)
        let box = try AES.GCM.seal(plaintext, using: key,
            nonce: AES.GCM.Nonce(data: Data(aad[368..<380])), authenticating: aad)
        let encrypted = box.ciphertext + box.tag
        var unsigned = aad
        appendUInt16(UInt16(encrypted.count), to: &unsigned)
        unsigned.append(encrypted)
        let signer = try P256.Signing.PrivateKey(rawRepresentation: scalar(3))
        let signature = try normalizedLowS(signer.signature(for: Data("Plainpost.ProducerNotification.v2.signature\0".utf8) + unsigned).rawRepresentation)
        return unsigned + signature
    }

    private func scalar(_ value: UInt8) -> Data {
        Data(repeating: 0, count: 31) + Data([value])
    }

    private func authority() throws -> RichNotificationEnvelope.Authority {
        try RichNotificationEnvelope.Authority(
            recipientDeviceID: AccountDeviceID("20000000-0000-4000-8000-000000000002"),
            nodeID: AccountDeviceID("30000000-0000-4000-8000-000000000003"),
            nodeSigningPublicKey: try P256.Signing.PrivateKey(rawRepresentation: scalar(3)).publicKey.x963Representation
        )
    }

    private var openedAt: Date { Date(timeIntervalSince1970: 1_787_227_320) }
    private var expiresAt: Date { Date(timeIntervalSince1970: 1_787_228_100) }

    private func open(_ wire: Data, now: Date = Date(timeIntervalSince1970: 1_787_227_320)) throws -> RichNotificationEnvelope.Opened {
        try RichNotificationEnvelope.open(wire, recipientAgreementPrivateKey: scalar(2), authority: authority(), now: now)
    }

    private func subtract(_ lhs: Data, _ rhs: Data) -> Data {
        var result = Array(lhs)
        let right = Array(rhs)
        var borrow = 0
        for index in result.indices.reversed() {
            let difference = Int(result[index]) - Int(right[index]) - borrow
            result[index] = UInt8(difference < 0 ? difference + 256 : difference)
            borrow = difference < 0 ? 1 : 0
        }
        return Data(result)
    }
}

private extension Data {
    init(hex: String) throws {
        guard hex.count.isMultiple(of: 2) else { throw AccountProtocolError.malformedWire }
        var value = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw AccountProtocolError.malformedWire }
            value.append(byte)
            index = next
        }
        self = value
    }
}
