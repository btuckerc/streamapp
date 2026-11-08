import Foundation
import CoreGraphics
@testable import StreamApp

/// Frozen pre-cutover planner, for same-input precision/recall comparisons only.
enum PrivacyLegacyEvaluation {
    struct Plan { var boxes: [CGRect] = []; var guards: [CGRect] = []; var coveringChanges = false }
    static func matches(_ a: Detection, _ b: Detection) -> Bool {
        guard a.owner == b.owner else { return false }
        let intersection = a.local.intersection(b.local)
        guard !intersection.isNull else { return false }
        let area = intersection.width * intersection.height
        let aa = a.local.width * a.local.height, bb = b.local.width * b.local.height
        return area >= 0.5 * min(aa, bb) || area >= 0.5 * (aa + bb - area)
    }
    private static func place(_ d: Detection, from scan: ScanResult, in f: ScreenFrame, previous: ScreenFrame?, next: ScreenFrame?) -> CGRect? {
        guard let owner = d.owner, f.geometry.tracksWindows, let windows = f.windows else { return d.absolute }
        // Unlisted: a later scan's detection stays where its pixels were read (the list can lag an
        // appearing window), and an earlier one is a sensitive window leaving, guarded in `plan`.
        guard let bounds = windows.frame(of: owner) else { return d.absolute }
        var rect = d.local.offsetBy(dx: bounds.minX, dy: bounds.minY)
        for neighbor in [previous, next] {
            if let bounds = neighbor?.windows?.frame(of: owner) {
                rect = rect.union(d.local.offsetBy(dx: bounds.minX, dy: bounds.minY))
            }
        }
        // On its own frame a detection also covers exactly where its pixels were read.
        return scan.sequence == f.sequence ? rect.union(d.absolute) : rect
    }
    /// Successive scans of the same text yield nearly the same box: keep one cover (their union)
    /// instead of stacking a compositing node per scan.
    private static func absorb(_ rect: CGRect, into boxes: inout [CGRect]) {
        let area = rect.width * rect.height
        if let index = boxes.firstIndex(where: { box in
            let overlap = box.intersection(rect)
            return !overlap.isNull && overlap.width * overlap.height >= 0.5 * min(area, box.width * box.height)
        }) {
            boxes[index] = boxes[index].union(rect)
        } else { boxes.append(rect) }
    }
    static func plan(for f: ScreenFrame, previous: ScreenFrame? = nil, next: ScreenFrame? = nil, scans: [ScanResult]) -> Plan {
        // Carried evidence makes the bracketing scans complete: no older scan is consulted. A scanned
        // frame also takes the next completed scan, so a misread of it (a window still fading in) is
        // caught by that scan's detections and new-detection guards, as between scans.
        let s1 = scans.last { $0.sequence <= f.sequence }
        let s2 = scans.first { $0.sequence > f.sequence } ?? s1.flatMap { $0.sequence == f.sequence ? $0 : nil }
        let bracket = s1?.sequence == s2?.sequence ? [s1].compactMap { $0 } : [s1, s2].compactMap { $0 }
        var result = Plan()
        var guardRegions: [CGRect] = []
        var compared = Set<UInt64>()
        for scan in bracket {
            for d in scan.detections {
                if let rect = place(d, from: scan, in: f, previous: previous, next: next) { absorb(rect, into: &result.boxes) }
                // Once per resized window and scan: its content may have reflowed since that scan.
                // Pixel-rounded bounds of a moving window jitter by a pixel; that is not a resize.
                if let owner = d.owner, let bounds = f.windows?.frame(of: owner), let size = d.ownerSize,
                   abs(bounds.width - size.width) > 2 || abs(bounds.height - size.height) > 2,
                   compared.insert(scan.sequence << 32 | UInt64(owner)).inserted {
                    result.guards += changedTiles(f.buffer, scan.frame.buffer, in: bounds)
                }
            }
        }
        if let s2, s2.sequence > f.sequence {
            let prior = s1?.detections ?? []
            for d in s2.detections where !prior.contains(where: { matches($0, d) }) {
                if let owner = d.owner {
                    // Not listed yet (or no list): the appearing window's pixels can be anywhere.
                    guard let bounds = f.windows?.frame(of: owner) else { guardRegions.append(f.geometry.bounds); continue }
                    if bounds == s2.frame.windows?.frame(of: owner) { guardRegions.append(bounds) }
                    else { result.guards.append(bounds) }
                } else { guardRegions.append(f.geometry.bounds) }
            }
        }
        // An overrunning or failed scan widened the bracket: text shown only inside it was never read,
        // so guard every pixel differing from the later scan, as before any scan. A scanned frame was read.
        if let s2, s2.sequence > f.sequence, s1?.sequence != f.sequence, s2.captured - (s1?.captured ?? -.infinity) > PrivacyTimeline.maxScanGap {
            guardRegions.append(f.geometry.bounds)
        }
        // A sensitive window leaving the list, in this frame or by the next scan (closing, hiding, or
        // listed before its last pixels are drawn), is a lifecycle transition: until a scan after it,
        // guard every pixel differing from the last scan that saw it, wherever those pixels went.
        if let s1, f.geometry.tracksWindows, let windows = f.windows, s1.detections.contains(where: { d in
            guard let owner = d.owner else { return false }
            let gone = { (list: WindowSnapshot?) in list.map { $0.frame(of: owner) == nil } ?? false }
            return gone(windows) || (s2.map { $0.sequence > f.sequence && gone($0.frame.windows) } ?? false)
        }) {
            result.guards += changedTiles(f.buffer, s1.frame.buffer, in: f.geometry.bounds)
        }
        if s2 == nil || (f.geometry.tracksWindows && f.windows == nil) {
            result.coveringChanges = true
            guardRegions.append(f.geometry.bounds)
        }
        if !guardRegions.isEmpty {
            if let reference = s2 ?? s1 {
                for region in guardRegions { result.guards += changedTiles(f.buffer, reference.frame.buffer, in: region) }
            } else { result.guards.append(f.geometry.bounds) }
        }
        result.guards = coalesced(result.guards)
        return result
    }
    /// Tile runs merge with any cover they touch, and more than `limit` covers become their bounding
    /// box: each cover costs a compositing node, and over-covering a change is the safe direction.
    static func coalesced(_ rects: [CGRect], limit: Int = 8) -> [CGRect] {
        var merged: [CGRect] = []
        for rect in rects {
            var cover = rect
            var index = 0
            while index < merged.count {
                if merged[index].insetBy(dx: -1, dy: -1).intersects(cover) {
                    cover = cover.union(merged.remove(at: index)); index = 0
                } else { index += 1 }
            }
            merged.append(cover)
        }
        return merged.count > limit ? [merged.reduce(CGRect.null) { $0.union($1) }] : merged
    }
}
