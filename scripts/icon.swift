import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let side = CGFloat(pixels)
        let background = NSBezierPath(roundedRect: NSRect(x: side * 0.07, y: side * 0.07, width: side * 0.86, height: side * 0.86), xRadius: side * 0.2, yRadius: side * 0.2)
        NSGradient(starting: NSColor(srgbRed: 0.18, green: 0.62, blue: 0.49, alpha: 1), ending: NSColor(srgbRed: 0.06, green: 0.32, blue: 0.28, alpha: 1))!.draw(in: background, angle: -90)
        let config = NSImage.SymbolConfiguration(pointSize: side * 0.48, weight: .medium)
            .applying(.init(paletteColors: [.white]))
        let symbol = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
        symbol.draw(in: NSRect(x: side * 0.26, y: side * 0.23, width: side * 0.48, height: side * 0.54))
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
