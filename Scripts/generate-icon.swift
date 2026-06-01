#!/usr/bin/env swift
// Renders Resources/AppIcon.icns from scratch at all macOS sizes.
//
// Design: violet→blue squircle background with a centered white bolt glyph.
// Composes the menu bar's visual identity into the bundle icon so Finder /
// Dock / About panel all read as the same app.
//
// Invoked by Scripts/build.sh before bundle assembly. Safe to re-run; idempotent.
import AppKit
import CoreGraphics
import Foundation

let projectRoot: String = {
    if CommandLine.arguments.count >= 2 {
        return CommandLine.arguments[1]
    }
    return FileManager.default.currentDirectoryPath
}()

let iconsetDir = "\(projectRoot)/Resources/AppIcon.iconset"
let icnsOut = "\(projectRoot)/Resources/AppIcon.icns"

let fm = FileManager.default
if fm.fileExists(atPath: iconsetDir) {
    try? fm.removeItem(atPath: iconsetDir)
}
try fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

// macOS icon set layout — `iconutil` requires exactly these filenames.
let sizes: [(filename: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func renderIcon(size: CGFloat) -> Data? {
    let pixelSize = NSSize(width: size, height: size)
    let image = NSImage(size: pixelSize)
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return nil
    }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius: CGFloat = size * 0.2237  // Apple's squircle approximation
    let path = CGPath(
        roundedRect: rect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    // Gradient squircle background.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let colors = [
        CGColor(srgbRed: 0.27, green: 0.20, blue: 0.83, alpha: 1.0),  // violet
        CGColor(srgbRed: 0.10, green: 0.45, blue: 0.95, alpha: 1.0),  // blue
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: size),
            end: CGPoint(x: size, y: 0),
            options: []
        )
    }
    ctx.restoreGState()

    // Subtle inner highlight along the top edge for depth.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    if let highlight = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            highlight,
            start: CGPoint(x: 0, y: size),
            end: CGPoint(x: 0, y: size * 0.5),
            options: []
        )
    }
    ctx.restoreGState()

    // Centered bolt symbol in white.
    let symbolPointSize = size * 0.55
    let baseConfig = NSImage.SymbolConfiguration(
        pointSize: symbolPointSize,
        weight: .bold,
        scale: .large
    )
    let whiteConfig = baseConfig.applying(
        NSImage.SymbolConfiguration(hierarchicalColor: .white)
    )
    if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(whiteConfig)
    {
        let boltRect = CGRect(
            x: (size - bolt.size.width) / 2,
            y: (size - bolt.size.height) / 2,
            width: bolt.size.width,
            height: bolt.size.height
        )
        // Soft drop shadow so the bolt reads on the lighter blue corner.
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
        shadow.shadowBlurRadius = size * 0.03
        shadow.shadowColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25)
        shadow.set()
        bolt.draw(in: boltRect)
    }

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff)
    else { return nil }
    return bitmap.representation(using: .png, properties: [:])
}

for (filename, px) in sizes {
    guard let data = renderIcon(size: px) else {
        FileHandle.standardError.write(Data("failed to render \(filename)\n".utf8))
        exit(1)
    }
    let dest = URL(fileURLWithPath: "\(iconsetDir)/\(filename)")
    try data.write(to: dest)
}

// Bake the iconset into a single .icns via iconutil.
let convert = Process()
convert.launchPath = "/usr/bin/iconutil"
convert.arguments = ["-c", "icns", "-o", icnsOut, iconsetDir]
try convert.run()
convert.waitUntilExit()
if convert.terminationStatus != 0 {
    FileHandle.standardError.write(Data("iconutil failed with status \(convert.terminationStatus)\n".utf8))
    exit(Int32(convert.terminationStatus))
}

// Iconset directory is intermediate. .icns is the artifact we keep.
try? fm.removeItem(atPath: iconsetDir)

print("generated \(icnsOut)")
