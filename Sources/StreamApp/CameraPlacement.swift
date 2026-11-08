import CoreGraphics
import Foundation

/// Fractions of free travel, not canvas coordinates. Y increases from top to bottom.
struct CameraAnchor: Codable, Equatable, Hashable, Sendable {
    let x: Double
    let y: Double
    init(x: Double, y: Double) {
        self.x = x.isFinite ? min(1, max(0, x)) : 1
        self.y = y.isFinite ? min(1, max(0, y)) : 1
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(x: try values.decode(Double.self, forKey: .x), y: try values.decode(Double.self, forKey: .y))
    }
    static let bottomRight = Self(x: 1, y: 1)
    static func legacy(_ name: String?) -> Self {
        switch name {
        case "topLeft": Self(x: 0, y: 0)
        case "topRight": Self(x: 1, y: 0)
        case "bottomLeft": Self(x: 0, y: 1)
        default: .bottomRight
        }
    }
}

enum CameraPreset: String, CaseIterable, Identifiable {
    case topLeft, topCenter, topRight, centerLeft, center, centerRight, bottomLeft, bottomCenter, bottomRight
    var id: String { rawValue }
    var anchor: CameraAnchor {
        let index = Self.allCases.firstIndex(of: self)!
        return CameraAnchor(x: Double(index % 3) / 2, y: Double(index / 3) / 2)
    }
    var title: String {
        switch self {
        case .topLeft: "Top left"
        case .topCenter: "Top center"
        case .topRight: "Top right"
        case .centerLeft: "Center left"
        case .center: "Center"
        case .centerRight: "Center right"
        case .bottomLeft: "Bottom left"
        case .bottomCenter: "Bottom center"
        case .bottomRight: "Bottom right"
        }
    }
}

/// All camera manipulation uses the compositor's bottom-left 1920 × 1080 canvas.
enum CameraPlacement {
    static let inset: CGFloat = 24
    static func rect(anchor: CameraAnchor, size: CGSize, desktop: CGRect) -> CGRect {
        let travel = CGSize(width: max(0, desktop.width - size.width - 48), height: max(0, desktop.height - size.height - 48))
        let x = anchor.x == 1 ? desktop.maxX - size.width - inset : desktop.minX + inset + CGFloat(anchor.x) * travel.width
        let y = anchor.y == 0 ? desktop.maxY - size.height - inset : desktop.minY + inset + (1 - CGFloat(anchor.y)) * travel.height
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
    static func anchor(origin: CGPoint, size: CGSize, desktop: CGRect, snapping: Bool = true) -> CameraAnchor {
        let w = max(0, desktop.width - size.width - 48), h = max(0, desktop.height - size.height - 48)
        func axis(_ value: CGFloat, travel: CGFloat) -> Double {
            guard travel > 0 else { return 0.5 }
            let clamped = min(travel, max(0, value))
            let nearest = (clamped / travel * 2).rounded() / 2 * travel
            if snapping, abs(nearest - clamped) <= 24 {
                return Double(nearest / travel)
            }
            return Double(clamped / travel)
        }
        return CameraAnchor(x: axis(origin.x - desktop.minX - inset, travel: w),
                            y: 1 - axis(origin.y - desktop.minY - inset, travel: h))
    }
    static func dodgeAnchor(home: CameraAnchor) -> CameraAnchor {
        abs(home.x - 0.5) < 0.05 ? CameraAnchor(x: home.x, y: 1 - home.y) : CameraAnchor(x: 1 - home.x, y: home.y)
    }
    /// Hysteresis uses the home rectangle even while away; never bounce between overlapping targets.
    static func shouldDodge(cursor: CGPoint, home: CGRect, dodge: CGRect, dodging: Bool, enabled: Bool) -> Bool {
        guard enabled, !home.intersects(dodge) else { return false }
        return home.insetBy(dx: dodging ? -48 : -24, dy: dodging ? -48 : -24).contains(cursor)
    }
}

/// Maps the sharp, aspect-fitted desktop foreground to AppKit global points. Letterbox
/// areas intentionally extrapolate: the camera may sit on the background outside the source.
struct CameraDisplayMapping {
    let region: CGRect // top-left, display-local capture points
    let displayFrame: CGRect // bottom-left, global AppKit points
    let content: CGRect // sharp fitted source in the compositor canvas
    init(region: CGRect, displayFrame: CGRect, desktop: CGRect, sourceSize: CGSize? = nil) {
        self.region = region; self.displayFrame = displayFrame
        content = Self.fitted(source: sourceSize ?? region.size, in: desktop)
    }
    static func fitted(source: CGSize, in rect: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return rect }
        let scale = min(rect.width / source.width, rect.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }
    func toDisplay(_ p: CGPoint) -> CGPoint {
        CGPoint(x: displayFrame.minX + region.minX + (p.x - content.minX) * region.width / content.width,
                y: displayFrame.maxY - region.maxY + (p.y - content.minY) * region.height / content.height)
    }
    func toCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: content.minX + (p.x - displayFrame.minX - region.minX) * content.width / region.width,
                y: content.minY + (p.y - displayFrame.maxY + region.maxY) * content.height / region.height)
    }
    func toDisplay(_ rect: CGRect) -> CGRect {
        let a = toDisplay(rect.origin), b = toDisplay(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }
}
