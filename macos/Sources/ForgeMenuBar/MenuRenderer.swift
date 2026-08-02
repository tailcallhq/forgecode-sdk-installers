import AppKit
import ForgeMenuCore
import Foundation

@MainActor
final class PopoverController: NSObject {
    enum LoginItemState: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable(String)
    }

    /// The panel is width-fixed and height-fits-content: the row list is short
    /// and its length varies by state, so a fixed height would either clip the
    /// transient states or leave dead space in the steady state.
    static let contentWidth: CGFloat = 280
    /// Ceiling for the fitted height. Beyond this the list scrolls rather than
    /// growing into a panel taller than the states that actually occur.
    private static let maxContentHeight: CGFloat = 420
    private static let bodyContentWidth = contentWidth - 8
    /// Horizontal inset shared by rows and notes.
    private static let rowInset: CGFloat = 12
    /// Left edge shared by command titles and supporting notes.
    private static let labelColumnInset = rowInset
    /// Corner radius of the panel. Matches the system menu silhouette.
    private static let cornerRadius: CGFloat = 12
    /// Gap between the menu bar and the top of the panel.
    private static let menuBarGap: CGFloat = 6

    /// How far the panel's left edge extends past the status item's left
    /// edge. System menus leave a small overhang rather than aligning exactly.
    private static let leftEdgeOverhang: CGFloat = 8

    var onWillShow: (() -> Void)?
    var onLaunchAtLoginChanged: ((Bool) -> Void)?
    var onOpenLoginItems: (() -> Void)?
    var onRetryInstallation: (() -> Void)?
    var onOpenFrontend: (() -> Void)?
    var onShowError: ((String) -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onQuit: (() -> Void)?

    private let panel = MenuPanel(
        contentRect: NSRect(x: 0, y: 0, width: PopoverController.contentWidth, height: 100),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private let contentController = PopoverContentViewController()
    private let backdrop = NSVisualEffectView()
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
        configurePanel()
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

    private func configurePanel() {
        contentController.onCancel = { [weak self] in self?.close() }
        contentController.view = buildRootView()

        // A borderless panel replaces NSPopover so the menu reads as a plain
        // floating box: NSPopover always draws a callout arrow and an opaque
        // backdrop behind its content, neither of which can be turned off.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .utilityWindow
        panel.contentViewController = contentController
    }

    private func buildRootView() -> NSView {
        let root = backdrop
        // `.menu` is the material the system menus themselves use, so the panel
        // picks up the same translucency and blur rather than the flatter,
        // heavier `.hudWindow` wash.
        root.material = .menu
        root.blendingMode = .behindWindow
        root.state = .active
        // Deliberately no explicit `appearance`: leaving it nil lets the view
        // inherit the system light/dark setting, matching every other menu bar
        // panel. Pinning it to .darkAqua forced a dark menu onto light-mode
        // users.
        root.wantsLayer = true
        // The mask (rather than layer.cornerRadius) is what clips a
        // behind-window blend correctly; a plain cornerRadius leaves the
        // blurred backdrop showing square corners underneath.
        root.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        root.translatesAutoresizingMaskIntoConstraints = false

        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        // Rows carry their own internal padding, so the stack only needs a
        // small outer margin and a hairline gap between rows.
        bodyStack.spacing = 1
        bodyStack.edgeInsets = NSEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
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
            root.widthAnchor.constraint(equalToConstant: Self.contentWidth),
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
            bodyStack.widthAnchor.constraint(equalToConstant: Self.contentWidth)
        ])
        return root
    }

    /// A resizable rounded-rect mask. The center is stretched, so one image
    /// serves every panel height.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
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
        if presentation.actionableError != nil {
            bodyStack.addArrangedSubview(commandRow(
                title: "Show Error Details",
                action: #selector(showErrorCommand)
            ))
        }
        // Separator fencing off the two app-level commands from the
        // service-related rows above.
        bodyStack.addArrangedSubview(separator())
        bodyStack.addArrangedSubview(commandRow(
            // Deliberately not "Check for Updates": the bundled server updates
            // on its own cadence, so an unqualified label reads as though it
            // covers both. "App" scopes it to this menu bar app only.
            title: "Update ForgeCode App",
            action: #selector(checkForUpdatesCommand),
            toolTip: "Check for updates to the ForgeCode menu bar app (not the bundled server runtime)"
        ))
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
        label.font = Typography.note
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
            titleFont: Typography.rowTitle(prominent: isProminent),
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

    /// A hairline divider, inset to the label column so it aligns with row text
    /// rather than spanning the full panel edge to edge.
    private func separator() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.bodyContentWidth),
            container.heightAnchor.constraint(equalToConstant: 11),
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.rowInset),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.rowInset),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    /// Secondary text aligned to the label column, so it reads as a note about
    /// the row above rather than a row of its own.
    private func noteView(_ text: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: text)
        label.font = Typography.note
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
            positionPanel(relativeTo: button)
            panel.orderFrontRegardless()
            // An accessory app is not active by default, so key events would
            // otherwise be delivered to whatever app is frontmost. Activate and
            // take key focus so Escape and Command-Q reach this panel.
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            // Becoming key makes AppKit promote the first focusable row to
            // first responder, which draws a focus ring on a row the user never
            // chose. Hand focus back to the window; Tab still starts traversal.
            panel.initialFirstResponder = nil
            panel.makeFirstResponder(nil)
            installAllMonitors()
        case .close:
            removeAllMonitors()
            // The panel has no close delegate, so unlike NSPopover there is no
            // `.popoverDidClose` echo; the transition above already left the
            // state `.hidden`.
            if panel.isVisible { panel.orderOut(nil) }
        }
    }

    /// Sizes the panel to its content and pins it under the status item,
    /// clamped to the screen so it cannot run off the right edge.
    private func positionPanel(relativeTo button: NSStatusBarButton) {
        let fitted = bodyStack.fittingSize.height
        let height = min(max(fitted, 1), Self.maxContentHeight)
        // The scroll view only ever engages once content exceeds the ceiling.
        scrollView.hasVerticalScroller = fitted > Self.maxContentHeight
        panel.setContentSize(NSSize(width: Self.contentWidth, height: height))

        guard let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        // The panel left-aligns to the status item rather than centring on it,
        // so the body hangs to the right of its icon. The overhang pulls the
        // edge just past the icon so the icon does not sit flush against the
        // corner of the panel. The clamp below still catches the case where a
        // status item sits far enough right that the panel would overflow.
        var origin = NSPoint(
            x: buttonFrame.minX - Self.leftEdgeOverhang,
            y: buttonFrame.minY - height - Self.menuBarGap
        )
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - Self.contentWidth - 8)
            origin.y = max(origin.y, visible.minY + 8)
        }
        panel.setFrameOrigin(origin)
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
        guard panel.isVisible else { return false }
        return panel.frame.contains(screenPoint)
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

/// Type scale for the menu. Sizes track the system menu bar metrics rather
/// than the smaller control sizes the panel previously used, which rendered
/// cramped next to native menus like the one in the reference screenshot.
enum Typography {
    /// Row titles: 13pt medium. Regular weight at this size reads thin against
    /// a translucent backdrop, so medium is the resting weight and semibold is
    /// reserved for prominent (call-to-action) rows.
    static func rowTitle(prominent: Bool) -> NSFont {
        let size: CGFloat = 13
        let weight: NSFont.Weight = prominent ? .semibold : .medium
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        // The system UI face at display sizes; falls back to `base` on any OS
        // that does not vend the descriptor.
        guard let descriptor = base.fontDescriptor.withDesign(.default) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Key equivalents and checkmarks. A step down and lighter than the title,
    /// so the shortcut column recedes.
    static let rowTrailing = NSFont.systemFont(ofSize: 12, weight: .regular)

    /// Supporting notes and progress captions.
    static let note = NSFont.systemFont(ofSize: 11, weight: .regular)
}

/// A borderless panel that can take key focus. `NSPanel` refuses to become key
/// while borderless unless this is overridden, which would leave Escape and
/// Command-Q unhandled.
final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A full-width, text-only menu row with a rounded highlight on hover.
private final class CommandRowView: NSView {
    /// Taller than the old 28pt to match the system menu rhythm and give the
    /// 13pt title room to breathe.
    static let height: CGFloat = 30
    static let inset: CGFloat = 12

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
        trailingLabel.font = Typography.rowTrailing
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
        let highlight = bounds.insetBy(dx: 5, dy: 1)
        let radius: CGFloat = 6
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focusPath = NSBezierPath(roundedRect: highlight, xRadius: radius, yRadius: radius)
            focusPath.lineWidth = 2
            focusPath.stroke()
        }
        guard isHovered else { return }
        // Fully opaque and using the brighter accent rather than the muted
        // selection background: a translucent wash would let the blurred
        // backdrop through and read as washed-out lavender.
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: highlight, xRadius: radius, yRadius: radius).fill()
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
