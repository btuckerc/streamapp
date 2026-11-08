import CoreGraphics

/// ScreenCaptureKit source rectangles use top-left, display-local points.
/// Intersect absolute boundaries so menu and Dock crops cannot crop each other twice.
enum DisplayCaptureGeometry {
    /// Match the compositor's actual captured buffer aspect, including integer rounding.
    static func outputSize(region: CGRect, pixelScale: CGFloat) -> CGSize {
        let width = max(1, region.width * pixelScale), height = max(1, region.height * pixelScale)
        let scale = min(1, min(1920 / width, 1080 / height))
        return CGSize(width: max(2, Int(width * scale)), height: max(2, Int(height * scale)))
    }
    static func crop(_ full: CGRect, displayBounds: CGRect, topInset: CGFloat,
                     includeMenuBar: Bool, dockHeightFraction: Double?) -> CGRect {
        guard !full.isEmpty, !full.isInfinite, !full.isNull,
              !displayBounds.isEmpty, !displayBounds.isInfinite, !displayBounds.isNull else { return full }
        var bounds = displayBounds
        if let fraction = dockHeightFraction, fraction.isFinite, fraction > 0, fraction <= 1 {
            bounds.size.height *= fraction
        }
        if !includeMenuBar, topInset.isFinite, topInset > 0, topInset < bounds.height {
            bounds.origin.y += topInset
            bounds.size.height -= topInset
        }
        let cropped = full.intersection(bounds)
        return cropped.isEmpty || cropped.isNull ? full : cropped
    }
}
