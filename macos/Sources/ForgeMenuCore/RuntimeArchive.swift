import Darwin
import Foundation

public struct RuntimeArchiveEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case regularFile
        case directory
    }

    public let path: String
    public let kind: Kind
    public let size: Int
    fileprivate let dataOffset: Int
}

public struct RuntimeArchiveInspection: Equatable, Sendable {
    public let entries: [RuntimeArchiveEntry]
    public let executableEntry: RuntimeArchiveEntry
    let tarURL: URL
}

public protocol RuntimeArchiveHandling: Sendable {
    func inspect(archiveURL: URL, temporaryDirectory: URL, limits: RuntimeInstallerLimits) async throws -> RuntimeArchiveInspection
    func extractExecutable(from inspection: RuntimeArchiveInspection, to destination: URL) throws
}

public struct SafeTarXZArchiveHandler: RuntimeArchiveHandling {
    private let processRunner: any RuntimeProcessRunning
    private let tarExecutable: URL
    private let processTimeout: TimeInterval
    private let terminationGracePeriod: TimeInterval

    public init(
        processRunner: any RuntimeProcessRunning = FoundationRuntimeProcessRunner(),
        tarExecutable: URL = URL(fileURLWithPath: "/usr/bin/tar"),
        processTimeout: TimeInterval = 60,
        terminationGracePeriod: TimeInterval = 1
    ) {
        self.processRunner = processRunner
        self.tarExecutable = tarExecutable
        self.processTimeout = processTimeout
        self.terminationGracePeriod = terminationGracePeriod
    }

    public func inspect(
        archiveURL: URL,
        temporaryDirectory: URL,
        limits: RuntimeInstallerLimits
    ) async throws -> RuntimeArchiveInspection {
        let archiveHandle: FileHandle
        do {
            archiveHandle = try FileHandle(forReadingFrom: archiveURL)
        } catch {
            throw RuntimeFilesystemError.wrapping(error, operation: "open downloaded runtime archive", path: archiveURL.path)
        }
        let magic: Data
        do {
            magic = try archiveHandle.read(upToCount: 6) ?? Data()
            try archiveHandle.close()
        } catch {
            try? archiveHandle.close()
            throw RuntimeFilesystemError.wrapping(error, operation: "read downloaded runtime archive", path: archiveURL.path)
        }
        guard magic == Data([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]) else {
            throw RuntimeInstallerError.malformedArchive("archive is not XZ-compressed data")
        }

        let tarURL = temporaryDirectory.appendingPathComponent("inspection.tar")
        let maximumTarBytes = limits.expandedArchiveBytes + (limits.archiveEntries + 4) * 1_024
        let result = try await processRunner.run(
            executable: tarExecutable,
            arguments: ["-cf", "-", "--format", "pax", "@\(archiveURL.path)"],
            standardOutput: tarURL,
            maximumStandardOutputBytes: maximumTarBytes,
            timeout: processTimeout,
            terminationGracePeriod: terminationGracePeriod
        )
        guard !result.standardOutputLimitExceeded else {
            throw RuntimeInstallerError.archiveLimitExceeded("converted archive is too large")
        }
        guard result.status == 0 else {
            let diagnostic = String(decoding: result.stderr.prefix(4_096), as: UTF8.self)
            throw RuntimeInstallerError.malformedArchive(diagnostic.isEmpty ? "tar exited with status \(result.status)" : diagnostic)
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: tarURL.path)
        } catch {
            throw RuntimeFilesystemError.wrapping(error, operation: "inspect converted runtime archive", path: tarURL.path)
        }
        let convertedSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard convertedSize <= Int64(limits.expandedArchiveBytes) + Int64(limits.archiveEntries + 4) * 1_024 else {
            throw RuntimeInstallerError.archiveLimitExceeded("converted archive is too large")
        }
        let data: Data
        do {
            data = try Data(contentsOf: tarURL, options: [.mappedIfSafe])
        } catch {
            throw RuntimeFilesystemError.wrapping(error, operation: "read converted runtime archive", path: tarURL.path)
        }
        return try Self.parseTar(data, tarURL: tarURL, limits: limits)
    }

    public func extractExecutable(from inspection: RuntimeArchiveInspection, to destination: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: inspection.tarURL, options: [.mappedIfSafe])
        } catch {
            throw RuntimeFilesystemError.wrapping(error, operation: "read inspected runtime archive", path: inspection.tarURL.path)
        }
        let entry = inspection.executableEntry
        let end = entry.dataOffset + entry.size
        guard entry.dataOffset >= 0, end <= data.count else {
            throw RuntimeInstallerError.malformedArchive("forge3 data lies outside the archive")
        }
        let descriptor = open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o700
        )
        guard descriptor >= 0 else {
            throw RuntimeFilesystemError.posix(errno, operation: "create staged runtime executable", path: destination.path)
        }
        defer { close(descriptor) }
        let executable = data[entry.dataOffset..<end]
        try executable.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw RuntimeFilesystemError.posix(errno, operation: "write staged runtime executable", path: destination.path)
                }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw RuntimeFilesystemError.posix(errno, operation: "synchronize staged runtime executable", path: destination.path)
        }
    }

    static func parseTar(_ data: Data, tarURL: URL, limits: RuntimeInstallerLimits) throws -> RuntimeArchiveInspection {
        var offset = 0
        var entries: [RuntimeArchiveEntry] = []
        var seen = Set<String>()
        var expandedBytes = 0
        var zeroBlocks = 0

        while offset + 512 <= data.count {
            let header = data.subdata(in: offset..<(offset + 512))
            if header.allSatisfy({ $0 == 0 }) {
                zeroBlocks += 1
                offset += 512
                if zeroBlocks == 2 { break }
                continue
            }
            guard zeroBlocks == 0 else {
                throw RuntimeInstallerError.malformedArchive("non-zero data after an end-of-archive block")
            }
            guard Self.hasValidChecksum(header) else {
                throw RuntimeInstallerError.malformedArchive("invalid tar header checksum")
            }
            guard entries.count < limits.archiveEntries else {
                throw RuntimeInstallerError.archiveLimitExceeded("too many entries")
            }

            let name = try Self.string(header, range: 0..<100, field: "name")
            let prefix = try Self.string(header, range: 345..<500, field: "prefix")
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            try Self.validate(path: path)
            let collisionKey = String(path.drop(while: { $0 == "/" }).dropLast(path.hasSuffix("/") ? 1 : 0))
                .precomposedStringWithCanonicalMapping
            guard seen.insert(collisionKey).inserted else {
                throw RuntimeInstallerError.unsafeArchiveEntry("duplicate path \(path)")
            }

            let size = try Self.octal(header, range: 124..<136, field: "size")
            let type = header[156]
            let kind: RuntimeArchiveEntry.Kind
            switch type {
            case 0, Character("0").asciiValue!: kind = .regularFile
            case Character("5").asciiValue!: kind = .directory
            case Character("1").asciiValue!, Character("2").asciiValue!:
                throw RuntimeInstallerError.unsafeArchiveEntry("links are not allowed: \(path)")
            default:
                throw RuntimeInstallerError.unsafeArchiveEntry("special or unsupported entry type \(type) at \(path)")
            }
            if kind == .directory && size != 0 {
                throw RuntimeInstallerError.malformedArchive("directory has data: \(path)")
            }
            guard (kind == .directory) == path.hasSuffix("/") else {
                throw RuntimeInstallerError.malformedArchive("entry type and path disagree: \(path)")
            }
            if kind == .regularFile {
                guard size <= limits.executableBytes || URL(fileURLWithPath: path).lastPathComponent != "forge3" else {
                    throw RuntimeInstallerError.archiveLimitExceeded("forge3 is too large")
                }
                guard expandedBytes <= limits.expandedArchiveBytes - size else {
                    throw RuntimeInstallerError.archiveLimitExceeded("expanded files are too large")
                }
                expandedBytes += size
            }

            let dataOffset = offset + 512
            guard dataOffset <= data.count, size <= data.count - dataOffset else {
                throw RuntimeInstallerError.malformedArchive("truncated data for \(path)")
            }
            entries.append(RuntimeArchiveEntry(path: path, kind: kind, size: size, dataOffset: dataOffset))
            let paddedSize = ((size + 511) / 512) * 512
            guard dataOffset <= Int.max - paddedSize else {
                throw RuntimeInstallerError.malformedArchive("entry size overflow")
            }
            offset = dataOffset + paddedSize
        }

        guard zeroBlocks == 2 else {
            throw RuntimeInstallerError.malformedArchive("missing end-of-archive blocks")
        }
        let trailing = data[offset...]
        guard trailing.allSatisfy({ $0 == 0 }) else {
            throw RuntimeInstallerError.malformedArchive("non-zero trailing bytes")
        }
        guard !entries.isEmpty else {
            throw RuntimeInstallerError.malformedArchive("empty archive")
        }
        let executables = entries.filter {
            $0.kind == .regularFile && URL(fileURLWithPath: $0.path).lastPathComponent == "forge3"
        }
        guard !executables.isEmpty else { throw RuntimeInstallerError.missingRuntimeExecutable }
        guard executables.count == 1 else { throw RuntimeInstallerError.duplicateRuntimeExecutable }
        return RuntimeArchiveInspection(entries: entries, executableEntry: executables[0], tarURL: tarURL)
    }

    private static func validate(path: String) throws {
        guard !path.isEmpty,
              path.utf8.count <= 1_024,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0")
        else { throw RuntimeInstallerError.unsafeArchiveEntry(path) }
        let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !normalizedPath.isEmpty else { throw RuntimeInstallerError.unsafeArchiveEntry(path) }
        let components = normalizedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RuntimeInstallerError.unsafeArchiveEntry(path)
        }
    }

    private static func string(_ header: Data, range: Range<Int>, field: String) throws -> String {
        let bytes = header[range].prefix { $0 != 0 }
        guard !bytes.contains(where: { $0 < 0x20 || $0 == 0x7f }),
              let value = String(bytes: bytes, encoding: .utf8)
        else { throw RuntimeInstallerError.malformedArchive("invalid \(field)") }
        return value
    }

    private static func octal(_ header: Data, range: Range<Int>, field: String) throws -> Int {
        let raw = header[range]
        guard raw.first.map({ $0 & 0x80 == 0 }) ?? false else {
            throw RuntimeInstallerError.malformedArchive("base-256 \(field) is not supported")
        }
        let text = String(bytes: raw, encoding: .ascii)?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0")) ?? ""
        guard !text.isEmpty,
              text.allSatisfy({ ("0"..."7").contains($0) }),
              let value = Int(text, radix: 8)
        else { throw RuntimeInstallerError.malformedArchive("invalid \(field)") }
        return value
    }

    private static func hasValidChecksum(_ header: Data) -> Bool {
        guard let stored = try? octal(header, range: 148..<156, field: "checksum") else { return false }
        var sum = 0
        for index in 0..<512 {
            sum += (148..<156).contains(index) ? 0x20 : Int(header[index])
        }
        return stored == sum
    }
}
