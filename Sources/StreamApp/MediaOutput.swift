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
    private var synthetic = false
    private var active = false
    private var previewActive = false
    private var stopping = false
    private(set) var recordingURL: URL?
    var videoFD: Int32 { videoHandle?.fileDescriptor ?? -1 }
    var levels: (microphone: Float, system: Float, output: Float, gainReduction: Float) { mixer.levels }
    var status: String { state.status }
    var errorMessage: String? { state.error }
    struct Health: Sendable {
        let frames: Int64
        let mediaSeconds: Double
        let recordingBytes: Int64
        let progressing: Bool
        let summary: String
    }
    private var startedAt = ProcessInfo.processInfo.systemUptime
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
                : "Preparing output · no media progress yet"
        } else if progressing {
            let duration = String(format: "%.1fs", current.mediaSeconds)
            summary = recordingURL == nil
                ? "Broadcast processing · \(duration) · \(current.frames) frames · delivery not confirmed"
                : "Recording \(duration) · \(ByteCountFormatter.string(fromByteCount: current.recordingBytes, countStyle: .file)) written"
        } else {
            summary = "Output stalled · \(String(format: "%.1fs", current.mediaSeconds)) · \(current.recordingBytes) bytes"
        }
        return Health(frames: current.frames, mediaSeconds: current.mediaSeconds,
                      recordingBytes: current.recordingBytes, progressing: progressing, summary: summary)
    }
    nonisolated static func microphoneDevices() -> [DeviceOption] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { DeviceOption(id: $0.uniqueID, name: $0.localizedName) }
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
        let start = ContinuousClock.now
        previewWriter = Task.detached(priority: .userInitiated) {
            var samples = [Float](repeating: 0, count: 1920)
            var block: Int64 = 0
            do {
                while !Task.isCancelled {
                    try await Task.sleep(until: start.advanced(by: .milliseconds(100 + block * 20)), clock: .continuous)
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
            var args = ["-hide_banner", "-nostdin", "-n", "-loglevel", "info", "-nostats", "-stats_period", "1", "-progress", "pipe:1", "-probesize", "32768", "-analyzeduration", "0", "-f", "flv", "-i", video.path,
                        "-thread_queue_size", "8", "-f", "f32le", "-ar", "48000", "-ac", "2", "-i", audio.path,
                        "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", "-b:a", "160k", "-flags:a", "+global_header", "-shortest"]
            var outputs: [String] = []
            if configuration.recordingEnabled {
                let folder = URL(fileURLWithPath: configuration.recordingDirectory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let url = folder.appendingPathComponent("StreamApp-\(stamp)-\(UUID().uuidString.prefix(8)).mkv")
                guard !FileManager.default.fileExists(atPath: url.path) else { throw OutputError.message("Recording already exists") }
                recordingURL = url; outputs.append("[f=matroska]" + Self.teeEscape(url.path))
            }
            if let target {
                let tls = target.hasPrefix("rtmps://") ? ":format_opts=tls_verify=1\\\\:ca_file=/etc/ssl/cert.pem" : ""
                outputs.append("[f=fifo:onfail=ignore:fifo_format=flv:queue_size=120:drop_pkts_on_overflow=1:attempt_recovery=1:recover_any_error=1:recovery_wait_time=1:restart_with_keyframe=1\(tls)]" + Self.teeEscape(target))
            }
            args += ["-f", "tee", outputs.joined(separator: "|")]
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
        mixer.reset(configuration: configuration, synthetic: synthetic, epoch: epoch)
        let fd = audioHandle!.fileDescriptor; let mixer = self.mixer; let state = self.state
        let start = ContinuousClock.now
        writer = Task.detached(priority: .userInitiated) {
            var samples = [Float](repeating: 0, count: 1920)
            var block: Int64 = 0
            do {
                while !Task.isCancelled {
                    try await Task.sleep(until: start.advanced(by: .milliseconds(100 + block * 20)), clock: .continuous)
                    samples.withUnsafeMutableBufferPointer { mixer.pull(into: $0) }
                    try samples.withUnsafeBytes { try Self.writePCM($0, to: fd) }
                    block += 1
                    state.wroteAudio(frames: block * 960)
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { state.fail("Audio output stalled or closed. Session stopped to preserve synchronization.") } }
        }
        return epoch
    }

    func updateAudio(configuration: StudioConfiguration) async throws {
        guard active else { return }
        if !synthetic {
            if configuration.microphoneEnabled && microphone == nil { try await enableMicrophone(configuration.microphoneID) }
            else if !configuration.microphoneEnabled, let microphone { await microphone.stop(); self.microphone = nil }
        }
        mixer.configure(configuration)
    }
    nonisolated func appendSystemAudio(_ sample: CMSampleBuffer) {
        do { try mixer.append(sample, microphone: false) } catch { state.fail("System audio format or clock changed. Restart the session.") }
    }

    func stop(videoFrames: Int64? = nil) async {
        guard active, !stopping else { return }
        stopping = true; state.beginStop()
        if let microphone { await microphone.stop(); self.microphone = nil }
        if let videoFrames, writer != nil {
            let target = videoFrames * 1600 // 48k samples / 30 fps.
            for _ in 0..<100 {
                if state.audioFrames >= target || state.error != nil { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            if state.audioFrames < target && state.error == nil { state.fail("Audio could not drain to the final video timestamp") }
        }
        writer?.cancel(); await writer?.value; writer = nil
        try? audioHandle?.close(); audioHandle = nil
        try? videoHandle?.close(); videoHandle = nil
        if let child = process {
            for _ in 0..<100 { if !child.isRunning { break }; try? await Task.sleep(for: .milliseconds(50)) }
            if child.isRunning {
                child.interrupt()
                for _ in 0..<40 { if !child.isRunning { break }; try? await Task.sleep(for: .milliseconds(50)) }
            }
            if child.isRunning { child.terminate(); try? await Task.sleep(for: .milliseconds(200)) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL); state.fail("Output did not finalize before timeout") }
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
    private static func teeEscape(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "'\\''").replacingOccurrences(of: "|", with: "\\|") }
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
    }
    private let lock = NSLock()
    private var message = "Idle"
    private var failure: String?
    private var stopping = false
    private var writtenAudioFrames: Int64 = 0
    private var frames: Int64 = 0
    private var mediaSeconds = 0.0
    private var lastProgress = 0.0
    private var recordingBytes: Int64 = 0
    private var nextByteSample = 0.0
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
                        lastProgress: lastProgress, failure: failure, shouldSampleBytes: sample)
    }
    func setRecordingBytes(_ value: Int64) { lock.lock(); recordingBytes = max(0, value); lock.unlock() }
    func reset() {
        lock.lock(); message = "Starting"; failure = nil; stopping = false; writtenAudioFrames = 0
        frames = 0; mediaSeconds = 0; lastProgress = 0; recordingBytes = 0; nextByteSample = 0; lock.unlock()
    }
    func beginStop() { lock.lock(); stopping = true; lock.unlock() }
    func setStatus(_ value: String) { lock.lock(); message = value; lock.unlock() }
    func fail(_ value: String) { lock.lock(); if failure == nil { failure = value }; lock.unlock() }
    func exited(_ code: Int32) { lock.lock(); if !stopping { failure = "Media output exited unexpectedly (\(code))" }; lock.unlock() }
    func observe(_ line: String) {
        if line.contains("Recovery successful") { setStatus("RTMP recovered") }
        else if line.contains("Recovery failed") || line.contains("Connection refused") || line.contains("Broken pipe") { setStatus("Reconnecting RTMP…") }
        else if line.contains("All tee outputs failed") || line.contains("No space left on device") || line.contains("Permission denied") { fail("Media destination failed. Check storage space and output permissions.") }
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

private final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let mixer: AudioMixer
    private let state: OutputState
    private let queue = DispatchQueue(label: "streamapp.microphone", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var observer: NSObjectProtocol?
    private var disconnectionObserver: NSObjectProtocol?
    init(mixer: AudioMixer, state: OutputState) { self.mixer = mixer; self.state = state }
    func start(id: String) async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw OutputError.message("Microphone access is not authorized") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard let device = id.isEmpty ? AVCaptureDevice.default(for: .audio) : AVCaptureDevice(uniqueID: id) else { throw OutputError.message("Selected microphone is unavailable") }
                    let session = AVCaptureSession(); session.beginConfiguration()
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else { throw OutputError.message("Cannot open microphone") }; session.addInput(input)
                    let output = AVCaptureAudioDataOutput(); output.setSampleBufferDelegate(self, queue: self.queue)
                    guard session.canAddOutput(output) else { throw OutputError.message("Cannot configure microphone") }; session.addOutput(output)
                    session.commitConfiguration(); self.session = session
                    self.observer = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in self?.state.fail("Microphone stopped. Check the device and restart the session.") }
                    self.disconnectionObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in self?.state.fail("Microphone disconnected. Select a device and restart.") }
                    session.startRunning()
                    guard session.isRunning else { throw OutputError.message("Microphone failed to start") }
                    continuation.resume()
                } catch { self.session?.stopRunning(); self.session = nil; continuation.resume(throwing: error) }
            }
        }
    }
    func stop() async {
        await withCheckedContinuation { continuation in queue.async {
            self.session?.stopRunning(); self.session = nil
            if let observer = self.observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            if let observer = self.disconnectionObserver { NotificationCenter.default.removeObserver(observer); self.disconnectionObserver = nil }
            continuation.resume()
        } }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        do { try mixer.append(sampleBuffer, microphone: true) } catch { state.fail("Microphone format or clock changed. Restart the session.") }
    }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let disconnectionObserver { NotificationCenter.default.removeObserver(disconnectionObserver) }
    }
}

enum OutputError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
