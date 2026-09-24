import CoreGraphics

/// ScreenCaptureKit source rectangles use top-left, display-local points.
/// Intersect absolute boundaries so menu and Dock crops cannot crop each other twice.
enum DisplayCaptureGeometry {
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
