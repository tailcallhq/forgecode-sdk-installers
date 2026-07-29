import Darwin
import Foundation

public enum RuntimeFilesystemFailure: Equatable, Sendable {
    case permissionDenied
    case diskFull
    case readOnlyFilesystem
    case io
    case other(Int32?)
}

public enum RuntimeInstallerError: LocalizedError, Equatable {
    case invalidReleaseVersion(String)
    case unsupportedArchitecture(String)
    case invalidURL(String)
    case network(String)
    case networkTimeout
    case tooManyRedirects
    case unsafeRedirect(String)
    case invalidHTTPStatus(Int)
    case missingContentLength
    case invalidContentLength(String)
    case responseTooLarge(limit: Int64)
    case invalidManifest(String)
    case invalidChecksumSidecar(String)
    case checksumMismatch(expected: String, actual: String)
    case malformedArchive(String)
    case unsafeArchiveEntry(String)
    case archiveLimitExceeded(String)
    case missingRuntimeExecutable
    case duplicateRuntimeExecutable
    case invalidMachO(String)
    case wrongArchitecture(expected: RuntimeArchitecture, actual: String)
    case untrustedStoreItem(String)
    case processFailure(String)
    case processLaunchDenied(String)
    case processTimeout
    case developerIDAuthenticationFailed(String)
    case quarantineRemovalFailed(String)
    case filesystem(operation: String, path: String, failure: RuntimeFilesystemFailure)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidReleaseVersion(let value): return "Invalid forge3 release version: \(value)"
        case .unsupportedArchitecture(let value): return "Unsupported process architecture: \(value)"
        case .invalidURL(let value): return "Invalid forge3 release URL: \(value)"
        case .network(let message): return "Could not download forge3: \(message)"
        case .networkTimeout: return "The forge3 download timed out."
        case .tooManyRedirects: return "The forge3 download exceeded the redirect limit."
        case .unsafeRedirect(let value): return "The forge3 download attempted an unsafe redirect to \(value)."
        case .invalidHTTPStatus(let status): return "The forge3 release host returned HTTP \(status)."
        case .missingContentLength: return "The forge3 release response did not include Content-Length."
        case .invalidContentLength(let value): return "The forge3 release response had an invalid Content-Length: \(value)."
        case .responseTooLarge(let limit): return "The forge3 release response exceeded \(limit) bytes."
        case .invalidManifest(let message): return "The forge3 release manifest is invalid: \(message)"
        case .invalidChecksumSidecar(let message): return "The forge3 checksum sidecar is invalid: \(message)"
        case .checksumMismatch(let expected, let actual): return "The forge3 checksum did not match (expected \(expected), got \(actual))."
        case .malformedArchive(let message): return "The forge3 archive is malformed: \(message)"
        case .unsafeArchiveEntry(let value): return "The forge3 archive contains an unsafe entry: \(value)"
        case .archiveLimitExceeded(let message): return "The forge3 archive exceeded a safety limit: \(message)"
        case .missingRuntimeExecutable: return "The forge3 archive does not contain a forge3 executable."
        case .duplicateRuntimeExecutable: return "The forge3 archive contains more than one forge3 executable."
        case .invalidMachO(let message): return "The downloaded forge3 executable is not a valid Mach-O executable: \(message)"
        case .wrongArchitecture(let expected, let actual): return "The downloaded forge3 executable has architecture \(actual), expected \(expected.rawValue)."
        case .untrustedStoreItem(let message): return "The installed forge3 runtime is not trustworthy: \(message)"
        case .processFailure(let message): return "Could not run a forge3 installation subprocess: \(message)"
        case .processLaunchDenied(let message): return "macOS denied launching the staged forge3 executable: \(message)"
        case .processTimeout: return "A forge3 installation subprocess timed out."
        case .developerIDAuthenticationFailed(let message):
            return "The downloaded Developer ID forge3 executable could not be authenticated: \(message)"
        case .quarantineRemovalFailed(let message): return "Could not remove quarantine from the staged forge3 executable: \(message)"
        case .filesystem(let operation, let path, let failure):
            return "Could not \(operation) at \(path): \(failure.description)."
        case .cancelled: return "The forge3 installation was cancelled."
        }
    }
}

public struct RuntimeReleaseVersion: RawRepresentable, Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public let major: UInt64
    public let minor: UInt64
    public let patch: UInt64

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [UInt64] = []
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  !(part.count > 1 && part.first == "0"),
                  let number = UInt64(part)
            else { return nil }
            numbers.append(number)
        }
        self.rawValue = rawValue
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "expected an exact three-component release semver"
            )
        }
        self = parsed
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { rawValue }
    public var releaseTag: String { "v\(rawValue)" }
}

public enum RuntimeArchitecture: String, Codable, Sendable, CaseIterable {
    case arm64
    case x86_64

    public static var native: RuntimeArchitecture {
#if arch(arm64)
        return .arm64
#elseif arch(x86_64)
        return .x86_64
#else
        fatalError("forge3 does not support this process architecture")
#endif
    }

    public var artifactComponent: String {
        switch self {
        case .arm64: return "aarch64"
        case .x86_64: return "x86_64"
        }
    }

    public var archiveName: String {
        "forge3-\(artifactComponent)-apple-darwin.tar.xz"
    }
}

public enum RuntimeReleaseURLs {
    public static let origin = URL(string: "https://install.forgecode.dev")!
    public static let latestManifest = URL(string: "https://install.forgecode.dev/server/releases/latest.json")!

    public static func archive(version: RuntimeReleaseVersion, architecture: RuntimeArchitecture) -> URL {
        origin
            .appendingPathComponent("server/releases", isDirectory: true)
            .appendingPathComponent(version.releaseTag, isDirectory: true)
            .appendingPathComponent(architecture.archiveName)
    }

    public static func checksum(version: RuntimeReleaseVersion, architecture: RuntimeArchitecture) -> URL {
        archive(version: version, architecture: architecture)
            .appendingPathExtension("sha256")
    }
}

public struct RuntimeInstallerLimits: Sendable, Equatable {
    public var manifestBytes: Int64
    public var checksumBytes: Int64
    public var archiveBytes: Int64
    public var expandedArchiveBytes: Int
    public var executableBytes: Int
    public var archiveEntries: Int
    public var redirects: Int

    public init(
        manifestBytes: Int64 = 4_096,
        checksumBytes: Int64 = 1_024,
        archiveBytes: Int64 = 64 * 1_024 * 1_024,
        expandedArchiveBytes: Int = 192 * 1_024 * 1_024,
        executableBytes: Int = 128 * 1_024 * 1_024,
        archiveEntries: Int = 128,
        redirects: Int = 3
    ) {
        self.manifestBytes = manifestBytes
        self.checksumBytes = checksumBytes
        self.archiveBytes = archiveBytes
        self.expandedArchiveBytes = expandedArchiveBytes
        self.executableBytes = executableBytes
        self.archiveEntries = archiveEntries
        self.redirects = redirects
    }
}

public enum RuntimeCodeSignatureClass: Equatable, Sendable {
    case unsigned
    case adHoc
    case developerID
    case otherSigned
}

public struct RuntimeCodeSignatureInspection: Equatable, Sendable {
    public let signatureClass: RuntimeCodeSignatureClass
    public let teamIdentifier: String?
    public let signingIdentity: String?

    public init(
        signatureClass: RuntimeCodeSignatureClass,
        teamIdentifier: String? = nil,
        signingIdentity: String? = nil
    ) {
        self.signatureClass = signatureClass
        self.teamIdentifier = teamIdentifier
        self.signingIdentity = signingIdentity
    }
}

public protocol RuntimeDeveloperIDRequirementEvaluating: Sendable {
    /// Evaluates Apple's Developer ID Application requirement. When a Team ID
    /// is supplied, the requirement must also bind the leaf certificate's
    /// organizational unit to that exact identifier.
    func satisfiesDeveloperIDApplicationRequirement(
        executableURL: URL,
        expectedTeamIdentifier: String?
    ) throws -> Bool
}

public struct RuntimeDeveloperIDAuthenticationPolicy: Equatable, Sendable {
    public let expectedTeamIdentifier: String?

    public init(expectedTeamIdentifier: String? = nil) {
        self.expectedTeamIdentifier = expectedTeamIdentifier
    }

    public func authenticate(
        _ signature: RuntimeCodeSignatureInspection,
        executableURL: URL,
        requirementEvaluator: any RuntimeDeveloperIDRequirementEvaluating
    ) throws {
        guard signature.signatureClass == .developerID else { return }
        guard let expectedTeamIdentifier, !expectedTeamIdentifier.isEmpty else {
            throw RuntimeInstallerError.developerIDAuthenticationFailed(
                "no expected Developer ID Team Identifier is configured"
            )
        }
        guard let actualTeamIdentifier = signature.teamIdentifier, !actualTeamIdentifier.isEmpty else {
            throw RuntimeInstallerError.developerIDAuthenticationFailed(
                "the signature does not contain a Team Identifier"
            )
        }
        guard actualTeamIdentifier == expectedTeamIdentifier else {
            throw RuntimeInstallerError.developerIDAuthenticationFailed(
                "Team Identifier \(actualTeamIdentifier) does not match expected \(expectedTeamIdentifier)"
            )
        }
        guard try requirementEvaluator.satisfiesDeveloperIDApplicationRequirement(
            executableURL: executableURL,
            expectedTeamIdentifier: expectedTeamIdentifier
        ) else {
            throw RuntimeInstallerError.developerIDAuthenticationFailed(
                "the signature does not satisfy Apple's Developer ID Application requirement for Team Identifier \(expectedTeamIdentifier)"
            )
        }
    }
}

public enum RuntimeInstallerProgressDeliveryKind: Equatable, Sendable {
    case replay
    case publication
}

public struct RuntimeInstallerProgressDelivery: Equatable, Sendable {
    public let phase: RuntimeInstallationPhase
    public let kind: RuntimeInstallerProgressDeliveryKind

    public init(phase: RuntimeInstallationPhase, kind: RuntimeInstallerProgressDeliveryKind) {
        self.phase = phase
        self.kind = kind
    }
}

public struct RuntimePreExecutionTrustContext: Equatable, Sendable {
    public let signature: RuntimeCodeSignatureInspection
    public let hasQuarantine: Bool
    public let architecture: RuntimeArchitecture
    public let executableIdentity: RuntimeExecutableIdentity

    public init(
        signature: RuntimeCodeSignatureInspection,
        hasQuarantine: Bool,
        architecture: RuntimeArchitecture,
        executableIdentity: RuntimeExecutableIdentity
    ) {
        self.signature = signature
        self.hasQuarantine = hasQuarantine
        self.architecture = architecture
        self.executableIdentity = executableIdentity
    }

    public init(
        signatureClass: RuntimeCodeSignatureClass,
        hasQuarantine: Bool,
        architecture: RuntimeArchitecture,
        executableIdentity: RuntimeExecutableIdentity
    ) {
        self.init(
            signature: RuntimeCodeSignatureInspection(signatureClass: signatureClass),
            hasQuarantine: hasQuarantine,
            architecture: architecture,
            executableIdentity: executableIdentity
        )
    }

    public var signatureClass: RuntimeCodeSignatureClass { signature.signatureClass }
}

public enum RuntimePreExecutionTrustDecision: Equatable, Sendable {
    case preserve
    case refreshRemovingQuarantine
}

public enum RuntimeInstallerValidationEvent: Equatable, Sendable {
    case initialMachOValidated
    case initialIdentityAndHashValidated
    case initialSignatureClassInspected
    case initialQuarantineInspected
    case trustPolicyEvaluated
    case stagedVnodeRefreshed
    case postRefreshIdentityAndHashValidated
    case postRefreshMachOValidated
    case postRefreshSignatureClassInspected
    case postRefreshQuarantineValidated
}

public struct RuntimeExecutableIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let sha256: String

    public init(device: UInt64, inode: UInt64, size: Int64, sha256: String) {
        self.device = device
        self.inode = inode
        self.size = size
        self.sha256 = sha256
    }
}

public struct InstalledRuntime: Equatable, Sendable {
    public let version: RuntimeReleaseVersion
    public let architecture: RuntimeArchitecture
    public let executableURL: URL
    public let executableIdentity: RuntimeExecutableIdentity?

    public init(
        version: RuntimeReleaseVersion,
        architecture: RuntimeArchitecture,
        executableURL: URL,
        executableIdentity: RuntimeExecutableIdentity? = nil
    ) {
        self.version = version
        self.architecture = architecture
        self.executableURL = executableURL.standardizedFileURL
        self.executableIdentity = executableIdentity
    }

    /// Reopens the executable without following symlinks and verifies the exact
    /// receipt-backed vnode identity. Call immediately before handing the path
    /// to a launcher that cannot accept an already-open descriptor.
    public func validateExecutableIdentity() throws {
        guard let executableIdentity else {
            throw RuntimeInstallerError.untrustedStoreItem("runtime executable identity is unavailable")
        }
        try RuntimeExecutableIdentityValidator.validate(executableURL, expected: executableIdentity)
    }
}

extension RuntimeFilesystemFailure {
    var description: String {
        switch self {
        case .permissionDenied: return "permission denied"
        case .diskFull: return "the disk is full"
        case .readOnlyFilesystem: return "the filesystem is read-only"
        case .io: return "an I/O error occurred"
        case .other(let code):
            return code.map { String(cString: strerror($0)) } ?? "an unknown filesystem error occurred"
        }
    }
}

public enum RuntimeFilesystemError {
    public static func posix(_ code: Int32, operation: String, path: String) -> RuntimeInstallerError {
        .filesystem(operation: operation, path: path, failure: failure(for: code))
    }

    public static func wrapping(_ error: Error, operation: String, path: String) -> RuntimeInstallerError {
        if let runtimeError = error as? RuntimeInstallerError { return runtimeError }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return posix(Int32(nsError.code), operation: operation, path: path)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return posix(Int32(underlying.code), operation: operation, path: path)
        }
        switch CocoaError.Code(rawValue: nsError.code) {
        case .fileWriteNoPermission, .fileReadNoPermission:
            return .filesystem(operation: operation, path: path, failure: .permissionDenied)
        case .fileWriteOutOfSpace:
            return .filesystem(operation: operation, path: path, failure: .diskFull)
        case .fileWriteVolumeReadOnly:
            return .filesystem(operation: operation, path: path, failure: .readOnlyFilesystem)
        default:
            return .filesystem(operation: operation, path: path, failure: .other(nil))
        }
    }

    private static func failure(for code: Int32) -> RuntimeFilesystemFailure {
        switch code {
        case EACCES, EPERM: return .permissionDenied
        case ENOSPC, EDQUOT: return .diskFull
        case EROFS: return .readOnlyFilesystem
        case EIO: return .io
        default: return .other(code)
        }
    }
}
