import Foundation

/// Keyboard commands the popover handles itself.
///
/// The app is an accessory (`LSUIElement`) and the popover window is not a
/// standard key window, so main-menu key equivalents are not reliably
/// delivered while the popover is open. These are matched explicitly instead.
public enum PopoverKeyCommand: Equatable, Sendable {
    case dismiss
    case quit
}

public enum PopoverKeyCommandMatcher {
    public static let escapeKeyCode: UInt16 = 53

    /// - Parameters:
    ///   - charactersIgnoringModifiers: `NSEvent.charactersIgnoringModifiers`.
    ///   - commandHeld: whether Command is the only modifier held.
    public static func command(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        commandHeld: Bool
    ) -> PopoverKeyCommand? {
        if keyCode == escapeKeyCode { return .dismiss }
        guard commandHeld else { return nil }
        // Compare the unmodified character so layouts that place "q"
        // elsewhere still match what the user sees on the key.
        guard charactersIgnoringModifiers?.lowercased() == "q" else { return nil }
        return .quit
    }
}
