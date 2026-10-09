import PlainpostCore

/// Previews stored before the normalizer existed still contain doubled
/// spaces; rows always display through this.
enum MailPreviewText {
    static func display(_ stored: String) -> String {
        MailPreviewNormalizer.normalized(stored)
    }
}
