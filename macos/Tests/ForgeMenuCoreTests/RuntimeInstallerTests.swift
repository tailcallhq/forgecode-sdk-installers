import Darwin
import Foundation
import XCTest
@testable import ForgeMenuCore

final class RuntimeInstallerTests: XCTestCase {
    override func tearDown() {
        ScriptedURLProtocol.reset()
        super.tearDown()
    }

    func testURLSessionNetworkReportsValidatedMonotonicByteProgress() async throws {
        let url = RuntimeReleaseURLs.origin.appendingPathComponent("progress")
        ScriptedURLProtocol.install([
            url: .response(status: 200, headers: ["Content-Length": "6"], chunks: [Data("ab".utf8), Data("cdef".utf8)])
        ])
        let progress = LockedValues<(Int64, Int64)>()
        let download = try await networkClient().download(
            RuntimeDownloadRequest(url: url, maximumBytes: 16)
        ) { received, expected in
            progress.append((received, expected))
        }

        XCTAssertEqual(download.data, Data("abcdef".utf8))
        XCTAssertEqual(progress.values.first?.0, 0)
        XCTAssertEqual(progress.values.last?.0, 6)
        XCTAssertTrue(progress.values.allSatisfy { $0.1 == 6 })
        XCTAssertEqual(progress.values.map(\.0), progress.values.map(\.0).sorted())
        XCTAssertTrue(zip(progress.values, progress.values.dropFirst()).allSatisfy { $0.0.0 <= $0.1.0 })
    }

    func testURLSessionNetworkThrottlesProgressToABoundedCallbackCount() async throws {
        let url = RuntimeReleaseURLs.origin.appendingPathComponent("bounded-progress")
        let data = Data(repeating: 7, count: 10_000)
        ScriptedURLProtocol.install([
            url: .response(
                status: 200,
                headers: ["Content-Length": "\(data.count)"],
                chunks: data.map { Data([$0]) }
            )
        ])
        let progress = LockedValues<(Int64, Int64)>()
        _ = try await networkClient().download(
            RuntimeDownloadRequest(url: url, maximumBytes: 20_000)
        ) { received, expected in
            progress.append((received, expected))
        }

        XCTAssertLessThanOrEqual(progress.values.count, 102)
        XCTAssertEqual(progress.values.first?.0, 0)
        XCTAssertEqual(progress.values.last?.0, Int64(data.count))
    }

    func testURLSessionNetworkRejectsHTTPAndContentLengthFailures() async throws {
        let cases: [(String, ScriptedURLProtocol.Plan, RuntimeInstallerError)] = [
            ("http", .response(status: 503, headers: ["Content-Length": "0"], chunks: []), .invalidHTTPStatus(503)),
            ("missing", .response(status: 200, headers: [:], chunks: [Data("a".utf8)]), .missingContentLength),
            ("malformed", .response(status: 200, headers: ["Content-Length": "1x"], chunks: [Data("a".utf8)]), .invalidContentLength("1x")),
            ("oversize", .response(status: 200, headers: ["Content-Length": "9"], chunks: []), .responseTooLarge(limit: 8)),
            ("short", .response(status: 200, headers: ["Content-Length": "3"], chunks: [Data("ab".utf8)]), .invalidContentLength("declared 3, received 2"))
        ]
        for (path, plan, expected) in cases {
            ScriptedURLProtocol.reset()
            let url = RuntimeReleaseURLs.origin.appendingPathComponent(path)
            ScriptedURLProtocol.install([url: plan])
            do {
                _ = try await networkClient().download(RuntimeDownloadRequest(url: url, maximumBytes: 8))
                XCTFail("expected failure for \(path)")
            } catch let error as RuntimeInstallerError {
                XCTAssertEqual(error, expected, path)
            }
        }
    }

    func testURLSessionNetworkRejectsUnsafeAndExcessiveRedirects() async throws {
        let first = RuntimeReleaseURLs.origin.appendingPathComponent("redirect-one")
        let second = RuntimeReleaseURLs.origin.appendingPathComponent("redirect-two")
        let final = RuntimeReleaseURLs.origin.appendingPathComponent("redirect-final")
        ScriptedURLProtocol.install([
            first: .redirect(second),
            second: .redirect(final),
            final: .response(status: 200, headers: ["Content-Length": "0"], chunks: [])
        ])
        do {
            _ = try await networkClient().download(
                RuntimeDownloadRequest(url: first, maximumBytes: 8, maximumRedirects: 1)
            )
            XCTFail("expected redirect limit")
        } catch let error as RuntimeInstallerError {
            XCTAssertEqual(error, .tooManyRedirects)
        }

        ScriptedURLProtocol.reset()
        let unsafe = URL(string: "https://example.com/runtime")!
        ScriptedURLProtocol.install([first: .redirect(unsafe)])
        do {
            _ = try await networkClient().download(RuntimeDownloadRequest(url: first, maximumBytes: 8))
            XCTFail("expected unsafe redirect")
        } catch let error as RuntimeInstallerError {
            XCTAssertEqual(error, .unsafeRedirect(unsafe.absoluteString))
        }
    }

    func testURLSessionNetworkMapsTimeoutAndCancellationAndStopsTransport() async throws {
        let timeoutURL = RuntimeReleaseURLs.origin.appendingPathComponent("timeout")
        ScriptedURLProtocol.install([timeoutURL: .failure(URLError(.timedOut))])
        do {
            _ = try await networkClient().download(RuntimeDownloadRequest(url: timeoutURL, maximumBytes: 8))
            XCTFail("expected timeout")
        } catch let error as RuntimeInstallerError {
            XCTAssertEqual(error, .networkTimeout)
        }

        ScriptedURLProtocol.reset()
        let cancelURL = RuntimeReleaseURLs.origin.appendingPathComponent("cancel")
        ScriptedURLProtocol.install([cancelURL: .hold])
        let task = Task {
            try await networkClient().download(RuntimeDownloadRequest(url: cancelURL, maximumBytes: 8))
        }
        await ScriptedURLProtocol.waitUntilStarted(cancelURL)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as RuntimeInstallerError {
            XCTAssertEqual(error, .cancelled)
        }
        let transportStopped = await ScriptedURLProtocol.waitUntilStopped(cancelURL)
        XCTAssertTrue(transportStopped)
    }

    func testReleaseVersionIsExactThreeComponentSemver() {
        XCTAssertEqual(RuntimeReleaseVersion(rawValue: "0.1.190")?.rawValue, "0.1.190")
        for value in ["v0.1.190", "0.1", "0.1.190.0", "01.1.190", "0.01.190", "0.1.0190", "0.1.190-rc.1", " 0.1.190", "+0.1.190", "0.a.190"] {
            XCTAssertNil(RuntimeReleaseVersion(rawValue: value), value)
        }
    }

    func testReleaseURLsAreFixedVersionedInstallHostURLs() throws {
        let version = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "0.1.190"))
        XCTAssertEqual(
            RuntimeReleaseURLs.archive(version: version, architecture: .arm64).absoluteString,
            "https://install.forgecode.dev/server/releases/v0.1.190/forge3-aarch64-apple-darwin.tar.xz"
        )
        XCTAssertEqual(
            RuntimeReleaseURLs.checksum(version: version, architecture: .x86_64).absoluteString,
            "https://install.forgecode.dev/server/releases/v0.1.190/forge3-x86_64-apple-darwin.tar.xz.sha256"
        )
        XCTAssertEqual(RuntimeArchitecture.native.rawValue, ProcessInfo.processInfo.machineArchitectureForTest)
    }

    func testChecksumSidecarParsingIsStrict() throws {
        let filename = RuntimeArchitecture.arm64.archiveName
        let hash = String(repeating: "a", count: 64)
        XCTAssertEqual(try RuntimeChecksumSidecar.parse(Data("\(hash) *\(filename)\n".utf8), expectedFilename: filename), hash)
        XCTAssertEqual(try RuntimeChecksumSidecar.parse(Data("\(hash) *\(filename)\n\n".utf8), expectedFilename: filename), hash)
        XCTAssertEqual(try RuntimeChecksumSidecar.parse(Data("\(hash)  \(filename)\r\n".utf8), expectedFilename: filename), hash)

        for value in [
            "\(hash) *other.tar.xz\n",
            "\(hash.uppercased()) *\(filename)\n",
            "\(hash) *\(filename)\nextra\n",
            " \(hash) *\(filename)\n",
            "\(hash) *../\(filename)\n",
            "\(hash) *\(filename) "
        ] {
            XCTAssertThrowsError(try RuntimeChecksumSidecar.parse(Data(value.utf8), expectedFilename: filename), value)
        }
    }

    func testSHA256KnownVectorAndFileDigest() throws {
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(RuntimeSHA256.hexDigest(of: Data("abc".utf8)), expected)
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.url.appendingPathComponent("input")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try RuntimeSHA256.hexDigest(ofFile: file), expected)
    }

    func testMachOValidatorRequiresCoherentExecutableStructureAndArchitecture() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let validator = MachORuntimeValidator()
        let arm = directory.url.appendingPathComponent("arm")
        try macho(architecture: .arm64).write(to: arm)
        XCTAssertNoThrow(try validator.validate(executableURL: arm, expectedArchitecture: .arm64))
        XCTAssertThrowsError(try validator.validate(executableURL: arm, expectedArchitecture: .x86_64)) {
            XCTAssertEqual($0 as? RuntimeInstallerError, .wrongArchitecture(expected: .x86_64, actual: "arm64"))
        }

        let headerOnly = directory.url.appendingPathComponent("header-only")
        var syntheticHeader = macho(architecture: .arm64)
        syntheticHeader.removeSubrange(32..<syntheticHeader.count)
        try syntheticHeader.write(to: headerOnly)
        XCTAssertThrowsError(try validator.validate(executableURL: headerOnly, expectedArchitecture: .arm64))

        let badSegment = directory.url.appendingPathComponent("bad-segment")
        var incoherent = macho(architecture: .arm64)
        putUInt64(UInt64(incoherent.count + 1), in: &incoherent, at: 32 + 40)
        try incoherent.write(to: badSegment)
        XCTAssertThrowsError(try validator.validate(executableURL: badSegment, expectedArchitecture: .arm64))

        let fat = directory.url.appendingPathComponent("fat")
        try Data([0xca, 0xfe, 0xba, 0xbe] + Array(repeating: 0, count: 28)).write(to: fat)
        XCTAssertThrowsError(try validator.validate(executableURL: fat, expectedArchitecture: .arm64))
    }

    func testMachOCodeSignVerificationUsesInjectedBoundedProcessRunner() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let source = directory.url.appendingPathComponent("main.c")
        let binary = directory.url.appendingPathComponent("signed")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        try runTool("/usr/bin/clang", [source.path, "-o", binary.path])
        try runTool("/usr/bin/codesign", ["--force", "--sign", "-", binary.path])
        let runner = RecordingProcessRunner(results: [.failure(.processTimeout)])
        let validator = MachORuntimeValidator(
            processRunner: runner,
            codeSignTimeout: 0.25,
            codeSignOutputBytes: 512
        )

        XCTAssertThrowsError(try validator.validate(executableURL: binary, expectedArchitecture: .native)) {
            XCTAssertEqual($0 as? RuntimeInstallerError, .invalidMachO("code-signature verification timed out"))
        }
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.executable.path, "/usr/bin/codesign")
        XCTAssertEqual(calls.first?.maximumStandardOutputBytes, 512)
        XCTAssertEqual(calls.first?.timeout, 0.25)
        XCTAssertEqual(calls.first?.terminationGracePeriod, 0.2)
    }

    func testProductionVersionIdentityInspectorRequiresExactUnambiguousMatchingCompiledRecords() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let inspector = Forge3MachOVersionIdentityInspector()
        let expected = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.3"))

        func writeFixture(commandVersion: String, updateVersion: String, duplicateCommand: Bool = false) throws -> URL {
            let executable = directory.url.appendingPathComponent(UUID().uuidString)
            var bytes = Data("prefix".utf8)
            let commandRecord = Forge3MachOVersionIdentityInspector.metadataPrefix
                + Data(commandVersion.utf8)
                + Forge3MachOVersionIdentityInspector.metadataSuffix
            bytes.append(commandRecord)
            if duplicateCommand { bytes.append(commandRecord) }
            bytes.append(Data("middle".utf8))
            bytes.append(Data(updateVersion.utf8))
            bytes.append(Forge3MachOVersionIdentityInspector.updateMetadataSuffix)
            bytes.append(Data("suffix".utf8))
            try bytes.write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            return executable
        }

        let valid = try writeFixture(commandVersion: "1.2.3", updateVersion: "1.2.3")
        let validIdentity = try RuntimeExecutableIdentityValidator.capture(valid)
        XCTAssertEqual(
            try inspector.inspectVersionIdentity(
                of: valid,
                expectedVersion: expected,
                expectedIdentity: validIdentity
            ),
            RuntimeExecutableVersionIdentity(version: expected)
        )

        let wrongExpected = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.4"))
        XCTAssertThrowsError(
            try inspector.inspectVersionIdentity(
                of: valid,
                expectedVersion: wrongExpected,
                expectedIdentity: validIdentity
            )
        ) {
            XCTAssertEqual(
                $0 as? RuntimeInstallerError,
                .executableVersionIdentityMismatch(expected: wrongExpected, actual: expected)
            )
        }

        let conflicting = try writeFixture(commandVersion: "1.2.3", updateVersion: "1.2.4")
        XCTAssertThrowsError(
            try inspector.inspectVersionIdentity(
                of: conflicting,
                expectedVersion: expected,
                expectedIdentity: try RuntimeExecutableIdentityValidator.capture(conflicting)
            )
        ) {
            XCTAssertEqual(
                $0 as? RuntimeInstallerError,
                .invalidExecutableVersionIdentity("compiled forge3 command and update identities disagree")
            )
        }

        let ambiguous = try writeFixture(commandVersion: "1.2.3", updateVersion: "1.2.3", duplicateCommand: true)
        XCTAssertThrowsError(
            try inspector.inspectVersionIdentity(
                of: ambiguous,
                expectedVersion: expected,
                expectedIdentity: try RuntimeExecutableIdentityValidator.capture(ambiguous)
            )
        ) {
            XCTAssertEqual(
                $0 as? RuntimeInstallerError,
                .invalidExecutableVersionIdentity("forge3 command version metadata is ambiguous")
            )
        }

        let malformed = try writeFixture(commandVersion: "01.2.3", updateVersion: "01.2.3")
        XCTAssertThrowsError(
            try inspector.inspectVersionIdentity(
                of: malformed,
                expectedVersion: expected,
                expectedIdentity: try RuntimeExecutableIdentityValidator.capture(malformed)
            )
        ) {
            XCTAssertEqual(
                $0 as? RuntimeInstallerError,
                .invalidExecutableVersionIdentity(
                    "embedded forge3 command version is not an exact three-component version"
                )
            )
        }
    }

    func testProductionVersionIdentityInspectorRejectsChangedSymlinkedAndHardLinkedIdentity() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let expected = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.3"))
        let executable = directory.url.appendingPathComponent("forge3")
        var bytes = Forge3MachOVersionIdentityInspector.metadataPrefix
        bytes.append(Data(expected.rawValue.utf8))
        bytes.append(Forge3MachOVersionIdentityInspector.metadataSuffix)
        bytes.append(Data(expected.rawValue.utf8))
        bytes.append(Forge3MachOVersionIdentityInspector.updateMetadataSuffix)
        try bytes.write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let identity = try RuntimeExecutableIdentityValidator.capture(executable)
        let inspector = Forge3MachOVersionIdentityInspector()

        let symlink = directory.url.appendingPathComponent("forge3-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: executable)
        XCTAssertThrowsError(
            try inspector.inspectVersionIdentity(
                of: symlink,
                expectedVersion: expected,
                expectedIdentity: identity
            )
        )

        let hardLink = directory.url.appendingPathComponent("forge3-hardlink")
        try FileManager.default.linkItem(at: executable, to: hardLink)
        XCTAssertThrowsError(
            try inspector.inspectVersionIdentity(
                of: executable,
                expectedVersion: expected,
                expectedIdentity: identity
            )
        )
        try FileManager.default.removeItem(at: hardLink)

        try FileManager.default.removeItem(at: executable)
        try bytes.write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        XCTAssertThrowsError(
            try inspector.inspectVersionIdentity(
                of: executable,
                expectedVersion: expected,
                expectedIdentity: identity
            )
        )
    }

    func testMachOValidatorAcceptsAdHocSignedBinaryAndRejectsCorruptPresentSignature() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let source = directory.url.appendingPathComponent("main.c")
        let binary = directory.url.appendingPathComponent("signed")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        try runTool("/usr/bin/clang", [source.path, "-o", binary.path])
        try runTool("/usr/bin/codesign", ["--force", "--sign", "-", binary.path])
        let validator = MachORuntimeValidator()
        XCTAssertNoThrow(try validator.validate(executableURL: binary, expectedArchitecture: .native))
        let adHocInspection = try validator.inspectSignature(of: binary)
        XCTAssertEqual(adHocInspection.signatureClass, .adHoc)
        XCTAssertNil(adHocInspection.teamIdentifier)

        let unsigned = directory.url.appendingPathComponent("unsigned")
        try runTool("/usr/bin/clang", [source.path, "-o", unsigned.path])
        try runTool("/usr/bin/codesign", ["--remove-signature", unsigned.path])
        let unsignedInspection = try validator.inspectSignature(of: unsigned)
        XCTAssertEqual(unsignedInspection.signatureClass, .unsigned)
        XCTAssertNil(unsignedInspection.teamIdentifier)
        XCTAssertNil(unsignedInspection.signingIdentity)

        var signedData = try Data(contentsOf: binary)
        let signatureRange = try XCTUnwrap(machOCodeSignatureRange(signedData))
        signedData[signatureRange.lowerBound + 16] ^= 0xff
        try signedData.write(to: binary)
        XCTAssertThrowsError(try validator.validate(executableURL: binary, expectedArchitecture: .native)) {
            guard case RuntimeInstallerError.invalidMachO = $0 else { return XCTFail("unexpected \($0)") }
        }
    }

    func testTarParserAcceptsOneForgeExecutableAndRejectsUnsafeEntries() throws {
        let limits = RuntimeInstallerLimits(expandedArchiveBytes: 1_024, executableBytes: 512, archiveEntries: 8)
        let tarURL = URL(fileURLWithPath: "/tmp/test.tar")
        let valid = makeTar([
            TarFixture(path: "forge3-arm64/", type: "5", data: Data()),
            TarFixture(path: "forge3-arm64/README.md", type: "0", data: Data("readme".utf8)),
            TarFixture(path: "forge3-arm64/forge3", type: "0", data: Data("binary".utf8))
        ])
        let inspection = try SafeTarXZArchiveHandler.parseTar(valid, tarURL: tarURL, limits: limits)
        XCTAssertEqual(inspection.executableEntry.path, "forge3-arm64/forge3")

        for fixture in [
            [TarFixture(path: "../forge3", type: "0", data: Data())],
            [TarFixture(path: "/absolute/forge3", type: "0", data: Data())],
            [TarFixture(path: "safe\\forge3", type: "0", data: Data())],
            [TarFixture(path: "link", type: "2", data: Data()), TarFixture(path: "forge3", type: "0", data: Data())],
            [TarFixture(path: "fifo", type: "6", data: Data()), TarFixture(path: "forge3", type: "0", data: Data())],
            [TarFixture(path: "forge3", type: "0", data: Data()), TarFixture(path: "forge3", type: "0", data: Data())],
            [TarFixture(path: "a/forge3", type: "0", data: Data()), TarFixture(path: "b/forge3", type: "0", data: Data())]
        ] {
            XCTAssertThrowsError(try SafeTarXZArchiveHandler.parseTar(makeTar(fixture), tarURL: tarURL, limits: limits))
        }
    }

    func testTarParserRejectsMalformedTruncatedAndOversizeArchives() throws {
        let tarURL = URL(fileURLWithPath: "/tmp/test.tar")
        let limits = RuntimeInstallerLimits(expandedArchiveBytes: 8, executableBytes: 4, archiveEntries: 2)
        var badChecksum = makeTar([TarFixture(path: "forge3", type: "0", data: Data("abc".utf8))])
        badChecksum[0] ^= 1
        XCTAssertThrowsError(try SafeTarXZArchiveHandler.parseTar(badChecksum, tarURL: tarURL, limits: limits))
        XCTAssertThrowsError(try SafeTarXZArchiveHandler.parseTar(Data(badChecksum.dropLast(1_024)), tarURL: tarURL, limits: limits))
        XCTAssertThrowsError(try SafeTarXZArchiveHandler.parseTar(makeTar([TarFixture(path: "forge3", type: "0", data: Data(repeating: 1, count: 5))]), tarURL: tarURL, limits: limits))
        XCTAssertThrowsError(try SafeTarXZArchiveHandler.parseTar(makeTar([
            TarFixture(path: "a", type: "0", data: Data()),
            TarFixture(path: "b", type: "0", data: Data()),
            TarFixture(path: "forge3", type: "0", data: Data())
        ]), tarURL: tarURL, limits: limits))
    }

    func testStoreUsesPrivatePermissionsTrustworthyReceiptAndAtomicCurrentPointer() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let validator = StubValidator()
        let store = RuntimeStore(rootURL: directory.url.appendingPathComponent("runtime"), validator: validator)
        let temporary = try store.makePrivateTemporaryDirectory()
        let executable = temporary.appendingPathComponent("forge3")
        try Data("one".utf8).write(to: executable)
        let version = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.3"))
        let receipt = RuntimeStoreReceipt(
            version: version,
            architecture: .arm64,
            archiveSHA256: String(repeating: "a", count: 64),
            executableSHA256: RuntimeSHA256.hexDigest(of: Data("one".utf8))
        )
        let installed = try store.installStagedRuntime(executableURL: executable, receipt: receipt, temporaryDirectory: temporary)
        XCTAssertEqual(try store.current(architecture: .arm64), installed)
        XCTAssertEqual(permissions(directory.url.appendingPathComponent("runtime")), 0o700)
        XCTAssertEqual(permissions(installed.executableURL.deletingLastPathComponent()), 0o500)
        XCTAssertEqual(permissions(installed.executableURL), 0o500)
        XCTAssertEqual(permissions(installed.executableURL.deletingLastPathComponent().appendingPathComponent("receipt.json")), 0o400)
        XCTAssertEqual(try String(contentsOf: directory.url.appendingPathComponent("runtime/current")), "1.2.3\n")

        let installedDirectory = installed.executableURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installedDirectory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installed.executableURL.path)
        try Data("tampered".utf8).write(to: installed.executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: installed.executableURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: installedDirectory.path)
        XCTAssertNil(try store.cached(version: version, architecture: .arm64))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.executableURL.deletingLastPathComponent().path))
    }

    func testStoreRejectsInstalledRuntimeModeDriftAndSafelyUnsealsForRecovery() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let root = directory.url.appendingPathComponent("runtime")
        let store = RuntimeStore(rootURL: root, validator: StubValidator())
        let installed = try installFixture(version: "1.2.3", data: Data("sealed".utf8), store: store)
        let runtimeDirectory = installed.executableURL.deletingLastPathComponent()
        let receipt = runtimeDirectory.appendingPathComponent("receipt.json")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtimeDirectory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installed.executableURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)

        XCTAssertNil(try store.cached(version: installed.version, architecture: .arm64))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeDirectory.path))
    }

    func testStoreRejectsUnsafeManagedPathComponentsAndDoesNotFollowRuntimeLinks() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let outside = directory.url.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let root = directory.url.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        let linkedRootStore = RuntimeStore(rootURL: root, validator: StubValidator())
        XCTAssertThrowsError(try linkedRootStore.makePrivateTemporaryDirectory()) {
            guard case RuntimeInstallerError.untrustedStoreItem = $0 else { return XCTFail("unexpected \($0)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))

        try FileManager.default.removeItem(at: root)
        let store = RuntimeStore(rootURL: root, validator: StubValidator())
        _ = try store.makePrivateTemporaryDirectory()
        let versions = root.appendingPathComponent("versions")
        try FileManager.default.removeItem(at: versions)
        try FileManager.default.createSymbolicLink(at: versions, withDestinationURL: outside)
        XCTAssertThrowsError(try store.cached(version: RuntimeReleaseVersion(rawValue: "1.2.3")!, architecture: .arm64))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testStoreColdRestartRecoversNewestReceiptBackedRuntimeAndCleansSafeStaleArtifacts() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let root = directory.url.appendingPathComponent("runtime", isDirectory: true)
        let original = RuntimeStore(rootURL: root, validator: StubValidator())
        _ = try installFixture(version: "1.2.3", data: Data("one".utf8), store: original)
        let newest = try installFixture(version: "1.2.4", data: Data("two".utf8), store: original)
        try FileManager.default.removeItem(at: root.appendingPathComponent("current"))
        let staleInstall = root.appendingPathComponent("tmp/install.stale", isDirectory: true)
        try FileManager.default.createDirectory(at: staleInstall, withIntermediateDirectories: false)
        try Data("stale".utf8).write(to: staleInstall.appendingPathComponent("partial"))
        let stalePointer = root.appendingPathComponent(".current.stale")
        try Data("1.2.3\n".utf8).write(to: stalePointer)
        let oldDate = Date().addingTimeInterval(-48 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: staleInstall.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: stalePointer.path)

        let restarted = RuntimeStore(rootURL: root, validator: StubValidator())
        let recovered = try restarted.current(architecture: .arm64)

        XCTAssertEqual(recovered?.version, newest.version)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("current")), "1.2.4\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleInstall.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stalePointer.path))
    }

    func testColdRestartInstallLatestRecoversReceiptBackedCacheWithExactlyZeroNetworkRequests() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let root = directory.url.appendingPathComponent("runtime", isDirectory: true)
        let originalStore = RuntimeStore(rootURL: root, validator: StubValidator())
        let installed = try installFixture(version: "1.2.4", data: Data("cached".utf8), store: originalStore)
        try FileManager.default.removeItem(at: root.appendingPathComponent("current"))

        let network = MockNetwork(responses: [:])
        let restartedInstaller = RuntimeInstaller(
            architecture: .arm64,
            dependencies: .init(
                network: network,
                store: RuntimeStore(rootURL: root, validator: StubValidator()),
                archive: MockArchive(),
                validator: StubValidator()
            )
        )

        let recovered = try await restartedInstaller.installLatest()
        let requestedURLs = await network.requestedURLs

        XCTAssertEqual(recovered, installed)
        XCTAssertEqual(requestedURLs, [], "receipt-backed cold recovery must issue exactly zero RuntimeNetworkClient requests")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("current")), "1.2.4\n")
    }

    func testStoreRecoversCorruptPointerAndDestinationWithoutFollowingLinks() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let root = directory.url.appendingPathComponent("runtime", isDirectory: true)
        let store = RuntimeStore(rootURL: root, validator: StubValidator())
        _ = try store.makePrivateTemporaryDirectory()
        let outsideFile = directory.url.appendingPathComponent("outside-file")
        try Data("outside".utf8).write(to: outsideFile)
        let current = root.appendingPathComponent("current")
        try FileManager.default.createSymbolicLink(at: current, withDestinationURL: outsideFile)
        XCTAssertNil(try store.current(architecture: .arm64))
        XCTAssertEqual(try Data(contentsOf: outsideFile), Data("outside".utf8))

        let version = RuntimeReleaseVersion(rawValue: "1.2.3")!
        let versionDirectory = root.appendingPathComponent("versions/1.2.3", isDirectory: true)
        try FileManager.default.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
        let destination = versionDirectory.appendingPathComponent("arm64", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: directory.url.appendingPathComponent("outside", isDirectory: true))
        let installed = try installFixture(version: version.rawValue, data: Data("replacement".utf8), store: store)
        XCTAssertEqual(installed.version, version)
        XCTAssertEqual(try Data(contentsOf: installed.executableURL), Data("replacement".utf8))
    }

    func testStoreActivationFailureAndCommitBoundaryCancellationRollBackDestinationAndPointer() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let root = directory.url.appendingPathComponent("runtime", isDirectory: true)
        let firstStore = RuntimeStore(rootURL: root, validator: StubValidator())
        let first = try installFixture(version: "1.2.3", data: Data("one".utf8), store: firstStore)

        let failingStore = RuntimeStore(
            rootURL: root,
            validator: StubValidator(),
            commitHooks: .init(beforeActivationRename: {
                throw RuntimeInstallerError.filesystem(
                    operation: "activate test runtime",
                    path: root.path,
                    failure: .io
                )
            })
        )
        XCTAssertThrowsError(try installFixture(version: "1.2.4", data: Data("two".utf8), store: failingStore))
        XCTAssertEqual(try firstStore.current(architecture: .arm64), first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("versions/1.2.4/arm64").path))

        let cancelledStore = RuntimeStore(
            rootURL: root,
            validator: StubValidator(),
            commitHooks: .init(afterDestinationMove: { throw RuntimeInstallerError.cancelled })
        )
        XCTAssertThrowsError(try installFixture(version: "1.2.5", data: Data("three".utf8), store: cancelledStore)) {
            XCTAssertEqual($0 as? RuntimeInstallerError, .cancelled)
        }
        XCTAssertEqual(try firstStore.current(architecture: .arm64), first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("versions/1.2.5/arm64").path))
    }

    func testStoreActivationRollsBackWhenNewRuntimeIsInvalid() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = RuntimeStore(rootURL: directory.url.appendingPathComponent("runtime"), validator: StubValidator())
        let first = try installFixture(version: "1.2.3", data: Data("one".utf8), store: store)
        let temporary = try store.makePrivateTemporaryDirectory()
        let executable = temporary.appendingPathComponent("forge3")
        try Data("two".utf8).write(to: executable)
        let secondVersion = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.4"))
        let invalidReceipt = RuntimeStoreReceipt(
            version: secondVersion,
            architecture: .arm64,
            archiveSHA256: String(repeating: "b", count: 64),
            executableSHA256: String(repeating: "0", count: 64)
        )
        XCTAssertThrowsError(try store.installStagedRuntime(executableURL: executable, receipt: invalidReceipt, temporaryDirectory: temporary))
        XCTAssertEqual(try store.current(architecture: .arm64), first)
    }

    func testInstallLatestUsesCurrentCachedRuntimeWithZeroNetworkAndReadyProgress() async throws {
        let version = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.3"))
        let cached = InstalledRuntime(
            version: version,
            architecture: .arm64,
            executableURL: URL(fileURLWithPath: "/cached/latest/forge3")
        )
        let store = MockStore(cached: cached)
        let network = MockNetwork(responses: [:])
        let installer = RuntimeInstaller(
            architecture: .arm64,
            dependencies: .init(network: network, store: store, archive: MockArchive(), validator: StubValidator())
        )
        let phases = LockedValues<RuntimeInstallationPhase>()

        let installed = try await installer.installLatest { phase in phases.append(phase) }

        let requestedURLs = await network.requestedURLs
        XCTAssertEqual(installed, cached)
        XCTAssertEqual(requestedURLs, [], "current cached reuse must issue exactly zero RuntimeNetworkClient requests")
        XCTAssertEqual(phases.values, [.resolving, .ready])
    }

    func testInstallerUsesCachedVersionWithZeroNetwork() async throws {
        let version = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.3"))
        let cached = InstalledRuntime(version: version, architecture: .arm64, executableURL: URL(fileURLWithPath: "/cached/forge3"))
        let store = MockStore(cached: cached)
        let network = MockNetwork(responses: [:])
        let installer = RuntimeInstaller(
            architecture: .arm64,
            dependencies: .init(network: network, store: store, archive: MockArchive(), validator: StubValidator())
        )
        let installed = try await installer.install(version: version)
        let requestedURLs = await network.requestedURLs
        XCTAssertEqual(installed, cached)
        XCTAssertEqual(requestedURLs, [], "versioned cached reuse must issue exactly zero RuntimeNetworkClient requests")
    }

    func testInstallerReportsOnlyArchiveByteDerivedDownloadProgress() async throws {
        let version = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.3"))
        let archiveData = Data("archive-progress".utf8)
        let archiveURL = RuntimeReleaseURLs.archive(version: version, architecture: .arm64)
        let checksumURL = RuntimeReleaseURLs.checksum(version: version, architecture: .arm64)
        let sidecar = Data("\(RuntimeSHA256.hexDigest(of: archiveData)) *\(RuntimeArchitecture.arm64.archiveName)\n".utf8)
        let manifest = Data("{\"version\":\"1.2.3\"}".utf8)
        let network = MockNetwork(responses: [
            RuntimeReleaseURLs.latestManifest: manifest,
            archiveURL: archiveData,
            checksumURL: sidecar
        ])
        let installer = RuntimeInstaller(
            architecture: .arm64,
            dependencies: .init(
                network: network,
                store: MockStore(),
                archive: MockArchive(executable: macho(architecture: .arm64)),
                validator: MachORuntimeValidator(),
                versionInspector: RecordingVersionIdentityInspector([
                    .success(RuntimeExecutableVersionIdentity(version: version))
                ]),
                executionProbe: ScriptedExecutionProbe([.succeeded])
            )
        )
        let phases = LockedValues<RuntimeInstallationPhase>()
        _ = try await installer.installLatest { phases.append($0) }

        let downloads = phases.values.compactMap(\.boundedDownloadProgress)
        XCTAssertEqual(downloads.first, 0)
        XCTAssertEqual(downloads.last, 1)
        XCTAssertFalse(downloads.contains(0.15), "progress must never be fabricated")
        XCTAssertEqual(downloads, downloads.sorted())
    }

    func testInstallerDownloadsImmutableAssetsVerifiesChecksumAndInstalls() async throws {
        let version = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.3"))
        let archiveData = Data("archive-fixture".utf8)
        let archiveURL = RuntimeReleaseURLs.archive(version: version, architecture: .arm64)
        let checksumURL = RuntimeReleaseURLs.checksum(version: version, architecture: .arm64)
        let sidecar = Data("\(RuntimeSHA256.hexDigest(of: archiveData)) *\(RuntimeArchitecture.arm64.archiveName)\n".utf8)
        let network = MockNetwork(responses: [archiveURL: archiveData, checksumURL: sidecar])
        let store = MockStore()
        let archive = MockArchive(executable: macho(architecture: .arm64))
        let installer = RuntimeInstaller(
            architecture: .arm64,
            dependencies: .init(
                network: network,
                store: store,
                archive: archive,
                validator: MachORuntimeValidator(),
                versionInspector: RecordingVersionIdentityInspector([
                    .success(RuntimeExecutableVersionIdentity(version: version))
                ]),
                executionProbe: ScriptedExecutionProbe([.succeeded])
            )
        )
        let installed = try await installer.install(version: version)
        XCTAssertEqual(installed.version, version)
        let requestedURLs = await network.requestedURLs
        XCTAssertEqual(Set(requestedURLs), Set([archiveURL, checksumURL]))
        XCTAssertEqual(store.installCount, 1)
    }

    func testInstallerRejectsMalformedManifestAndChecksumEndToEnd() async throws {
        let malformedManifestInstaller = RuntimeInstaller(
            architecture: .arm64,
            dependencies: .init(
                network: MockNetwork(responses: [RuntimeReleaseURLs.latestManifest: Data("{\"version\":\"01.2.3\"}".utf8)]),
                store: MockStore(),
                archive: MockArchive(),
                validator: StubValidator()
            )
        )
        do {
            _ = try await malformedManifestInstaller.installLatest()
            XCTFail("expected malformed manifest rejection")
        } catch let error as RuntimeInstallerError {
            guard case .invalidManifest = error else { return XCTFail("unexpected \(error)") }
        }

        let version = RuntimeReleaseVersion(rawValue: "1.2.3")!
        let archiveURL = RuntimeReleaseURLs.archive(version: version, architecture: .arm64)
        let checksumURL = RuntimeReleaseURLs.checksum(version: version, architecture: .arm64)
        let archive = MockArchive()
        let malformedChecksumInstaller = RuntimeInstaller(
            architecture: .arm64,
            dependencies: .init(
                network: MockNetwork(responses: [
                    archiveURL: Data("archive".utf8),
                    checksumURL: Data("not-a-checksum\n".utf8)
                ]),
                store: MockStore(),
                archive: archive,
                validator: StubValidator()
            )
        )
        do {
            _ = try await malformedChecksumInstaller.install(version: version)
            XCTFail("expected malformed checksum rejection")
        } catch let error as RuntimeInstallerError {
            guard case .invalidChecksumSidecar = error else { return XCTFail("unexpected \(error)") }
        }
        let inspectCount = await archive.inspectCount
        XCTAssertEqual(inspectCount, 0)
    }

    func testInstallerRejectsChecksumMismatchBeforeArchiveInspection() async throws {
        let version = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.3"))
        let archiveURL = RuntimeReleaseURLs.archive(version: version, architecture: .arm64)
        let checksumURL = RuntimeReleaseURLs.checksum(version: version, architecture: .arm64)
        let network = MockNetwork(responses: [
            archiveURL: Data("bad".utf8),
            checksumURL: Data("\(String(repeating: "0", count: 64)) *\(RuntimeArchitecture.arm64.archiveName)\n".utf8)
        ])
        let archive = MockArchive()
        let installer = RuntimeInstaller(
            architecture: .arm64,
            dependencies: .init(network: network, store: MockStore(), archive: archive, validator: StubValidator())
        )
        do {
            _ = try await installer.install(version: version)
            XCTFail("expected checksum mismatch")
        } catch let error as RuntimeInstallerError {
            guard case .checksumMismatch = error else { return XCTFail("unexpected \(error)") }
        }
        let inspectCount = await archive.inspectCount
        XCTAssertEqual(inspectCount, 0)
    }

    func testInstallerGloballySerializesDifferentVersionRequests() async throws {
        let firstVersion = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.3"))
        let secondVersion = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.4"))
        let network = SerializedInstallNetwork()
        let installer = RuntimeInstaller(
            architecture: .arm64,
            dependencies: .init(
                network: network,
                store: MockStore(),
                archive: MockArchive(executable: macho(architecture: .arm64)),
                validator: MachORuntimeValidator(),
                versionInspector: RecordingVersionIdentityInspector([
                    .success(RuntimeExecutableVersionIdentity(version: firstVersion)),
                    .success(RuntimeExecutableVersionIdentity(version: secondVersion))
                ]),
                executionProbe: ScriptedExecutionProbe([.succeeded, .succeeded])
            )
        )

        let first = Task { try await installer.install(version: firstVersion) }
        await network.waitUntilFirstRequestStarted()
        let second = Task { try await installer.install(version: secondVersion) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let requestedBeforeRelease = await network.requestedVersions
        XCTAssertEqual(requestedBeforeRelease, [firstVersion])
        await network.releaseFirstVersion()
        _ = try await first.value
        _ = try await second.value
        let maximumConcurrent = await network.maximumConcurrentVersionCount
        XCTAssertEqual(maximumConcurrent, 1)
    }

    func testInstallerCoalescesConcurrentSameVersionRequests() async throws {
        let version = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.3"))
        let archiveData = Data("archive".utf8)
        let archiveURL = RuntimeReleaseURLs.archive(version: version, architecture: .arm64)
        let checksumURL = RuntimeReleaseURLs.checksum(version: version, architecture: .arm64)
        let network = MockNetwork(responses: [
            archiveURL: archiveData,
            checksumURL: Data("\(RuntimeSHA256.hexDigest(of: archiveData)) *\(RuntimeArchitecture.arm64.archiveName)\n".utf8)
        ], delayNanoseconds: 50_000_000)
        let store = MockStore()
        let installer = RuntimeInstaller(
            architecture: .arm64,
            dependencies: .init(
                network: network,
                store: store,
                archive: MockArchive(executable: macho(architecture: .arm64)),
                validator: MachORuntimeValidator(),
                versionInspector: RecordingVersionIdentityInspector([
                    .success(RuntimeExecutableVersionIdentity(version: version))
                ]),
                executionProbe: ScriptedExecutionProbe([.succeeded])
            )
        )
        async let firstOperation = installer.install(version: version)
        async let secondOperation = installer.install(version: version)
        let first = try await firstOperation
        let second = try await secondOperation
        let requestCount = await network.requestCount
        XCTAssertEqual(first, second)
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(store.installCount, 1)
    }

    func testCoalescedReplayCannotArriveAfterNewerPublicationOrCompletion() async throws {
        let version = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.3"))
        let network = ReplayRaceNetwork(version: version)
        let hook = BlockingReplayProgressHook()
        let deliveries = LockedValues<String>()
        let installer = RuntimeInstaller(
            architecture: .arm64,
            dependencies: .init(
                network: network,
                store: MockStore(),
                archive: MockArchive(executable: macho(architecture: .arm64)),
                validator: MachORuntimeValidator(),
                versionInspector: ExpectedVersionIdentityInspector(),
                executionProbe: ScriptedExecutionProbe([.succeeded]),
                progressDeliveryHook: hook
            )
        )

        let owner = Task { try await installer.installLatest() }
        await network.waitUntilManifestRequested()
        let joiner = Task {
            let runtime = try await installer.installLatest { phase in
                deliveries.append("phase:\(phase.testName)")
            }
            deliveries.append("completed")
            return runtime
        }
        await hook.waitUntilReplayBlocked()

        await network.releaseManifest()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(deliveries.values, [], "completion must wait for the blocked replay stream")

        await hook.releaseReplay()
        _ = try await owner.value
        _ = try await joiner.value

        let values = deliveries.values
        XCTAssertEqual(values.first, "phase:resolving")
        XCTAssertEqual(values.last, "completed")
        XCTAssertEqual(values.filter { $0 == "phase:resolving" }.count, 1)
        let phaseOrder = values.dropLast().compactMap { RuntimeInstallationPhase.testOrder(named: $0) }
        XCTAssertEqual(phaseOrder, phaseOrder.sorted())
        let blockedReplayCount = await hook.blockedReplayCount
        XCTAssertEqual(blockedReplayCount, 1)
    }

    func testCancellingOneCoalescedWaiterDoesNotCancelAnother() async throws {
        let version = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.3"))
        let archiveData = Data("archive".utf8)
        let archiveURL = RuntimeReleaseURLs.archive(version: version, architecture: .arm64)
        let checksumURL = RuntimeReleaseURLs.checksum(version: version, architecture: .arm64)
        let network = MockNetwork(responses: [
            archiveURL: archiveData,
            checksumURL: Data("\(RuntimeSHA256.hexDigest(of: archiveData)) *\(RuntimeArchitecture.arm64.archiveName)\n".utf8)
        ], delayNanoseconds: 100_000_000)
        let store = MockStore()
        let installer = RuntimeInstaller(
            architecture: .arm64,
            dependencies: .init(
                network: network,
                store: store,
                archive: MockArchive(executable: macho(architecture: .arm64)),
                validator: MachORuntimeValidator(),
                versionInspector: RecordingVersionIdentityInspector([
                    .success(RuntimeExecutableVersionIdentity(version: version))
                ]),
                executionProbe: ScriptedExecutionProbe([.succeeded])
            )
        )
        let cancelled = Task { try await installer.install(version: version) }
        let survivor = Task { try await installer.install(version: version) }
        try await Task.sleep(nanoseconds: 20_000_000)
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("expected cancelled waiter")
        } catch {}
        let installed = try await survivor.value
        let requestCount = await network.requestCount
        XCTAssertEqual(installed.version, version)
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(store.installCount, 1)
    }

    func testCancelledSoleOperationRemainsRegisteredUntilTerminationBeforeReplacementStarts() async throws {
        let firstVersion = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.3"))
        let secondVersion = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.4"))
        let network = CancellationHoldingNetwork(firstVersion: firstVersion)
        let installer = RuntimeInstaller(
            architecture: .arm64,
            dependencies: .init(network: network, store: MockStore(), archive: MockArchive(), validator: StubValidator())
        )
        let first = Task { try await installer.install(version: firstVersion) }
        await network.waitUntilFirstVersionStarted()
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("expected prompt waiter cancellation")
        } catch let error as RuntimeInstallerError {
            XCTAssertEqual(error, .cancelled)
        }
        let replacement = Task { try await installer.install(version: secondVersion) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let startedBeforeRelease = await network.secondVersionStarted
        XCTAssertFalse(startedBeforeRelease)
        await network.releaseCancelledFirstVersion()
        _ = try? await replacement.value
        let startedAfterRelease = await network.secondVersionStarted
        XCTAssertTrue(startedAfterRelease)
    }

    func testInstallerCancellationPreventsActivation() async throws {
        let version = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.3"))
        let network = CancellingNetwork()
        let store = MockStore()
        let installer = RuntimeInstaller(
            architecture: .arm64,
            dependencies: .init(network: network, store: store, archive: MockArchive(), validator: StubValidator())
        )
        let task = Task { try await installer.install(version: version) }
        await network.waitUntilRequested()
        task.cancel()
        await network.release()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {}
        XCTAssertEqual(store.installCount, 0)
    }

    func testProductionTemporaryTrustPolicyPredicateIsExactlyAdHocPlusQuarantine() throws {
        let version = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.3"))
        let identity = RuntimeExecutableIdentity(
            device: 1,
            inode: 2,
            size: 3,
            sha256: String(repeating: "a", count: 64)
        )
        let policy = TemporaryAdHocRuntimeTrustPolicy()
        for signatureClass in [
            RuntimeCodeSignatureClass.unsigned,
            .adHoc,
            .developerID,
            .otherSigned
        ] {
            for hasQuarantine in [false, true] {
                let decision = try policy.decision(
                    for: RuntimePreExecutionTrustContext(
                        signatureClass: signatureClass,
                        hasQuarantine: hasQuarantine,
                        versionIdentity: RuntimeExecutableVersionIdentity(version: version),
                        architecture: .arm64,
                        executableIdentity: identity
                    )
                )
                XCTAssertEqual(
                    decision,
                    signatureClass == .adHoc && hasQuarantine
                        ? .refreshRemovingQuarantine
                        : .preserve
                )
            }
        }
    }

    func testDeveloperIDClassificationRequiresAppleAnchorRequirementNotLookalikeSubject() throws {
        let executableURL = URL(fileURLWithPath: "/tmp/forge3-lookalike")

        let anchoredEvaluator = RecordingDeveloperIDRequirementEvaluator(results: [.success(true)])
        let anchoredValidator = MachORuntimeValidator(
            developerIDRequirementEvaluator: anchoredEvaluator
        )
        XCTAssertEqual(
            try anchoredValidator.classifySignature(
                flags: 0,
                hasCertificates: true,
                executableURL: executableURL
            ),
            .developerID
        )
        XCTAssertEqual(anchoredEvaluator.calls.map(\.expectedTeamIdentifier), [nil])

        let lookalikeEvaluator = RecordingDeveloperIDRequirementEvaluator(results: [.success(false)])
        let lookalikeValidator = MachORuntimeValidator(
            developerIDRequirementEvaluator: lookalikeEvaluator
        )
        XCTAssertEqual(
            try lookalikeValidator.classifySignature(
                flags: 0,
                hasCertificates: true,
                executableURL: executableURL
            ),
            .otherSigned,
            "a self-signed/lookalike certificate subject must not classify as Developer ID"
        )
        XCTAssertEqual(lookalikeEvaluator.calls.map(\.expectedTeamIdentifier), [nil])
    }

    func testDeveloperIDClassificationFailsClosedWhenRequirementEvaluationFails() throws {
        let expected = RuntimeInstallerError.developerIDAuthenticationFailed(
            "injected requirement evaluation failure"
        )
        let evaluator = RecordingDeveloperIDRequirementEvaluator(results: [.failure(expected)])
        let validator = MachORuntimeValidator(developerIDRequirementEvaluator: evaluator)

        XCTAssertThrowsError(
            try validator.classifySignature(
                flags: 0,
                hasCertificates: true,
                executableURL: URL(fileURLWithPath: "/tmp/forge3")
            )
        ) {
            XCTAssertEqual($0 as? RuntimeInstallerError, expected)
        }
    }

    func testDeveloperIDRequirementTextUsesAppleAnchorOIDsAndExactTeamID() throws {
        let base = try SecurityRuntimeDeveloperIDRequirementEvaluator.requirementText(
            expectedTeamIdentifier: nil
        )
        XCTAssertTrue(base.contains("anchor apple generic"))
        XCTAssertTrue(base.contains("certificate 1[field.1.2.840.113635.100.6.2.6] exists"))
        XCTAssertTrue(base.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] exists"))
        XCTAssertFalse(base.contains("subject.OU"))

        let teamBound = try SecurityRuntimeDeveloperIDRequirementEvaluator.requirementText(
            expectedTeamIdentifier: "TEAM123456"
        )
        XCTAssertTrue(teamBound.contains("certificate leaf[subject.OU] = \"TEAM123456\""))
        XCTAssertThrowsError(
            try SecurityRuntimeDeveloperIDRequirementEvaluator.requirementText(
                expectedTeamIdentifier: "bad-team"
            )
        )
    }

    func testDeveloperIDAuthenticationPolicyRequiresExactConfiguredTeamIdentifier() throws {
        let matching = RuntimeCodeSignatureInspection(
            signatureClass: .developerID,
            teamIdentifier: "TEAM123456",
            signingIdentity: "Developer ID Application: Forge Example (TEAM123456)"
        )
        XCTAssertNoThrow(
            try RuntimeDeveloperIDAuthenticationPolicy(
                expectedTeamIdentifier: "TEAM123456"
            ).authenticate(
                matching,
                executableURL: URL(fileURLWithPath: "/tmp/forge3"),
                requirementEvaluator: RecordingDeveloperIDRequirementEvaluator(results: [.success(true)])
            )
        )

        for (policy, signature, expectedError) in [
            (
                RuntimeDeveloperIDAuthenticationPolicy(),
                matching,
                RuntimeInstallerError.developerIDAuthenticationFailed(
                    "no expected Developer ID Team Identifier is configured"
                )
            ),
            (
                RuntimeDeveloperIDAuthenticationPolicy(expectedTeamIdentifier: "TEAM123456"),
                RuntimeCodeSignatureInspection(
                    signatureClass: .developerID,
                    signingIdentity: "Developer ID Application: Forge Example"
                ),
                RuntimeInstallerError.developerIDAuthenticationFailed(
                    "the signature does not contain a Team Identifier"
                )
            ),
            (
                RuntimeDeveloperIDAuthenticationPolicy(expectedTeamIdentifier: "TEAM123456"),
                RuntimeCodeSignatureInspection(
                    signatureClass: .developerID,
                    teamIdentifier: "OTHER98765",
                    signingIdentity: "Developer ID Application: Other (OTHER98765)"
                ),
                RuntimeInstallerError.developerIDAuthenticationFailed(
                    "Team Identifier OTHER98765 does not match expected TEAM123456"
                )
            )
        ] {
            XCTAssertThrowsError(
                try policy.authenticate(
                    signature,
                    executableURL: URL(fileURLWithPath: "/tmp/forge3"),
                    requirementEvaluator: RecordingDeveloperIDRequirementEvaluator(results: [.success(true)])
                )
            ) {
                XCTAssertEqual($0 as? RuntimeInstallerError, expectedError)
            }
        }

        for signatureClass in [
            RuntimeCodeSignatureClass.unsigned,
            .adHoc,
            .otherSigned
        ] {
            XCTAssertNoThrow(
                try RuntimeDeveloperIDAuthenticationPolicy().authenticate(
                    RuntimeCodeSignatureInspection(signatureClass: signatureClass),
                    executableURL: URL(fileURLWithPath: "/tmp/forge3"),
                    requirementEvaluator: RecordingDeveloperIDRequirementEvaluator(results: [.success(true)])
                )
            )
        }
    }

    func testDeveloperIDAuthenticationRequirementFailureIsABarrierBeforeTrustPolicyOrProbe() async throws {
        let expected = RuntimeInstallerError.developerIDAuthenticationFailed(
            "injected Apple-anchor evaluation failure"
        )
        let trustPolicy = RecordingTrustPolicy(decision: .preserve)
        let quarantine = RecordingQuarantineManager()
        let probe = ScriptedExecutionProbe([.succeeded])
        let evaluator = RecordingDeveloperIDRequirementEvaluator(results: [.failure(expected)])
        let fixture = try installerFixture(
            probe: probe,
            quarantineManager: quarantine,
            securityLogger: RecordingSecurityLogger(),
            signatureInspector: matchingDeveloperIDSignatureInspector(),
            trustPolicy: trustPolicy,
            developerIDAuthenticationPolicy: matchingDeveloperIDAuthenticationPolicy(),
            developerIDRequirementEvaluator: evaluator
        )

        do {
            _ = try await fixture.installer.install(version: fixture.version)
            XCTFail("expected Developer ID requirement-evaluation failure")
        } catch let error as RuntimeInstallerError {
            XCTAssertEqual(error, expected)
        }
        XCTAssertEqual(evaluator.calls.map(\.expectedTeamIdentifier), ["TEAM123456"])
        XCTAssertEqual(trustPolicy.contexts, [])
        XCTAssertEqual(quarantine.inspectedURLs, [])
        XCTAssertEqual(probe.callCount, 0)
        XCTAssertEqual(fixture.store.installCount, 0)
    }

    func testDeveloperIDTeamAuthenticationIsABarrierBeforeTrustPolicyOrProbe() async throws {
        let cases: [(String?, String?, RuntimeInstallerError?)] = [
            ("TEAM123456", "TEAM123456", nil),
            (nil, "TEAM123456", .developerIDAuthenticationFailed(
                "no expected Developer ID Team Identifier is configured"
            )),
            ("TEAM123456", nil, .developerIDAuthenticationFailed(
                "the signature does not contain a Team Identifier"
            )),
            ("TEAM123456", "OTHER98765", .developerIDAuthenticationFailed(
                "Team Identifier OTHER98765 does not match expected TEAM123456"
            ))
        ]

        for (expectedTeam, actualTeam, expectedError) in cases {
            let trustPolicy = RecordingTrustPolicy(decision: .preserve)
            let quarantine = RecordingQuarantineManager()
            let probe = ScriptedExecutionProbe([.succeeded])
            let signingIdentity = "Developer ID Application: Forge Example"
            let fixture = try installerFixture(
                probe: probe,
                quarantineManager: quarantine,
                securityLogger: RecordingSecurityLogger(),
                signatureInspector: RecordingSignatureInspector(inspections: [
                    RuntimeCodeSignatureInspection(
                        signatureClass: .developerID,
                        teamIdentifier: actualTeam,
                        signingIdentity: signingIdentity
                    )
                ]),
                trustPolicy: trustPolicy,
                developerIDAuthenticationPolicy: RuntimeDeveloperIDAuthenticationPolicy(
                    expectedTeamIdentifier: expectedTeam
                )
            )

            if let expectedError {
                do {
                    _ = try await fixture.installer.install(version: fixture.version)
                    XCTFail("expected Developer ID authentication failure")
                } catch let error as RuntimeInstallerError {
                    XCTAssertEqual(error, expectedError)
                }
                XCTAssertEqual(trustPolicy.contexts, [])
                XCTAssertEqual(quarantine.inspectedURLs, [])
                XCTAssertEqual(probe.callCount, 0)
                XCTAssertEqual(fixture.store.installCount, 0)
            } else {
                _ = try await fixture.installer.install(version: fixture.version)
                XCTAssertEqual(trustPolicy.contexts.count, 1)
                XCTAssertEqual(trustPolicy.contexts.first?.signature.teamIdentifier, expectedTeam)
                XCTAssertEqual(trustPolicy.contexts.first?.signature.signingIdentity, signingIdentity)
                XCTAssertEqual(quarantine.refreshedURLs, [])
                XCTAssertEqual(probe.callCount, 1)
                XCTAssertEqual(fixture.store.installCount, 1)
            }
        }
    }

    func testPreExecutionTrustPolicyRunsOnlyAfterFullExecutableValidation() async throws {
        let validator = RecordingValidator(error: .invalidMachO("rejected before policy"))
        let signatureInspector = RecordingSignatureInspector([.adHoc])
        let trustPolicy = RecordingTrustPolicy(decision: .refreshRemovingQuarantine)
        let quarantine = RecordingQuarantineManager()
        let probe = ScriptedExecutionProbe([.succeeded])
        let fixture = try installerFixture(
            probe: probe,
            quarantineManager: quarantine,
            securityLogger: RecordingSecurityLogger(),
            validator: validator,
            signatureInspector: signatureInspector,
            trustPolicy: trustPolicy
        )

        do {
            _ = try await fixture.installer.install(version: fixture.version)
            XCTFail("expected Mach-O validation failure")
        } catch let error as RuntimeInstallerError {
            XCTAssertEqual(error, .invalidMachO("rejected before policy"))
        }
        XCTAssertEqual(validator.calls.count, 1)
        XCTAssertEqual(signatureInspector.inspectedURLs, [])
        XCTAssertEqual(trustPolicy.contexts, [])
        XCTAssertEqual(quarantine.inspectedURLs, [])
        XCTAssertEqual(quarantine.refreshedURLs, [])
        XCTAssertEqual(probe.callCount, 0)
        XCTAssertEqual(fixture.store.installCount, 0)
    }

    func testTemporaryTrustPolicyRefreshesOnlyAdHocQuarantinedArtifactBeforeFirstProbe() async throws {
        let validator = RecordingValidator()
        let signatureInspector = RecordingSignatureInspector([.adHoc, .adHoc])
        let trustPolicy = RecordingTrustPolicy(decision: .refreshRemovingQuarantine)
        let quarantine = RecordingQuarantineManager()
        let securityLogger = RecordingSecurityLogger()
        let probe = ScriptedExecutionProbe([.succeeded])
        let fixture = try installerFixture(
            probe: probe,
            quarantineManager: quarantine,
            securityLogger: securityLogger,
            validator: validator,
            signatureInspector: signatureInspector,
            trustPolicy: trustPolicy
        )

        let installed = try await fixture.installer.install(version: fixture.version)

        XCTAssertEqual(installed.version, fixture.version)
        XCTAssertEqual(validator.calls.count, 2)
        XCTAssertEqual(signatureInspector.inspectedURLs.count, 2)
        XCTAssertEqual(trustPolicy.contexts.count, 1)
        XCTAssertEqual(trustPolicy.contexts.first?.signatureClass, .adHoc)
        XCTAssertNil(trustPolicy.contexts.first?.signature.teamIdentifier)
        XCTAssertNil(trustPolicy.contexts.first?.signature.signingIdentity)
        XCTAssertEqual(trustPolicy.contexts.first?.hasQuarantine, true)
        XCTAssertEqual(quarantine.refreshedURLs.count, 1)
        XCTAssertNotEqual(
            quarantine.refreshIdentities.first?.inode,
            try inode(quarantine.refreshedURLs[0])
        )
        XCTAssertEqual(probe.callCount, 1)
        XCTAssertEqual(securityLogger.events, [.refreshedAdHocQuarantinedStagedExecutable])
        XCTAssertEqual(fixture.store.installCount, 1)
    }

    func testOrderedValidationTracePlacesVersionBeforePolicyAndAllRefreshChecksBeforeProbe() async throws {
        let tracer = RecordingValidationTracer()
        let version = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.3"))
        let fixture = try installerFixture(
            probe: ScriptedExecutionProbe([.succeeded]),
            quarantineManager: RecordingQuarantineManager(),
            securityLogger: RecordingSecurityLogger(),
            validator: RecordingValidator(),
            versionInspector: RecordingVersionIdentityInspector([
                .success(RuntimeExecutableVersionIdentity(version: version)),
                .success(RuntimeExecutableVersionIdentity(version: version))
            ]),
            signatureInspector: RecordingSignatureInspector([.adHoc, .adHoc]),
            trustPolicy: TemporaryAdHocRuntimeTrustPolicy(),
            validationTracer: tracer
        )

        _ = try await fixture.installer.install(version: fixture.version)

        XCTAssertEqual(
            tracer.events,
            [
                .initialMachOValidated,
                .initialIdentityAndHashValidated,
                .initialVersionIdentityValidated,
                .initialSignatureClassInspected,
                .initialQuarantineInspected,
                .trustPolicyEvaluated,
                .stagedVnodeRefreshed,
                .postRefreshIdentityAndHashValidated,
                .postRefreshMachOValidated,
                .postRefreshVersionIdentityValidated,
                .postRefreshSignatureClassInspected,
                .postRefreshQuarantineValidated,
                .executionProbeStarted
            ]
        )
    }

    func testInitialAndPostRefreshVersionFailuresAreBarriersThatPreventPolicyOrProbe() async throws {
        let version = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.3"))

        do {
            let tracer = RecordingValidationTracer()
            let trustPolicy = RecordingTrustPolicy(decision: .refreshRemovingQuarantine)
            let probe = ScriptedExecutionProbe([.succeeded])
            let fixture = try installerFixture(
                probe: probe,
                quarantineManager: RecordingQuarantineManager(),
                securityLogger: RecordingSecurityLogger(),
                versionInspector: RecordingVersionIdentityInspector([
                    .failure(.invalidExecutableVersionIdentity("ambiguous"))
                ]),
                signatureInspector: RecordingSignatureInspector([.adHoc]),
                trustPolicy: trustPolicy,
                validationTracer: tracer
            )

            do {
                _ = try await fixture.installer.install(version: fixture.version)
                XCTFail("expected initial version identity failure")
            } catch let error as RuntimeInstallerError {
                XCTAssertEqual(error, .invalidExecutableVersionIdentity("ambiguous"))
            }
            XCTAssertEqual(
                tracer.events,
                [.initialMachOValidated, .initialIdentityAndHashValidated]
            )
            XCTAssertEqual(trustPolicy.contexts, [])
            XCTAssertEqual(probe.callCount, 0)
        }

        do {
            let tracer = RecordingValidationTracer()
            let probe = ScriptedExecutionProbe([.succeeded])
            let fixture = try installerFixture(
                probe: probe,
                quarantineManager: RecordingQuarantineManager(),
                securityLogger: RecordingSecurityLogger(),
                versionInspector: RecordingVersionIdentityInspector([
                    .success(RuntimeExecutableVersionIdentity(version: version)),
                    .failure(.invalidExecutableVersionIdentity("post-refresh malformed"))
                ]),
                signatureInspector: RecordingSignatureInspector([.adHoc, .adHoc]),
                trustPolicy: TemporaryAdHocRuntimeTrustPolicy(),
                validationTracer: tracer
            )

            do {
                _ = try await fixture.installer.install(version: fixture.version)
                XCTFail("expected post-refresh version identity failure")
            } catch let error as RuntimeInstallerError {
                XCTAssertEqual(error, .invalidExecutableVersionIdentity("post-refresh malformed"))
            }
            XCTAssertEqual(
                tracer.events,
                [
                    .initialMachOValidated,
                    .initialIdentityAndHashValidated,
                    .initialVersionIdentityValidated,
                    .initialSignatureClassInspected,
                    .initialQuarantineInspected,
                    .trustPolicyEvaluated,
                    .stagedVnodeRefreshed,
                    .postRefreshIdentityAndHashValidated,
                    .postRefreshMachOValidated
                ]
            )
            XCTAssertEqual(probe.callCount, 0)
        }
    }

    func testEveryPostRefreshValidationFailurePreventsExecutionProbe() async throws {
        let version = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.3"))

        struct Case {
            let name: String
            let validator: RecordingValidator
            let versionInspector: RecordingVersionIdentityInspector
            let signatureInspector: RecordingSignatureInspector
            let quarantineManager: RecordingQuarantineManager
            let expectedEvents: [RuntimeInstallerValidationEvent]
        }

        let cases = [
            Case(
                name: "identity/hash",
                validator: RecordingValidator(),
                versionInspector: RecordingVersionIdentityInspector([
                    .success(RuntimeExecutableVersionIdentity(version: version)),
                    .success(RuntimeExecutableVersionIdentity(version: version))
                ]),
                signatureInspector: RecordingSignatureInspector([.adHoc, .adHoc]),
                quarantineManager: RecordingQuarantineManager(
                    corruptReturnedHashAfterRefresh: true
                ),
                expectedEvents: [
                    .initialMachOValidated,
                    .initialIdentityAndHashValidated,
                    .initialVersionIdentityValidated,
                    .initialSignatureClassInspected,
                    .initialQuarantineInspected,
                    .trustPolicyEvaluated,
                    .stagedVnodeRefreshed
                ]
            ),
            Case(
                name: "Mach-O",
                validator: RecordingValidator(results: [
                    .success(()),
                    .failure(.invalidMachO("post-refresh rejected"))
                ]),
                versionInspector: RecordingVersionIdentityInspector([
                    .success(RuntimeExecutableVersionIdentity(version: version)),
                    .success(RuntimeExecutableVersionIdentity(version: version))
                ]),
                signatureInspector: RecordingSignatureInspector([.adHoc, .adHoc]),
                quarantineManager: RecordingQuarantineManager(),
                expectedEvents: [
                    .initialMachOValidated,
                    .initialIdentityAndHashValidated,
                    .initialVersionIdentityValidated,
                    .initialSignatureClassInspected,
                    .initialQuarantineInspected,
                    .trustPolicyEvaluated,
                    .stagedVnodeRefreshed,
                    .postRefreshIdentityAndHashValidated
                ]
            ),
            Case(
                name: "version identity",
                validator: RecordingValidator(),
                versionInspector: RecordingVersionIdentityInspector([
                    .success(RuntimeExecutableVersionIdentity(version: version)),
                    .failure(.invalidExecutableVersionIdentity("post-refresh malformed"))
                ]),
                signatureInspector: RecordingSignatureInspector([.adHoc, .adHoc]),
                quarantineManager: RecordingQuarantineManager(),
                expectedEvents: [
                    .initialMachOValidated,
                    .initialIdentityAndHashValidated,
                    .initialVersionIdentityValidated,
                    .initialSignatureClassInspected,
                    .initialQuarantineInspected,
                    .trustPolicyEvaluated,
                    .stagedVnodeRefreshed,
                    .postRefreshIdentityAndHashValidated,
                    .postRefreshMachOValidated
                ]
            ),
            Case(
                name: "signature class",
                validator: RecordingValidator(),
                versionInspector: RecordingVersionIdentityInspector([
                    .success(RuntimeExecutableVersionIdentity(version: version)),
                    .success(RuntimeExecutableVersionIdentity(version: version))
                ]),
                signatureInspector: RecordingSignatureInspector([.adHoc, .developerID]),
                quarantineManager: RecordingQuarantineManager(),
                expectedEvents: [
                    .initialMachOValidated,
                    .initialIdentityAndHashValidated,
                    .initialVersionIdentityValidated,
                    .initialSignatureClassInspected,
                    .initialQuarantineInspected,
                    .trustPolicyEvaluated,
                    .stagedVnodeRefreshed,
                    .postRefreshIdentityAndHashValidated,
                    .postRefreshMachOValidated,
                    .postRefreshVersionIdentityValidated
                ]
            ),
            Case(
                name: "quarantine removal",
                validator: RecordingValidator(),
                versionInspector: RecordingVersionIdentityInspector([
                    .success(RuntimeExecutableVersionIdentity(version: version)),
                    .success(RuntimeExecutableVersionIdentity(version: version))
                ]),
                signatureInspector: RecordingSignatureInspector([.adHoc, .adHoc]),
                quarantineManager: RecordingQuarantineManager(
                    forceQuarantinedAfterRefresh: true
                ),
                expectedEvents: [
                    .initialMachOValidated,
                    .initialIdentityAndHashValidated,
                    .initialVersionIdentityValidated,
                    .initialSignatureClassInspected,
                    .initialQuarantineInspected,
                    .trustPolicyEvaluated,
                    .stagedVnodeRefreshed,
                    .postRefreshIdentityAndHashValidated,
                    .postRefreshMachOValidated,
                    .postRefreshVersionIdentityValidated,
                    .postRefreshSignatureClassInspected
                ]
            )
        ]

        for testCase in cases {
            let tracer = RecordingValidationTracer()
            let probe = ScriptedExecutionProbe([.succeeded])
            let fixture = try installerFixture(
                probe: probe,
                quarantineManager: testCase.quarantineManager,
                securityLogger: RecordingSecurityLogger(),
                validator: testCase.validator,
                versionInspector: testCase.versionInspector,
                signatureInspector: testCase.signatureInspector,
                trustPolicy: TemporaryAdHocRuntimeTrustPolicy(),
                validationTracer: tracer
            )

            do {
                _ = try await fixture.installer.install(version: fixture.version)
                XCTFail("expected post-refresh \(testCase.name) failure")
            } catch {
                // Each injected failure is expected; the barrier assertions below are the security property.
            }
            XCTAssertEqual(tracer.events, testCase.expectedEvents, testCase.name)
            XCTAssertFalse(tracer.events.contains(.executionProbeStarted), testCase.name)
            XCTAssertEqual(probe.callCount, 0, testCase.name)
            XCTAssertEqual(fixture.store.installCount, 0, testCase.name)
        }
    }

    func testTemporaryTrustPolicyPreservesUnquarantinedAndDeveloperIDArtifacts() async throws {
        for (signatureClass, quarantined) in [
            (RuntimeCodeSignatureClass.adHoc, false),
            (.developerID, true)
        ] {
            let quarantine = RecordingQuarantineManager(quarantined: quarantined)
            let trustPolicy = RecordingTrustPolicy(decision: .preserve)
            let signatureInspector: any RuntimeCodeSignatureInspecting = signatureClass == .developerID
                ? matchingDeveloperIDSignatureInspector()
                : RecordingSignatureInspector([signatureClass])
            let authenticationPolicy = signatureClass == .developerID
                ? matchingDeveloperIDAuthenticationPolicy()
                : RuntimeDeveloperIDAuthenticationPolicy()
            let fixture = try installerFixture(
                probe: ScriptedExecutionProbe([.succeeded]),
                quarantineManager: quarantine,
                securityLogger: RecordingSecurityLogger(),
                signatureInspector: signatureInspector,
                trustPolicy: trustPolicy,
                developerIDAuthenticationPolicy: authenticationPolicy
            )

            _ = try await fixture.installer.install(version: fixture.version)

            XCTAssertEqual(trustPolicy.contexts.first?.signatureClass, signatureClass)
            XCTAssertEqual(trustPolicy.contexts.first?.hasQuarantine, quarantined)
            XCTAssertEqual(quarantine.refreshedURLs, [])
            XCTAssertEqual(fixture.store.installCount, 1)
        }
    }

    func testTrustPolicyCannotRequestRefreshOutsideAdHocQuarantinedCase() async throws {
        for (signatureClass, quarantined) in [
            (RuntimeCodeSignatureClass.developerID, true),
            (.adHoc, false)
        ] {
            let quarantine = RecordingQuarantineManager(quarantined: quarantined)
            let signatureInspector: any RuntimeCodeSignatureInspecting = signatureClass == .developerID
                ? matchingDeveloperIDSignatureInspector()
                : RecordingSignatureInspector([signatureClass])
            let authenticationPolicy = signatureClass == .developerID
                ? matchingDeveloperIDAuthenticationPolicy()
                : RuntimeDeveloperIDAuthenticationPolicy()
            let fixture = try installerFixture(
                probe: ScriptedExecutionProbe([.succeeded]),
                quarantineManager: quarantine,
                securityLogger: RecordingSecurityLogger(),
                signatureInspector: signatureInspector,
                trustPolicy: RecordingTrustPolicy(decision: .refreshRemovingQuarantine),
                developerIDAuthenticationPolicy: authenticationPolicy
            )

            do {
                _ = try await fixture.installer.install(version: fixture.version)
                XCTFail("expected policy boundary rejection")
            } catch let error as RuntimeInstallerError {
                XCTAssertEqual(
                    error,
                    .quarantineRemovalFailed(
                        "the pre-execution trust policy attempted quarantine removal outside the ad-hoc quarantined case"
                    )
                )
            }
            XCTAssertEqual(quarantine.refreshedURLs, [])
            XCTAssertEqual(fixture.store.installCount, 0)
        }
    }

    func testPostRefreshIdentityAndMachOAreRevalidatedBeforeProbe() async throws {
        let validator = RecordingValidator()
        let quarantine = RecordingQuarantineManager()
        let probe = ScriptedExecutionProbe([.succeeded])
        let fixture = try installerFixture(
            probe: probe,
            quarantineManager: quarantine,
            securityLogger: RecordingSecurityLogger(),
            validator: validator,
            signatureInspector: RecordingSignatureInspector([.adHoc, .adHoc]),
            trustPolicy: RecordingTrustPolicy(decision: .refreshRemovingQuarantine)
        )

        _ = try await fixture.installer.install(version: fixture.version)

        XCTAssertEqual(validator.calls.count, 2)
        XCTAssertEqual(quarantine.refreshedURLs.count, 1)
        XCTAssertEqual(probe.callCount, 1)
    }

    func testTimeoutAndLaunchFailureNeverTriggerQuarantineMutation() async throws {
        for (probeResult, expectedError) in [
            (
                RuntimeExecutionProbeResult.timedOut,
                RuntimeInstallerError.runtimeProbeFailed("forge3 --version timed out")
            ),
            (
                .executionUnavailable("operation not permitted"),
                .runtimeProbeFailed("forge3 --version could not launch: operation not permitted")
            )
        ] {
            let quarantine = RecordingQuarantineManager()
            let fixture = try installerFixture(
                probe: ScriptedExecutionProbe([probeResult]),
                quarantineManager: quarantine,
                securityLogger: RecordingSecurityLogger(),
                signatureInspector: RecordingSignatureInspector(inspections: [
                    RuntimeCodeSignatureInspection(
                        signatureClass: .developerID,
                        teamIdentifier: "TEAM123456",
                        signingIdentity: "Developer ID Application: Forge Example (TEAM123456)"
                    )
                ]),
                trustPolicy: RecordingTrustPolicy(decision: .preserve),
                developerIDAuthenticationPolicy: RuntimeDeveloperIDAuthenticationPolicy(
                    expectedTeamIdentifier: "TEAM123456"
                )
            )

            do {
                _ = try await fixture.installer.install(version: fixture.version)
                XCTFail("expected execution probe failure")
            } catch let error as RuntimeInstallerError {
                XCTAssertEqual(error, expectedError)
            }
            XCTAssertEqual(quarantine.refreshedURLs, [])
            XCTAssertEqual(fixture.store.installCount, 0)
        }
    }

    func testStagedExecutionProbeRejectsVersionMismatchWithoutQuarantineMutation() async throws {
        let expected = "forge3 1.2.3"
        let actual = "forge3 1.2.4"
        let quarantine = RecordingQuarantineManager()
        let fixture = try installerFixture(
            probe: ScriptedExecutionProbe([.versionMismatch(expected: expected, actual: actual)]),
            quarantineManager: quarantine,
            securityLogger: RecordingSecurityLogger(),
            signatureInspector: matchingDeveloperIDSignatureInspector(),
            trustPolicy: RecordingTrustPolicy(decision: .preserve),
            developerIDAuthenticationPolicy: matchingDeveloperIDAuthenticationPolicy()
        )

        do {
            _ = try await fixture.installer.install(version: fixture.version)
            XCTFail("expected version mismatch")
        } catch let error as RuntimeInstallerError {
            XCTAssertEqual(error, .runtimeProbeVersionMismatch(expected: expected, actual: actual))
        }
        XCTAssertEqual(quarantine.refreshedURLs, [])
        XCTAssertEqual(fixture.store.installCount, 0)
    }

    func testStagedExecutionProbeCancellationAfterPolicyDoesNotMutateAgainOrActivate() async throws {
        let probe = HoldingExecutionProbe()
        let quarantine = RecordingQuarantineManager(quarantined: false)
        let fixture = try installerFixture(
            probe: probe,
            quarantineManager: quarantine,
            securityLogger: RecordingSecurityLogger(),
            signatureInspector: matchingDeveloperIDSignatureInspector(),
            trustPolicy: RecordingTrustPolicy(decision: .preserve),
            developerIDAuthenticationPolicy: matchingDeveloperIDAuthenticationPolicy()
        )
        let task = Task { try await fixture.installer.install(version: fixture.version) }
        await probe.waitUntilStarted()

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as RuntimeInstallerError {
            XCTAssertEqual(error, .cancelled)
        }
        for _ in 0..<100 where !(await probe.wasCancelled()) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let probeWasCancelled = await probe.wasCancelled()
        XCTAssertTrue(probeWasCancelled)
        XCTAssertEqual(quarantine.refreshedURLs, [])
        XCTAssertEqual(fixture.store.installCount, 0)
    }

    func testStagedProbeRejectsReplacementAtAdjacentLaunchValidation() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let executable = directory.url.appendingPathComponent("forge3")
        let replacement = directory.url.appendingPathComponent("replacement")
        try Data("#!/bin/sh\nprintf 'forge3 1.2.3\\n'\n".utf8).write(to: executable)
        try Data("#!/bin/sh\nprintf 'forge3 1.2.3\\n'\n".utf8).write(to: replacement)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: replacement.path)
        let identity = try RuntimeExecutableIdentityValidator.capture(executable)
        let probe = BoundedRuntimeExecutionProbe(
            processRunner: POSIXRuntimeProcessRunner(
                launchHooks: RuntimePinnedLaunchHooks(beforeFinalIdentityValidation: {
                    try FileManager.default.removeItem(at: executable)
                    try FileManager.default.moveItem(at: replacement, to: executable)
                })
            ),
            timeout: 1,
            terminationGracePeriod: 0.1,
            maximumOutputBytes: 128
        )

        do {
            _ = try await probe.probe(
                executableURL: executable,
                expectedVersion: RuntimeReleaseVersion(rawValue: "1.2.3")!,
                expectedIdentity: identity
            )
            XCTFail("staged executable replacement must be rejected before spawn")
        } catch {
            XCTAssertEqual(
                error as? RuntimeInstallerError,
                .untrustedStoreItem("runtime executable identity changed at the launch boundary")
            )
        }
    }

    func testBoundedExecutionProbeUsesExactVersionCommandAndOutput() async throws {
        let version = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.3"))
        let runner = RecordingProcessRunner(results: [
            .success(RuntimeProcessResult(status: 0, stdout: Data("forge3 1.2.3\n".utf8))),
            .success(RuntimeProcessResult(status: 0, stdout: Data("forge3 1.2.3 \n".utf8)))
        ])
        let probe = BoundedRuntimeExecutionProbe(
            processRunner: runner,
            timeout: 0.25,
            terminationGracePeriod: 0.05,
            maximumOutputBytes: 128
        )
        let executable = URL(fileURLWithPath: "/private/tmp/staged/forge3")

        let exactResult = try await probe.probe(executableURL: executable, expectedVersion: version)
        let mismatchResult = try await probe.probe(executableURL: executable, expectedVersion: version)
        XCTAssertEqual(exactResult, .succeeded)
        XCTAssertEqual(
            mismatchResult,
            .versionMismatch(expected: "forge3 1.2.3", actual: "forge3 1.2.3 ")
        )
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.executable == executable })
        XCTAssertTrue(calls.allSatisfy { $0.arguments == ["--version"] })
        XCTAssertTrue(calls.allSatisfy { $0.standardOutput == nil })
        XCTAssertTrue(calls.allSatisfy { $0.maximumStandardOutputBytes == 128 })
        XCTAssertTrue(calls.allSatisfy { $0.timeout == 0.25 })
        XCTAssertTrue(calls.allSatisfy { $0.terminationGracePeriod == 0.05 })
    }

    func testDarwinQuarantineManagerAtomicallyRefreshesPinnedVnodeAndOmitsOnlyQuarantine() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let executable = directory.url.appendingPathComponent("forge3")
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let quarantine = Data("0081;00000000;Forge Menu Bar;https://install.forgecode.dev".utf8)
        let unrelated = Data("preserve-me".utf8)
        try setExtendedAttribute("com.apple.quarantine", value: quarantine, at: executable)
        try setExtendedAttribute("dev.forgecode.runtime-test", value: unrelated, at: executable)
        let originalIdentity = try RuntimeExecutableIdentityValidator.capture(executable)
        let originalData = try Data(contentsOf: executable)
        let originalPermissions = permissions(executable)

        let replacementIdentity = try DarwinRuntimeQuarantineManager()
            .refreshExecutableRemovingQuarantine(
                from: executable,
                expectedIdentity: originalIdentity
            )

        XCTAssertEqual(replacementIdentity.device, originalIdentity.device)
        XCTAssertNotEqual(replacementIdentity.inode, originalIdentity.inode)
        XCTAssertEqual(replacementIdentity.sha256, originalIdentity.sha256)
        XCTAssertEqual(try Data(contentsOf: executable), originalData)
        XCTAssertEqual(permissions(executable), originalPermissions)
        XCTAssertNil(try extendedAttribute("com.apple.quarantine", at: executable))
        XCTAssertEqual(try extendedAttribute("dev.forgecode.runtime-test", at: executable), unrelated)
        XCTAssertNoThrow(try RuntimeExecutableIdentityValidator.validate(executable, expected: replacementIdentity))
    }

    func testDarwinQuarantineManagerRejectsSymlinkHardLinkAndUnexpectedOwner() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let executable = directory.url.appendingPathComponent("forge3")
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try setExtendedAttribute(
            "com.apple.quarantine",
            value: Data("0081;test".utf8),
            at: executable
        )
        let identity = try RuntimeExecutableIdentityValidator.capture(executable)

        let symlink = directory.url.appendingPathComponent("forge3-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: executable)
        XCTAssertThrowsError(
            try DarwinRuntimeQuarantineManager().refreshExecutableRemovingQuarantine(
                from: symlink,
                expectedIdentity: identity
            )
        )

        let hardLink = directory.url.appendingPathComponent("forge3-hardlink")
        try FileManager.default.linkItem(at: executable, to: hardLink)
        XCTAssertThrowsError(
            try DarwinRuntimeQuarantineManager().refreshExecutableRemovingQuarantine(
                from: executable,
                expectedIdentity: identity
            )
        )
        try FileManager.default.removeItem(at: hardLink)

        XCTAssertThrowsError(
            try DarwinRuntimeQuarantineManager(expectedUserID: geteuid() &+ 1)
                .refreshExecutableRemovingQuarantine(
                    from: executable,
                    expectedIdentity: identity
                )
        )
        XCTAssertEqual(try extendedAttribute("com.apple.quarantine", at: executable), Data("0081;test".utf8))
        XCTAssertEqual(try inode(executable), identity.inode)
    }

    func testTypedFilesystemFailuresPreservePermissionDiskAndReadOnlyIdentity() {
        XCTAssertEqual(
            RuntimeFilesystemError.posix(EACCES, operation: "write", path: "/runtime"),
            .filesystem(operation: "write", path: "/runtime", failure: .permissionDenied)
        )
        XCTAssertEqual(
            RuntimeFilesystemError.posix(ENOSPC, operation: "write", path: "/runtime"),
            .filesystem(operation: "write", path: "/runtime", failure: .diskFull)
        )
        XCTAssertEqual(
            RuntimeFilesystemError.posix(EROFS, operation: "write", path: "/runtime"),
            .filesystem(operation: "write", path: "/runtime", failure: .readOnlyFilesystem)
        )
    }

    func testDefaultRuntimeRootUsesForgeCodeApplicationSupportDirectory() {
        let library = URL(fileURLWithPath: "/Users/example/Library", isDirectory: true)
        XCTAssertEqual(
            RuntimeStore.defaultRoot(libraryDirectory: library),
            library.appendingPathComponent("Application Support/ForgeCode/runtime", isDirectory: true)
        )
    }

    func testRealTarXZInspectionAcceptsValidAndRejectsCorruptMaliciousAndOversizedArchives() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let limits = RuntimeInstallerLimits(expandedArchiveBytes: 4_096, executableBytes: 1_024, archiveEntries: 8)
        let handler = SafeTarXZArchiveHandler(processTimeout: 5, terminationGracePeriod: 0.05)

        let valid = directory.url.appendingPathComponent("valid.tar.xz")
        try makeRealTarXZ(
            [TarFixture(path: "package/", type: "5", data: Data()), TarFixture(path: "package/forge3", type: "0", data: Data("binary".utf8))],
            at: valid
        )
        let validTemp = directory.url.appendingPathComponent("valid-temp", isDirectory: true)
        try FileManager.default.createDirectory(at: validTemp, withIntermediateDirectories: false)
        let inspection = try await handler.inspect(archiveURL: valid, temporaryDirectory: validTemp, limits: limits)
        XCTAssertEqual(inspection.executableEntry.path, "package/forge3")

        let corrupt = directory.url.appendingPathComponent("corrupt.tar.xz")
        try Data([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00, 1, 2, 3]).write(to: corrupt)
        let corruptTemp = directory.url.appendingPathComponent("corrupt-temp", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptTemp, withIntermediateDirectories: false)
        do {
            _ = try await handler.inspect(archiveURL: corrupt, temporaryDirectory: corruptTemp, limits: limits)
            XCTFail("expected corrupt archive rejection")
        } catch {}

        let malicious = directory.url.appendingPathComponent("malicious.tar.xz")
        try makeRealTarXZ([TarFixture(path: "../forge3", type: "0", data: Data())], at: malicious)
        let maliciousTemp = directory.url.appendingPathComponent("malicious-temp", isDirectory: true)
        try FileManager.default.createDirectory(at: maliciousTemp, withIntermediateDirectories: false)
        do {
            _ = try await handler.inspect(archiveURL: malicious, temporaryDirectory: maliciousTemp, limits: limits)
            XCTFail("expected malicious archive rejection")
        } catch {}

        let oversized = directory.url.appendingPathComponent("oversized.tar.xz")
        try makeRealTarXZ([TarFixture(path: "forge3", type: "0", data: Data(repeating: 7, count: 1_025))], at: oversized)
        let oversizedTemp = directory.url.appendingPathComponent("oversized-temp", isDirectory: true)
        try FileManager.default.createDirectory(at: oversizedTemp, withIntermediateDirectories: false)
        do {
            _ = try await handler.inspect(archiveURL: oversized, temporaryDirectory: oversizedTemp, limits: limits)
            XCTFail("expected oversized archive rejection")
        } catch let error as RuntimeInstallerError {
            guard case .archiveLimitExceeded = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testArchiveInspectionCancellationTerminatesAndReapsRunner() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let archive = directory.url.appendingPathComponent("held.tar.xz")
        try Data([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]).write(to: archive)
        let temporary = directory.url.appendingPathComponent("temp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let runner = HoldingProcessRunner()
        let handler = SafeTarXZArchiveHandler(processRunner: runner, processTimeout: 10, terminationGracePeriod: 0.01)
        let task = Task {
            try await handler.inspect(archiveURL: archive, temporaryDirectory: temporary, limits: RuntimeInstallerLimits())
        }
        await runner.waitUntilStarted()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as RuntimeInstallerError {
            XCTAssertEqual(error, .cancelled)
        }
        let runnerCancelled = await runner.wasCancelled()
        XCTAssertTrue(runnerCancelled)
    }

    func testProcessRunnerTimesOutTerminatesKillsAndReapsIgnoringProcess() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let script = directory.url.appendingPathComponent("ignore-term.sh")
        try "#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        for runner in [
            FoundationRuntimeProcessRunner() as any RuntimeProcessRunning,
            POSIXRuntimeProcessRunner() as any RuntimeProcessRunning
        ] {
            let started = Date()
            do {
                _ = try await runner.run(
                    executable: script,
                    arguments: [],
                    standardOutput: nil,
                    maximumStandardOutputBytes: 1_024,
                    timeout: 0.1,
                    terminationGracePeriod: 0.05
                )
                XCTFail("expected timeout")
            } catch let error as RuntimeInstallerError {
                XCTAssertEqual(error, .processTimeout)
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        }
    }

    func testPOSIXProcessRunnerCancellationTerminatesAndReapsChild() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let pidURL = directory.url.appendingPathComponent("pid")
        let script = directory.url.appendingPathComponent("hold.sh")
        try "#!/bin/sh\necho $$ > \"$1\"\ntrap '' TERM\nwhile :; do sleep 1; done\n".write(
            to: script,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let task = Task {
            try await POSIXRuntimeProcessRunner().run(
                executable: script,
                arguments: [pidURL.path],
                standardOutput: nil,
                maximumStandardOutputBytes: 1_024,
                timeout: 30,
                terminationGracePeriod: 0.05
            )
        }
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: pidURL.path) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidURL).trimmingCharacters(in: .whitespacesAndNewlines)))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as RuntimeInstallerError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testPOSIXProcessRunnerReturnsWhenEscapedDescendantRetainsPipes() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let script = directory.url.appendingPathComponent("escape-pipes.sh")
        try "#!/bin/sh\npython3 -c 'import os,time; os.setsid(); time.sleep(2)' &\nexit 0\n".write(
            to: script,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let started = Date()
        let result = try await POSIXRuntimeProcessRunner().run(
            executable: script,
            arguments: [],
            standardOutput: nil,
            maximumStandardOutputBytes: 1_024,
            timeout: 1,
            terminationGracePeriod: 0.05
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.75)
    }

    func testPOSIXProcessControlNeverSignalsAfterReap() {
        let signals = LockedValues<Int32>()
        let scheduled = LockedValues<@Sendable () -> Void>()
        let control = POSIXProcessControl(
            pid: 12345,
            gracePeriod: 0.1,
            sendSignal: { _, signal in signals.append(signal) },
            schedule: { _, action in scheduled.append(action) }
        )
        control.requestTermination()
        control.markReaped()
        scheduled.values.forEach { $0() }
        XCTAssertEqual(signals.values, [SIGTERM])
    }

    func testPOSIXProcessRunnerEnforcesCapturedOutputLimit() async throws {
        let result = try await POSIXRuntimeProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: [],
            standardOutput: nil,
            maximumStandardOutputBytes: 16_384,
            timeout: 5,
            terminationGracePeriod: 0.05
        )
        XCTAssertTrue(result.standardOutputLimitExceeded)
        XCTAssertEqual(result.stdout.count, 16_384)
    }

    func testProcessRunnerEnforcesStandardOutputLimit() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let output = directory.url.appendingPathComponent("output")
        let result = try await FoundationRuntimeProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: [],
            standardOutput: output,
            maximumStandardOutputBytes: 16_384
        )
        XCTAssertTrue(result.standardOutputLimitExceeded)
        let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertLessThanOrEqual(size, 16_384)
    }

    func testRuntimeStoreLeaseCoordinatesAcrossProcessesAndReleasesOnCrash() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let root = directory.url.appendingPathComponent("runtime")
        let lease = RuntimeStoreLease(rootURL: root)
        let shared = try lease.acquire(.sharedExecution)
        XCTAssertEqual(fcntl(shared.descriptor, F_GETFD) & FD_CLOEXEC, FD_CLOEXEC)

        let blockedMarker = directory.url.appendingPathComponent("exclusive-acquired")
        let blockedPID = try spawnLeaseChild(
            rootURL: root,
            mode: "exclusive",
            markerURL: blockedMarker
        )
        defer { terminateAndReap(blockedPID) }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blockedMarker.path))
        shared.release()
        try await waitForFileExists(blockedMarker)
        _ = waitForChild(blockedPID)

        let crashMarker = directory.url.appendingPathComponent("shared-acquired")
        let crashPID = try spawnLeaseChild(
            rootURL: root,
            mode: "shared",
            markerURL: crashMarker,
            hold: true
        )
        try await waitForFileExists(crashMarker)
        let exclusiveTask = Task.detached { try lease.acquire(.exclusiveMutation) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(exclusiveTask.isCancelled)
        _ = kill(crashPID, SIGKILL)
        _ = waitForChild(crashPID)
        let exclusive = try await exclusiveTask.value
        exclusive.release()
    }

    func testInstalledRuntimeIdentityDetectsHardLinkAndReplacementBeforeLaunch() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let executable = directory.url.appendingPathComponent("forge3")
        try Data("one".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let identity = try RuntimeExecutableIdentityValidator.capture(executable)
        let runtime = InstalledRuntime(
            version: RuntimeReleaseVersion(rawValue: "1.2.3")!,
            architecture: .arm64,
            executableURL: executable,
            executableIdentity: identity
        )
        XCTAssertNoThrow(try runtime.validateExecutableIdentity())

        let link = directory.url.appendingPathComponent("forge3-link")
        try FileManager.default.linkItem(at: executable, to: link)
        XCTAssertThrowsError(try runtime.validateExecutableIdentity())
        try FileManager.default.removeItem(at: link)
        try FileManager.default.removeItem(at: executable)
        try Data("two".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        XCTAssertThrowsError(try runtime.validateExecutableIdentity())
    }

    private func installerFixture(
        probe: any RuntimeExecutionProbing,
        quarantineManager: any RuntimeQuarantineManaging,
        securityLogger: any RuntimeInstallationSecurityLogging,
        validator: any RuntimeExecutableValidating = StubValidator(),
        versionInspector: any RuntimeExecutableVersionIdentityInspecting = ExpectedVersionIdentityInspector(),
        signatureInspector: any RuntimeCodeSignatureInspecting = UnsignedRuntimeCodeSignatureInspector(),
        trustPolicy: any RuntimePreExecutionTrustPolicy = TemporaryAdHocRuntimeTrustPolicy(),
        validationTracer: any RuntimeInstallerValidationTracing = NoOpRuntimeInstallerValidationTracer(),
        developerIDAuthenticationPolicy: RuntimeDeveloperIDAuthenticationPolicy = RuntimeDeveloperIDAuthenticationPolicy(),
        developerIDRequirementEvaluator: any RuntimeDeveloperIDRequirementEvaluating = RecordingDeveloperIDRequirementEvaluator(results: [.success(true)]),
        progressDeliveryHook: any RuntimeInstallerProgressDeliveryHook = NoOpRuntimeInstallerProgressDeliveryHook()
    ) throws -> (installer: RuntimeInstaller, version: RuntimeReleaseVersion, store: MockStore) {
        let version = try XCTUnwrap(RuntimeReleaseVersion(rawValue: "1.2.3"))
        let archiveData = Data("probe-archive".utf8)
        let archiveURL = RuntimeReleaseURLs.archive(version: version, architecture: .arm64)
        let checksumURL = RuntimeReleaseURLs.checksum(version: version, architecture: .arm64)
        let network = MockNetwork(responses: [
            archiveURL: archiveData,
            checksumURL: Data("\(RuntimeSHA256.hexDigest(of: archiveData)) *\(RuntimeArchitecture.arm64.archiveName)\n".utf8)
        ])
        let store = MockStore()
        let installer = RuntimeInstaller(
            architecture: .arm64,
            dependencies: .init(
                network: network,
                store: store,
                archive: MockArchive(executable: Data("probe-executable".utf8)),
                validator: validator,
                versionInspector: versionInspector,
                signatureInspector: signatureInspector,
                trustPolicy: trustPolicy,
                executionProbe: probe,
                quarantineManager: quarantineManager,
                securityLogger: securityLogger,
                validationTracer: validationTracer,
                developerIDAuthenticationPolicy: developerIDAuthenticationPolicy,
                developerIDRequirementEvaluator: developerIDRequirementEvaluator,
                progressDeliveryHook: progressDeliveryHook
            )
        )
        return (installer, version, store)
    }
}

private func matchingDeveloperIDSignatureInspector() -> RecordingSignatureInspector {
    RecordingSignatureInspector(inspections: [
        RuntimeCodeSignatureInspection(
            signatureClass: .developerID,
            teamIdentifier: "TEAM123456",
            signingIdentity: "Developer ID Application: Forge Example (TEAM123456)"
        )
    ])
}

private func matchingDeveloperIDAuthenticationPolicy() -> RuntimeDeveloperIDAuthenticationPolicy {
    RuntimeDeveloperIDAuthenticationPolicy(expectedTeamIdentifier: "TEAM123456")
}

private func networkClient() -> URLSessionRuntimeNetworkClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScriptedURLProtocol.self]
    return URLSessionRuntimeNetworkClient(configuration: configuration, requestTimeout: 0.2, resourceTimeout: 0.5)
}

private final class ScriptedURLProtocol: URLProtocol, @unchecked Sendable {
    enum Plan {
        case response(status: Int, headers: [String: String], chunks: [Data])
        case redirect(URL)
        case failure(Error)
        case hold
    }

    private static let lock = NSLock()
    private static var plans: [URL: Plan] = [:]
    private static var started: Set<URL> = []
    private static var stopped: Set<URL> = []
    private static var startWaiters: [URL: [CheckedContinuation<Void, Never>]] = [:]
    private let stateLock = NSLock()
    private var stoppedLocally = false

    static func install(_ plans: [URL: Plan]) {
        lock.withLock { self.plans = plans }
    }

    static func reset() {
        lock.withLock {
            plans = [:]
            started = []
            stopped = []
            startWaiters.values.flatMap { $0 }.forEach { $0.resume() }
            startWaiters = [:]
        }
    }

    static func waitUntilStarted(_ url: URL) async {
        if lock.withLock({ started.contains(url) }) { return }
        await withCheckedContinuation { continuation in
            lock.withLock {
                if started.contains(url) { continuation.resume() }
                else { startWaiters[url, default: []].append(continuation) }
            }
        }
    }

    static func waitUntilStopped(_ url: URL) async -> Bool {
        for _ in 0..<200 {
            if lock.withLock({ stopped.contains(url) }) { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return lock.withLock { stopped.contains(url) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let plan: Plan? = Self.lock.withLock {
            Self.started.insert(url)
            let waiters = Self.startWaiters.removeValue(forKey: url) ?? []
            waiters.forEach { $0.resume() }
            return Self.plans[url]
        }
        guard let plan else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        switch plan {
        case .response(let status, let headers, let chunks):
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks where !stateLock.withLock({ stoppedLocally }) {
                client?.urlProtocol(self, didLoad: chunk)
            }
            if !stateLock.withLock({ stoppedLocally }) { client?.urlProtocolDidFinishLoading(self) }
        case .redirect(let destination):
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString]
            ) else { return }
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .hold:
            break
        }
    }

    override func stopLoading() {
        stateLock.withLock { stoppedLocally = true }
        if let url = request.url { _ = Self.lock.withLock { Self.stopped.insert(url) } }
    }
}

private final class StubValidator: RuntimeExecutableValidating, @unchecked Sendable {
    func validate(executableURL: URL, expectedArchitecture: RuntimeArchitecture) throws {}
}

private final class RecordingValidator: RuntimeExecutableValidating, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Void, RuntimeInstallerError>]
    private var storedCalls: [(URL, RuntimeArchitecture)] = []

    init(error: RuntimeInstallerError? = nil) {
        results = error.map { [.failure($0)] } ?? []
    }

    init(results: [Result<Void, RuntimeInstallerError>]) {
        self.results = results
    }

    var calls: [(URL, RuntimeArchitecture)] { lock.withLock { storedCalls } }

    func validate(executableURL: URL, expectedArchitecture: RuntimeArchitecture) throws {
        try lock.withLock {
            storedCalls.append((executableURL, expectedArchitecture))
            if !results.isEmpty { try results.removeFirst().get() }
        }
    }
}

private final class ExpectedVersionIdentityInspector: RuntimeExecutableVersionIdentityInspecting, @unchecked Sendable {
    func inspectVersionIdentity(
        of executableURL: URL,
        expectedVersion: RuntimeReleaseVersion,
        expectedIdentity: RuntimeExecutableIdentity
    ) throws -> RuntimeExecutableVersionIdentity {
        try RuntimeExecutableIdentityValidator.validate(executableURL, expected: expectedIdentity)
        return RuntimeExecutableVersionIdentity(version: expectedVersion)
    }
}

private final class RecordingVersionIdentityInspector: RuntimeExecutableVersionIdentityInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<RuntimeExecutableVersionIdentity, RuntimeInstallerError>]
    private var storedCalls: [(URL, RuntimeReleaseVersion, RuntimeExecutableIdentity)] = []

    init(_ results: [Result<RuntimeExecutableVersionIdentity, RuntimeInstallerError>]) {
        self.results = results
    }

    var calls: [(URL, RuntimeReleaseVersion, RuntimeExecutableIdentity)] { lock.withLock { storedCalls } }

    func inspectVersionIdentity(
        of executableURL: URL,
        expectedVersion: RuntimeReleaseVersion,
        expectedIdentity: RuntimeExecutableIdentity
    ) throws -> RuntimeExecutableVersionIdentity {
        try RuntimeExecutableIdentityValidator.validate(executableURL, expected: expectedIdentity)
        return try lock.withLock {
            storedCalls.append((executableURL, expectedVersion, expectedIdentity))
            if results.isEmpty {
                return RuntimeExecutableVersionIdentity(version: expectedVersion)
            }
            return try results.removeFirst().get()
        }
    }
}

private final class RecordingDeveloperIDRequirementEvaluator: RuntimeDeveloperIDRequirementEvaluating, @unchecked Sendable {
    struct Call: Equatable {
        let executableURL: URL
        let expectedTeamIdentifier: String?
    }

    private let lock = NSLock()
    private var results: [Result<Bool, RuntimeInstallerError>]
    private var storedCalls: [Call] = []

    init(results: [Result<Bool, RuntimeInstallerError>]) {
        self.results = results
    }

    var calls: [Call] { lock.withLock { storedCalls } }

    func satisfiesDeveloperIDApplicationRequirement(
        executableURL: URL,
        expectedTeamIdentifier: String?
    ) throws -> Bool {
        try lock.withLock {
            storedCalls.append(Call(
                executableURL: executableURL,
                expectedTeamIdentifier: expectedTeamIdentifier
            ))
            return try (results.isEmpty ? .success(false) : results.removeFirst()).get()
        }
    }
}

private final class RecordingSignatureInspector: RuntimeCodeSignatureInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var inspections: [RuntimeCodeSignatureInspection]
    private var storedURLs: [URL] = []

    init(_ classes: [RuntimeCodeSignatureClass]) {
        inspections = classes.map { RuntimeCodeSignatureInspection(signatureClass: $0) }
    }

    init(inspections: [RuntimeCodeSignatureInspection]) {
        self.inspections = inspections
    }

    var inspectedURLs: [URL] { lock.withLock { storedURLs } }

    func inspectSignature(of executableURL: URL) throws -> RuntimeCodeSignatureInspection {
        lock.withLock {
            storedURLs.append(executableURL)
            return inspections.isEmpty
                ? RuntimeCodeSignatureInspection(signatureClass: .unsigned)
                : inspections.removeFirst()
        }
    }
}

private final class RecordingValidationTracer: RuntimeInstallerValidationTracing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [RuntimeInstallerValidationEvent] = []

    var events: [RuntimeInstallerValidationEvent] { lock.withLock { storedEvents } }

    func record(_ event: RuntimeInstallerValidationEvent) {
        lock.withLock { storedEvents.append(event) }
    }
}

private final class RecordingTrustPolicy: RuntimePreExecutionTrustPolicy, @unchecked Sendable {
    private let lock = NSLock()
    private let decision: RuntimePreExecutionTrustDecision
    private var storedContexts: [RuntimePreExecutionTrustContext] = []

    init(decision: RuntimePreExecutionTrustDecision) {
        self.decision = decision
    }

    var contexts: [RuntimePreExecutionTrustContext] { lock.withLock { storedContexts } }

    func decision(for context: RuntimePreExecutionTrustContext) throws -> RuntimePreExecutionTrustDecision {
        lock.withLock { storedContexts.append(context) }
        return decision
    }
}

private actor MockNetwork: RuntimeNetworkClient {
    let responses: [URL: Data]
    let delayNanoseconds: UInt64
    private(set) var requestedURLs: [URL] = []
    var requestCount: Int { requestedURLs.count }

    init(responses: [URL: Data], delayNanoseconds: UInt64 = 0) {
        self.responses = responses
        self.delayNanoseconds = delayNanoseconds
    }

    func download(
        _ request: RuntimeDownloadRequest,
        progress: @escaping RuntimeDownloadProgressHandler
    ) async throws -> RuntimeDownload {
        requestedURLs.append(request.url)
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        guard let data = responses[request.url] else { throw RuntimeInstallerError.network("unexpected URL") }
        guard Int64(data.count) <= request.maximumBytes else { throw RuntimeInstallerError.responseTooLarge(limit: request.maximumBytes) }
        await progress(0, Int64(data.count))
        await progress(Int64(data.count), Int64(data.count))
        return RuntimeDownload(data: data, responseURL: request.url)
    }
}

private actor ReplayRaceNetwork: RuntimeNetworkClient {
    private let version: RuntimeReleaseVersion
    private var manifestRequested = false
    private var manifestWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseManifestWaiters: [CheckedContinuation<Void, Never>] = []
    private var manifestReleased = false

    init(version: RuntimeReleaseVersion) {
        self.version = version
    }

    func download(
        _ request: RuntimeDownloadRequest,
        progress: @escaping RuntimeDownloadProgressHandler
    ) async throws -> RuntimeDownload {
        if request.url == RuntimeReleaseURLs.latestManifest {
            manifestRequested = true
            manifestWaiters.forEach { $0.resume() }
            manifestWaiters.removeAll()
            if !manifestReleased {
                await withCheckedContinuation { releaseManifestWaiters.append($0) }
            }
            let data = Data("{\"version\":\"\(version.rawValue)\"}".utf8)
            return RuntimeDownload(data: data, responseURL: request.url)
        }
        let archive = Data("race-archive".utf8)
        let data = request.url.path.hasSuffix(".sha256")
            ? Data("\(RuntimeSHA256.hexDigest(of: archive)) *\(RuntimeArchitecture.arm64.archiveName)\n".utf8)
            : archive
        await progress(0, Int64(data.count))
        await progress(Int64(data.count), Int64(data.count))
        return RuntimeDownload(data: data, responseURL: request.url)
    }

    func waitUntilManifestRequested() async {
        if manifestRequested { return }
        await withCheckedContinuation { manifestWaiters.append($0) }
    }

    func releaseManifest() {
        manifestReleased = true
        releaseManifestWaiters.forEach { $0.resume() }
        releaseManifestWaiters.removeAll()
    }
}

private actor BlockingReplayProgressHook: RuntimeInstallerProgressDeliveryHook {
    private var replayBlocked = false
    private var replayReleased = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var blockedReplayCount = 0

    func beforeDelivery(_ delivery: RuntimeInstallerProgressDelivery) async {
        guard delivery.kind == .replay, !replayBlocked else { return }
        replayBlocked = true
        blockedReplayCount += 1
        blockedWaiters.forEach { $0.resume() }
        blockedWaiters.removeAll()
        if !replayReleased {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
    }

    func waitUntilReplayBlocked() async {
        if replayBlocked { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func releaseReplay() {
        replayReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor SerializedInstallNetwork: RuntimeNetworkClient {
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRequestStarted = false
    private var releaseFirst = false
    private var activeVersions: Set<RuntimeReleaseVersion> = []
    private(set) var requestedVersions: [RuntimeReleaseVersion] = []
    private(set) var maximumConcurrentVersionCount = 0

    func download(
        _ request: RuntimeDownloadRequest,
        progress: @escaping RuntimeDownloadProgressHandler
    ) async throws -> RuntimeDownload {
        guard let version = releaseVersion(from: request.url) else {
            throw RuntimeInstallerError.network("missing release version in test URL")
        }
        if activeVersions.insert(version).inserted {
            requestedVersions.append(version)
            maximumConcurrentVersionCount = max(maximumConcurrentVersionCount, activeVersions.count)
        }
        if version.rawValue == "1.2.3", !releaseFirst {
            firstRequestStarted = true
            firstRequestWaiters.forEach { $0.resume() }
            firstRequestWaiters.removeAll()
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        let archive = Data("archive-\(version.rawValue)".utf8)
        let data: Data
        if request.url.path.hasSuffix(".sha256") {
            data = Data("\(RuntimeSHA256.hexDigest(of: archive)) *\(RuntimeArchitecture.arm64.archiveName)\n".utf8)
        } else {
            data = archive
        }
        await progress(0, Int64(data.count))
        await progress(Int64(data.count), Int64(data.count))
        return RuntimeDownload(data: data, responseURL: request.url)
    }

    func waitUntilFirstRequestStarted() async {
        if firstRequestStarted { return }
        await withCheckedContinuation { firstRequestWaiters.append($0) }
    }

    func releaseFirstVersion() {
        releaseFirst = true
        activeVersions.remove(RuntimeReleaseVersion(rawValue: "1.2.3")!)
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor CancellationHoldingNetwork: RuntimeNetworkClient {
    private let firstVersion: RuntimeReleaseVersion
    private var firstStarted = false
    private var firstStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseFirst = false
    private(set) var secondVersionStarted = false

    init(firstVersion: RuntimeReleaseVersion) {
        self.firstVersion = firstVersion
    }

    func download(
        _ request: RuntimeDownloadRequest,
        progress: @escaping RuntimeDownloadProgressHandler
    ) async throws -> RuntimeDownload {
        guard let version = releaseVersion(from: request.url) else {
            throw RuntimeInstallerError.network("missing release version in test URL")
        }
        if version == firstVersion, !releaseFirst {
            firstStarted = true
            firstStartWaiters.forEach { $0.resume() }
            firstStartWaiters.removeAll()
            await withCheckedContinuation { releaseWaiters.append($0) }
            try Task.checkCancellation()
        } else if version != firstVersion {
            secondVersionStarted = true
        }
        let archive = Data("archive-\(version.rawValue)".utf8)
        let data = request.url.path.hasSuffix(".sha256")
            ? Data("\(RuntimeSHA256.hexDigest(of: archive)) *\(RuntimeArchitecture.arm64.archiveName)\n".utf8)
            : archive
        await progress(0, Int64(data.count))
        await progress(Int64(data.count), Int64(data.count))
        return RuntimeDownload(data: data, responseURL: request.url)
    }

    func waitUntilFirstVersionStarted() async {
        if firstStarted { return }
        await withCheckedContinuation { firstStartWaiters.append($0) }
    }

    func releaseCancelledFirstVersion() {
        releaseFirst = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private func releaseVersion(from url: URL) -> RuntimeReleaseVersion? {
    url.pathComponents
        .first(where: { $0.hasPrefix("v") })
        .flatMap { RuntimeReleaseVersion(rawValue: String($0.dropFirst())) }
}

private actor CancellingNetwork: RuntimeNetworkClient {
    private var requested = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func download(
        _ request: RuntimeDownloadRequest,
        progress: @escaping RuntimeDownloadProgressHandler
    ) async throws -> RuntimeDownload {
        requested = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        await withCheckedContinuation { releaseWaiters.append($0) }
        try Task.checkCancellation()
        return RuntimeDownload(data: Data(), responseURL: request.url)
    }

    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private final class MockStore: RuntimeStoreManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var cachedRuntime: InstalledRuntime?
    private var storedInstallCount = 0
    private let directory: TemporaryDirectory

    var installCount: Int { lock.withLock { storedInstallCount } }

    init(cached: InstalledRuntime? = nil) {
        cachedRuntime = cached
        directory = try! TemporaryDirectory()
    }

    deinit { directory.remove() }

    func cached(version: RuntimeReleaseVersion, architecture: RuntimeArchitecture) throws -> InstalledRuntime? {
        lock.withLock {
            guard cachedRuntime?.version == version, cachedRuntime?.architecture == architecture else { return nil }
            return cachedRuntime
        }
    }

    func current(architecture: RuntimeArchitecture) throws -> InstalledRuntime? {
        lock.withLock { cachedRuntime }
    }

    func makePrivateTemporaryDirectory() throws -> URL {
        let url = directory.url.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    func installStagedRuntime(executableURL: URL, receipt: RuntimeStoreReceipt, temporaryDirectory: URL) throws -> InstalledRuntime {
        lock.withLock {
            storedInstallCount += 1
            let installed = InstalledRuntime(version: receipt.version, architecture: receipt.architecture, executableURL: executableURL)
            cachedRuntime = installed
            return installed
        }
    }
}

private final class ScriptedExecutionProbe: RuntimeExecutionProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [RuntimeExecutionProbeResult]
    private var storedCallCount = 0

    init(_ results: [RuntimeExecutionProbeResult]) {
        self.results = results
    }

    var callCount: Int { lock.withLock { storedCallCount } }

    func probe(
        executableURL: URL,
        expectedVersion: RuntimeReleaseVersion
    ) async throws -> RuntimeExecutionProbeResult {
        try Task.checkCancellation()
        return lock.withLock {
            storedCallCount += 1
            return results.isEmpty ? .failed("unexpected probe call") : results.removeFirst()
        }
    }
}

private actor HoldingExecutionProbe: RuntimeExecutionProbing {
    private var started = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func probe(
        executableURL: URL,
        expectedVersion: RuntimeReleaseVersion
    ) async throws -> RuntimeExecutionProbeResult {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        do {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        } catch {
            cancelled = true
            throw RuntimeInstallerError.cancelled
        }
        return .succeeded
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func wasCancelled() -> Bool { cancelled }
}

private final class RecordingQuarantineManager: RuntimeQuarantineManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var storedInspectedURLs: [URL] = []
    private var storedRefreshURLs: [URL] = []
    private var storedRefreshIdentities: [RuntimeExecutableIdentity] = []
    private let error: RuntimeInstallerError?
    private let quarantined: Bool
    private let performRealRefresh: Bool
    private let replacementIdentityOverride: RuntimeExecutableIdentity?
    private let corruptReturnedHashAfterRefresh: Bool
    private let forceQuarantinedAfterRefresh: Bool

    init(
        error: RuntimeInstallerError? = nil,
        quarantined: Bool = true,
        performRealRefresh: Bool = true,
        replacementIdentityOverride: RuntimeExecutableIdentity? = nil,
        corruptReturnedHashAfterRefresh: Bool = false,
        forceQuarantinedAfterRefresh: Bool = false
    ) {
        self.error = error
        self.quarantined = quarantined
        self.performRealRefresh = performRealRefresh
        self.replacementIdentityOverride = replacementIdentityOverride
        self.corruptReturnedHashAfterRefresh = corruptReturnedHashAfterRefresh
        self.forceQuarantinedAfterRefresh = forceQuarantinedAfterRefresh
    }

    var inspectedURLs: [URL] { lock.withLock { storedInspectedURLs } }
    var refreshedURLs: [URL] { lock.withLock { storedRefreshURLs } }
    var refreshIdentities: [RuntimeExecutableIdentity] { lock.withLock { storedRefreshIdentities } }

    func hasQuarantine(
        at executableURL: URL,
        expectedIdentity: RuntimeExecutableIdentity
    ) throws -> Bool {
        let refreshed = lock.withLock { () -> Bool in
            storedInspectedURLs.append(executableURL)
            return !storedRefreshURLs.isEmpty
        }
        if forceQuarantinedAfterRefresh, refreshed { return true }
        if !quarantined { return false }
        return try DarwinRuntimeQuarantineManager().hasQuarantine(
            at: executableURL,
            expectedIdentity: expectedIdentity
        )
    }

    func refreshExecutableRemovingQuarantine(
        from executableURL: URL,
        expectedIdentity: RuntimeExecutableIdentity
    ) throws -> RuntimeExecutableIdentity {
        lock.withLock {
            storedRefreshURLs.append(executableURL)
            storedRefreshIdentities.append(expectedIdentity)
        }
        if let error { throw error }
        if let replacementIdentityOverride { return replacementIdentityOverride }
        if performRealRefresh {
            let refreshed = try DarwinRuntimeQuarantineManager().refreshExecutableRemovingQuarantine(
                from: executableURL,
                expectedIdentity: expectedIdentity
            )
            if corruptReturnedHashAfterRefresh {
                return RuntimeExecutableIdentity(
                    device: refreshed.device,
                    inode: refreshed.inode,
                    size: refreshed.size,
                    sha256: String(repeating: "0", count: 64)
                )
            }
            return refreshed
        }
        return expectedIdentity
    }
}

private final class RecordingSecurityLogger: RuntimeInstallationSecurityLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [RuntimeInstallationSecurityEvent] = []

    var events: [RuntimeInstallationSecurityEvent] { lock.withLock { storedEvents } }

    func log(_ event: RuntimeInstallationSecurityEvent) {
        lock.withLock { storedEvents.append(event) }
    }
}

private actor RecordingProcessRunner: RuntimeProcessRunning {
    struct Call: Sendable {
        let executable: URL
        let arguments: [String]
        let standardOutput: URL?
        let maximumStandardOutputBytes: Int
        let timeout: TimeInterval
        let terminationGracePeriod: TimeInterval
    }

    private var results: [Result<RuntimeProcessResult, RuntimeInstallerError>]
    private(set) var calls: [Call] = []

    init(results: [Result<RuntimeProcessResult, RuntimeInstallerError>]) {
        self.results = results
    }

    func run(
        executable: URL,
        arguments: [String],
        standardOutput: URL?,
        maximumStandardOutputBytes: Int,
        timeout: TimeInterval,
        terminationGracePeriod: TimeInterval
    ) async throws -> RuntimeProcessResult {
        calls.append(
            Call(
                executable: executable,
                arguments: arguments,
                standardOutput: standardOutput,
                maximumStandardOutputBytes: maximumStandardOutputBytes,
                timeout: timeout,
                terminationGracePeriod: terminationGracePeriod
            )
        )
        guard !results.isEmpty else { throw RuntimeInstallerError.processFailure("unexpected process call") }
        return try results.removeFirst().get()
    }
}

private actor HoldingProcessRunner: RuntimeProcessRunning {
    private var started = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func run(
        executable: URL,
        arguments: [String],
        standardOutput: URL?,
        maximumStandardOutputBytes: Int,
        timeout: TimeInterval,
        terminationGracePeriod: TimeInterval
    ) async throws -> RuntimeProcessResult {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        do {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        } catch {
            cancelled = true
            throw RuntimeInstallerError.cancelled
        }
        return RuntimeProcessResult(status: 0)
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func wasCancelled() -> Bool { cancelled }
}

private actor MockArchive: RuntimeArchiveHandling {
    let executable: Data
    private(set) var inspectCount = 0

    init(executable: Data = Data("fixture".utf8)) { self.executable = executable }

    func inspect(archiveURL: URL, temporaryDirectory: URL, limits: RuntimeInstallerLimits) async throws -> RuntimeArchiveInspection {
        inspectCount += 1
        let tar = temporaryDirectory.appendingPathComponent("mock.tar")
        let data = makeTar([TarFixture(path: "package/forge3", type: "0", data: executable)])
        try data.write(to: tar)
        return try SafeTarXZArchiveHandler.parseTar(data, tarURL: tar, limits: limits)
    }

    nonisolated func extractExecutable(from inspection: RuntimeArchiveInspection, to destination: URL) throws {
        try executable.write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
    }
}

private struct TemporaryDirectory {
    let url: URL

    init() throws {
        let template = FileManager.default.temporaryDirectory.appendingPathComponent("forge-runtime-tests.XXXXXX").path
        var bytes = Array(template.utf8CString)
        guard mkdtemp(&bytes) != nil else { throw POSIXError(.EIO) }
        url = URL(fileURLWithPath: String(cString: bytes), isDirectory: true)
    }

    func remove() {
        makeTreeOwnerWritable(url)
        try? FileManager.default.removeItem(at: url)
    }
}

private func makeTreeOwnerWritable(_ url: URL) {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return }
    if (info.st_mode & S_IFMT) == S_IFDIR {
        _ = chmod(url.path, 0o700)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
            for name in names {
                makeTreeOwnerWritable(url.appendingPathComponent(name))
            }
        }
    } else if (info.st_mode & S_IFMT) == S_IFREG {
        _ = chmod(url.path, 0o600)
    }
}

private struct TarFixture {
    let path: String
    let type: Character
    let data: Data
}

private func makeTar(_ entries: [TarFixture]) -> Data {
    var archive = Data()
    for entry in entries {
        var header = Data(repeating: 0, count: 512)
        write(entry.path, to: &header, range: 0..<100)
        write("0000700\0", to: &header, range: 100..<108)
        write("0000000\0", to: &header, range: 108..<116)
        write("0000000\0", to: &header, range: 116..<124)
        write(String(format: "%011o\0", entry.data.count), to: &header, range: 124..<136)
        write("00000000000\0", to: &header, range: 136..<148)
        write("        ", to: &header, range: 148..<156)
        header[156] = entry.type.asciiValue!
        write("ustar\0", to: &header, range: 257..<263)
        write("00", to: &header, range: 263..<265)
        let checksum = header.reduce(0) { $0 + Int($1) }
        write(String(format: "%06o\0 ", checksum), to: &header, range: 148..<156)
        archive.append(header)
        archive.append(entry.data)
        if entry.data.count % 512 != 0 {
            archive.append(Data(repeating: 0, count: 512 - entry.data.count % 512))
        }
    }
    archive.append(Data(repeating: 0, count: 1_024))
    return archive
}

private func makeRealTarXZ(_ entries: [TarFixture], at destination: URL) throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let tarURL = directory.url.appendingPathComponent("fixture.tar")
    try makeTar(entries).write(to: tarURL)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = ["-cJf", destination.path, "@\(tarURL.path)"]
    process.standardOutput = FileHandle.nullDevice
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    let diagnostic = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw RuntimeInstallerError.processFailure(diagnostic)
    }
}

private func write(_ string: String, to data: inout Data, range: Range<Int>) {
    let bytes = Array(string.utf8.prefix(range.count))
    data.replaceSubrange(range.lowerBound..<(range.lowerBound + bytes.count), with: bytes)
}

private func macho(architecture: RuntimeArchitecture) -> Data {
    let segmentSize = 72
    let mainSize = 24
    let commandsSize = segmentSize + mainSize
    let fileSize = 32 + commandsSize + 16
    var bytes = Data(repeating: 0, count: fileSize)
    putUInt32(0xfeedfacf, in: &bytes, at: 0)
    putUInt32(architecture == .arm64 ? 0x0100000c : 0x01000007, in: &bytes, at: 4)
    putUInt32(0, in: &bytes, at: 8)
    putUInt32(0x2, in: &bytes, at: 12)
    putUInt32(2, in: &bytes, at: 16)
    putUInt32(UInt32(commandsSize), in: &bytes, at: 20)

    putUInt32(0x19, in: &bytes, at: 32)
    putUInt32(UInt32(segmentSize), in: &bytes, at: 36)
    write("__TEXT", to: &bytes, range: 40..<56)
    putUInt64(0x100000000, in: &bytes, at: 56)
    putUInt64(UInt64(fileSize), in: &bytes, at: 64)
    putUInt64(0, in: &bytes, at: 72)
    putUInt64(UInt64(fileSize), in: &bytes, at: 80)
    putUInt32(0x5, in: &bytes, at: 88)
    putUInt32(0x5, in: &bytes, at: 92)

    let mainOffset = 32 + segmentSize
    putUInt32(0x80000028, in: &bytes, at: mainOffset)
    putUInt32(UInt32(mainSize), in: &bytes, at: mainOffset + 4)
    putUInt64(UInt64(32 + commandsSize), in: &bytes, at: mainOffset + 8)
    bytes[32 + commandsSize] = 0xc3
    return bytes
}

private func putUInt32(_ value: UInt32, in data: inout Data, at offset: Int) {
    for index in 0..<4 { data[offset + index] = UInt8((value >> UInt32(index * 8)) & 0xff) }
}

private func putUInt64(_ value: UInt64, in data: inout Data, at offset: Int) {
    for index in 0..<8 { data[offset + index] = UInt8((value >> UInt64(index * 8)) & 0xff) }
}

private func machOCodeSignatureRange(_ data: Data) -> Range<Int>? {
    guard data.count >= 32 else { return nil }
    func u32(_ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | (UInt32(data[offset + $1]) << UInt32($1 * 8)) }
    }
    let commandCount = Int(u32(16))
    var offset = 32
    for _ in 0..<commandCount {
        guard offset + 8 <= data.count else { return nil }
        let command = u32(offset)
        let size = Int(u32(offset + 4))
        guard size >= 8, offset + size <= data.count else { return nil }
        if command == 0x1d {
            let signatureOffset = Int(u32(offset + 8))
            let signatureSize = Int(u32(offset + 12))
            guard signatureOffset <= data.count, signatureSize <= data.count - signatureOffset else { return nil }
            return signatureOffset..<(signatureOffset + signatureSize)
        }
        offset += size
    }
    return nil
}

private func spawnLeaseChild(
    rootURL: URL,
    mode: String,
    markerURL: URL,
    hold: Bool = false
) throws -> pid_t {
    let helperURL = try locateBuiltHelper(named: "ForgeRuntimeLeaseTestHelper")
    let arguments = [
        helperURL.path,
        rootURL.path,
        mode,
        markerURL.path,
        hold ? "hold" : "exit"
    ]
    var argv = arguments.map { strdup($0) } + [nil]
    defer { for pointer in argv where pointer != nil { free(pointer) } }
    var pid: pid_t = 0
    let result = posix_spawn(&pid, arguments[0], nil, nil, &argv, environ)
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    return pid
}

private func locateBuiltHelper(named name: String) throws -> URL {
    let testsURL = Bundle(for: RuntimeInstallerTests.self).bundleURL
    let candidates = [
        testsURL.deletingLastPathComponent().appendingPathComponent(name),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/\(name)")
    ]
    return try XCTUnwrap(
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) },
        "Could not locate \(name). Checked: \(candidates.map(\.path))"
    )
}

private func waitForFileExists(_ url: URL) async throws {
    for _ in 0..<200 {
        if FileManager.default.fileExists(atPath: url.path) { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("timed out waiting for \(url.path)")
}

@discardableResult
private func waitForChild(_ pid: pid_t) -> Int32 {
    var status: Int32 = 0
    var result: pid_t
    repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
    return status
}

private func terminateAndReap(_ pid: pid_t) {
    if waitpid(pid, nil, WNOHANG) == 0 {
        _ = kill(pid, SIGKILL)
        _ = waitForChild(pid)
    }
}

private func runTool(_ path: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    let diagnostic = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard process.terminationStatus == 0 else { throw RuntimeInstallerError.processFailure(diagnostic) }
}

private func setExtendedAttribute(_ name: String, value: Data, at url: URL) throws {
    let result = value.withUnsafeBytes { bytes in
        url.path.withCString { path in
            name.withCString { attributeName in
                setxattr(path, attributeName, bytes.baseAddress, value.count, 0, 0)
            }
        }
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

private func extendedAttribute(_ name: String, at url: URL) throws -> Data? {
    let size = url.path.withCString { path in
        name.withCString { attributeName in
            getxattr(path, attributeName, nil, 0, 0, 0)
        }
    }
    if size < 0 {
        if errno == ENOATTR { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var data = Data(count: size)
    let readCount = data.withUnsafeMutableBytes { bytes in
        url.path.withCString { path in
            name.withCString { attributeName in
                getxattr(path, attributeName, bytes.baseAddress, size, 0, 0)
            }
        }
    }
    guard readCount == size else { throw POSIXError(.EIO) }
    return data
}

private func permissions(_ url: URL) -> Int {
    let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as! NSNumber).intValue
}

private func inode(_ url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let number = attributes[.systemFileNumber] as? NSNumber else {
        throw RuntimeInstallerError.filesystem(
            operation: "read inode",
            path: url.path,
            failure: .other(nil)
        )
    }
    return number.uint64Value
}

private func installFixture(version: String, data: Data, store: RuntimeStore) throws -> InstalledRuntime {
    let parsed = try XCTUnwrap(RuntimeReleaseVersion(rawValue: version))
    let temporary = try store.makePrivateTemporaryDirectory()
    let executable = temporary.appendingPathComponent("forge3")
    try data.write(to: executable)
    return try store.installStagedRuntime(
        executableURL: executable,
        receipt: RuntimeStoreReceipt(
            version: parsed,
            architecture: .arm64,
            archiveSHA256: String(repeating: "a", count: 64),
            executableSHA256: RuntimeSHA256.hexDigest(of: data)
        ),
        temporaryDirectory: temporary
    )
}

private extension RuntimeInstallationPhase {
    var testName: String {
        switch self {
        case .resolving: return "resolving"
        case .downloading: return "downloading"
        case .verifying: return "verifying"
        case .installing: return "installing"
        case .ready: return "ready"
        }
    }

    static func testOrder(named value: String) -> Int? {
        switch value {
        case "phase:resolving": return 0
        case "phase:downloading": return 1
        case "phase:verifying": return 2
        case "phase:installing": return 3
        case "phase:ready": return 4
        default: return nil
        }
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    var values: [Value] { lock.withLock { stored } }
    func append(_ value: Value) { lock.withLock { stored.append(value) } }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension ProcessInfo {
    var machineArchitectureForTest: String {
#if arch(arm64)
        return "arm64"
#else
        return "x86_64"
#endif
    }
}
