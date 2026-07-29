import XCTest
@testable import ForgeMenuCore

final class AppVersionTests: XCTestCase {
    func testParsesPlainAndTagStyleVersions() {
        XCTAssertEqual(AppVersion.parse("1.2.3"), Version(1, 2, 3))
        XCTAssertEqual(AppVersion.parse("v1.2.3"), Version(1, 2, 3))
        XCTAssertEqual(AppVersion.parse("  v0.1.0 "), Version(0, 1, 0))
    }

    func testParsesPrereleaseAndBuildMetadata() {
        XCTAssertEqual(
            AppVersion.parse("1.2.3-alpha.1+build.57"),
            Version(
                1,
                2,
                3,
                prereleaseIdentifiers: ["alpha", "1"],
                buildMetadataIdentifiers: ["build", "57"]
            )
        )
    }

    func testRejectsNonSemverInputs() {
        for value in [
            "not-a-version", "", "version", "vv1.2.3", "1.2.3.4",
            "1.0", "1", "01.2.3", "1.02.3", "1.2.03", "1.2.3-",
            "1.2.3+", "1.2.3-01", "1.2.3-alpha..1", "1.2.3+build..1",
            "1.2.3 alpha", "V1.2.3"
        ] {
            XCTAssertNil(AppVersion.parse(value), "expected rejection: \(value)")
        }
    }

    func testRejectsNumericOverflow() {
        XCTAssertNil(AppVersion.parse("18446744073709551616.0.0"))
    }

    func testShippedDefaultVersionIsParseable() {
        let shipped = "0.1.0"
        XCTAssertEqual(AppVersion.parse(shipped)?.description, shipped)
    }

    func testIdenticalVersionsAreNotAnUpdate() throws {
        let version = try XCTUnwrap(AppVersion.parse("0.1.0"))
        XCTAssertFalse(AppVersion.isUpdate(from: version, to: version))
    }

    func testComparesCoreVersionsNumerically() throws {
        let older = try XCTUnwrap(AppVersion.parse("0.1.9"))
        let newer = try XCTUnwrap(AppVersion.parse("0.1.10"))
        XCTAssertTrue(AppVersion.isUpdate(from: older, to: newer))
        XCTAssertFalse(AppVersion.isUpdate(from: newer, to: older))
    }

    func testSemverPrereleasePrecedence() throws {
        let ordered = [
            "1.0.0-alpha",
            "1.0.0-alpha.1",
            "1.0.0-alpha.beta",
            "1.0.0-beta",
            "1.0.0-beta.2",
            "1.0.0-beta.11",
            "1.0.0-rc.1",
            "1.0.0"
        ]
        let versions = try ordered.map { try XCTUnwrap(AppVersion.parse($0)) }
        for index in 0..<(versions.count - 1) {
            XCTAssertLessThan(versions[index], versions[index + 1])
        }
    }

    func testBuildMetadataIsIgnoredForEqualityAndPrecedence() throws {
        let first = try XCTUnwrap(AppVersion.parse("1.2.3+14"))
        let second = try XCTUnwrap(AppVersion.parse("1.2.3+15"))
        XCTAssertEqual(first, second)
        XCTAssertFalse(AppVersion.isUpdate(from: first, to: second))
        XCTAssertFalse(AppVersion.isUpdate(from: second, to: first))
    }

    func testDescriptionCanonicalizesOnlyTagWhitespace() {
        XCTAssertEqual(AppVersion.parse(" v1.2.3-alpha+build ")?.description, "1.2.3-alpha+build")
    }

    func testReadsVersionFromBundleInfoDictionary() {
        XCTAssertNil(AppVersion.read(from: Bundle(for: AppVersionTests.self)))
    }
}
