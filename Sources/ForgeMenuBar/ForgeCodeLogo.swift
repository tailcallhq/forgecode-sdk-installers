import AppKit

@MainActor
enum ForgeCodeLogo {
    static func statusImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.cgContext.saveGState()
            let scale = min(rect.width, rect.height) / 32
            NSGraphicsContext.current?.cgContext.translateBy(x: rect.minX, y: rect.maxY)
            NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: -scale)
            logoPath().fill()
            NSGraphicsContext.current?.cgContext.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ForgeCode"
        return image
    }

    private static func logoPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 31, y: 14.7334))
        path.line(to: NSPoint(x: 31, y: 17.7344))
        path.curve(to: NSPoint(x: 28.8967, y: 19.844), controlPoint1: NSPoint(x: 29.8405, y: 17.7344), controlPoint2: NSPoint(x: 28.8967, y: 18.6797))
        path.line(to: NSPoint(x: 28.8967, y: 24.2792))
        path.curve(to: NSPoint(x: 24.1839, y: 28.9997), controlPoint1: NSPoint(x: 28.8967, y: 26.884), controlPoint2: NSPoint(x: 26.7815, y: 28.9997))
        path.line(to: NSPoint(x: 17.6344, y: 28.9997))
        path.line(to: NSPoint(x: 19.432, y: 25.9987))
        path.line(to: NSPoint(x: 24.1839, y: 25.9987))
        path.curve(to: NSPoint(x: 25.9006, y: 24.2792), controlPoint1: NSPoint(x: 25.1306, y: 25.9987), controlPoint2: NSPoint(x: 25.9006, y: 25.2275))
        path.line(to: NSPoint(x: 25.9006, y: 19.844))
        path.curve(to: NSPoint(x: 27.3927, y: 16.2339), controlPoint1: NSPoint(x: 25.9006, y: 18.4336), controlPoint2: NSPoint(x: 26.4729, y: 17.1612))
        path.curve(to: NSPoint(x: 25.9006, y: 12.6267), controlPoint1: NSPoint(x: 26.4729, y: 15.3096), controlPoint2: NSPoint(x: 25.9006, y: 14.0342))
        path.line(to: NSPoint(x: 25.9006, y: 7.71752))
        path.curve(to: NSPoint(x: 24.1839, y: 6.00097), controlPoint1: NSPoint(x: 25.9006, y: 6.77222), controlPoint2: NSPoint(x: 25.1306, y: 6.00097))
        path.line(to: NSPoint(x: 19.2133, y: 6.00097))
        path.curve(to: NSPoint(x: 17.4966, y: 7.71752), controlPoint1: NSPoint(x: 18.2666, y: 6.00097), controlPoint2: NSPoint(x: 17.4966, y: 6.77222))
        path.line(to: NSPoint(x: 17.4966, y: 14.7334))
        path.line(to: NSPoint(x: 21.9068, y: 14.7334))
        path.line(to: NSPoint(x: 21.9068, y: 17.7344))
        path.line(to: NSPoint(x: 17.4966, y: 17.7344))
        path.line(to: NSPoint(x: 17.4966, y: 24.2792))
        path.curve(to: NSPoint(x: 12.7867, y: 28.9997), controlPoint1: NSPoint(x: 17.4966, y: 26.884), controlPoint2: NSPoint(x: 15.3843, y: 28.9997))
        path.line(to: NSPoint(x: 7.81614, y: 28.9997))
        path.curve(to: NSPoint(x: 3.10327, y: 24.2792), controlPoint1: NSPoint(x: 5.21852, y: 28.9997), controlPoint2: NSPoint(x: 3.10327, y: 26.884))
        path.line(to: NSPoint(x: 3.10327, y: 19.844))
        path.curve(to: NSPoint(x: 1, y: 17.7344), controlPoint1: NSPoint(x: 3.10327, y: 18.6797), controlPoint2: NSPoint(x: 2.15949, y: 17.7344))
        path.line(to: NSPoint(x: 1, y: 14.7334))
        path.curve(to: NSPoint(x: 3.10327, y: 12.6267), controlPoint1: NSPoint(x: 2.15949, y: 14.7334), controlPoint2: NSPoint(x: 3.10327, y: 13.7881))
        path.line(to: NSPoint(x: 3.10327, y: 7.71752))
        path.curve(to: NSPoint(x: 7.81614, y: 3), controlPoint1: NSPoint(x: 3.10327, y: 5.11568), controlPoint2: NSPoint(x: 5.21852, y: 3))
        path.line(to: NSPoint(x: 14.3656, y: 3))
        path.line(to: NSPoint(x: 12.568, y: 6.00097))
        path.line(to: NSPoint(x: 7.81614, y: 6.00097))
        path.curve(to: NSPoint(x: 6.09937, y: 7.71752), controlPoint1: NSPoint(x: 6.86937, y: 6.00097), controlPoint2: NSPoint(x: 6.09937, y: 6.77222))
        path.line(to: NSPoint(x: 6.09937, y: 12.6267))
        path.curve(to: NSPoint(x: 4.60731, y: 16.2339), controlPoint1: NSPoint(x: 6.09937, y: 14.0342), controlPoint2: NSPoint(x: 5.52711, y: 15.3096))
        path.curve(to: NSPoint(x: 6.09937, y: 19.844), controlPoint1: NSPoint(x: 5.52711, y: 17.1612), controlPoint2: NSPoint(x: 6.09937, y: 18.4336))
        path.line(to: NSPoint(x: 6.09937, y: 24.2792))
        path.curve(to: NSPoint(x: 7.81614, y: 25.9987), controlPoint1: NSPoint(x: 6.09937, y: 25.2275), controlPoint2: NSPoint(x: 6.86937, y: 25.9987))
        path.line(to: NSPoint(x: 12.7867, y: 25.9987))
        path.curve(to: NSPoint(x: 14.5005, y: 24.2792), controlPoint1: NSPoint(x: 13.7305, y: 25.9987), controlPoint2: NSPoint(x: 14.5005, y: 25.2275))
        path.line(to: NSPoint(x: 14.5005, y: 7.71752))
        path.curve(to: NSPoint(x: 19.2133, y: 3), controlPoint1: NSPoint(x: 14.5005, y: 5.11568), controlPoint2: NSPoint(x: 16.6157, y: 3))
        path.line(to: NSPoint(x: 24.1839, y: 3))
        path.curve(to: NSPoint(x: 28.8967, y: 7.71752), controlPoint1: NSPoint(x: 26.7815, y: 3), controlPoint2: NSPoint(x: 28.8967, y: 5.11568))
        path.line(to: NSPoint(x: 28.8967, y: 12.6267))
        path.curve(to: NSPoint(x: 31, y: 14.7334), controlPoint1: NSPoint(x: 28.8967, y: 13.7881), controlPoint2: NSPoint(x: 29.8405, y: 14.7334))
        path.close()
        return path
    }
}
