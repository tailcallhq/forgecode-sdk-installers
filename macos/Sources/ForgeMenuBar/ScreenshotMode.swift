import AppKit
import ForgeMenuCore
import Foundation

/// A headless-ish rendering harness used to review the menu panel's appearance
/// on an OS the developer cannot boot locally.
///
/// The panel's backdrop is chosen at runtime (`MenuBackdrop`), and on macOS 26
/// it is Liquid Glass, which cannot be judged from source or from a unit test.
/// This mode drives the real `PopoverController` through a set of states and
/// captures each one so CI on a macOS 26 runner can publish the images.
///
/// Activated by `FORGE_SCREENSHOT_DIR`; the app otherwise never enters this
/// path, and the service is never started while it is active.
@MainActor
enum ScreenshotMode {
    static var requestedDirectory: URL? {
        guard let raw = ProcessInfo.processInfo.environment["FORGE_SCREENSHOT_DIR"],
              !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }

    /// One captured case: a panel state crossed with an appearance.
    private struct Scenario {
        let name: String
        let snapshot: ServiceSnapshot
        let loginItemState: PopoverController.LoginItemState
    }

    private static var scenarios: [Scenario] {
        [
            // `ready` carries an endpoint: without one the "Open" row renders
            // disabled, which is not the steady state worth reviewing.
            Scenario(
                name: "ready",
                snapshot: .init(phase: .ready, endpoint: .init(port: 9753)),
                loginItemState: .enabled
            ),
            Scenario(name: "starting", snapshot: .init(phase: .starting), loginItemState: .disabled),
            Scenario(
                name: "installing",
                snapshot: .init(phase: .installing(.downloading(progress: 0.42))),
                loginItemState: .disabled
            ),
            Scenario(
                name: "install-failed",
                snapshot: .init(phase: .installationFailed(.download)),
                loginItemState: .requiresApproval
            ),
            Scenario(
                name: "failed",
                snapshot: .init(phase: .failed("The ForgeCode service stopped unexpectedly.")),
                loginItemState: .disabled
            )
        ]
    }

    /// One unit of work: a scenario crossed with a backend and an appearance.
    private struct Shot {
        let label: String
        let scenario: Scenario
        let backend: MenuBackdrop.Backend
        let appearance: NSAppearance.Name
    }

    /// Runs every scenario, writes the captures, and terminates the app.
    ///
    /// Called from `applicationDidFinishLaunching`, so the work is queued back
    /// onto the main queue rather than driven inline: nesting a
    /// `RunLoop.run(until:)` inside the run loop AppKit is still starting stalls
    /// the app after the first capture instead of advancing to the next.
    static func run(outputDirectory: URL) {
        NSApp.setActivationPolicy(.regular)
        try? FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        writeEnvironmentReport(to: outputDirectory)

        // Liquid Glass refracts and samples whatever is behind the window, so a
        // capture taken over an empty grey desktop shows almost nothing. This
        // puts a known, high-contrast pattern behind the panel so the material
        // has something to pick up and the effect is actually visible.
        let stage = StageWindow()
        stage.orderFrontRegardless()

        let appearances: [(String, NSAppearance.Name)] = [
            ("light", .aqua),
            ("dark", .darkAqua)
        ]

        // On macOS 26 both materials are reachable, so both are captured: the
        // glass the OS would pick, and the fallback that macOS 13-15 users
        // actually see. Below 26 only the fallback exists.
        let backends: [(String, MenuBackdrop.Backend)]
        switch MenuBackdrop.Backend.supported {
        case .glass:
            backends = [("glass", .glass), ("legacy", .visualEffect)]
        case .visualEffect:
            backends = [("legacy", .visualEffect)]
        }

        var shots: [Shot] = []
        for (backendName, backend) in backends {
            for (appearanceName, appearance) in appearances {
                for scenario in scenarios {
                    let label = String(
                        format: "%@-%02d-%@-%@",
                        backendName, shots.count + 1, scenario.name, appearanceName
                    )
                    shots.append(Shot(
                        label: label,
                        scenario: scenario,
                        backend: backend,
                        appearance: appearance
                    ))
                }
            }
        }

        captureNext(shots, index: 0, written: 0, stage: stage, into: outputDirectory)
    }

    /// Captures `shots[index]`, then reschedules itself for the next one.
    private static func captureNext(
        _ shots: [Shot],
        index: Int,
        written: Int,
        stage: StageWindow,
        into directory: URL
    ) {
        guard index < shots.count else {
            MenuBackdrop.forced = nil
            stage.orderOut(nil)
            FileHandle.standardError.write(
                Data("screenshot mode: wrote \(written) captures to \(directory.path)\n".utf8)
            )
            NSApp.terminate(nil)
            return
        }

        let shot = shots[index]
        MenuBackdrop.forced = shot.backend
        NSApp.appearance = NSAppearance(named: shot.appearance)

        let controller = PopoverController()
        controller.update(
            snapshot: shot.scenario.snapshot,
            loginItemState: shot.scenario.loginItemState
        )
        controller.presentForCapture(below: stage.anchorRectInScreen)

        // The settle lets AppKit lay the panel out and lets the backdrop sample
        // what is behind it. Glass composites asynchronously, so capturing in
        // the same turn as ordering the window front yields an untextured panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            var didWrite = false
            if let image = controller.captureWindowImage() {
                write(image, to: directory.appendingPathComponent("\(shot.label).png"))
                didWrite = true
            } else {
                FileHandle.standardError.write(
                    Data("screenshot mode: window capture failed for \(shot.label)\n".utf8)
                )
            }
            controller.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                captureNext(
                    shots,
                    index: index + 1,
                    written: written + (didWrite ? 1 : 0),
                    stage: stage,
                    into: directory
                )
            }
        }
    }

    private static func write(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    /// Records what actually rendered, so a reviewer can tell a glass capture
    /// from a fallback capture without guessing from the image.
    private static func writeEnvironmentReport(to directory: URL) {
        let process = ProcessInfo.processInfo
        let native: String
        switch MenuBackdrop.Backend.supported {
        case .glass: native = "NSGlassEffectView (Liquid Glass)"
        case .visualEffect: native = "NSVisualEffectView (.menu)"
        }
        let report = """
        os version        : \(process.operatingSystemVersionString)
        native backend    : \(native)
        NSGlassEffectView : \(NSClassFromString("NSGlassEffectView") == nil ? "absent" : "present")
        screens           : \(NSScreen.screens.map { "\($0.frame.size) @\($0.backingScaleFactor)x" })

        Files are prefixed by the backend that rendered them:
          glass-*  : NSGlassEffectView, what macOS 26 users see
          legacy-* : NSVisualEffectView .menu, what macOS 13-15 users see

        On macOS 26 both are captured, because the fallback can be forced there.
        Below macOS 26 only legacy-* exists -- glass cannot be synthesised on an
        OS whose AppKit lacks it, which is why CI also runs this on older
        runners against the same binary.

        NOTE: Liquid Glass samples content behind the window. These captures put
        a synthetic pattern behind the panel for that reason; the material will
        look different over a real desktop.

        """
        try? report.write(
            to: directory.appendingPathComponent("environment.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}

/// A backdrop window that stands in for the desktop behind the panel.
///
/// Without something textured behind it, a glass panel captured on a CI runner
/// reads as a flat grey rectangle and tells the reviewer nothing.
private final class StageWindow: NSWindow {
    /// Where the panel is anchored, standing in for the status item's frame.
    var anchorRectInScreen: NSRect {
        let origin = frame.origin
        return NSRect(x: origin.x + 220, y: frame.maxY - 24, width: 24, height: 24)
    }

    init() {
        let size = NSSize(width: 900, height: 600)
        let screenFrame = NSScreen.main?.frame ?? NSRect(origin: .zero, size: size)
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2
        )
        super.init(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = true
        hasShadow = false
        level = .normal
        contentView = StageView()
    }
}

private final class StageView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // Saturated diagonal bands: colour variation is what makes refraction,
        // tinting and edge lensing legible in a still image.
        let colors: [NSColor] = [
            .systemRed, .systemOrange, .systemYellow, .systemGreen,
            .systemTeal, .systemBlue, .systemIndigo, .systemPurple
        ]
        let bandWidth = bounds.width / CGFloat(colors.count)
        for (index, color) in colors.enumerated() {
            color.setFill()
            NSRect(
                x: CGFloat(index) * bandWidth,
                y: 0,
                width: bandWidth,
                height: bounds.height
            ).fill()
        }
        // A few light shapes so the blur has high-frequency detail to smear.
        NSColor.white.withAlphaComponent(0.85).setFill()
        for row in 0..<6 {
            for column in 0..<9 {
                let dot = NSRect(
                    x: CGFloat(column) * 100 + 20,
                    y: CGFloat(row) * 100 + 20,
                    width: 26,
                    height: 26
                )
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }
}
