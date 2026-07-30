import XCTest
@testable import ForgeMenuCore

final class PopoverPresentationTests: XCTestCase {
    func testReadyPresentationShowsRunningService() {
        let snapshot = ServiceSnapshot(
            phase: .ready,
            endpoint: LoopbackEndpoint(port: 50_001)
        )
        let presentation = PopoverPresentation.make(snapshot: snapshot)
        XCTAssertEqual(presentation.serviceTitle, "ForgeCode")
        XCTAssertEqual(presentation.serviceDetail, "Running")
        XCTAssertEqual(presentation.serviceTone, .normal)
        XCTAssertEqual(presentation.endpointAddress, "ws://127.0.0.1:50001")
        XCTAssertTrue(presentation.canOpenFrontend)
        XCTAssertTrue(presentation.refreshEnabled)
        XCTAssertNil(presentation.actionableError)
    }

    func testVersionLabelShowsAppAndServerIndependently() {
        let both = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .ready,
            endpoint: LoopbackEndpoint(port: 9_755),
            sdkVersion: "0.1.190",
            appVersion: "1.0.0"
        ))
        XCTAssertEqual(both.versionLabel, "1.0.0 · Server 0.1.190")

        // Before the helper reports in, the app version still stands alone.
        let appOnly = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .starting,
            appVersion: "1.0.0"
        ))
        XCTAssertEqual(appOnly.versionLabel, "1.0.0")

        let neither = PopoverPresentation.make(snapshot: ServiceSnapshot(phase: .stopped))
        XCTAssertNil(neither.versionLabel)
    }

    func testPreferredFrontendPortEnablesOpenAction() {
        let presentation = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .ready,
            endpoint: LoopbackEndpoint(port: SystemLoopbackEndpointAllocator.preferredPort)
        ))
        XCTAssertTrue(presentation.canOpenFrontend)
    }

    func testSDKVersionIsSurfacedInLabel() {
        let withVersion = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .ready,
            endpoint: LoopbackEndpoint(port: 9_755),
            sdkVersion: "0.1.0"
        ))
        // Labelled as the server's version, since the app has its own.
        XCTAssertEqual(withVersion.versionLabel, "Server 0.1.0")

        let withoutVersion = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .ready,
            endpoint: LoopbackEndpoint(port: 9_755)
        ))
        XCTAssertNil(withoutVersion.versionLabel)

        let stopped = PopoverPresentation.make(snapshot: ServiceSnapshot(phase: .stopped))
        XCTAssertNil(stopped.versionLabel)
    }

    func testStartingAndFailedStatesAreCompact() {
        let starting = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .starting,
            endpoint: LoopbackEndpoint(port: 50_001)
        ))
        XCTAssertEqual(starting.serviceDetail, "Starting")
        XCTAssertEqual(starting.serviceTone, .active)
        XCTAssertTrue(starting.refreshEnabled)
        XCTAssertFalse(starting.canOpenFrontend)

        let failed = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .failed("helper exited")
        ))
        XCTAssertEqual(failed.serviceDetail, "Unavailable")
        XCTAssertEqual(failed.serviceTone, .warning)
        XCTAssertEqual(failed.actionableError, "helper exited")
        XCTAssertFalse(failed.refreshEnabled)
    }

    func testInstallationPhasesAreCompactAndBounded() {
        let phases: [(RuntimeInstallationPhase, String)] = [
            (.resolving, "Resolving runtime"),
            (.downloading(progress: -0.5), "Downloading 0%"),
            (.downloading(progress: 1.5), "Downloading 100%"),
            (.verifying, "Verifying runtime"),
            (.installing, "Installing runtime"),
            (.ready, "Runtime ready")
        ]

        for (phase, detail) in phases {
            let presentation = PopoverPresentation.make(snapshot: ServiceSnapshot(phase: .installing(phase)))
            XCTAssertEqual(presentation.serviceDetail, detail)
            XCTAssertEqual(presentation.serviceTone, .active)
            XCTAssertFalse(presentation.refreshEnabled)
            XCTAssertFalse(presentation.canOpenFrontend)
        }

        XCTAssertEqual(
            PopoverPresentation.make(snapshot: ServiceSnapshot(
                phase: .installing(.downloading(progress: -2))
            )).installationProgress,
            .determinate(value: 0, label: "Downloading ForgeCode runtime, 0 percent")
        )
        XCTAssertEqual(
            PopoverPresentation.make(snapshot: ServiceSnapshot(
                phase: .installing(.downloading(progress: 4))
            )).installationProgress,
            .determinate(value: 1, label: "Downloading ForgeCode runtime, 100 percent")
        )
    }

    func testNonDownloadInstallationPhasesExposeTextualIndeterminateProgress() {
        let expected: [(RuntimeInstallationPhase, PopoverPresentation.InstallationProgress)] = [
            (.resolving, .indeterminate(label: "Resolving ForgeCode runtime")),
            (.verifying, .indeterminate(label: "Verifying ForgeCode runtime")),
            (.installing, .indeterminate(label: "Installing ForgeCode runtime")),
            (.ready, .indeterminate(label: "Starting ForgeCode service"))
        ]
        for (phase, progress) in expected {
            XCTAssertEqual(
                PopoverPresentation.make(snapshot: ServiceSnapshot(phase: .installing(phase))).installationProgress,
                progress
            )
        }
    }

    func testInstallationFailureOffersRetryWithConciseError() {
        let message = "Runtime download failed. Check your connection and retry."
        let presentation = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .installationFailed(.download)
        ))
        XCTAssertEqual(presentation.serviceDetail, "Install failed")
        XCTAssertEqual(presentation.actionableError, message)
        XCTAssertTrue(presentation.retryInstallationEnabled)
        XCTAssertFalse(presentation.refreshEnabled)
        XCTAssertNil(presentation.installationProgress)
    }

    func testPermissionFailurePresentationPreservesIdentityAndIsActionable() {
        let presentation = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .installationFailed(.filesystem(.permissionDenied))
        ))

        XCTAssertEqual(presentation.serviceDetail, "Install failed")
        XCTAssertEqual(
            presentation.actionableError,
            "Runtime folder access was denied. Check permissions and retry."
        )
        XCTAssertTrue(presentation.retryInstallationEnabled)
        XCTAssertFalse(presentation.refreshEnabled)
    }

    func testDisabledAndStoppedDisableActions() {
        for phase in [ServicePhase.disabled, .stopped] {
            let presentation = PopoverPresentation.make(snapshot: ServiceSnapshot(phase: phase))
            XCTAssertFalse(presentation.refreshEnabled)
            XCTAssertNil(presentation.endpointAddress)
            XCTAssertFalse(presentation.canOpenFrontend)
        }
    }

    func testLongErrorsStayOutOfPrimaryStrings() {
        let longError = String(repeating: "diagnostic ", count: 100)
        let presentation = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .failed(longError)
        ))
        XCTAssertEqual(presentation.serviceTitle, "ForgeCode")
        XCTAssertEqual(presentation.serviceDetail, "Unavailable")
        XCTAssertEqual(presentation.actionableError, longError)
    }
}
