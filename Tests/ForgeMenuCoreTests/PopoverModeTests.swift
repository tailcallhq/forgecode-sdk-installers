import XCTest
@testable import ForgeMenuCore

final class PopoverModeTests: XCTestCase {
    func testCommandsIsTheDefaultAndExpandingShowsConversations() {
        XCTAssertEqual(
            PopoverModeReducer.reduce(state: .commands, event: .expandConversations),
            .conversations
        )
    }

    func testCollapsingReturnsToCommands() {
        XCTAssertEqual(
            PopoverModeReducer.reduce(state: .conversations, event: .collapseConversations),
            .commands
        )
    }

    func testClosingResetsToCommandsFromEitherMode() {
        // Reopening the popover must always land on the same entry point.
        for state in [PopoverMode.commands, .conversations] {
            XCTAssertEqual(
                PopoverModeReducer.reduce(state: state, event: .popoverDidClose),
                .commands
            )
        }
    }

    func testRepeatedEventsAreIdempotent() {
        XCTAssertEqual(
            PopoverModeReducer.reduce(state: .conversations, event: .expandConversations),
            .conversations
        )
        XCTAssertEqual(
            PopoverModeReducer.reduce(state: .commands, event: .collapseConversations),
            .commands
        )
    }
}
