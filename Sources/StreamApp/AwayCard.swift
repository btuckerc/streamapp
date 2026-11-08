import AppKit
import CoreImage
import CoreText

/// Everything the Away card's pixels depend on, so a card is drawn once per distinct look.
struct AwayCardSpec: Equatable, Sendable {
    let title: String
    let subtitle: String
    let background: AwayBackground
    let red: Double, green: Double, blue: Double
    let imagePath: String
    /// Width the chat column (plus its margin) takes from the right edge.
    let chatWidth: CGFloat

    init(_ c: StudioConfiguration) {
        let title = c.awayMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.isEmpty ? "Be right back" : title
        subtitle = c.awaySubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        background = c.awayBackground
        // Only what the chosen background reads, so unrelated edits do not redraw the card.
        let colored = c.awayBackground == .color
        red = colored ? c.awayRed : 0; green = colored ? c.awayGreen : 0; blue = colored ? c.awayBlue : 0
        imagePath = c.awayBackground == .image ? c.awayImagePath : ""
        chatWidth = c.chatEnabled ? CGFloat(min(576, max(288, c.chatWidth))) + 24 : 0
    }
}

/// A drawn card and the look it was drawn for.
struct AwayCardBake: @unchecked Sendable {
    let spec: AwayCardSpec
    let image: CGImage
}

/// The Away card: one or two lines of type on a flat surface, centred in the area chat leaves free.
enum AwayCard {
    static let canvas = CGSize(width: 1920, height: 1080)
    private static let dark = (red: 0x16 / 255.0, green: 0x18 / 255.0, blue: 0x1C / 255.0)
    private static let darkText = (red: 0x11 / 255.0, green: 0x13 / 255.0, blue: 0x16 / 255.0)
    // CIContext is thread-safe (Sendable); the card is drawn on the image queue or, on a cache miss, the compositor.
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    /// The last blurred image, shared by every session and preview so a new one starts with it.
    private static let backdropLock = NSLock()
    nonisolated(unsafe) private static var lastBackdrop: (path: String, image: CGImage?)?

    /// The blurred image for `path` if it has already been prepared; never decodes.
    static func cachedBackdrop(_ path: String) -> CGImage? {
        backdropLock.lock(); defer { backdropLock.unlock() }
        return lastBackdrop?.path == path ? lastBackdrop?.image : nil
    }
    /// The blurred image for `path`, decoded with `load` and blurred once per path. Off the compositor.
    static func preparedBackdrop(_ path: String, load: (String) -> CGImage?) -> CGImage? {
        backdropLock.lock()
        if let last = lastBackdrop, last.path == path { backdropLock.unlock(); return last.image }
        backdropLock.unlock()
        let image = load(path).flatMap(backdrop)
        backdropLock.lock(); lastBackdrop = (path, image); backdropLock.unlock()
        return image
    }

    /// Draws the card. `backdrop` is the prepared image for `.image`; without one the card is Dark.
    static func render(_ spec: AwayCardSpec, backdrop: CGImage?) -> CGImage? {
        let pixelWidth = Int(canvas.width), pixelHeight = Int(canvas.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(origin: .zero, size: canvas)
        var lightSurface = false
        if spec.background == .image, let backdrop {
            context.draw(backdrop, in: bounds)
            // A deep scrim keeps any photo quiet and the white type legible.
            context.setFillColor(CGColor(red: 0x05 / 255.0, green: 0x07 / 255.0, blue: 0x0A / 255.0, alpha: 0.55))
            context.fill(bounds)
        } else {
            let fill = spec.background == .color ? (red: spec.red, green: spec.green, blue: spec.blue) : dark
            context.setFillColor(CGColor(red: fill.red, green: fill.green, blue: fill.blue, alpha: 1))
            context.fill(bounds)
            lightSurface = spec.background == .color && prefersDarkText(red: fill.red, green: fill.green, blue: fill.blue)
        }
        let ink = lightSurface ? darkText : (red: 1.0, green: 1.0, blue: 1.0)
        let available = max(240, canvas.width - spec.chatWidth - 240)
        let centerX = (canvas.width - spec.chatWidth) / 2
        var size: CGFloat = 72
        var title = line(spec.title, size: size, weight: .semibold, kern: -0.5, color: ink, alpha: lightSurface ? 0.92 : 0.96)
        while width(of: title) > available && size > 44 {
            size -= 4
            title = line(spec.title, size: size, weight: .semibold, kern: -0.5, color: ink, alpha: lightSurface ? 0.92 : 0.96)
        }
        title = truncated(title, to: available, ink: ink, size: size)
        let subtitle = spec.subtitle.isEmpty ? nil
            : truncated(line(spec.subtitle, size: 30, weight: .regular, kern: 0, color: ink, alpha: lightSurface ? 0.66 : 0.62), to: available, ink: ink, size: 30)
        // Lay the group out by cap height so it centres optically, a little above the middle.
        let titleFont = NSFont.systemFont(ofSize: size, weight: .semibold)
        let subtitleFont = NSFont.systemFont(ofSize: 30, weight: .regular)
        // 22 px of clear space under the title's descenders, then the subtitle's cap height.
        let gap = -titleFont.descender + 22
        let groupHeight = titleFont.capHeight + (subtitle == nil ? 0 : gap + subtitleFont.capHeight)
        let center = canvas.height * (1 - 0.48)
        let titleBaseline = center + groupHeight / 2 - titleFont.capHeight
        context.textPosition = CGPoint(x: centerX - width(of: title) / 2, y: titleBaseline)
        CTLineDraw(title, context)
        if let subtitle {
            context.textPosition = CGPoint(x: centerX - width(of: subtitle) / 2, y: titleBaseline - gap - subtitleFont.capHeight)
            CTLineDraw(subtitle, context)
        }
        return context.makeImage()
    }

    /// Dark type wins on surfaces where it has more contrast than white (WCAG relative luminance).
    static func prefersDarkText(red: Double, green: Double, blue: Double) -> Bool {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b) }
        let surface = luminance(red, green, blue)
        let ink = luminance(darkText.red, darkText.green, darkText.blue)
        return (surface + 0.05) / (ink + 0.05) > 1.05 / (surface + 0.05)
    }

    private static func line(_ text: String, size: CGFloat, weight: NSFont.Weight, kern: CGFloat, color: (red: Double, green: Double, blue: Double), alpha: Double) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): NSFont.systemFont(ofSize: size, weight: weight),
            NSAttributedString.Key(kCTKernAttributeName as String): kern,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: color.red, green: color.green, blue: color.blue, alpha: alpha)
        ]))
    }
    private static func width(of line: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }
    private static func truncated(_ line: CTLine, to available: CGFloat, ink: (red: Double, green: Double, blue: Double), size: CGFloat) -> CTLine {
        guard width(of: line) > available else { return line }
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): NSFont.systemFont(ofSize: size),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: ink.red, green: ink.green, blue: ink.blue, alpha: 0.9)
        ]))
        return CTLineCreateTruncatedLine(line, Double(available), .end, ellipsis) ?? line
    }
    /// The image aspect-filled and softly blurred, with clamped edges so the frame keeps no dark fringe.
    private static func backdrop(_ image: CGImage) -> CGImage? {
        let source = CIImage(cgImage: image)
        let scale = max(canvas.width / source.extent.width, canvas.height / source.extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let offset = CGAffineTransform(translationX: (canvas.width - scaled.extent.width) / 2 - scaled.extent.minX,
                                       y: (canvas.height - scaled.extent.height) / 2 - scaled.extent.minY)
        let blurred = scaled.transformed(by: offset).clampedToExtent()
            .applyingGaussianBlur(sigma: 24)
            .cropped(to: CGRect(origin: .zero, size: canvas))
        return ciContext.createCGImage(blurred, from: blurred.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
