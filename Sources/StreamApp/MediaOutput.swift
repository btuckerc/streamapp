import Foundation
import AVFoundation
import CoreMedia
import Darwin

@MainActor
final class MediaOutput {
    private let mixer = AudioMixer()
    private let state = OutputState()
    private var process: Process?
    private var videoHandle: FileHandle?
    private var audioHandle: FileHandle?
    private var progressPipe: Pipe?
    private var diagnosticPipe: Pipe?
    private var progressReader: Task<Void, Never>?
    private var diagnosticReader: Task<Void, Never>?
    private var directory: URL?
    private var writer: Task<Void, Never>?
    private var previewWriter: Task<Void, Never>?
    private var microphone: MicrophoneCapture?
    private var microphoneID: String?
    private var synthetic = false
    private var active = false
    private var previewActive = false
    private var stopping = false
    private var privacyDelaySamples = 0
    private(set) var recordingURL: URL?
    var videoFD: Int32 { videoHandle?.fileDescriptor ?? -1 }
    var levels: AudioMixer.Levels { mixer.levels }
    var status: String { state.status }
    var errorMessage: String? { state.error }
    /// Media time FFmpeg has muxed; survives `stop` until the next start.
    var mediaSeconds: Double { state.snapshot().mediaSeconds }
    var microphoneStatus: String? { state.microphoneStatus }
    var resolvedMicrophoneID: String? { state.resolvedMicrophoneID }
    var echoReferenceCaptureFailure: String?
    var echoCancellationStatus: String? {
        guard let status = mixer.echoCancellationStatus else { return nil }
        return echoReferenceCaptureFailure ?? status
    }
    struct Health: Sendable {
        let frames: Int64
        let mediaSeconds: Double
        let recordingBytes: Int64
        let progressing: Bool
        let summary: String
    }
    private var startedAt = ProcessInfo.processInfo.systemUptime
    /// When the first video tick was scheduled; the session timer counts from here because
    /// FFmpeg's `out_time` trails the wall clock by its mux queue and 1 s report period.
    private var clockStartedAt: TimeInterval?
    private var streamLabel: String?
    private var nextDiskSample = 0.0
    private var diskWarning: String?
    var health: Health {
        let snapshot = state.snapshot()
        if let url = recordingURL, snapshot.shouldSampleBytes {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            state.setRecordingBytes(bytes)
        }
        let current = state.snapshot()
        let now = Date().timeIntervalSinceReferenceDate
        let hasOutput = current.frames > 0 || current.mediaSeconds > 0
        let progressing = active && current.failure == nil && hasOutput && now - current.lastProgress <= 3
        let summary: String
        if !active { summary = current.failure == nil ? "Idle" : current.failure! }
        else if let failure = current.failure { summary = failure }
        else if !hasOutput {
            summary = ProcessInfo.processInfo.systemUptime - startedAt > 10
                ? "Output stalled · no media progress"
                : "Starting output…"
        } else if progressing {
            let elapsed = clockStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? current.mediaSeconds
            let delivery = streamLabel.map {
                StreamDelivery(label: $0, phase: .init(retry: current.streamRetry, stalled: current.streamStalled,
                                                       secondsSinceDrop: current.lastQueueFull.map { ProcessInfo.processInfo.systemUptime - $0 },
                                                       recovered: current.streamRecovered, muxedSeconds: current.mediaSeconds),
                               reconnected: current.streamRecovered)
            }
            summary = Self.sessionSummary(seconds: elapsed, recordingBytes: recordingURL == nil ? nil : current.recordingBytes,
                                          stream: delivery) + (sampleDiskWarning(current).map { "\n" + $0 } ?? "")
        } else {
            summary = "Output stalled · \(Self.clock(current.mediaSeconds)) · \(ByteCountFormatter.string(fromByteCount: current.recordingBytes, countStyle: .file))"
        }
        return Health(frames: current.frames, mediaSeconds: current.mediaSeconds,
                      recordingBytes: current.recordingBytes, progressing: progressing, summary: summary)
    }
    /// The stream's fifo queue holds 120 packets. Audio alone is about 47 packets/s, so once
    /// FFmpeg has muxed this much media the fifo has either sent packets or logged
    /// `FIFO queue full`; before that, delivery is unknown.
    nonisolated static let connectEvidenceSeconds = 3.0
    /// A full queue that later flushed dropped up to 120 packets; say so for this long.
    nonisolated static let dropMemorySeconds = 10.0
    struct StreamDelivery: Equatable, Sendable {
        enum Phase: Equatable, Sendable {
            /// Too little media muxed to know whether the server is taking data.
            case connecting
            /// The fifo is draining and FFmpeg reports no error.
            case sending
            /// The fifo filled recently and dropped its queue; the connection is too slow.
            case dropping
            /// The queue is full and no write has returned since.
            case stalled
            /// FFmpeg's reason while the connection is being retried.
            case retrying(String)

            /// A retry outranks everything; a slow first handshake is still `connecting`;
            /// a reconnect is evidence enough to skip `connecting`.
            init(retry: String?, stalled: Bool, secondsSinceDrop: Double?, recovered: Bool, muxedSeconds: Double) {
                if let retry { self = .retrying(retry) }
                else if muxedSeconds < MediaOutput.connectEvidenceSeconds && !recovered { self = .connecting }
                else if stalled { self = .stalled }
                else if let drop = secondsSinceDrop, drop < MediaOutput.dropMemorySeconds { self = .dropping }
                else { self = .sending }
            }
        }
        /// "Streaming", or "Bandwidth test" for Twitch test mode.
        let label: String
        let phase: Phase
        let reconnected: Bool
    }
    /// One line per output.
    nonisolated static func sessionSummary(seconds: Double, recordingBytes: Int64?, stream: StreamDelivery?) -> String {
        var lines: [String] = []
        if let recordingBytes {
            lines.append("Recording · \(clock(seconds)) · \(ByteCountFormatter.string(fromByteCount: recordingBytes, countStyle: .file))")
        }
        if let stream {
            let continues = recordingBytes == nil ? "" : " · recording continues"
            switch stream.phase {
            case .connecting: lines.append("Stream connecting…")
            case .stalled: lines.append("Stream stalled · connection not taking data" + continues)
            case .dropping: lines.append("Stream dropping data · connection too slow" + continues)
            case .retrying(let reason): lines.append("Stream reconnecting · \(reason)" + continues)
            case .sending:
                lines.append(stream.label + (recordingBytes == nil ? " · \(clock(seconds))" : "") + (stream.reconnected ? " · reconnected" : ""))
            }
        }
        return lines.joined(separator: "\n")
    }
    /// Checks free space every 10 s while recording; nil while there is room for ten minutes.
    private func sampleDiskWarning(_ current: OutputState.Snapshot) -> String? {
        guard let url = recordingURL else { return nil }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime >= nextDiskSample else { return diskWarning }
        nextDiskSample = uptime + 10
        // A fresh URL each sample: URL caches resource values per instance.
        let folder = URL(fileURLWithPath: url.deletingLastPathComponent().path, isDirectory: true)
        guard let available = Self.availableCapacity(of: folder, needed: Self.lowSpaceBytes), available < Self.lowSpaceBytes else { diskWarning = nil; return nil }
        let rate = current.mediaSeconds >= 10 && current.recordingBytes > 0
            ? max(1, Double(current.recordingBytes) / current.mediaSeconds) : Double(Self.recordingBytesPerSecond)
        diskWarning = "Disk almost full · about \(max(0, Int(Double(available) / rate / 60))) min left"
        return diskWarning
    }
    nonisolated static func microphoneDevices() -> [DeviceOption] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { device in AudioInputRoutes.option(device) }
    }
    func startPreview(configuration: StudioConfiguration, synthetic: Bool = false) async throws {
        guard !active, !previewActive else { throw OutputError.message("Audio preview is already running") }
        guard synthetic || !configuration.microphoneEnabled || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw OutputError.message("Microphone access is not authorized")
        }
        self.synthetic = synthetic; previewActive = true
        mixer.reset(configuration: configuration, synthetic: synthetic)
        state.reset()
        do {
            if !synthetic && configuration.microphoneEnabled { try await enableMicrophone(configuration.microphoneID) }
        } catch { previewActive = false; throw error }
    }

    func startPreviewClock(configuration: StudioConfiguration) {
        guard previewActive, previewWriter == nil else { return }
        mixer.reset(configuration: configuration, synthetic: synthetic)
        let mixer = self.mixer
        let playout = Int64(AudioSync.playoutMilliseconds(configuration))
        let start = ContinuousClock.now
        previewWriter = Task.detached(priority: .userInitiated) {
            var samples = [Float](repeating: 0, count: 1920)
            var block: Int64 = 0
            do {
                while !Task.isCancelled {
                    try await Task.sleep(until: start.advanced(by: .milliseconds(playout + block * 20)), clock: .continuous)
                    samples.withUnsafeMutableBufferPointer { mixer.pull(into: $0) }
                    block += 1
                }
            } catch { }
        }
    }

    func configurePreview(_ configuration: StudioConfiguration) {
        mixer.configure(configuration)
    }

    func stopPreview() async {
        guard previewActive || previewWriter != nil else { return }
        previewActive = false
        previewWriter?.cancel(); await previewWriter?.value; previewWriter = nil
        if let microphone { await microphone.stop(); self.microphone = nil }
        mixer.reset(configuration: StudioConfiguration(), synthetic: false)
    }


    func start(configuration: StudioConfiguration, streamKey: String, synthetic: Bool = false) async throws {
        guard !active else { throw OutputError.message("Output is already running") }
        guard configuration.recordingEnabled || configuration.streamingEnabled else { throw OutputError.message("Enable recording or streaming first") }
        var target: String?
        if configuration.streamingEnabled {
            target = try Self.makeStreamTarget(configuration: configuration, streamKey: streamKey)
        }
        self.synthetic = synthetic; active = true; stopping = false; recordingURL = nil
        startedAt = ProcessInfo.processInfo.systemUptime
        streamLabel = configuration.streamingEnabled ? (configuration.twitchTestMode ? "Bandwidth test" : "Streaming") : nil
        nextDiskSample = 0; diskWarning = nil; clockStartedAt = nil
        privacyDelaySamples = configuration.privacyShieldEnabled ? Int(PrivacyTimeline.delay * 48_000) * 2 : 0
        state.reset(); mixer.reset(configuration: configuration, synthetic: synthetic)
        do {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("StreamApp-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            directory = temp
            let video = temp.appendingPathComponent("video.flv"); let audio = temp.appendingPathComponent("audio.f32")
            for url in [video, audio] { guard mkfifo(url.path, 0o600) == 0 else { throw OutputError.message("Cannot create media transport") } }
            videoHandle = try openTransport(video); audioHandle = try openTransport(audio)
            let executable = ProcessInfo.processInfo.environment["STREAMAPP_FFMPEG_PATH"] ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ffmpeg").path
            guard FileManager.default.isExecutableFile(atPath: executable) else { throw OutputError.message("Bundled FFmpeg is missing. Rebuild StreamApp.app.") }
            if configuration.recordingEnabled {
                let folder = URL(fileURLWithPath: configuration.recordingDirectory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if let available = Self.availableCapacity(of: folder, needed: Self.minimumFreeBytes), available < Self.minimumFreeBytes {
                    throw OutputError.message("Not enough disk space to record (\(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) free). Free up space or choose another folder in Settings › Output.")
                }
                let url = Self.recordingURL(in: folder, format: configuration.recordingFormat, date: Date())
                recordingURL = url
            }
            let args = Self.ffmpegArguments(configuration: configuration, videoPath: video.path, audioPath: audio.path,
                                            recordingPath: recordingURL?.path, streamTarget: target)
            let child = Process(); child.executableURL = URL(fileURLWithPath: executable); child.arguments = args
            child.standardInput = FileHandle.nullDevice
            let progress = Pipe(); child.standardOutput = progress.fileHandleForWriting
            let errors = Pipe(); child.standardError = errors.fileHandleForWriting
            let state = self.state
            child.terminationHandler = { process in state.exited(process.terminationStatus) }
            try child.run(); process = child; progressPipe = progress; diagnosticPipe = errors
            try? progress.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
            progressReader = Task.detached(priority: .utility) {
                var pending = Data()
                    while !Task.isCancelled {
                        let data = progress.fileHandleForReading.availableData
                        guard !data.isEmpty else { break }
                        pending.append(data)
                        while let newline = pending.firstIndex(of: 10) {
                            state.observeProgress(String(decoding: pending[..<newline], as: UTF8.self))
                            pending.removeSubrange(...newline)
                        }
                        if pending.count > 16_384 { pending.removeAll(keepingCapacity: true) }
                    }
            }
            diagnosticReader = Task.detached(priority: .utility) {
                var pending = Data()
                    while !Task.isCancelled {
                        let data = errors.fileHandleForReading.availableData
                        guard !data.isEmpty else { break }
                        pending.append(data)
                        while let newline = pending.firstIndex(of: 10) {
                            state.observe(String(decoding: pending[..<newline], as: UTF8.self))
                            pending.removeSubrange(...newline)
                        }
                        if pending.count > 16_384 { pending.removeAll(keepingCapacity: true) }
                    }
            }
            if !synthetic && configuration.microphoneEnabled { try await enableMicrophone(configuration.microphoneID) }
            state.setStatus(configuration.outputSummary)
        } catch { await stop(); throw error }
    }

    /// Called once, immediately before the first video tick. Device warmup and
    func beginMediaClock(configuration: StudioConfiguration) -> Double {
        let epoch = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        clockStartedAt = ProcessInfo.processInfo.systemUptime
        mixer.reset(configuration: configuration, synthetic: synthetic, epoch: epoch)
        let fd = audioHandle!.fileDescriptor; let mixer = self.mixer; let state = self.state
        let start = ContinuousClock.now
        let delaySamples = privacyDelaySamples
        let playout = Int64(AudioSync.playoutMilliseconds(configuration))
        writer = Task.detached(priority: .userInitiated) {
            var samples = [Float](repeating: 0, count: 1920)
            var delayed = [Float](repeating: 0, count: delaySamples > 0 ? 1920 : 0)
            var ring = delaySamples > 0 ? PCMDelayRing(delaySamples: delaySamples, blockSamples: 1920) : nil
            var capturedFrames: Int64 = 0
            var emittedFrames: Int64 = 0
            var block: Int64 = 0
            do {
                while !Task.isCancelled {
                    try await Task.sleep(until: start.advanced(by: .milliseconds(playout + block * 20)), clock: .continuous)
                    let target = state.audioTarget
                    let captureCount = Int(min(960, max(0, (target ?? Int64.max) - capturedFrames))) * 2
                    if captureCount > 0 {
                        samples.withUnsafeMutableBufferPointer { mixer.pull(into: UnsafeMutableBufferPointer(rebasing: $0[..<captureCount])) }
                        capturedFrames += Int64(captureCount / 2)
                    }
                    let outputCount: Int
                    if delaySamples > 0 {
                        outputCount = samples.withUnsafeBufferPointer { input in
                            delayed.withUnsafeMutableBufferPointer { output in
                                if captureCount == 0 {
                                    // Short sessions must still honor wall-clock latency before draining.
                                    let due = Int(max(0, min(1920, (block + 1) * 1920 - Int64(delaySamples) - emittedFrames * 2)))
                                    return ring!.flush(into: UnsafeMutableBufferPointer(rebasing: output[..<due]))
                                }
                                return ring!.append(UnsafeBufferPointer(rebasing: input[..<captureCount]), output: output)
                            }
                        }
                        if outputCount > 0 {
                            try delayed.withUnsafeBytes { try Self.writePCM(UnsafeRawBufferPointer(rebasing: $0[..<(outputCount * MemoryLayout<Float>.size)]), to: fd) }
                        }
                    } else {
                        outputCount = captureCount
                        if outputCount > 0 {
                            try samples.withUnsafeBytes { try Self.writePCM(UnsafeRawBufferPointer(rebasing: $0[..<(outputCount * MemoryLayout<Float>.size)]), to: fd) }
                        }
                    }
                    emittedFrames += Int64(outputCount / 2)
                    block += 1
                    state.wroteAudio(frames: emittedFrames)
                    if let target, emittedFrames >= target || state.error != nil { return }
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { state.fail("Audio output stalled or closed. Session stopped to preserve synchronization.") } }
        }
        return epoch
    }

    func updateAudio(configuration: StudioConfiguration) async throws {
        guard active else { return }
        if !synthetic {
            if let microphone, !configuration.microphoneEnabled || microphoneID != configuration.microphoneID {
                await microphone.stop(); self.microphone = nil; microphoneID = nil
            }
            // Invalidate queued samples before opening a different device.
            mixer.configure(configuration)
            if configuration.microphoneEnabled && microphone == nil { try await enableMicrophone(configuration.microphoneID) }
        }
        mixer.configure(configuration)
    }
    /// Program audio takes `newer`'s silence at once (see `AudioMixer.hide(as:)`).
    func hide(as newer: StudioConfiguration) {
        if active { mixer.hide(as: newer) }
    }
    nonisolated func appendSystemAudio(_ sample: CMSampleBuffer) {
        do { try mixer.append(sample, microphone: false) } catch { state.fail("System audio format or clock changed. Restart the session.") }
    }
    nonisolated func appendEchoReference(_ sample: CMSampleBuffer) {
        // Missing/invalid references are detected by the mixer's per-frame tags.
        try? mixer.appendReference(sample)
    }

    /// Freeze the PCM target as soon as the compositor knows its final tick count.
    nonisolated func prepareToStop(videoFrames: Int64) {
        state.setAudioTarget(videoFrames * 1600)
    }
    func stop(videoFrames: Int64? = nil) async {
        guard active, !stopping else { return }
        stopping = true; state.beginStop()
        if let videoFrames { prepareToStop(videoFrames: videoFrames) }
        // The writer's lookahead must collect the final advanced source interval
        // before closing the mic; it returns once it has written through the final video
        // timestamp (or the session failed). The bound also covers the privacy tail.
        if let videoFrames, let writer {
            let target = videoFrames * 1600 // 48k samples / 30 fps.
            let bound = Duration.milliseconds((privacyDelaySamples / 960 + 200) * 10)
            let deadline = Task { do { try await Task.sleep(for: bound) } catch { return }; writer.cancel() }
            await writer.value
            deadline.cancel()
            if state.audioFrames < target && state.error == nil { state.fail("Audio could not drain to the final video timestamp") }
        }
        if let microphone { await microphone.stop(); self.microphone = nil }
        writer?.cancel(); await writer?.value; writer = nil
        mixer.reset(configuration: StudioConfiguration(), synthetic: false)
        try? audioHandle?.close(); audioHandle = nil
        try? videoHandle?.close(); videoHandle = nil
        if let child = process {
            // FFmpeg finalizes the recording after both FIFOs close; its termination handler signals the exit.
            var exited = await state.waitForExit(timeout: .seconds(5))
            if !exited { child.interrupt(); exited = await state.waitForExit(timeout: .seconds(2)) }
            if !exited { child.terminate(); exited = await state.waitForExit(timeout: .milliseconds(200)) }
            if !exited { kill(child.processIdentifier, SIGKILL); state.fail("Output did not finalize before timeout") }
            else if child.terminationStatus != 0 { state.fail("Media output exited with code \(child.terminationStatus)") }
        }
        await progressReader?.value; progressReader = nil
        await diagnosticReader?.value; diagnosticReader = nil
        try? progressPipe?.fileHandleForReading.close(); progressPipe = nil
        try? diagnosticPipe?.fileHandleForReading.close(); diagnosticPipe = nil
        process = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil; active = false; stopping = false
        state.setStatus(state.error == nil ? "Idle" : "Failed")
    }

    private func enableMicrophone(_ id: String) async throws {
        let capture = MicrophoneCapture(mixer: mixer, state: state)
        try await capture.start(id: id)
        guard (active || previewActive), !stopping else { await capture.stop(); throw CancellationError() }
        microphone = capture
        microphoneID = id
    }
    private func openTransport(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw OutputError.message("Cannot open media transport") }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    /// Builds the transient RTMP target. Twitch bandwidth-test mode is only
    /// accepted for Twitch's documented ingest hostnames.
    static func makeStreamTarget(configuration: StudioConfiguration, streamKey: String) throws -> String {
        guard configuration.streamingEnabled else {
            if configuration.twitchTestMode { throw OutputError.message("Enable streaming before selecting Twitch bandwidth test.") }
            return ""
        }
        guard let url = URL(string: configuration.streamURL),
              ["rtmp", "rtmps"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, url.user == nil, url.password == nil,
              url.fragment == nil, url.query == nil else {
            throw OutputError.message("Use an RTMP/RTMPS server URL without embedded credentials or query. Put credentials in the key field.")
        }
        guard !streamKey.isEmpty, !streamKey.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" || $0 == "?" || $0 == "#" || $0 == "&" }) else {
            throw OutputError.message("Invalid stream key")
        }
        if configuration.twitchTestMode {
            let hostname = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard hostname == "ingest.global-contribute.live-video.net" || hostname == "live.twitch.tv" || hostname.hasSuffix(".contribute.live-video.net") else {
                throw OutputError.message("Twitch bandwidth test requires an official Twitch ingest URL (…contribute.live-video.net).")
            }
        }
        let base = configuration.streamURL + (configuration.streamURL.hasSuffix("/") ? "" : "/") + streamKey
        return configuration.twitchTestMode ? base + "?bandwidthtest=true" : base
    }
    /// Names follow macOS screenshots: local time, Finder-sortable, a counter only on collision.
    nonisolated static func recordingURL(in folder: URL, format: RecordingFormat, date: Date, timeZone: TimeZone = .current,
                                         exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "StreamApp \(formatter.string(from: date))"
        var url = folder.appendingPathComponent(base).appendingPathExtension(format.fileExtension)
        var counter = 2
        while exists(url.path) {
            url = folder.appendingPathComponent("\(base) \(counter)").appendingPathExtension(format.fileExtension)
            counter += 1
        }
        return url
    }
    /// 6 Mb/s video plus AAC up to 320 kb/s, rounded up.
    nonisolated static let recordingBytesPerSecond: Int64 = 800_000
    /// Starting needs two minutes of space; a running recording warns below ten.
    nonisolated static let minimumFreeBytes = recordingBytesPerSecond * 120
    nonisolated static let lowSpaceBytes = recordingBytesPerSecond * 600
    /// Free space for new files, or nil when the volume does not report it. The plain figure
    /// is immediate; the important-usage figure also counts purgeable space but takes about
    /// 17 ms on APFS, so it is read only when the plain figure is below `needed`.
    nonisolated static func availableCapacity(of folder: URL, needed: Int64) -> Int64? {
        let plain = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
        if let plain, plain >= needed { return plain }
        let important = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        // Some volumes report 0 for important usage; take the larger figure rather than refuse.
        return [important, plain].compactMap { $0 }.max()
    }
    /// `m:ss`, or `h:mm:ss` from one hour.
    nonisolated static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
    enum StreamEvent: Equatable, Sendable { case retrying(String), recovered, stalled, drained, destinationFailed }
    /// Delivery signals from FFmpeg's fifo muxer at `-loglevel info`. A dropped or refused
    /// connection logs `Recovery failed: <reason>` once per retry; a reconnect logs
    /// `Recovery successful`; a successful first connect logs nothing. A server that stops
    /// taking data fills the queue (`FIFO queue full`) until the blocked write returns
    /// (`FIFO queue flushed`). Only the reason after the colon is kept: `Error opening`
    /// lines carry the stream key.
    nonisolated static func streamEvent(_ line: String) -> StreamEvent? {
        if line.contains("Recovery successful") { return .recovered }
        if line.contains("FIFO queue full") { return .stalled }
        if line.contains("FIFO queue flushed") { return .drained }
        if let range = line.range(of: "Recovery failed: ") {
            let reason = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            switch reason {
            case "Connection refused": return .retrying("server refused the connection")
            case "End of file", "Broken pipe", "Connection reset by peer": return .retrying("server closed the connection")
            case "Input/output error": return .retrying("network error")
            case "Operation timed out", "Connection timed out": return .retrying("connection timed out")
            default: return .retrying(String(reason.prefix(60)).lowercased())
            }
        }
        if line.contains("All tee outputs failed") || line.contains("No space left on device") || line.contains("Permission denied") { return .destinationFailed }
        return nil
    }
    /// A tee slave cannot change encoded bitrate. Unequal rates share H.264,
    /// but map PCM twice and select the appropriate AAC stream for each slave.
    nonisolated static func ffmpegArguments(configuration: StudioConfiguration, videoPath: String, audioPath: String,
                                           recordingPath: String?, streamTarget: String?) -> [String] {
        let separateAudio = recordingPath != nil && streamTarget != nil && configuration.recordingAudioBitrateKbps != .standard
        let videoQueue = max(8, (AudioSync.playoutMilliseconds(configuration) * 30 + 999) / 1000 + 8)
        // Preserve the common zero-based video/PCM timeline through remuxing.
        // Wall-clock privacy staging never changes either stream's timestamps.
        var args = ["-hide_banner", "-nostdin", "-n", "-loglevel", "info", "-nostats", "-stats_period", "1", "-progress", "pipe:1", "-copyts",
                    "-thread_queue_size", "\(videoQueue)", "-probesize", "32768", "-analyzeduration", "0", "-f", "flv", "-i", videoPath,
                    "-thread_queue_size", "8", "-f", "f32le", "-ar", "48000", "-ac", "2", "-i", audioPath,
                    "-map", "0:v", "-map", "1:a"]
        if separateAudio { args += ["-map", "1:a"] }
        args += ["-c:v", "copy", "-c:a", "aac", "-b:a:0",
                 streamTarget == nil ? "\(configuration.recordingAudioBitrateKbps.rawValue)k" : "160k"]
        if separateAudio { args += ["-b:a:1", "\(configuration.recordingAudioBitrateKbps.rawValue)k"] }
        args += ["-flags:a", "+global_header", "-shortest"]
        var outputs: [String] = []
        if let recordingPath {
            let select = separateAudio ? ":select=\\'v:0,a:1\\'" : ""
            outputs.append("[\(configuration.recordingFormat.teeOptions)\(select)]" + teeEscape(recordingPath))
        }
        if let streamTarget {
            let tls = streamTarget.hasPrefix("rtmps://") ? ":format_opts=tls_verify=1\\\\:ca_file=/etc/ssl/cert.pem" : ""
            let select = separateAudio ? ":select=\\'v:0,a:0\\'" : ""
            outputs.append("[f=fifo:onfail=ignore:fifo_format=flv:queue_size=120:drop_pkts_on_overflow=1:attempt_recovery=1:recover_any_error=1:recovery_wait_time=1:restart_with_keyframe=1\(tls)\(select)]" + teeEscape(streamTarget))
        }
        return args + ["-f", "tee", outputs.joined(separator: "|")]
    }
    nonisolated private static func teeEscape(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "|", with: "\\|") }
    nonisolated private static func writePCM(_ bytes: UnsafeRawBufferPointer, to fd: Int32) throws {
        var written = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while written < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
            if count > 0 { written += count; continue }
            if count < 0 && errno == EINTR { continue }
            guard count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK), ContinuousClock.now < deadline else { throw OutputError.message("PCM write failed") }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            _ = poll(&descriptor, 1, 20)
        }
    }
}

private final class OutputState: @unchecked Sendable {
    struct Snapshot {
        let frames: Int64
        let mediaSeconds: Double
        let recordingBytes: Int64
        let lastProgress: TimeInterval
        let failure: String?
        let shouldSampleBytes: Bool
        let streamRetry: String?
        let streamStalled: Bool
        /// System uptime of the last `FIFO queue full`.
        let lastQueueFull: TimeInterval?
        let streamRecovered: Bool
    }
    private let lock = NSLock()
    private var message = "Idle"
    private var failure: String?
    private var microphoneWarning: String?
    var microphoneStatus: String? { lock.lock(); defer { lock.unlock() }; return microphoneWarning }
    func setMicrophoneStatus(_ value: String?) { lock.lock(); microphoneWarning = value; lock.unlock() }
    private var inputID: String?
    var resolvedMicrophoneID: String? { lock.lock(); defer { lock.unlock() }; return inputID }
    func setMicrophoneID(_ value: String?) { lock.lock(); inputID = value; lock.unlock() }
    private var stopping = false
    private var writtenAudioFrames: Int64 = 0
    private var targetAudioFrames: Int64?
    var audioTarget: Int64? { lock.lock(); defer { lock.unlock() }; return targetAudioFrames }
    func setAudioTarget(_ frames: Int64) { lock.lock(); targetAudioFrames = frames; lock.unlock() }
    private var frames: Int64 = 0
    private var mediaSeconds = 0.0
    private var lastProgress = 0.0
    private var recordingBytes: Int64 = 0
    private var nextByteSample = 0.0
    private var streamRetry: String?
    private var streamStalled = false
    private var lastQueueFull: TimeInterval?
    private var streamRecovered = false
    var audioFrames: Int64 { lock.lock(); defer { lock.unlock() }; return writtenAudioFrames }
    func wroteAudio(frames: Int64) { lock.lock(); writtenAudioFrames = frames; lock.unlock() }
    var status: String { lock.lock(); defer { lock.unlock() }; return message }
    var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSinceReferenceDate
        let sample = now >= nextByteSample
        if sample { nextByteSample = now + 1 }
        return Snapshot(frames: frames, mediaSeconds: mediaSeconds, recordingBytes: recordingBytes,
                        lastProgress: lastProgress, failure: failure, shouldSampleBytes: sample,
                        streamRetry: streamRetry, streamStalled: streamStalled, lastQueueFull: lastQueueFull, streamRecovered: streamRecovered)
    }
    func setRecordingBytes(_ value: Int64) { lock.lock(); recordingBytes = max(0, value); lock.unlock() }
    func reset() {
        lock.lock(); message = "Starting"; failure = nil; stopping = false; writtenAudioFrames = 0
        targetAudioFrames = nil
        microphoneWarning = nil
        processExited = false; streamRetry = nil; streamStalled = false; lastQueueFull = nil; streamRecovered = false
        frames = 0; mediaSeconds = 0; lastProgress = 0; recordingBytes = 0; nextByteSample = 0; lock.unlock()
    }
    func beginStop() { lock.lock(); stopping = true; lock.unlock() }
    func setStatus(_ value: String) { lock.lock(); message = value; lock.unlock() }
    func fail(_ value: String) { lock.lock(); if failure == nil { failure = value }; lock.unlock() }
    private var processExited = false
    private var exitWaiter: CheckedContinuation<Bool, Never>?
    func exited(_ code: Int32) {
        lock.lock()
        if !stopping { failure = "Media output exited unexpectedly (\(code))" }
        processExited = true
        let waiter = exitWaiter; exitWaiter = nil
        lock.unlock()
        waiter?.resume(returning: true)
    }
    /// True once FFmpeg has exited; false after `timeout`. One waiter at a time.
    func waitForExit(timeout: Duration) async -> Bool {
        var timer: Task<Void, Never>?
        let exited = await withCheckedContinuation { continuation in
            lock.lock()
            if processExited { lock.unlock(); continuation.resume(returning: true); return }
            exitWaiter = continuation
            lock.unlock()
            // Armed after the waiter is installed, so expiry can never miss it.
            timer = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                self?.expireExitWaiter()
            }
        }
        timer?.cancel()
        return exited
    }
    private func expireExitWaiter() {
        lock.lock(); let waiter = exitWaiter; exitWaiter = nil; lock.unlock()
        waiter?.resume(returning: false)
    }
    func observe(_ line: String) {
        switch MediaOutput.streamEvent(line) {
        case .retrying(let reason)?: lock.lock(); streamRetry = reason; lock.unlock()
        case .recovered?: lock.lock(); streamRetry = nil; streamStalled = false; streamRecovered = true; lock.unlock()
        case .stalled?: let now = ProcessInfo.processInfo.systemUptime; lock.lock(); streamStalled = true; lastQueueFull = now; lock.unlock()
        case .drained?: lock.lock(); streamStalled = false; lock.unlock()
        case .destinationFailed?: fail("Media destination failed. Check storage space and output permissions.")
        case nil: break
        }
    }
    func observeProgress(_ line: String) {
        guard let split = line.firstIndex(of: "=") else { return }
        let key = String(line[..<split]); let value = String(line[line.index(after: split)...])
        lock.lock(); defer { lock.unlock() }
        var advanced = false
        if key == "frame", let value = Int64(value), value >= frames { advanced = value > frames; frames = value }
        else if key == "out_time_us", let value = Int64(value), value >= 0 {
            let seconds = Double(value) / 1_000_000; advanced = seconds > mediaSeconds; mediaSeconds = max(mediaSeconds, seconds)
        } else if key == "out_time_ms", let value = Int64(value), value >= 0 {
            let seconds = Double(value) / 1_000_000; advanced = seconds > mediaSeconds; mediaSeconds = max(mediaSeconds, seconds)
        }
        if advanced { lastProgress = Date().timeIntervalSinceReferenceDate }
    }
}

/// All capture/recovery state is owned by the existing sample queue. Recovery
/// never moves the mixer epoch or substitutes another device for the saved UID.
private final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let mixer: AudioMixer
    private let state: OutputState
    private let queue = DispatchQueue(label: "streamapp.microphone", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var observer: NSObjectProtocol?
    private var deviceObservers: [NSObjectProtocol] = []
    private var deviceID = ""
    private var stopped = true
    private var restartAttempted = false
    init(mixer: AudioMixer, state: OutputState) { self.mixer = mixer; self.state = state }

    private static func device(_ id: String) -> AVCaptureDevice? {
        if id.isEmpty { return AVCaptureDevice.default(for: .audio) }
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.first { $0.uniqueID == id } ?? AVCaptureDevice(uniqueID: id)
    }
    func start(id: String) async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw OutputError.message("Microphone access is not authorized") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard let device = Self.device(id) else { throw OutputError.message("Selected microphone is unavailable") }
                    self.deviceID = device.uniqueID; self.stopped = false; self.restartAttempted = false
                    try self.open(device)
                    for name in [AVCaptureDevice.wasDisconnectedNotification, AVCaptureDevice.wasConnectedNotification] {
                        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                            guard let id = (note.object as? AVCaptureDevice)?.uniqueID else { return }
                            let connected = note.name == AVCaptureDevice.wasConnectedNotification
                            self?.queue.async { [weak self] in self?.deviceChanged(id: id, connected: connected) }
                        }
                        self.deviceObservers.append(token)
                    }
                    continuation.resume()
                } catch { self.closeSession(); self.stopped = true; continuation.resume(throwing: error) }
            }
        }
    }
    private func open(_ device: AVCaptureDevice) throws {
        let session = AVCaptureSession(); session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw OutputError.message("Cannot open microphone") }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = nil // Select from native channels before conversion.
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw OutputError.message("Cannot configure microphone") }
        session.addOutput(output); session.commitConfiguration()
        self.session = session
        observer = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            guard let failed = note.object as? AVCaptureSession else { return }
            self?.queue.async { [weak self] in
                guard let self, self.session === failed else { return }
                self.runtimeError()
            }
        }
        session.startRunning()
        guard session.isRunning else { closeSession(); throw OutputError.message("Microphone failed to start") }
        state.setMicrophoneStatus(nil)
        state.setMicrophoneID(device.uniqueID)
    }
    private func closeSession() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        session?.stopRunning(); session = nil
        state.setMicrophoneID(nil)
    }
    private func suspend() {
        closeSession(); mixer.silenceMicrophone()
        state.setMicrophoneStatus("Microphone disconnected — reconnect to resume")
    }
    private func deviceChanged(id: String, connected: Bool) {
        guard !stopped, id == deviceID else { return }
        if !connected { suspend(); return }
        guard session == nil else { return }
        restartAttempted = false
        do {
            guard let device = Self.device(deviceID) else { return }
            try open(device)
        } catch { suspend() }
    }
    private func runtimeError() {
        guard !stopped else { return }
        suspend()
        guard !restartAttempted else { return }
        restartAttempted = true
        do {
            guard let device = Self.device(deviceID), device.isConnected else { return }
            try open(device)
        } catch { suspend() }
    }
    func stop() async {
        await withCheckedContinuation { continuation in queue.async {
            self.stopped = true
            self.closeSession()
            for token in self.deviceObservers { NotificationCenter.default.removeObserver(token) }
            self.deviceObservers.removeAll()
            self.state.setMicrophoneStatus(nil)
            continuation.resume()
        } }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // An old session's queued callback cannot inject audio after reconnect.
        guard !stopped, let session, session.outputs.contains(where: { $0 === output }) else { return }
        do {
            guard let clock = session.synchronizationClock else { throw OutputError.message("Microphone clock unavailable") }
            let hostTime = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                                            from: clock, to: CMClockGetHostTimeClock())
            try mixer.append(sampleBuffer, microphone: true, hostTimestamp: hostTime.seconds)
        } catch { runtimeError() }
    }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        for token in deviceObservers { NotificationCenter.default.removeObserver(token) }
    }
}

enum OutputError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
