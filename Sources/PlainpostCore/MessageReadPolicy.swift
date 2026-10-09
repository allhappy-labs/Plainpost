public enum MessageReadPolicy {
    public static func validateBodyRead(actor: Actor) throws {
        guard actor.permissions.readBody else {
            throw PlainpostError.permissionDenied("Actor is not allowed to read message bodies.")
        }
    }

    public static func validateAttachmentRead(actor: Actor) throws {
        guard actor.permissions.readAttachments else {
            throw PlainpostError.permissionDenied("Actor is not allowed to read attachments.")
        }
    }
}
