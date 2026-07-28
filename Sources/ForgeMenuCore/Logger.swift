import Foundation
import os

public final class AppLogger: @unchecked Sendable {
    public static let shared = AppLogger()

    private let logger = Logger(subsystem: "dev.forgecode.menubar", category: "application")
    private let writer: RotatingLogWriter
    public let logURL: URL

    public init(fileManager: FileManager = .default, logURL: URL? = nil) {
        if let logURL {
            self.logURL = logURL
        } else {
            let logs = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/ForgeMenuBar", isDirectory: true)
            self.logURL = logs.appendingPathComponent("ForgeMenuBar.log")
        }
        self.writer = RotatingLogWriter(fileManager: fileManager, logURL: self.logURL)
    }

    public func info(_ message: String) {
        write(level: "INFO", message: message)
    }

    public func warning(_ message: String) {
        write(level: "WARN", message: message)
    }

    public func error(_ message: String) {
        write(level: "ERROR", message: message)
    }

    private func write(level: String, message: String) {
        let safe = Redactor.redact(message)
        switch level {
        case "ERROR": logger.error("\(safe, privacy: .public)")
        case "WARN": logger.warning("\(safe, privacy: .public)")
        default: logger.info("\(safe, privacy: .public)")
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        writer.append("\(timestamp) [\(level)] \(safe)\n")
    }
}
