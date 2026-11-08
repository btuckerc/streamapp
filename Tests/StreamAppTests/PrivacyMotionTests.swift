import Foundation
import CoreGraphics
import CoreVideo
import Testing
@testable import StreamApp

struct PrivacyMotionTests {
    private let bounds = CGRect(x: 0, y: 0, width: 320, height: 320)
    private let span = CGRect(x: 24, y: 140, width: 180, height: 20)
    private func frame(_ sequence: UInt64, shift: Int = 0, edited: Bool = false, x: Int = 0, front: CGRect? = nil) throws -> ScreenFrame {
        var made: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 400, 360, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &made) == kCVReturnSuccess)
        let buffer = try #require(made)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 { memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!, plane == 0 ? 16 : 128,
            CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)) }
        let p = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<20 {
            for column in 0..<180 {
                let value = ((row * 73 + column * 19 + column * row * 13) % 211) + 24
                p[(140 + shift + row) * stride + 24 + x + column] = UInt8(edited ? 32 : value)
            }
        }
        return ScreenFrame(sequence: sequence, captured: Double(sequence) / 30, buffer: buffer,
            windows: WindowSnapshot(windows: (front.map { [.init(id: 2, frame: $0, layer: 0)] } ?? [])
                + [.init(id: 1, frame: bounds.offsetBy(dx: CGFloat(x), dy: 0), layer: 0)]),
            geometry: CaptureGeometry(size: CGSize(width: 400, height: 360), globalRect: .zero, tracksWindows: true), epoch: 0)
    }
    private func scan(_ f: ScreenFrame, _ rect: CGRect?) -> ScanResult {
        ScanResult(frame: f, rects: rect.map { [PrivacyScanner.normalized($0, f.geometry.size)] } ?? [])
    }
    private func contains(_ rects: [CGRect], _ r: CGRect) -> Bool {
        let union = PrivacyTimeline.exactUnion(rects.map { $0.intersection(r) })
        return union.reduce(0) { $0 + $1.width * $1.height } >= r.width * r.height - 0.001
    }
    @Test func scrolledSecretIsCoveredWithoutCoveringItsOldRow() throws {
        let a = try frame(1), f = try frame(4, shift: -48), b = try frame(9, shift: -96)
        let plan = PrivacyTimeline.plan(for: f, scans: [scan(a, span), scan(b, span.offsetBy(dx: 0, dy: -96))])
        #expect(contains(plan.boxes, span.offsetBy(dx: 0, dy: -48)))
        #expect(plan.uncertainRows.isEmpty)
        #expect(!plan.boxes.contains { $0.intersects(span) })
    }
    @Test func simultaneousDragAndScrollUseDifferentTransforms() throws {
        let a = try frame(1), f = try frame(4, shift: -40, x: 50)
        let plan = PrivacyTimeline.plan(for: f, scans: [scan(a, span)])
        #expect(contains(plan.boxes, span.offsetBy(dx: 50, dy: -40)))
        #expect(!plan.boxes.contains { $0.intersects(span) })
    }
    @Test func emptyChangedScansCarryTheOriginalPositivePatch() throws {
        let a = try frame(1), b = try frame(9, shift: -40), c = try frame(17, shift: -80)
        let timeline = PrivacyTimeline()
        let first = try #require(timeline.complete(scan(a, span)))
        let second = try #require(timeline.complete(scan(b, nil)))
        let third = try #require(timeline.complete(scan(c, nil)))
        #expect(!second.detections.isEmpty && !third.detections.isEmpty)
        #expect(third.detections.allSatisfy { $0.carried && $0.observedSequence == 1 && $0.patch === first.detections[0].patch })
        #expect(contains(timeline.preview(frame: c, now: c.captured).boxes, span.offsetBy(dx: 0, dy: -80)))
    }
    @Test func foundAndCarriedCoversFollowThePixelsNotAFrontWindowListedOverThem() throws {
        // Scrolled 40 rows up, the row sits at 100..<120 under a front window listed over 0..<119 but not
        // yet drawn: the pixels still show it. The carried detection stays the whole row (a sliver once
        // became a null rectangle and trapped) and is covered whole, before and after the front window goes.
        let front = CGRect(x: 0, y: 0, width: 400, height: 119)
        let a = try frame(1), b = try frame(9, shift: -40, front: front), c = try frame(17, shift: -40)
        let timeline = PrivacyTimeline()
        let row = try #require(timeline.complete(scan(a, span))?.detections.first).absolute.offsetBy(dx: 0, dy: -40)
        let second = try #require(timeline.complete(scan(b, nil)))
        let carried = try #require(second.detections.first)
        #expect(carried.absolute == row)
        #expect(contains(timeline.preview(frame: b, now: b.captured).boxes, row))
        #expect(contains(PrivacyTimeline.plan(for: c, scans: [second]).boxes, row))
        _ = try #require(timeline.complete(scan(c, nil)))
        #expect(contains(timeline.preview(frame: c, now: c.captured).boxes, row))
    }
    @Test func aSecretFoundBetweenScansIsCoveredWhereverTheListPutsWindows() throws {
        // Normal-spaced scans read the secret; the frame between them lists a front window over it that
        // is not drawn yet, then lists its own window 10 rows short of the secret's last rows.
        let a = try frame(1), b = try frame(9), shown = try frame(4, front: span)
        #expect(contains(PrivacyTimeline.plan(for: shown, scans: [scan(a, span), scan(b, span)]).boxes, span))
        let short = ScreenFrame(sequence: 4, captured: shown.captured, buffer: shown.buffer,
            windows: WindowSnapshot(windows: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 320, height: 150), layer: 0)]),
            geometry: shown.geometry, epoch: 0)
        let plan = PrivacyTimeline.plan(for: short, scans: [scan(a, span), scan(b, span)])
        #expect(contains(plan.boxes, span))
        #expect(plan.guards.isEmpty)
    }
    @Test func unresolvedNeighborOriginIsClippedToTheWindowListedThere() throws {
        // Pixels still at the previous origin while the list already moved the window 40 right: the
        // previous-origin candidate covers the secret's whole width, not only the part inside the new bounds.
        let a = try frame(1), previous = try frame(3), f = try frame(4, edited: true, x: 40)
        let plan = PrivacyTimeline.plan(for: f, previous: previous, scans: [scan(a, span)])
        #expect(contains(plan.uncertainRows, span))
    }
    @Test func changedSecretIsUnknownNotAWholeWindowCover() throws {
        let a = try frame(1), f = try frame(4, edited: true)
        let plan = PrivacyTimeline.plan(for: f, scans: [scan(a, span)])
        #expect(plan.degraded)
        #expect(plan.boxes.isEmpty)
        #expect(plan.uncertainRows.allSatisfy { $0.width <= span.width + 4 && $0.height <= span.height + 64 })
        #expect(!plan.uncertainRows.contains { $0.contains(CGPoint(x: 300, y: 300)) })
    }
    @Test func exactUnionPreservesHolesDiagonalsAndMoreThanEightCovers() {
        let rects = [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 5, y: 5, width: 10, height: 10)] +
            (0..<10).map { CGRect(x: 30 + $0 * 4, y: 30, width: 2, height: 2) }
        let union = PrivacyTimeline.exactUnion(rects)
        #expect(union.count > 8)
        let area = (0..<75).reduce(0) { total, x in total + (0..<35).filter { y in union.contains { $0.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) } }.count }
        #expect(area == 215)
        #expect(!union.contains { $0.contains(CGPoint(x: 2, y: 12)) })
        #expect(!union.contains { $0.contains(CGPoint(x: 12, y: 2)) })
    }
    @Test func frontWindowOcclusionIsSubtractedExactly() throws {
        let f = try frame(1)
        let occluded = ScreenFrame(sequence: 1, captured: f.captured, buffer: f.buffer,
            windows: WindowSnapshot(windows: [.init(id: 2, frame: CGRect(x: 60, y: 140, width: 40, height: 20), layer: 0),
                .init(id: 1, frame: bounds, layer: 0)]), geometry: f.geometry, epoch: 0)
        let visible = PrivacyMotionTracker.visible(span, owner: 1, frame: occluded)
        #expect(!visible.contains { $0.contains(CGPoint(x: 80, y: 150)) })
        #expect(visible.reduce(0) { $0 + $1.width * $1.height } == span.width * span.height - 800)
    }
    /// A credential row ending at the pane's right edge; `next` is the following row's read text, if any.
    private func wrapRecords(next: (start: CGFloat, couldContinue: Bool)?) -> [PrivacyScanner.OCRRecord] {
        let pane = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        var parent = PrivacyScanner.OCRLine(box: CGRect(x: 0.12, y: 0.6, width: 0.72, height: 0.02))
        parent.pane = pane; parent.endsInCredential = true; parent.secret = parent.box
        parent.advance = 0.01
        var calibration = PrivacyScanner.OCRLine(box: CGRect(x: 0.12, y: 0.63, width: 0.72, height: 0.02))
        calibration.pane = pane; calibration.advance = parent.advance
        var records: [PrivacyScanner.OCRRecord] = [.init(line: parent, matches: [parent.box]), .init(line: calibration, matches: [])]
        if let next {
            var following = PrivacyScanner.OCRLine(box: CGRect(x: next.start, y: 0.57, width: 0.5, height: 0.02))
            following.pane = pane; following.rawStartCouldContinue = next.couldContinue
            records.append(.init(line: following, matches: []))
        }
        return records
    }
    @Test func unreadWrapTailIsEightCellsOfTheNextRow() {
        let tails = PrivacyScanner.wrapTails(wrapRecords(next: nil), aspect: 1)
        #expect(tails.count == 1)
        #expect(abs((tails.first?.rect.width ?? 0) - 0.08) < 1e-8)
        #expect(abs((tails.first?.rect.midY ?? 0) - 0.58) < 1e-8)
        // A row read from its start decides itself.
        #expect(PrivacyScanner.wrapTails(wrapRecords(next: (0.12, false)), aspect: 1).isEmpty)
        #expect(PrivacyScanner.wrapTails(wrapRecords(next: (0.12, true)), aspect: 1).isEmpty)
        // Text read two cells in (an unread prompt glyph) leaves only those two cells.
        let clipped = PrivacyScanner.wrapTails(wrapRecords(next: (0.14, false)), aspect: 1)
        #expect(abs((clipped.first?.rect.width ?? 0) - 0.02) < 1e-8)
    }
}
