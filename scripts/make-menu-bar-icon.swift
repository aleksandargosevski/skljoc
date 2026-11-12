#!/usr/bin/env swift
// Renders Resources/MenuBarIcon.png (18 px) and MenuBarIcon@2x.png (36 px) from Resources/MenuBarIcon.svg.
// Usage: swift scripts/make-menu-bar-icon.swift
import AppKit

let svgPath = "Resources/MenuBarIcon.svg"
guard let svg = NSImage(contentsOfFile: svgPath) else {
    FileHandle.standardError.write("Error: could not read \(svgPath)\n".data(using: .utf8)!)
    exit(1)
}

for (pixels, name) in [(18, "MenuBarIcon.png"), (36, "MenuBarIcon@2x.png")] {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        FileHandle.standardError.write("Error: could not create a bitmap\n".data(using: .utf8)!)
        exit(1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    svg.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    bitmap.size = NSSize(width: 18, height: 18)
    do {
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/\(name)"))
        print("Wrote Resources/\(name)")
    } catch {
        FileHandle.standardError.write("Error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}
