import Darwin
import Foundation
import Security

public protocol RuntimeExecutableValidating: Sendable {
    func validate(executableURL: URL, expectedArchitecture: RuntimeArchitecture) throws
}

public protocol RuntimeCodeSignatureInspecting: Sendable {
    func inspectSignature(of executableURL: URL) throws -> RuntimeCodeSignatureInspection
}

public extension RuntimeCodeSignatureInspecting {
    func signatureClass(of executableURL: URL) throws -> RuntimeCodeSignatureClass {
        try inspectSignature(of: executableURL).signatureClass
    }
}

public protocol RuntimeExecutableVersionIdentityInspecting: Sendable {
    func inspectVersionIdentity(
        of executableURL: URL,
        expectedVersion: RuntimeReleaseVersion,
        expectedIdentity: RuntimeExecutableIdentity
    ) throws -> RuntimeExecutableVersionIdentity
}

public struct Forge3MachOVersionIdentityInspector: RuntimeExecutableVersionIdentityInspecting {
    // Rust clap places the executable name, version, and about text in one
    // immutable metadata record. The current public forge3 artifact contains
    // exactly one copy of this prefix followed immediately by its strict semver
    // and this suffix. Ambiguous or changed metadata fails closed.
    static let metadataPrefix = Data(
        "prettyforge3log_formatthe following required argument was not provided: log_formatCliLOG_FORMATLog output format (logs are always written to stderr)log-format".utf8
    )
    static let metadataSuffix = Data("Agent SDK server ".utf8)
    static let updateMetadataSuffix = Data(
        "FORGE_UPDATE_MANIFEST_URLhttps://install.forgecode.dev/server/releases/latest.jsonFORGE_UPDATE_INSTALLER_URLhttps://install.forgecode.dev/serverFORGE_UPDATE_CURRENT_VERSION".utf8
    )
    private static let maximumVersionBytes = 64

    public init() {}

    public func inspectVersionIdentity(
        of executableURL: URL,
        expectedVersion: RuntimeReleaseVersion,
        expectedIdentity: RuntimeExecutableIdentity
    ) throws -> RuntimeExecutableVersionIdentity {
        let descriptor = open(executableURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw RuntimeInstallerError.invalidExecutableVersionIdentity(
                "could not safely open the validated executable"
            )
        }
        defer { close(descriptor) }

        let before = try Self.validatePinnedDescriptor(
            descriptor,
            expectedIdentity: expectedIdentity
        )
        guard expectedIdentity.size <= Int64(Int.max) else {
            throw RuntimeInstallerError.invalidExecutableVersionIdentity("executable is too large to inspect")
        }
        let bytes = try Self.readExactly(
            descriptor,
            count: Int(expectedIdentity.size),
            path: executableURL.path
        )
        let hash = try RuntimeSHA256.hexDigest(
            ofDescriptor: descriptor,
            path: executableURL.path
        )
        let after = try Self.validatePinnedDescriptor(
            descriptor,
            expectedIdentity: expectedIdentity
        )
        guard Self.stable(before, after), hash == expectedIdentity.sha256 else {
            throw RuntimeInstallerError.invalidExecutableVersionIdentity(
                "executable identity or checksum changed during non-executing inspection"
            )
        }

        let commandVersion = try Self.parseCommandMetadataVersion(bytes)
        let updateVersion = try Self.parseUpdateMetadataVersion(bytes)
        guard commandVersion == updateVersion else {
            throw RuntimeInstallerError.invalidExecutableVersionIdentity(
                "compiled forge3 command and update identities disagree"
            )
        }
        guard commandVersion == expectedVersion else {
            throw RuntimeInstallerError.executableVersionIdentityMismatch(
                expected: expectedVersion,
                actual: commandVersion
            )
        }
        return RuntimeExecutableVersionIdentity(version: commandVersion)
    }

    private static func parseCommandMetadataVersion(_ bytes: Data) throws -> RuntimeReleaseVersion {
        let prefixMatches = bytes.allRanges(of: metadataPrefix)
        guard prefixMatches.count == 1, let prefixRange = prefixMatches.first else {
            throw RuntimeInstallerError.invalidExecutableVersionIdentity(
                prefixMatches.isEmpty
                    ? "required forge3 command version metadata is missing"
                    : "forge3 command version metadata is ambiguous"
            )
        }
        let versionStart = prefixRange.upperBound
        let searchEnd = min(bytes.count, versionStart + maximumVersionBytes + metadataSuffix.count)
        guard versionStart < searchEnd,
              let suffixRange = bytes.range(
                of: metadataSuffix,
                options: [],
                in: versionStart..<searchEnd
              ),
              suffixRange.lowerBound > versionStart
        else {
            throw RuntimeInstallerError.invalidExecutableVersionIdentity(
                "forge3 command version metadata is malformed"
            )
        }
        return try parseStrictVersion(
            bytes[versionStart..<suffixRange.lowerBound],
            label: "command"
        )
    }

    private static func parseUpdateMetadataVersion(_ bytes: Data) throws -> RuntimeReleaseVersion {
        let suffixMatches = bytes.allRanges(of: updateMetadataSuffix)
        guard suffixMatches.count == 1, let suffixRange = suffixMatches.first else {
            throw RuntimeInstallerError.invalidExecutableVersionIdentity(
                suffixMatches.isEmpty
                    ? "required forge3 update version metadata is missing"
                    : "forge3 update version metadata is ambiguous"
            )
        }
        var versionStart = suffixRange.lowerBound
        var count = 0
        while versionStart > bytes.startIndex,
              count < maximumVersionBytes,
              isVersionByte(bytes[versionStart - 1]) {
            versionStart -= 1
            count += 1
        }
        guard versionStart < suffixRange.lowerBound,
              !(versionStart > bytes.startIndex && isVersionByte(bytes[versionStart - 1]))
        else {
            throw RuntimeInstallerError.invalidExecutableVersionIdentity(
                "forge3 update version metadata is malformed"
            )
        }
        return try parseStrictVersion(
            bytes[versionStart..<suffixRange.lowerBound],
            label: "update"
        )
    }

    private static func parseStrictVersion(
        _ bytes: Data.SubSequence,
        label: String
    ) throws -> RuntimeReleaseVersion {
        guard bytes.count <= maximumVersionBytes,
              let text = String(data: Data(bytes), encoding: .utf8),
              text.utf8.allSatisfy({ $0 < 0x80 }),
              let version = RuntimeReleaseVersion(rawValue: text)
        else {
            throw RuntimeInstallerError.invalidExecutableVersionIdentity(
                "embedded forge3 \(label) version is not an exact three-component version"
            )
        }
        return version
    }

    private static func isVersionByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || byte == 0x2e
    }

    private static func validatePinnedDescriptor(
        _ descriptor: Int32,
        expectedIdentity: RuntimeExecutableIdentity
    ) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_mode & 0o022 == 0,
              info.st_size == expectedIdentity.size,
              UInt64(info.st_dev) == expectedIdentity.device,
              UInt64(info.st_ino) == expectedIdentity.inode
        else {
            throw RuntimeInstallerError.invalidExecutableVersionIdentity(
                "executable is not the expected private single-link user-owned vnode"
            )
        }
        return info
    }

    private static func readExactly(_ descriptor: Int32, count: Int, path: String) throws -> Data {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw RuntimeFilesystemError.posix(errno, operation: "seek executable version metadata", path: path)
        }
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let readCount = data.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw RuntimeFilesystemError.posix(errno, operation: "read executable version metadata", path: path)
            }
            guard readCount > 0 else {
                throw RuntimeInstallerError.invalidExecutableVersionIdentity(
                    "executable was truncated during non-executing inspection"
                )
            }
            offset += readCount
        }
        var trailingByte: UInt8 = 0
        let trailingCount = read(descriptor, &trailingByte, 1)
        guard trailingCount == 0 else {
            throw RuntimeInstallerError.invalidExecutableVersionIdentity(
                "executable grew during non-executing inspection"
            )
        }
        return data
    }

    private static func stable(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

public struct SecurityRuntimeDeveloperIDRequirementEvaluator: RuntimeDeveloperIDRequirementEvaluating {
    public init() {}

    public func satisfiesDeveloperIDApplicationRequirement(
        executableURL: URL,
        expectedTeamIdentifier: String?
    ) throws -> Bool {
        var staticCode: SecStaticCode?
        let createCodeStatus = SecStaticCodeCreateWithPath(executableURL as CFURL, [], &staticCode)
        guard createCodeStatus == errSecSuccess, let staticCode else {
            throw RuntimeInstallerError.developerIDAuthenticationFailed(
                "could not create static code for Developer ID requirement evaluation (OSStatus \(createCodeStatus))"
            )
        }

        let requirementText = try Self.requirementText(expectedTeamIdentifier: expectedTeamIdentifier)
        var requirement: SecRequirement?
        let createRequirementStatus = SecRequirementCreateWithString(
            requirementText as CFString,
            [],
            &requirement
        )
        guard createRequirementStatus == errSecSuccess, let requirement else {
            throw RuntimeInstallerError.developerIDAuthenticationFailed(
                "could not create the Apple Developer ID Application requirement (OSStatus \(createRequirementStatus))"
            )
        }

        let checkStatus = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: UInt32(kSecCSStrictValidate)),
            requirement
        )
        if checkStatus == errSecSuccess { return true }
        if checkStatus == errSecCSReqFailed { return false }
        throw RuntimeInstallerError.developerIDAuthenticationFailed(
            "could not evaluate the Apple Developer ID Application requirement (OSStatus \(checkStatus))"
        )
    }

    static func requirementText(expectedTeamIdentifier: String?) throws -> String {
        var requirement = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        if let expectedTeamIdentifier {
            guard expectedTeamIdentifier.count == 10,
                  expectedTeamIdentifier.utf8.allSatisfy({
                      ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x30 && $0 <= 0x39)
                  })
            else {
                throw RuntimeInstallerError.developerIDAuthenticationFailed(
                    "the configured Developer ID Team Identifier is not exactly 10 uppercase ASCII letters or digits"
                )
            }
            requirement += " and certificate leaf[subject.OU] = \"\(expectedTeamIdentifier)\""
        }
        return requirement
    }
}

public struct UnavailableRuntimeDeveloperIDRequirementEvaluator: RuntimeDeveloperIDRequirementEvaluating {
    public init() {}

    public func satisfiesDeveloperIDApplicationRequirement(
        executableURL: URL,
        expectedTeamIdentifier: String?
    ) throws -> Bool {
        throw RuntimeInstallerError.developerIDAuthenticationFailed(
            "Developer ID requirement evaluation is unavailable"
        )
    }
}

public struct UnsignedRuntimeCodeSignatureInspector: RuntimeCodeSignatureInspecting {
    public init() {}

    public func inspectSignature(of executableURL: URL) throws -> RuntimeCodeSignatureInspection {
        RuntimeCodeSignatureInspection(signatureClass: .unsigned)
    }
}

public struct MachORuntimeValidator: RuntimeExecutableValidating, RuntimeCodeSignatureInspecting {
    private static let mhMagic64: UInt32 = 0xfeedfacf
    private static let mhCigam64: UInt32 = 0xcffaedfe
    private static let mhExecute: UInt32 = 0x2
    private static let cpuTypeX86_64: UInt32 = 0x01000007
    private static let cpuTypeArm64: UInt32 = 0x0100000c
    private static let lcSegment64: UInt32 = 0x19
    private static let lcMain: UInt32 = 0x80000028
    private static let lcCodeSignature: UInt32 = 0x1d

    private let processRunner: any RuntimeProcessRunning
    private let codeSignTimeout: TimeInterval
    private let codeSignOutputBytes: Int
    private let developerIDRequirementEvaluator: any RuntimeDeveloperIDRequirementEvaluating

    public init(
        processRunner: any RuntimeProcessRunning = POSIXRuntimeProcessRunner(),
        codeSignTimeout: TimeInterval = 5,
        codeSignOutputBytes: Int = 4_096,
        developerIDRequirementEvaluator: any RuntimeDeveloperIDRequirementEvaluating = SecurityRuntimeDeveloperIDRequirementEvaluator()
    ) {
        self.processRunner = processRunner
        self.codeSignTimeout = codeSignTimeout
        self.codeSignOutputBytes = codeSignOutputBytes
        self.developerIDRequirementEvaluator = developerIDRequirementEvaluator
    }

    public func inspectSignature(of executableURL: URL) throws -> RuntimeCodeSignatureInspection {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(executableURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw RuntimeInstallerError.invalidMachO("could not inspect code signature (OSStatus \(createStatus))")
        }
        var signingInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &signingInformation
        )
        guard informationStatus == errSecSuccess,
              let information = signingInformation as? [CFString: Any]
        else {
            throw RuntimeInstallerError.invalidMachO(
                "could not read code-signature information (OSStatus \(informationStatus))"
            )
        }

        let flags = (information[kSecCodeInfoFlags] as? NSNumber)?.uint32Value ?? 0
        let teamIdentifier = information[kSecCodeInfoTeamIdentifier] as? String
        let certificates = information[kSecCodeInfoCertificates] as? [SecCertificate] ?? []
        let signingIdentity = certificates.first.flatMap {
            SecCertificateCopySubjectSummary($0) as String?
        }
        let signatureClass = try classifySignature(
            flags: flags,
            hasCertificates: !certificates.isEmpty,
            executableURL: executableURL
        )
        return RuntimeCodeSignatureInspection(
            signatureClass: signatureClass,
            teamIdentifier: teamIdentifier,
            signingIdentity: signingIdentity
        )
    }

    func classifySignature(
        flags: UInt32,
        hasCertificates: Bool,
        executableURL: URL
    ) throws -> RuntimeCodeSignatureClass {
        if flags & 0x2 != 0 { return .adHoc } // CS_ADHOC.
        guard hasCertificates else { return .unsigned }
        return try developerIDRequirementEvaluator.satisfiesDeveloperIDApplicationRequirement(
            executableURL: executableURL,
            expectedTeamIdentifier: nil
        ) ? .developerID : .otherSigned
    }

    public func validate(executableURL: URL, expectedArchitecture: RuntimeArchitecture) throws {
        var info = stat()
        guard lstat(executableURL.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG
        else { throw RuntimeInstallerError.invalidMachO("not a regular file") }
        guard info.st_size >= 32, info.st_size <= Int64(Int.max) else {
            throw RuntimeInstallerError.invalidMachO("file has an invalid size")
        }
        let data = try Data(contentsOf: executableURL, options: [.mappedIfSafe])
        guard data.count == Int(info.st_size), data.count >= 32 else {
            throw RuntimeInstallerError.invalidMachO("file changed or is truncated")
        }

        let magic = data.uint32(at: 0, littleEndian: true)
        let littleEndian: Bool
        switch magic {
        case Self.mhMagic64: littleEndian = true
        case Self.mhCigam64: littleEndian = false
        default: throw RuntimeInstallerError.invalidMachO("unexpected magic 0x\(String(magic, radix: 16))")
        }
        let cpuType = data.uint32(at: 4, littleEndian: littleEndian)
        let fileType = data.uint32(at: 12, littleEndian: littleEndian)
        guard fileType == Self.mhExecute else {
            throw RuntimeInstallerError.invalidMachO("Mach-O file type is not executable")
        }
        let expectedCPU = expectedArchitecture == .arm64 ? Self.cpuTypeArm64 : Self.cpuTypeX86_64
        guard cpuType == expectedCPU else {
            let actual: String
            switch cpuType {
            case Self.cpuTypeArm64: actual = RuntimeArchitecture.arm64.rawValue
            case Self.cpuTypeX86_64: actual = RuntimeArchitecture.x86_64.rawValue
            default: actual = "cpu-0x\(String(cpuType, radix: 16))"
            }
            throw RuntimeInstallerError.wrongArchitecture(expected: expectedArchitecture, actual: actual)
        }

        let commandCount = Int(data.uint32(at: 16, littleEndian: littleEndian))
        let commandsSize = Int(data.uint32(at: 20, littleEndian: littleEndian))
        guard commandCount > 0,
              commandsSize >= commandCount * 8,
              32 <= data.count,
              commandsSize <= data.count - 32
        else { throw RuntimeInstallerError.invalidMachO("load-command table is incoherent") }

        var offset = 32
        let commandsEnd = 32 + commandsSize
        var sawExecutableSegment = false
        var sawEntryPoint = false
        var codeSignature: (offset: Int, size: Int)?
        for _ in 0..<commandCount {
            guard offset <= commandsEnd - 8 else {
                throw RuntimeInstallerError.invalidMachO("truncated load command")
            }
            let command = data.uint32(at: offset, littleEndian: littleEndian)
            let commandSize = Int(data.uint32(at: offset + 4, littleEndian: littleEndian))
            guard commandSize >= 8,
                  commandSize % 8 == 0,
                  commandSize <= commandsEnd - offset
            else { throw RuntimeInstallerError.invalidMachO("invalid load-command size") }

            switch command {
            case Self.lcSegment64:
                guard commandSize >= 72 else { throw RuntimeInstallerError.invalidMachO("truncated LC_SEGMENT_64") }
                let fileOffset = data.uint64(at: offset + 40, littleEndian: littleEndian)
                let fileSize = data.uint64(at: offset + 48, littleEndian: littleEndian)
                let initProtection = data.uint32(at: offset + 60, littleEndian: littleEndian)
                guard fileOffset <= UInt64(data.count), fileSize <= UInt64(data.count) - fileOffset else {
                    throw RuntimeInstallerError.invalidMachO("segment lies outside the file")
                }
                if fileSize > 0, initProtection & 0x4 != 0 { sawExecutableSegment = true }
            case Self.lcMain:
                guard commandSize >= 24 else { throw RuntimeInstallerError.invalidMachO("truncated LC_MAIN") }
                let entryOffset = data.uint64(at: offset + 8, littleEndian: littleEndian)
                guard entryOffset < UInt64(data.count) else {
                    throw RuntimeInstallerError.invalidMachO("entry point lies outside the file")
                }
                sawEntryPoint = true
            case Self.lcCodeSignature:
                guard commandSize >= 16, codeSignature == nil else {
                    throw RuntimeInstallerError.invalidMachO("invalid or duplicate code-signature command")
                }
                let signatureOffset = Int(data.uint32(at: offset + 8, littleEndian: littleEndian))
                let signatureSize = Int(data.uint32(at: offset + 12, littleEndian: littleEndian))
                guard signatureSize > 0,
                      signatureOffset >= commandsEnd,
                      signatureOffset <= data.count,
                      signatureSize <= data.count - signatureOffset
                else { throw RuntimeInstallerError.invalidMachO("code signature lies outside the file") }
                codeSignature = (signatureOffset, signatureSize)
            default:
                break
            }
            offset += commandSize
        }
        guard offset == commandsEnd else {
            throw RuntimeInstallerError.invalidMachO("load-command table size does not match commands")
        }
        guard sawExecutableSegment else {
            throw RuntimeInstallerError.invalidMachO("no executable file-backed segment")
        }
        guard sawEntryPoint else {
            throw RuntimeInstallerError.invalidMachO("missing LC_MAIN entry point")
        }
        if let codeSignature {
            try validateEmbeddedCodeSignature(data, range: codeSignature.offset..<(codeSignature.offset + codeSignature.size))
            try verifyCodeSignature(executableURL)
        }
    }

    private func validateEmbeddedCodeSignature(_ data: Data, range: Range<Int>) throws {
        guard range.count >= 12 else { throw RuntimeInstallerError.invalidMachO("truncated code signature") }
        let magic = data.uint32(at: range.lowerBound, littleEndian: false)
        let length = Int(data.uint32(at: range.lowerBound + 4, littleEndian: false))
        guard length >= 8, length <= range.count else {
            throw RuntimeInstallerError.invalidMachO("code-signature length is inconsistent")
        }
        let blobRange = range.lowerBound..<(range.lowerBound + length)
        switch magic {
        case 0xfade0cc0: // CodeDirectory
            guard blobRange.count >= 44 else { throw RuntimeInstallerError.invalidMachO("truncated CodeDirectory") }
        case 0xfade0cc1: // SuperBlob
            let count = Int(data.uint32(at: range.lowerBound + 8, littleEndian: false))
            guard count >= 1, count <= (blobRange.count - 12) / 8 else {
                throw RuntimeInstallerError.invalidMachO("invalid code-signature blob index")
            }
            for index in 0..<count {
                let blobOffset = Int(data.uint32(at: range.lowerBound + 16 + index * 8, littleEndian: false))
                guard blobOffset >= 12 + count * 8,
                      blobOffset <= blobRange.count - 8
                else { throw RuntimeInstallerError.invalidMachO("code-signature blob lies outside superblob") }
                let blobLength = Int(data.uint32(at: range.lowerBound + blobOffset + 4, littleEndian: false))
                guard blobLength >= 8, blobLength <= blobRange.count - blobOffset else {
                    throw RuntimeInstallerError.invalidMachO("invalid code-signature blob length")
                }
            }
        default:
            throw RuntimeInstallerError.invalidMachO("unexpected code-signature magic")
        }
    }

    private func verifyCodeSignature(_ executableURL: URL) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedCodeSignResult()
        Task.detached(priority: .utility) { [processRunner, codeSignTimeout, codeSignOutputBytes] in
            do {
                let processResult = try await processRunner.run(
                    executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                    arguments: ["--verify", "--strict", "--verbose=2", executableURL.path],
                    standardOutput: nil,
                    maximumStandardOutputBytes: codeSignOutputBytes,
                    timeout: codeSignTimeout,
                    terminationGracePeriod: 0.2
                )
                result.set(.success(processResult))
            } catch {
                result.set(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch result.get() {
        case .success(let processResult):
            guard !processResult.standardOutputLimitExceeded else {
                throw RuntimeInstallerError.invalidMachO("codesign output exceeded the verification limit")
            }
            guard processResult.status == 0 else {
                let diagnostic = String(decoding: processResult.stderr.prefix(codeSignOutputBytes), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw RuntimeInstallerError.invalidMachO(diagnostic.isEmpty ? "invalid code signature" : diagnostic)
            }
        case .failure(RuntimeInstallerError.processTimeout):
            throw RuntimeInstallerError.invalidMachO("code-signature verification timed out")
        case .failure(let error):
            throw RuntimeInstallerError.invalidMachO("could not verify code signature: \(error.localizedDescription)")
        case nil:
            throw RuntimeInstallerError.invalidMachO("code-signature verification returned no result")
        }
    }
}

private final class LockedCodeSignResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<RuntimeProcessResult, Error>?

    func set(_ value: Result<RuntimeProcessResult, Error>) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Result<RuntimeProcessResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private extension Data {
    func allRanges(of needle: Data) -> [Range<Int>] {
        guard !needle.isEmpty, needle.count <= count else { return [] }
        var ranges: [Range<Int>] = []
        var searchStart = startIndex
        while searchStart <= endIndex - needle.count,
              let range = range(of: needle, options: [], in: searchStart..<endIndex) {
            ranges.append(range)
            searchStart = range.lowerBound + 1
        }
        return ranges
    }

    func uint32(at offset: Int, littleEndian: Bool) -> UInt32 {
        let bytes = self[offset..<(offset + 4)]
        if littleEndian {
            return bytes.enumerated().reduce(0) { $0 | (UInt32($1.element) << UInt32($1.offset * 8)) }
        }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func uint64(at offset: Int, littleEndian: Bool) -> UInt64 {
        let bytes = self[offset..<(offset + 8)]
        if littleEndian {
            return bytes.enumerated().reduce(0) { $0 | (UInt64($1.element) << UInt64($1.offset * 8)) }
        }
        return bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
