import Foundation

/// What the popover body is showing. Commands are the default; the
/// conversation list is reached by expanding the disclosure row.
public enum PopoverMode: Equatable, Sendable {
    case commands
    case conversations
}

public enum PopoverModeEvent: Equatable, Sendable {
    case expandConversations
    case collapseConversations
    /// The popover was dismissed. Reopening always starts from the commands
    /// list so the entry point is predictable.
    case popoverDidClose
}

public enum PopoverModeReducer {
    public static func reduce(state: PopoverMode, event: PopoverModeEvent) -> PopoverMode {
        switch event {
        case .expandConversations: return .conversations
        case .collapseConversations, .popoverDidClose: return .commands
        }
    }
}
