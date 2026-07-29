import CommonCrypto
import Darwin
import Foundation

public enum RuntimeSHA256 {
    public static func hexDigest(of data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func hexDigest(ofFile url: URL) throws -> String {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw RuntimeFilesystemError.posix(errno, operation: "open runtime file", path: url.path)
        }
        defer { close(descriptor) }
        return try hexDigest(ofDescriptor: descriptor, path: url.path)
    }

    static func hexDigest(ofDescriptor descriptor: Int32, path: String) throws -> String {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw RuntimeFilesystemError.posix(errno, operation: "seek runtime file", path: path)
        }
        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw RuntimeFilesystemError.posix(errno, operation: "read runtime file", path: path)
            }
            if count == 0 { break }
            CC_SHA256_Update(&context, buffer, CC_LONG(count))
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum RuntimeExecutableIdentityValidator {
    public static func capture(_ url: URL, expectedSHA256: String? = nil) throws -> RuntimeExecutableIdentity {
        try validatePathComponentsDoNotContainSymlinks(url)
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw RuntimeInstallerError.untrustedStoreItem("could not safely open runtime executable")
        }
        defer { close(descriptor) }
        let before = try trustedStat(descriptor, path: url.path)
        let hash = try RuntimeSHA256.hexDigest(ofDescriptor: descriptor, path: url.path)
        let after = try trustedStat(descriptor, path: url.path)
        guard stable(before, after) else {
            throw RuntimeInstallerError.untrustedStoreItem("runtime executable changed while its identity was captured")
        }
        if let expectedSHA256, hash != expectedSHA256 {
            throw RuntimeInstallerError.untrustedStoreItem("executable checksum does not match receipt")
        }
        return RuntimeExecutableIdentity(
            device: UInt64(before.st_dev),
            inode: UInt64(before.st_ino),
            size: before.st_size,
            sha256: hash
        )
    }

    public static func validate(_ url: URL, expected: RuntimeExecutableIdentity) throws {
        let actual = try capture(url, expectedSHA256: expected.sha256)
        guard actual == expected else {
            throw RuntimeInstallerError.untrustedStoreItem("runtime executable identity changed before launch")
        }
    }

    private static func trustedStat(_ descriptor: Int32, path: String) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw RuntimeFilesystemError.posix(errno, operation: "inspect runtime executable", path: path)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_mode & 0o022 == 0,
              info.st_size >= 0
        else {
            throw RuntimeInstallerError.untrustedStoreItem("runtime executable is not a private single-link regular file")
        }
        return info
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

    private static func validatePathComponentsDoNotContainSymlinks(_ url: URL) throws {
        let standardized = url.standardizedFileURL
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        var enteredUserBoundary = false
        for component in standardized.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            guard lstat(current.path, &info) == 0 else {
                throw RuntimeFilesystemError.posix(errno, operation: "inspect runtime path component", path: current.path)
            }
            if info.st_uid == geteuid() { enteredUserBoundary = true }
            if (info.st_mode & S_IFMT) == S_IFLNK, enteredUserBoundary {
                throw RuntimeInstallerError.untrustedStoreItem("runtime path contains a symbolic link at \(current.path)")
            }
        }
    }
}

public enum RuntimeChecksumSidecar {
    public static func parse(_ data: Data, expectedFilename: String) throws -> String {
        guard data.count <= 1_024,
              let text = String(data: data, encoding: .utf8),
              !text.contains("\0")
        else {
            throw RuntimeInstallerError.invalidChecksumSidecar("not a small UTF-8 text record")
        }

        var recordBytes = Array(text.utf8)
        // The public release sidecar currently ends with a blank line. Permit
        // only terminal CR/LF bytes; embedded line breaks still fail below, so
        // exactly one checksum record is accepted.
        while recordBytes.last == 0x0A || recordBytes.last == 0x0D {
            recordBytes.removeLast()
        }
        guard !recordBytes.isEmpty,
              let record = String(bytes: recordBytes, encoding: .utf8) else {
            throw RuntimeInstallerError.invalidChecksumSidecar("not valid UTF-8")
        }
        guard !record.contains("\n"), !record.contains("\r") else {
            throw RuntimeInstallerError.invalidChecksumSidecar("expected exactly one line")
        }

        let plainPrefix = "  "
        let binaryPrefix = " *"
        guard record.utf8.count == 64 + 2 + expectedFilename.utf8.count else {
            throw RuntimeInstallerError.invalidChecksumSidecar("unexpected record length")
        }
        let hashEnd = record.index(record.startIndex, offsetBy: 64)
        let hash = String(record[..<hashEnd])
        let suffix = String(record[hashEnd...])
        guard hash.count == 64, hash.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }) else {
            throw RuntimeInstallerError.invalidChecksumSidecar("checksum must be 64 lowercase hexadecimal characters")
        }
        guard suffix == plainPrefix + expectedFilename || suffix == binaryPrefix + expectedFilename else {
            throw RuntimeInstallerError.invalidChecksumSidecar("filename does not exactly match \(expectedFilename)")
        }
        return hash
    }
}
