import XCTest
import Version
@testable import ForgeMenuCore

final class AppVersionTests: XCTestCase {
    func testParsesPlainAndTagStyleVersions() {
        XCTAssertEqual(AppVersion.parse("1.2.3"), Version(1, 2, 3))
        // Git tags carry a leading `v`; the SDK's parse_release_version
        // tolerates it, so we must too.
        XCTAssertEqual(AppVersion.parse("v1.2.3"), Version(1, 2, 3))
        XCTAssertEqual(AppVersion.parse("  v0.1.0 "), Version(0, 1, 0))
    }

    func testRejectsGarbage() {
        XCTAssertNil(AppVersion.parse("not-a-version"))
        XCTAssertNil(AppVersion.parse(""))
        // Guards against a naive "strip leading v" that would accept this.
        XCTAssertNil(AppVersion.parse("version"))
        XCTAssertNil(AppVersion.parse("1.2.3.4"))
    }

    func testRequiresAllThreeComponents() {
        // Parsing is strict, so a two-component version would build fine and
        // then render no version at all. scripts/common.sh rejects these at
        // build time; this pins the behavior that makes that check necessary.
        XCTAssertNil(AppVersion.parse("1.0"))
        XCTAssertNil(AppVersion.parse("1"))
    }

    func testShippedDefaultVersionIsParseable() {
        // Round-trips the value in the repository-root versions.sh. If someone
        // sets APP_VERSION_DEFAULT to something this parser rejects, that must
        // fail here rather than silently blank the version in the UI.
        let shipped = "0.1.0"
        XCTAssertEqual(AppVersion.parse(shipped)?.description, shipped)
    }

    func testIdenticalVersionsAreNotAnUpdate() throws {
        let version = try XCTUnwrap(AppVersion.parse("0.1.0"))
        XCTAssertFalse(AppVersion.isUpdate(from: version, to: version))
    }

    func testComparesByPrecedenceNotLexicographically() throws {
        // The bug a string comparison would introduce: "0.1.9" > "0.1.10".
        let older = try XCTUnwrap(AppVersion.parse("0.1.9"))
        let newer = try XCTUnwrap(AppVersion.parse("0.1.10"))
        XCTAssertTrue(AppVersion.isUpdate(from: older, to: newer))
        XCTAssertFalse(AppVersion.isUpdate(from: newer, to: older))
    }

    func testPrereleasePrecedesItsRelease() throws {
        let beta = try XCTUnwrap(AppVersion.parse("1.0.0-beta"))
        let release = try XCTUnwrap(AppVersion.parse("1.0.0"))
        XCTAssertTrue(AppVersion.isUpdate(from: beta, to: release))
        XCTAssertFalse(AppVersion.isUpdate(from: release, to: beta))
    }

    func testBuildMetadataIsIgnoredWhenComparing() throws {
        // Per semver, build metadata does not affect precedence, so a rebuild
        // of the same version must not register as an available update.
        let first = try XCTUnwrap(AppVersion.parse("1.2.3+14"))
        let second = try XCTUnwrap(AppVersion.parse("1.2.3+15"))
        XCTAssertFalse(AppVersion.isUpdate(from: first, to: second))
        XCTAssertFalse(AppVersion.isUpdate(from: second, to: first))
    }

    func testReadsVersionFromBundleInfoDictionary() {
        // Under `swift test` there is no app bundle, so the value is absent
        // rather than a misleading default.
        XCTAssertNil(AppVersion.read(from: Bundle(for: AppVersionTests.self)))
    }

    func testDescriptionDropsTheTagPrefix() {
        XCTAssertEqual(AppVersion.parse("v0.1.0")?.description, "0.1.0")
    }
}
