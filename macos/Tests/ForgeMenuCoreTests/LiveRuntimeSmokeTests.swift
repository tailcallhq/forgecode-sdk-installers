import Foundation
import XCTest
@testable import ForgeMenuCore

final class LiveRuntimeSmokeTests: XCTestCase {
    private struct SmokeResult: Decodable {
        let succeeded: Bool
        let version: String?
        let architecture: String?
        let executablePath: String?
        let cachedRuntimeMatched: Bool?
        let error: String?
    }

    func testPublicFirstInstallAndCacheSmoke() throws {
        guard ProcessInfo.processInfo.environment["FORGE_LIVE_RUNTIME_SMOKE"] == "1" else {
            throw XCTSkip("Set FORGE_LIVE_RUNTIME_SMOKE=1 to exercise the real public runtime endpoint.")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-live-runtime-smoke.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let runtimeRoot = directory.appendingPathComponent("runtime", isDirectory: true)
        let resultURL = directory.appendingPathComponent("result.json")
        let helperURL = try locateSmokeHelper()
        let helperAppURL = try makeSmokeHelperApp(in: directory, executableURL: helperURL)

        // LaunchServices establishes an application responsibility context,
        // unlike a process spawned by xctest or submitted by xctest to launchd.
        // This matches the menu-bar application's production launch context.
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launch.arguments = [
            "-n", helperAppURL.path,
            "--args", runtimeRoot.path, resultURL.path
        ]
        let launchError = Pipe()
        launch.standardOutput = FileHandle.nullDevice
        launch.standardError = launchError
        try launch.run()
        launch.waitUntilExit()
        let launchDiagnostic = String(
            decoding: launchError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(launch.terminationStatus, 0, launchDiagnostic)
        guard launch.terminationStatus == 0 else { return }

        let deadline = Date().addingTimeInterval(120)
        while !FileManager.default.fileExists(atPath: resultURL.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: resultURL.path),
            "LaunchServices install/cache smoke helper did not produce a result within 120 seconds"
        )
        guard FileManager.default.fileExists(atPath: resultURL.path) else { return }

        let result = try JSONDecoder().decode(SmokeResult.self, from: Data(contentsOf: resultURL))
        guard result.succeeded else {
            XCTFail(result.error ?? "smoke helper failed without a diagnostic")
            return
        }
        XCTAssertEqual(result.version, "0.1.191")
        XCTAssertEqual(result.architecture, RuntimeArchitecture.native.rawValue)
        XCTAssertEqual(result.cachedRuntimeMatched, true)
        if let executablePath = result.executablePath {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executablePath))
        } else {
            XCTFail("smoke helper did not report the installed executable path")
        }
    }

    private func makeSmokeHelperApp(in directory: URL, executableURL: URL) throws -> URL {
        let appURL = directory.appendingPathComponent("ForgeRuntimeSmokeHelper.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        let bundledExecutable = macOSURL.appendingPathComponent("ForgeRuntimeSmokeHelper")
        try FileManager.default.copyItem(at: executableURL, to: bundledExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: bundledExecutable.path
        )
        let identifier = "dev.forgecode.runtime-smoke.\(UUID().uuidString)"
        let info: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": "ForgeRuntimeSmokeHelper",
            "CFBundleIdentifier": identifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Forge Runtime Smoke Helper",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSBackgroundOnly": true,
            "LSMinimumSystemVersion": "13.0"
        ]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plist.write(to: contentsURL.appendingPathComponent("Info.plist"), options: .atomic)

        // Give LaunchServices a sealed application identity. A loose or
        // unsealed executable does not become the responsible application for
        // Gatekeeper's launch assessment of the downloaded runtime.
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--identifier", identifier, appURL.path]
        let signError = Pipe()
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = signError
        try sign.run()
        sign.waitUntilExit()
        let diagnostic = String(
            decoding: signError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard sign.terminationStatus == 0 else {
            throw RuntimeInstallerError.processFailure("could not sign smoke helper app: \(diagnostic)")
        }
        return appURL
    }

    private func locateSmokeHelper() throws -> URL {
        let testsURL = Bundle(for: Self.self).bundleURL
        let candidates = [
            testsURL.deletingLastPathComponent().appendingPathComponent("ForgeRuntimeSmokeHelper"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/debug/ForgeRuntimeSmokeHelper")
        ]
        return try XCTUnwrap(
            candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) },
            "Build ForgeRuntimeSmokeHelper before running the live smoke test. Checked: \(candidates.map(\.path))"
        )
    }
}
