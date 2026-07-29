import Foundation

/// A strict Semantic Versioning 2.0.0 value used by the app without a remote
/// SwiftPM dependency.
public struct Version: Equatable, Comparable, CustomStringConvertible, Sendable {
    public let major: UInt64
    public let minor: UInt64
    public let patch: UInt64
    public let prereleaseIdentifiers: [String]
    public let buildMetadataIdentifiers: [String]

    public init(
        _ major: UInt64,
        _ minor: UInt64,
        _ patch: UInt64,
        prereleaseIdentifiers: [String] = [],
        buildMetadataIdentifiers: [String] = []
    ) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prereleaseIdentifiers = prereleaseIdentifiers
        self.buildMetadataIdentifiers = buildMetadataIdentifiers
    }

    fileprivate init?(_ raw: String) {
        let pattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: raw,
                range: NSRange(raw.startIndex..., in: raw)
              ),
              match.range == NSRange(raw.startIndex..., in: raw),
              let major = Self.number(at: 1, match: match, raw: raw),
              let minor = Self.number(at: 2, match: match, raw: raw),
              let patch = Self.number(at: 3, match: match, raw: raw)
        else {
            return nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prereleaseIdentifiers = Self.identifiers(at: 4, match: match, raw: raw)
        self.buildMetadataIdentifiers = Self.identifiers(at: 5, match: match, raw: raw)
    }

    public var description: String {
        var value = "\(major).\(minor).\(patch)"
        if !prereleaseIdentifiers.isEmpty {
            value += "-" + prereleaseIdentifiers.joined(separator: ".")
        }
        if !buildMetadataIdentifiers.isEmpty {
            value += "+" + buildMetadataIdentifiers.joined(separator: ".")
        }
        return value
    }

    public static func == (left: Version, right: Version) -> Bool {
        left.major == right.major &&
            left.minor == right.minor &&
            left.patch == right.patch &&
            left.prereleaseIdentifiers == right.prereleaseIdentifiers
    }

    public static func < (left: Version, right: Version) -> Bool {
        let leftCore = (left.major, left.minor, left.patch)
        let rightCore = (right.major, right.minor, right.patch)
        if leftCore != rightCore {
            return leftCore < rightCore
        }

        switch (left.prereleaseIdentifiers.isEmpty, right.prereleaseIdentifiers.isEmpty) {
        case (true, true):
            return false
        case (true, false):
            return false
        case (false, true):
            return true
        case (false, false):
            break
        }

        for (leftIdentifier, rightIdentifier) in zip(
            left.prereleaseIdentifiers,
            right.prereleaseIdentifiers
        ) {
            if leftIdentifier == rightIdentifier {
                continue
            }
            let leftNumber = UInt64(leftIdentifier)
            let rightNumber = UInt64(rightIdentifier)
            switch (leftNumber, rightNumber) {
            case let (.some(leftValue), .some(rightValue)):
                return leftValue < rightValue
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return leftIdentifier.utf8.lexicographicallyPrecedes(rightIdentifier.utf8)
            }
        }
        return left.prereleaseIdentifiers.count < right.prereleaseIdentifiers.count
    }

    private static func number(
        at index: Int,
        match: NSTextCheckingResult,
        raw: String
    ) -> UInt64? {
        guard let range = Range(match.range(at: index), in: raw) else { return nil }
        return UInt64(raw[range])
    }

    private static func identifiers(
        at index: Int,
        match: NSTextCheckingResult,
        raw: String
    ) -> [String] {
        guard let range = Range(match.range(at: index), in: raw) else { return [] }
        return raw[range].split(separator: ".").map(String.init)
    }
}

/// The app's own version, read from the bundle.
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

    /// Parse strict SemVer 2.0.0 while tolerating surrounding whitespace and a
    /// single leading `v`, as used by release tags.
    static func parse(_ raw: String) -> Version? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") { trimmed.removeFirst() }
        return Version(trimmed)
    }

    /// Whether `latest` supersedes `current`, ignoring build metadata as
    /// required by Semantic Versioning.
    public static func isUpdate(from current: Version, to latest: Version) -> Bool {
        latest > current
    }
}
