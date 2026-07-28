import AppKit
import ForgeMenuCore
import Foundation

@MainActor
final class PopoverController: NSObject, NSPopoverDelegate {
    enum LoginItemState: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable(String)
    }

    // Sized so the default command list fits without scrolling; the expanded
    // conversation list scrolls within the same fixed frame.
    static let contentSize = NSSize(width: 288, height: 336)
    private static let bodyContentWidth: CGFloat = 280
    /// Horizontal inset shared by rows, separators and notes.
    private static let rowInset: CGFloat = 10
    /// Left edge of the label column, so notes line up under row titles.
    private static let labelColumnInset = rowInset
        + CommandRowView.iconColumnWidth
        + CommandRowView.iconToLabelGap

    var onWillShow: (() -> Void)?
    var onRunServiceChanged: ((Bool) -> Void)?
    var onLaunchAtLoginChanged: ((Bool) -> Void)?
    var onOpenLoginItems: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onRestart: (() -> Void)?
    var onOpenLogs: (() -> Void)?
    var onConfigureConsoleOrigin: (() -> Void)?
    var onOpenFrontend: (() -> Void)?
    var onOpenConversation: ((String) -> Void)?
    var onShowError: ((String) -> Void)?
    var onQuit: (() -> Void)?

    private let preferences: AppPreferences
    private let popover = NSPopover()
    private let contentController = PopoverContentViewController()
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusVersion = NSTextField(labelWithString: "")
    private let statusDetail = NSTextField(labelWithString: "")
    private let statusIcon = NSImageView()
    private let scrollView = NSScrollView()
    private let bodyStack = NSStackView()
    private let endpointLabel = NSTextField(labelWithString: "")
    private let openFrontendButton = NSButton()
    private let refreshButton = NSButton()

    private var snapshot = ServiceSnapshot()
    private var loginItemState: LoginItemState = .disabled
    private var presentation = PopoverPresentation.make(snapshot: ServiceSnapshot())
    private var visibilityState: PopoverVisibilityState = .hidden
    private var mode: PopoverMode = .commands
    private weak var statusButton: NSStatusBarButton?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localKeyMonitor: Any?

    init(preferences: AppPreferences) {
        self.preferences = preferences
        super.init()
        configurePopover()
        rebuild()
    }

    deinit {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
    }

    func update(snapshot: ServiceSnapshot, loginItemState: LoginItemState? = nil) {
        self.snapshot = snapshot
        if let loginItemState { self.loginItemState = loginItemState }
        rebuild()
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        statusButton = button
        applyVisibilityEvent(.statusButtonMouseUp, relativeTo: button)
    }

    func close() {
        applyVisibilityEvent(.outsideInteraction)
    }

    private func configurePopover() {
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentSize = Self.contentSize
        popover.delegate = self
        contentController.preferredContentSize = Self.contentSize
        contentController.onCancel = { [weak self] in self?.close() }
        contentController.view = buildRootView()
        popover.contentViewController = contentController
    }

    private func buildRootView() -> NSView {
        let root = NSVisualEffectView()
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.appearance = NSAppearance(named: .darkAqua)
        root.translatesAutoresizingMaskIntoConstraints = false

        let header = buildHeader()
        let footer = buildFooter()
        let topSeparator = separator()
        let bottomSeparator = separator()

        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        // Rows carry their own internal padding, so the stack only needs a
        // small outer margin and a hairline gap between rows.
        bodyStack.spacing = 1
        bodyStack.edgeInsets = NSEdgeInsets(top: 6, left: 4, bottom: 8, right: 4)
        bodyStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(bodyStack)
        scrollView.documentView = document

        root.addSubview(header)
        root.addSubview(topSeparator)
        root.addSubview(scrollView)
        root.addSubview(bottomSeparator)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.contentSize.width),
            root.heightAnchor.constraint(equalToConstant: Self.contentSize.height),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 56),
            topSeparator.topAnchor.constraint(equalTo: header.bottomAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.bottomAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.bottomAnchor),
            bodyStack.topAnchor.constraint(equalTo: document.topAnchor),
            bodyStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            bodyStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            bodyStack.widthAnchor.constraint(equalToConstant: Self.contentSize.width),
            bottomSeparator.bottomAnchor.constraint(equalTo: footer.topAnchor),
            bottomSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 46)
        ])
        return root
    }

    private func buildHeader() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        statusTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        statusTitle.lineBreakMode = .byTruncatingTail
        statusTitle.maximumNumberOfLines = 1
        statusTitle.translatesAutoresizingMaskIntoConstraints = false
        statusVersion.font = .systemFont(ofSize: 10, weight: .regular)
        statusVersion.textColor = .secondaryLabelColor
        statusVersion.lineBreakMode = .byTruncatingTail
        statusVersion.maximumNumberOfLines = 1
        statusVersion.translatesAutoresizingMaskIntoConstraints = false
        statusDetail.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        statusDetail.textColor = .secondaryLabelColor
        statusDetail.maximumNumberOfLines = 1
        statusDetail.lineBreakMode = .byTruncatingTail
        statusDetail.alignment = .right
        statusDetail.translatesAutoresizingMaskIntoConstraints = false
        let titleStack = NSStackView(views: [statusTitle, statusVersion])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusIcon)
        container.addSubview(titleStack)
        container.addSubview(statusDetail)
        NSLayoutConstraint.activate([
            statusIcon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.rowInset + 2),
            statusIcon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusIcon.widthAnchor.constraint(equalToConstant: 16),
            statusIcon.heightAnchor.constraint(equalToConstant: 16),
            titleStack.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: 9),
            titleStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            titleStack.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            statusDetail.leadingAnchor.constraint(greaterThanOrEqualTo: titleStack.trailingAnchor, constant: 6),
            statusDetail.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -(Self.rowInset + 2)),
            statusDetail.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusDetail.widthAnchor.constraint(lessThanOrEqualToConstant: 96)
        ])
        return container
    }

    private func buildFooter() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        endpointLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        endpointLabel.textColor = .secondaryLabelColor
        endpointLabel.lineBreakMode = .byTruncatingMiddle
        endpointLabel.maximumNumberOfLines = 1
        endpointLabel.isSelectable = true
        endpointLabel.translatesAutoresizingMaskIntoConstraints = false
        openFrontendButton.title = "Open"
        openFrontendButton.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
        openFrontendButton.imagePosition = .imageLeading
        openFrontendButton.bezelStyle = .rounded
        openFrontendButton.controlSize = .small
        openFrontendButton.target = self
        openFrontendButton.action = #selector(openFrontendCommand)
        openFrontendButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.title = "Refresh"
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshButton.imagePosition = .imageLeading
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(endpointLabel)
        container.addSubview(openFrontendButton)
        container.addSubview(refreshButton)
        NSLayoutConstraint.activate([
            endpointLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.rowInset + 2),
            endpointLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            endpointLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 90),
            refreshButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -(Self.rowInset + 2)),
            refreshButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 74),
            refreshButton.heightAnchor.constraint(equalToConstant: 26),
            openFrontendButton.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -6),
            openFrontendButton.leadingAnchor.constraint(greaterThanOrEqualTo: endpointLabel.trailingAnchor, constant: 6),
            openFrontendButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            openFrontendButton.widthAnchor.constraint(equalToConstant: 64),
            openFrontendButton.heightAnchor.constraint(equalToConstant: 26)
        ])
        return container
    }

    private func rebuild() {
        presentation = PopoverPresentation.make(snapshot: snapshot)
        statusTitle.stringValue = presentation.serviceTitle
        statusDetail.stringValue = presentation.serviceDetail
        statusIcon.image = NSImage(
            systemSymbolName: statusSymbol(for: presentation.serviceTone),
            accessibilityDescription: presentation.serviceTitle
        )
        statusIcon.contentTintColor = statusColor(for: presentation.serviceTone)
        statusVersion.stringValue = presentation.versionLabel ?? ""
        statusVersion.isHidden = presentation.versionLabel == nil
        endpointLabel.stringValue = presentation.endpointPortLabel ?? "Not running"
        endpointLabel.toolTip = presentation.endpointTooltip
        openFrontendButton.isEnabled = presentation.canOpenFrontend
        openFrontendButton.toolTip = presentation.canOpenFrontend
            ? frontendTooltip
            : "Start ForgeCode before opening the frontend"
        refreshButton.isEnabled = presentation.refreshEnabled
        rebuildConversationBody()
    }

    private func rebuildConversationBody() {
        bodyStack.arrangedSubviews.forEach {
            bodyStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        switch mode {
        case .commands: buildCommandBody()
        case .conversations: buildConversationBody()
        }
    }

    /// The default body: the conversation disclosure row followed by the
    /// commands that previously lived behind the overflow button.
    private func buildCommandBody() {
        bodyStack.addArrangedSubview(conversationsDisclosureRow())
        bodyStack.addArrangedSubview(bodySeparator())

        bodyStack.addArrangedSubview(commandRow(
            title: "Run ForgeCode Service",
            symbol: preferences.runService ? "checkmark.circle.fill" : "circle",
            action: #selector(toggleRunServiceCommand),
            isOn: preferences.runService
        ))
        bodyStack.addArrangedSubview(commandRow(
            title: launchAtLoginTitle,
            symbol: loginItemState == .enabled ? "checkmark.circle.fill" : "circle",
            action: #selector(toggleLaunchAtLoginCommand),
            isOn: loginItemState == .enabled,
            isEnabled: loginItemState != .requiresApproval
        ))
        if loginItemState == .requiresApproval {
            bodyStack.addArrangedSubview(commandRow(
                title: "Approve in Login Items…",
                symbol: "exclamationmark.triangle",
                action: #selector(openLoginItemsCommand)
            ))
        } else if case .unavailable(let message) = loginItemState {
            bodyStack.addArrangedSubview(noteView("Login item unavailable: \(message)"))
        }
        bodyStack.addArrangedSubview(commandRow(
            title: "Restart ForgeCode Service",
            symbol: "arrow.triangle.2.circlepath",
            action: #selector(restartCommand),
            isEnabled: presentation.restartEnabled
        ))
        bodyStack.addArrangedSubview(commandRow(
            title: "Open Logs",
            symbol: "doc.text",
            action: #selector(openLogsCommand)
        ))
        bodyStack.addArrangedSubview(commandRow(
            title: "Console Origin…",
            symbol: "network",
            action: #selector(configureConsoleOriginCommand)
        ))
        if presentation.actionableError != nil {
            bodyStack.addArrangedSubview(commandRow(
                title: "Show Error Details…",
                symbol: "exclamationmark.triangle.fill",
                action: #selector(showErrorCommand)
            ))
        }
        bodyStack.addArrangedSubview(bodySeparator())
        bodyStack.addArrangedSubview(commandRow(
            title: "Quit ForgeCode",
            symbol: "power",
            action: #selector(quitCommand),
            trailingText: "⌘Q"
        ))
    }

    /// The expanded conversation list, reached from the disclosure row.
    private func buildConversationBody() {
        bodyStack.addArrangedSubview(commandRow(
            title: "Conversations",
            symbol: "chevron.left",
            action: #selector(collapseConversations),
            trailingText: presentation.conversationsSummary,
            isProminent: true
        ))
        bodyStack.addArrangedSubview(bodySeparator())
        if let message = presentation.bodyMessage {
            bodyStack.addArrangedSubview(noteView(message, centered: true))
        }
        for conversation in presentation.conversations {
            bodyStack.addArrangedSubview(conversationRow(conversation))
        }
    }

    private func conversationsDisclosureRow() -> NSView {
        commandRow(
            title: "Conversations",
            symbol: "bubble.left.and.bubble.right",
            action: #selector(expandConversations),
            isEnabled: presentation.canExpandConversations,
            trailingText: presentation.conversationsSummary,
            showsDisclosure: presentation.canExpandConversations
        )
    }

    private func commandRow(
        title: String,
        symbol: String,
        action: Selector,
        isOn: Bool = false,
        isEnabled: Bool = true,
        trailingText: String? = nil,
        isProminent: Bool = false,
        showsDisclosure: Bool = false
    ) -> NSView {
        let row = CommandRowView(target: self, action: action)
        row.isEnabled = isEnabled
        row.configure(
            symbol: symbol,
            title: title,
            titleFont: .systemFont(ofSize: 12, weight: isProminent ? .semibold : .regular),
            tint: isOn ? .controlAccentColor : nil,
            trailingText: trailingText,
            showsDisclosure: showsDisclosure
        )
        row.toolTip = title
        row.setAccessibilityLabel(title)
        row.widthAnchor.constraint(equalToConstant: Self.bodyContentWidth).isActive = true
        return row
    }

    /// Group separator: an inset hairline with equal space above and below, so
    /// groups read as groups rather than rows crowded against a line.
    private func bodySeparator() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(box)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.bodyContentWidth),
            container.heightAnchor.constraint(equalToConstant: 13),
            box.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.rowInset),
            box.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.rowInset),
            box.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    /// Secondary text aligned to the label column, so it reads as a note about
    /// the row above rather than a row of its own.
    private func noteView(_ text: String, centered: Bool = false) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10)
        label.textColor = .tertiaryLabelColor
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.alignment = centered ? .center : .left
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        let leading = centered ? Self.rowInset : Self.labelColumnInset
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.bodyContentWidth),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leading),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.rowInset),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5)
        ])
        return container
    }

    /// Conversation rows use the same metrics as command rows so the icon and
    /// label columns stay aligned across both views.
    private func conversationRow(_ conversation: PopoverPresentation.ConversationRow) -> NSView {
        let row = CommandRowView(target: self, action: #selector(openConversation(_:)))
        row.representedID = conversation.id
        row.configure(
            symbol: "bubble.left",
            title: conversation.title,
            titleFont: .systemFont(ofSize: 12, weight: .regular),
            tint: nil,
            trailingText: nil,
            showsDisclosure: false
        )
        row.toolTip = conversation.title
        row.setAccessibilityLabel(conversation.title)
        row.widthAnchor.constraint(equalToConstant: Self.bodyContentWidth).isActive = true
        return row
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    private func applyVisibilityEvent(_ event: PopoverVisibilityEvent, relativeTo button: NSStatusBarButton? = nil) {
        let transition = PopoverVisibilityReducer.reduce(state: visibilityState, event: event)
        visibilityState = transition.state
        switch transition.effect {
        case .none:
            if event == .popoverDidClose { removeAllMonitors() }
        case .show:
            guard let button = button ?? statusButton else { visibilityState = .hidden; return }
            onWillShow?()
            rebuild()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // An accessory app is not active by default, so key events would
            // otherwise be delivered to whatever app is frontmost. Activate and
            // take key focus so Escape and Command-Q reach this popover.
            NSApp.activate(ignoringOtherApps: true)
            contentController.view.window?.makeKeyAndOrderFront(nil)
            installAllMonitors()
        case .close:
            removeAllMonitors()
            if popover.isShown { popover.performClose(nil) }
        }
    }

    private func installAllMonitors() {
        removeAllMonitors()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.visibilityState == .visible else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let command = PopoverKeyCommandMatcher.command(
                keyCode: event.keyCode,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                commandHeld: modifiers == .command
            )
            switch command {
            case .dismiss:
                self.applyVisibilityEvent(.escape)
                return nil
            case .quit:
                // Dismiss first so the popover cannot outlive the app during
                // an asynchronous termination reply.
                self.applyVisibilityEvent(.escape)
                self.onQuit?()
                return nil
            case nil:
                return event
            }
        }
        installMouseMonitors()
    }

    private func installMouseMonitors() {
        removeMouseMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, self.visibilityState == .visible else { return event }
            self.handleMouseInteraction(at: self.screenLocation(for: event))
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in
                guard let self, self.visibilityState == .visible else { return }
                self.handleMouseInteraction(at: self.screenLocation(for: event))
            }
        }
    }

    private func handleMouseInteraction(at screenPoint: NSPoint) {
        if isInsidePopover(screenPoint) || isInsideStatusButton(screenPoint) { return }
        applyVisibilityEvent(.outsideInteraction)
    }

    private func screenLocation(for event: NSEvent) -> NSPoint {
        if let window = event.window { return window.convertPoint(toScreen: event.locationInWindow) }
        return NSEvent.mouseLocation
    }

    private func isInsidePopover(_ screenPoint: NSPoint) -> Bool {
        guard let window = contentController.view.window, window.isVisible else { return false }
        return window.frame.contains(screenPoint)
    }

    private func isInsideStatusButton(_ screenPoint: NSPoint) -> Bool {
        guard let button = statusButton, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(screenPoint)
    }

    private func removeMouseMonitors() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor); self.localMouseMonitor = nil }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor); self.globalMouseMonitor = nil }
    }

    private func removeAllMonitors() {
        removeMouseMonitors()
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor); self.localKeyMonitor = nil }
    }

    func popoverDidClose(_ notification: Notification) {
        // Reopening always starts on the commands list.
        mode = PopoverModeReducer.reduce(state: mode, event: .popoverDidClose)
        applyVisibilityEvent(.popoverDidClose)
    }

    @objc private func openConversation(_ sender: Any?) {
        guard let id = (sender as? CommandRowView)?.representedID else { return }
        close()
        onOpenConversation?(id)
    }
    @objc private func refresh() { onRefresh?() }

    @objc private func expandConversations() {
        guard presentation.canExpandConversations else { return }
        setMode(.conversations)
    }

    @objc private func collapseConversations() { setMode(.commands) }

    private func setMode(_ next: PopoverMode) {
        let event: PopoverModeEvent = next == .conversations ? .expandConversations : .collapseConversations
        let resolved = PopoverModeReducer.reduce(state: mode, event: event)
        guard resolved != mode else { return }
        mode = resolved
        rebuild()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // Toggles keep the popover open so the resulting state change is visible.
    @objc private func toggleRunServiceCommand() { onRunServiceChanged?(!preferences.runService) }
    @objc private func toggleLaunchAtLoginCommand() { onLaunchAtLoginChanged?(loginItemState != .enabled) }
    @objc private func restartCommand() { onRestart?() }

    // Actions that hand off to another app or window dismiss the popover first.
    @objc private func openLoginItemsCommand() { close(); onOpenLoginItems?() }
    @objc private func openLogsCommand() { close(); onOpenLogs?() }
    @objc private func configureConsoleOriginCommand() { close(); onConfigureConsoleOrigin?() }
    @objc private func openFrontendCommand() { close(); onOpenFrontend?() }
    @objc private func showErrorCommand() {
        guard let message = presentation.actionableError else { return }
        close()
        onShowError?(message)
    }
    @objc private func quitCommand() { onQuit?() }

    private var frontendTooltip: String {
        guard let address = presentation.endpointAddress else {
            return "Open the configured ForgeCode frontend"
        }
        return "Open the ForgeCode frontend connected to \(address)"
    }

    private var launchAtLoginTitle: String {
        loginItemState == .requiresApproval ? "Launch at Login — Approval Required" : "Launch at Login"
    }

    private func statusSymbol(for tone: PopoverPresentation.ServiceTone) -> String {
        switch tone {
        case .normal: return "circle.fill"
        case .active: return "arrow.triangle.2.circlepath"
        case .warning: return "exclamationmark.triangle.fill"
        case .inactive: return "pause.circle"
        }
    }

    private func statusColor(for tone: PopoverPresentation.ServiceTone) -> NSColor {
        switch tone {
        case .normal: return .systemGreen
        case .active: return .controlAccentColor
        case .warning: return .systemOrange
        case .inactive: return .secondaryLabelColor
        }
    }
}

/// A full-width menu-style row: fixed icon column, generous gap to the label,
/// and a rounded highlight that only appears on hover. Modelled on the spacing
/// of native macOS menus rather than stacked buttons.
private final class CommandRowView: NSView {
    static let height: CGFloat = 28
    static let inset: CGFloat = 10
    static let iconColumnWidth: CGFloat = 18
    static let iconToLabelGap: CGFloat = 9

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private weak var target: AnyObject?
    private let action: Selector
    /// Identifier carried by conversation rows.
    var representedID: String?
    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false { didSet { needsDisplay = true } }

    var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1 : 0.35
            if !isEnabled { isHovered = false }
        }
    }

    init(target: AnyObject, action: Selector) {
        self.target = target
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        iconView.imageAlignment = .alignCenter
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailingLabel.translatesAutoresizingMaskIntoConstraints = false
        trailingLabel.font = .systemFont(ofSize: 11, weight: .regular)
        trailingLabel.textColor = .tertiaryLabelColor
        trailingLabel.lineBreakMode = .byTruncatingTail
        trailingLabel.maximumNumberOfLines = 1
        trailingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevronView.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevronView.contentTintColor = .tertiaryLabelColor

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(trailingLabel)
        addSubview(chevronView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconColumnWidth),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor,
                constant: Self.iconToLabelGap
            ),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor,
                constant: 8
            )
        ])
        chevronTrailingConstraint = trailingLabel.trailingAnchor.constraint(
            equalTo: chevronView.leadingAnchor,
            constant: -5
        )
        plainTrailingConstraint = trailingLabel.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -Self.inset
        )
    }

    private var chevronTrailingConstraint: NSLayoutConstraint?
    private var plainTrailingConstraint: NSLayoutConstraint?

    func configure(
        symbol: String,
        title: String,
        titleFont: NSFont,
        tint: NSColor?,
        trailingText: String?,
        showsDisclosure: Bool
    ) {
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.contentTintColor = tint ?? .secondaryLabelColor
        titleLabel.stringValue = title
        titleLabel.font = titleFont
        titleLabel.textColor = tint ?? .labelColor
        trailingLabel.stringValue = trailingText ?? ""
        trailingLabel.isHidden = trailingText == nil
        chevronView.isHidden = !showsDisclosure
        chevronTrailingConstraint?.isActive = showsDisclosure
        plainTrailingConstraint?.isActive = !showsDisclosure
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { if isEnabled { isHovered = true } }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if let target { NSApp.sendAction(action, to: target, from: self) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHovered else { return }
        let highlight = bounds.insetBy(dx: 4, dy: 1)
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: highlight, xRadius: 5, yRadius: 5).fill()
    }

    override var isFlipped: Bool { true }
}

private final class PopoverContentViewController: NSViewController {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
