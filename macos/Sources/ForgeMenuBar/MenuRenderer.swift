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

    // Sized so the steady-state text list fits snugly without scrolling.
    // Transient states with extra rows or details overflow into the scroll view
    // within this same fixed frame.
    static let contentSize = NSSize(width: 260, height: 146)
    private static let bodyContentWidth: CGFloat = 252
    /// Horizontal inset shared by rows and notes.
    private static let rowInset: CGFloat = 10
    /// Left edge shared by command titles and supporting notes.
    private static let labelColumnInset = rowInset

    var onWillShow: (() -> Void)?
    var onLaunchAtLoginChanged: ((Bool) -> Void)?
    var onOpenLoginItems: (() -> Void)?
    var onRetryInstallation: (() -> Void)?
    var onOpenFrontend: (() -> Void)?
    var onShowError: ((String) -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onQuit: (() -> Void)?

    private let popover = NSPopover()
    private let contentController = PopoverContentViewController()
    private let scrollView = NSScrollView()
    private let bodyStack = NSStackView()
    private let installationProgress = NSProgressIndicator()

    private var snapshot = ServiceSnapshot()
    private var loginItemState: LoginItemState = .disabled
    private var presentation = PopoverPresentation.make(snapshot: ServiceSnapshot())
    private var visibilityState: PopoverVisibilityState = .hidden
    private weak var statusButton: NSStatusBarButton?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localKeyMonitor: Any?

    override init() {
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

        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.contentSize.width),
            root.heightAnchor.constraint(equalToConstant: Self.contentSize.height),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.bottomAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.bottomAnchor),
            bodyStack.topAnchor.constraint(equalTo: document.topAnchor),
            bodyStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            bodyStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            bodyStack.widthAnchor.constraint(equalToConstant: Self.contentSize.width)
        ])
        return root
    }

    private func rebuild() {
        presentation = PopoverPresentation.make(snapshot: snapshot)
        rebuildBody()
    }

    private func rebuildBody() {
        bodyStack.arrangedSubviews.forEach {
            bodyStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        buildCommandBody()
    }

    /// The body: one consistent text-only command list.
    private func buildCommandBody() {
        bodyStack.addArrangedSubview(commandRow(
            title: "Open",
            action: #selector(openFrontendCommand),
            isEnabled: presentation.canOpenFrontend,
            toolTip: presentation.canOpenFrontend
                ? frontendTooltip
                : "The frontend can be opened once the ForgeCode service is running"
        ))

        if let progress = presentation.installationProgress {
            bodyStack.addArrangedSubview(installationProgressView(progress))
            bodyStack.addArrangedSubview(groupSpacer())
        } else if presentation.retryInstallationEnabled {
            bodyStack.addArrangedSubview(noteView(presentation.actionableError ?? "Runtime installation failed."))
            bodyStack.addArrangedSubview(commandRow(
                title: "Retry Runtime Installation",
                action: #selector(retryInstallationCommand),
                isProminent: true
            ))
            bodyStack.addArrangedSubview(groupSpacer())
        }

        bodyStack.addArrangedSubview(commandRow(
            title: launchAtLoginTitle,
            action: #selector(toggleLaunchAtLoginCommand),
            isOn: loginItemState == .enabled,
            isEnabled: launchAtLoginAvailable,
            isToggle: true,
            trailingText: loginItemState == .enabled ? "✓" : nil
        ))
        if loginItemState == .requiresApproval {
            bodyStack.addArrangedSubview(commandRow(
                title: "Approve in Login Items",
                action: #selector(openLoginItemsCommand)
            ))
        } else if case .unavailable(let message) = loginItemState {
            bodyStack.addArrangedSubview(noteView("Login item unavailable: \(message)"))
        }
        bodyStack.addArrangedSubview(commandRow(
            title: "Check for Updates",
            action: #selector(checkForUpdatesCommand)
        ))
        if presentation.actionableError != nil {
            bodyStack.addArrangedSubview(commandRow(
                title: "Show Error Details",
                action: #selector(showErrorCommand)
            ))
        }
        bodyStack.addArrangedSubview(commandRow(
            title: "Quit",
            action: #selector(quitCommand),
            trailingText: "⌘Q"
        ))
    }

    private func installationProgressView(
        _ progress: PopoverPresentation.InstallationProgress
    ) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        installationProgress.minValue = 0
        installationProgress.maxValue = 1
        installationProgress.controlSize = .small
        installationProgress.style = .bar
        installationProgress.translatesAutoresizingMaskIntoConstraints = false
        switch progress {
        case .indeterminate(let accessibilityLabel):
            label.stringValue = accessibilityLabel
            installationProgress.isIndeterminate = true
            installationProgress.startAnimation(nil)
            installationProgress.setAccessibilityLabel(accessibilityLabel)
            installationProgress.setAccessibilityValue("In progress")
        case .determinate(let value, let accessibilityLabel):
            let bounded = min(1, max(0, value))
            label.stringValue = "Downloading runtime — \(Int(bounded * 100))%"
            installationProgress.stopAnimation(nil)
            installationProgress.isIndeterminate = false
            installationProgress.doubleValue = bounded
            installationProgress.setAccessibilityLabel(accessibilityLabel)
            installationProgress.setAccessibilityValue(bounded)
        }
        container.addSubview(label)
        container.addSubview(installationProgress)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.bodyContentWidth),
            container.heightAnchor.constraint(equalToConstant: 38),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.labelColumnInset),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.rowInset),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            installationProgress.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            installationProgress.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            installationProgress.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4)
        ])
        return container
    }

    private func commandRow(
        title: String,
        action: Selector,
        isOn: Bool = false,
        isEnabled: Bool = true,
        isToggle: Bool = false,
        trailingText: String? = nil,
        isProminent: Bool = false,
        toolTip: String? = nil
    ) -> NSView {
        let row = CommandRowView(target: self, action: action)
        row.isEnabled = isEnabled
        row.configure(
            title: title,
            titleFont: .systemFont(ofSize: 12, weight: isProminent ? .semibold : .regular),
            trailingText: trailingText
        )
        row.toolTip = toolTip ?? title
        row.configureAccessibility(
            label: title,
            value: isToggle ? (isOn ? "On" : "Off") : trailingText,
            enabled: isEnabled
        )
        row.widthAnchor.constraint(equalToConstant: Self.bodyContentWidth).isActive = true
        return row
    }

    /// Group spacer: empty vertical breathing room between command groups, so
    /// groups still read as groups without drawing a hairline.
    private func groupSpacer() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.bodyContentWidth),
            container.heightAnchor.constraint(equalToConstant: 13)
        ])
        return container
    }

    /// Secondary text aligned to the label column, so it reads as a note about
    /// the row above rather than a row of its own.
    private func noteView(_ text: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10)
        label.textColor = .tertiaryLabelColor
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        let leading = Self.labelColumnInset
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.bodyContentWidth),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leading),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.rowInset),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5)
        ])
        return container
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
        applyVisibilityEvent(.popoverDidClose)
    }

    // Toggles keep the popover open so the resulting state change is visible.
    @objc private func toggleLaunchAtLoginCommand() {
        guard launchAtLoginAvailable else { return }
        onLaunchAtLoginChanged?(loginItemState != .enabled)
    }
    @objc private func retryInstallationCommand() { onRetryInstallation?() }

    // Actions that hand off to another app or window dismiss the popover first.
    @objc private func openLoginItemsCommand() { close(); onOpenLoginItems?() }
    @objc private func checkForUpdatesCommand() { close(); onCheckForUpdates?() }
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

    private var launchAtLoginAvailable: Bool {
        switch loginItemState {
        case .enabled, .disabled: return true
        case .requiresApproval, .unavailable: return false
        }
    }

}

/// A full-width, text-only menu row with a rounded highlight on hover.
private final class CommandRowView: NSView {
    static let height: CGFloat = 28
    static let inset: CGFloat = 10

    private let titleLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")
    private weak var target: AnyObject?
    private let action: Selector
    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
            applyContentColors()
        }
    }
    var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1 : 0.35
            setAccessibilityEnabled(isEnabled)
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
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
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

        addSubview(titleLabel)
        addSubview(trailingLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor,
                constant: 8
            ),
            trailingLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Self.inset
            )
        ])
    }

    func configureAccessibility(label: String, value: String?, enabled: Bool) {
        setAccessibilityLabel(label)
        setAccessibilityValue(value)
        setAccessibilityEnabled(enabled)
    }

    func configure(
        title: String,
        titleFont: NSFont,
        trailingText: String?
    ) {
        titleLabel.stringValue = title
        titleLabel.font = titleFont
        applyContentColors()
        trailingLabel.stringValue = trailingText ?? ""
        trailingLabel.isHidden = trailingText == nil
    }

    /// The hover highlight is a saturated, fully opaque fill, so row content
    /// switches to the matching foreground color to stay legible on top of it.
    private func applyContentColors() {
        if isHovered {
            let onHighlight = NSColor.alternateSelectedControlTextColor
            titleLabel.textColor = onHighlight
            trailingLabel.textColor = onHighlight.withAlphaComponent(0.75)
        } else {
            titleLabel.textColor = .labelColor
            trailingLabel.textColor = .tertiaryLabelColor
        }
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

    override var acceptsFirstResponder: Bool { isEnabled }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { needsDisplay = true }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { needsDisplay = true }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.keyCode == 36 || event.keyCode == 76 || event.charactersIgnoringModifiers == " " {
            performAction()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performAction()
        return true
    }

    override func mouseEntered(with event: NSEvent) { if isEnabled { isHovered = true } }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        performAction()
    }

    private func performAction() {
        guard isEnabled, let target else { return }
        NSApp.sendAction(action, to: target, from: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let highlight = bounds.insetBy(dx: 4, dy: 1)
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focusPath = NSBezierPath(roundedRect: highlight, xRadius: 5, yRadius: 5)
            focusPath.lineWidth = 2
            focusPath.stroke()
        }
        guard isHovered else { return }
        // Fully opaque and using the brighter accent rather than the muted
        // selection background: the previous 0.28 wash let the dark popover
        // show through and read as washed-out lavender.
        NSColor.controlAccentColor.setFill()
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
