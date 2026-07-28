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

    let scriptURL = URL(fileURLWithPath: #filePath)
    let logoURL = scriptURL.deletingLastPathComponent().appendingPathComponent("forgecode-logo-mark.svg")
    guard let logo = NSImage(contentsOf: logoURL) else {
        fatalError("could not load ForgeCode logo at \(logoURL.path)")
    }
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

func background(width: CGFloat, height: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: width, height: height)
    NSGradient(colors: [
        NSColor(calibratedWhite: 0.97, alpha: 1),
        NSColor(calibratedRed: 0.86, green: 0.91, blue: 0.98, alpha: 1)
    ])!.draw(in: rect, angle: -25)

    let title = "ForgeCode"
    let subtitle = "Drag the app to Applications"
    let center = NSMutableParagraphStyle()
    center.alignment = .center
    title.draw(
        in: NSRect(x: 20, y: height - 92, width: width - 40, height: 44),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 30, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.14, alpha: 1),
            .paragraphStyle: center
        ]
    )
    subtitle.draw(
        in: NSRect(x: 20, y: height - 125, width: width - 40, height: 28),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.32, alpha: 1),
            .paragraphStyle: center
        ]
    )

    let arrow = "→"
    arrow.draw(
        in: NSRect(x: width / 2 - 35, y: 92, width: 70, height: 70),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 54, weight: .semibold),
            .foregroundColor: NSColor(calibratedRed: 0.19, green: 0.42, blue: 0.72, alpha: 1),
            .paragraphStyle: center
        ]
    )
    image.unlockFocus()
    return image
}

try savePNG(icon(size: 1024), to: URL(fileURLWithPath: arguments[1]))
try savePNG(background(width: 660, height: 400), to: URL(fileURLWithPath: arguments[2]))
