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

// Load the app icon artwork from a committed hi-res raster (1600x1600 PNG)
// rather than rasterizing the SVG at build time. AppKit's private
// `_NSSVGImageRep` intermittently rasterizes to a fully transparent image on
// cold process starts, which shipped a blank/generic-glyph icon in the DMG. A
// pre-rendered PNG decodes deterministically, and `assertOpaqueCoverage` below
// fails the build if the artwork ever comes through empty again.
func loadAppIconArtwork() -> NSImage {
    let scriptURL = URL(fileURLWithPath: #filePath)
    let artworkURL = scriptURL.deletingLastPathComponent().appendingPathComponent("forgecode-app-icon.png")
    guard let artwork = NSImage(contentsOf: artworkURL) else {
        fatalError("could not load ForgeCode app icon artwork at \(artworkURL.path)")
    }
    return artwork
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

// The artwork already carries its own squircle silhouette and background, so
// it is composited full-bleed: no synthetic plate, no extra inset. Anything
// else would double up rounded corners and shrink the mark.
//
// Draws into an explicitly sized bitmap rep rather than `lockFocus()`: the
// focused-image path picks a backing scale from the source artwork's pixel
// density, so a 1600px source silently produced a 2048px "1024" master.
func icon(size: CGFloat) -> NSImage {
    let pixels = Int(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { fatalError("app icon: could not allocate \(pixels)x\(pixels) bitmap") }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("app icon: could not create drawing context")
    }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    loadAppIconArtwork().draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    context.flushGraphics()

    let image = NSImage(size: NSSize(width: size, height: size))
    image.addRepresentation(rep)
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

// Dark theme ([data-theme="dark"]) is used deliberately: the app icon artwork
// is a black squircle, which disappears into the light theme's near-white
// paper. The dark surface gives the mark a rim of contrast instead.
let colorBgBase = rgb(0x1C1D1F)      // --primitive-gray-950 (dark --color-bg-base)
let colorTextPrimary = rgb(0xE4E0D0) // --primitive-gray-200 (dark --color-text-primary)
let colorTextSubtle = rgb(0xA8A088)  // --primitive-gray-400 (dark --color-text-subtle)
let colorAccent = rgb(0xF97316)      // --primitive-orange-500 (unchanged across themes)
let colorMonoText = rgb(0xF5DFA8)    // --primitive-sand-300 (dark --color-mono-text)

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
    // rendered at a whisper so it reads as grain, not noise. Dark theme uses
    // white stripes (`--grid-line-color: rgba(255,255,255,0.05)`); black ones
    // are invisible against the near-black base.
    let stripeSpacing: CGFloat = 6
    let stripe = NSBezierPath()
    stripe.lineWidth = stripeSpacing / 2
    var offset = -height
    while offset < width + height {
        stripe.move(to: NSPoint(x: offset, y: 0))
        stripe.line(to: NSPoint(x: offset + height, y: height))
        offset += stripeSpacing
    }
    rgb(0xFFFFFF, alpha: 0.02).setStroke()
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
