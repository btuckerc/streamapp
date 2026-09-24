import Foundation
import CoreGraphics

/// Geometry shared by the program compositor and its interruptible scene motion.
struct SceneGeometry: Equatable {
    var desktop: CGRect
    var camera: CGRect
    var chat: CGRect
    var overlay: CGFloat

    init(configuration c: StudioConfiguration) {
        let width = c.chatEnabled ? CGFloat(min(576, max(288, c.chatWidth))) : 0
        let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        if c.layout == .justChatting {
            desktop = full; camera = full
            chat = CGRect(x: 1920 - width - 24, y: 24, width: width, height: 1032)
            overlay = 1
        } else {
            desktop = CGRect(x: c.chatOnLeft ? width : 0, y: 0, width: 1920 - width, height: 1080)
            chat = CGRect(x: c.chatOnLeft ? 0 : desktop.width, y: 0, width: width, height: 1080)
            let size = CGFloat(c.effectiveCameraSize)
            let heightBasedFrame = c.cameraFrame != .widescreen
            let w: CGFloat
            let h: CGFloat
            if heightBasedFrame {
                h = min(desktop.height * size, desktop.height - 48)
                w = h * c.cameraFrame.aspectRatio
            } else {
                w = min(desktop.width * size, (desktop.height - 48) * c.cameraFrame.aspectRatio)
                h = w / c.cameraFrame.aspectRatio
            }
            let left = c.cameraCorner == .bottomLeft || c.cameraCorner == .topLeft
            let top = c.cameraCorner == .topLeft || c.cameraCorner == .topRight
            camera = CGRect(x: left ? desktop.minX + 24 : desktop.maxX - w - 24,
                            y: top ? 1080 - h - 24 : 24, width: w, height: h)
            overlay = 0
        }
    }

    func interpolated(to target: Self, progress p: CGFloat) -> Self {
        var result = self
        result.desktop = Self.interpolate(desktop, target.desktop, p)
        result.camera = Self.interpolate(camera, target.camera, p)
        result.chat = Self.interpolate(chat, target.chat, p)
        result.overlay += (target.overlay - overlay) * p
        return result
    }
    private static func interpolate(_ a: CGRect, _ b: CGRect, _ p: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * p, y: a.minY + (b.minY - a.minY) * p,
               width: a.width + (b.width - a.width) * p, height: a.height + (b.height - a.height) * p)
    }
}

struct SceneTransition {
    static let duration: TimeInterval = 0.35
    private var from: SceneGeometry?
    private var target: SceneGeometry?
    private var startedAt: TimeInterval = 0
    private var cameraOnly = false

    mutating func sample(target next: SceneGeometry, now: TimeInterval, reduceMotion: Bool) -> SceneGeometry {
        if target == nil || reduceMotion {
            from = next; target = next; startedAt = now
            return next
        }
        if next != target {
            // Retarget from the actually visible geometry, not the previous endpoint.
            let visible = value(at: now)
            cameraOnly = visible.desktop == next.desktop && visible.chat == next.chat && visible.overlay == next.overlay
            from = visible
            target = next
            startedAt = now
        }
        return value(at: now)
    }
    private func value(at now: TimeInterval) -> SceneGeometry {
        let t = CGFloat(min(1, max(0, (now - startedAt) / (cameraOnly ? 0.6 : Self.duration))))
        if t >= 1 { return target! }
        let eased = cameraOnly ? Self.cameraEase(t) : t * t * (3 - 2 * t)
        return from!.interpolated(to: target!, progress: eased)
    }

    /// Cubic-bezier(0.22, 0, 0.18, 1): soft departure, a decisive move, gentle settle.
    /// Solve the curve's time coordinate; using t directly would be a different easing.
    private static func cameraEase(_ t: CGFloat) -> CGFloat {
        var u = t
        for _ in 0..<6 {
            let error = u * (0.66 + u * (-0.78 + 1.12 * u)) - t
            if abs(error) < 0.000001 { break }
            let slope = 0.66 + u * (-1.56 + 3.36 * u)
            u = min(1, max(0, u - error / slope))
        }
        return u * u * (3 - 2 * u)
    }
}
