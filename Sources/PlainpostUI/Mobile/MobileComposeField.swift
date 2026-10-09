/// A field in the iPhone Compose sheet, in the order Return walks them.
enum MobileComposeField: Hashable {
    case to, cc, bcc, subject, body

    /// Where Return goes from this field: To, then Cc and Bcc when they're shown, then Subject,
    /// then the body.
    func next(showsCcBcc: Bool) -> MobileComposeField {
        switch self {
        case .to: showsCcBcc ? .cc : .subject
        case .cc: .bcc
        case .bcc: .subject
        case .subject, .body: .body
        }
    }
}
