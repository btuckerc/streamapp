import Foundation
import CoreGraphics

/// Geometry shared by the program compositor and its interruptible scene motion.
struct SceneGeometry: Equatable {
    var desktop: CGRect
    var camera: CGRect
    /// Chat keeps its size when it is off, parked just outside the frame, so it slides in and out.
    var chat: CGRect
    /// 0 = floating camera over an opaque chat column; 1 = full-frame camera under a glass chat panel.
    var overlay: CGFloat
    /// Split's camera-and-chat column. Elsewhere it waits just outside the chat-side edge, so
    /// switching into Split slides the column in.
    var sidebar: CGRect
    /// 1 = the Away card covers everything but chat; leaving, it lifts off the top of the frame.
    var away: CGFloat
    /// 1 = the Away card has just landed, slightly enlarged; it settles to 0.
    var awaySettle: CGFloat = 0

    static let canvas = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    /// Split column width and the gap around its cards.
    static let sidebarWidth: CGFloat = 600
    static let sidebarMargin: CGFloat = 20

    /// The chat's size in the scene `c` describes, whether or not chat is on: the chat page is
    /// drawn at exactly this size, so its text keeps its configured pixel size in every scene.
    static func chatSize(_ c: StudioConfiguration) -> CGSize {
        let rect = SceneGeometry(configuration: c).chat
        return CGSize(width: rect.width.rounded(), height: rect.height.rounded())
    }

    /// `cameraReady` is false while an enabled webcam has no frame yet (starting or lost): Full Camera
    /// then shows the Away card, Split a chat-only column, and Desktop no webcam, rather than a slate.
    init(configuration c: StudioConfiguration, cameraReady: Bool = true) {
        let width = CGFloat(min(576, max(288, c.chatWidth)))
        let full = Self.canvas
        let hasCamera = c.cameraEnabled && cameraReady
        let offscreenX = c.chatOnLeft ? -width : full.maxX
        sidebar = CGRect(x: c.chatOnLeft ? -Self.sidebarWidth : full.maxX, y: 0, width: Self.sidebarWidth, height: full.height)
        away = 0
        switch c.layout {
        case .justChatting, .away:
            desktop = full; camera = full
            chat = CGRect(x: c.chatEnabled ? full.maxX - width - 24 : full.maxX, y: 24, width: width, height: full.height - 48)
            overlay = 1
            if c.layout == .away || !hasCamera {
                camera = CGRect(x: full.midX, y: full.midY, width: 0, height: 0)
                away = 1
            }
        case .sideBySide:
            overlay = 0
            let m = Self.sidebarMargin
            guard hasCamera || c.chatEnabled else {
                desktop = full; camera = CGRect(x: full.maxX, y: full.midY, width: 0, height: 0)
                // Parked inside the parked column, wholly outside the frame on either side.
                chat = CGRect(x: sidebar.minX + m, y: m, width: Self.sidebarWidth - 2 * m, height: full.height - 2 * m)
                return
            }
            sidebar.origin.x = c.chatOnLeft ? 0 : full.maxX - Self.sidebarWidth
            desktop = CGRect(x: c.chatOnLeft ? sidebar.maxX : 0, y: 0, width: full.width - sidebar.width, height: full.height)
            let card = sidebar.insetBy(dx: m, dy: m)
            if !hasCamera {
                camera = CGRect(x: card.midX, y: card.maxY, width: 0, height: 0)
                chat = card
            } else {
                let h = card.width / c.cameraFrame.aspectRatio
                chat = CGRect(x: card.minX, y: card.minY, width: card.width, height: max(0, card.height - h - m))
                if c.chatEnabled {
                    camera = CGRect(x: card.minX, y: card.maxY - h, width: card.width, height: h)
                } else {
                    // A circle stays round; otherwise the webcam becomes a full-height portrait card,
                    // and chat drops out of the bottom of the frame.
                    let side = card.width
                    camera = c.cameraFrame == .circle ? CGRect(x: card.minX, y: card.midY - side / 2, width: side, height: side) : card
                    chat.origin.y = -chat.height
                }
            }
        case .desktopChat:
            let column = c.chatEnabled ? width : 0
            desktop = CGRect(x: c.chatOnLeft ? column : 0, y: 0, width: full.width - column, height: full.height)
            chat = CGRect(x: c.chatEnabled ? (c.chatOnLeft ? 0 : desktop.maxX) : offscreenX, y: 0, width: width, height: full.height)
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
            camera = CameraPlacement.rect(anchor: c.cameraAnchor, size: CGSize(width: w, height: h), desktop: desktop)
            // Without the webcam its card shrinks to its centre, so turning it on grows it in place.
            if !hasCamera { camera = CGRect(x: camera.midX, y: camera.midY, width: 0, height: 0) }
            overlay = 0
        }
    }
    /// The webcam's card is on screen (not collapsed, not behind the Away card).
    var showsCamera: Bool { away < 1 && camera.width >= 1 && camera.height >= 1 }
    /// How framed the chat is: 0 = a flush column beside the desktop, 1 = a rounded card (Split) or panel (Full Camera, Away).
    var chatFraming: CGFloat {
        let presence = max(0, min(1, sidebar.intersection(Self.canvas).width / Self.sidebarWidth))
        return max(overlay, presence)
    }

    func interpolated(to target: Self, progress p: CGFloat) -> Self {
        var result = self
        result.desktop = Self.interpolate(desktop, target.desktop, p)
        result.camera = Self.interpolate(camera, target.camera, p)
        result.chat = Self.interpolate(chat, target.chat, p)
        result.sidebar = Self.interpolate(sidebar, target.sidebar, p)
        result.overlay += (target.overlay - overlay) * p
        result.away += (target.away - away) * p
        result.awaySettle += (target.awaySettle - awaySettle) * p
        return result
    }
    static func interpolate(_ a: CGRect, _ b: CGRect, _ p: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * p, y: a.minY + (b.minY - a.minY) * p,
               width: a.width + (b.width - a.width) * p, height: a.height + (b.height - a.height) * p)
    }
}

/// Scene motion. Everything moves; nothing cross-fades. The layout (desktop, Split column, webcam)
/// leads on Material's emphasized curve and chat follows a beat later. Privacy is never animated:
/// the Away card covers and a hidden webcam disappears on the next frame, while anything else keeps
/// moving under or beside them. Leaving Away, the scene underneath is already in place and the
/// card lifts off the top. Program output ignores Reduce Motion: it is footage for viewers, not
/// interface on this Mac.
struct SceneTransition {
    /// Layout moves (Material duration-long2).
    static let duration: TimeInterval = 0.5
    /// Chat starts this much after the layout, so the column arrives and its content follows.
    static let follow: TimeInterval = 0.06
    /// The Away card lifting off: an exit, so shorter and accelerating.
    static let lift: TimeInterval = 0.35
    /// The Away card landing: covers at once, then settles from 103% over this long.
    static let settle: TimeInterval = 0.6
    private var from: SceneGeometry?
    private var target: SceneGeometry?
    private var startedAt: TimeInterval = 0
    private var cameraOnly = false

    mutating func sample(target next: SceneGeometry, now: TimeInterval, dragging: Bool = false) -> SceneGeometry {
        if target == nil || dragging {
            from = next; target = next; startedAt = now
            return next
        }
        if next != target {
            // Retarget from the actually visible geometry, not the previous endpoint.
            var visible = value(at: now)
            if next.away >= 1 && visible.away < 1 {
                // Cover at once; what is under the card jumps to its place unseen. Only chat keeps moving.
                let chat = visible.chat
                visible = next
                visible.chat = chat
                visible.awaySettle = 1
            } else if visible.away >= 1 && next.away < 1 {
                // The scene being uncovered is already where it belongs; the card and chat move.
                // Once the card is lifting, a further change moves on from what is visible instead.
                let chat = visible.chat, away = visible.away, settle = visible.awaySettle
                visible = next
                visible.chat = chat; visible.away = away; visible.awaySettle = settle
            } else if visible.showsCamera && !next.showsCamera {
                visible.camera = next.camera
            }
            // Parked chat moves to its next parking place unseen, never across the frame.
            if !visible.chat.intersects(SceneGeometry.canvas) && !next.chat.intersects(SceneGeometry.canvas) {
                visible.chat = next.chat
            }
            cameraOnly = visible.desktop == next.desktop && visible.chat == next.chat && visible.overlay == next.overlay
                && visible.sidebar == next.sidebar && visible.away == next.away && visible.awaySettle == next.awaySettle
            from = visible
            target = next
            startedAt = now
        }
        return value(at: now)
    }

    private func value(at now: TimeInterval) -> SceneGeometry {
        let from = from!, target = target!
        let t = now - startedAt
        if cameraOnly {
            guard t < 0.6 else { return target }
            var result = from
            result.camera = SceneGeometry.interpolate(from.camera, target.camera, Ease.camera(t / 0.6))
            return result
        }
        guard t < max(Self.duration + Self.follow, Self.lift, Self.settle) else { return target }
        var result = from.interpolated(to: target, progress: Ease.emphasized(t / Self.duration))
        result.chat = SceneGeometry.interpolate(from.chat, target.chat, Ease.emphasized((t - Self.follow) / Self.duration))
        result.away = from.away + (target.away - from.away) * Ease.accelerate(t / Self.lift)
        result.awaySettle = from.awaySettle + (target.awaySettle - from.awaySettle) * Ease.decelerate(t / Self.settle)
        return result
    }
}

/// Cubic-bezier timing curves, solved for the time coordinate (using t directly would be a different curve).
enum Ease {
    /// Material emphasized: a decisive start and a long, gentle settle. Layout moves.
    static func emphasized(_ t: CGFloat) -> CGFloat { bezier(t, 0.2, 0, 0, 1) }
    /// Material emphasized-accelerate: eases off its mark, then leaves quickly. Exits.
    static func accelerate(_ t: CGFloat) -> CGFloat { bezier(t, 0.3, 0, 0.8, 0.15) }
    /// Material emphasized-decelerate: arrives fast and comes to rest softly. Landings.
    static func decelerate(_ t: CGFloat) -> CGFloat { bezier(t, 0.05, 0.7, 0.1, 1) }
    /// Webcam-only moves (punch-in, corner changes): soft departure, a decisive move, gentle settle.
    static func camera(_ t: CGFloat) -> CGFloat { bezier(t, 0.22, 0, 0.18, 1) }

    static func bezier(_ t: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> CGFloat {
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        func curve(_ u: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let v = 1 - u
            return 3 * v * v * u * a + 3 * v * u * u * b + u * u * u
        }
        // x(u) is monotonic on [0, 1] for these curves, so bisection always converges.
        var low: CGFloat = 0, high: CGFloat = 1
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if curve(mid, x1, x2) < t { low = mid } else { high = mid }
        }
        return curve((low + high) / 2, y1, y2)
    }
}
