import AppKit

/// Original StreamApp mark: three swept ribbons form a wing, not a display/share glyph.
/// Both states are templates so AppKit owns contrast, including menu highlighting.
@MainActor
enum StudioMark {
    static let idle = image(recording: false)
    static let recording = image(recording: true)

    private static func image(recording: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            context.saveGState()
            context.translateBy(x: 1, y: 0.25)
            context.scaleBy(x: 0.68, y: 0.68)
            let wing = CGMutablePath()
            wing.move(to: CGPoint(x: 1, y: 17))
            wing.addCurve(to: CGPoint(x: 23, y: 2), control1: CGPoint(x: 3, y: 8), control2: CGPoint(x: 11, y: 2))
            wing.addCurve(to: CGPoint(x: 10, y: 14), control1: CGPoint(x: 17, y: 5), control2: CGPoint(x: 13, y: 9))
            wing.addCurve(to: CGPoint(x: 1, y: 17), control1: CGPoint(x: 6, y: 14), control2: CGPoint(x: 3, y: 15))
            wing.closeSubpath()
            wing.move(to: CGPoint(x: 3, y: 21))
            wing.addCurve(to: CGPoint(x: 22, y: 10), control1: CGPoint(x: 6, y: 14), control2: CGPoint(x: 13, y: 10))
            wing.addCurve(to: CGPoint(x: 12, y: 20), control1: CGPoint(x: 17, y: 13), control2: CGPoint(x: 14, y: 16))
            wing.addCurve(to: CGPoint(x: 3, y: 21), control1: CGPoint(x: 8, y: 19), control2: CGPoint(x: 5, y: 19))
            wing.closeSubpath()
            wing.move(to: CGPoint(x: 7, y: 24))
            wing.addCurve(to: CGPoint(x: 21, y: 18), control1: CGPoint(x: 10, y: 20), control2: CGPoint(x: 15, y: 18))
            wing.addCurve(to: CGPoint(x: 14, y: 25), control1: CGPoint(x: 17, y: 20), control2: CGPoint(x: 15, y: 23))
            wing.addCurve(to: CGPoint(x: 7, y: 24), control1: CGPoint(x: 11, y: 23), control2: CGPoint(x: 9, y: 23))
            wing.closeSubpath()
            context.addPath(wing); context.fillPath()
            context.restoreGState()
            if recording { context.fillEllipse(in: CGRect(x: 18.6, y: 0.6, width: 4.8, height: 4.8)) }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = recording ? "StreamApp — recording or broadcasting" : "StreamApp — idle"
        return image
    }
}
