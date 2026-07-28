public enum PopoverVisibilityState: Equatable, Sendable {
    case hidden
    case visible
}

public enum PopoverVisibilityEvent: Equatable, Sendable {
    case statusButtonMouseUp
    case insideInteraction
    case outsideInteraction
    case escape
    case popoverDidClose
}

public enum PopoverVisibilityEffect: Equatable, Sendable {
    case none
    case show
    case close
}

public struct PopoverVisibilityTransition: Equatable, Sendable {
    public let state: PopoverVisibilityState
    public let effect: PopoverVisibilityEffect

    public init(state: PopoverVisibilityState, effect: PopoverVisibilityEffect) {
        self.state = state
        self.effect = effect
    }
}

public enum PopoverVisibilityReducer {
    public static func reduce(
        state: PopoverVisibilityState,
        event: PopoverVisibilityEvent
    ) -> PopoverVisibilityTransition {
        switch (state, event) {
        case (.hidden, .statusButtonMouseUp):
            return PopoverVisibilityTransition(state: .visible, effect: .show)
        case (.visible, .statusButtonMouseUp),
             (.visible, .outsideInteraction),
             (.visible, .escape):
            return PopoverVisibilityTransition(state: .hidden, effect: .close)
        case (_, .popoverDidClose):
            return PopoverVisibilityTransition(state: .hidden, effect: .none)
        case (_, .insideInteraction),
             (.hidden, .outsideInteraction),
             (.hidden, .escape):
            return PopoverVisibilityTransition(state: state, effect: .none)
        }
    }
}
