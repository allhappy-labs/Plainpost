public enum AIUsagePolicy {
    public static func validateSummary(actor: Actor) throws {
        guard actor.permissions.useAISummary else {
            throw PlainpostError.permissionDenied("Actor is not allowed to use AI summaries.")
        }
    }

    public static func validateDraftReply(actor: Actor) throws {
        guard actor.permissions.useAIDraftReply else {
            throw PlainpostError.permissionDenied("Actor is not allowed to use AI draft replies.")
        }
    }

    public static func validateSemanticSearch(actor: Actor) throws {
        guard actor.permissions.useAISemanticSearch else {
            throw PlainpostError.permissionDenied("Actor is not allowed to use AI semantic search.")
        }
    }

    public static func validateClassification(actor: Actor) throws {
        guard actor.permissions.useAIClassification else {
            throw PlainpostError.permissionDenied("Actor is not allowed to use AI classification.")
        }
    }
}
