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

// Light theme is used deliberately, and is NOT just an aesthetic preference:
// Finder renders the "ForgeCode" / "Applications" icon labels itself, in a
// color derived from the *user's* system appearance, which we cannot control
// or query at build time. Most users run light appearance -> dark labels, so a
// dark background makes the labels nearly unreadable (see the dark-mode DMG
// screenshot). A light surface keeps them legible for the common case, and the
// black squircle app icon reads well against warm paper.
let colorBgBase = rgb(0xFAF9F5)      // --primitive-gray-50
let colorAccent = rgb(0xF97316)      // --primitive-orange-500

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
// (180, 210) and (480, 210) in top-based Finder coordinates. These MUST stay in
// sync with dmg-layout.applescript (icon positions, window bounds, icon size).
//
// Design intent: the background is *chrome*, not the subject. The only content
// is the two Finder icons and the drag gesture between them; the background
// carries nothing but the arrow linking them. No headline or wordmark — Finder
// already labels both icons, and the drag affordance is self-evident, so extra
// copy is redundant weight.
func drawBackground(width: CGFloat, height: CGFloat) {
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    colorBgBase.setFill()
    bounds.fill()

    // Icon slots, mirrored from dmg-layout.applescript. Finder composites the
    // real icons on top of this image at these centers.
    let iconRowTopY: CGFloat = 210
    let iconRowCenterY = height - iconRowTopY
    let slotSize: CGFloat = 96 // must match "icon size" in dmg-layout.applescript
    let appCenterX: CGFloat = 180
    let applicationsCenterX: CGFloat = 480

    // The drag path: a single horizontal arrow spanning the gap between the
    // two icons. One clear line of motion communicates "move this there" far
    // better than a dense graph, and it leaves the icons as the focal points.
    // Both ends clear the icon slots so nothing is drawn under a Finder icon.
    let gapPadding: CGFloat = 26
    let arrowStart = appCenterX + slotSize / 2 + gapPadding
    let arrowEnd = applicationsCenterX - slotSize / 2 - gapPadding
    let arrowHeadLength: CGFloat = 11
    let arrowHeadHalfHeight: CGFloat = 5.5

    // Shaft stops short of the tip so the stroke's flat end never pokes out
    // through the filled arrowhead.
    let shaft = NSBezierPath()
    shaft.lineWidth = 1.5
    shaft.lineCapStyle = .round
    // Dashed to read as a path of travel rather than a static rule or divider.
    shaft.setLineDash([5, 5], count: 2, phase: 0)
    shaft.move(to: NSPoint(x: arrowStart, y: iconRowCenterY))
    shaft.line(to: NSPoint(x: arrowEnd - arrowHeadLength + 1, y: iconRowCenterY))
    colorAccent.withAlphaComponent(0.85).setStroke()
    shaft.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: arrowEnd, y: iconRowCenterY))
    head.line(to: NSPoint(
        x: arrowEnd - arrowHeadLength,
        y: iconRowCenterY + arrowHeadHalfHeight
    ))
    head.line(to: NSPoint(
        x: arrowEnd - arrowHeadLength,
        y: iconRowCenterY - arrowHeadHalfHeight
    ))
    head.close()
    colorAccent.setFill()
    head.fill()

    FileHandle.standardError.write(Data(
        "icon slots: ForgeCode.app x=\(Int(appCenterX)) Applications x=\(Int(applicationsCenterX)) y=\(Int(iconRowTopY))\n".utf8
    ))
}

let iconImage = icon(size: 1024)
assertOpaqueCoverage(iconImage, label: "app icon")
try savePNG(iconImage, to: URL(fileURLWithPath: arguments[1]))
let backgroundData = try renderRetinaPNG(width: 660, height: 440) {
    drawBackground(width: 660, height: 440)
}
try backgroundData.write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
