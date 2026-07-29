import Foundation
import ForgeMenuCore

private struct SmokeResult: Codable {
    let succeeded: Bool
    let version: String?
    let architecture: String?
    let executablePath: String?
    let expectedVersionOutput: String?
    let cachedRuntimeMatched: Bool?
    let error: String?
}

@main
private enum ForgeRuntimeSmokeHelper {
    static func main() async {
        guard CommandLine.arguments.count == 3 else {
            FileHandle.standardError.write(Data("usage: ForgeRuntimeSmokeHelper <runtime-root> <result-json>\n".utf8))
            exit(64)
        }

        let rootURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let resultURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let result: SmokeResult
        let exitStatus: Int32
        do {
            let installer = RuntimeInstaller(rootURL: rootURL)
            let runtime = try await installer.installLatest()
            guard FileManager.default.isExecutableFile(atPath: runtime.executableURL.path) else {
                throw RuntimeInstallerError.runtimeProbeFailed("installed runtime is not executable")
            }

            let probeResult = try await BoundedRuntimeExecutionProbe(
                processRunner: POSIXRuntimeProcessRunner(),
                timeout: 15,
                terminationGracePeriod: 1,
                maximumOutputBytes: 4_096
            ).probe(installedRuntime: runtime)
            guard probeResult == .succeeded else {
                throw RuntimeInstallerError.runtimeProbeFailed("post-install exact version probe returned \(probeResult)")
            }

            let restartedInstaller = RuntimeInstaller(rootURL: rootURL)
            let cached = try await restartedInstaller.installedCurrentRuntime()
            guard cached == runtime else {
                throw RuntimeInstallerError.runtimeProbeFailed("cold-restarted current runtime did not match the activated runtime")
            }
            try cached?.validateExecutableIdentity()
            result = SmokeResult(
                succeeded: true,
                version: runtime.version.rawValue,
                architecture: runtime.architecture.rawValue,
                executablePath: runtime.executableURL.path,
                expectedVersionOutput: "forge3 \(runtime.version.rawValue)",
                cachedRuntimeMatched: true,
                error: nil
            )
            exitStatus = 0
        } catch {
            result = SmokeResult(
                succeeded: false,
                version: nil,
                architecture: nil,
                executablePath: nil,
                expectedVersionOutput: nil,
                cachedRuntimeMatched: nil,
                error: String(describing: error)
            )
            exitStatus = 1
        }

        do {
            let data = try JSONEncoder().encode(result)
            try data.write(to: resultURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("could not write smoke result: \(error)\n".utf8))
            exit(74)
        }
        exit(exitStatus)
    }
}
