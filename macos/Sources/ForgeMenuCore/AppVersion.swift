import Foundation
import Version

/// The app's version, read from the bundle.
///
/// This is the version of the bundled `forge3` release: the app ships 1:1 with
/// the SDK, so SDK `v0.1.191` is ForgeCode `0.1.191`. There is no independent
/// app version to drift from the server it embeds.
public enum AppVersion {
    /// `CFBundleShortVersionString` of the running bundle, or `nil` when
    /// unavailable — for example under `swift test`, where there is no app
    /// bundle to read.
    public static let current: Version? = read(from: .main)

    /// The version rendered for display, or `nil` when unavailable.
    public static var currentDescription: String? { current?.description }

    static func read(from bundle: Bundle) -> Version? {
        let raw = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return raw.flatMap(parse)
    }

    /// Parse a version string, tolerating surrounding whitespace and a leading
    /// `v` as in `v1.2.3` git tags.
    ///
    /// Tolerates the same `v` prefix and whitespace as `parse_release_version`
    /// in the SDK's `svc-update` crate, but the two are not byte-for-byte
    /// equivalent at the margins: this rejects `vv1.2.3`, and accepts a few
    /// inputs Rust's `semver` rejects (`1.02.3`, `1.2.3-`, `1.2.3+`). All three
    /// components are required, so `1.0` is `nil`.
    static func parse(_ raw: String) -> Version? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") { trimmed.removeFirst() }
        return Version(trimmed)
    }

    /// Whether `latest` supersedes `current`, for update checks.
    ///
    /// Comparison ignores build metadata, per the semver specification, so
    /// `1.2.3+1` and `1.2.3+2` are the same release.
    public static func isUpdate(from current: Version, to latest: Version) -> Bool {
        latest > current
    }
}
