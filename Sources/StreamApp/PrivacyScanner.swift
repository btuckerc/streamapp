import Foundation
import CoreVideo

/// One latest slot; submissions and the existing compositor cadence drive the throttle.
final class PrivacyScanner: @unchecked Sendable {
    /// Minimum time between scan starts: with recognition latency, inside the render delay.
    static let interval: TimeInterval = 0.25
    private let queue = DispatchQueue(label: "streamapp.privacy-scanner", qos: .utility)
    private let lock = NSLock()
    private let publish: @Sendable (ScanResult) -> Void
    private var enabled = false
    private var latest: ScreenFrame?
    private var running = false
    private var hidesPersonalInfo = true
    private var revision: UInt64 = 0
    private var lastStart = -Double.infinity
    /// Queue-confined: the last recognized input, its pre-context OCR records and its result.
    struct Recognized {
        let buffer: CVPixelBuffer
        let personal: Bool
        let revision: UInt64
        let records: [OCRRecord]
        let rects: [CGRect]
    }
    var recognized: Recognized?

    init(publish: @escaping @Sendable (ScanResult) -> Void) { self.publish = publish }
    func configure(enabled: Bool, hidesPersonalInfo: Bool) {
        lock.lock()
        if self.enabled != enabled || self.hidesPersonalInfo != hidesPersonalInfo {
            revision &+= 1; latest = nil
            queue.async { self.recognized = nil }
        }
        self.enabled = enabled; self.hidesPersonalInfo = hidesPersonalInfo
        lock.unlock()
    }
    func submit(_ frame: ScreenFrame) {
        lock.lock(); if enabled { latest = frame }; lock.unlock()
        tick()
    }
    func tick() {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        guard enabled, !running, let frame = latest, now - lastStart >= Self.interval else { lock.unlock(); return }
        latest = nil; running = true; lastStart = now
        let personal = hidesPersonalInfo, revision = self.revision
        lock.unlock()
        queue.async {
            // A failed scan publishes no evidence; known positives remain detection-conditioned.
            let size = frame.geometry.size
            let windows = frame.geometry.tracksWindows ? (frame.windows?.windows ?? []).map { w in
                CGRect(x: w.frame.minX / size.width, y: 1 - w.frame.maxY / size.height,
                       width: w.frame.width / size.width, height: w.frame.height / size.height)
            } : []
            let result = self.recognize(frame, windows: windows, personal: personal, revision: revision)
            self.lock.lock()
            let accept = self.enabled && revision == self.revision
            self.running = false
            self.lock.unlock()
            if accept, let result { self.publish(self.scanResult(frame: frame, rects: result)) }
            self.tick()
        }
    }
    /// Recognition of `frame`, re-reading only regions around pixels changed since the last
    /// recognized input; every other record lies over exactly unchanged pixels, so context is rebuilt
    /// over the whole image. Option changes, too large regions, and text cut by a region edge take a
    /// whole-image scan. A failed scan publishes nothing and keeps the reference.
    func recognize(_ frame: ScreenFrame, windows: [CGRect], personal: Bool, revision: UInt64) -> [CGRect]? {
        let size = CGSize(width: CVPixelBufferGetWidth(frame.buffer), height: CVPixelBufferGetHeight(frame.buffer))
        guard size.width > 0, size.height > 0 else { return nil }
        var records: [OCRRecord]?
        if let last = recognized, last.personal == personal, last.revision == revision {
            let tiles = changedTiles(frame.buffer, last.buffer, in: CGRect(origin: .zero, size: size))
            if tiles.isEmpty {
                recognized = Recognized(buffer: frame.buffer, personal: personal, revision: revision, records: last.records, rects: last.rects)
                return last.rects
            }
            if let regions = Self.regions(around: tiles, records: last.records, size: size),
               let fresh = try? Self.observe(frame.buffer, hidesPersonalInfo: personal, windows: windows, regions: regions) {
                records = last.records.filter { r in !regions.contains { $0.intersects(r.extent) } } + fresh
            }
        }
        if records == nil { records = try? Self.observe(frame.buffer, hidesPersonalInfo: personal, windows: windows) }
        guard let records else { return nil }
        let rects = Self.redactions(records, aspect: size.height / size.width)
        recognized = Recognized(buffer: frame.buffer, personal: personal, revision: revision, records: records, rects: rects)
        return rects
    }
    /// Both live publication and the evaluation harness retain identical OCR row/provenance evidence.
    func scanResult(frame: ScreenFrame, rects: [CGRect]) -> ScanResult {
        ScanResult(frame: frame, rects: rects, records: recognized?.records ?? [])
    }
    /// Top-left pixels to normalized, bottom-left.
    static func normalized(_ r: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: r.minX / size.width, y: 1 - r.maxY / size.height, width: r.width / size.width, height: r.height / size.height)
    }
    /// Atlas reads cost about in proportion to their area; past this share of the image a
    /// whole-image read costs about the same and sees all context.
    static let maxRegionArea: CGFloat = 0.6
    /// Regions (normalized, bottom-left) to re-read around changed tiles (top-left pixels): each tile
    /// padded by a line of nearby text, at least 16 px, and grown until no cached text lies within
    /// 8 px of an edge, so a re-read finding text at an edge inside the image means new text crossing
    /// it. Overlapping regions merge only when their bounding box adds little, so a moved window's
    /// outline stays a few strips rather than its whole box. One request reads them all (see
    /// `observe`), so their number costs little. Nil past `maxRegionArea`.
    static func regions(around tiles: [CGRect], records: [OCRRecord], size: CGSize) -> [CGRect]? {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1), px = 1 / size.width, py = 1 / size.height
        let area = { (r: CGRect) in r.isNull ? 0 : r.width * r.height }
        guard tiles.reduce(0, { $0 + area($1) }) * px * py <= maxRegionArea else { return nil }
        let extents = records.map(\.extent)
        var regions = tiles.map { tile -> CGRect in
            let r = normalized(tile, size)
            let near = r.insetBy(dx: -16 * px, dy: -16 * py)
            let pad = max(16, extents.filter { $0.intersects(near) }.map { $0.height / py }.max() ?? 0)
            return r.insetBy(dx: -pad * px, dy: -pad * py).intersection(unit)
        }
        // Rects only grow, so this ends; the cap only guards float rounding.
        for _ in 0..<32 {
            var changed = false, merged: [CGRect] = []
            for region in regions {
                var r = region
                while let i = merged.firstIndex(where: { m in
                    m.intersects(r) && area(m.union(r)) <= 1.25 * (area(m) + area(r) - area(m.intersection(r)))
                }) { r = r.union(merged.remove(at: i)); changed = true }
                merged.append(r)
            }
            regions = merged
            guard regions.count <= 64 else { return nil }
            for i in regions.indices {
                for e in extents {
                    let need = e.insetBy(dx: -8 * px, dy: -8 * py).intersection(unit)
                    // The tolerance keeps a rounded union from counting as still short of `need`.
                    if regions[i].intersects(need), !regions[i].insetBy(dx: -1e-9, dy: -1e-9).contains(need) {
                        regions[i] = regions[i].union(need); changed = true
                    }
                }
            }
            if !changed {
                guard regions.reduce(0, { $0 + area($1) }) <= maxRegionArea else { return nil }
                return regions
            }
        }
        return nil
    }
}
