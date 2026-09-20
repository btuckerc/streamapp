import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let tile = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 210, yRadius: 210)
        NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.24, blue: 0.56, alpha: 1), ending: NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.22, alpha: 1))!.draw(in: tile, angle: -70)
        NSColor(calibratedWhite: 1, alpha: 0.92).setStroke()
        let screen = NSBezierPath(roundedRect: NSRect(x: 182, y: 290, width: 660, height: 462), xRadius: 55, yRadius: 55)
        screen.lineWidth = 28; screen.stroke()
        NSColor(calibratedRed: 0.27, green: 0.85, blue: 0.8, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 624, y: 330, width: 176, height: 382), xRadius: 24, yRadius: 24).fill()
        NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 324, y: 495, width: 130, height: 130)).fill()
        NSBezierPath(roundedRect: NSRect(x: 284, y: 368, width: 210, height: 104), xRadius: 50, yRadius: 50).fill()
        NSColor(calibratedWhite: 0.12, alpha: 0.5).setFill()
        for y in [598, 542, 486] {
            NSBezierPath(roundedRect: NSRect(x: 654, y: y, width: 116, height: 15), xRadius: 7, yRadius: 7).fill()
        }
        NSColor(calibratedWhite: 1, alpha: 0.75).setFill()
        NSBezierPath(roundedRect: NSRect(x: 376, y: 216, width: 272, height: 24), xRadius: 12, yRadius: 12).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
