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
    ///
    /// Width is drawn from AppKit: an `NSMenu` built from these exact labels
    /// reports an intrinsic width of 171pt. 220pt keeps headroom for the longest
    /// steady-state row ("Update ForgeCode App") without leaving the ~110pt of
    /// dead space the previous 280pt had. Error notes are not sized for here:
    /// they wrap to two lines rather than widening the panel.
    static let contentWidth: CGFloat = 220
    /// Ceiling for the fitted height. Beyond this the list scrolls rather than
    /// growing into a panel taller than the states that actually occur.
    private static let maxContentHeight: CGFloat = 420
    private static let bodyContentWidth = contentWidth - 8
    /// Horizontal inset shared by rows and notes.
    private static let rowInset: CGFloat = 12
    /// Left edge shared by command titles and supporting notes.
    private static let labelColumnInset: CGFloat = rowInset
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
        // The body is assembled first and handed to the backdrop as a single
        // content view. On macOS 26 the backdrop is an `NSGlassEffectView`,
        // which only makes placement guarantees for its `contentView` -- the
        // scroll view must not be a sibling of the effect.
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false

        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        // Rows carry their own internal padding, so the stack only needs a
        // small outer margin.
        // Native menus report 22pt per item with no inter-item gap and 10pt of
        // total chrome, so rows butt together and the panel pads 5pt each end.
        bodyStack.spacing = 0
        bodyStack.edgeInsets = NSEdgeInsets(top: 5, left: 4, bottom: 5, right: 4)
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

        body.addSubview(scrollView)

        NSLayoutConstraint.activate([
            // The width lives on the body, not the backdrop: the glass view
            // derives its own geometry from its content view.
            body.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            scrollView.topAnchor.constraint(equalTo: body.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor),
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

        return MenuBackdrop.makeRoot(content: body)
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
                title: "Retry Install",
                action: #selector(retryInstallationCommand),
                isProminent: true
            ))
            bodyStack.addArrangedSubview(groupSpacer())
        }

        // No header or spacer ahead of this row: the switch itself is enough to
        // mark it as a setting, so it sits flush with the command rows above.
        bodyStack.addArrangedSubview(commandRow(
            title: launchAtLoginTitle,
            action: #selector(toggleLaunchAtLoginCommand),
            isOn: loginItemState == .enabled,
            isEnabled: launchAtLoginAvailable,
            isToggle: true
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
        // Whitespace rather than a drawn line to fence off the two app-level
        // commands from the service rows above. An `NSBox` hairline reads as a
        // hard border against Liquid Glass, which has no internal dividers of
        // its own; the gap groups the rows without cutting the material.
        bodyStack.addArrangedSubview(groupSpacer())
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
            trailingText: trailingText,
            toggleState: isToggle ? isOn : nil,
            isProminent: isProminent
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
        label.font = Typography.note
        label.textColor = .tertiaryLabelColor
        // `.byWordWrapping`, not `.byTruncatingTail`: a truncating break mode
        // keeps the label on one line no matter what `maximumNumberOfLines`
        // says, which clipped these notes mid-word ("...failed. Check y...").
        // Wrapping needs an explicit `preferredMaxLayoutWidth` too, or the
        // label reports a single-line intrinsic height and the second line is
        // laid out but never given room.
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = Self.bodyContentWidth - Self.labelColumnInset - Self.rowInset
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
        // The approval case is carried by the subordinate "Approve in Login
        // Items" row plus the off/disabled switch, not by a title suffix: the
        // suffixed string overflowed the 280pt panel and truncated.
        "Launch at Login"
    }

    private var launchAtLoginAvailable: Bool {
        switch loginItemState {
        case .enabled, .disabled: return true
        case .requiresApproval, .unavailable: return false
        }
    }

}

/// Type scale for the menu, matched to native menus rather than chosen by eye.
/// `NSFont.menuFont(ofSize: 0)` reports 13pt at weight 5 (regular) on this OS,
/// so that is what the rows use.
enum Typography {
    /// Row titles: 13pt regular, the system menu face.
    ///
    /// This was previously medium, on the theory that regular reads thin over a
    /// translucent backdrop. It does not: vibrancy plus `labelColor` already
    /// carries the contrast, and the extra weight simply made every row look
    /// emphasised. Prominent rows no longer bump the weight either -- emphasis
    /// comes from colour, which is how native menus signal it.
    static func rowTitle(prominent: Bool) -> NSFont {
        let size: CGFloat = 13
        let base = NSFont.systemFont(ofSize: size, weight: .regular)
        // The system UI face at display sizes; falls back to `base` on any OS
        // that does not vend the descriptor.
        guard let descriptor = base.fontDescriptor.withDesign(.default) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Key equivalents. Same size as the title so the two columns sit on a
    /// shared optical baseline; it recedes via `tertiaryLabelColor`, not size.
    static let rowTrailing = NSFont.systemFont(ofSize: 13, weight: .regular)

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
    /// 22pt, measured from AppKit rather than guessed: building an `NSMenu` of
    /// N items and differencing the reported heights gives exactly 22pt per
    /// item. The previous 30pt was ~36% taller than a native menu row.
    static let height: CGFloat = 22
    static let inset: CGFloat = 12

    /// Drives the resting title colour; see `applyContentColors()`.
    private var isProminent = false

    private let titleLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")
    /// Only installed for toggle rows. `.mini` keeps the control inside the
    /// 22pt row; the regular size is 22pt tall on its own and would force every
    /// row taller to stay aligned.
    private let toggleSwitch = NSSwitch()
    private var showsToggle = false
    private var titleLeading: NSLayoutConstraint!
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
        // macOS 26 made mini/small controls taller. The row is pinned to the
        // 22pt native menu metric and the switch is `.mini` precisely to fit
        // inside it, so without this the switch outgrows the row it sits in.
        // Apple names dense popovers as the motivating case for this property.
        if #available(macOS 26.0, *) { prefersCompactControlSizeMetrics = true }
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

        toggleSwitch.translatesAutoresizingMaskIntoConstraints = false
        // `.mini` so the control fits inside the 22pt native row height; at
        // `.small` it was ~18pt tall and dominated the panel.
        toggleSwitch.controlSize = .mini
        toggleSwitch.target = self
        toggleSwitch.action = #selector(switchToggled)
        toggleSwitch.isHidden = true
        toggleSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        toggleSwitch.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(titleLabel)
        addSubview(trailingLabel)
        addSubview(toggleSwitch)

        titleLeading = titleLabel.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: Self.inset
        )

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            titleLeading,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor,
                constant: 8
            ),
            trailingLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Self.inset
            ),
            toggleSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            toggleSwitch.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor,
                constant: 8
            )
        ])
    }

    /// The switch is a passive indicator: the entire row is the click target,
    /// matching every other row in the panel. Routing clicks that land on the
    /// control to the row keeps a single toggle path — otherwise the switch
    /// would flip itself and the row's `mouseUp` would immediately flip it back.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === toggleSwitch ? self : hit
    }

    /// Only reachable via accessibility/keyboard activation of the control.
    @objc private func switchToggled() { performAction() }

    func configureAccessibility(label: String, value: String?, enabled: Bool) {
        setAccessibilityLabel(label)
        setAccessibilityValue(value)
        setAccessibilityEnabled(enabled)
    }

    func configure(
        title: String,
        titleFont: NSFont,
        trailingText: String?,
        toggleState: Bool? = nil,
        isProminent: Bool = false
    ) {
        titleLabel.stringValue = title
        titleLabel.font = titleFont
        self.isProminent = isProminent
        applyContentColors()
        showsToggle = toggleState != nil
        toggleSwitch.isHidden = !showsToggle
        if let toggleState {
            toggleSwitch.state = toggleState ? .on : .off
        }
        // The switch occupies the trailing slot, so it suppresses any key
        // equivalent there. No row needs both.
        let text = showsToggle ? nil : trailingText
        trailingLabel.stringValue = text ?? ""
        trailingLabel.isHidden = text == nil
    }

    /// Row content colour follows the highlight fill; see `draw(_:)` for why
    /// the two backdrops highlight differently.
    private func applyContentColors() {
        if isHovered {
            let onHighlight: NSColor
            switch MenuBackdrop.Backend.active {
            case .glass:
                // The glass highlight is a neutral translucent wash, not a
                // saturated fill, so the label stays the ordinary label colour.
                // `.selectedMenuItemTextColor` is white and would vanish into
                // that wash in light mode.
                onHighlight = .labelColor
            case .visualEffect:
                onHighlight = .alternateSelectedControlTextColor
            }
            titleLabel.textColor = onHighlight
            trailingLabel.textColor = onHighlight.withAlphaComponent(0.75)
        } else {
            // Prominence is carried by colour, not weight: native menus never
            // bold a row, and doing so made call-to-action rows shout.
            titleLabel.textColor = isProminent ? .controlAccentColor : .labelColor
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
        let isGlass = MenuBackdrop.Backend.active == .glass
        // One geometry for both backends, matching the panel's own radius
        // decision: the wider inset and larger radius tried on glass read as
        // over-rounded next to the system's menus.
        let highlight = bounds.insetBy(dx: 5, dy: 1)
        let radius: CGFloat = 6
        if window?.firstResponder === self {
            // A filled wash on glass rather than an accent-blue ring. System
            // menu bar popovers mark the focused row the same way they mark the
            // hovered one, so a saturated ring is the thing that looked bolted
            // on; the pre-26 path keeps the ring it has always drawn.
            if isGlass {
                NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: highlight, xRadius: radius, yRadius: radius).fill()
            } else {
                NSColor.keyboardFocusIndicatorColor.setStroke()
                let focusPath = NSBezierPath(roundedRect: highlight, xRadius: radius, yRadius: radius)
                focusPath.lineWidth = 2
                focusPath.stroke()
            }
        }
        guard isHovered else { return }
        if isGlass {
            // Neutral and translucent rather than an accent fill. The system's
            // own macOS 26 menu bar popovers (volume, Wi-Fi) highlight with a
            // plain tinted wash and let the glass show through; a saturated
            // accent slab is what made this panel read as non-native. This
            // colour is the system's non-emphasised selection, so it also
            // tracks light/dark and the user's accent-free preference.
            NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
        } else {
            // Fully opaque and using the brighter accent rather than the muted
            // selection background: over `NSVisualEffectView` a translucent wash
            // lets the blurred backdrop through and reads as washed-out lavender.
            NSColor.controlAccentColor.setFill()
        }
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
