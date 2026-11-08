import Foundation
import CoreGraphics
import CoreVideo
import Testing
@testable import StreamApp

struct PrivacyTimelineTests {
    private let size = CGSize(width: 64, height: 64)
    private let secret = CGRect(x: 4, y: 4, width: 12, height: 8)
    private func buffer() throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &created) == kCVReturnSuccess)
        let value = try #require(created)
        CVPixelBufferLockBaseAddress(value, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(value, plane)!, 0,
                CVPixelBufferGetBytesPerRowOfPlane(value, plane) * CVPixelBufferGetHeightOfPlane(value, plane))
        }
        CVPixelBufferUnlockBaseAddress(value, [])
        return value
    }
    private func change(_ value: CVPixelBuffer, plane: Int, x: Int, y: Int) {
        CVPixelBufferLockBaseAddress(value, [])
        CVPixelBufferGetBaseAddressOfPlane(value, plane)!.assumingMemoryBound(to: UInt8.self)[y * CVPixelBufferGetBytesPerRowOfPlane(value, plane) + x] = 1
        CVPixelBufferUnlockBaseAddress(value, [])
    }
    private func frame(_ sequence: UInt64, _ time: Double, x: CGFloat = 0, windows: Bool = true,
                       snapshot: Bool = true, present: Bool = true, buffer: CVPixelBuffer? = nil, epoch: UInt64 = 0) throws -> ScreenFrame {
        let bounds = CGRect(x: x, y: 8, width: 40, height: 40)
        return ScreenFrame(sequence: sequence, captured: time, buffer: try buffer ?? self.buffer(),
            windows: snapshot ? WindowSnapshot(windows: present ? [.init(id: 7, frame: bounds, layer: 0)] : []) : nil,
            geometry: CaptureGeometry(size: size, globalRect: CGRect(origin: .zero, size: size), tracksWindows: windows), epoch: epoch)
    }
    private func scan(_ frame: ScreenFrame, rect: CGRect?) -> ScanResult {
        let normalized = rect.map { CGRect(x: $0.minX / 64, y: 1 - $0.maxY / 64, width: $0.width / 64, height: $0.height / 64) }
        return ScanResult(frame: frame, rects: normalized.map { [$0] } ?? [])
    }
    private func covers(_ rects: [CGRect], _ rect: CGRect) -> Bool { rects.contains { $0.contains(rect) } }

    @Test func draggingUsesSeparateOwnerOriginCandidatesWithoutTrails() throws {
        let frames = try (0..<7).map { try frame(UInt64($0 + 1), Double($0) / 30, x: CGFloat($0 * 3)) }
        let scans = [0, 3, 6].map { i in scan(frames[i], rect: secret.offsetBy(dx: CGFloat(i * 3), dy: 8)) }
        #expect(scans.allSatisfy { $0.detections.first?.local == secret })
        for i in frames.indices {
            let plan = PrivacyTimeline.plan(for: frames[i], previous: i > 0 ? frames[i - 1] : nil,
                next: i + 1 < frames.count ? frames[i + 1] : nil, scans: scans)
            #expect(covers(plan.boxes, secret.offsetBy(dx: CGFloat(i * 3), dy: 8)))
            #expect(plan.uncertainRows.isEmpty)
            // Only the neighboring-frame skew union is allowed, not scan-time screen trails.
            #expect(plan.boxes.allSatisfy { $0.width <= secret.width + 6 })
        }
    }
    @Test func exactWindowContainmentWinsOverAFrontWindowsMargin() throws {
        let front = WindowSnapshot.Window(id: 9, frame: CGRect(x: 0, y: 8, width: 20, height: 40), layer: 0)
        let back = WindowSnapshot.Window(id: 7, frame: CGRect(x: 0, y: 8, width: 60, height: 50), layer: 0)
        let f = ScreenFrame(sequence: 1, captured: 0, buffer: try buffer(), windows: WindowSnapshot(windows: [front, back]),
            geometry: CaptureGeometry(size: size, globalRect: CGRect(origin: .zero, size: size), tracksWindows: true), epoch: 0)
        // Centre x 26: within the front window's 24-pixel margin, but inside only the back window.
        #expect(scan(f, rect: CGRect(x: 22, y: 20, width: 8, height: 6)).detections.first?.owner == 7)
    }
    @Test func aScannedFrameTakesTheNextScan() throws {
        // The scan of `a` misread its text (a window still fading in); the next scan found it.
        let changed = try buffer(); change(changed, plane: 0, x: 8, y: 16)
        let a = try frame(1, 0, buffer: changed), b = try frame(2, 0.25)
        let plan = PrivacyTimeline.plan(for: a, scans: [scan(a, rect: nil), scan(b, rect: secret.offsetBy(dx: 0, dy: 8))])
        #expect(covers(plan.boxes + plan.uncertainRows, secret.offsetBy(dx: 0, dy: 8)))
        // A scanned frame was read: a late next scan does not guard its changes.
        let late = PrivacyTimeline.plan(for: a, scans: [scan(a, rect: nil), scan(try frame(2, 3), rect: nil)])
        #expect(late.uncertainRows.isEmpty)
    }
    @Test func idlePreviewGuardsChangesOnlyOnceItsNewestScanPassesTheDeadline() throws {
        let timeline = PrivacyTimeline(), a = try frame(1, 0)
        #expect(timeline.preview(frame: a, now: 0).waiting)
        timeline.complete(scan(a, rect: secret.offsetBy(dx: 0, dy: 8)))
        let changed = try buffer(); change(changed, plane: 0, x: 40, y: 40)
        let later = try frame(2, 0.3, buffer: changed)
        // Within the deadline a benign change stays visible: the next scan is about to read it.
        let healthy = timeline.preview(frame: later, now: 0.45)
        #expect(healthy.guards.isEmpty && healthy.uncertainRows.isEmpty)
        #expect(covers(healthy.boxes, secret.offsetBy(dx: 0, dy: 8)))
        // The same frame and evidence once scans have failed past the deadline: the change is guarded.
        let stale = timeline.preview(frame: later, now: 0.55)
        #expect(stale.guards == [CGRect(x: 32, y: 32, width: 16, height: 16)])
        #expect(covers(stale.boxes, secret.offsetBy(dx: 0, dy: 8)))
        // A scanned frame was read however old it is, and a successful scan ends the guard.
        #expect(timeline.preview(frame: a, now: 9).guards.isEmpty)
        timeline.complete(scan(later, rect: nil))
        #expect(timeline.preview(frame: later, now: 9).guards.isEmpty)
    }
    @Test func missingOrOverWideEvidenceGuardsWhatNoScanRead() throws {
        // Scans at 0 and 0.8 read nothing; those between failed while a secret showed at 0.4.
        let shown = try buffer(); change(shown, plane: 0, x: 8, y: 20)
        let tile = [CGRect(x: 0, y: 16, width: 16, height: 16)]
        let a = try frame(1, 0), f = try frame(2, 0.4, buffer: shown), b = try frame(3, 0.8)
        let wide = PrivacyTimeline.plan(for: f, scans: [scan(a, rect: nil), scan(b, rect: nil)])
        #expect(wide.guards == tile && wide.degraded)
        // At normal spacing, a change neither scan saw is the documented short-flash limit, not a guard.
        #expect(PrivacyTimeline.plan(for: f, scans: [scan(a, rect: nil), scan(try frame(3, PrivacyTimeline.maxScanGap), rect: nil)]).guards.isEmpty)
        // No later scan in time (a backlog, stop's tail): changes since the earlier one are guarded.
        #expect(PrivacyTimeline.plan(for: f, scans: [scan(a, rect: nil)]).guards == tile)
        // Nothing earlier: frames ahead of the first scan are guarded against it.
        #expect(PrivacyTimeline.plan(for: f, scans: [scan(b, rect: nil)]).guards == tile)
        // Pixels equal to the later scan's were read by it.
        #expect(PrivacyTimeline.plan(for: f, scans: [scan(a, rect: nil), scan(try frame(3, 0.8, buffer: shown), rect: nil)]).guards.isEmpty)
    }
    @Test func aSensitiveWindowLeavingTheListGuardsWhatChangedAnywhere() throws {
        // A scan found a secret in window 7. The window then moved far right and left the list while its
        // last pixels still show there; the next scan, at normal spacing, sees it gone.
        let moved = try buffer(); change(moved, plane: 0, x: 56, y: 20)
        let a = try frame(1, 0), b = try frame(3, 0.25, present: false)
        let found = scan(a, rect: secret.offsetBy(dx: 0, dy: 8))
        let gone = PrivacyTimeline.plan(for: try frame(2, 0.1, present: false, buffer: moved), scans: [found, scan(b, rect: nil)])
        #expect(gone.guards.contains { $0.contains(CGPoint(x: 56, y: 20)) })
        // Still listed in this frame but gone from the later scan's list (snapshots skew around a close).
        let listed = PrivacyTimeline.plan(for: try frame(2, 0.1, buffer: moved), scans: [found, scan(b, rect: nil)])
        #expect(listed.guards.contains { $0.contains(CGPoint(x: 56, y: 20)) })
        // A missing list proves nothing, and a window with nothing found may come and go.
        let unlisted = try frame(2, 0.1, snapshot: false, buffer: moved)
        #expect(PrivacyTimeline.plan(for: unlisted, scans: [found, scan(try frame(3, 0.25), rect: nil)]).guards.isEmpty)
        #expect(PrivacyTimeline.plan(for: try frame(2, 0.1, present: false, buffer: moved), scans: [scan(a, rect: nil), scan(b, rect: nil)]).guards.isEmpty)
    }
    @Test func windowListedLateKeepsALaterScanAtItsScannedPosition() throws {
        let before = try frame(1, 0, present: false), f = try frame(2, 0.1, present: false)
        let after = try frame(3, 0.2, x: 8)
        let plan = PrivacyTimeline.plan(for: f, scans: [scan(before, rect: nil), scan(after, rect: secret.offsetBy(dx: 8, dy: 8))])
        #expect(covers(plan.boxes, secret.offsetBy(dx: 8, dy: 8)))
        // Pixels matching either bracketing scan were scanned: no guard.
        #expect(plan.uncertainRows.isEmpty)
    }
    @Test func windowSourceNeverTranslates() throws {
        let a = try frame(1, 0, windows: false), b = try frame(2, 0.1, x: 20, windows: false)
        let detection = scan(a, rect: secret)
        #expect(detection.detections.first?.owner == nil)
        #expect(PrivacyTimeline.plan(for: b, scans: [detection]).boxes == [secret])
    }
    @Test func exactLumaChromaAndRegionClipping() throws {
        let a = try buffer(), luma = try buffer(), chroma = try buffer()
        #expect(changedTiles(a, luma, in: CGRect(origin: .zero, size: size)).isEmpty)
        change(luma, plane: 0, x: 17, y: 3)
        #expect(changedTiles(a, luma, in: CGRect(origin: .zero, size: size)) == [CGRect(x: 16, y: 0, width: 16, height: 16)])
        change(chroma, plane: 1, x: 34, y: 17)
        #expect(changedTiles(a, chroma, in: CGRect(origin: .zero, size: size)) == [CGRect(x: 32, y: 32, width: 16, height: 16)])
        #expect(changedTiles(a, luma, in: CGRect(x: 17, y: 3, width: 2, height: 2)) == [CGRect(x: 17, y: 3, width: 2, height: 2)])
        #expect(changedTiles(a, luma, in: CGRect(x: 0, y: 0, width: 16, height: 16)).isEmpty)
        #expect(changedTiles(a, chroma, in: CGRect(x: -10, y: -10, width: 8, height: 8)).isEmpty)
    }
    @Test func historySelectsByCaptureTimeAndRejectsOldEpochResults() throws {
        let timeline = PrivacyTimeline(), a = try frame(1, 0), b = try frame(2, 0.2)
        timeline.record(a); timeline.record(b)
        timeline.complete(scan(a, rect: secret.offsetBy(dx: 0, dy: 8)))
        #expect(timeline.select(at: 0.1).frame?.sequence == 1)
        #expect(timeline.select(at: 0.2).frame?.sequence == 2)
        let epoch = timeline.reset()
        timeline.complete(scan(a, rect: secret))
        let fresh = try frame(3, 0.3, epoch: epoch)
        timeline.record(fresh)
        #expect(timeline.select(at: 0.3).frame == nil)
    }
    @Test func poolGapWaitsAndStaticScannedFrameKeepsItsMask() throws {
        let timeline = PrivacyTimeline(), a = try frame(1, 0)
        timeline.record(a); timeline.complete(scan(a, rect: secret.offsetBy(dx: 0, dy: 8)))
        #expect(!timeline.select(at: 10).plan.boxes.isEmpty)
        timeline.recordGap(at: 11, epoch: 0)
        let gap = timeline.select(at: 11)
        #expect(gap.plan.waiting)
        #expect(gap.frame == nil)
    }
    @Test func delayedCameraFollowsCaptureTimeWhilePreviewStaysLive() throws {
        var c = StudioConfiguration(); c.privacyShieldEnabled = true; c.cameraEnabled = true
        let inputs = RenderInputs(historyEnabled: true); inputs.configure(c)
        let early = try buffer(), late = try buffer()
        change(late, plane: 0, x: 1, y: 1)
        inputs.setCamera(early, captured: 10)
        inputs.setCamera(late, captured: 10.2)
        func marked(_ value: CVPixelBuffer?) throws -> Bool {
            let value = try #require(value)
            CVPixelBufferLockBaseAddress(value, .readOnly); defer { CVPixelBufferUnlockBaseAddress(value, .readOnly) }
            return CVPixelBufferGetBaseAddressOfPlane(value, 0)!.assumingMemoryBound(to: UInt8.self)[CVPixelBufferGetBytesPerRowOfPlane(value, 0) + 1] == 1
        }
        #expect(inputs.snapshot(contentTime: 9.9).camera == nil)
        #expect(try !marked(inputs.snapshot(contentTime: 10.1).camera))
        #expect(try marked(inputs.snapshot(contentTime: 10.25).camera))
        #expect(inputs.snapshot().camera === late)
        c.cameraEnabled = false; inputs.configure(c)
        #expect(inputs.snapshot(contentTime: 10.3).camera == nil)
    }
    @Test func idlePreviewNeverShowsAScreenItsPlanDoesNotDescribe() throws {
        var c = StudioConfiguration(); c.privacyShieldEnabled = true
        let inputs = RenderInputs(); inputs.configure(c)
        let screen = try buffer()
        inputs.setScreen(screen)
        #expect(inputs.snapshot().screen == nil)
        // A geometry reset drops scan evidence; a callback of the old size is not a new-epoch frame.
        let geometry = CaptureGeometry(size: CGSize(width: 128, height: 128), globalRect: .zero, tracksWindows: false)
        inputs.setCaptureGeometry(geometry)
        #expect(inputs.snapshot().screen == nil)
        inputs.setScreen(try buffer())
        #expect(inputs.snapshot().screen == nil)
    }
}
