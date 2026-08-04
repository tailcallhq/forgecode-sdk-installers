import AppKit

/// The material behind the menu panel.
///
/// macOS 26 introduced Liquid Glass, which is what the system's own menu bar
/// popovers use. `NSVisualEffectView` was not deprecated by that release, but it
/// also did not adopt the new material: `.menu` still renders the pre-26 frosted
/// blur. Left alone, the panel would read as a macOS 15 menu sitting next to
/// system surfaces that had moved on, so the backend is chosen per OS.
///
/// See `docs/liquid-glass-adoption.md` for the decision record.
enum MenuBackdrop {
    /// Which material is in use. Callers whose own styling has to follow the
    /// backdrop -- corner radius and the row highlight -- branch on this rather
    /// than repeating the availability check.
    enum Backend {
        case glass
        case visualEffect

        /// What this OS would use on its own.
        static var supported: Backend {
            if #available(macOS 26.0, *) { return .glass }
            return .visualEffect
        }

        static var active: Backend {
            // An override can only ever step *down* to the fallback: glass
            // cannot be conjured on an OS whose AppKit does not have it.
            if forced == .visualEffect { return .visualEffect }
            return supported
        }
    }

    /// Pins the backend regardless of OS. Only the screenshot harness sets this,
    /// so a reviewer on macOS 26 can also see what macOS 13-15 users get; the
    /// shipping app always follows the OS.
    static var forced: Backend?

    /// Corner radius of the panel.
    ///
    /// One value for both backends. A larger radius was tried on glass on the
    /// theory that macOS 26 rounds popovers more generously, but at this panel's
    /// size it read as overly bubbled rather than native, so both paths keep the
    /// 10pt that matches the system menu silhouette.
    static let cornerRadius: CGFloat = 10

    /// Wraps `content` in the backdrop and returns the view to use as the
    /// panel's root.
    ///
    /// `content` must be the whole panel body. On the glass path it becomes the
    /// glass view's `contentView`, which is the only placement AppKit makes
    /// guarantees about: arbitrary subviews of an `NSGlassEffectView` have
    /// undefined z-order with respect to the effect, and a glass view installed
    /// *behind* content as a sibling is explicitly wrong.
    static func makeRoot(content: NSView) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        let radius = cornerRadius

        if #available(macOS 26.0, *), Backend.active == .glass {
            let glass = NSGlassEffectView()
            glass.translatesAutoresizingMaskIntoConstraints = false
            // `.regular` is the variant the HIG names for popovers: it adapts
            // luminosity to keep text legible. `.clear` is for floating over
            // photo/video content and would wash these rows out.
            glass.style = .regular
            // Deliberately the view's own `cornerRadius` and not a layer mask.
            // Glass samples a region larger than itself to refract what is
            // behind the window; clipping the layer clips that sampling region
            // and flattens the effect into a plain blur with hard corners.
            glass.cornerRadius = radius
            // `cornerRadius` alone only rounds the glass; the content view and
            // its rows keep painting square right out to the bounds, so the
            // corners read as pointy tabs poking past the curve and any row
            // highlight squares off the top and bottom of the panel. Clipping
            // is what makes the content follow the same silhouette.
            glass.clipsToBounds = true
            // Assigning `contentView` also installs the Auto Layout ties
            // between the two, so the glass tracks the body's geometry.
            glass.contentView = content
            return glass
        }

        let backdrop = NSVisualEffectView()
        // `.menu` is the material the pre-26 system menus themselves use, so
        // the panel picks up the same translucency and blur rather than the
        // flatter, heavier `.hudWindow` wash.
        backdrop.material = .menu
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        // Deliberately no explicit `appearance`: leaving it nil lets the view
        // inherit the system light/dark setting, matching every other menu bar
        // panel. Pinning it to .darkAqua forced a dark menu onto light-mode
        // users.
        backdrop.wantsLayer = true
        // The mask (rather than layer.cornerRadius) is what clips a
        // behind-window blend correctly; a plain cornerRadius leaves the
        // blurred backdrop showing square corners underneath. This is the
        // legacy path only -- see the glass branch above.
        backdrop.maskImage = roundedMask(radius: radius)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: backdrop.topAnchor),
            content.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor)
        ])
        return backdrop
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
}
