import XCTest
@testable import ForgeMenuCore

final class PopoverPresentationTests: XCTestCase {
    func testReadyPresentationShowsRunningCountAndRows() {
        let snapshot = ServiceSnapshot(
            phase: .ready,
            endpoint: LoopbackEndpoint(port: 50_001),
            activeConversations: [
                ActiveConversation(id: "a", title: "Alpha"),
                ActiveConversation(id: "b", title: "Untitled")
            ],
            conversationStreamState: .subscribed
        )
        let presentation = PopoverPresentation.make(snapshot: snapshot)
        XCTAssertEqual(presentation.serviceTitle, "ForgeCode")
        XCTAssertEqual(presentation.serviceDetail, "2 running")
        XCTAssertEqual(presentation.serviceTone, .normal)
        XCTAssertEqual(presentation.endpointAddress, "ws://127.0.0.1:50001")
        XCTAssertEqual(presentation.endpointPortLabel, "Port 50001")
        XCTAssertTrue(presentation.canOpenFrontend)
        XCTAssertEqual(presentation.conversations.map(\.id), ["a", "b"])
        XCTAssertNil(presentation.bodyMessage)
        XCTAssertTrue(presentation.refreshEnabled)
        XCTAssertEqual(presentation.conversationsSummary, "2 running")
        XCTAssertTrue(presentation.canExpandConversations)
    }

    func testVersionLabelShowsAppAndServerIndependently() {
        let both = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .ready,
            endpoint: LoopbackEndpoint(port: 9_755),
            conversationStreamState: .subscribed,
            sdkVersion: "0.1.190",
            appVersion: "1.0.0"
        ))
        XCTAssertEqual(both.versionLabel, "1.0.0 · Server 0.1.190")
        XCTAssertEqual(
            both.endpointTooltip,
            "ws://127.0.0.1:9755\nForgeCode 1.0.0\nServer 0.1.190"
        )

        // Before the helper reports in, the app version still stands alone.
        let appOnly = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .starting,
            appVersion: "1.0.0"
        ))
        XCTAssertEqual(appOnly.versionLabel, "1.0.0")

        let neither = PopoverPresentation.make(snapshot: ServiceSnapshot(phase: .stopped))
        XCTAssertNil(neither.versionLabel)
    }

    func testConversationsSummaryReflectsCountAndState() {
        let one = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .ready,
            endpoint: LoopbackEndpoint(port: 50_001),
            activeConversations: [ActiveConversation(id: "a", title: "Alpha")],
            conversationStreamState: .subscribed
        ))
        XCTAssertEqual(one.conversationsSummary, "1 running")

        let none = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .ready,
            endpoint: LoopbackEndpoint(port: 50_001),
            conversationStreamState: .subscribed
        ))
        XCTAssertEqual(none.conversationsSummary, "None running")

        let connecting = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .ready,
            endpoint: LoopbackEndpoint(port: 50_001),
            conversationStreamState: .connecting
        ))
        XCTAssertEqual(connecting.conversationsSummary, "Connecting…")
    }

    func testConversationsCannotExpandWhileServiceIsOff() {
        for phase in [ServicePhase.disabled, .stopped] {
            let presentation = PopoverPresentation.make(snapshot: ServiceSnapshot(phase: phase))
            XCTAssertFalse(
                presentation.canExpandConversations,
                "there is nothing to expand into while the service is off"
            )
            XCTAssertEqual(presentation.conversationsSummary, "Off")
        }
    }

    func testPreferredFrontendPortEnablesOpenAction() {
        let presentation = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .ready,
            endpoint: LoopbackEndpoint(port: SystemLoopbackEndpointAllocator.preferredPort),
            conversationStreamState: .subscribed
        ))
        XCTAssertEqual(presentation.endpointPortLabel, "Port 9753")
        XCTAssertTrue(presentation.canOpenFrontend)
    }

    func testSDKVersionIsSurfacedInLabelAndTooltip() {
        let withVersion = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .ready,
            endpoint: LoopbackEndpoint(port: 9_755),
            conversationStreamState: .subscribed,
            sdkVersion: "0.1.0"
        ))
        // Labelled as the server's version, since the app has its own.
        XCTAssertEqual(withVersion.versionLabel, "Server 0.1.0")
        XCTAssertEqual(withVersion.endpointTooltip, "ws://127.0.0.1:9755\nServer 0.1.0")

        let withoutVersion = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .ready,
            endpoint: LoopbackEndpoint(port: 9_755),
            conversationStreamState: .subscribed
        ))
        XCTAssertNil(withoutVersion.versionLabel)
        XCTAssertEqual(withoutVersion.endpointTooltip, "ws://127.0.0.1:9755")

        let stopped = PopoverPresentation.make(snapshot: ServiceSnapshot(phase: .stopped))
        XCTAssertNil(stopped.versionLabel)
        XCTAssertNil(stopped.endpointTooltip)
    }

    func testEmptySubscribedSnapshotIsExplicit() {
        let presentation = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .ready,
            endpoint: LoopbackEndpoint(port: 50_001),
            conversationStreamState: .subscribed
        ))
        XCTAssertEqual(presentation.serviceDetail, "0 running")
        XCTAssertEqual(presentation.bodyMessage, "No active conversations")
    }

    func testConnectingReconnectingAndUnavailableStatesAreCompact() {
        let connecting = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .starting,
            endpoint: LoopbackEndpoint(port: 50_001),
            conversationStreamState: .connecting
        ))
        XCTAssertEqual(connecting.serviceDetail, "Starting")
        XCTAssertEqual(connecting.bodyMessage, "Connecting…")
        XCTAssertEqual(connecting.serviceTone, .active)
        XCTAssertTrue(connecting.refreshEnabled)

        let reconnecting = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .ready,
            endpoint: LoopbackEndpoint(port: 50_001),
            conversationStreamState: .reconnecting(attempt: 2, delay: 4),
            streamError: "socket closed"
        ))
        XCTAssertEqual(reconnecting.serviceDetail, "Reconnecting")
        XCTAssertEqual(reconnecting.bodyMessage, "Connecting…")
        XCTAssertEqual(reconnecting.actionableError, "socket closed")
        XCTAssertEqual(reconnecting.serviceTone, .warning)

        let failed = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .failed("helper exited"),
            streamError: "stream detail"
        ))
        XCTAssertEqual(failed.serviceDetail, "Unavailable")
        XCTAssertEqual(failed.bodyMessage, "Conversations unavailable")
        XCTAssertEqual(failed.actionableError, "helper exited")
        XCTAssertFalse(failed.refreshEnabled)
    }

    func testDisabledAndStoppedDoNotExposeConversationRows() {
        for phase in [ServicePhase.disabled, .stopped] {
            let presentation = PopoverPresentation.make(snapshot: ServiceSnapshot(
                phase: phase,
                activeConversations: [ActiveConversation(id: "late", title: "Late")]
            ))
            XCTAssertTrue(presentation.conversations.isEmpty)
            XCTAssertEqual(presentation.bodyMessage, "Start ForgeCode to view active conversations")
            XCTAssertFalse(presentation.refreshEnabled)
            XCTAssertFalse(presentation.restartEnabled)
            XCTAssertNil(presentation.endpointAddress)
            XCTAssertNil(presentation.endpointPortLabel)
            XCTAssertFalse(presentation.canOpenFrontend)
        }
    }

    func testLongErrorsStayOutOfPrimaryStrings() {
        let longError = String(repeating: "diagnostic ", count: 100)
        let presentation = PopoverPresentation.make(snapshot: ServiceSnapshot(
            phase: .ready,
            endpoint: LoopbackEndpoint(port: 50_001),
            conversationStreamState: .reconnecting(attempt: 1, delay: 1),
            streamError: longError
        ))
        XCTAssertEqual(presentation.serviceTitle, "ForgeCode")
        XCTAssertEqual(presentation.serviceDetail, "Reconnecting")
        XCTAssertEqual(presentation.bodyMessage, "Connecting…")
        XCTAssertEqual(presentation.actionableError, longError)
    }
}
