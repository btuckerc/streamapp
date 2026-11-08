import Foundation
import CoreGraphics
import CoreVideo

/// Immutable, bounded positive evidence. Carry retains this patch, not the original screen buffer.
final class PrivacyRowPatch: @unchecked Sendable {
    let bounds: CGRect
    let width: Int, height: Int
    let bytes: ContiguousArray<UInt8>
    let sequence: UInt64
    /// Both pixels across the strongest horizontal edge of each 16-pixel-wide, quarter-height cell: a
    /// sparse signature that ranks candidate shifts without a dense comparison. Per sample, its patch
    /// row, column and value.
    let rows: ContiguousArray<Int>, columns: ContiguousArray<Int>, values: ContiguousArray<Int>
    init?(frame: ScreenFrame, rect: CGRect) {
        let r = rect.integral.intersection(frame.geometry.bounds)
        guard !r.isNull, r.width >= 2, r.height >= 2,
              CVPixelBufferGetPixelFormatType(frame.buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              CVPixelBufferLockBaseAddress(frame.buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(frame.buffer, .readOnly) }
        guard let p = CVPixelBufferGetBaseAddressOfPlane(frame.buffer, 0) else { return nil }
        bounds = r; sequence = frame.sequence
        let width = Int(r.width), height = Int(r.height)
        self.width = width; self.height = height
        var data = ContiguousArray<UInt8>(repeating: 0, count: width * height)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(frame.buffer, 0)
        data.withUnsafeMutableBytes { target in
            for y in 0..<height { memcpy(target.baseAddress! + y * width, p + (Int(r.minY) + y) * stride + Int(r.minX), width) }
        }
        bytes = data
        var rows = ContiguousArray<Int>(), columns = ContiguousArray<Int>(), values = ContiguousArray<Int>()
        let cellHeight = max(2, height / 4)
        data.withUnsafeBufferPointer { b in
            for cy in Swift.stride(from: 0, to: height, by: cellHeight) {
                for cx in Swift.stride(from: 0, to: width - 1, by: 16) {
                    var best = -1, strongest = 8
                    for y in cy..<min(height, cy + cellHeight) {
                        for x in cx..<min(width - 1, cx + 16) {
                            let g = abs(Int(b[y * width + x + 1]) - Int(b[y * width + x]))
                            if g > strongest { strongest = g; best = y * width + x }
                        }
                    }
                    if best >= 0 {
                        for i in [best, best + 1] { rows.append(i / width); columns.append(i % width); values.append(Int(b[i])) }
                    }
                }
            }
        }
        self.rows = rows; self.columns = columns; self.values = values
    }
}

/// Places scan detections in other frames by finding their own pixels. Serializes only its own cache;
/// never holds the timeline lock or invokes Vision.
final class PrivacyMotionTracker: @unchecked Sendable {
    struct Placement {
        var rects: [CGRect] = []
        var unresolved = false
        var shift: CGFloat?
        /// The detection's own rectangle where it was found, before padding and window-lag copies.
        var placed: CGRect?
    }
    /// A detection within its scan, per planning lane. Consecutive frames move it by about the same step,
    /// so its last shift and step predict the next.
    private struct Track: Hashable { let scan: UInt64; let x: Int32; let y: Int32; let preview: Bool }
    /// `misses` counts consecutive frames the detection was not found since `shift`.
    private struct Motion { var shift: Int; var step: Int; var misses = 0 }
    /// Rows searched around the prediction. The whole window is searched for a detection's first placement
    /// and every fourth consecutive miss, so text that left the window costs a near search per frame. A
    /// moving window searches only the first radius: its misses are resampled pixels, never a far scroll.
    static let radii = [8, 48]
    /// Sparse-signature correlation a candidate needs before the dense check.
    static let sparseMatch: Float = 0.6
    /// Dense check: whole-patch correlation, and each 32-column block's mean residual after the
    /// patch-wide gain/offset fit, relative to the target's contrast. One differing glyph fails its block.
    static let denseMatch: Float = 0.9
    static let blockResidual: Float = 0.35
    private let lock = NSRecursiveLock()
    private var motion: [Track: Motion] = [:]
    /// Per window, the last nonzero shift per frame any detection was found at: the scroll speed, which
    /// predicts where a row that was out of view or moved far since its scan has gone.
    private var velocity: [CGWindowID: (perFrame: Double, at: UInt64)] = [:]
    /// Per moving window, the horizontal offset of its pixels from its listed bounds in one frame; nil
    /// when the first of its detections searched there matched at no offset, so the rest skip the probe.
    private var offsets: [CGWindowID: (sequence: UInt64, preview: Bool, dx: Int?)] = [:]
    private var previewing = false
    private var candidates: [(dy: Int, score: Float)] = []
    private var cached: (epoch: UInt64, sequence: UInt64, revision: UInt64, preview: Bool, stale: Bool, plan: PrivacyTimeline.Plan)?
    private var cachedEpoch: UInt64?
    init() {
        motion.reserveCapacity(64); candidates.reserveCapacity(64)
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        motion.removeAll(keepingCapacity: true); velocity.removeAll(keepingCapacity: true); offsets.removeAll(keepingCapacity: true); cached = nil
    }
    /// `stale`: a preview whose evidence passed its deadline plans differently for the same frame and evidence.
    func plan(frame: ScreenFrame, revision: UInt64, preview: Bool, stale: Bool = false, build: () -> PrivacyTimeline.Plan) -> PrivacyTimeline.Plan {
        lock.lock(); defer { lock.unlock() }
        if let c = cached, c.epoch == frame.epoch, c.sequence == frame.sequence, c.revision == revision, c.preview == preview,
           c.stale == stale { return c.plan }
        // Numeric sequences are session-local: epoch reset must not reuse predictions from another source.
        if cachedEpoch != frame.epoch {
            motion.removeAll(keepingCapacity: true); velocity.removeAll(keepingCapacity: true); offsets.removeAll(keepingCapacity: true)
            cachedEpoch = frame.epoch
        }
        if motion.count > 512 { motion.removeAll(keepingCapacity: true) }
        previewing = preview
        let value = build()
        previewing = false
        cached = (frame.epoch, frame.sequence, revision, preview, stale, value)
        return value
    }

    @_optimize(speed)
    private func identical(_ patch: PrivacyRowPatch, _ p: UnsafePointer<UInt8>, _ stride: Int, x: Int, y: Int) -> Bool {
        patch.bytes.withUnsafeBytes { bytes in
            for row in 0..<patch.height where memcmp(bytes.baseAddress! + row * patch.width, p + (y + row) * stride + x, patch.width) != 0 {
                return false
            }
            return true
        }
    }
    /// Sparse-signature correlation of `patch` at `(x, y + dy)`, over samples whose patch row lies inside
    /// `top..<bottom`.
    @_optimize(speed)
    private func score(_ patch: PrivacyRowPatch, _ p: UnsafePointer<UInt8>, _ stride: Int, x: Int, y: Int, dy: Int, top: Int, bottom: Int) -> Float {
        let n = patch.values.count, base = p + (y + dy) * stride + x, first = top - y - dy, end = bottom - y - dy
        var used = 0, sa = 0, aa = 0, sb = 0, bb = 0, ab = 0
        patch.rows.withUnsafeBufferPointer { r in
            patch.columns.withUnsafeBufferPointer { c in
                patch.values.withUnsafeBufferPointer { v in
                    if first <= 0 && end >= patch.height {
                        used = n
                        for i in 0..<n {
                            let b = Int(base[r[i] * stride + c[i]]), a = v[i]
                            sa += a; aa += a * a; sb += b; bb += b * b; ab += a * b
                        }
                    } else {
                        for i in 0..<n where r[i] >= first && r[i] < end {
                            let b = Int(base[r[i] * stride + c[i]]), a = v[i]
                            used += 1; sa += a; aa += a * a; sb += b; bb += b * b; ab += a * b
                        }
                    }
                }
            }
        }
        guard used >= 16 else { return -1 }
        let count = Float(used), ma = Float(sa) / count, mb = Float(sb) / count
        let va = Float(aa) / count - ma * ma, vb = Float(bb) / count - mb * mb
        guard va > 4, vb > 4 else { return -1 }
        return (Float(ab) / count - ma * mb) / (va * vb).squareRoot()
    }
    /// Appends to `candidates` the local maxima of `score` over shifts `lo...hi` reaching `sparseMatch`.
    @_optimize(speed)
    private func rank(_ patch: PrivacyRowPatch, _ p: UnsafePointer<UInt8>, _ stride: Int, x: Int, y: Int, lo: Int, hi: Int, top: Int, bottom: Int) {
        guard lo <= hi else { return }
        var previous: Float = -1, rising = false
        for dy in lo...(hi + 1) {
            let s = dy <= hi ? score(patch, p, stride, x: x, y: y, dy: dy, top: top, bottom: bottom) : -1
            // `previous` is a local maximum once the score stops rising.
            if rising, s < previous, previous >= Self.sparseMatch { candidates.append((dy - 1, previous)) }
            rising = s >= previous || dy == lo
            previous = s
        }
    }
    /// Dense gain/offset match of patch rows `first..<end` at `(x, y)` over every other column, then per
    /// 32-column block.
    @_optimize(speed)
    private func verify(_ patch: PrivacyRowPatch, _ p: UnsafePointer<UInt8>, _ stride: Int, x: Int, y: Int, rows first: Int, _ end: Int) -> Bool {
        let w = patch.width
        guard end > first else { return false }
        return patch.bytes.withUnsafeBufferPointer { buffer in
            let a = buffer.baseAddress!
            var sa = 0, sb = 0, aa = 0, bb = 0, ab = 0
            for row in first..<end {
                let line = p + (y + row) * stride + x, source = a + row * w
                for column in Swift.stride(from: 0, to: w, by: 2) {
                    let av = Int(source[column]), bv = Int(line[column])
                    sa += av; sb += bv; aa += av * av; bb += bv * bv; ab += av * bv
                }
            }
            let count = Double(((w + 1) / 2) * (end - first))
            let va = Double(aa) - Double(sa) * Double(sa) / count, vb = Double(bb) - Double(sb) * Double(sb) / count
            let cov = Double(ab) - Double(sa) * Double(sb) / count
            guard va > count, vb > count, cov > 0, cov / (va * vb).squareRoot() >= Double(Self.denseMatch) else { return false }
            let gain = Float(cov / va), offset = Float((Double(sb) - cov / va * Double(sa)) / count)
            let limit = Self.blockResidual * Float((vb / count).squareRoot())
            for start in Swift.stride(from: 0, to: w, by: 32) {
                let stop = min(w, start + 32)
                var residual: Float = 0
                for row in first..<end {
                    let line = p + (y + row) * stride + x, source = a + row * w
                    for column in Swift.stride(from: start, to: stop, by: 2) {
                        residual += abs(Float(line[column]) - gain * Float(source[column]) - offset)
                    }
                }
                if residual > limit * Float(((stop - start + 1) / 2) * (end - first)) { return false }
            }
            return true
        }
    }
    /// The vertical shift at which `patch`, expected at `origin`, appears in `frame` with at least a fifth of
    /// its rows (and 3) inside `clip`, so text scrolling past a window edge stays found. Several equal
    /// matches (a repeated secret) resolve to the one nearest the prediction. `wide` false: near rows only.
    @_optimize(speed)
    private func locate(_ patch: PrivacyRowPatch, at origin: CGPoint, clip: CGRect, in frame: ScreenFrame, track: Track?, hint: Int?, wide: Bool = true) -> Int? {
        guard CVPixelBufferGetPixelFormatType(frame.buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              CVPixelBufferLockBaseAddress(frame.buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(frame.buffer, .readOnly) }
        guard let raw = CVPixelBufferGetBaseAddressOfPlane(frame.buffer, 0) else { return nil }
        let p = UnsafePointer(raw.assumingMemoryBound(to: UInt8.self)), stride = CVPixelBufferGetBytesPerRowOfPlane(frame.buffer, 0)
        let x = Int(origin.x.rounded()), y = Int(origin.y.rounded()), h = patch.height
        let width = CVPixelBufferGetWidth(frame.buffer), height = CVPixelBufferGetHeight(frame.buffer)
        guard x >= 0, x + patch.width <= width else { return nil }
        let known = track.flatMap { motion[$0] }
        let predicted = known.map { $0.shift + $0.step } ?? 0, previous = known?.shift ?? 0
        func found(_ dy: Int) -> Int {
            if let track { motion[track] = Motion(shift: dy, step: known.map { $0.misses == 0 ? dy - $0.shift : 0 } ?? 0) }
            return dy
        }
        func fits(_ dy: Int) -> Bool { y + dy >= 0 && y + dy + h <= height }
        if hint == nil {
            if fits(predicted), identical(patch, p, stride, x: x, y: y + predicted) { return found(predicted) }
            if previous != predicted, fits(previous), identical(patch, p, stride, x: x, y: y + previous) { return found(previous) }
            if predicted != 0, previous != 0, fits(0), identical(patch, p, stride, x: x, y: y) { return found(0) }
        }
        let top = max(Int(clip.minY.rounded(.up)), 0), bottom = min(Int(clip.maxY.rounded(.down)), height)
        let minimum = max(3, h / 5)
        let lo = top - y - (h - minimum), hi = bottom - y - minimum
        guard lo <= hi, patch.values.count >= 16 else { return nil }
        func accept(_ dy: Int) -> Bool {
            verify(patch, p, stride, x: x, y: y + dy, rows: max(0, top - y - dy), min(h, bottom - y - dy))
        }
        /// The candidate nearest `center` among new shifts `a...b` (and `c...d`) that passes the dense check.
        func search(_ center: Int, _ a: Int, _ b: Int, _ c: Int = 1, _ d: Int = 0) -> Int? {
            candidates.removeAll(keepingCapacity: true)
            rank(patch, p, stride, x: x, y: y, lo: a, hi: b, top: top, bottom: bottom)
            rank(patch, p, stride, x: x, y: y, lo: c, hi: d, top: top, bottom: bottom)
            candidates.sort { abs($0.dy - center) < abs($1.dy - center) }
            return candidates.prefix(4).first { accept($0.dy) }?.dy
        }
        if let hint {
            // Only where the rest of its window moved; a miss here is not this detection's own.
            return search(hint, max(lo, hint - Self.radii[0]), min(hi, hint + Self.radii[0])).map(found)
        }
        // Resampled pixels (a window at a fractional position) differ but still match where predicted.
        if predicted >= lo, predicted <= hi, score(patch, p, stride, x: x, y: y, dy: predicted, top: top, bottom: bottom) >= Self.sparseMatch,
           accept(predicted) { return found(predicted) }
        var searched = (lo: 1, hi: 0)
        // Near rows only (`wide` false: a moving window), else wider, and the whole window on a first
        // placement and every fourth consecutive miss.
        let stages = !wide ? 1 : known.map { $0.misses % 4 == 0 } ?? true ? Self.radii.count + 1 : Self.radii.count
        for stage in 0..<stages {
            let radius = stage < Self.radii.count ? Self.radii[stage] : Int.max / 4
            let a = max(lo, predicted - radius), b = min(hi, predicted + radius)
            guard a <= b, searched.lo > searched.hi || a < searched.lo || b > searched.hi else { continue }
            // Only the newly widened parts.
            let dy = searched.lo > searched.hi ? search(predicted, a, b) : search(predicted, a, searched.lo - 1, searched.hi + 1, b)
            searched = (a, b)
            if let dy { return found(dy) }
        }
        if let track { motion[track] = Motion(shift: previous, step: 0, misses: (known?.misses ?? 0) + 1) }
        return nil
    }
    /// Where `detection` from `scan` lies in `frame`: its scan's own pixels, or its patch found again in its
    /// window (moved with the window, then searched vertically for scrolling). Unresolved when the patch is
    /// not found (the text changed, reflowed or left the window) or `resolve` is false (the caller found
    /// the match ambiguous, which also drops its motion state). `predict` keeps per-detection motion state.
    /// `hint`, the shift its resolved neighbors in the same window found, limits the search to near it;
    /// without one, a missed search retries near where the window's recent scroll speed puts the row.
    /// A moving window's listed bounds miss its pixels by up to a frame's step: the first of its
    /// detections found in a frame measures the horizontal offset, which the rest then start from.
    func place(_ detection: Detection, from scan: ScanResult, in frame: ScreenFrame,
               previous: ScreenFrame?, next: ScreenFrame?, predict: Bool = true, resolve: Bool = true, hint: Int? = nil) -> Placement {
        lock.lock(); defer { lock.unlock() }
        let d = detection
        if scan.sequence == frame.sequence {
            // Read here, or carried here as a patch found in these pixels: the pixels decide, not the list.
            return Placement(rects: Self.visible(d.absolute, owner: nil, frame: frame), shift: 0, placed: d.absolute)
        }
        let bounds = d.owner.flatMap { frame.windows?.frame(of: $0) }
        let sourceBounds = d.owner.flatMap { scan.frame.windows?.frame(of: $0) }
        let origin = bounds?.origin ?? sourceBounds?.origin ?? CGPoint(x: d.absolute.minX - d.local.minX, y: d.absolute.minY - d.local.minY)
        let base = d.owner != nil ? d.local.offsetBy(dx: origin.x, dy: origin.y) : d.absolute
        var origins = [origin]
        if let owner = d.owner {
            for neighbor in [previous, next] {
                if let p = neighbor?.windows?.frame(of: owner)?.origin, !origins.contains(p) { origins.append(p) }
            }
        }
        // Pixels of a window listed at another place in a neighbor frame may sit up to that far off.
        let reach = bounds == nil ? 0 : min(Self.radii[0], Int(origins.map { abs($0.x - origin.x) }.max()!.rounded(.up)))
        var shift: Int?, dx = 0
        if let patch = d.patch {
            let track = predict ? Track(scan: scan.sequence, x: Int32(d.absolute.minX), y: Int32(d.absolute.minY), preview: previewing) : nil
            if !resolve { if let track { motion[track] = nil } }
            else {
                let window = d.owner ?? 0, elapsed = Double(Int64(bitPattern: frame.sequence &- scan.sequence))
                // This frame's offset of the window, once measured (nil: its first detection matched nowhere).
                let entry = reach > 0 ? offsets[window].flatMap { $0.sequence == frame.sequence && $0.preview == previewing ? $0 : nil } : nil
                dx = entry?.dx ?? 0
                let start = CGPoint(x: base.minX + d.patchOffset.x, y: base.minY + d.patchOffset.y), clip = bounds ?? frame.geometry.bounds
                func at(_ x: Int) -> CGPoint { CGPoint(x: start.x + CGFloat(x), y: start.y) }
                // A moving window's misses are its resampled pixels, not a far scroll: near rows only.
                shift = locate(patch, at: at(dx), clip: clip, in: frame, track: track, hint: hint, wide: reach == 0)
                if shift == nil, entry == nil, reach > 0 {
                    // Near rows only: the offset is the window's, not a scroll's.
                    let center = hint ?? track.flatMap { motion[$0]?.shift } ?? 0
                    search: for m in 1...reach {
                        for x in stride(from: -m, through: m, by: 2 * m) {
                            if let s = locate(patch, at: at(x), clip: clip, in: frame, track: track, hint: center) { shift = s; dx = x; break search }
                        }
                    }
                }
                if reach > 0, entry == nil {
                    if offsets.count > 64 { offsets.removeAll(keepingCapacity: true) }
                    offsets[window] = (frame.sequence, previewing, shift != nil ? dx : nil)
                }
                if let s = shift, s != 0 { velocity[window] = (Double(s) / elapsed, frame.sequence) }
                else if shift == nil, hint == nil, let v = velocity[window], max(frame.sequence, v.at) - min(frame.sequence, v.at) <= 8,
                        case let guess = Int((v.perFrame * elapsed).rounded()), guess != 0 {
                    shift = locate(patch, at: at(dx), clip: clip, in: frame, track: track, hint: guess)
                }
            }
        }
        var result = Placement(unresolved: shift == nil, shift: shift.map { CGFloat($0) },
                               placed: shift.map { base.offsetBy(dx: CGFloat(dx), dy: CGFloat($0)) })
        if let shift {
            // Found in this frame's own pixels: covered exactly there, whatever the window list says. The
            // list can trail or lead the pixels (a window listed lower, or a front window listed before it
            // is drawn), so clipping to it would expose text the dense check just saw.
            var r = base.offsetBy(dx: CGFloat(dx), dy: CGFloat(shift))
            if shift != 0 || dx != 0 { r = r.insetBy(dx: dx == 0 ? 0 : -2, dy: -2) }
            result.rects = Self.visible(r, owner: nil, frame: frame)
            return result
        }
        // Window bounds lag their pixels by up to a frame: cover where either neighbor puts the window,
        // clipped to the window as listed there.
        for candidate in origins {
            let shift = d.owner != nil ? CGPoint(x: candidate.x - origin.x, y: candidate.y - origin.y) : .zero
            let r = base.offsetBy(dx: shift.x, dy: shift.y)
            result.rects += Self.visible(r.insetBy(dx: -2, dy: -d.rowPitch), owner: d.owner, frame: frame, offset: shift)
        }
        return result
    }
    /// `offset`: how far from its listed bounds the owner's pixels lie.
    static func visible(_ rect: CGRect, owner: CGWindowID?, frame: ScreenFrame, offset: CGPoint = .zero) -> [CGRect] {
        let clipped = rect.intersection(frame.geometry.bounds)
        guard !clipped.isNull, !clipped.isEmpty else { return [] }
        var result = [clipped]
        if let owner, let windows = frame.windows?.windows, let i = windows.firstIndex(where: { $0.id == owner }) {
            // Clip to the owner's surface and subtract front windows, without bounding-box bridges.
            result = result.map { $0.intersection(windows[i].frame.offsetBy(dx: offset.x, dy: offset.y)) }.filter { !$0.isNull && !$0.isEmpty }
            for front in windows[..<i] { result = result.flatMap { subtract($0, front.frame) } }
        }
        return result
    }
    static func subtract(_ rect: CGRect, _ other: CGRect) -> [CGRect] {
        let i = rect.intersection(other)
        guard !i.isNull, !i.isEmpty else { return [rect] }
        return [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: i.minY - rect.minY),
                CGRect(x: rect.minX, y: i.maxY, width: rect.width, height: rect.maxY - i.maxY),
                CGRect(x: rect.minX, y: i.minY, width: i.minX - rect.minX, height: i.height),
                CGRect(x: i.maxX, y: i.minY, width: rect.maxX - i.maxX, height: i.height)].filter { $0.width > 0 && $0.height > 0 }
    }
}
