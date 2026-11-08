import Foundation
import Vision
import CoreVideo

/// OCR and box geometry. Output: padded detection boxes in Vision's normalized, bottom-left-origin
/// coordinates for the scanned buffer. Fragments on one text row are merged; rows never merge.
extension PrivacyScanner {
    /// One recognized observation before context, in full-image normalized coordinates: kept so a
    /// rescan of changed regions can rebuild context over the whole image.
    struct OCRRecord {
        var line: OCRLine
        /// Matched sensitive ranges in this observation alone.
        var matches: [CGRect]
        /// Everything this record places.
        var extent: CGRect {
            ([line.labelBox, line.secret].compactMap { $0 } + line.continuations + matches).reduce(line.box) { $0.union($1) }
        }
    }
    /// Recognizes the whole image (`regions` nil) or only `regions` (normalized, bottom-left), copied
    /// into one atlas so a single request reads them all: Vision's cost per request dwarfs a small
    /// region's. `windows`: visible window rects front to back, in the same normalized coordinates;
    /// empty for a single-window source or a failed window query. Throws when an observation spans
    /// two atlas slots or reaches an edge of its slot inside the image (its text may continue beyond
    /// what was read), so the caller reads the whole image instead.
    static func observe(_ pixelBuffer: CVPixelBuffer, hidesPersonalInfo: Bool, windows: [CGRect] = [],
                        regions: [CGRect]? = nil) throws -> [OCRRecord] {
        let atlas = try regions.map { try Atlas($0, of: pixelBuffer) }
        let image = atlas?.buffer ?? pixelBuffer
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        // The same absolute minimum as a whole-image scan, relative to the atlas.
        request.minimumTextHeight = Float(min(1, 0.008 * CGFloat(CVPixelBufferGetHeight(pixelBuffer)) / CGFloat(CVPixelBufferGetHeight(image))))
        try VNImageRequestHandler(cvPixelBuffer: image).perform([request])
        let detector = SensitiveTextDetector()
        var records: [OCRRecord] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            // Maps the request's normalized boxes to the whole image.
            let full = try atlas.map { try $0.mapping(for: observation.boundingBox) } ?? { $0 }
            let text = candidate.string, box = full(observation.boundingBox)
            var record = OCRRecord(line: OCRLine(box: box), matches: [])
            record.line.pane = windows.first { $0.contains(CGPoint(x: box.midX, y: box.midY)) } ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            record.line.rawStartCouldContinue = detector.couldContinueSecret(text)
            // The line's mean glyph advance: long lines of one pane agreeing on it establish a monospace grid.
            if text.count >= 16 { record.line.advance = box.width / CGFloat(text.count) }
            if let label = detector.secretLabelRange(in: text) {
                record.line.labelBox = (try? candidate.boundingBox(for: label)).map { full($0.boundingBox) } ?? box
            }
            let found = detector.ocrRanges(in: text, hidesPersonalInfo: hidesPersonalInfo)
            record.line.endsInCredential = found.endsInCredential
            for range in found.ranges {
                // A detected secret must never pass unredacted: if Vision cannot localize the
                // matched range, hide the whole recognized line instead.
                let b = (try? candidate.boundingBox(for: range)).map { full($0.boundingBox) } ?? box
                record.matches.append(b)
                record.line.secret = record.line.secret.map { $0.union(b) } ?? b
            }
            record.line.continuations = segments(of: candidate, box: box, windows: windows, full: full)
                .filter { detector.couldContinueSecret(String(text[$0.range])) }.map(\.box)
            records.append(record)
        }
        return records
    }
    /// Regions of a 420f image copied into one 420f buffer: shelves of slots separated by blank gaps
    /// wider than text joins across, at even pixels so chroma copies whole.
    struct Atlas {
        struct Spill: Error {}
        let buffer: CVPixelBuffer
        /// Each slot's source (whole-image normalized) and place (atlas normalized), bottom-left.
        private(set) var slots: [(source: CGRect, place: CGRect)] = []
        static let gap = 64

        init(_ regions: [CGRect], of image: CVPixelBuffer) throws {
            let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
            guard CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { throw Spill() }
            // Pixel rects (top-left), grown to even bounds.
            let rects = regions.map { r -> (x: Int, y: Int, w: Int, h: Int) in
                let x0 = max(0, Int((r.minX * CGFloat(width)).rounded(.down)) & ~1)
                let y0 = max(0, Int(((1 - r.maxY) * CGFloat(height)).rounded(.down)) & ~1)
                let x1 = min(width & ~1, (Int((r.maxX * CGFloat(width)).rounded(.up)) + 1) & ~1)
                let y1 = min(height & ~1, (Int(((1 - r.minY) * CGFloat(height)).rounded(.up)) + 1) & ~1)
                return (x0, y0, max(0, x1 - x0), max(0, y1 - y0))
            }.filter { $0.w > 0 && $0.h > 0 }
            // Shelf packing, tallest first, no wider than the image.
            var places: [(index: Int, x: Int, y: Int)] = []
            var x = Self.gap / 2, y = Self.gap / 2, shelf = 0, used = 0
            for i in rects.indices.sorted(by: { rects[$0].h > rects[$1].h }) {
                if x > Self.gap / 2, x + rects[i].w + Self.gap / 2 > max(width, rects[i].w + Self.gap) {
                    x = Self.gap / 2; y += shelf + Self.gap; shelf = 0
                }
                places.append((i, x, y))
                x += rects[i].w + Self.gap; shelf = max(shelf, rects[i].h); used = max(used, x - Self.gap / 2)
            }
            let atlasWidth = (used + 1) & ~1, atlasHeight = (y + shelf + Self.gap / 2 + 1) & ~1
            var created: CVPixelBuffer?
            guard !places.isEmpty, atlasHeight <= 2 * height,
                  CVPixelBufferCreate(nil, atlasWidth, atlasHeight, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &created) == kCVReturnSuccess,
                  let atlas = created else { throw Spill() }
            guard CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { throw Spill() }
            defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
            guard CVPixelBufferLockBaseAddress(atlas, []) == kCVReturnSuccess else { throw Spill() }
            defer { CVPixelBufferUnlockBaseAddress(atlas, []) }
            for plane in 0..<2 {
                guard let source = CVPixelBufferGetBaseAddressOfPlane(image, plane),
                      let target = CVPixelBufferGetBaseAddressOfPlane(atlas, plane) else { throw Spill() }
                let sourceRow = CVPixelBufferGetBytesPerRowOfPlane(image, plane), targetRow = CVPixelBufferGetBytesPerRowOfPlane(atlas, plane)
                // Blank: black luma, neutral chroma. Chroma rows are half as many, bytes per row the same.
                memset(target, plane == 0 ? 0 : 128, targetRow * CVPixelBufferGetHeightOfPlane(atlas, plane))
                let scale = plane == 0 ? 1 : 2
                for p in places {
                    let r = rects[p.index]
                    for row in 0..<(r.h / scale) {
                        memcpy(target + (p.y / scale + row) * targetRow + p.x, source + (r.y / scale + row) * sourceRow + r.x, r.w)
                    }
                }
            }
            buffer = atlas
            slots = places.map { p in
                let r = rects[p.index]
                return (CGRect(x: CGFloat(r.x) / CGFloat(width), y: 1 - CGFloat(r.y + r.h) / CGFloat(height),
                               width: CGFloat(r.w) / CGFloat(width), height: CGFloat(r.h) / CGFloat(height)),
                        CGRect(x: CGFloat(p.x) / CGFloat(atlasWidth), y: 1 - CGFloat(p.y + r.h) / CGFloat(atlasHeight),
                               width: CGFloat(r.w) / CGFloat(atlasWidth), height: CGFloat(r.h) / CGFloat(atlasHeight)))
            }
        }
        /// The map from atlas-normalized boxes to whole-image ones for an observation at `box`, which
        /// must lie in one slot (a blank margin of a pixel or two aside) and stay 2 px clear of each
        /// slot edge inside the image: its own slot, since slots of overlapping regions read the same
        /// pixels with different edges.
        func mapping(for box: CGRect) throws -> (CGRect) -> CGRect {
            let center = CGPoint(x: box.midX, y: box.midY)
            let tx = 2 / CGFloat(CVPixelBufferGetWidth(buffer)), ty = 2 / CGFloat(CVPixelBufferGetHeight(buffer))
            guard let slot = slots.first(where: { $0.place.contains(center) }) else { throw Spill() }
            let s = slot.source, p = slot.place, border: CGFloat = 1e-6
            guard p.insetBy(dx: -tx, dy: -ty).contains(box),
                  s.minX <= border || box.minX > p.minX + tx, s.maxX >= 1 - border || box.maxX < p.maxX - tx,
                  s.minY <= border || box.minY > p.minY + ty, s.maxY >= 1 - border || box.maxY < p.maxY - ty
            else { throw Spill() }
            let sx = s.width / p.width, sy = s.height / p.height
            return { r in
                CGRect(x: s.minX + (r.minX - p.minX) * sx, y: s.minY + (r.minY - p.minY) * sy,
                       width: r.width * sx, height: r.height * sy)
            }
        }
    }
    /// Context over the whole image's records, then row merging. `aspect` is buffer height / width.
    static func redactions(_ records: [OCRRecord], aspect: CGFloat) -> [CGRect] {
        let tails = wrapTails(records, aspect: aspect).map(\.rect)
        return mergeRows(records.flatMap(\.matches) + contextualRedactions(records.map(\.line), aspect: aspect) + tails, aspect: aspect)
    }

    /// Fast OCR joins text from adjacent windows into one observation. An observation crossing a
    /// window edge splits into runs of words whose centers share the frontmost window (or the
    /// desktop); any other observation stays whole. `full` maps the request's region-relative boxes
    /// to whole-image coordinates.
    static func segments(of candidate: VNRecognizedText, box: CGRect, windows: [CGRect],
                         full: (CGRect) -> CGRect) -> [(range: Range<String.Index>, box: CGRect)] {
        let text = candidate.string
        let whole = [(range: text.startIndex..<text.endIndex, box: box)]
        guard windows.contains(where: { w in
            w.minY < box.midY && box.midY < w.maxY &&
                ((box.minX < w.minX && w.minX < box.maxX) || (box.minX < w.maxX && w.maxX < box.maxX))
        }) else { return whole }
        var result: [(range: Range<String.Index>, box: CGRect)] = []
        var owner = -2
        for word in text.split(whereSeparator: \.isWhitespace) {
            let range = word.startIndex..<word.endIndex
            guard let b = (try? candidate.boundingBox(for: range)).map({ full($0.boundingBox) }) else { return whole }
            let center = CGPoint(x: b.midX, y: b.midY)
            let o = windows.firstIndex { $0.contains(center) } ?? -1
            if o == owner, let last = result.popLast() {
                result.append((last.range.lowerBound..<range.upperBound, last.box.union(b)))
            } else {
                result.append((range, b)); owner = o
            }
        }
        return result.isEmpty ? whole : result
    }

    struct OCRLine {
        var box: CGRect
        /// The credential label ending this line (`OPENROUTER_API_KEY=`), when the line ends in one.
        var labelBox: CGRect?
        /// Sensitive text in this line: matched ranges, a label's own value, or a wrapped remainder.
        var secret: CGRect?
        /// The line's text ends in a credential (its secret runs to the line's end).
        var endsInCredential = false
        /// Parts of the line (split at window edges) that could be the wrapped remainder of a secret.
        var continuations: [CGRect] = []
        var rawStartCouldContinue: Bool?
        var advance: CGFloat?
        var pane: CGRect?
    }

    /// Lines hidden by their neighbours, in Vision's normalized, bottom-left-origin coordinates.
    /// `aspect` is buffer height / width, so a text height converts to x units.
    /// Fast OCR splits a row at wide gaps and misread characters: a credential label hides the nearest
    /// line starting to its right on the same row, within a few label heights, and the label itself;
    /// a value or credential running to its line's end hides the next line to its right within two
    /// text heights, and so on along the row. A label with no
    /// value beside it ends its line, so its value wrapped below. A secret may wrap: the nearest
    /// token-like row directly below that starts at (or left of) the start of the secret's text — or
    /// of a label just left of it — is hidden too, and so on down. Fast OCR interpolates sub-range boxes
    /// across a whole observation, so a line joined with another window's text can place the secret's
    /// start too far left: a row starting left of the secret's middle also continues it. Geometry comes
    /// from the secret, label and continuation text itself, never from text of another window joined into the line.
    static func contextualRedactions(_ input: [OCRLine], aspect: CGFloat) -> [CGRect] {
        var lines = input
        var hidden: [CGRect] = []
        var labels: [CGRect] = []
        var wrappedLabels: [(line: Int, box: CGRect)] = []
        /// The nearest other line starting right of `anchor`'s middle on its row, within `reach`.
        func next(after anchor: CGRect, of index: Int, reach: CGFloat) -> Int? {
            lines.indices.filter { other in
                let b = lines[other].box
                return other != index && b.minX >= anchor.midX && b.minX - anchor.maxX <= reach && b.midY > anchor.minY && b.midY < anchor.maxY
            }.min { lines[$0].box.minX < lines[$1].box.minX }
        }
        /// Hides `line`, continuing the row from `anchor`, with the gap between them: text OCR dropped
        /// there (a pointer over the secret splits its row) belongs to the same run.
        func hide(_ line: Int, after anchor: CGRect) {
            let b = lines[line].box
            let run = b.minX > anchor.maxX ? CGRect(x: anchor.maxX, y: b.minY, width: b.maxX - anchor.maxX, height: b.height) : b
            if !hidden.contains(run) { hidden.append(run) }
            lines[line].secret = lines[line].secret.map { $0.union(b) } ?? b
        }
        /// Hides the lines continuing `line`'s row to the right, each within two text heights of the last.
        func extendRow(_ line: Int) {
            var current = line, seen: Set<Int> = [line]
            while let right = next(after: lines[current].box, of: current, reach: 2 * lines[current].box.height * aspect),
                  seen.insert(right).inserted {
                hide(right, after: lines[current].box); current = right
            }
        }
        for index in lines.indices {
            guard let l = lines[index].labelBox else { continue }
            if let value = next(after: l, of: index, reach: 4 * l.height * aspect) {
                hide(value, after: l); extendRow(value)
                labels.append(l)
            } else {
                lines[index].secret = lines[index].secret.map { $0.union(l) } ?? l
                wrappedLabels.append((index, l))
            }
        }
        for index in lines.indices where lines[index].endsInCredential { extendRow(index) }
        var continued = Set<Int>()
        func top(_ line: OCRLine) -> CGFloat { (line.secret ?? line.continuations.first ?? line.box).maxY }
        for index in lines.indices.sorted(by: { top(lines[$0]) > top(lines[$1]) }) {
            guard let l = lines[index].secret else { continue }
            let unit = l.height * aspect
            let rowStart = lines.compactMap { other -> CGFloat? in
                guard let label = other.labelBox, label.midY > l.minY, label.midY < l.maxY,
                      label.maxX <= l.minX + unit, l.minX - label.maxX <= 4 * unit else { return nil }
                return label.minX
            }.min().map { min($0, l.minX) } ?? l.minX
            let candidates = lines.indices.flatMap { below in
                lines[below].continuations.filter { b in
                    b.maxY <= l.midY && l.minY - b.maxY < l.height && b.minX <= max(rowStart + 1.5 * unit, l.midX) && b.maxX > rowStart
                }.map { (line: below, box: $0) }
            }
            guard let nearest = candidates.max(by: { $0.box.maxY < $1.box.maxY }) else { continue }
            continued.insert(index)
            // Parts of the same line touching a fitting one: a window edge listed a little off (a
            // moving window) splits the remainder, and only its first part starts in the column.
            var chosen = candidates.filter { $0.box.midY > nearest.box.minY && $0.box.midY < nearest.box.maxY }
            var grew = true
            while grew {
                grew = false
                for c in chosen {
                    for part in lines[c.line].continuations where !chosen.contains(where: { $0.box == part }) &&
                        part.minX - c.box.maxX <= unit && c.box.minX - part.maxX <= unit {
                        chosen.append((c.line, part)); grew = true
                    }
                }
            }
            for c in chosen {
                if !hidden.contains(c.box) { hidden.append(c.box) }
                // The next row continues from this column, not from another window's text joined left;
                // a secret the line itself holds keeps its own start.
                let own = lines[c.line].secret
                let union = own.map { $0.union(c.box) } ?? c.box
                let start = min(max(union.minX, rowStart), union.maxX, own?.minX ?? .infinity)
                lines[c.line].secret = CGRect(x: start, y: union.minY, width: union.maxX - start, height: union.height)
                extendRow(c.line)
            }
        }
        // A trailing label is hidden only when its wrapped value was found below it.
        return hidden + labels + wrappedLabels.filter { continued.contains($0.line) }.map(\.box)
    }

    /// Predict at most one unread row from an established grid. Raw non-continuation always wins.
    static func wrapTails(_ records: [OCRRecord], aspect: CGFloat) -> [(rect: CGRect, parent: CGRect)] {
        let lines = records.map(\.line)
        let positives = records.flatMap(\.matches) + contextualRedactions(lines, aspect: aspect)
        var result: [(rect: CGRect, parent: CGRect)] = []
        for line in lines {
            guard line.endsInCredential || positives.contains(where: { $0.intersects(line.box) }),
                  let pane = line.pane else { continue }
            let same = lines.filter { $0.pane == pane }
            let advances = same.compactMap(\.advance).sorted()
            guard advances.count >= 2 else { continue }
            let c = advances[advances.count / 2]
            guard c > 0, advances.filter({ abs($0 - c) <= 0.15 * c }).count >= Int(ceil(0.85 * Double(advances.count))) else { continue }
            let left = same.map(\.box.minX).min() ?? line.box.minX
            let right = same.map(\.box.maxX).max() ?? line.box.maxX
            guard same.filter({ abs($0.box.minX - left) <= c }).count >= 2,
                  same.filter({ abs($0.box.maxX - right) <= 2 * c }).count >= 2,
                  right - line.box.maxX <= 2 * c else { continue }
            let baselines = same.map(\.box.midY).sorted()
            let spaces = zip(baselines, baselines.dropFirst()).map { $1 - $0 }.filter { $0 > line.box.height * 0.7 }
            // The closest row spacing: blank lines and headers only widen gaps.
            guard let pitch = spaces.min() else { continue }
            let nextY = line.box.midY - pitch
            guard nextY > pane.minY else { continue }
            let row = same.filter { abs($0.box.midY - nextY) <= line.box.height * 0.6 && $0.box.maxX >= left }
            let fresh = row.filter { $0.box.minX <= left + c }
            // A row read in full is not a tail: its own text decides it.
            if fresh.contains(where: { $0.rawStartCouldContinue == false || $0.box.width > 8 * c }) { continue }
            // The whole row pitch: OCR boxes sit a pixel or two off the glyph cells.
            var tail = CGRect(x: left, y: nextY - pitch / 2, width: 8 * c, height: pitch).intersection(pane)
            if let ink = fresh.first(where: { $0.rawStartCouldContinue == true && $0.box.width <= 8 * c }) {
                tail = tail.intersection(CGRect(x: ink.box.minX, y: tail.minY, width: ink.box.width, height: tail.height))
            }
            // Text read further along the row ends the unread start.
            if !tail.isNull, let next = row.filter({ $0.box.minX > left + c }).map(\.box.minX).min(), next < tail.maxX {
                tail.size.width = max(0, next - tail.minX)
            }
            guard !tail.isNull, !tail.isEmpty else { continue }
            result.append((tail, line.box))
        }
        return result
    }

    /// Merges fragments of one text row (vertical overlap at least half the shorter height, horizontal
    /// gap at most one text height), then pads each box by its text height: 0.4 h left and right,
    /// 0.25 h above and below. Boxes on different rows never merge, so coverage stays line-tight.
    static func mergeRows(_ boxes: [CGRect], aspect: CGFloat) -> [CGRect] {
        var rows = boxes.filter { !$0.isNull && !$0.isEmpty }
        var merged = true
        while merged {
            merged = false
            outer: for i in rows.indices {
                for j in rows.indices where j > i {
                    let a = rows[i], b = rows[j]
                    let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                    let gap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
                    guard overlap >= 0.5 * min(a.height, b.height), gap <= max(a.height, b.height) * aspect else { continue }
                    rows[i] = a.union(b)
                    rows.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        return rows.map { box in
            box.insetBy(dx: -0.4 * box.height * aspect, dy: -0.25 * box.height).intersection(unit)
        }
    }
}
