import Foundation

public struct RuntimePaths: Equatable, Sendable {
    public let forgeExecutable: URL
    public let logsDirectory: URL
    public let serviceLog: URL

    public init(forgeExecutable: URL, logsDirectory: URL, serviceLog: URL) {
        self.forgeExecutable = forgeExecutable
        self.logsDirectory = logsDirectory
        self.serviceLog = serviceLog
    }

    public static func resolve(
        bundleURL: URL = Bundle.main.bundleURL,
        libraryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> RuntimePaths {
        let executable = bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("forge3")
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw ForgeCoreError.missingExecutable(executable.path)
        }

        let library = libraryDirectory ?? fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let logs = library.appendingPathComponent("Logs/ForgeMenuBar", isDirectory: true)
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)

        return RuntimePaths(
            forgeExecutable: executable,
            logsDirectory: logs,
            serviceLog: logs.appendingPathComponent("forge3.jsonl")
        )
    }
}
