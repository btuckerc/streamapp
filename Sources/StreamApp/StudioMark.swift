import AppKit

/// A screen with a webcam cameo breaking its lower-right corner, echoing the app icon.
/// The cameo is hollow when idle and filled during a session. Both states are templates
/// so AppKit owns contrast, including menu highlighting.
@MainActor
enum StudioMark {
    static let idle = image(recording: false)
    static let recording = image(recording: true)

    private static func image(recording: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineWidth(1.5)
            // Clip out the cameo's clearance instead of erasing: AppKit may run this handler
            // directly in the menu bar's context. The cameo's outer radius is 4 pt in both states.
            let center = CGPoint(x: 16.75, y: 12.5)
            context.saveGState()
            context.addRect(CGRect(x: 0, y: 0, width: 22, height: 18))
            context.addEllipse(in: CGRect(x: center.x - 5.25, y: center.y - 5.25, width: 10.5, height: 10.5))
            context.clip(using: .evenOdd)
            context.addPath(CGPath(roundedRect: CGRect(x: 1.5, y: 1.75, width: 16, height: 11.5),
                                   cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
            context.strokePath()
            context.restoreGState()
            if recording {
                context.fillEllipse(in: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
            } else {
                context.setLineWidth(1.25)
                context.strokeEllipse(in: CGRect(x: center.x - 3.375, y: center.y - 3.375, width: 6.75, height: 6.75))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = recording ? "StreamApp — recording or broadcasting" : "StreamApp — idle"
        return image
    }
}
