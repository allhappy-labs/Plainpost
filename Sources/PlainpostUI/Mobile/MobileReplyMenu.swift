import Foundation

/// Which items of a conversation's Reply menu are enabled. The menu itself always opens. Draft
/// with AI and Translate live in the ✦ pane.
struct MobileReplyMenu: Equatable {
    /// Reply, Reply All and Forward: each opens a composer that would send.
    let allowsReplies: Bool

    init(allowsMutations: Bool) {
        allowsReplies = allowsMutations
    }
}
