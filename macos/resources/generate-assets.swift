#!/usr/bin/env swift
import AppKit
import Foundation

let arguments = CommandLine.arguments
if arguments.count != 3 {
    fputs("usage: generate-assets.swift ICON_PNG BACKGROUND_PNG\n", stderr)
    exit(64)
}

func savePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Assets", code: 1)
    }
    try data.write(to: url, options: .atomic)
}

// Draw the committed SVG mark as a native AppKit path. Keeping the path in
// vector form until the final icon bitmap avoids the two raster resampling
// passes that previously softened the logo at Finder and Dock sizes. This is
// deterministic and does not rely on AppKit's private SVG image renderer.
func logoPath() -> NSBezierPath {
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

func drawLogo(in rect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: rect.minX, yBy: rect.maxY)
    transform.scaleX(by: rect.width / 32, yBy: -rect.height / 32)
    transform.concat()
    NSColor.black.setFill()
    logoPath().fill()
    NSGraphicsContext.restoreGraphicsState()
}

// Guard against a silently empty rasterization: sample the bitmap and require
// a minimum number of non-transparent pixels, otherwise abort the build.
func assertOpaqueCoverage(_ image: NSImage, label: String) {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else {
        fatalError("\(label): could not read rendered bitmap")
    }
    var opaqueSamples = 0
    let step = max(1, min(bitmap.pixelsWide, bitmap.pixelsHigh) / 64)
    for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
            if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.01 {
                opaqueSamples += 1
            }
        }
    }
    guard opaqueSamples >= 32 else {
        fatalError("\(label): rendered image is blank (opaqueSamples=\(opaqueSamples))")
    }
}

func icon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.07
    let rounded = NSBezierPath(
        roundedRect: rect.insetBy(dx: inset, dy: inset),
        xRadius: size * 0.21,
        yRadius: size * 0.21
    )
    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    rounded.fill()

    let logoInset = size * 0.25
    drawLogo(in: rect.insetBy(dx: logoInset, dy: logoInset))
    image.unlockFocus()
    return image
}

// ForgeCode desktop design tokens (design-tokens.css) — warm neutrals + orange brand.
func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let colorBgBase = rgb(0xFAF9F5)      // --primitive-gray-50
let colorTextPrimary = rgb(0x232427) // --primitive-gray-900
let colorTextSubtle = rgb(0x7A7260)  // --primitive-gray-500
let colorAccent = rgb(0xF97316)      // --primitive-orange-500
let colorMonoText = rgb(0xC2410C)    // --primitive-orange-700 (--color-mono-text)

// Renders at 2x pixel density with a 144 DPI tag so Finder shows the image at
// point size on both retina and non-retina displays without blur.
func renderRetinaPNG(width: Int, height: Int, draw: () -> Void) throws -> Data {
    let scale = 2
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width * scale,
        pixelsHigh: height * scale,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { throw NSError(domain: "Assets", code: 2) }
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        NSGraphicsContext.restoreGraphicsState()
        throw NSError(domain: "Assets", code: 3)
    }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    draw()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Assets", code: 4)
    }
    return data
}

// DMG window background. Coordinates are bottom-left based; the Finder window
// content area is 660x440 and the app/Applications icons sit centered at
// (180, 210) and (480, 210) in top-based Finder coordinates (dmg-layout.applescript).
// The extra vertical slack (vs. the old 660x400) keeps the icon labels and the
// footer visible even when Finder chrome (path/status bar) shrinks the content
// area on some setups.
func drawBackground(width: CGFloat, height: CGFloat) {
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    colorBgBase.setFill()
    bounds.fill()

    // Diagonal grid texture — the desktop app's `.grid-background` stripes,
    // rendered at a whisper so it reads as paper grain, not noise.
    let stripeSpacing: CGFloat = 6
    let stripe = NSBezierPath()
    stripe.lineWidth = stripeSpacing / 2
    var offset = -height
    while offset < width + height {
        stripe.move(to: NSPoint(x: offset, y: 0))
        stripe.line(to: NSPoint(x: offset + height, y: height))
        offset += stripeSpacing
    }
    rgb(0x000000, alpha: 0.02).setStroke()
    stripe.stroke()

    // Center row: a neural net links the two icons — a single input
    // neuron fed by the ForgeCode icon fans out through widening,
    // fully-connected layers (1 -> 3 -> 5 -> 6 -> 7), and the output layer
    // wires into the Applications folder.
    // The real Finder icons sit in the operand slots; dmg-layout.applescript
    // positions them at the slot centers printed below (icon size 96).
    let iconRowCenterY = height - 210
    let slotSize: CGFloat = 96 // must match "icon size" in dmg-layout.applescript
    let appCenterX = Int(180)
    let applicationsCenterX = Int(480)

    // Both ends clear the Finder icons by 12pt so no neuron is ever drawn
    // underneath an icon (Finder composites the icons on top of this image).
    let netLeft = CGFloat(appCenterX) + slotSize / 2 + 12
    let netRight = CGFloat(applicationsCenterX) - slotSize / 2 - 12
    let layerCounts = [1, 3, 5, 6, 7]
    let neuronSpacing: CGFloat = 20
    // Non-uniform horizontal gaps. Wire count per gap grows fast
    // (3, 15, 30, 42), so later gaps are widened to keep the *visual* wire
    // density roughly even instead of bunching up on the right.
    let layerGapWeights: [CGFloat] = [0.62, 0.86, 1.16, 1.36]
    let layerXs: [CGFloat] = {
        let span = netRight - netLeft
        let unit = span / layerGapWeights.reduce(0, +)
        var xs: [CGFloat] = [netLeft]
        for weight in layerGapWeights {
            xs.append(xs[xs.count - 1] + weight * unit)
        }
        return xs
    }()
    // Neuron centers per layer, vertically centered on the icon row.
    let layers: [[NSPoint]] = zip(layerCounts, layerXs).map { count, lx in
        (0..<count).map { i in
            let offset = (CGFloat(i) - CGFloat(count - 1) / 2) * neuronSpacing
            return NSPoint(x: lx, y: iconRowCenterY + offset)
        }
    }

    // Wires first (under the neurons): thin, subtle orange.
    let wire = NSBezierPath()
    wire.lineWidth = 1
    // ForgeCode icon -> input neuron. The wire originates at the icon's
    // horizontal center; the icon itself is drawn by Finder on top, so the
    // line visually emerges from the middle of the logo.
    wire.move(to: NSPoint(x: CGFloat(appCenterX), y: iconRowCenterY))
    wire.line(to: layers[0][0])
    // Fully-connected wires between adjacent layers.
    for l in 0..<(layers.count - 1) {
        for a in layers[l] {
            for b in layers[l + 1] {
                wire.move(to: a)
                wire.line(to: b)
            }
        }
    }
    // Output layer -> Applications icon (wires converge into the folder's
    // horizontal center; Finder draws the icon on top of them).
    let appsCenter = NSPoint(x: CGFloat(applicationsCenterX), y: iconRowCenterY)
    for neuron in layers[layers.count - 1] {
        wire.move(to: neuron)
        wire.line(to: appsCenter)
    }
    colorAccent.withAlphaComponent(0.35).setStroke()
    wire.stroke()

    // Neurons on top: filled orange dots with a paper-colored ring so they
    // pop cleanly off the crossing wires.
    let neuronRadius: CGFloat = 4.5
    for layer in layers {
        for center in layer {
            let dotRect = NSRect(
                x: center.x - neuronRadius,
                y: center.y - neuronRadius,
                width: neuronRadius * 2,
                height: neuronRadius * 2
            )
            let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: -2, dy: -2))
            colorBgBase.setFill()
            ring.fill()
            let dot = NSBezierPath(ovalIn: dotRect)
            colorAccent.setFill()
            dot.fill()
        }
    }
    FileHandle.standardError.write(Data(
        "icon slots: ForgeCode.app x=\(appCenterX) Applications x=\(applicationsCenterX) y=210\n".utf8
    ))
}

let iconImage = icon(size: 1024)
assertOpaqueCoverage(iconImage, label: "app icon")
try savePNG(iconImage, to: URL(fileURLWithPath: arguments[1]))
let backgroundData = try renderRetinaPNG(width: 660, height: 440) {
    drawBackground(width: 660, height: 440)
}
try backgroundData.write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
