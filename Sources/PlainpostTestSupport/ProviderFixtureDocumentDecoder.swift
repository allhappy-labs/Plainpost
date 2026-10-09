import Foundation
import PlainpostCore

// The shared fixture decoder owns document shape, ID bijection, transcript
// byte syntax, and every closed semantic or MIME expectation union. Neither
// Core nor Integration is allowed to independently rediscover a fixture
// document or its JSON-shaped expected values.
enum ProviderFixtureDocumentDecoder {
    enum DecodingError: Error, Equatable {
        case invalid
    }

    enum Kind: Equatable {
        case imap
        case smtp
        case mime

        init?(name: String) {
            switch name {
            case "imap-transcripts.json": self = .imap
            case "smtp-transcripts.json": self = .smtp
            case "mime-corpus.json": self = .mime
            default: return nil
            }
        }
    }

    struct Document {
        let kind: Kind
        let schemaVersion: Int
        let cases: [FixtureCase]
        let operations: [Operation]

        var caseIDs: Set<String> { Set(cases.map(\.id)) }
        var operationIDs: Set<String> { Set(operations.map(\.id)) }
    }

    struct FixtureCase {
        let id: String
        let provider: String
        let transport: String
        let authentication: String
        let script: [TranscriptStep]
        let inputBase64: String?
        let generator: Generator?
        let hasNormalizedExpectation: Bool
        let boundarySources: [HeaderBoundarySource]
        let mime: MIMEFixture?
    }

    struct TranscriptStep {
        let kind: String
        let direction: String?
        let bytesBase64: String?
    }

    struct Generator: Equatable {
        let kind: String
        let dimension: String
        let accepted: Int?
        let rejected: Int?
        let attachmentCount: GeneratorLimit?
        let attachmentMetadataBytes: GeneratorLimit?

        var boundaryCases: [GeneratorBoundary] {
            if let accepted, let rejected {
                return [.init(kind: kind, dimension: dimension, accepted: accepted, rejected: rejected)]
            }
            guard let attachmentCount, let attachmentMetadataBytes else { return [] }
            return [
                .init(
                    kind: kind,
                    dimension: "attachment_count",
                    accepted: attachmentCount.accepted,
                    rejected: attachmentCount.rejected
                ),
                .init(
                    kind: kind,
                    dimension: "attachment_metadata_bytes",
                    accepted: attachmentMetadataBytes.accepted,
                    rejected: attachmentMetadataBytes.rejected
                ),
            ]
        }
    }

    struct GeneratorLimit: Equatable {
        let accepted: Int
        let rejected: Int
    }

    struct GeneratorBoundary: Equatable {
        let kind: String
        let dimension: String
        let accepted: Int
        let rejected: Int
    }

    struct HeaderBoundarySource: Equatable {
        let kind: String
        let header: String
        let dimension: String
        let accepted: Int
        let rejected: Int

        var name: String {
            "\(kind.replacingOccurrences(of: "_", with: "-"))-\(header.replacingOccurrences(of: "_", with: "-"))-\(dimension.replacingOccurrences(of: "_", with: "-"))"
        }
    }

    struct MIMEFixture: Equatable {
        let id: String
        let input: Data?
        let generator: Generator?
        let boundarySources: [HeaderBoundarySource]
        let expectation: MIMEExpectation?
        let result: String
        let error: String?
    }

    struct MIMEExpectation: Equatable {
        let projection: MIMEProviderProjection
        let attachments: [MIMEAttachmentExpectation]
    }

    struct MIMEAttachmentExpectation: Equatable {
        let part: MIMEProviderProjection.Part
        let bytes: Data?
        let byteCount: Int?
        let sha256: String?
        let bytesError: String?
    }

    // Raw union payloads are deliberately private to this decoder. The
    // Integration runner receives its rich typed operation through its own
    // adapter after this common structural gate has established a valid ID
    // bijection and exact document envelope.
    struct Operation {
        let id: String
        fileprivate let input: [String: Any]
        fileprivate let expected: [String: Any]
    }

    static func load(_ name: String) throws -> Document {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Protocol/provider-fixtures/\(name)")
        return try decode(Data(contentsOf: url), named: name)
    }

    static func decode(_ source: Data, named name: String) throws -> Document {
        guard let kind = Kind(name: name),
              let root = try JSONSerialization.jsonObject(with: source) as? [String: Any],
              Set(root.keys) == rootKeys(kind),
              root["schemaVersion"] as? Int == 1,
              let rawCases = root["cases"] as? [[String: Any]], !rawCases.isEmpty
        else { throw DecodingError.invalid }

        var seenCaseIDs = Set<String>()
        let cases = try rawCases.map { raw -> FixtureCase in
            let fixture = try fixtureCase(raw, kind: kind)
            guard seenCaseIDs.insert(fixture.id).inserted else { throw DecodingError.invalid }
            return fixture
        }

        let operations: [Operation]
        if kind == .mime {
            operations = []
        } else {
            guard let rawOperations = root["operations"] as? [[String: Any]],
                  rawOperations.count == cases.count
            else { throw DecodingError.invalid }
            var seenOperationIDs = Set<String>()
            operations = try rawOperations.map { raw in
                guard Set(raw.keys) == ["id", "input", "expected"],
                      let id = raw["id"] as? String,
                      validID(id),
                      let input = raw["input"] as? [String: Any],
                      let expected = raw["expected"] as? [String: Any],
                      seenOperationIDs.insert(id).inserted,
                      !input.isEmpty,
                      !expected.isEmpty
                else { throw DecodingError.invalid }
                return Operation(id: id, input: input, expected: expected)
            }
            guard seenOperationIDs == seenCaseIDs else { throw DecodingError.invalid }
        }
        return Document(kind: kind, schemaVersion: 1, cases: cases, operations: operations)
    }

    private static func fixtureCase(_ raw: [String: Any], kind: Kind) throws -> FixtureCase {
        let allowedKeys: Set<String>
        switch kind {
        case .imap, .smtp:
            allowedKeys = ["id", "provider", "transport", "authentication", "script", "expected"]
        case .mime:
            allowedKeys = [
                "id", "provider", "transport", "authentication", "script", "expected",
                "inputBase64", "generator", "boundarySources",
            ]
        }
        guard Set(raw.keys).isSubset(of: allowedKeys),
              let id = raw["id"] as? String,
              validID(id),
              let provider = raw["provider"] as? String,
              ["gmail", "icloud", "generic"].contains(provider),
              let transport = raw["transport"] as? String,
              ["implicit_tls", "starttls", "loopback_fixture"].contains(transport),
              let authentication = raw["authentication"] as? String,
              ["oauth_bearer", "app_password", "password"].contains(authentication),
              let rawScript = raw["script"] as? [[String: Any]], !rawScript.isEmpty,
              let expected = raw["expected"] as? [String: Any]
        else { throw DecodingError.invalid }

        let script: [TranscriptStep]
        if kind == .mime {
            guard rawScript.allSatisfy({
                Set($0.keys) == ["kind"] && ["message", "generator"].contains($0["kind"] as? String ?? "")
            }) else { throw DecodingError.invalid }
            script = rawScript.compactMap {
                ($0["kind"] as? String).map { TranscriptStep(kind: $0, direction: nil, bytesBase64: nil) }
            }
        } else {
            script = try rawScript.map(transcriptStep)
        }
        let inputBase64 = raw["inputBase64"] as? String
        let input: Data?
        if let inputBase64 {
            guard let decoded = Data(base64Encoded: inputBase64),
                  decoded.base64EncodedString() == inputBase64
            else { throw DecodingError.invalid }
            input = decoded
        } else {
            input = nil
        }
        let parsedGenerator: Generator?
        if raw.keys.contains("generator") {
            guard let rawGenerator = raw["generator"] else { throw DecodingError.invalid }
            parsedGenerator = try generator(rawGenerator)
        } else {
            parsedGenerator = nil
        }
        let sources = try (raw["boundarySources"] as? [[String: Any]] ?? []).map(headerBoundarySource)
        let mime: MIMEFixture?
        if kind == .mime {
            guard rawScript.count == 1,
                  rawScript[0]["kind"] as? String == (input == nil ? "generator" : "message")
            else { throw DecodingError.invalid }
            mime = try mimeFixture(
                id: id,
                input: input,
                generator: parsedGenerator,
                boundarySources: sources,
                expected: expected
            )
        } else if inputBase64 != nil || parsedGenerator != nil || !sources.isEmpty {
            throw DecodingError.invalid
        } else {
            mime = nil
        }
        guard kind == .mime || expected["normalized"] is [String: Any] else {
            throw DecodingError.invalid
        }
        return FixtureCase(
            id: id,
            provider: provider,
            transport: transport,
            authentication: authentication,
            script: script,
            inputBase64: inputBase64,
            generator: parsedGenerator,
            hasNormalizedExpectation: expected["normalized"] is [String: Any],
            boundarySources: sources,
            mime: mime
        )
    }

    static func mimeFixtures(_ document: Document) throws -> [MIMEFixture] {
        guard document.kind == .mime else { throw DecodingError.invalid }
        return try document.cases.map {
            guard let fixture = $0.mime else { throw DecodingError.invalid }
            return fixture
        }
    }

    // The only fixture-facing production MIME ingress seam. Core and
    // Integration compare this typed value with decoded corpus expectations;
    // they never reconstruct a dictionary projection of parser internals.
    static func mimeProjection(from input: Data) throws -> MIMEProviderProjection {
        try MIMEMessageDecoder.providerProjection(from: input)
    }

    // Hydration assertions use the same descriptor-to-payload conversion in
    // Core and Integration. The decoder rejects a fixture whose declared
    // bytes, size, or digest cannot construct the exact production payload.
    static func hydratedAttachmentPayloads(
        for expectation: MIMEExpectation
    ) throws -> [IncomingMessageAttachmentPayload] {
        try expectation.attachments.map { attachment in
            guard attachment.bytesError == nil,
                  let bytes = attachment.bytes,
                  let byteCount = attachment.byteCount,
                  let sha256 = attachment.sha256
            else { throw DecodingError.invalid }
            let payload = IncomingMessageAttachmentPayload(
                partPath: attachment.part.path,
                filename: attachment.part.filename,
                mimeType: attachment.part.mediaType,
                data: bytes,
                contentID: attachment.part.contentID
            )
            guard payload.byteCount == byteCount,
                  payload.sha256 == sha256
            else { throw DecodingError.invalid }
            return payload
        }
    }

    private static func mimeFixture(
        id: String,
        input: Data?,
        generator: Generator?,
        boundarySources: [HeaderBoundarySource],
        expected: [String: Any]
    ) throws -> MIMEFixture {
        guard (input != nil) != (generator != nil) else { throw DecodingError.invalid }
        if let input {
            guard Set(expected.keys) == ["result", "normalized"],
                  expected["result"] as? String == "normalized",
                  let rawNormalized = expected["normalized"] as? [String: Any]
            else { throw DecodingError.invalid }
            return .init(
                id: id,
                input: input,
                generator: nil,
                boundarySources: boundarySources,
                expectation: try mimeExpectation(rawNormalized),
                result: "normalized",
                error: nil
            )
        }
        guard let generator,
              Set(expected.keys) == ["result", "error"],
              expected["result"] as? String == "resource_limit",
              let error = expected["error"] as? String,
              !error.isEmpty
        else { throw DecodingError.invalid }
        return .init(
            id: id,
            input: nil,
            generator: generator,
            boundarySources: boundarySources,
            expectation: nil,
            result: "resource_limit",
            error: error
        )
    }

    private static func mimeExpectation(_ raw: [String: Any]) throws -> MIMEExpectation {
        let keys: Set<String> = [
            "subject", "rfcMessageID", "date", "from", "sender", "replyTo", "to", "cc", "bcc",
            "inReplyTo", "references", "textBody", "htmlBody", "parts",
        ]
        guard Set(raw.keys) == keys,
              let subject = raw["subject"] as? String,
              let rfcMessageID = raw["rfcMessageID"] as? String,
              let date = raw["date"] as? String,
              let from = raw["from"] as? [[String: Any]],
              let replyTo = raw["replyTo"] as? [[String: Any]],
              let to = raw["to"] as? [[String: Any]],
              let cc = raw["cc"] as? [[String: Any]],
              let bcc = raw["bcc"] as? [[String: Any]],
              let inReplyTo = raw["inReplyTo"] as? [String],
              let references = raw["references"] as? [String],
              let textBody = raw["textBody"] as? [String: Any],
              let htmlBody = raw["htmlBody"] as? [String: Any],
              let parts = raw["parts"] as? [[String: Any]],
              from.count <= 256, replyTo.count <= 256, to.count <= 256, cc.count <= 256, bcc.count <= 256,
              inReplyTo.count <= 256, references.count <= 256, parts.count <= 4_096
        else { throw DecodingError.invalid }
        let sender: MIMEProviderProjection.Address?
        if raw["sender"] is NSNull {
            sender = nil
        } else {
            guard let rawSender = raw["sender"] as? [String: Any] else { throw DecodingError.invalid }
            sender = try mimeAddress(rawSender)
        }
        let attachments = try parts.map(mimeAttachment)
        return .init(
            projection: .init(
                subject: subject,
                rfcMessageID: rfcMessageID,
                date: date,
                from: try from.map(mimeAddress),
                sender: sender,
                replyTo: try replyTo.map(mimeAddress),
                to: try to.map(mimeAddress),
                cc: try cc.map(mimeAddress),
                bcc: try bcc.map(mimeAddress),
                inReplyTo: try mimeMessageIDs(inReplyTo),
                references: try mimeMessageIDs(references),
                textBody: try mimeBody(textBody),
                htmlBody: try mimeBody(htmlBody),
                parts: attachments.map(\.part)
            ),
            attachments: attachments
        )
    }

    private static func mimeAddress(_ raw: [String: Any]) throws -> MIMEProviderProjection.Address {
        guard Set(raw.keys) == ["displayName", "mailbox"],
              let displayName = raw["displayName"] as? String, displayName.utf8.count <= 998,
              let mailbox = raw["mailbox"] as? String, mailbox.utf8.count <= 512
        else { throw DecodingError.invalid }
        return .init(displayName: displayName, mailbox: mailbox)
    }

    private static func mimeMessageIDs(_ values: [String]) throws -> [String] {
        guard values.allSatisfy({ $0.utf8.count <= 998 }) else { throw DecodingError.invalid }
        return values
    }

    private static func mimeBody(_ raw: [String: Any]) throws -> MIMEProviderProjection.Body {
        guard Set(raw.keys) == ["state", "value"],
              let state = raw["state"] as? String,
              let value = raw["value"] as? String,
              value.utf8.count <= 1 << 20
        else { throw DecodingError.invalid }
        switch state {
        case "absent":
            guard value.isEmpty else { throw DecodingError.invalid }
            return .absent
        case "complete":
            return .complete(value)
        case "malformed":
            guard value.isEmpty else { throw DecodingError.invalid }
            return .malformed
        case "omitted_oversized":
            guard value.isEmpty else { throw DecodingError.invalid }
            return .omittedOversized
        default:
            throw DecodingError.invalid
        }
    }

    private static func mimeAttachment(_ raw: [String: Any]) throws -> MIMEAttachmentExpectation {
        let descriptorKeys: Set<String> = ["path", "filename", "mediaType", "disposition", "contentID", "declaredSize"]
        guard Set(raw.keys) == descriptorKeys.union(["bytes"]) || Set(raw.keys) == descriptorKeys.union(["bytesError"]),
              let path = raw["path"] as? String, canonicalPartPath(path),
              let filename = raw["filename"] as? String, filename.utf8.count <= 998,
              let mediaType = raw["mediaType"] as? String, !mediaType.isEmpty, mediaType.utf8.count <= 256,
              let disposition = raw["disposition"] as? String, ["attachment", "inline", "none"].contains(disposition),
              let contentID = raw["contentID"] as? String, contentID.utf8.count <= 998,
              let declaredSize = raw["declaredSize"] as? Int, declaredSize >= 0
        else { throw DecodingError.invalid }
        let part = MIMEProviderProjection.Part(
            path: path,
            filename: filename,
            mediaType: mediaType,
            disposition: disposition,
            contentID: contentID,
            declaredSize: declaredSize
        )
        if let bytesError = raw["bytesError"] as? String {
            guard bytesError == "protocol" else { throw DecodingError.invalid }
            return .init(part: part, bytes: nil, byteCount: nil, sha256: nil, bytesError: bytesError)
        }
        guard let rawBytes = raw["bytes"] as? [String: Any],
              Set(rawBytes.keys) == ["base64", "size", "sha256"],
              let encoded = rawBytes["base64"] as? String,
              let bytes = Data(base64Encoded: encoded), bytes.base64EncodedString() == encoded,
              let byteCount = rawBytes["size"] as? Int, byteCount == bytes.count,
              let sha256 = rawBytes["sha256"] as? String,
              sha256.count == 64, sha256.allSatisfy({ $0.isNumber || ("a" ... "f").contains($0) })
        else { throw DecodingError.invalid }
        return .init(part: part, bytes: bytes, byteCount: byteCount, sha256: sha256, bytesError: nil)
    }

    private static func transcriptStep(_ raw: [String: Any]) throws -> TranscriptStep {
        guard let kind = raw["kind"] as? String else { throw DecodingError.invalid }
        switch kind {
        case "wire":
            guard Set(raw.keys) == ["kind", "direction", "bytesBase64"],
                  let direction = raw["direction"] as? String,
                  ["client", "server"].contains(direction),
                  let bytesBase64 = raw["bytesBase64"] as? String,
                  let bytes = Data(base64Encoded: bytesBase64),
                  bytes.base64EncodedString() == bytesBase64
            else { throw DecodingError.invalid }
            return TranscriptStep(kind: kind, direction: direction, bytesBase64: bytesBase64)
        case "auth":
            guard Set(raw.keys) == ["kind", "direction", "credentialGeneration"],
                  raw["direction"] as? String == "client",
                  raw["credentialGeneration"] as? String == "synthetic-v1"
            else { throw DecodingError.invalid }
            return TranscriptStep(kind: kind, direction: "client", bytesBase64: nil)
        case "tls":
            guard Set(raw.keys) == ["kind", "direction"], raw["direction"] as? String == "client" else {
                throw DecodingError.invalid
            }
            return TranscriptStep(kind: kind, direction: "client", bytesBase64: nil)
        case "message":
            guard Set(raw.keys) == ["kind", "from", "to", "bytesBase64"],
                  let from = raw["from"] as? String, !from.isEmpty,
                  let recipients = raw["to"] as? [String], !recipients.isEmpty,
                  let bytesBase64 = raw["bytesBase64"] as? String,
                  let bytes = Data(base64Encoded: bytesBase64), !bytes.isEmpty,
                  bytes.base64EncodedString() == bytesBase64
            else { throw DecodingError.invalid }
            return TranscriptStep(kind: kind, direction: nil, bytesBase64: bytesBase64)
        case "data":
            let allowed: Set<String> = ["kind", "messageSHA256", "messageSize", "prefixSize"]
            guard Set(raw.keys).isSubset(of: allowed) else { throw DecodingError.invalid }
            let full = raw["messageSHA256"] as? String != nil && raw["messageSize"] as? String != nil
            let prefix = raw["prefixSize"] as? String != nil
            guard full != prefix else { throw DecodingError.invalid }
            return TranscriptStep(kind: kind, direction: nil, bytesBase64: nil)
        case "disconnect":
            guard Set(raw.keys) == ["kind", "direction"], raw["direction"] as? String == "server" else {
                throw DecodingError.invalid
            }
            return TranscriptStep(kind: kind, direction: "server", bytesBase64: nil)
        default:
            throw DecodingError.invalid
        }
    }

    private static func generator(_ raw: Any) throws -> Generator {
        guard let raw = raw as? [String: Any],
              let kind = raw["kind"] as? String,
              let dimension = raw["dimension"] as? String
        else { throw DecodingError.invalid }
        switch (kind, dimension) {
        case ("nested_multipart", "depth"),
             ("repeated_parts", "part_count"),
             ("header_bytes", "header_bytes"),
             ("attachment_bytes", "attachment_bytes"),
             ("aggregate_attachment_bytes", "aggregate_attachment_bytes"),
             ("header_bytes", "body_bytes"):
            guard Set(raw.keys) == ["kind", "dimension", "accepted", "rejected"],
                  let accepted = raw["accepted"] as? Int,
                  let rejected = raw["rejected"] as? Int,
                  generatorBoundaryIsExact(kind: kind, dimension: dimension, accepted: accepted, rejected: rejected)
            else { throw DecodingError.invalid }
            return Generator(
                kind: kind,
                dimension: dimension,
                accepted: accepted,
                rejected: rejected,
                attachmentCount: nil,
                attachmentMetadataBytes: nil
            )
        case ("repeated_parts", "attachment_boundaries"):
            guard Set(raw.keys) == ["kind", "dimension", "attachmentCount", "attachmentMetadataBytes"],
                  let rawAttachmentCount = raw["attachmentCount"],
                  let rawAttachmentMetadataBytes = raw["attachmentMetadataBytes"]
            else { throw DecodingError.invalid }
            let attachmentCount = try generatorLimit(rawAttachmentCount)
            let attachmentMetadataBytes = try generatorLimit(rawAttachmentMetadataBytes)
            guard attachmentCount == .init(accepted: 256, rejected: 257),
                  attachmentMetadataBytes == .init(accepted: 65_536, rejected: 65_537)
            else { throw DecodingError.invalid }
            return Generator(
                kind: kind,
                dimension: dimension,
                accepted: nil,
                rejected: nil,
                attachmentCount: attachmentCount,
                attachmentMetadataBytes: attachmentMetadataBytes
            )
        default:
            throw DecodingError.invalid
        }
    }

    private static func generatorLimit(_ raw: Any) throws -> GeneratorLimit {
        guard let raw = raw as? [String: Any],
              Set(raw.keys) == ["accepted", "rejected"],
              let accepted = raw["accepted"] as? Int,
              let rejected = raw["rejected"] as? Int,
              accepted > 0,
              rejected == accepted + 1
        else { throw DecodingError.invalid }
        return .init(accepted: accepted, rejected: rejected)
    }

    private static func generatorBoundaryIsExact(
        kind: String,
        dimension: String,
        accepted: Int,
        rejected: Int
    ) -> Bool {
        switch (kind, dimension, accepted, rejected) {
        case ("nested_multipart", "depth", 64, 65),
             ("repeated_parts", "part_count", 2_000, 2_001),
             ("header_bytes", "header_bytes", 2_097_152, 2_097_153),
             ("attachment_bytes", "attachment_bytes", 52_428_800, 52_428_801),
             ("aggregate_attachment_bytes", "aggregate_attachment_bytes", 104_857_600, 104_857_601),
             ("header_bytes", "body_bytes", 1_048_576, 1_048_577):
            return true
        default:
            return false
        }
    }

    private static func headerBoundarySource(_ raw: [String: Any]) throws -> HeaderBoundarySource {
        guard Set(raw.keys) == ["kind", "header", "dimension", "accepted", "rejected"],
              let kind = raw["kind"] as? String,
              ["message_ids", "addresses"].contains(kind),
              let header = raw["header"] as? String,
              ["in_reply_to", "references", "to", "cc"].contains(header),
              let dimension = raw["dimension"] as? String,
              ["count", "aggregate_bytes"].contains(dimension),
              let accepted = raw["accepted"] as? Int, accepted > 0,
              let rejected = raw["rejected"] as? Int, rejected == accepted + 1
        else { throw DecodingError.invalid }
        switch (kind, header, dimension, accepted, rejected) {
        case ("message_ids", "in_reply_to", "count", 256, 257),
             ("message_ids", "references", "count", 256, 257),
             ("addresses", "to", "count", 256, 257),
             ("addresses", "cc", "count", 256, 257),
             ("message_ids", "in_reply_to", "aggregate_bytes", 65_536, 65_537),
             ("message_ids", "references", "aggregate_bytes", 65_536, 65_537),
             ("addresses", "to", "aggregate_bytes", 65_536, 65_537),
             ("addresses", "cc", "aggregate_bytes", 65_536, 65_537):
            break
        default:
            throw DecodingError.invalid
        }
        return HeaderBoundarySource(
            kind: kind,
            header: header,
            dimension: dimension,
            accepted: accepted,
            rejected: rejected
        )
    }

    private static func rootKeys(_ kind: Kind) -> Set<String> {
        switch kind {
        case .imap, .smtp: ["schemaVersion", "operations", "cases"]
        case .mime: ["schemaVersion", "cases"]
        }
    }

    private static func validID(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 128,
              value.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" })
        else { return false }
        return value.first != "-" && value.last != "-" && !value.contains("--")
    }

    static func smtpOperations(_ document: Document) throws -> [ProviderFixtureSMTPSemanticOperation] {
        guard document.kind == .smtp else { throw DecodingError.invalid }
        let cases = Dictionary(uniqueKeysWithValues: document.cases.map { ($0.id, $0) })
        guard cases.count == document.cases.count else { throw DecodingError.invalid }
        return try document.operations.map { raw in
            guard let fixture = cases[raw.id],
                  let provider = raw.input["provider"] as? String,
                  let transport = raw.input["transport"] as? String,
                  let authentication = raw.input["authentication"] as? String,
                  provider == fixture.provider,
                  transport == fixture.transport,
                  authentication == fixture.authentication
            else { throw DecodingError.invalid }
            return try smtpSemanticOperation(id: raw.id, input: raw.input, expected: raw.expected)
        }
    }

    private static func smtpSemanticOperation(
        id: String,
        input: [String: Any],
        expected: [String: Any]
    ) throws -> ProviderFixtureSMTPSemanticOperation {
        let requiredInput: Set<String> = [
            "action", "provider", "transport", "authentication", "envelopeFrom", "recipients",
            "messageID", "messageBase64", "scenario", "capabilities", "sentBehavior", "cancellation", "authRejections",
        ]
        guard Set(input.keys) == requiredInput,
              input["action"] as? String == "submit",
              let provider = input["provider"] as? String,
              ["gmail", "icloud", "generic"].contains(provider),
              let transport = input["transport"] as? String,
              transport == "starttls",
              let authentication = input["authentication"] as? String,
              ["oauth_bearer", "app_password", "password"].contains(authentication),
              let envelopeFrom = input["envelopeFrom"] as? String,
              validSMTPAddress(envelopeFrom),
              let recipients = input["recipients"] as? [String],
              !recipients.isEmpty, recipients.count <= 256,
              recipients.allSatisfy(validSMTPAddress),
              Set(recipients.map(canonicalSMTPAddress)).count == recipients.count,
              let messageID = input["messageID"] as? String,
              validMessageID(messageID),
              let messageBase64 = input["messageBase64"] as? String,
              let source = Data(base64Encoded: messageBase64), !source.isEmpty,
              source.base64EncodedString() == messageBase64,
              String(decoding: source, as: UTF8.self).hasPrefix("Message-ID: \(messageID)\r\n"),
              let scenario = input["scenario"] as? String,
              [
                  "pre_data_unavailable", "recipient_rejected", "disconnect_after_354",
                  "disconnect_while_writing_data", "disconnect_before_final_reply", "final_451",
                  "final_550", "accepted", "accepted_quit_drop", "smtp_utf8_missing",
                  "oversized_response", "cancel_before_data", "cancel_after_data",
              ].contains(scenario),
              let capabilities = input["capabilities"] as? [String],
              (2 ... 4).contains(capabilities.count),
              Set(capabilities).count == capabilities.count,
              capabilities.allSatisfy(["STARTTLS", "SMTPUTF8", "AUTH PLAIN", "AUTH XOAUTH2"].contains),
              capabilities.contains("STARTTLS"),
              let sentBehavior = input["sentBehavior"] as? String,
              ["not_applicable", "provider_managed", "append_success", "append_rejected", "append_unavailable"].contains(sentBehavior),
              let cancellation = input["cancellation"] as? String,
              ["none", "before_data", "after_data"].contains(cancellation),
              let authRejections = input["authRejections"] as? Int,
              (0 ... 1).contains(authRejections),
              (scenario == "cancel_before_data") == (cancellation == "before_data"),
              (scenario == "cancel_after_data") == (cancellation == "after_data"),
              ["cancel_before_data", "cancel_after_data"].contains(scenario) || cancellation == "none",
              authRejections == 0 || (provider == "gmail" && authentication == "oauth_bearer"),
              authentication == "oauth_bearer" ? capabilities.contains("AUTH XOAUTH2") : capabilities.contains("AUTH PLAIN")
        else { throw DecodingError.invalid }

        let operation = ProviderFixtureSMTPSemanticOperation(
            id: id,
            input: .init(
                provider: provider,
                transport: transport,
                authentication: authentication,
                envelopeFrom: envelopeFrom,
                recipients: recipients,
                messageID: messageID,
                messageBase64: messageBase64,
                scenario: scenario,
                capabilities: capabilities,
                sentBehavior: sentBehavior,
                cancellation: cancellation,
                authRejections: authRejections
            ),
            expected: .init(result: try smtpSemanticResult(expected))
        )
        guard validSMTPProviderBinding(operation) else { throw DecodingError.invalid }
        return operation
    }

    private static func smtpSemanticResult(
        _ expected: [String: Any]
    ) throws -> ProviderFixtureSMTPSemanticOperation.Result {
        guard Set(expected.keys) == ["result"],
              let rawResult = expected["result"] as? [String: Any],
              let kind = rawResult["kind"] as? String
        else { throw DecodingError.invalid }
        switch kind {
        case "outcome":
            guard Set(rawResult.keys) == ["kind", "outcome"],
                  let rawOutcome = rawResult["outcome"] as? [String: Any]
            else { throw DecodingError.invalid }
            return .outcome(try smtpOutcome(rawOutcome))
        case "error":
            guard Set(rawResult.keys) == ["kind", "error"],
                  let rawError = rawResult["error"] as? [String: Any]
            else { throw DecodingError.invalid }
            return .error(try smtpErrorExpectation(rawError))
        default:
            throw DecodingError.invalid
        }
    }

    private static func smtpOutcome(
        _ raw: [String: Any]
    ) throws -> ProviderFixtureSMTPSemanticOperation.Outcome {
        guard Set(raw.keys) == ["state", "code", "providerReference", "sentCopy", "destinationRawID"],
              let state = raw["state"] as? String,
              ["applied", "rejected", "delivery_uncertain"].contains(state),
              let code = raw["code"] as? String,
              ["accepted", "provider_rejected", "unsupported", "acceptance_unknown"].contains(code),
              raw["providerReference"] as? String == "",
              let sentCopy = raw["sentCopy"] as? String,
              ["not_applicable", "provider_managed", "appended", "missing", "unknown"].contains(sentCopy),
              raw["destinationRawID"] as? String == ""
        else { throw DecodingError.invalid }
        return .init(state: state, code: code, providerReference: "", sentCopy: sentCopy, destinationRawID: "")
    }

    private static func smtpErrorExpectation(
        _ raw: [String: Any]
    ) throws -> ProviderFixtureSMTPSemanticOperation.ErrorExpectation {
        guard Set(raw.keys) == ["tag", "retry", "cause"],
              let tag = raw["tag"] as? String,
              providerErrorTags.contains(tag),
              let retry = raw["retry"] as? String,
              ["never", "safe", "reconcile_first"].contains(retry),
              let cause = raw["cause"] as? String,
              ["", "context_canceled", "deadline_exceeded"].contains(cause)
        else { throw DecodingError.invalid }
        return .init(tag: tag, retry: retry, cause: cause)
    }

    private static func validSMTPProviderBinding(_ operation: ProviderFixtureSMTPSemanticOperation) -> Bool {
        switch operation.provider {
        case "gmail":
            guard operation.authentication == "oauth_bearer", operation.input.sentBehavior == "provider_managed" else { return false }
        case "icloud":
            guard operation.authentication == "app_password",
                  ["append_success", "append_rejected", "append_unavailable"].contains(operation.input.sentBehavior)
            else { return false }
        case "generic":
            guard operation.authentication == "password", operation.input.sentBehavior == "not_applicable" else { return false }
        default:
            return false
        }
        guard let outcome = operation.expected.result.outcome else { return true }
        if outcome.code == "acceptance_unknown" { return outcome.sentCopy == "unknown" }
        if outcome.code != "accepted" { return outcome.sentCopy == "not_applicable" }
        let expectedSentCopy = [
            "not_applicable": "not_applicable",
            "provider_managed": "provider_managed",
            "append_success": "appended",
            "append_rejected": "missing",
            "append_unavailable": "unknown",
        ][operation.input.sentBehavior]
        return outcome.sentCopy == expectedSentCopy
    }

    private static let providerErrorTags: Set<String> = [
        "invalid", "unsupported", "authentication", "permission", "not_found", "conflict",
        "rate_limited", "unavailable", "protocol", "tls", "resource_limit", "closed",
    ]

    private static func validSMTPAddress(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512,
              !value.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "<" || $0 == ">" }),
              let at = value.lastIndex(of: "@")
        else { return false }
        return at != value.startIndex && value.index(after: at) != value.endIndex
    }

    private static func canonicalSMTPAddress(_ value: String) -> String {
        guard let at = value.lastIndex(of: "@") else { return value }
        return String(value[..<value.index(after: at)]) + String(value[value.index(after: at)...]).lowercased()
    }

    private static func validMessageID(_ value: String) -> Bool {
        value.utf8.count <= 998 && value.hasPrefix("<") && value.hasSuffix(">")
            && !value.dropFirst().dropLast().contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" })
    }

    static func imapOperations(_ document: Document) throws -> [ProviderFixtureSemanticOperation] {
        guard document.kind == .imap else { throw DecodingError.invalid }
        let cases = Dictionary(uniqueKeysWithValues: document.cases.map { ($0.id, $0) })
        guard cases.count == document.cases.count else { throw DecodingError.invalid }
        return try document.operations.map { raw in
            guard let fixture = cases[raw.id],
                  let provider = raw.input["provider"] as? String,
                  let transport = raw.input["transport"] as? String,
                  let authentication = raw.input["authentication"] as? String,
                  provider == fixture.provider,
                  transport == fixture.transport,
                  authentication == fixture.authentication
            else { throw DecodingError.invalid }
            return try semanticOperation(id: raw.id, input: raw.input, expected: raw.expected)
        }
    }

    private static func semanticOperation(
        id: String,
        input: [String: Any],
        expected: [String: Any]
    ) throws -> ProviderFixtureSemanticOperation {
        let commonFields: Set<String> = ["action", "provider", "transport", "authentication", "peer"]
        guard let actionValue = input["action"] as? String,
              let action = ProviderFixtureSemanticOperation.Action(rawValue: actionValue),
              let provider = input["provider"] as? String,
              ["gmail", "icloud", "generic"].contains(provider),
              input["transport"] as? String == "loopback_fixture",
              let authentication = input["authentication"] as? String,
              ["oauth_bearer", "app_password", "password"].contains(authentication),
              let peer = try? semanticPeer(input["peer"])
        else { throw DecodingError.invalid }

        let shared = ProviderFixtureSemanticOperation.Common(
            provider: provider,
            transport: "loopback_fixture",
            authentication: authentication,
            peer: peer
        )
        func exact(_ fields: Set<String>) -> Bool {
            Set(input.keys) == commonFields.union(fields)
        }
        func mailbox() throws -> String {
            guard let value = input["mailbox"] as? String,
                  !value.isEmpty, value.utf8.count <= 512
            else { throw DecodingError.invalid }
            return value
        }
        func rawID() throws -> String {
            guard let value = input["rawID"] as? String, canonicalPositiveInteger(value)
            else { throw DecodingError.invalid }
            return value
        }
        func pageSize() throws -> Int {
            guard let value = input["pageSize"] as? Int, (1 ... 500).contains(value)
            else { throw DecodingError.invalid }
            return value
        }

        let parsed: (input: ProviderFixtureSemanticOperation.Input, appendAttempts: Int)
        switch action {
        case .discover:
            guard exact([]) else { throw DecodingError.invalid }
            parsed = (.discover(shared), 0)
        case .synchronize:
            let parsedMailbox = try mailbox()
            let parsedPageSize = try pageSize()
            guard let mode = input["syncMode"] as? String else { throw DecodingError.invalid }
            switch mode {
            case "baseline":
                guard exact(["mailbox", "pageSize", "syncMode"]) else { throw DecodingError.invalid }
                parsed = (.synchronizeBaseline(shared, mailbox: parsedMailbox, pageSize: parsedPageSize), 0)
            case "incremental":
                guard exact(["mailbox", "pageSize", "syncMode", "cursor"]),
                      let value = input["cursor"] as? String, validOptionalCursor(value), !value.isEmpty
                else { throw DecodingError.invalid }
                parsed = (.synchronizeIncremental(shared, mailbox: parsedMailbox, pageSize: parsedPageSize, cursor: value), 0)
            case "reconcile":
                guard exact(["mailbox", "pageSize", "syncMode", "cursor", "knownRawIDs"]),
                      let value = input["cursor"] as? String, validOptionalCursor(value), !value.isEmpty,
                      let values = input["knownRawIDs"] as? [String], !values.isEmpty, values.count <= 500,
                      Set(values).count == values.count, values.allSatisfy(canonicalPositiveInteger)
                else { throw DecodingError.invalid }
                parsed = (.synchronizeReconcile(
                    shared,
                    mailbox: parsedMailbox,
                    pageSize: parsedPageSize,
                    cursor: value,
                    knownRawIDs: values
                ), 0)
            default:
                throw DecodingError.invalid
            }
        case .wait:
            guard exact(["mailbox", "maximumWaitMilliseconds"]),
                  let value = input["maximumWaitMilliseconds"] as? Int,
                  (1 ... 1_500_000).contains(value)
            else { throw DecodingError.invalid }
            parsed = (.wait(shared, mailbox: try mailbox(), maximumWaitMilliseconds: value), 0)
        case .setFlags:
            let parsedMailbox = try mailbox()
            let parsedRawID = try rawID()
            guard let parsedAdd = input["addFlags"] as? [String], validFlags(parsedAdd),
                  let parsedRemove = input["removeFlags"] as? [String], validFlags(parsedRemove),
                  !parsedAdd.isEmpty || !parsedRemove.isEmpty,
                  Set(parsedAdd).isDisjoint(with: Set(parsedRemove))
            else { throw DecodingError.invalid }
            var fields: Set<String> = ["mailbox", "rawID", "addFlags", "removeFlags"]
            let parsedExpectedModSequence: Int?
            if let value = input["expectedModSequence"] {
                guard let parsed = value as? Int, parsed > 0 else { throw DecodingError.invalid }
                parsedExpectedModSequence = parsed
                fields.insert("expectedModSequence")
            } else {
                parsedExpectedModSequence = nil
            }
            guard exact(fields) else { throw DecodingError.invalid }
            parsed = (.setFlags(
                shared,
                mailbox: parsedMailbox,
                rawID: parsedRawID,
                addFlags: parsedAdd,
                removeFlags: parsedRemove,
                expectedModSequence: parsedExpectedModSequence
            ), 0)
        case .setLabels:
            guard exact(["mailbox", "rawID", "addLabels", "removeLabels"]), provider == "gmail" else { throw DecodingError.invalid }
            let parsedAddLabels = try semanticLabelArray(input["addLabels"])
            let parsedRemoveLabels = try semanticLabelArray(input["removeLabels"])
            guard !parsedAddLabels.isEmpty || !parsedRemoveLabels.isEmpty,
                  Set(parsedAddLabels.map(\.id)).isDisjoint(with: Set(parsedRemoveLabels.map(\.id)))
            else { throw DecodingError.invalid }
            parsed = (.setLabels(
                shared,
                mailbox: try mailbox(),
                rawID: try rawID(),
                addLabels: parsedAddLabels,
                removeLabels: parsedRemoveLabels
            ), 0)
        case .move:
            guard exact(["mailbox", "rawID", "destination"]),
                  let value = input["destination"] as? String, !value.isEmpty, value.utf8.count <= 512
            else { throw DecodingError.invalid }
            parsed = (.move(shared, mailbox: try mailbox(), rawID: try rawID(), destination: value), 0)
        case .delete:
            guard exact(["mailbox", "rawID"]) else { throw DecodingError.invalid }
            parsed = (.delete(shared, mailbox: try mailbox(), rawID: try rawID()), 0)
        case .append:
            guard exact(["mailbox", "destination", "flags", "messageID", "appendPurpose", "appendAttempts"]),
                  let parsedFlags = input["flags"] as? [String], validFlags(parsedFlags),
                  let parsedMessageID = input["messageID"] as? String, validMessageID(parsedMessageID),
                  let purpose = input["appendPurpose"] as? String, ["draft", "sent_copy"].contains(purpose),
                  let attempts = input["appendAttempts"] as? Int, (1 ... 2).contains(attempts)
            else { throw DecodingError.invalid }
            let parsedDestination: String?
            if input["destination"] is NSNull {
                parsedDestination = nil
            } else if let value = input["destination"] as? String, !value.isEmpty, value.utf8.count <= 512 {
                parsedDestination = value
            } else {
                throw DecodingError.invalid
            }
            parsed = (.append(
                shared,
                mailbox: try mailbox(),
                destination: parsedDestination,
                flags: parsedFlags,
                messageID: parsedMessageID,
                appendPurpose: purpose,
                appendAttempts: attempts
            ), attempts)
        case .fetchPart:
            guard exact(["mailbox", "rawID", "path", "pageSize"]),
                  let value = input["path"] as? String, canonicalPartPath(value)
            else { throw DecodingError.invalid }
            parsed = (.fetchPart(
                shared,
                mailbox: try mailbox(),
                rawID: try rawID(),
                path: value,
                pageSize: try pageSize()
            ), 0)
        }
        return .init(
            id: id,
            input: parsed.input,
            expected: .init(result: try semanticResult(expected, action: action, appendAttempts: parsed.appendAttempts))
        )
    }

    private static func semanticResult(
        _ expected: [String: Any],
        action: ProviderFixtureSemanticOperation.Action,
        appendAttempts: Int
    ) throws -> ProviderFixtureSemanticOperation.Result {
        guard Set(expected.keys) == ["result"],
              let rawResult = expected["result"] as? [String: Any],
              let kind = rawResult["kind"] as? String
        else { throw DecodingError.invalid }
        switch kind {
        case "catalog":
            guard action == .discover,
                  Set(rawResult.keys) == ["kind", "catalog"],
                  let rawCatalog = rawResult["catalog"] as? [String: Any],
                  Set(rawCatalog.keys) == ["mailboxes"],
                  let rawMailboxes = rawCatalog["mailboxes"] as? [[String: Any]],
                  rawMailboxes.count <= 4_096
            else { throw DecodingError.invalid }
            return .catalog(.init(mailboxes: try rawMailboxes.map(semanticMailbox)))
        case "page":
            guard action == .synchronize,
                  Set(rawResult.keys) == ["kind", "page"],
                  let rawPage = rawResult["page"] as? [String: Any]
            else { throw DecodingError.invalid }
            return .page(try semanticPage(rawPage))
        case "part":
            guard action == .fetchPart,
                  Set(rawResult.keys) == ["kind", "part"],
                  let rawPart = rawResult["part"] as? [String: Any]
            else { throw DecodingError.invalid }
            return .part(try semanticPart(rawPart))
        case "wait":
            guard action == .wait,
                  Set(rawResult.keys) == ["kind", "wait"],
                  let rawWait = rawResult["wait"] as? [String: Any]
            else { throw DecodingError.invalid }
            return .wait(try semanticWait(rawWait))
        case "mutation":
            guard [.setFlags, .setLabels, .move, .delete, .append].contains(action),
                  Set(rawResult.keys) == ["kind", "mutation"],
                  let rawMutation = rawResult["mutation"] as? [String: Any],
                  Set(rawMutation.keys) == ["outcomes"],
                  let rawOutcomes = rawMutation["outcomes"] as? [[String: Any]],
                  !rawOutcomes.isEmpty,
                  (action == .append ? rawOutcomes.count == appendAttempts : rawOutcomes.count == 1)
            else { throw DecodingError.invalid }
            let outcomes = try rawOutcomes.map(semanticOutcome)
            guard outcomes.allSatisfy({ $0.sentCopy == "not_applicable" }) else {
                throw DecodingError.invalid
            }
            return .mutation(.init(outcomes: outcomes))
        case "error":
            guard Set(rawResult.keys) == ["kind", "error"],
                  let rawError = rawResult["error"] as? [String: Any]
            else { throw DecodingError.invalid }
            return .error(try semanticError(rawError))
        default:
            throw DecodingError.invalid
        }
    }

    private static func semanticMailbox(
        _ raw: [String: Any]
    ) throws -> ProviderFixtureSemanticOperation.Peer.Mailbox {
        guard Set(raw.keys) == ["id", "displayName", "selectable", "specialUse"],
              let id = raw["id"] as? String, !id.isEmpty, id.utf8.count <= 512,
              let displayName = raw["displayName"] as? String, displayName.utf8.count <= 512,
              let selectable = raw["selectable"] as? Bool,
              let specialUse = raw["specialUse"] as? String,
              ["none", "inbox", "sent", "drafts", "trash", "junk", "archive", "all"].contains(specialUse)
        else { throw DecodingError.invalid }
        return .init(id: id, displayName: displayName, selectable: selectable, specialUse: specialUse)
    }

    private static func semanticMailboxRef(
        _ raw: Any?
    ) throws -> ProviderFixtureSemanticOperation.MailboxRef {
        guard let raw = raw as? [String: Any],
              Set(raw.keys) == ["id", "epoch"],
              let id = raw["id"] as? String, !id.isEmpty, id.utf8.count <= 512,
              let epoch = raw["epoch"] as? Int, epoch > 0
        else { throw DecodingError.invalid }
        return .init(id: id, epoch: epoch)
    }

    private static func semanticMessageRef(
        _ raw: Any?
    ) throws -> ProviderFixtureSemanticOperation.MessageRef {
        guard let raw = raw as? [String: Any],
              Set(raw.keys) == ["mailbox", "rawID"],
              let rawID = raw["rawID"] as? String,
              canonicalPositiveInteger(rawID)
        else { throw DecodingError.invalid }
        return .init(mailbox: try semanticMailboxRef(raw["mailbox"]), rawID: rawID)
    }

    private static func semanticPage(
        _ raw: [String: Any]
    ) throws -> ProviderFixtureSemanticOperation.Page {
        guard Set(raw.keys) == ["mailbox", "changes", "nextCursor", "hasMore", "observedUIDValidity", "epochReset"],
              let rawChanges = raw["changes"] as? [[String: Any]], rawChanges.count <= 500,
              let hasMore = raw["hasMore"] as? Bool,
              let observedUIDValidity = raw["observedUIDValidity"] as? Int, observedUIDValidity > 0,
              let epochReset = raw["epochReset"] as? Bool
        else { throw DecodingError.invalid }
        let nextCursor: ProviderFixtureSemanticOperation.Cursor?
        if raw["nextCursor"] is NSNull {
            nextCursor = nil
        } else {
            nextCursor = try semanticCursor(raw["nextCursor"])
        }
        guard (epochReset && rawChanges.isEmpty && nextCursor == nil && !hasMore)
                || (!epochReset && nextCursor != nil)
        else { throw DecodingError.invalid }
        return .init(
            mailbox: try semanticMailboxRef(raw["mailbox"]),
            changes: try rawChanges.map(semanticChange),
            nextCursor: nextCursor,
            hasMore: hasMore,
            observedUIDValidity: observedUIDValidity,
            epochReset: epochReset
        )
    }

    private static func semanticChange(
        _ raw: [String: Any]
    ) throws -> ProviderFixtureSemanticOperation.Change {
        guard Set(raw.keys) == ["kind", "ref", "message"],
              let kind = raw["kind"] as? String,
              ["upsert", "membership_removed"].contains(kind)
        else { throw DecodingError.invalid }
        let message: ProviderFixtureSemanticOperation.Message?
        if raw["message"] is NSNull {
            guard kind == "membership_removed" else { throw DecodingError.invalid }
            message = nil
        } else {
            guard kind == "upsert", let rawMessage = raw["message"] as? [String: Any] else { throw DecodingError.invalid }
            message = try semanticMessage(rawMessage)
        }
        return .init(kind: kind, ref: try semanticMessageRef(raw["ref"]), message: message)
    }

    private static func semanticMessage(
        _ raw: [String: Any]
    ) throws -> ProviderFixtureSemanticOperation.Message {
        let required: Set<String> = [
            "rfcMessageID", "providerStableID", "providerThreadID", "inReplyTo", "references", "from", "sender",
            "replyTo", "to", "cc", "bcc", "subject", "receivedAt", "sentAt", "flags", "labels", "textBody", "htmlBody", "parts",
        ]
        guard Set(raw.keys) == required,
              let rfcMessageID = raw["rfcMessageID"] as? String, validMessageID(rfcMessageID),
              let providerStableID = raw["providerStableID"] as? String, providerStableID.utf8.count <= 512,
              let providerThreadID = raw["providerThreadID"] as? String, providerThreadID.utf8.count <= 512,
              let rawFrom = raw["from"] as? [[String: Any]],
              let rawReplyTo = raw["replyTo"] as? [[String: Any]],
              let rawTo = raw["to"] as? [[String: Any]],
              let rawCC = raw["cc"] as? [[String: Any]],
              let rawBCC = raw["bcc"] as? [[String: Any]],
              let subject = raw["subject"] as? String, subject.utf8.count <= 998,
              let receivedAt = raw["receivedAt"] as? String, !receivedAt.isEmpty,
              let rawFlags = raw["flags"] as? [String], rawFlags.count <= 256,
              let rawLabels = raw["labels"] as? [[String: Any]], rawLabels.count <= 4_096,
              let rawTextBody = raw["textBody"] as? [String: Any],
              let rawHTMLBody = raw["htmlBody"] as? [String: Any],
              let rawParts = raw["parts"] as? [[String: Any]], rawParts.count <= 4_096
        else { throw DecodingError.invalid }
        let sender: ProviderFixtureSemanticOperation.Address?
        if raw["sender"] is NSNull {
            sender = nil
        } else {
            guard let rawSender = raw["sender"] as? [String: Any] else { throw DecodingError.invalid }
            sender = try semanticAddress(rawSender)
        }
        let sentAt: String?
        if raw["sentAt"] is NSNull {
            sentAt = nil
        } else {
            guard let value = raw["sentAt"] as? String, !value.isEmpty else { throw DecodingError.invalid }
            sentAt = value
        }
        return .init(
            rfcMessageID: rfcMessageID,
            providerStableID: providerStableID,
            providerThreadID: providerThreadID,
            inReplyTo: try semanticStringArray(raw["inReplyTo"], maximum: 256),
            references: try semanticStringArray(raw["references"], maximum: 256),
            from: try rawFrom.map(semanticAddress),
            sender: sender,
            replyTo: try rawReplyTo.map(semanticAddress),
            to: try rawTo.map(semanticAddress),
            cc: try rawCC.map(semanticAddress),
            bcc: try rawBCC.map(semanticAddress),
            subject: subject,
            receivedAt: receivedAt,
            sentAt: sentAt,
            flags: rawFlags,
            labels: try rawLabels.map(semanticLabel),
            textBody: try semanticBody(rawTextBody),
            htmlBody: try semanticBody(rawHTMLBody),
            parts: try rawParts.map(semanticDescriptor)
        )
    }

    private static func semanticAddress(
        _ raw: [String: Any]
    ) throws -> ProviderFixtureSemanticOperation.Address {
        guard Set(raw.keys) == ["displayName", "mailbox"],
              let displayName = raw["displayName"] as? String, displayName.utf8.count <= 998,
              let mailbox = raw["mailbox"] as? String, mailbox.utf8.count <= 512
        else { throw DecodingError.invalid }
        return .init(displayName: displayName, mailbox: mailbox)
    }

    private static func semanticLabel(
        _ raw: [String: Any]
    ) throws -> ProviderFixtureSemanticOperation.Label {
        guard Set(raw.keys) == ["id", "displayName"],
              let id = raw["id"] as? String, !id.isEmpty, id.utf8.count <= 512,
              let displayName = raw["displayName"] as? String, displayName.utf8.count <= 512
        else { throw DecodingError.invalid }
        return .init(id: id, displayName: displayName)
    }

    private static func semanticLabelArray(
        _ raw: Any?
    ) throws -> [ProviderFixtureSemanticOperation.Label] {
        guard let raw else { return [] }
        guard let labels = raw as? [[String: Any]], labels.count <= 256 else {
            throw DecodingError.invalid
        }
        let result = try labels.map(semanticLabel)
        guard Set(result.map(\.id)).count == result.count else {
            throw DecodingError.invalid
        }
        return result
    }

    private static func semanticStringArray(_ raw: Any?, maximum: Int) throws -> [String] {
        guard let values = raw as? [String], values.count <= maximum,
              values.allSatisfy({ $0.utf8.count <= 998 })
        else { throw DecodingError.invalid }
        return values
    }

    private static func semanticBody(
        _ raw: [String: Any]
    ) throws -> ProviderFixtureSemanticOperation.Body {
        guard Set(raw.keys) == ["state", "value"],
              let state = raw["state"] as? String,
              ["complete", "absent", "omitted_oversized"].contains(state),
              let value = raw["value"] as? String,
              value.utf8.count <= 64 << 10,
              (state == "complete" || value.isEmpty)
        else { throw DecodingError.invalid }
        return .init(state: state, value: value)
    }

    private static func semanticDescriptor(
        _ raw: [String: Any]
    ) throws -> ProviderFixtureSemanticOperation.PartDescriptor {
        guard Set(raw.keys) == ["path", "filename", "mimeType", "disposition", "contentID", "declaredSize"],
              let path = raw["path"] as? String, canonicalPartPath(path),
              let filename = raw["filename"] as? String, filename.utf8.count <= 998,
              let mimeType = raw["mimeType"] as? String, !mimeType.isEmpty, mimeType.utf8.count <= 256,
              let disposition = raw["disposition"] as? String,
              ["attachment", "inline", "none"].contains(disposition),
              let contentID = raw["contentID"] as? String, contentID.utf8.count <= 998,
              let declaredSize = raw["declaredSize"] as? Int, declaredSize >= 0
        else { throw DecodingError.invalid }
        return .init(
            path: path,
            filename: filename,
            mimeType: mimeType,
            disposition: disposition,
            contentID: contentID,
            declaredSize: declaredSize
        )
    }

    private static func semanticCursor(
        _ raw: Any?
    ) throws -> ProviderFixtureSemanticOperation.Cursor {
        guard let raw = raw as? [String: Any],
              Set(raw.keys) == ["provider", "mailboxID", "epoch", "uidValidity", "lastUID", "scanUID"],
              let provider = raw["provider"] as? String, ["gmail", "icloud", "generic"].contains(provider),
              let mailboxID = raw["mailboxID"] as? String, !mailboxID.isEmpty, mailboxID.utf8.count <= 512,
              let epoch = raw["epoch"] as? Int, epoch > 0,
              let uidValidity = raw["uidValidity"] as? Int, uidValidity > 0,
              let lastUID = raw["lastUID"] as? Int, lastUID >= 0,
              let scanUID = raw["scanUID"] as? Int, scanUID >= 0
        else { throw DecodingError.invalid }
        return .init(provider: provider, mailboxID: mailboxID, epoch: epoch, uidValidity: uidValidity, lastUID: lastUID, scanUID: scanUID)
    }

    private static func semanticPart(
        _ raw: [String: Any]
    ) throws -> ProviderFixtureSemanticOperation.Part {
        guard Set(raw.keys) == ["ref", "descriptor", "bytesBase64", "bytesRead", "sha256", "complete"],
              let rawDescriptor = raw["descriptor"] as? [String: Any],
              let bytesBase64 = raw["bytesBase64"] as? String,
              let bytes = Data(base64Encoded: bytesBase64),
              bytes.base64EncodedString() == bytesBase64,
              let bytesRead = raw["bytesRead"] as? Int, bytesRead == bytes.count,
              let sha256 = raw["sha256"] as? String,
              sha256.count == 64, sha256.allSatisfy({ $0.isNumber || ("a" ... "f").contains($0) }),
              let complete = raw["complete"] as? Bool
        else { throw DecodingError.invalid }
        return .init(
            ref: try semanticMessageRef(raw["ref"]),
            descriptor: try semanticDescriptor(rawDescriptor),
            bytesBase64: bytesBase64,
            bytesRead: bytesRead,
            sha256: sha256,
            complete: complete
        )
    }

    private static func semanticWait(
        _ raw: [String: Any]
    ) throws -> ProviderFixtureSemanticOperation.Wait {
        guard Set(raw.keys) == ["mailbox", "kind"],
              let kind = raw["kind"] as? String,
              ["provider_change", "poll_due"].contains(kind)
        else { throw DecodingError.invalid }
        return .init(mailbox: try semanticMailboxRef(raw["mailbox"]), kind: kind)
    }

    private static func semanticOutcome(
        _ raw: [String: Any]
    ) throws -> ProviderFixtureSemanticOperation.Outcome {
        guard Set(raw.keys) == ["state", "code", "providerReference", "destinationRawID", "sentCopy"],
              let state = raw["state"] as? String,
              ["applied", "rejected", "conflicted", "delivery_uncertain"].contains(state),
              let code = raw["code"] as? String,
              ["applied", "accepted", "unsupported", "not_found", "permission_denied", "recipient_rejected", "provider_rejected", "precondition_failed", "acceptance_unknown"].contains(code),
              let providerReference = raw["providerReference"] as? String, providerReference.utf8.count <= 512,
              let destinationRawID = raw["destinationRawID"] as? String,
              destinationRawID.isEmpty || canonicalPositiveInteger(destinationRawID),
              let sentCopy = raw["sentCopy"] as? String,
              ["not_applicable", "provider_managed", "appended", "observed", "missing", "unknown"].contains(sentCopy),
              validOutcomeCombination(state: state, code: code, sentCopy: sentCopy)
        else { throw DecodingError.invalid }
        return .init(
            state: state,
            code: code,
            providerReference: providerReference,
            sentCopy: sentCopy,
            destinationRawID: destinationRawID
        )
    }

    private static func validOutcomeCombination(state: String, code: String, sentCopy: String) -> Bool {
        switch (state, code) {
        case ("applied", "applied"):
            return sentCopy == "not_applicable"
        case ("applied", "accepted"):
            return ["not_applicable", "provider_managed", "appended", "observed", "missing", "unknown"].contains(sentCopy)
        case ("rejected", "unsupported"), ("rejected", "not_found"), ("rejected", "permission_denied"),
             ("rejected", "recipient_rejected"), ("rejected", "provider_rejected"):
            return sentCopy == "not_applicable"
        case ("conflicted", "precondition_failed"):
            return sentCopy == "not_applicable"
        case ("delivery_uncertain", "acceptance_unknown"):
            return sentCopy == "unknown"
        default:
            return false
        }
    }

    private static func semanticError(
        _ raw: [String: Any]
    ) throws -> ProviderFixtureSemanticOperation.ErrorExpectation {
        guard Set(raw.keys) == ["tag", "retry", "cause"],
              let tag = raw["tag"] as? String, providerErrorTags.contains(tag),
              let retry = raw["retry"] as? String,
              ["never", "safe", "reconcile_first"].contains(retry),
              let cause = raw["cause"] as? String,
              ["", "context_canceled", "deadline_exceeded"].contains(cause)
        else { throw DecodingError.invalid }
        return .init(tag: tag, retry: retry, cause: cause)
    }

    private static func semanticPeer(_ raw: Any?) throws -> ProviderFixtureSemanticOperation.Peer {
        guard let peer = raw as? [String: Any],
              Set(peer.keys) == [
                  "capabilities", "mailboxes", "uidValidity", "idleBehavior", "appendResponses", "disconnect",
                  "catalogBehavior", "metadataBehavior", "security", "oauthBehavior",
              ],
              let capabilities = peer["capabilities"] as? [String], !capabilities.isEmpty, capabilities.count <= 64,
              Set(capabilities).count == capabilities.count,
              capabilities.allSatisfy({ !$0.isEmpty && $0 == $0.uppercased() }),
              let rawMailboxes = peer["mailboxes"] as? [[String: Any]], !rawMailboxes.isEmpty, rawMailboxes.count <= 4_096,
              let uidValidity = peer["uidValidity"] as? Int, uidValidity > 0,
              let idleBehavior = peer["idleBehavior"] as? String,
              ["changed", "renew", "poll", "disabled"].contains(idleBehavior),
              let appendResponses = peer["appendResponses"] as? [String], !appendResponses.isEmpty, appendResponses.count <= 2,
              appendResponses.allSatisfy(["append_uid", "append_without_uid"].contains),
              let disconnect = peer["disconnect"] as? String, ["none", "metadata"].contains(disconnect),
              let catalogBehavior = peer["catalogBehavior"] as? String, ["normal", "oversized"].contains(catalogBehavior),
              let metadataBehavior = peer["metadataBehavior"] as? String,
              ["normal", "oversized_gmail_labels_literal"].contains(metadataBehavior),
              let security = peer["security"] as? String,
              ["verified", "invalid_certificate", "cleartext_nonloopback"].contains(security),
              let oauthBehavior = peer["oauthBehavior"] as? String,
              ["none", "refresh_before_connect"].contains(oauthBehavior)
        else { throw DecodingError.invalid }
        var seen = Set<String>()
        let mailboxes = try rawMailboxes.map { mailbox -> ProviderFixtureSemanticOperation.Peer.Mailbox in
            let parsed = try semanticMailbox(mailbox)
            guard seen.insert(parsed.id).inserted else { throw DecodingError.invalid }
            return parsed
        }
        return .init(
            capabilities: capabilities,
            mailboxes: mailboxes,
            uidValidity: uidValidity,
            idleBehavior: idleBehavior,
            appendResponses: appendResponses,
            disconnect: disconnect,
            catalogBehavior: catalogBehavior,
            metadataBehavior: metadataBehavior,
            security: security,
            oauthBehavior: oauthBehavior
        )
    }

    private static func canonicalPositiveInteger(_ value: String) -> Bool {
        guard let number = Int(value), number > 0 else { return false }
        return String(number) == value
    }

    private static func canonicalPartPath(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512
            && value.split(separator: ".").allSatisfy { canonicalPositiveInteger(String($0)) }
    }

    private static func validOptionalString(_ value: Any?, maximum: Int) -> Bool {
        value == nil || ((value as? String).map { !$0.isEmpty && $0.utf8.count <= maximum } ?? false)
    }

    private static func validOptionalCursor(_ value: Any?) -> Bool {
        value == nil || ((value as? String).map {
            $0.utf8.count <= 512 && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        } ?? false)
    }

    private static func validOptionalMessageID(_ value: Any?) -> Bool {
        value == nil || ((value as? String).map(validMessageID) ?? false)
    }

    private static func validOptionalPositiveInteger(_ value: Any?) -> Bool {
        value == nil || ((value as? Int).map { $0 > 0 } ?? false)
    }

    private static func validFlags(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let values = value as? [String], values.count <= 256 else { return false }
        return Set(values).count == values.count
            && values.allSatisfy(["seen", "answered", "flagged", "draft", "deleted"].contains)
    }
}
