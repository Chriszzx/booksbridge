import AppKit

// Package the selected transparent logo into macOS icon sizes.
let arguments = CommandLine.arguments
guard arguments.count == 3, let logo = NSImage(contentsOfFile: arguments[1]) else {
    fatalError("Usage: swift generate-icons.swift <logo.png> <output.iconset>")
}
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let size = CGFloat(pixels)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: size * 0.06, y: size * 0.06,
            width: size * 0.88, height: size * 0.88), xRadius: size * 0.20, yRadius: size * 0.20).fill()
        let width = size * 0.72
        let height = width * logo.size.height / logo.size.width
        logo.draw(in: NSRect(x: (size - width) / 2, y: (size - height) / 2,
            width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(
            to: output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
