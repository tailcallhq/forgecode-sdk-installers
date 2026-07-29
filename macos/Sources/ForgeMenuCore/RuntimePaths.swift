import Foundation

public struct RuntimePaths: Equatable, Sendable {
    public let logsDirectory: URL
    public let serviceLog: URL

    public init(logsDirectory: URL, serviceLog: URL) {
        self.logsDirectory = logsDirectory
        self.serviceLog = serviceLog
    }

    public static func resolve(
        libraryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> RuntimePaths {
        let library = libraryDirectory ?? fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let logs = library.appendingPathComponent("Logs/ForgeMenuBar", isDirectory: true)
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)

        return RuntimePaths(
            logsDirectory: logs,
            serviceLog: logs.appendingPathComponent("forge3.jsonl")
        )
    }
}
