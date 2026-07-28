import XCTest
@testable import ForgeMenuCore

final class PopoverKeyCommandTests: XCTestCase {
    func testCommandQQuits() {
        XCTAssertEqual(
            PopoverKeyCommandMatcher.command(
                keyCode: 12,
                charactersIgnoringModifiers: "q",
                commandHeld: true
            ),
            .quit
        )
    }

    func testUppercaseQStillQuits() {
        // Command-Shift-Q reports an uppercase character on some layouts.
        XCTAssertEqual(
            PopoverKeyCommandMatcher.command(
                keyCode: 12,
                charactersIgnoringModifiers: "Q",
                commandHeld: true
            ),
            .quit
        )
    }

    func testEscapeDismisses() {
        XCTAssertEqual(
            PopoverKeyCommandMatcher.command(
                keyCode: PopoverKeyCommandMatcher.escapeKeyCode,
                charactersIgnoringModifiers: nil,
                commandHeld: false
            ),
            .dismiss
        )
    }

    func testQWithoutCommandIsNotAQuit() {
        // Typing "q" must never quit the app.
        XCTAssertNil(
            PopoverKeyCommandMatcher.command(
                keyCode: 12,
                charactersIgnoringModifiers: "q",
                commandHeld: false
            )
        )
    }

    func testOtherCommandShortcutsArePassedThrough() {
        for character in ["w", "r", "a", "n"] {
            XCTAssertNil(
                PopoverKeyCommandMatcher.command(
                    keyCode: 13,
                    charactersIgnoringModifiers: character,
                    commandHeld: true
                ),
                "Command-\(character) must not be swallowed by the popover"
            )
        }
    }
}
