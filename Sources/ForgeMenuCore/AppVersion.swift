import Foundation

/// The app's own version, read from the bundle.
///
/// Deliberately separate from the bundled `forge3` version: the app and the
/// server are released independently, so a UI-only release can ship without a
/// server bump, and a server bump does not masquerade as a new app release.
public enum AppVersion {
    /// `CFBundleShortVersionString` of the running bundle, or `nil` when
    /// unavailable — for example under `swift test`, where there is no app
    /// bundle to read.
    public static let current: String? = read(from: .main)

    static func read(from bundle: Bundle) -> String? {
        let value = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
