import Foundation
import CoreGraphics
import CoreImage
import CoreVideo

struct CaptureGeometry: Equatable, Sendable {
    let size: CGSize
    let globalRect: CGRect
    let tracksWindows: Bool
    var bounds: CGRect { CGRect(origin: .zero, size: size) }
    func pixels(fromGlobal rect: CGRect) -> CGRect {
        guard globalRect.width > 0, globalRect.height > 0 else { return .zero }
        return CGRect(x: (rect.minX - globalRect.minX) * size.width / globalRect.width,
                      y: (rect.minY - globalRect.minY) * size.height / globalRect.height,
                      width: rect.width * size.width / globalRect.width,
                      height: rect.height * size.height / globalRect.height).integral
    }
}

struct WindowSnapshot: Sendable {
    struct Window: Sendable {
        let id: CGWindowID
        let frame: CGRect
        let layer: Int
    }
    let windows: [Window] // Front to back, in capture pixels, top-left origin.
    func frame(of id: CGWindowID) -> CGRect? { windows.first { $0.id == id }?.frame }
}

struct ScreenFrame: @unchecked Sendable {
    let sequence: UInt64
    let captured: TimeInterval
    let buffer: CVPixelBuffer
    let windows: WindowSnapshot?
    let geometry: CaptureGeometry
    let epoch: UInt64
}

struct Detection: Sendable {
    var owner: CGWindowID?
    var local: CGRect
    var ownerSize: CGSize?
    /// Where the pixels were read, in the scan's frame.
    var absolute: CGRect
    var span = CGRect.zero
    var row = CGRect.zero
    var rowPitch: CGFloat = 24
    var observedSequence: UInt64 = 0
    var observedAbsolute = CGRect.zero
    var patch: PrivacyRowPatch?
    var patchOffset = CGPoint.zero
    var carried = false
    var uncertain = false
}

struct ScanResult: Sendable {
    let sequence: UInt64
    let captured: TimeInterval
    private(set) var detections: [Detection]
    let frame: ScreenFrame
    init(frame: ScreenFrame, rects: [CGRect], records: [PrivacyScanner.OCRRecord] = []) {
        self.frame = frame; sequence = frame.sequence; captured = frame.captured
        let tails = PrivacyScanner.wrapTails(records, aspect: frame.geometry.size.height / frame.geometry.size.width)
        detections = rects.map { r in
            let pixels = CGRect(x: r.minX * frame.geometry.size.width,
                                y: (1 - r.maxY) * frame.geometry.size.height,
                                width: r.width * frame.geometry.size.width,
                                height: r.height * frame.geometry.size.height).integral
            let center = CGPoint(x: pixels.midX, y: pixels.midY)
            let windows = frame.geometry.tracksWindows ? frame.windows?.windows ?? [] : []
            // Window bounds are read after the pixels were captured, so a moving window's text can sit
            // just outside its listed frame. Exact containment wins; only then does a small margin
            // apply, so a neighboring window's margin cannot take text inside another window.
            let margin = max(24, 0.02 * frame.geometry.size.width)
            func owner(_ pad: CGFloat, normal: Bool) -> WindowSnapshot.Window? {
                windows.first { (!normal || $0.layer == 0) && $0.frame.insetBy(dx: -pad, dy: -pad).contains(center) }
            }
            let owner = owner(0, normal: true) ?? owner(margin, normal: true) ?? owner(0, normal: false) ?? owner(margin, normal: false)
            var d = Detection(owner: owner?.id,
                local: owner.map { pixels.offsetBy(dx: -$0.frame.minX, dy: -$0.frame.minY) } ?? pixels,
                ownerSize: owner?.frame.size, absolute: pixels)
            d.span = pixels.insetBy(dx: pixels.height * 0.4 / 1.5, dy: pixels.height * 0.25 / 1.5)
            let row = records.map(\.line.box).filter { $0.intersects(r) }.max { $0.intersection(r).width < $1.intersection(r).width }
            if let row {
                d.row = CGRect(x: row.minX * frame.geometry.size.width, y: (1 - row.maxY) * frame.geometry.size.height,
                    width: row.width * frame.geometry.size.width, height: row.height * frame.geometry.size.height)
            } else { d.row = d.span }
            let pitches = records.map(\.line.box).filter { other in
                other.maxX > r.minX && other.minX < r.maxX && abs(other.midY - r.midY) > r.height * 0.5
            }.map { abs((1 - $0.midY) * frame.geometry.size.height - d.row.midY) }.filter { $0 >= d.row.height }
            d.rowPitch = min(64, max(12, pitches.min() ?? 1.5 * d.row.height))
            d.observedSequence = frame.sequence; d.observedAbsolute = pixels
            d.patch = PrivacyRowPatch(frame: frame, rect: pixels)
            d.patchOffset = d.patch.map { CGPoint(x: $0.bounds.minX - pixels.minX, y: $0.bounds.minY - pixels.minY) } ?? .zero
            if let tail = tails.first(where: { r.intersection($0.rect).width >= $0.rect.width * 0.8 && r.midY < $0.parent.minY }) {
                let parent = CGRect(x: tail.parent.minX * frame.geometry.size.width,
                    y: (1 - tail.parent.maxY) * frame.geometry.size.height,
                    width: tail.parent.width * frame.geometry.size.width, height: tail.parent.height * frame.geometry.size.height)
                d.patch = PrivacyRowPatch(frame: frame, rect: parent)
                d.patchOffset = d.patch.map { CGPoint(x: $0.bounds.minX - pixels.minX, y: $0.bounds.minY - pixels.minY) } ?? .zero
                d.uncertain = true
            }
            return d
        }
    }
    /// An empty OCR result is not negative evidence. Only exact crops or confirmed row matches carry;
    /// the immutable patch keeps original provenance without retaining its full capture buffer.
    mutating func carry(from earlier: ScanResult, tracker: PrivacyMotionTracker = PrivacyMotionTracker()) {
        for old in earlier.detections {
            let placed = tracker.place(old, from: earlier, in: frame, previous: nil, next: nil, predict: false)
            guard !placed.unresolved, let moved = placed.placed else { continue }
            // A predicted wrap tail stands on its parent row: when this scan read that row itself, its own
            // tails (or none, after a reflow) decide.
            if old.uncertain, let parent = old.patch?.bounds.offsetBy(dx: moved.minX - old.absolute.minX, dy: moved.minY - old.absolute.minY),
               detections.contains(where: { !$0.carried && $0.absolute.intersects(parent) }) { continue }
            let uncovered = placed.rects.contains { rect in
                !detections.contains { $0.owner == old.owner && $0.absolute.insetBy(dx: -2, dy: -2).contains(rect) }
            }
            guard uncovered else { continue }
            // The found rectangle itself, whole: tracking's 2-pixel allowance must not accumulate on every
            // empty scan, and pixels found there are covered whatever the window list says.
            var d = old
            let delta = CGPoint(x: moved.minX - old.absolute.minX, y: moved.minY - old.absolute.minY)
            d.absolute = moved; d.span = old.span.offsetBy(dx: delta.x, dy: delta.y)
            d.row = old.row.offsetBy(dx: delta.x, dy: delta.y)
            d.carried = true
            if let bounds = d.owner.flatMap({ frame.windows?.frame(of: $0) }) {
                d.local = d.absolute.offsetBy(dx: -bounds.minX, dy: -bounds.minY); d.ownerSize = bounds.size
            } else { d.owner = nil; d.local = d.absolute; d.ownerSize = nil }
            detections.append(d)
        }
    }
}

/// History and OCR evidence have one owner. Pixel comparison runs after releasing this lock.
final class PrivacyTimeline: @unchecked Sendable {
    static let delay: TimeInterval = 0.5
    /// Delayed history at 30 fps, plus scanned frames spanning the delay and one predecessor, plus
    /// neighbors and in-flight work. Pools allocate on demand.
    static let poolCapacity = Int(ceil(delay * 30)) + Int(ceil(delay / PrivacyScanner.interval)) + 6
    struct Plan: Equatable, Sendable {
        var boxes: [CGRect] = []
        var uncertainRows: [CGRect] = []
        /// Solid changed-tile runs (top-left pixels) over pixels no scan read: see `unreadReference`.
        var guards: [CGRect] = []
        var degraded = false
        var waiting = false
    }
    struct Selection: Sendable {
        let frame: ScreenFrame?
        let plan: Plan
    }
    private struct Entry {
        let captured: TimeInterval
        let frame: ScreenFrame?
    }
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var frames: [Entry] = []
    private var scans: [ScanResult] = []
    private var consumed = -Double.infinity
    private let tracker = PrivacyMotionTracker()
    private var evidenceRevision: UInt64 = 0
    /// Consecutive scanned frames normally lie one scan interval apart (plus a frame of jitter); a wider
    /// bracket (failed or overrunning scans) left text in between unread.
    static let maxScanGap = PrivacyScanner.interval + 0.1
    func reset() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1; frames.removeAll(); scans.removeAll(); consumed = -.infinity; evidenceRevision &+= 1
        return epoch
    }
    var currentEpoch: UInt64 { lock.lock(); defer { lock.unlock() }; return epoch }
    func record(_ frame: ScreenFrame) {
        lock.lock(); defer { lock.unlock() }
        guard frame.epoch == epoch else { return }
        frames.append(Entry(captured: frame.captured, frame: frame))
        prune()
    }
    func recordGap(at captured: TimeInterval, epoch: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard epoch == self.epoch else { return }
        // Consecutive allocation failures form one gap, not an unbounded backlog.
        if frames.last?.frame == nil, !frames.isEmpty { return }
        frames.append(Entry(captured: captured, frame: nil)); prune()
    }
    @discardableResult func complete(_ result: ScanResult) -> ScanResult? {
        // Scans complete serially, so the newest stored scan is this one's predecessor.
        lock.lock()
        guard result.frame.epoch == epoch else { lock.unlock(); return nil }
        let earlier = scans.last { $0.sequence < result.sequence }
        lock.unlock()
        var result = result
        if let earlier { result.carry(from: earlier, tracker: tracker) }
        lock.lock(); defer { lock.unlock() }
        guard result.frame.epoch == epoch else { return nil }
        scans.append(result); scans.sort { $0.sequence < $1.sequence }; evidenceRevision &+= 1; prune()
        return result
    }
    private func prune() {
        // Keep one previous neighbor for window skew and the selected static frame.
        while frames.count > 2, frames[2].captured <= consumed { frames.removeFirst() }
        // Retain each bracketing scan and its original positive patches.
        let retainedTime = frames.first?.captured ?? scans.last?.captured ?? consumed
        while scans.count > 1, scans[1].captured <= retainedTime { scans.removeFirst() }
    }
    func select(at time: TimeInterval) -> Selection {
        lock.lock()
        consumed = max(consumed, time); prune()
        let index = frames.lastIndex { $0.captured <= time }
        let f = index.flatMap { frames[$0].frame }
        let previous = index.flatMap { $0 > 0 ? frames[$0 - 1].frame : nil }
        let next = index.flatMap { $0 + 1 < frames.count ? frames[$0 + 1].frame : nil }
        let evidence = scans, revision = evidenceRevision
        lock.unlock()
        guard let f else {
            // A capture allocation gap must not release an unplanned raw frame.
            return Selection(frame: nil, plan: Plan(degraded: true, waiting: true))
        }
        let plan = tracker.plan(frame: f, revision: revision, preview: false) {
            Self.plan(for: f, previous: previous, next: next, scans: evidence, tracker: tracker)
        }
        return Selection(frame: plan.waiting ? nil : f, plan: plan)
    }
    /// Preview is explicitly no-lookahead: precise positives plus degraded status. Its frame is up to a scan
    /// interval plus recognition newer than the newest scan; once that scan is older than the output delay
    /// at host time `now` (scans failing or backlogged), what changed since it is guarded.
    func preview(frame: ScreenFrame, now: TimeInterval) -> Plan {
        lock.lock(); let newest = scans.last, revision = evidenceRevision; lock.unlock()
        let stale = newest.map { frame.sequence != $0.sequence && now - $0.captured > Self.delay } ?? false
        return tracker.plan(frame: frame, revision: revision, preview: true, stale: stale) {
            guard let newest else { return Plan(degraded: true, waiting: true) }
            return Self.plan(for: frame, scans: [newest], tracker: tracker, successorDue: stale)
        }
    }
    /// `successorDue`: a scan after `f` should have completed (always for delayed output), so its absence
    /// leaves `f`'s changes unread.
    static func plan(for f: ScreenFrame, previous: ScreenFrame? = nil, next: ScreenFrame? = nil,
                     scans: [ScanResult], tracker: PrivacyMotionTracker = PrivacyMotionTracker(), successorDue: Bool = true) -> Plan {
        // Even a scanned frame uses its successor: its own OCR can miss a fading credential.
        let s1 = scans.last { $0.sequence <= f.sequence }
        let s2 = scans.first { $0.sequence > f.sequence }
        let bracket = [s1, s2].compactMap { $0 }
        guard !bracket.isEmpty else { return Plan(degraded: true, waiting: true) }
        var result = Plan(degraded: s2 == nil && s1?.sequence != f.sequence)
        if let reference = unreadReference(for: f, s1: s1, s2: s2, successorDue: successorDue) {
            result.degraded = true
            result.guards = stacked(changedTiles(f.buffer, reference.buffer, in: f.geometry.bounds))
        }
        for scan in bracket {
            var placements = scan.detections.map { tracker.place($0, from: scan, in: f, previous: previous, next: next) }
            // A row that missed its own search (moved far while unseen, e.g. text scrolling in) is looked for
            // near the shift most of its window's resolved rows found.
            for i in placements.indices where placements[i].unresolved && scan.detections[i].patch != nil {
                guard let owner = scan.detections[i].owner else { continue }
                let shifts = placements.indices.compactMap { j in
                    scan.detections[j].owner == owner ? placements[j].shift.map { Int($0) } : nil
                }
                guard let hint = Dictionary(shifts.map { ($0, 1) }, uniquingKeysWith: +).max(by: { $0.value < $1.value })?.key else { continue }
                placements[i] = tracker.place(scan.detections[i], from: scan, in: f, previous: previous, next: next, hint: hint)
            }
            // A repeated secret's patch also matches its other occurrence: two separate detections found on
            // one spot leave the one that moved further unresolved, so the hidden copy is not mislaid.
            for i in placements.indices {
                guard let a = placements[i].placed, let shift = placements[i].shift, shift != 0 else { continue }
                let claimed = placements.indices.contains { j in
                    guard j != i, let b = placements[j].placed, let other = placements[j].shift, abs(other) < abs(shift),
                          !scan.detections[i].absolute.intersects(scan.detections[j].absolute) else { return false }
                    let overlap = a.intersection(b)
                    return !overlap.isNull && overlap.height >= 0.5 * min(a.height, b.height) && overlap.width >= 0.5 * min(a.width, b.width)
                }
                if claimed { placements[i] = tracker.place(scan.detections[i], from: scan, in: f, previous: previous, next: next, resolve: false) }
            }
            for (d, placement) in zip(scan.detections, placements) {
                if placement.unresolved {
                    result.degraded = true
                    // Carry is not a new observation authorizing unlimited speculative backfill.
                    if !d.carried || f.sequence >= d.observedSequence { result.uncertainRows += placement.rects }
                } else if d.uncertain { result.uncertainRows += placement.rects }
                else { result.boxes += placement.rects }
            }
        }
        result.boxes = exactUnion(result.boxes)
        result.uncertainRows = exactUnion(result.uncertainRows)
        return result
    }
    /// The scanned frame whose differences from `f` no scan read, when evidence around `f` is missing:
    /// the later scan when the bracket is wider than normal spacing (failed or overrunning scans) or has
    /// no earlier scan; the earlier scan when no later one completed in time, or when a window it found a
    /// detection in has left `f`'s list or the later scan's (it may have moved and closed between window
    /// snapshots, leaving its last pixels anywhere). Pixels equal to a scanned frame were read; a scanned
    /// frame itself needs none. Normal operation (scans every interval, windows listed) has none.
    static func unreadReference(for f: ScreenFrame, s1: ScanResult?, s2: ScanResult?, successorDue: Bool) -> ScreenFrame? {
        if s1?.sequence == f.sequence { return nil }
        guard let s1 else { return s2?.frame }
        guard let s2 else { return successorDue ? s1.frame : gone(s1, from: f.windows) ? s1.frame : nil }
        if s2.captured - s1.captured > maxScanGap { return s2.frame }
        return gone(s1, from: f.windows) || gone(s1, from: s2.frame.windows) ? s1.frame : nil
    }
    /// Whether a window `scan` listed and found a detection in is missing from `windows` (a list that
    /// was read; an absent list proves nothing).
    private static func gone(_ scan: ScanResult, from windows: WindowSnapshot?) -> Bool {
        guard scan.frame.geometry.tracksWindows, let windows, let seen = scan.frame.windows else { return false }
        return scan.detections.contains { d in
            guard let owner = d.owner, seen.frame(of: owner) != nil else { return false }
            return windows.frame(of: owner) == nil
        }
    }
    /// Changed-tile runs (ordered by tile row) with identical runs in consecutive rows stacked into one.
    static func stacked(_ runs: [CGRect]) -> [CGRect] {
        var result: [CGRect] = [], above: [Int] = [], current: [Int] = [], row = -CGFloat.infinity
        result.reserveCapacity(runs.count)
        for run in runs {
            if run.minY != row { swap(&above, &current); current.removeAll(keepingCapacity: true); row = run.minY }
            if let i = above.first(where: { result[$0].minX == run.minX && result[$0].width == run.width && result[$0].maxY == run.minY }) {
                result[i].size.height += run.height; current.append(i)
            } else { current.append(result.count); result.append(run) }
        }
        return result
    }
    /// Preserve the exact union and each rectangle's padding: splitting would round internal seams.
    static func exactUnion(_ rects: [CGRect]) -> [CGRect] {
        var result = rects.filter { !$0.isNull && !$0.isEmpty }
        // Merge only when the bounding rectangle adds no uncovered pixels.
        var changed = true
        while changed {
            changed = false
            outer: for i in result.indices {
                for j in result.indices where j > i {
                    let a = result[i], b = result[j]
                    let overlap = a.intersection(b)
                    let area = a.width * a.height + b.width * b.height - (overlap.isNull ? 0 : overlap.width * overlap.height)
                    let union = a.union(b)
                    if abs(union.width * union.height - area) <= 1e-8 {
                        result[i] = a.union(b); result.remove(at: j); changed = true; break outer
                    }
                }
            }
        }
        return result
    }
}

/// Exact 420f luma equality of `rect` in `a` and the same-size rectangle at `origin` in `b`, over the
/// part visible in both. Rectangles are top-left pixels; nothing comparable means not the same.
func sameLuma(_ a: CVPixelBuffer, _ rect: CGRect, _ b: CVPixelBuffer, at origin: CGPoint) -> Bool {
    let dx = Int(origin.x.rounded()) - Int(rect.minX.rounded()), dy = Int(origin.y.rounded()) - Int(rect.minY.rounded())
    let boundsA = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(a), height: CVPixelBufferGetHeight(a))
    let boundsB = CGRect(x: -dx, y: -dy, width: CVPixelBufferGetWidth(b), height: CVPixelBufferGetHeight(b))
    let region = rect.integral.intersection(boundsA).intersection(boundsB)
    guard !region.isNull, !region.isEmpty,
          CVPixelBufferGetPixelFormatType(a) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
          CVPixelBufferGetPixelFormatType(b) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
          CVPixelBufferLockBaseAddress(a, .readOnly) == kCVReturnSuccess else { return false }
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly) }
    guard CVPixelBufferLockBaseAddress(b, .readOnly) == kCVReturnSuccess else { return false }
    defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    guard let ay = CVPixelBufferGetBaseAddressOfPlane(a, 0), let by = CVPixelBufferGetBaseAddressOfPlane(b, 0) else { return false }
    let ays = CVPixelBufferGetBytesPerRowOfPlane(a, 0), bys = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
    let x0 = Int(region.minX), width = Int(region.width)
    for row in Int(region.minY)..<Int(region.maxY) {
        if memcmp(ay.advanced(by: row * ays + x0), by.advanced(by: (row + dy) * bys + x0 + dx), width) != 0 { return false }
    }
    return true
}

/// Exact 420f luma + interleaved chroma comparison, as runs of changed 16×16 tiles per tile row.
/// Rectangles are top-left pixels. Each pixel row is compared whole first; only a differing row is
/// compared per tile, so an unchanged frame costs one `memcmp` per row.
func changedTiles(_ a: CVPixelBuffer, _ b: CVPixelBuffer, in region: CGRect) -> [CGRect] {
    let width = CVPixelBufferGetWidth(a), height = CVPixelBufferGetHeight(a)
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    let region = region.intersection(bounds).integral
    guard !region.isNull, !region.isEmpty else { return [] }
    guard width == CVPixelBufferGetWidth(b), height == CVPixelBufferGetHeight(b),
          CVPixelBufferGetPixelFormatType(a) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
          CVPixelBufferGetPixelFormatType(b) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return [region] }
    guard CVPixelBufferLockBaseAddress(a, .readOnly) == kCVReturnSuccess else { return [region] }
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly) }
    guard CVPixelBufferLockBaseAddress(b, .readOnly) == kCVReturnSuccess else { return [region] }
    defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    guard let ay = CVPixelBufferGetBaseAddressOfPlane(a, 0), let by = CVPixelBufferGetBaseAddressOfPlane(b, 0),
          let ac = CVPixelBufferGetBaseAddressOfPlane(a, 1), let bc = CVPixelBufferGetBaseAddressOfPlane(b, 1) else { return [region] }
    let ays = CVPixelBufferGetBytesPerRowOfPlane(a, 0), bys = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
    let acs = CVPixelBufferGetBytesPerRowOfPlane(a, 1), bcs = CVPixelBufferGetBytesPerRowOfPlane(b, 1)
    let x0 = Int(region.minX), x1 = Int(region.maxX), first = x0 / 16 * 16
    // Interleaved CbCr at half resolution: byte offset `x` covers luma column `x`.
    let cx0 = x0 / 2 * 2, cx1 = min(CVPixelBufferGetWidthOfPlane(a, 1) * 2, (x1 + 1) / 2 * 2)
    var changed = [Bool](repeating: false, count: (x1 - first + 15) / 16)
    /// Marks every tile in which the row segments `[from, to)` of `p` and `q` differ.
    func mark(_ p: UnsafeMutableRawPointer, _ q: UnsafeMutableRawPointer, from: Int, to: Int) {
        guard from < to, memcmp(p + from, q + from, to - from) != 0 else { return }
        for tile in changed.indices where !changed[tile] {
            let start = max(from, first + tile * 16), end = min(to, first + tile * 16 + 16)
            if start < end, memcmp(p + start, q + start, end - start) != 0 { changed[tile] = true }
        }
    }
    var result: [CGRect] = []
    for y in stride(from: Int(region.minY) / 16 * 16, to: Int(region.maxY), by: 16) {
        let y0 = max(y, Int(region.minY)), y1 = min(y + 16, Int(region.maxY))
        for index in changed.indices { changed[index] = false }
        for row in y0..<y1 { mark(ay + row * ays, by + row * bys, from: x0, to: x1) }
        for row in (y0 / 2)..<((y1 + 1) / 2) { mark(ac + row * acs, bc + row * bcs, from: cx0, to: cx1) }
        var run: CGRect?
        for tile in changed.indices {
            let x = first + tile * 16
            if changed[tile] {
                let rect = CGRect(x: x, y: y, width: min(16, width - x), height: min(16, height - y)).intersection(region)
                run = run.map { $0.union(rect) } ?? rect
            } else if let rect = run { result.append(rect); run = nil }
        }
        if let run { result.append(run) }
    }
    return result
}

/// Queue-confined pools never recycle a retained history/scan buffer. Copies are exact: the screen
/// stream already delivers the 420f the shield reads while it is on.
final class PrivacyBufferPool {
    private var pool: CVPixelBufferPool?
    private var size = CGSize.zero
    private var format: OSType = 0
    private let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: PrivacyTimeline.poolCapacity] as CFDictionary
    private func allocate(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let size = CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        let format = CVPixelBufferGetPixelFormatType(source)
        if pool == nil || self.size != size || self.format != format {
            self.size = size; self.format = format; pool = nil
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVBufferPropagateAttachments(source, buffer)
        return buffer
    }
    func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let buffer = allocate(source),
              CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        func copyRows(_ src: UnsafeMutableRawPointer, _ srcRow: Int, _ dst: UnsafeMutableRawPointer, _ dstRow: Int, _ rows: Int) {
            if srcRow == dstRow { memcpy(dst, src, srcRow * rows); return }
            for row in 0..<rows { memcpy(dst + row * dstRow, src + row * srcRow, min(srcRow, dstRow)) }
        }
        let planes = CVPixelBufferGetPlaneCount(source)
        if planes == 0 {
            guard let src = CVPixelBufferGetBaseAddress(source), let dst = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            copyRows(src, CVPixelBufferGetBytesPerRow(source), dst, CVPixelBufferGetBytesPerRow(buffer), CVPixelBufferGetHeight(source))
        } else {
            for plane in 0..<planes {
                guard let src = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dst = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return nil }
                copyRows(src, CVPixelBufferGetBytesPerRowOfPlane(source, plane), dst, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane),
                         CVPixelBufferGetHeightOfPlane(source, plane))
            }
        }
        return buffer
    }
}
