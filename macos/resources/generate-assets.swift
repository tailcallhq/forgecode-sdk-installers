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

func loadLogo() -> NSImage {
    let scriptURL = URL(fileURLWithPath: #filePath)
    let logoURL = scriptURL.deletingLastPathComponent().appendingPathComponent("forgecode-logo-mark.svg")
    guard let logo = NSImage(contentsOf: logoURL) else {
        fatalError("could not load ForgeCode logo at \(logoURL.path)")
    }
    return logo
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

    let logo = loadLogo()
    let logoInset = size * 0.25
    logo.draw(
        in: rect.insetBy(dx: logoInset, dy: logoInset),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
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

    // Brand header, top-left: logo mark + wordmark (JetBrains Toolbox style).
    let markSize: CGFloat = 30
    let markRect = NSRect(x: 30, y: height - 30 - markSize, width: markSize, height: markSize)
    loadLogo().draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1)
    let wordmark = NSAttributedString(
        string: "ForgeCode",
        attributes: [
            .font: NSFont.systemFont(ofSize: 19, weight: .bold),
            .foregroundColor: colorTextPrimary,
        ]
    )
    let wordmarkSize = wordmark.size()
    wordmark.draw(at: NSPoint(
        x: markRect.maxX + 10,
        y: markRect.midY - wordmarkSize.height / 2
    ))

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

try savePNG(icon(size: 1024), to: URL(fileURLWithPath: arguments[1]))
let backgroundData = try renderRetinaPNG(width: 660, height: 440) {
    drawBackground(width: 660, height: 440)
}
try backgroundData.write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
