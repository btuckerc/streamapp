import Foundation
import Testing
@testable import StreamApp

struct SessionOutputTests {
    @Test func clockUsesMinutesThenHours() {
        #expect(MediaOutput.clock(0) == "0:00")
        #expect(MediaOutput.clock(-3) == "0:00")
        #expect(MediaOutput.clock(59.99) == "0:59")
        #expect(MediaOutput.clock(61) == "1:01")
        #expect(MediaOutput.clock(3599.9) == "59:59")
        #expect(MediaOutput.clock(3600) == "1:00:00")
        #expect(MediaOutput.clock(36_125) == "10:02:05")
    }

    @Test func recordingNamesUseLocalTimeAndCountOnlyOnCollision() throws {
        let folder = URL(fileURLWithPath: "/tmp/Recordings", isDirectory: true)
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        // 2026-11-06 18:07:05 UTC is 13:07:05 in New York.
        let date = Date(timeIntervalSince1970: 1_793_988_425)
        let first = MediaOutput.recordingURL(in: folder, format: .mp4, date: date, timeZone: zone, exists: { _ in false })
        #expect(first.path == "/tmp/Recordings/StreamApp 2026-11-06 at 13.07.05.mp4")
        var taken: Set<String> = [first.path, "/tmp/Recordings/StreamApp 2026-11-06 at 13.07.05 2.mkv"]
        let second = MediaOutput.recordingURL(in: folder, format: .mp4, date: date, timeZone: zone, exists: { taken.contains($0) })
        #expect(second.lastPathComponent == "StreamApp 2026-11-06 at 13.07.05 2.mp4")
        taken.insert(second.path)
        let third = MediaOutput.recordingURL(in: folder, format: .mp4, date: date, timeZone: zone, exists: { taken.contains($0) })
        #expect(third.lastPathComponent == "StreamApp 2026-11-06 at 13.07.05 3.mp4")
        // Another container's file with the same stem does not collide.
        let mkv = MediaOutput.recordingURL(in: folder, format: .mkv, date: date, timeZone: zone, exists: { taken.contains($0) })
        #expect(mkv.lastPathComponent == "StreamApp 2026-11-06 at 13.07.05.mkv")
    }

    /// Fifo/tcp lines as captured from the bundled FFmpeg 9.0.2 at `-loglevel info`.
    @Test func streamEventsFollowFifoRecoveryLogs() {
        #expect(MediaOutput.streamEvent("[fifo @ 0x7899019180] Recovery failed: Connection refused") == .retrying("server refused the connection"))
        #expect(MediaOutput.streamEvent("[fifo @ 0x7657015180] Recovery failed: End of file") == .retrying("server closed the connection"))
        #expect(MediaOutput.streamEvent("[fifo @ 0x78e6c2d180] Recovery failed: Input/output error") == .retrying("network error"))
        #expect(MediaOutput.streamEvent("[fifo @ 0x7899019180] Recovery successful") == .recovered)
        #expect(MediaOutput.streamEvent("[fifo @ 0x7899019180] FIFO queue full") == .stalled)
        #expect(MediaOutput.streamEvent("[fifo @ 0x7899019180] FIFO queue flushed") == .drained)
        #expect(MediaOutput.streamEvent("[out#0/tee @ 0x1] Error writing trailer: No space left on device") == .destinationFailed)
        // Lines that carry the target URL (and so the stream key) never become status text.
        #expect(MediaOutput.streamEvent("[fifo @ 0x7899019180] Error opening rtmp://127.0.0.1:19351/live/secret-key: Connection refused") == nil)
        #expect(MediaOutput.streamEvent("[tcp @ 0x78e8005a00] Failed to resolve hostname nonexistent.invalid: nodename nor servname provided, or not known") == nil)
        #expect(MediaOutput.streamEvent("frame=830") == nil)
    }

    @Test func streamPhaseNeedsEvidenceBeforeClaimingDelivery() {
        typealias Phase = MediaOutput.StreamDelivery.Phase
        let enough = MediaOutput.connectEvidenceSeconds
        func phase(retry: String? = nil, stalled: Bool = false, sinceDrop: Double? = nil, recovered: Bool = false, muxed: Double) -> Phase {
            Phase(retry: retry, stalled: stalled, secondsSinceDrop: sinceDrop, recovered: recovered, muxedSeconds: muxed)
        }
        // Until the fifo must have sent or overflowed, nothing is claimed, even after a slow first handshake overflowed.
        #expect(phase(muxed: enough - 0.1) == .connecting)
        #expect(phase(stalled: true, sinceDrop: 0.5, muxed: 1) == .connecting)
        #expect(phase(muxed: enough) == .sending)
        #expect(phase(stalled: true, sinceDrop: 20, muxed: 30) == .stalled)
        // A queue that filled and flushed keeps reporting drops for a while, then clears.
        #expect(phase(sinceDrop: MediaOutput.dropMemorySeconds - 1, muxed: 30) == .dropping)
        #expect(phase(sinceDrop: MediaOutput.dropMemorySeconds, muxed: 30) == .sending)
        #expect(phase(retry: "network error", stalled: true, sinceDrop: 1, muxed: 1) == .retrying("network error"))
        #expect(phase(recovered: true, muxed: 1) == .sending)
    }

    @Test func sessionSummaryShowsEachOutput() {
        let size = ByteCountFormatter.string(fromByteCount: 4_500_000, countStyle: .file)
        let streaming = MediaOutput.StreamDelivery(label: "Streaming", phase: .sending, reconnected: false)
        let retrying = MediaOutput.StreamDelivery(label: "Streaming", phase: .retrying("server refused the connection"), reconnected: false)
        let reconnected = MediaOutput.StreamDelivery(label: "Streaming", phase: .sending, reconnected: true)
        #expect(MediaOutput.sessionSummary(seconds: 83.4, recordingBytes: 4_500_000, stream: nil) == "Recording · 1:23 · \(size)")
        #expect(MediaOutput.sessionSummary(seconds: 83.4, recordingBytes: nil, stream: streaming) == "Streaming · 1:23")
        #expect(MediaOutput.sessionSummary(seconds: 83.4, recordingBytes: nil, stream: retrying) == "Stream reconnecting · server refused the connection")
        #expect(MediaOutput.sessionSummary(seconds: 83.4, recordingBytes: 4_500_000, stream: retrying)
                == "Recording · 1:23 · \(size)\nStream reconnecting · server refused the connection · recording continues")
        #expect(MediaOutput.sessionSummary(seconds: 83.4, recordingBytes: 4_500_000, stream: reconnected)
                == "Recording · 1:23 · \(size)\nStreaming · reconnected")
        let stalled = MediaOutput.StreamDelivery(label: "Streaming", phase: .stalled, reconnected: false)
        #expect(MediaOutput.sessionSummary(seconds: 83.4, recordingBytes: 4_500_000, stream: stalled)
                == "Recording · 1:23 · \(size)\nStream stalled · connection not taking data · recording continues")
        let dropping = MediaOutput.StreamDelivery(label: "Streaming", phase: .dropping, reconnected: false)
        #expect(MediaOutput.sessionSummary(seconds: 83.4, recordingBytes: nil, stream: dropping) == "Stream dropping data · connection too slow")
        let connecting = MediaOutput.StreamDelivery(label: "Streaming", phase: .connecting, reconnected: false)
        #expect(MediaOutput.sessionSummary(seconds: 1, recordingBytes: nil, stream: connecting) == "Stream connecting…")
        let test = MediaOutput.StreamDelivery(label: "Bandwidth test", phase: .sending, reconnected: false)
        #expect(MediaOutput.sessionSummary(seconds: 5, recordingBytes: nil, stream: test) == "Bandwidth test · 0:05")
    }
}
