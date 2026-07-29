import AppKit

@MainActor
enum ForgeCodeLogo {
    static func statusImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            let pointsPerUnit = min(rect.width, rect.height) / 32
            // The drawing handler runs once per backing store, so the current
            // transform reveals the device scale (1x, 2x, ...). Snapping the
            // path to that device-pixel grid is what keeps the mark crisp: an
            // unsnapped 18/32 scale puts every edge between pixels and renders
            // mostly anti-aliasing fringe on non-Retina displays.
            let deviceScale = max(1, abs(context.ctm.a).rounded())
            let grid = PixelGrid(pixelsPerUnit: pointsPerUnit * deviceScale)
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: pointsPerUnit, y: -pointsPerUnit)
            logoPath(on: grid).fill()
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ForgeCode"
        return image
    }

    /// Grid-fits the logo's 32x32-unit coordinate space to device pixels.
    ///
    /// Generic coordinates round to the nearest device-pixel boundary. The
    /// mark's strokes are all 3 units thick, which is a fractional number of
    /// pixels at menu-bar sizes; rounding their two edges independently would
    /// produce a mix of 1px and 2px strokes. Paired stroke edges are therefore
    /// hinted together: the leading edge snaps to the grid and the trailing
    /// edge is placed a uniform whole number of pixels away.
    private struct PixelGrid {
        private let pixelsPerUnit: CGFloat
        private var xEdges: [CGFloat: CGFloat] = [:]
        private var yEdges: [CGFloat: CGFloat] = [:]

        // Leading/trailing edge coordinate pairs of every 3-unit stroke,
        // matching the literals used in logoPath(on:) exactly.
        private static let verticalStrokes: [(CGFloat, CGFloat)] = [
            (3.10327, 6.09937),
            (14.5005, 17.4966),
            (25.9006, 28.8967)
        ]
        private static let horizontalStrokes: [(CGFloat, CGFloat)] = [
            (3, 6.00097),
            (14.7334, 17.7344),
            (25.9987, 28.9997)
        ]

        init(pixelsPerUnit: CGFloat) {
            self.pixelsPerUnit = pixelsPerUnit
            let strokePixels = max(1, (3 * pixelsPerUnit).rounded())
            for (lead, trail) in Self.verticalStrokes {
                let snapped = (lead * pixelsPerUnit).rounded()
                xEdges[lead] = snapped / pixelsPerUnit
                xEdges[trail] = (snapped + strokePixels) / pixelsPerUnit
            }
            for (lead, trail) in Self.horizontalStrokes {
                let snapped = (lead * pixelsPerUnit).rounded()
                yEdges[lead] = snapped / pixelsPerUnit
                yEdges[trail] = (snapped + strokePixels) / pixelsPerUnit
            }
        }

        func x(_ value: CGFloat) -> CGFloat {
            xEdges[value] ?? (value * pixelsPerUnit).rounded() / pixelsPerUnit
        }

        func y(_ value: CGFloat) -> CGFloat {
            yEdges[value] ?? (value * pixelsPerUnit).rounded() / pixelsPerUnit
        }

        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: self.x(x), y: self.y(y))
        }
    }

    private static func logoPath(on grid: PixelGrid) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: grid.point(31, 14.7334))
        path.line(to: grid.point(31, 17.7344))
        path.curve(to: grid.point(28.8967, 19.844), controlPoint1: grid.point(29.8405, 17.7344), controlPoint2: grid.point(28.8967, 18.6797))
        path.line(to: grid.point(28.8967, 24.2792))
        path.curve(to: grid.point(24.1839, 28.9997), controlPoint1: grid.point(28.8967, 26.884), controlPoint2: grid.point(26.7815, 28.9997))
        path.line(to: grid.point(17.6344, 28.9997))
        path.line(to: grid.point(19.432, 25.9987))
        path.line(to: grid.point(24.1839, 25.9987))
        path.curve(to: grid.point(25.9006, 24.2792), controlPoint1: grid.point(25.1306, 25.9987), controlPoint2: grid.point(25.9006, 25.2275))
        path.line(to: grid.point(25.9006, 19.844))
        path.curve(to: grid.point(27.3927, 16.2339), controlPoint1: grid.point(25.9006, 18.4336), controlPoint2: grid.point(26.4729, 17.1612))
        path.curve(to: grid.point(25.9006, 12.6267), controlPoint1: grid.point(26.4729, 15.3096), controlPoint2: grid.point(25.9006, 14.0342))
        path.line(to: grid.point(25.9006, 7.71752))
        path.curve(to: grid.point(24.1839, 6.00097), controlPoint1: grid.point(25.9006, 6.77222), controlPoint2: grid.point(25.1306, 6.00097))
        path.line(to: grid.point(19.2133, 6.00097))
        path.curve(to: grid.point(17.4966, 7.71752), controlPoint1: grid.point(18.2666, 6.00097), controlPoint2: grid.point(17.4966, 6.77222))
        path.line(to: grid.point(17.4966, 14.7334))
        path.line(to: grid.point(21.9068, 14.7334))
        path.line(to: grid.point(21.9068, 17.7344))
        path.line(to: grid.point(17.4966, 17.7344))
        path.line(to: grid.point(17.4966, 24.2792))
        path.curve(to: grid.point(12.7867, 28.9997), controlPoint1: grid.point(17.4966, 26.884), controlPoint2: grid.point(15.3843, 28.9997))
        path.line(to: grid.point(7.81614, 28.9997))
        path.curve(to: grid.point(3.10327, 24.2792), controlPoint1: grid.point(5.21852, 28.9997), controlPoint2: grid.point(3.10327, 26.884))
        path.line(to: grid.point(3.10327, 19.844))
        path.curve(to: grid.point(1, 17.7344), controlPoint1: grid.point(3.10327, 18.6797), controlPoint2: grid.point(2.15949, 17.7344))
        path.line(to: grid.point(1, 14.7334))
        path.curve(to: grid.point(3.10327, 12.6267), controlPoint1: grid.point(2.15949, 14.7334), controlPoint2: grid.point(3.10327, 13.7881))
        path.line(to: grid.point(3.10327, 7.71752))
        path.curve(to: grid.point(7.81614, 3), controlPoint1: grid.point(3.10327, 5.11568), controlPoint2: grid.point(5.21852, 3))
        path.line(to: grid.point(14.3656, 3))
        path.line(to: grid.point(12.568, 6.00097))
        path.line(to: grid.point(7.81614, 6.00097))
        path.curve(to: grid.point(6.09937, 7.71752), controlPoint1: grid.point(6.86937, 6.00097), controlPoint2: grid.point(6.09937, 6.77222))
        path.line(to: grid.point(6.09937, 12.6267))
        path.curve(to: grid.point(4.60731, 16.2339), controlPoint1: grid.point(6.09937, 14.0342), controlPoint2: grid.point(5.52711, 15.3096))
        path.curve(to: grid.point(6.09937, 19.844), controlPoint1: grid.point(5.52711, 17.1612), controlPoint2: grid.point(6.09937, 18.4336))
        path.line(to: grid.point(6.09937, 24.2792))
        path.curve(to: grid.point(7.81614, 25.9987), controlPoint1: grid.point(6.09937, 25.2275), controlPoint2: grid.point(6.86937, 25.9987))
        path.line(to: grid.point(12.7867, 25.9987))
        path.curve(to: grid.point(14.5005, 24.2792), controlPoint1: grid.point(13.7305, 25.9987), controlPoint2: grid.point(14.5005, 25.2275))
        path.line(to: grid.point(14.5005, 7.71752))
        path.curve(to: grid.point(19.2133, 3), controlPoint1: grid.point(14.5005, 5.11568), controlPoint2: grid.point(16.6157, 3))
        path.line(to: grid.point(24.1839, 3))
        path.curve(to: grid.point(28.8967, 7.71752), controlPoint1: grid.point(26.7815, 3), controlPoint2: grid.point(28.8967, 5.11568))
        path.line(to: grid.point(28.8967, 12.6267))
        path.curve(to: grid.point(31, 14.7334), controlPoint1: grid.point(28.8967, 13.7881), controlPoint2: grid.point(29.8405, 14.7334))
        path.close()
        return path
    }
}
