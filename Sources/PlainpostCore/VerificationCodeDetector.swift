import Foundation

/// Finds the one-time sign-in code in a message, so the reader can offer to
/// copy it. A candidate counts only near a code prompt ("verification code",
/// "123456 is your code", "Ваш код"), and the detector answers nil whenever
/// two different candidates qualify: no suggestion is better than the wrong one.
public enum VerificationCodeDetector {
    /// The code as it should be pasted: a split numeric code ("381 027")
    /// loses its separator.
    public static func code(subject: String, body: String) -> String? {
        let text = subject + "\n" + String(body.prefix(bodyLimit))
        let range = NSRange(text.startIndex..., in: text)
        let prompts = prompt.matches(in: text, range: range).map(\.range)
        guard !prompts.isEmpty else { return nil }

        var found = Set<String>()
        for match in candidate.matches(in: text, range: range) {
            guard
                let tokenRange = Range(match.range, in: text),
                isNearPrompt(match.range, prompts),
                !followsReferenceLabel(text[..<tokenRange.lowerBound])
            else { continue }
            let token = String(text[tokenRange])
            guard let value = codeValue(token) else { continue }
            found.insert(value)
        }
        return found.count == 1 ? found.first : nil
    }

    private static let bodyLimit = 8_000
    /// How far a code may sit after its prompt ("enter the verification
    /// code on the unrecognized device.\n\n482913") or before it
    /// ("123456 is your Instagram code").
    private static let reachAfterPrompt = 80
    private static let reachBeforePrompt = 40

    private static let prompt = try! NSRegularExpression(
        pattern: #"(?<!promo |discount |coupon |gift |voucher |referral |postal |zip |area |country |tracking |source |qr |bar |dress |error |status |product )\b(?:code|passcode|otp|2fa|one-time password|verification|verify)\b|\b(?:код|пароль)\b"#,
        options: [.caseInsensitive]
    )

    /// Four to eight digits, a 3+3 or 4+4 split code, or uppercase letters
    /// mixed with digits. Neighbouring characters rule out parts of longer
    /// numbers, decimals, prices, dates, phone numbers and "#123456".
    private static let candidate = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}#№$€£₴₽@/.\-_])(?<!\d[ \-])(?:\d{3}[ \-]\d{3}|\d{4}[ \-]\d{4}|[A-Z0-9]{4,8})(?![\p{L}\p{N}@/%\-_])(?![.,]\d)(?![ \-]\d)"#
    )

    private static let referenceLabel = try! NSRegularExpression(
        pattern: #"\b(?:order|invoice|ticket|booking|reference|ref|account|case|tracking)\W{0,3}$"#,
        options: [.caseInsensitive]
    )

    private static func isNearPrompt(_ token: NSRange, _ prompts: [NSRange]) -> Bool {
        prompts.contains { prompt in
            let promptEnd = prompt.location + prompt.length
            let tokenEnd = token.location + token.length
            if promptEnd <= token.location {
                return token.location - promptEnd <= reachAfterPrompt
            }
            return prompt.location >= tokenEnd && prompt.location - tokenEnd <= reachBeforePrompt
        }
    }

    private static func followsReferenceLabel(_ prefix: Substring) -> Bool {
        let tail = String(prefix.suffix(16))
        return referenceLabel.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) != nil
    }

    private static func codeValue(_ token: String) -> String? {
        let compact = token.filter { $0 != " " && $0 != "-" }
        guard compact.contains(where: \.isNumber) else { return nil }
        if compact.allSatisfy(\.isNumber), compact.count == 4, let year = Int(compact), (1900...2099).contains(year) {
            return nil
        }
        return compact
    }
}
