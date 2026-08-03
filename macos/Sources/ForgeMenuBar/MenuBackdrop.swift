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

        static var active: Backend {
            if #available(macOS 26.0, *) { return .glass }
            return .visualEffect
        }
    }

    /// Corner radius of the panel.
    ///
    /// macOS 26 popovers are rounded noticeably more generously than the 10pt
    /// that matched the pre-26 menu silhouette, so this tracks the backend
    /// instead of being one fixed constant.
    static var cornerRadius: CGFloat {
        switch Backend.active {
        case .glass: return 16
        case .visualEffect: return 10
        }
    }

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

        if #available(macOS 26.0, *) {
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
