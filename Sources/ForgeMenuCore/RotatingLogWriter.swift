import Foundation

public final class RotatingLogWriter: @unchecked Sendable {
    private let fileManager: FileManager
    public let logURL: URL
    private let maximumBytes: UInt64
    private let retainedFiles: Int
    private let queue: DispatchQueue

    public init(
        fileManager: FileManager = .default,
        logURL: URL,
        maximumBytes: UInt64 = 2_000_000,
        retainedFiles: Int = 3
    ) {
        self.fileManager = fileManager
        self.logURL = logURL
        self.maximumBytes = maximumBytes
        self.retainedFiles = max(0, retainedFiles)
        self.queue = DispatchQueue(label: "dev.forgecode.menubar.log-writer.\(UUID().uuidString)")
    }

    public func append(_ value: String) {
        let data = Data(Redactor.redact(value).utf8)
        queue.sync {
            do {
                try fileManager.createDirectory(
                    at: logURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try rotateIfNeeded(incomingBytes: UInt64(data.count))
                if !fileManager.fileExists(atPath: logURL.path) {
                    try data.write(to: logURL, options: .atomic)
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
                } else {
                    let handle = try FileHandle(forWritingTo: logURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                }
            } catch {
                // Logging must never crash or block service supervision.
            }
        }
    }

    private func rotateIfNeeded(incomingBytes: UInt64) throws {
        guard maximumBytes > 0 else { return }
        let size = ((try? fileManager.attributesOfItem(atPath: logURL.path)[.size]) as? NSNumber)?.uint64Value ?? 0
        guard size > 0, size + incomingBytes > maximumBytes else { return }

        if retainedFiles == 0 {
            try? fileManager.removeItem(at: logURL)
            return
        }

        let oldest = rotatedURL(retainedFiles)
        try? fileManager.removeItem(at: oldest)
        if retainedFiles > 1 {
            for index in stride(from: retainedFiles - 1, through: 1, by: -1) {
                let source = rotatedURL(index)
                let destination = rotatedURL(index + 1)
                if fileManager.fileExists(atPath: source.path) {
                    try fileManager.moveItem(at: source, to: destination)
                }
            }
        }
        if fileManager.fileExists(atPath: logURL.path) {
            try fileManager.moveItem(at: logURL, to: rotatedURL(1))
        }
    }

    private func rotatedURL(_ index: Int) -> URL {
        URL(fileURLWithPath: logURL.path + ".\(index)")
    }
}
