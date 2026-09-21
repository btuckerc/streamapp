import CoreImage
import CoreGraphics

/// Builds the opaque desktop background and places the original desktop sharply on top.
/// All geometry is expressed in output coordinates; the source is never cropped in fit mode.
struct DesktopBackgroundRenderer {
    static func compose(source: CIImage, in rect: CGRect, configuration: StudioConfiguration, image: CGImage? = nil, preparedBackground: CIImage? = nil) -> CIImage {
        guard rect.width > 0, rect.height > 0 else { return CIImage(color: .black).cropped(to: rect) }
        if let preparedBackground {
            return fit(source, into: rect, fill: false).composited(over: preparedBackground).cropped(to: rect)
        }
        if configuration.backgroundStyle == .black {
            return fit(source, into: rect, fill: false).composited(over: CIImage(color: .black).cropped(to: rect))
        }
        let rgb = CIColor(red: CGFloat(configuration.backgroundRed), green: CGFloat(configuration.backgroundGreen), blue: CGFloat(configuration.backgroundBlue), alpha: 1)
        let solid = CIImage(color: rgb).cropped(to: rect)
        let background: CIImage
        switch configuration.backgroundStyle {
        case .black, .color:
            background = solid
        case .image:
            if let image { background = fit(CIImage(cgImage: image), into: rect, fill: true).composited(over: solid).cropped(to: rect) }
            else { background = solid }
        case .blur:
            let enlarged = fit(source, into: rect, fill: true).clampedToExtent()
            let blurred = enlarged.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: CGFloat(configuration.backgroundBlurRadius) * 0.25])
                .transformed(by: CGAffineTransform(scaleX: 4, y: 4)).cropped(to: rect)
            background = blurred.composited(over: solid).cropped(to: rect)
        case .mirror:
            background = mirrorBackground(source: source, in: rect, configuration: configuration, image: image)
        }
        return fit(source, into: rect, fill: false).composited(over: background).cropped(to: rect)
    }

    /// Builds the reflection recipe; FrameRenderer bakes and caches its output.
    /// The captured foreground is composited separately and never reflected.
    static func mirrorBackground(source: CIImage, in rect: CGRect, configuration: StudioConfiguration, image: CGImage?) -> CIImage {
        let rgb = CIColor(red: CGFloat(configuration.backgroundRed), green: CGFloat(configuration.backgroundGreen), blue: CGFloat(configuration.backgroundBlue), alpha: 1)
        let solid = CIImage(color: configuration.backgroundStyle == .black ? .black : rgb).cropped(to: rect)
        guard configuration.backgroundStyle == .mirror, let image else { return solid }
        let content = fittedContentRect(source, in: rect)
        let wallpaper = fit(CIImage(cgImage: image), into: content, fill: true)
        let reflected = reflectedTile(wallpaper, content: content)
            .applyingFilter("CIAffineTile", parameters: ["inputTransform": NSAffineTransform()])
            .transformed(by: CGAffineTransform(translationX: content.minX, y: content.minY))
            .cropped(to: rect)
        return reflected.composited(over: solid).cropped(to: rect)
    }

    private static func fittedContentRect(_ image: CIImage, in rect: CGRect) -> CGRect {
        let e = image.extent
        let scale = min(rect.width / e.width, rect.height / e.height)
        let w = e.width * scale, h = e.height * scale
        return CGRect(x: rect.minX + (rect.width - w) / 2, y: rect.minY + (rect.height - h) / 2, width: w, height: h)
    }
    private static func reflectedTile(_ image: CIImage, content: CGRect) -> CIImage {
        let base = image.transformed(by: CGAffineTransform(translationX: -content.minX, y: -content.minY))
        let w = content.width, h = content.height
        let horizontal = base.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * w, ty: 0))
        let vertical = base.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 2 * h))
        let both = base.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 2 * w, ty: 2 * h))
        return both.composited(over: vertical).composited(over: horizontal).composited(over: base).cropped(to: CGRect(x: 0, y: 0, width: 2 * w, height: 2 * h))
    }
    private static func fit(_ image: CIImage, into rect: CGRect, fill: Bool) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, rect.width > 0, rect.height > 0 else { return image.cropped(to: rect) }
        let x = rect.width / extent.width, y = rect.height / extent.height
        let scale = fill ? max(x, y) : min(x, y)
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        return normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).transformed(by: CGAffineTransform(translationX: rect.minX + (rect.width - extent.width * scale) / 2, y: rect.minY + (rect.height - extent.height * scale) / 2)).cropped(to: rect)
    }
}
