import AppKit
import ForgeMenuCore
import Foundation
import ServiceManagement
import Sparkle

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }

    private let preferences = AppPreferences()
    private let logger = AppLogger.shared
    // Sparkle drives application self-updates from the appcast feed declared
    // in Info.plist (SUFeedURL) and verifies each download against the
    // embedded EdDSA public key (SUPublicEDKey) plus Developer ID signing.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var statusItem: NSStatusItem!
    private var popoverController: PopoverController!
    private var serviceController: ServiceController!
    private var terminationReplyPending = false
    private var terminationWatchdog: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installApplicationMainMenu()

        do {
            let paths = try RuntimePaths.resolve()
            let runtimeRoot = RuntimeStore.defaultRoot()
            let runtimeLease = RuntimeStoreLease(rootURL: runtimeRoot)
            let runtimeInstaller = RuntimeInstaller(rootURL: runtimeRoot)
            let processHost = ForgeProcessHost(
                configuration: .init(logURL: paths.serviceLog),
                logger: logger,
                lease: runtimeLease
            )
            let supervisor = ServiceSupervisor(
                processHost: processHost,
                runtimeInstaller: runtimeInstaller,
                clientFactory: { endpoint in WebSocketRPCClient(endpoint: endpoint.webSocketURL) },
                logger: logger
            )
            serviceController = ServiceController(supervisor: supervisor)

            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem.button?.image = ForgeCodeLogo.statusImage()
            statusItem.button?.image?.isTemplate = true
            statusItem.button?.target = self
            statusItem.button?.action = #selector(togglePopover(_:))
            statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

            popoverController = PopoverController()
            wireActions(paths: paths)
            serviceController.onSnapshotChanged = { [weak self] snapshot in
                guard let self else { return }
                self.popoverController.update(snapshot: snapshot, loginItemState: self.loginItemState)
                self.updateStatusItem(snapshot)
            }
            synchronizeLoginPreference()
            popoverController.update(snapshot: serviceController.snapshot, loginItemState: loginItemState)
            serviceController.start()
        } catch {
            logger.error(error.localizedDescription)
            presentFatalError(error.localizedDescription)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationReplyPending else { return .terminateLater }
        terminationReplyPending = true
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.terminationReplyPending else { return }
            self.logger.error("Termination watchdog expired; allowing app termination")
            self.terminationReplyPending = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        terminationWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: watchdog)
        Task {
            await serviceController?.stopForTermination()
            await MainActor.run {
                guard self.terminationReplyPending else { return }
                self.terminationWatchdog?.cancel()
                self.terminationWatchdog = nil
                self.terminationReplyPending = false
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    private func wireActions(paths: RuntimePaths) {
        popoverController.onWillShow = { [weak self] in self?.synchronizeLoginPreference() }
        popoverController.onLaunchAtLoginChanged = { [weak self] enabled in
            self?.setLaunchAtLogin(enabled)
        }
        popoverController.onOpenLoginItems = { [weak self] in self?.openLoginItemsSettings() }
        popoverController.onRefresh = { [weak self] in self?.serviceController.refreshNow() }
        popoverController.onRetryInstallation = { [weak self] in self?.serviceController.retryInstallation() }
        popoverController.onOpenLogs = { [weak self] in
            do {
                try FileManager.default.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(paths.logsDirectory)
            } catch {
                self?.presentActionError(title: "Logs could not be opened", error: error)
            }
        }
        popoverController.onOpenFrontend = { [weak self] in
            self?.openFrontend()
        }
        popoverController.onOpenConversation = { [weak self] conversationID in
            self?.openConversation(conversationID)
        }
        popoverController.onShowError = { [weak self] message in
            let error = NSError(domain: "ForgeMenuBar", code: 2, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
            self?.presentActionError(title: "ForgeCode needs attention", error: error)
        }
        popoverController.onCheckForUpdates = { [weak self] in self?.checkForUpdates() }
        popoverController.onQuit = { NSApp.terminate(nil) }
    }

    private func openFrontend() {
        do {
            let origin = try ConsoleURLBuilder.resolvedOrigin()
            let url = try ConsoleURLBuilder.consoleURL(
                origin: origin,
                endpoint: serviceController.snapshot.endpoint
            )
            guard NSWorkspace.shared.open(url) else {
                throw ForgeCoreError.connection("The default browser did not accept the ForgeCode frontend URL.")
            }
        } catch {
            logger.error("Could not open ForgeCode frontend: \(error.localizedDescription)")
            presentActionError(title: "ForgeCode frontend could not be opened", error: error)
        }
    }

    private func openConversation(_ conversationID: String) {
        do {
            let origin = try ConsoleURLBuilder.resolvedOrigin()
            let url = try ConsoleURLBuilder.conversationURL(
                conversationID: conversationID,
                origin: origin,
                endpoint: serviceController.snapshot.endpoint
            )
            guard NSWorkspace.shared.open(url) else {
                throw ForgeCoreError.connection("The default browser did not accept the ForgeCode console URL.")
            }
        } catch {
            logger.error("Could not open conversation: \(error.localizedDescription)")
            presentActionError(title: "Conversation could not be opened", error: error)
        }
    }

    private func installApplicationMainMenu() {
        let mainMenu = NSMenu(title: "Main Menu")
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "ForgeCode")
        let checkForUpdates = NSMenuItem(
            title: "Check for Updates",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdates.target = updaterController
        appMenu.addItem(checkForUpdates)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit ForgeCode",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = [.command]
        quit.target = NSApp
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }

    private func checkForUpdates() {
        // The update alert is an ordinary window; an accessory app must
        // activate so the panel actually comes to the front.
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            synchronizeLoginPreference()
            if loginItemState == .requiresApproval {
                presentApprovalRequired()
            }
        } catch {
            synchronizeLoginPreference()
            logger.error("Could not update Launch at Login: \(error.localizedDescription)")
            presentActionError(
                title: "Launch at Login could not be changed",
                message: "Open System Settings › General › Login Items, allow ForgeCode, then try again.",
                error: error
            )
        }
    }

    private func synchronizeLoginPreference() {
        preferences.launchAtLogin = SMAppService.mainApp.status == .enabled
        popoverController?.update(snapshot: serviceController?.snapshot ?? ServiceSnapshot(), loginItemState: loginItemState)
    }

    private var loginItemState: PopoverController.LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        // `.notFound` is what macOS reports for a main-app login item that has
        // never been registered, so it must remain toggleable; if registration
        // is truly impossible, `register()` throws and the error alert explains.
        case .notFound: return .disabled
        @unknown default: return .unavailable("macOS returned an unknown login item status.")
        }
    }

    private func presentApprovalRequired() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Approve Launch at Login"
        alert.informativeText = "macOS requires approval in System Settings › General › Login Items before ForgeCode can launch automatically."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            openLoginItemsSettings()
        }
    }

    private func openLoginItemsSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.users?LoginItems"
        ]
        for value in urls {
            if let url = URL(string: value), NSWorkspace.shared.open(url) { return }
        }
        let error = NSError(domain: "ForgeMenuBar", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "System Settings could not be opened."
        ])
        presentActionError(title: "Login Items settings could not be opened", error: error)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        popoverController.toggle(relativeTo: sender)
    }

    private func updateStatusItem(_ snapshot: ServiceSnapshot) {
        guard let button = statusItem.button else { return }
        button.image = ForgeCodeLogo.statusImage()
        button.image?.isTemplate = true
        let presentation = PopoverPresentation.make(snapshot: snapshot)
        let accessibilityStatus = "\(presentation.serviceTitle), \(presentation.serviceDetail)"
        button.setAccessibilityLabel(accessibilityStatus)
        button.setAccessibilityHelp("Open ForgeCode status")
        button.toolTip = accessibilityStatus
        switch snapshot.phase {
        case .ready: button.contentTintColor = nil
        case .installing, .starting, .restarting: button.contentTintColor = .controlAccentColor
        case .installationFailed, .failed: button.contentTintColor = .systemOrange
        case .disabled, .stopped: button.contentTintColor = .secondaryLabelColor
        }
    }

    private func presentActionError(title: String, message: String? = nil, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = [message, error.localizedDescription].compactMap { $0 }.joined(separator: "\n\n")
        alert.runModal()
    }

    private func presentFatalError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "ForgeCode could not start"
        alert.informativeText = message
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
