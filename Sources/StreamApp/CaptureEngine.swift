import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit

@MainActor
final class StudioEngine: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    let previewFrames = PreviewFrames()
    @Published private(set) var microphoneLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var outputLevel: Float = 0
    @Published private(set) var gainReduction: Float = 0
    @Published private(set) var meterPreviewActive = false
    @Published private(set) var meterPreviewError: String?
    @Published private(set) var videoPreviewMode: PreviewFrames.Mode?
    @Published private(set) var videoPreviewError: String?
    @Published private(set) var status = "Idle"
    @Published private(set) var outputHealth = "Idle"
    @Published private(set) var captureApplications: [DeviceOption] = []
    var annotationWindowID: CGWindowID?
    private var inputs: RenderInputs?
    private var bridge: CaptureBridge?
    private var renderer: FrameRenderer?
    private var output: MediaOutput?
    private var stream: SCStream?
    private var camera: CameraCapture?
    private var chat: Chat?
    private var monitor: Task<Void, Never>?
    private var previewMonitor: Task<Void, Never>?
    private var configuration = StudioConfiguration()
    private var synthetic = false
    private var starting = false
    private var stopping = false
    private var previewChat: Chat?
    private var previewRenderer: FrameRenderer?
    private var generation: UInt64 = 0
    private var previewOutput: MediaOutput?
    private var previewStream: SCStream?
    private var previewDesired = false
    private var previewGeneration: UInt64 = 0
    private var previewTransition: Task<Void, Never>?
    private var previewConfiguration = StudioConfiguration()
    private var previewSynthetic = false
    private var previewInputs: RenderInputs?
    private var previewCamera: CameraCapture?
    private var previewBridge: CaptureBridge?
    /// Visible-menu capture only: no encoder, recording, or streaming output.
    func setMenuPreview(visible: Bool, configuration: StudioConfiguration, synthetic: Bool = false) async {
        previewDesired = visible
        previewConfiguration = configuration
        previewSynthetic = synthetic
        if !visible { previewCamera?.cancelStart() }
        await reconcileMenuPreview()
    }

    func setVideoPreviewMode(_ mode: PreviewFrames.Mode?) async {
        guard videoPreviewMode != mode else { return }
        videoPreviewMode = mode
        previewFrames.request(mode)
        if mode == nil { previewCamera?.cancelStart() }
        if !isRunning { await reconcileMenuPreview() }
    }

    private func reconcileMenuPreview() async {
        previewGeneration &+= 1
        let token = previewGeneration
        let previous = previewTransition
        let task = Task { [self] in
            await previous?.value
            guard token == previewGeneration else { return }
            await stopMenuPreview()
            guard token == previewGeneration, previewDesired, !isRunning, !starting, !stopping else { return }
            meterPreviewError = nil
            videoPreviewError = nil
            let c = previewConfiguration
            let mode = videoPreviewMode
            let needsScreen = mode == .program && c.layout == .desktopChat
            let inputs = RenderInputs()
            inputs.configure(c)
            inputs.setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            previewInputs = inputs
            let meter = MediaOutput()
            previewOutput = meter
            do {
                try await meter.startPreview(configuration: c, synthetic: previewSynthetic)
                guard token == previewGeneration else { await stopMenuPreview(); return }
                if !previewSynthetic && (c.systemAudioEnabled || needsScreen) {
                    if CGPreflightScreenCaptureAccess() {
                        let filter = try await captureFilter(c)
                        guard token == previewGeneration else { await stopMenuPreview(); return }
                        let options = SCStreamConfiguration()
                        if needsScreen {
                            let rect = try captureRect(filter, configuration: c)
                            options.sourceRect = rect
                            let scale = min(1, min(1920 / max(1, rect.width * CGFloat(filter.pointPixelScale)), 1080 / max(1, rect.height * CGFloat(filter.pointPixelScale))))
                            options.width = max(2, Int(rect.width * CGFloat(filter.pointPixelScale) * scale))
                            options.height = max(2, Int(rect.height * CGFloat(filter.pointPixelScale) * scale))
                            options.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                            options.pixelFormat = kCVPixelFormatType_32BGRA
                            options.queueDepth = 3
                        } else {
                            options.width = 2; options.height = 2
                            options.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                        }
                        options.capturesAudio = c.systemAudioEnabled
                        options.excludesCurrentProcessAudio = true
                        options.sampleRate = 48_000; options.channelCount = 2
                        let bridge = CaptureBridge(inputs: inputs, output: meter)
                        let stream = SCStream(filter: filter, configuration: options, delegate: bridge)
                        previewBridge = bridge; previewStream = stream
                        if needsScreen { try stream.addStreamOutput(bridge, type: .screen, sampleHandlerQueue: bridge.queue) }
                        if c.systemAudioEnabled { try stream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: bridge.audioQueue) }
                        try await stream.startCapture()
                    } else if needsScreen {
                        videoPreviewError = "Allow Screen Recording in Settings to preview your desktop."
                    }
                }
                guard token == previewGeneration else { await stopMenuPreview(); return }
                if mode != nil {
                    if c.cameraEnabled && !previewSynthetic {
                        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                            let camera = CameraCapture(inputs: inputs)
                            previewCamera = camera
                            try await camera.start(id: c.cameraID)
                        } else {
                            videoPreviewError = "Allow Camera access in Settings to preview your webcam."
                        }
                    }
                    guard token == previewGeneration else { await stopMenuPreview(); return }
                    if mode == .program && c.chatEnabled && !previewSynthetic {
                        previewChat = Chat(onImage: { image in inputs.setChat(image) }, chatURL: c.chatURL, width: Int(c.chatWidth))
                    }
                    let renderer = try FrameRenderer(inputs: inputs, preview: previewFrames, outputFD: nil, synthetic: previewSynthetic)
                    previewRenderer = renderer
                    renderer.start(epoch: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
                }
                meter.startPreviewClock(configuration: c)
                meterPreviewActive = true
                previewMonitor = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                        guard let self, let meter = self.previewOutput else { return }
                        inputs.setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                        if let failure = meter.errorMessage ?? inputs.error {
                            self.meterPreviewError = failure
                            self.videoPreviewError = failure
                            self.previewDesired = false
                            await self.reconcileMenuPreview()
                            return
                        }
                        let levels = meter.levels
                        self.microphoneLevel = levels.microphone; self.systemLevel = levels.system
                        self.outputLevel = levels.output; self.gainReduction = levels.gainReduction
                    }
                }
            } catch {
                await stopMenuPreview()
                if token == previewGeneration { videoPreviewError = error.localizedDescription }
            }
        }
        previewTransition = task
        await task.value
        if token == previewGeneration { previewTransition = nil }
    }

    private func stopMenuPreview() async {
        previewMonitor?.cancel(); previewMonitor = nil
        let stream = previewStream; previewStream = nil
        let output = previewOutput; previewOutput = nil
        let camera = previewCamera; previewCamera = nil
        let renderer = previewRenderer; previewRenderer = nil
        previewChat?.stop(); previewChat = nil
        meterPreviewActive = false
        if let renderer { _ = try? await renderer.finish() }
        if let camera { await camera.stop() }
        if let stream { try? await stream.stopCapture() }
        if let output { await output.stopPreview() }
        previewBridge = nil; previewInputs = nil
        if !isRunning {
            previewFrames.publish(nil)
            microphoneLevel = 0; systemLevel = 0; outputLevel = 0; gainReduction = 0
        }
    }

    func cameras() -> [DeviceOption] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)
            .devices.map { DeviceOption(id: $0.uniqueID, name: $0.localizedName) }
    }
    func microphones() -> [DeviceOption] { MediaOutput.microphoneDevices() }
    func sources() async throws -> [CaptureSource] {
        guard CGPreflightScreenCaptureAccess() else { throw EngineError.message("Screen Recording permission is required to list sources") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        captureApplications = content.applications.filter { $0.processID != ProcessInfo.processInfo.processIdentifier && !$0.bundleIdentifier.isEmpty }
            .map { DeviceOption(id: $0.bundleIdentifier, name: $0.applicationName) }
            .reduce(into: [DeviceOption]()) { result, item in if !result.contains(where: { $0.id == item.id }) { result.append(item) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return content.displays.map { CaptureSource(id: $0.displayID, kind: .display, name: "Display \($0.displayID) · \($0.width) × \($0.height)") } +
            content.windows.filter { $0.frame.width > 1 && $0.frame.height > 1 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }.map {
                CaptureSource(id: $0.windowID, kind: .window, name: "\($0.owningApplication?.applicationName ?? "App") — \($0.title ?? "Window")")
            }
    }

    func start(configuration: StudioConfiguration, streamKey: String, synthetic: Bool = false) async throws {
        guard !isRunning, !starting, !stopping else { throw EngineError.message("A session is already active or changing") }
        starting = true; generation &+= 1; let session = generation
        await reconcileMenuPreview()
        errorMessage = nil; status = "Starting"; outputHealth = "Preparing output…"
        self.configuration = configuration; self.synthetic = synthetic
        do {
            let inputs = RenderInputs(); inputs.configure(configuration); self.inputs = inputs
            inputs.setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            let output = MediaOutput(); self.output = output
            let bridge = CaptureBridge(inputs: inputs, output: output); self.bridge = bridge
            if !synthetic {
                try await configureScreen(configuration)
                try ensureCurrent(session)
                if configuration.cameraEnabled { try await startCamera(configuration) }
                try ensureCurrent(session)
                configureChat(configuration)
            }
            try await output.start(configuration: configuration, streamKey: streamKey, synthetic: synthetic)
            try ensureCurrent(session)
            let renderer = try FrameRenderer(inputs: inputs, preview: previewFrames, outputFD: output.videoFD, synthetic: synthetic)
            self.renderer = renderer
            renderer.start(epoch: output.beginMediaClock(configuration: configuration))
            starting = false; isRunning = true; status = output.status
            monitor = Task { [weak self] in
                var nextHealth = 0.0
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    guard let self else { return }
                    self.inputs?.setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                    if let failure = self.inputs?.error ?? self.output?.errorMessage ?? self.chat?.error.map({ "Chat renderer: \($0.localizedDescription)" }) {
                        self.errorMessage = failure
                        self.monitor = nil
                        await self.stop()
                        self.status = "Failed"
                        return
                    }
                    if let levels = self.output?.levels {
                        if self.microphoneLevel != levels.microphone { self.microphoneLevel = levels.microphone }
                        if self.systemLevel != levels.system { self.systemLevel = levels.system }
                        if self.outputLevel != levels.output { self.outputLevel = levels.output }
                        if self.gainReduction != levels.gainReduction { self.gainReduction = levels.gainReduction }
                    }
                    let status = self.output?.status ?? "Idle"
                    if self.status != status { self.status = status }
                    let now = ProcessInfo.processInfo.systemUptime
                    if now >= nextHealth {
                        nextHealth = now + 1
                        let health = self.output?.health.summary ?? "Idle"
                        if self.outputHealth != health { self.outputHealth = health }
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            await stop(); starting = false; status = "Failed"
            throw error
        }
    }

    func update(configuration next: StudioConfiguration) async throws {
        guard !stopping else { return }
        if !isRunning {
            if previewDesired {
                let old = previewConfiguration
                if meterPreviewActive, old.microphoneID == next.microphoneID,
                   old.microphoneEnabled == next.microphoneEnabled, old.systemAudioEnabled == next.systemAudioEnabled,
                   old.displayID == next.displayID, old.windowID == next.windowID,
                   old.dockFitDisplayID == next.dockFitDisplayID,
                   old.layout == next.layout, old.cameraEnabled == next.cameraEnabled, old.cameraID == next.cameraID,
                   old.chatEnabled == next.chatEnabled, old.chatURL == next.chatURL, old.chatWidth == next.chatWidth,
                   old.excludedApplicationIDs == next.excludedApplicationIDs, old.excludedWindowIDs == next.excludedWindowIDs {
                    previewConfiguration = next
                    previewOutput?.configurePreview(next)
                    previewInputs?.configure(next)
                } else {
                    await setMenuPreview(visible: true, configuration: next, synthetic: previewSynthetic)
                }
            }
            return
        }
        previewConfiguration = next
        let old = configuration
        do {
            if !next.cameraEnabled {
                var hidden = old; hidden.cameraEnabled = false; inputs?.configure(hidden)
            }
            if !synthetic {
                if next.layout == .desktopChat && next.displayID == nil && next.windowID == nil { throw EngineError.message("Choose a display or window before switching to Desktop") }
                if old.cameraEnabled != next.cameraEnabled || old.cameraID != next.cameraID {
                    inputs?.setCamera(nil)
                    if let camera { await camera.stop(); self.camera = nil }
                    if next.cameraEnabled { try await startCamera(next) }
                }
                if old.layout != next.layout || old.systemAudioEnabled != next.systemAudioEnabled || old.displayID != next.displayID || old.windowID != next.windowID {
                    try await configureScreen(next, preserveFrame: old.displayID == next.displayID && old.windowID == next.windowID)
                }
                if old.chatEnabled != next.chatEnabled || old.chatURL != next.chatURL || old.chatWidth != next.chatWidth { configureChat(next) }
                if old.excludedApplicationIDs != next.excludedApplicationIDs || old.excludedWindowIDs != next.excludedWindowIDs {
                    try await updateCaptureFilter(next)
                }
            }
            try await output?.updateAudio(configuration: next)
            configuration = next; inputs?.configure(next)
        } catch {
            errorMessage = error.localizedDescription
            await stop(); status = "Failed"
            throw error
        }
    }
    func stop() async {
        if stopping { return }
        stopping = true; generation &+= 1
        monitor?.cancel(); monitor = nil
        status = "Stopping"
        chat?.stop(); chat = nil
        if let camera { await camera.stop(); self.camera = nil }
        if let stream { try? await stream.stopCapture(); self.stream = nil }
        var videoFrames: Int64?
        if let renderer {
            do { videoFrames = try await renderer.finish() } catch { if errorMessage == nil { errorMessage = "Could not finalize video: \(error.localizedDescription)" } }
            self.renderer = nil
        }
        if let output {
            await output.stop(videoFrames: videoFrames)
            if errorMessage == nil { errorMessage = output.errorMessage }
            self.output = nil
        }
        inputs = nil; bridge = nil; previewFrames.publish(nil)
        microphoneLevel = 0; systemLevel = 0; outputLevel = 0; gainReduction = 0
        isRunning = false; starting = false; stopping = false
        status = errorMessage == nil ? "Idle" : "Failed"
        await reconcileMenuPreview()
    }
    private func ensureCurrent(_ session: UInt64) throws {
        guard generation == session, !stopping else { throw CancellationError() }
    }
    private func configureChat(_ c: StudioConfiguration) {
        guard let inputs else { return }
        if !c.chatEnabled {
            chat?.stop(); chat = nil; inputs.setChat(nil)
            return
        }
        if chat != nil, configuration.chatURL == c.chatURL, configuration.chatWidth == c.chatWidth { return }
        chat?.stop()
        self.chat = Chat(onImage: { image in inputs.setChat(image) }, chatURL: c.chatURL, width: Int(c.chatWidth))
    }
    func refreshCaptureFilter() async throws {
        try await updateCaptureFilter(configuration)
    }
    private func updateCaptureFilter(_ c: StudioConfiguration) async throws {
        guard let stream, !synthetic else { return }
        let session = generation
        let filter = try await captureFilter(c)
        guard generation == session, !stopping else { return }
        try await stream.updateContentFilter(filter)
    }
    private func captureFilter(_ c: StudioConfiguration) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        if let id = c.windowID {
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw EngineError.message("Selected window is no longer available") }
            guard !c.excludedWindowIDs.contains(id), !c.excludedApplicationIDs.contains(window.owningApplication?.bundleIdentifier ?? "") else {
                throw EngineError.message("The selected capture source is excluded. Choose another source or remove its exclusion.")
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
        let id = c.displayID ?? (c.layout == .justChatting && c.systemAudioEnabled ? CGMainDisplayID() : 0)
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw EngineError.message("Select an available display") }
        let excluded = Set(c.excludedApplicationIDs)
        let applications = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier || excluded.contains($0.bundleIdentifier)
        }
        let excludedPIDs = Set(applications.map(\.processID))
        let exceptions = content.windows.filter { window in
            if window.windowID == annotationWindowID { return true }
            return c.excludedWindowIDs.contains(window.windowID) && !excludedPIDs.contains(window.owningApplication?.processID ?? -1)
        }
        return SCContentFilter(display: display, excludingApplications: applications, exceptingWindows: exceptions)
    }
    private func captureRect(_ filter: SCContentFilter, configuration c: StudioConfiguration) throws -> CGRect {
        var rect = filter.contentRect
        guard c.windowID == nil, let id = c.dockFitDisplayID, id == c.displayID else { return rect }
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }), DockCanvasFit.fits(screen) else {
            throw EngineError.message("The Dock or display changed. Turn off Fit desktop to 16:9, then enable it again.")
        }
        rect.size.height = rect.width * 9 / 16
        return rect
    }

    private func configureScreen(_ c: StudioConfiguration, preserveFrame: Bool = false) async throws {
        if let stream { try await stream.stopCapture(); self.stream = nil }
        let session = generation
        if !preserveFrame { inputs?.setScreen(nil) }
        guard c.layout == .desktopChat || c.systemAudioEnabled else { return }
        guard CGPreflightScreenCaptureAccess() else { throw EngineError.message("Grant Screen Recording access in Settings before enabling screen or system audio capture") }
        guard let bridge else { throw EngineError.message("Capture is not initialized") }
        let filter = try await captureFilter(c)
        let rect = try captureRect(filter, configuration: c)
        let width = max(1, rect.width * CGFloat(filter.pointPixelScale)); let height = max(1, rect.height * CGFloat(filter.pointPixelScale))
        let scale = min(1, min(1920 / width, 1080 / height))
        let options = SCStreamConfiguration()
        options.sourceRect = rect
        options.width = max(2, Int(width * scale)); options.height = max(2, Int(height * scale))
        options.pixelFormat = kCVPixelFormatType_32BGRA; options.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        options.queueDepth = 3; options.showsCursor = true
        options.capturesAudio = c.systemAudioEnabled; options.excludesCurrentProcessAudio = true
        options.sampleRate = 48_000; options.channelCount = 2
        let stream = SCStream(filter: filter, configuration: options, delegate: bridge)
        if c.layout == .desktopChat { try stream.addStreamOutput(bridge, type: .screen, sampleHandlerQueue: bridge.queue) }
        if c.systemAudioEnabled { try stream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: bridge.audioQueue) }
        try await stream.startCapture()
        guard session == generation, !stopping else { try? await stream.stopCapture(); throw CancellationError() }
        self.stream = stream
    }
    private func startCamera(_ c: StudioConfiguration) async throws {
        guard let inputs else { throw EngineError.message("Capture is not initialized") }
        let camera = CameraCapture(inputs: inputs)
        let session = generation
        try await camera.start(id: c.cameraID)
        guard session == generation, !stopping else { await camera.stop(); throw CancellationError() }
        self.camera = camera
    }
}

private final class CaptureBridge: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "streamapp.screen", qos: .userInitiated)
    let audioQueue = DispatchQueue(label: "streamapp.system-audio", qos: .userInitiated)
    private let inputs: RenderInputs
    private let output: MediaOutput
    init(inputs: RenderInputs, output: MediaOutput) { self.inputs = inputs; self.output = output }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { output.appendSystemAudio(sample); return }
        guard type == .screen, let image = sample.imageBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              (attachments.first?[.status] as? NSNumber)?.intValue == SCFrameStatus.complete.rawValue else { return }
        inputs.setScreen(image)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { inputs.fail("Screen capture stopped. Reselect your source and restart.") }
}

private final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "streamapp.camera", qos: .userInitiated)
    private let inputs: RenderInputs
    private var session: AVCaptureSession?
    private var observer: NSObjectProtocol?
    private var disconnectionObserver: NSObjectProtocol?
    private let startLock = NSLock()
    private var startCancelled = false
    func cancelStart() {
        startLock.lock(); startCancelled = true; startLock.unlock()
    }
    private func checkStart() throws {
        startLock.lock(); let cancelled = startCancelled; startLock.unlock()
        if cancelled { throw CancellationError() }
    }
    init(inputs: RenderInputs) { self.inputs = inputs }
    func start(id: String) async throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { throw EngineError.message("Grant Camera access in Settings first") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in queue.async {
            do {
                try self.checkStart()
                guard let device = id.isEmpty ? AVCaptureDevice.default(for: .video) : AVCaptureDevice(uniqueID: id) else { throw EngineError.message("Selected camera is unavailable") }
                let session = AVCaptureSession(); session.beginConfiguration()
                if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw EngineError.message("Cannot open camera") }; session.addInput(input)
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true; output.setSampleBufferDelegate(self, queue: self.queue)
                guard session.canAddOutput(output) else { throw EngineError.message("Cannot configure camera") }; session.addOutput(output)
                session.commitConfiguration(); self.session = session
                try self.checkStart()
                self.observer = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in self?.inputs.fail("Camera stopped. Check the device and restart.") }
                self.disconnectionObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
                    self?.inputs.setCamera(nil)
                    self?.inputs.fail("Camera disconnected. Select a device and restart.")
                }
                try self.checkStart()
                session.startRunning()
                guard session.isRunning else { throw EngineError.message("Camera failed to start") }
                continuation.resume()
            } catch { self.session?.stopRunning(); self.session = nil; continuation.resume(throwing: error) }
        } }
    }
    func stop() async {
        cancelStart()
        await withCheckedContinuation { continuation in queue.async {
            self.session?.stopRunning(); self.session = nil
            if let observer = self.observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            if let observer = self.disconnectionObserver { NotificationCenter.default.removeObserver(observer); self.disconnectionObserver = nil }
            self.inputs.setCamera(nil)
            continuation.resume()
        } }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let image = sampleBuffer.imageBuffer { inputs.setCamera(image) }
    }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let disconnectionObserver { NotificationCenter.default.removeObserver(disconnectionObserver) }
    }
}

enum EngineError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
