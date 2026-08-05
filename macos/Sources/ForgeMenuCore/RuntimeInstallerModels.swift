import Darwin
import Foundation

public enum RuntimeFilesystemFailure: Equatable, Sendable {
    case permissionDenied
    case diskFull
    case readOnlyFilesystem
    case io
    case other(Int32?)
}

/// Errors surfaced by the thin shell-installer flow. The app fully trusts the
/// upstream installer script, so these describe only coarse failures the UI can
/// bucket into `RuntimeInstallationFailure`.
public enum ThinInstallerError: LocalizedError, Equatable {
    case download(String)
    case installerFailed(status: Int32)
    case missingExecutable(String)
    case filesystem(operation: String, path: String, failure: RuntimeFilesystemFailure)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .download(let message):
            return "Could not download the forge3 installer: \(message)"
        case .installerFailed(let status):
            return "The forge3 installer script exited with status \(status)."
        case .missingExecutable(let path):
            return "The forge3 installer did not produce an executable at \(path)."
        case .filesystem(let operation, let path, let failure):
            return "Could not \(operation) at \(path): \(failure.description)."
        case .cancelled:
            return "The forge3 installation was cancelled."
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

    /// Placeholder used when the runtime is installed by the shell installer,
    /// which does not report a version the app can trust. `0.0.0` sorts below
    /// every real release.
    public static let unknown = RuntimeReleaseVersion(rawValue: "0.0.0")!
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
}

public struct InstalledRuntime: Equatable, Sendable {
    public let version: RuntimeReleaseVersion
    public let architecture: RuntimeArchitecture
    public let executableURL: URL

    public init(
        version: RuntimeReleaseVersion,
        architecture: RuntimeArchitecture,
        executableURL: URL
    ) {
        self.version = version
        self.architecture = architecture
        self.executableURL = executableURL.standardizedFileURL
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
    public static func failure(for code: Int32) -> RuntimeFilesystemFailure {
        switch code {
        case EACCES, EPERM: return .permissionDenied
        case ENOSPC, EDQUOT: return .diskFull
        case EROFS: return .readOnlyFilesystem
        case EIO: return .io
        default: return .other(code)
        }
    }

    public static func failure(for error: Error) -> RuntimeFilesystemFailure {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return failure(for: Int32(nsError.code))
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return failure(for: Int32(underlying.code))
        }
        switch CocoaError.Code(rawValue: nsError.code) {
        case .fileWriteNoPermission, .fileReadNoPermission:
            return .permissionDenied
        case .fileWriteOutOfSpace:
            return .diskFull
        case .fileWriteVolumeReadOnly:
            return .readOnlyFilesystem
        default:
            return .other(nil)
        }
    }

    public static func thin(_ error: Error, operation: String, path: String) -> ThinInstallerError {
        if let thin = error as? ThinInstallerError { return thin }
        return .filesystem(operation: operation, path: path, failure: failure(for: error))
    }
}
