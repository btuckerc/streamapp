import AppKit

// App icon: the menu bar mark's screen + webcam cameo on a dark studio tile.
// Drawn in a 1024 canvas on Apple's macOS grid (824 pt body at a 100 pt margin), y up.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

func draw(_ c: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    c.saveGState(); c.addPath(tile); c.clip()
    c.drawLinearGradient(gradient([srgb(0x2E3552), srgb(0x181C30)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Quiet edge light: brighter along the top, darker along the bottom.
    c.addPath(tile); c.setLineWidth(8)
    c.replacePathWithStrokedPath(); c.clip()
    c.drawLinearGradient(gradient([srgb(0xFFFFFF, 0.14), srgb(0xFFFFFF, 0), srgb(0x000000, 0.18)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    c.restoreGState()

    let screen = CGRect(x: 214, y: 366, width: 520, height: 380)
    let screenPath = CGPath(roundedRect: screen, cornerWidth: 64, cornerHeight: 64, transform: nil)
    let stroke: CGFloat = 60
    let center = CGPoint(x: 700, y: 396), radius: CGFloat = 150
    let cameo = CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
    // Screen layer, with the cameo's clearance knocked out so the tile shows through.
    c.beginTransparencyLayer(auxiliaryInfo: nil)
    c.addPath(screenPath); c.setFillColor(srgb(0xFFFFFF, 0.08)); c.fillPath()
    c.addPath(screenPath); c.setStrokeColor(srgb(0xF2F4F8)); c.setLineWidth(stroke); c.strokePath()
    c.setBlendMode(.clear); c.fillEllipse(in: cameo.insetBy(dx: -stroke * 0.75, dy: -stroke * 0.75))
    c.endTransparencyLayer()

    c.saveGState(); c.addEllipse(in: cameo); c.clip()
    c.drawRadialGradient(gradient([srgb(0xFF5A47), srgb(0xE8452F)]), startCenter: CGPoint(x: center.x - 40, y: center.y + 60), startRadius: 0,
                         endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
    // Presenter: head and shoulders, about 55% of the cameo, set slightly low.
    c.setFillColor(srgb(0xFFFFFF))
    c.fillEllipse(in: CGRect(x: center.x - 50, y: center.y - 4, width: 100, height: 100))
    c.fillEllipse(in: CGRect(x: center.x - 104, y: center.y - 186, width: 208, height: 166))
    c.restoreGState()
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        draw(ctx)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
