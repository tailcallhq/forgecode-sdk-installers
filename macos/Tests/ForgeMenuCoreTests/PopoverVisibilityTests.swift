import XCTest
@testable import ForgeMenuCore

final class PopoverVisibilityTests: XCTestCase {
    func testRapidStatusButtonMouseUpTogglesDeterministically() {
        var state = PopoverVisibilityState.hidden

        let open = PopoverVisibilityReducer.reduce(state: state, event: .statusButtonMouseUp)
        XCTAssertEqual(open, .init(state: .visible, effect: .show))
        state = open.state

        let close = PopoverVisibilityReducer.reduce(state: state, event: .statusButtonMouseUp)
        XCTAssertEqual(close, .init(state: .hidden, effect: .close))
        state = close.state

        let reopen = PopoverVisibilityReducer.reduce(state: state, event: .statusButtonMouseUp)
        XCTAssertEqual(reopen, .init(state: .visible, effect: .show))
    }

    func testOutsideClickAndEscapeCloseOnlyWhenVisible() {
        XCTAssertEqual(
            PopoverVisibilityReducer.reduce(state: .visible, event: .outsideInteraction),
            .init(state: .hidden, effect: .close)
        )
        XCTAssertEqual(
            PopoverVisibilityReducer.reduce(state: .visible, event: .escape),
            .init(state: .hidden, effect: .close)
        )
        XCTAssertEqual(
            PopoverVisibilityReducer.reduce(state: .hidden, event: .outsideInteraction),
            .init(state: .hidden, effect: .none)
        )
    }

    func testInsidePopoverAndActionsMenuInteractionsRemainVisible() {
        XCTAssertEqual(
            PopoverVisibilityReducer.reduce(state: .visible, event: .insideInteraction),
            .init(state: .visible, effect: .none)
        )
    }

    func testPopoverDidCloseSynchronizesStateWithoutSecondCloseEffect() {
        XCTAssertEqual(
            PopoverVisibilityReducer.reduce(state: .visible, event: .popoverDidClose),
            .init(state: .hidden, effect: .none)
        )
        XCTAssertEqual(
            PopoverVisibilityReducer.reduce(state: .hidden, event: .popoverDidClose),
            .init(state: .hidden, effect: .none)
        )
    }
}
