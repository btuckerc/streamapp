import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit

/// Live channel levels at the 5 Hz meter poll. Kept apart from `StudioEngine` so each poll
/// invalidates only the meter rows that observe it, not every view observing the engine.
@MainActor
final class AudioMeters: ObservableObject {
    @Published private(set) var microphone = AudioLevel.silent
    @Published private(set) var system = AudioLevel.silent
    @Published private(set) var output = AudioLevel.silent
    @Published private(set) var limiterReduction: Float = 0

    func update(_ levels: AudioMixer.Levels) {
        if microphone != levels.microphone { microphone = levels.microphone }
        if system != levels.system { system = levels.system }
        if output != levels.output { output = levels.output }
        if limiterReduction != levels.limiterReduction { limiterReduction = levels.limiterReduction }
    }
    func clear() { update((.silent, .silent, .silent, 0, 0)) }
}

@MainActor
final class StudioEngine: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    let previewFrames = PreviewFrames()
    let meters = AudioMeters()
    @Published private(set) var echoCancellationStatus: String?
    @Published private(set) var meterPreviewActive = false
    @Published private(set) var meterPreviewError: String?
    @Published private(set) var videoPreviewMode: PreviewFrames.Mode?
    @Published private(set) var videoPreviewError: String?
    @Published private(set) var status = "Idle"
    @Published private(set) var outputHealth = "Idle"
    @Published private(set) var privacyStatus: String?
    @Published private(set) var captureApplications: [DeviceOption] = []
    /// Non-fatal camera warning; the session keeps running without the frame.
    @Published private(set) var cameraStatus: String?
    /// A session or preview holds the camera open; macOS offers Video Effects only then.
    @Published private(set) var cameraOpen = false
    @Published private(set) var microphoneStatus: String?
    @Published private(set) var resolvedMicrophoneID: String?
    struct RecordingResult: Equatable {
        let url: URL
        let bytes: Int64
        let seconds: Double
        /// False when the session ended with an error, so the file may be cut short.
        let complete: Bool
    }
    /// The latest recording on disk. Kept through a failed start; cleared once a new session runs.
    @Published private(set) var lastRecording: RecordingResult?
    /// Encoder progress of the running session (frames/seconds from FFmpeg `-progress`); nil when idle.
    var outputHealthSnapshot: MediaOutput.Health? { output?.health }
    var annotationWindowID: CGWindowID?
    var teleprompterWindowIDs: Set<CGWindowID> = []
    var cameraArrangeWindowID: CGWindowID?
    @Published private(set) var cameraDragAnchor: CameraAnchor?
    @Published private(set) var cameraDodgeAnchor: CameraAnchor?
    private var cursorGlobalMonitor: Any?
    private var cursorLocalMonitor: Any?
    private var cursorDodging = false
    private var cameraArrangementActive = false
    func setCameraArrangementActive(_ active: Bool) {
        cameraArrangementActive = active
        reconcileCursorAvoidance()
    }

    func setCameraDrag(_ anchor: CameraAnchor?) {
        guard cameraDragAnchor != anchor else { return }
        cameraDragAnchor = anchor
        inputs?.setCameraDrag(anchor); previewInputs?.setCameraDrag(anchor)
        if anchor != nil { cursorDodging = false; cameraDodgeAnchor = nil }
    }
    func finishCameraDrag(committing anchor: CameraAnchor) {
        inputs?.finishCameraDrag(committing: anchor); previewInputs?.finishCameraDrag(committing: anchor)
        cameraDragAnchor = nil
    }
    /// AppKit supplies display metrics once per event; crop math itself is pure and shared.
    private func captureRegion(_ full: CGRect, configuration c: StudioConfiguration) -> CGRect {
        guard c.windowID == nil, let screen = captureScreen(c) else {
            return c.dockFitRegion?.crop(full, selectedDisplayID: c.displayID, windowID: c.windowID) ?? full
        }
        let topInset = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        return DisplayCaptureGeometry.crop(full, displayBounds: CGRect(origin: .zero, size: screen.frame.size),
            topInset: topInset, includeMenuBar: c.includeMenuBar,
            dockHeightFraction: c.dockFitRegion.flatMap { $0.displayID == c.displayID ? $0.heightFraction : nil })
    }
    private func captureScreen(_ c: StudioConfiguration) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == c.displayID
        }
    }
    func cameraDisplayMapping(configuration c: StudioConfiguration) -> CameraDisplayMapping? {
        guard c.layout == .desktopChat, c.cameraEnabled, c.windowID == nil, let screen = captureScreen(c) else { return nil }
        let sessionSource = isRunning && configuration.displayID == c.displayID && configuration.windowID == nil
        let previewSource = previewStream != nil && previewConfiguration.displayID == c.displayID && previewConfiguration.windowID == nil
        let full = sessionSource && !screenRect.isEmpty ? screenRect :
            (previewSource && !previewScreenRect.isEmpty ? previewScreenRect : CGRect(origin: .zero, size: screen.frame.size))
        let region = captureRegion(full, configuration: c)
        let pixelScale = sessionSource ? screenScale : previewSource ? previewScreenScale : screen.backingScaleFactor
        return CameraDisplayMapping(region: region, displayFrame: screen.frame,
            desktop: SceneGeometry(configuration: c).desktop,
            sourceSize: DisplayCaptureGeometry.outputSize(region: region, pixelScale: pixelScale))
    }
    private func reconcileCursorAvoidance() {
        let c = isRunning ? configuration : previewConfiguration
        let enabled = (isRunning || (previewRenderer != nil && videoPreviewMode == .program)) &&
            c.cameraAvoidCursor && c.cameraEnabled && c.layout == .desktopChat && c.windowID == nil
        if enabled {
            if cursorLocalMonitor == nil {
                let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
                cursorGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cursorMoved() }
                }
                cursorLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                    self?.cursorMoved(); return event
                }
            }
            cursorMoved()
        } else {
            if let cursorGlobalMonitor { NSEvent.removeMonitor(cursorGlobalMonitor) }
            if let cursorLocalMonitor { NSEvent.removeMonitor(cursorLocalMonitor) }
            cursorGlobalMonitor = nil; cursorLocalMonitor = nil; cursorDodging = false
            inputs?.setCameraDodge(nil); previewInputs?.setCameraDodge(nil)
            if cameraDodgeAnchor != nil { cameraDodgeAnchor = nil }
        }
    }
    private func cursorMoved() {
        let c = isRunning ? configuration : previewConfiguration
        guard let mapping = cameraDisplayMapping(configuration: c) else { return }
        let g = SceneGeometry(configuration: c)
        let anchor = CameraPlacement.dodgeAnchor(home: c.cameraAnchor)
        let dodge = CameraPlacement.rect(anchor: anchor, size: g.camera.size, desktop: g.desktop)
        cursorDodging = CameraPlacement.shouldDodge(cursor: mapping.toCanvas(NSEvent.mouseLocation),
            home: g.camera, dodge: dodge, dodging: cursorDodging,
            enabled: !c.cameraPunchIn && cameraDragAnchor == nil && !cameraArrangementActive)
        let next = cursorDodging ? anchor : nil
        if cameraDodgeAnchor != next { cameraDodgeAnchor = next }
        inputs?.setCameraDodge(cursorDodging ? anchor : nil)
        previewInputs?.setCameraDodge(cursorDodging ? anchor : nil)
    }
    private var captureFilterRevision: UInt64 = 0
    private var captureFilterUpdate: Task<Void, Error>?
    private var desiredConfiguration = StudioConfiguration()
    /// The newest configuration handed to `update`, which may still be queued behind an earlier one.
    private var requestedConfiguration: StudioConfiguration?
    /// What `request` last put on air ahead of a commit, so repeated requests skip reconfiguring.
    private var requestedMask: StudioConfiguration?
    private var inputs: RenderInputs?
    private var bridge: CaptureBridge?
    private var audioBridge: CaptureBridge?
    private var renderer: FrameRenderer?
    private var output: MediaOutput?
    private var stream: SCStream?
    private var audioStream: SCStream?
    private var referenceStream: SCStream?
    private var referenceBridge: CaptureBridge?
    private var audioRevision: UInt64 = 0
    private var audioUpdate: Task<Void, Error>?
    private var audioApplications: [NSRunningApplication] = []
    private var camera: CameraCapture? { didSet { cameraOpen = camera != nil || previewCamera != nil } }
    private var chat: Chat?
    private var monitor: Task<Void, Never>?
    /// Held only while a session runs: keeps App Nap from throttling capture/encode in a windowless menu-bar app,
    /// and keeps the system and display awake (a sleeping display stops ScreenCaptureKit frames mid-stream).
    private var sessionActivity: NSObjectProtocol?
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
    private var previewAudioStream: SCStream?
    private var previewAudioApplications: [NSRunningApplication] = []
    private var menuPreviewVisible = false
    private var settingsPreviewVisible = false
    private var previewDesired: Bool { menuPreviewVisible || settingsPreviewVisible }
    private var previewGeneration: UInt64 = 0
    private var previewTransition: Task<Void, Never>?
    private var previewConfiguration = StudioConfiguration()
    private var previewSynthetic = false
    private var previewInputs: RenderInputs?
    private var previewCamera: CameraCapture? { didSet { cameraOpen = camera != nil || previewCamera != nil } }
    private var previewBridge: CaptureBridge?
    private var previewAudioBridge: CaptureBridge?
    private var previewReferenceStream: SCStream?
    private var previewReferenceBridge: CaptureBridge?
    private var previewScreenOptions: SCStreamConfiguration?
    private var previewScreenRect = CGRect.zero
    private var previewScreenScale: CGFloat = 1
    private var screenOptions: SCStreamConfiguration?
    private var screenRect = CGRect.zero
    private var screenScale: CGFloat = 1
    /// Visible preview capture only: no encoder, recording, or streaming output.
    func setMenuPreview(visible: Bool, configuration: StudioConfiguration, synthetic: Bool = false) async {
        menuPreviewVisible = visible
        previewConfiguration = configuration
        previewSynthetic = synthetic
        if !previewDesired { previewCamera?.cancelStart() }
        await reconcileMenuPreview()
    }

    func setSettingsPreview(visible: Bool, configuration: StudioConfiguration, synthetic: Bool = false) async {
        settingsPreviewVisible = visible
        previewConfiguration = configuration
        previewSynthetic = synthetic
        if !previewDesired { previewCamera?.cancelStart() }
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
            // A rebuild keeps the last preview frame up until the new renderer replaces it.
            let keepFrame = previewDesired && videoPreviewMode != nil
            await stopMenuPreview(clearFrame: !keepFrame)
            defer { if keepFrame, token == previewGeneration, previewRenderer == nil, !isRunning { previewFrames.publish(nil) } }
            guard token == previewGeneration, previewDesired, !isRunning, !starting, !stopping else { return }
            meterPreviewError = nil
            videoPreviewError = nil
            let c = previewConfiguration
            let mode = videoPreviewMode
            let needsScreen = mode == .program && c.layout.showsDesktop
            // Missing permission is an onboarding state, not a preview failure.
            // Do not open any devices until the configured preview can run.
            if !previewSynthetic {
                if c.microphoneEnabled && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { return }
                if mode != nil && c.cameraEnabled && AVCaptureDevice.authorizationStatus(for: .video) != .authorized { return }
                if (c.systemAudioEnabled || needsScreen) && !CGPreflightScreenCaptureAccess() {
                    meterPreviewError = "Allow Screen Recording to capture system audio or use echo cancellation."
                    echoCancellationStatus = c.microphoneEchoCancellationEnabled ? "Waiting for Screen Recording permission" : nil
                    return
                }
            }
            let inputs = RenderInputs()
            inputs.configure(c)
            previewInputs = inputs
            let meter = MediaOutput()
            previewOutput = meter
            do {
                try await meter.startPreview(configuration: c, synthetic: previewSynthetic)
                guard token == previewGeneration else { await stopMenuPreview(); return }
                if !previewSynthetic && (c.systemAudioEnabled || needsScreen || needsEchoReference(c)) {
                    if (c.systemAudioEnabled || needsScreen) && !CGPreflightScreenCaptureAccess() {
                        if needsScreen { videoPreviewError = "Allow Screen Recording in Settings to preview your desktop." }
                        if c.systemAudioEnabled { meterPreviewError = "Allow Screen Recording to capture system audio." }
                        throw EngineError.message("Screen Recording permission is required")
                    }
                    let bridge = CaptureBridge(inputs: inputs, output: meter)
                    previewBridge = bridge
                    if needsScreen { try await startPreviewScreen(c, bridge: bridge, token: token) }
                    let audio = try await startAudioStreams(c, inputs: inputs, output: meter)
                    guard token == previewGeneration else {
                        for stream in audio.streams { try? await stream.stopCapture() }
                        await stopMenuPreview(); return
                    }
                    previewAudioStream = audio.system
                    previewAudioBridge = audio.systemBridge
                    previewReferenceStream = audio.reference
                    previewReferenceBridge = audio.referenceBridge
                    previewAudioApplications = audio.applications
                }
                guard token == previewGeneration else { await stopMenuPreview(); return }
                if mode != nil {
                    if c.cameraEnabled && !previewSynthetic {
                        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                            let camera = makeCamera(inputs: inputs)
                            previewCamera = camera
                            try await camera.start(id: c.cameraID)
                            cameraStatus = nil
                        } else {
                            videoPreviewError = "Camera access is off."
                        }
                    }
                    guard token == previewGeneration else { await stopMenuPreview(); return }
                    if mode == .program && c.chatEnabled && !previewSynthetic {
                        previewChat = Chat(onImage: { image in inputs.setChat(image) }, channel: c.twitchChatChannel, size: SceneGeometry.chatSize(c), appearance: c.chatAppearance)
                    }
                    let renderer = try FrameRenderer(inputs: inputs, preview: previewFrames, outputFD: nil, synthetic: previewSynthetic)
                    previewRenderer = renderer
                    renderer.start(epoch: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
                    reconcileCursorAvoidance()
                }
                meter.startPreviewClock(configuration: c)
                meterPreviewActive = true
                previewMonitor = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                        guard let self, let meter = self.previewOutput else { return }
                        if self.previewAudioApplications.contains(where: \.isTerminated) {
                            inputs.fail("Selected audio application quit. Reopen it and restart capture.")
                        }
                        if let failure = meter.errorMessage ?? inputs.error {
                            self.meterPreviewError = failure
                            self.videoPreviewError = failure
                            self.menuPreviewVisible = false
                            self.settingsPreviewVisible = false
                            await self.reconcileMenuPreview()
                            return
                        }
                        self.meters.update(meter.levels)
                        let echo = meter.echoCancellationStatus
                        if self.echoCancellationStatus != echo { self.echoCancellationStatus = echo }
                        let microphoneStatus = meter.microphoneStatus
                        if self.microphoneStatus != microphoneStatus { self.microphoneStatus = microphoneStatus }
                        if self.resolvedMicrophoneID != meter.resolvedMicrophoneID { self.resolvedMicrophoneID = meter.resolvedMicrophoneID }
                    }
                }
            } catch {
                await stopMenuPreview()
                if token == previewGeneration {
                    meterPreviewError = error.localizedDescription
                    if mode != nil { videoPreviewError = error.localizedDescription }
                }
            }
        }
        previewTransition = task
        await task.value
        if token == previewGeneration { previewTransition = nil }
    }

    /// Starts the program preview's screen stream into the current preview inputs.
    private func startPreviewScreen(_ c: StudioConfiguration, bridge: CaptureBridge, token: UInt64) async throws {
        let filter = try await captureFilter(c, inputs: previewInputs)
        guard token == previewGeneration else { throw CancellationError() }
        let options = SCStreamConfiguration()
        setCaptureGeometry(options, rect: filter.contentRect, scale: CGFloat(filter.pointPixelScale), configuration: c, inputs: previewInputs)
        options.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        options.pixelFormat = c.privacyShieldEnabled ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_32BGRA
        options.queueDepth = c.privacyShieldEnabled ? 4 : 3
        options.capturesAudio = false
        let stream = SCStream(filter: filter, configuration: options, delegate: bridge)
        previewScreenOptions = options
        previewScreenRect = filter.contentRect
        previewScreenScale = CGFloat(filter.pointPixelScale)
        previewStream = stream
        try stream.addStreamOutput(bridge, type: .screen, sampleHandlerQueue: bridge.queue)
        try await stream.startCapture()
    }

    /// Adds the screen stream to a running preview. On failure the preview is rebuilt so the usual error surfaces.
    private func addPreviewScreen(_ c: StudioConfiguration) async -> Bool {
        let token = previewGeneration
        if CGPreflightScreenCaptureAccess(), let inputs = previewInputs, let output = previewOutput {
            let bridge = previewBridge ?? CaptureBridge(inputs: inputs, output: output)
            previewBridge = bridge
            do { try await startPreviewScreen(c, bridge: bridge, token: token); return true } catch {}
        }
        if token == previewGeneration { await reconcileMenuPreview() }
        return false
    }

    private func stopMenuPreview(clearFrame: Bool = true) async {
        previewMonitor?.cancel(); previewMonitor = nil
        previewAudioApplications = []
        let stream = previewStream; previewStream = nil
        let audioStream = previewAudioStream; previewAudioStream = nil
        let referenceStream = previewReferenceStream; previewReferenceStream = nil
        previewScreenOptions = nil
        let output = previewOutput; previewOutput = nil
        let camera = previewCamera; previewCamera = nil
        if camera != nil { cameraStatus = nil }
        let renderer = previewRenderer; previewRenderer = nil
        previewChat?.stop(); previewChat = nil
        reconcileCursorAvoidance()
        meterPreviewActive = false
        previewInputs?.closeScreenWaits()
        if let renderer { _ = try? await renderer.finish(clearingPreview: clearFrame) }
        if let camera { await camera.stop() }
        if let stream { try? await stream.stopCapture() }
        if let audioStream { try? await audioStream.stopCapture() }
        if let referenceStream { try? await referenceStream.stopCapture() }
        if let output { await output.stopPreview() }
        previewBridge = nil; previewInputs = nil
        previewAudioBridge = nil
        previewReferenceBridge = nil
        if !isRunning {
            if clearFrame { previewFrames.publish(nil) }
            meters.clear()
            echoCancellationStatus = nil
            microphoneStatus = nil
            resolvedMicrophoneID = nil
            Self.releaseFreedMemory()
        }
    }

    nonisolated static func cameras() -> [DeviceOption] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)
            .devices.map { DeviceOption(id: $0.uniqueID, name: $0.localizedName) }
    }
    nonisolated static func microphones() -> [DeviceOption] { MediaOutput.microphoneDevices() }
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
        errorMessage = nil; status = "Starting"; outputHealth = "Starting…"
        sessionActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: "Recording or streaming")
        self.configuration = configuration; self.synthetic = synthetic
        desiredConfiguration = configuration
        do {
            let inputs = RenderInputs(historyEnabled: configuration.privacyShieldEnabled); inputs.configure(configuration); self.inputs = inputs
            let output = MediaOutput(); self.output = output
            let bridge = CaptureBridge(inputs: inputs, output: output); self.bridge = bridge
            if !synthetic {
                // One enumeration serves the screen and audio filters of this start.
                let content = ShareableContentOnce()
                try await configureScreen(configuration, content: content)
                try await configureSystemAudio(configuration, content: content)
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
            starting = false; isRunning = true; status = output.status; lastRecording = nil
            reconcileCursorAvoidance()
            privacyStatus = renderer.privacyStatus
            monitor = Task { [weak self] in
                var nextHealth = 0.0
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    guard let self else { return }
                    if self.audioApplications.contains(where: \.isTerminated) {
                        self.inputs?.fail("Selected audio application quit. Reopen it and restart capture.")
                    }
                    if let failure = self.inputs?.error ?? self.output?.errorMessage ?? self.chat?.error.map({ "Chat renderer: \($0.localizedDescription)" }) {
                        self.errorMessage = failure
                        self.monitor = nil
                        await self.stop()
                        self.status = "Failed"
                        return
                    }
                    if let levels = self.output?.levels { self.meters.update(levels) }
                    let echo = self.output?.echoCancellationStatus
                    if self.echoCancellationStatus != echo { self.echoCancellationStatus = echo }
                    let privacy = self.renderer?.privacyStatus
                    if self.privacyStatus != privacy { self.privacyStatus = privacy }
                    let microphoneStatus = self.output?.microphoneStatus
                    if self.microphoneStatus != microphoneStatus { self.microphoneStatus = microphoneStatus }
                    if self.resolvedMicrophoneID != self.output?.resolvedMicrophoneID { self.resolvedMicrophoneID = self.output?.resolvedMicrophoneID }
                    let status = [self.output?.status, self.renderer?.privacyStatus].compactMap { $0 }.joined(separator: " · ")
                    if self.status != status { self.status = status }
                    let now = ProcessInfo.processInfo.systemUptime
                    if now >= nextHealth {
                        nextHealth = now + 1
                        var health = self.output?.health.summary ?? "Idle"
                        // Thermal pressure throttles encode/render before frames are dropped; say why early.
                        switch ProcessInfo.processInfo.thermalState {
                        case .serious: health += " · Mac is hot; performance may be throttled"
                        case .critical: health += " · Mac is overheating; frames may drop"
                        default: break
                        }
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

    /// Records the newest configuration the user asked for, ahead of serialized updates still applying
    /// an older one. Hiding the webcam or the desktop is on air by the next frame and silencing the
    /// microphone by the next audio block; queued updates then commit under the same mask.
    func request(_ next: StudioConfiguration) {
        requestedConfiguration = next
        guard isRunning, let inputs else { return }
        output?.hide(as: next)
        let masked = privacyMasked(configuration)
        if masked != configuration && masked != requestedMask { inputs.configure(masked) }
        requestedMask = masked
    }

    func update(configuration next: StudioConfiguration) async throws {
        request(next)
        let previous = audioUpdate
        let task = Task { [self] in
            _ = try? await previous?.value
            try await applyUpdate(configuration: next)
        }
        audioUpdate = task
        try await task.value
    }

    private func applyUpdate(configuration next: StudioConfiguration) async throws {
        guard !stopping else { return }
        defer { reconcileCursorAvoidance() }
        desiredConfiguration = next
        if !isRunning {
            if previewDesired {
                let old = previewConfiguration
                if meterPreviewActive, old.microphoneID == next.microphoneID,
                   old.microphoneChannels == next.microphoneChannels,
                   old.microphoneSyncOffsetMs == next.microphoneSyncOffsetMs,
                   old.systemAudioSyncOffsetMs == next.systemAudioSyncOffsetMs,
                   old.microphoneEnabled == next.microphoneEnabled, old.systemAudioEnabled == next.systemAudioEnabled,
                   old.microphoneEchoCancellationEnabled == next.microphoneEchoCancellationEnabled,
                   old.systemAudioApplicationID == next.systemAudioApplicationID,
                   old.displayID == next.displayID, old.windowID == next.windowID,
                   old.showStreamAppWindows == next.showStreamAppWindows,
                   old.teleprompterInCapture == next.teleprompterInCapture,
                   old.includeMenuBar == next.includeMenuBar,
                   old.privacyShieldEnabled == next.privacyShieldEnabled,
                   old.excludedApplicationIDs == next.excludedApplicationIDs, old.excludedWindowIDs == next.excludedWindowIDs,
                   let inputs = previewInputs {
                    previewConfiguration = next
                    // Scene, webcam, and chat changes add or remove only that source; the microphone,
                    // renderer, and preview surface stay up, so the change plays live instead of blanking.
                    let mode = videoPreviewMode, token = previewGeneration
                    let cameraChanged = old.cameraEnabled != next.cameraEnabled || old.cameraID != next.cameraID
                    if cameraChanged { videoPreviewError = nil }
                    if cameraChanged, let camera = previewCamera {
                        // Off is immediate: the renderer drops the webcam before the device closes.
                        var hidden = old; hidden.cameraEnabled = false; inputs.configure(hidden)
                        previewCamera = nil; cameraStatus = nil
                        await camera.stop()
                        inputs.setCamera(nil)
                    }
                    if cameraChanged, mode != nil, next.cameraEnabled, !previewSynthetic, previewCamera == nil {
                        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                            let camera = makeCamera(inputs: inputs)
                            previewCamera = camera
                            do { try await camera.start(id: next.cameraID); cameraStatus = nil }
                            catch { if previewCamera === camera { previewCamera = nil }; videoPreviewError = error.localizedDescription }
                        } else {
                            videoPreviewError = "Camera access is off."
                        }
                    }
                    // A rebuild or teardown during the awaits owns the preview now.
                    guard token == previewGeneration, previewInputs === inputs else { return }
                    if mode == .program, !previewSynthetic,
                       old.chatEnabled != next.chatEnabled || old.twitchChatChannel != next.twitchChatChannel {
                        previewChat?.stop(); previewChat = nil; inputs.setChat(nil)
                        if next.chatEnabled {
                            previewChat = Chat(onImage: { image in inputs.setChat(image) }, channel: next.twitchChatChannel, size: SceneGeometry.chatSize(next), appearance: next.chatAppearance)
                        }
                    }
                    // Redraw the chat page for its next slot before the scene moves (see `Chat.resize`).
                    previewChat?.resize(to: SceneGeometry.chatSize(next))
                    let wantsScreen = !previewSynthetic && mode == .program && next.layout.showsDesktop
                    if wantsScreen, previewStream == nil {
                        // The current scene keeps playing until the desktop's first frame is ready.
                        let mark = inputs.screenMark()
                        guard await addPreviewScreen(next) else { return }
                        await inputs.waitForScreen(after: mark)
                        guard token == previewGeneration, previewInputs === inputs else { return }
                    }
                    let leftScreen = wantsScreen ? nil : previewStream
                    if leftScreen != nil { previewStream = nil; previewScreenOptions = nil }
                    if old.dockFitRegion != next.dockFitRegion, mode == .program,
                       next.layout.showsDesktop, let stream = previewStream, let options = previewScreenOptions {
                        setCaptureGeometry(options, rect: previewScreenRect, scale: previewScreenScale, configuration: next, inputs: inputs)
                        try await stream.updateConfiguration(options)
                    }
                    previewOutput?.configurePreview(next)
                    inputs.configure(next)
                    previewChat?.updateAppearance(next.chatAppearance)
                    // Stop after the layout change so the last desktop frame carries the transition out.
                    if let leftScreen { try? await leftScreen.stopCapture() }
                } else {
                    previewConfiguration = next
                    await reconcileMenuPreview()
                }
            }
            return
        }
        previewConfiguration = next
        let old = configuration
        guard old.privacyShieldEnabled == next.privacyShieldEnabled,
              old.privacyHidesPersonalInfo == next.privacyHidesPersonalInfo else {
            throw EngineError.message("Stop the session before changing Privacy shield settings")
        }
        do {
            if !next.cameraEnabled {
                var hidden = old; hidden.cameraEnabled = false; inputs?.configure(privacyMasked(hidden)); requestedMask = nil
            }
            if !synthetic {
                if next.layout.showsDesktop && next.displayID == nil && next.windowID == nil { throw EngineError.message("Choose a display or window before switching to \(next.layout.title)") }
                if old.cameraEnabled != next.cameraEnabled || old.cameraID != next.cameraID {
                    inputs?.setCamera(nil)
                    if let camera { await camera.stop(); self.camera = nil; cameraStatus = nil }
                    if next.cameraEnabled { try await startCamera(next) }
                }
                // Desktop ↔ Split keeps the running screen stream; only showing or hiding the desktop restarts it.
                let sourceChanged = old.displayID != next.displayID || old.windowID != next.windowID
                if next.layout.showsDesktop && (!old.layout.showsDesktop || sourceChanged) {
                    // Make before break: the current scene stays on air until the incoming desktop's
                    // first frame can be drawn, so the switch never shows a stale or missing desktop.
                    let mark = inputs?.screenMark() ?? 0
                    try await configureScreen(next)
                    await inputs?.waitForScreen(after: mark)
                    if stopping { return }
                } else if next.layout.showsDesktop, old.dockFitRegion != next.dockFitRegion, let stream, let options = screenOptions {
                    setCaptureGeometry(options, rect: screenRect, scale: screenScale, configuration: next, inputs: inputs)
                    try await stream.updateConfiguration(options)
                }
                if old.systemAudioEnabled != next.systemAudioEnabled || old.systemAudioApplicationID != next.systemAudioApplicationID {
                    try await configureSystemAudio(next)
                } else if old.microphoneEnabled != next.microphoneEnabled || old.microphoneEchoCancellationEnabled != next.microphoneEchoCancellationEnabled {
                    try await configureEchoReference(next)
                }
                if old.chatEnabled != next.chatEnabled || old.twitchChatChannel != next.twitchChatChannel { configureChat(next) }
                chat?.resize(to: SceneGeometry.chatSize(next))
                chat?.updateAppearance(next.chatAppearance)
                if old.showStreamAppWindows != next.showStreamAppWindows || old.teleprompterInCapture != next.teleprompterInCapture || old.includeMenuBar != next.includeMenuBar || old.excludedApplicationIDs != next.excludedApplicationIDs || old.excludedWindowIDs != next.excludedWindowIDs {
                    try await updateCaptureFilter(next)
                }
            }
            // The mixer masks this with the newest request, so an older queued change cannot unmute Away.
            try await output?.updateAudio(configuration: next)
            configuration = next; inputs?.configure(privacyMasked(next)); requestedMask = nil
            // Leaving the desktop: the scene changes first, so its last frame carries the change out,
            // then screen capture stops.
            if !synthetic, old.layout.showsDesktop, !next.layout.showsDesktop { try await configureScreen(next, preserveFrame: true) }
        } catch {
            errorMessage = error.localizedDescription
            await stop(); status = "Failed"
            throw error
        }
    }
    private func privacyMasked(_ c: StudioConfiguration) -> StudioConfiguration {
        requestedConfiguration.map { c.hiding(as: $0) } ?? c
    }
    func stop() async {
        if stopping { return }
        stopping = true; generation &+= 1
        monitor?.cancel(); monitor = nil
        status = "Stopping"
        chat?.stop(); chat = nil
        audioApplications = []
        // Render through the stop content time, then release video capture. Keep audio
        // and the AEC reference alive for advanced sources and the PCM tail.
        var videoFrames: Int64?
        if let renderer {
            let output = self.output
            do { videoFrames = try await renderer.finish { output?.prepareToStop(videoFrames: $0) } }
            catch { if errorMessage == nil { errorMessage = "Could not finalize video: \(error.localizedDescription)" } }
            self.renderer = nil
        }
        if let camera { await camera.stop(); self.camera = nil; cameraStatus = nil }
        if let stream { try? await stream.stopCapture(); self.stream = nil }
        if let output {
            await output.stop(videoFrames: videoFrames)
            if errorMessage == nil { errorMessage = output.errorMessage }
            // Rendered ticks are exact at 30 fps; FFmpeg's last progress report can trail by a second or more.
            let seconds = videoFrames.map { Double($0) / 30 } ?? output.mediaSeconds
            // A start that failed before media flowed keeps the previous result.
            if let url = output.recordingURL, seconds > 0,
               let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value, bytes > 0 {
                lastRecording = RecordingResult(url: url, bytes: bytes, seconds: seconds, complete: errorMessage == nil)
            }
            self.output = nil
        }
        if let audioStream { try? await audioStream.stopCapture(); self.audioStream = nil }
        if let referenceStream { try? await referenceStream.stopCapture(); self.referenceStream = nil }
        inputs = nil; bridge = nil; previewFrames.publish(nil)
        audioBridge = nil
        referenceBridge = nil; echoCancellationStatus = nil
        privacyStatus = nil
        microphoneStatus = nil
        resolvedMicrophoneID = nil
        meters.clear()
        isRunning = false; starting = false; stopping = false
        if let sessionActivity { ProcessInfo.processInfo.endActivity(sessionActivity); self.sessionActivity = nil }
        reconcileCursorAvoidance()
        status = errorMessage == nil ? "Idle" : "Failed"
        await reconcileMenuPreview()
    }
    /// Sessions and previews allocate frame-rate transient buffers; return the allocator's freed pages after teardown
    /// (`stop()` reaches here through `reconcileMenuPreview`) so an idle menu-bar app does not keep its session peak.
    private static func releaseFreedMemory() { _ = malloc_zone_pressure_relief(nil, 0) }
    private func ensureCurrent(_ session: UInt64) throws {
        guard generation == session, !stopping else { throw CancellationError() }
    }
    private func configureChat(_ c: StudioConfiguration) {
        guard let inputs else { return }
        if !c.chatEnabled {
            chat?.stop(); chat = nil; inputs.setChat(nil)
            return
        }
        if chat != nil, configuration.twitchChatChannel == c.twitchChatChannel { return }
        chat?.stop()
        self.chat = Chat(onImage: { image in inputs.setChat(image) }, channel: c.twitchChatChannel, size: SceneGeometry.chatSize(c), appearance: c.chatAppearance)
    }
    func refreshCaptureFilter() async throws {
        try await updateCaptureFilter(desiredConfiguration)
        if let previewStream, !previewSynthetic {
            let revision = previewGeneration
            let filter = try await captureFilter(previewConfiguration, inputs: previewInputs)
            guard revision == previewGeneration, previewStream === self.previewStream else { return }
            try await previewStream.updateContentFilter(filter)
            guard revision == previewGeneration, previewStream === self.previewStream,
                  let options = previewScreenOptions else { return }
            setCaptureGeometry(options, rect: filter.contentRect, scale: CGFloat(filter.pointPixelScale), configuration: previewConfiguration, inputs: previewInputs)
            try await previewStream.updateConfiguration(options)
            guard revision == previewGeneration, previewStream === self.previewStream else { return }
            previewScreenRect = filter.contentRect
            previewScreenScale = CGFloat(filter.pointPixelScale)
        }
    }
    private func updateCaptureFilter(_ c: StudioConfiguration) async throws {
        guard let stream, !synthetic else { return }
        captureFilterRevision &+= 1
        let revision = captureFilterRevision
        let session = generation
        let previous = captureFilterUpdate
        let update = Task { [weak self] in
            _ = try? await previous?.value
            guard let self, generation == session, !stopping, stream === self.stream else { return }
            let filter = try await captureFilter(c, inputs: inputs)
            guard generation == session, !stopping, stream === self.stream else { return }
            try await stream.updateContentFilter(filter)
            guard generation == session, !stopping, stream === self.stream, let options = screenOptions else { return }
            setCaptureGeometry(options, rect: filter.contentRect, scale: CGFloat(filter.pointPixelScale), configuration: c, inputs: inputs)
            try await stream.updateConfiguration(options)
            guard generation == session, !stopping, stream === self.stream else { return }
            screenRect = filter.contentRect
            screenScale = CGFloat(filter.pointPixelScale)
        }
        captureFilterUpdate = update
        defer { if revision == captureFilterRevision { captureFilterUpdate = nil } }
        try await update.value
    }
    private func captureFilter(_ c: StudioConfiguration, inputs: RenderInputs?, content shared: ShareableContentOnce? = nil) async throws -> SCContentFilter {
        let content = try await ShareableContentOnce.content(shared)
        if let id = c.windowID {
            guard id != cameraArrangeWindowID else { throw EngineError.message("The webcam arrangement handle is private. Choose another source.") }
            guard !teleprompterWindowIDs.contains(id) || c.teleprompterInCapture else {
                throw EngineError.message("The teleprompter is private. Choose another capture source.")
            }
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw EngineError.message("Selected window is no longer available") }
            guard !c.excludedWindowIDs.contains(id), !c.excludedApplicationIDs.contains(window.owningApplication?.bundleIdentifier ?? "") else {
                throw EngineError.message("The selected capture source is excluded. Choose another source or remove its exclusion.")
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
        let id = c.displayID ?? 0
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw EngineError.message("Select an available display") }
        let excluded = Set(c.excludedApplicationIDs)
        let applications = content.applications.filter {
            // Exclude our process even with “Show StreamApp windows” enabled,
            // then allow known windows individually. New/private panels fail closed.
            $0.processID == ProcessInfo.processInfo.processIdentifier || excluded.contains($0.bundleIdentifier)
        }
        let excludedPIDs = Set(applications.map(\.processID))
        var hiddenWindows: Set<CGWindowID> = []
        let exceptions = content.windows.filter { window in
            let owner = window.owningApplication?.processID ?? -1
            let visible = CaptureWindowPolicy.isVisible(
                windowID: window.windowID, isOwnWindow: owner == ProcessInfo.processInfo.processIdentifier,
                applicationExcluded: excluded.contains(window.owningApplication?.bundleIdentifier ?? ""), configuration: c,
                annotationWindowID: annotationWindowID, teleprompterWindowIDs: teleprompterWindowIDs,
                cameraArrangeWindowID: cameraArrangeWindowID)
            if !visible { hiddenWindows.insert(window.windowID) }
            return excludedPIDs.contains(owner) == visible
        }
        inputs?.setCaptureExcludedWindows(hiddenWindows)
        let filter = SCContentFilter(display: display, excludingApplications: applications, exceptingWindows: exceptions)
        filter.includeMenuBar = c.includeMenuBar
        return filter
    }

    private func audioCaptureFilter(_ c: StudioConfiguration, content shared: ShareableContentOnce? = nil) async throws -> (filter: SCContentFilter, applications: [NSRunningApplication]) {
        let content = try await ShareableContentOnce.content(shared)
        let displayID = c.displayID ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw EngineError.message("No display is available for system audio capture")
        }
        if !c.systemAudioApplicationID.isEmpty {
            let apps = content.applications.filter { $0.bundleIdentifier == c.systemAudioApplicationID }
            guard !apps.isEmpty else { throw EngineError.message("Selected audio application is not running: \(c.systemAudioApplicationID)") }
            let running = apps.compactMap { NSRunningApplication(processIdentifier: $0.processID) }
            guard running.count == apps.count, !running.contains(where: \.isTerminated) else {
                throw EngineError.message("Selected audio application quit. Reopen it and restart capture.")
            }
            return (SCContentFilter(display: display, including: apps, exceptingWindows: []), running)
        }
        let current = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        return (SCContentFilter(display: display, excludingApplications: current, exceptingWindows: []), [])
    }
    private func audioStreamConfiguration() -> SCStreamConfiguration {
        let options = SCStreamConfiguration()
        // Match SCK's screen-backed audio path, but discard its tiny video frames.
        options.width = 2; options.height = 2
        options.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        options.capturesAudio = true; options.excludesCurrentProcessAudio = true
        options.sampleRate = 48_000; options.channelCount = 2
        return options
    }
    private func setCaptureGeometry(_ options: SCStreamConfiguration, rect full: CGRect, scale pixelScale: CGFloat, configuration c: StudioConfiguration, inputs: RenderInputs?) {
        let rect = captureRegion(full, configuration: c)
        let size = DisplayCaptureGeometry.outputSize(region: rect, pixelScale: pixelScale)
        options.sourceRect = c.windowID == nil ? rect : .zero
        options.width = Int(size.width)
        options.height = Int(size.height)
        let display = c.displayID.map { CGDisplayBounds($0) } ?? .zero
        let global = c.windowID == nil ? rect.offsetBy(dx: display.minX, dy: display.minY) : full
        inputs?.setCaptureGeometry(CaptureGeometry(size: size, globalRect: global, tracksWindows: c.windowID == nil))
    }

    private func configureScreen(_ c: StudioConfiguration, preserveFrame: Bool = false, content: ShareableContentOnce? = nil) async throws {
        if let stream { try await stream.stopCapture(); self.stream = nil }
        let session = generation
        if !preserveFrame { inputs?.setScreen(nil) }
        guard c.layout.showsDesktop else { return }
        guard CGPreflightScreenCaptureAccess() else { throw EngineError.message("Grant Screen Recording access in Settings before enabling screen capture") }
        guard let bridge else { throw EngineError.message("Capture is not initialized") }
        let filter = try await captureFilter(c, inputs: inputs, content: content)
        let options = SCStreamConfiguration()
        setCaptureGeometry(options, rect: filter.contentRect, scale: CGFloat(filter.pointPixelScale), configuration: c, inputs: inputs)
        screenOptions = options; screenRect = filter.contentRect; screenScale = CGFloat(filter.pointPixelScale)
        // The shield reads luma and keeps exact copies, so it takes 420f straight from the stream.
        options.pixelFormat = c.privacyShieldEnabled ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_32BGRA
        options.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        options.queueDepth = c.privacyShieldEnabled ? 4 : 3; options.showsCursor = true; options.capturesAudio = false
        let stream = SCStream(filter: filter, configuration: options, delegate: bridge)
        try stream.addStreamOutput(bridge, type: .screen, sampleHandlerQueue: bridge.queue)
        try await stream.startCapture()
        guard session == generation, !stopping else { try? await stream.stopCapture(); throw CancellationError() }
        self.stream = stream
    }
    private func needsEchoReference(_ c: StudioConfiguration) -> Bool {
        c.microphoneEnabled && c.microphoneEchoCancellationEnabled
    }

    private struct AudioStreams {
        var system: SCStream?
        var systemBridge: CaptureBridge?
        var reference: SCStream?
        var referenceBridge: CaptureBridge?
        var applications: [NSRunningApplication] = []
        var streams: [SCStream] { [system, reference].compactMap { $0 } }
    }

    private func startAudioStreams(_ c: StudioConfiguration, inputs: RenderInputs, output: MediaOutput, content: ShareableContentOnce? = nil) async throws -> AudioStreams {
        var result = AudioStreams()
        let echo = needsEchoReference(c)
        guard c.systemAudioEnabled || echo else { return result }
        if c.systemAudioEnabled && !CGPreflightScreenCaptureAccess() {
            throw EngineError.message("Grant Screen Recording access in Settings before enabling system audio or echo cancellation")
        }
        let shared = c.systemAudioEnabled && c.systemAudioApplicationID.isEmpty
        output.echoReferenceCaptureFailure = nil
        do {
            if c.systemAudioEnabled {
                let selection = try await audioCaptureFilter(c, content: content)
                let bridge = CaptureBridge(inputs: inputs, output: output, audioOnly: true, echoReference: shared)
                let stream = SCStream(filter: selection.filter, configuration: audioStreamConfiguration(), delegate: bridge)
                result.system = stream; result.systemBridge = bridge; result.applications = selection.applications
                try stream.addStreamOutput(bridge, type: .screen, sampleHandlerQueue: bridge.queue)
                try stream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: bridge.audioQueue)
                try await stream.startCapture()
            }
            if echo && !shared {
                let reference = await startEchoReference(c, inputs: inputs, output: output, content: content)
                result.reference = reference?.stream; result.referenceBridge = reference?.bridge
            }
            return result
        } catch {
            for stream in result.streams { try? await stream.stopCapture() }
            throw error
        }
    }

    private func startEchoReference(_ c: StudioConfiguration, inputs: RenderInputs, output: MediaOutput, content: ShareableContentOnce? = nil) async -> (stream: SCStream, bridge: CaptureBridge)? {
        var startedStream: SCStream?
        do {
            guard CGPreflightScreenCaptureAccess() else {
                throw EngineError.message("Allow Screen Recording in Settings for echo cancellation")
            }
            var allApps = c; allApps.systemAudioApplicationID = ""
            let selection = try await audioCaptureFilter(allApps, content: content)
            let bridge = CaptureBridge(inputs: inputs, output: output, audioOnly: true, echoReference: true, referenceOnly: true)
            let stream = SCStream(filter: selection.filter, configuration: audioStreamConfiguration(), delegate: bridge)
            startedStream = stream
            try stream.addStreamOutput(bridge, type: .screen, sampleHandlerQueue: bridge.queue)
            try stream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: bridge.audioQueue)
            try await stream.startCapture()
            output.echoReferenceCaptureFailure = nil
            return (stream, bridge)
        } catch {
            if let startedStream { try? await startedStream.stopCapture() }
            output.echoReferenceCaptureFailure = "Bypassed: playback reference unavailable. \(error.localizedDescription)"
            return nil
        }
    }

    /// A microphone/AEC-only change never interrupts the broadcast system bus.
    private func configureEchoReference(_ c: StudioConfiguration) async throws {
        let session = generation
        let needsSeparate = needsEchoReference(c) && !(c.systemAudioEnabled && c.systemAudioApplicationID.isEmpty)
        guard let inputs, let output else { throw EngineError.message("Capture is not initialized") }
        output.echoReferenceCaptureFailure = nil
        if !needsSeparate {
            let old = referenceStream; referenceStream = nil; referenceBridge = nil
            if let old { try? await old.stopCapture() }
            try ensureCurrent(session)
            return
        }
        guard referenceStream == nil else { return }
        let reference = await startEchoReference(c, inputs: inputs, output: output)
        guard session == generation, !stopping else {
            if let reference { try? await reference.stream.stopCapture() }
            throw CancellationError()
        }
        referenceStream = reference?.stream; referenceBridge = reference?.bridge
    }

    private func configureSystemAudio(_ c: StudioConfiguration, content: ShareableContentOnce? = nil) async throws {
        audioRevision &+= 1
        let revision = audioRevision
        let session = generation
        let oldSystem = audioStream; audioStream = nil
        let oldReference = referenceStream; referenceStream = nil
        audioApplications = []; audioBridge = nil; referenceBridge = nil
        if let oldSystem { try await oldSystem.stopCapture() }
        if let oldReference { try await oldReference.stopCapture() }
        try ensureCurrent(session)
        guard let inputs, let output else { throw EngineError.message("Capture is not initialized") }
        let audio = try await startAudioStreams(c, inputs: inputs, output: output, content: content)
        guard session == generation, revision == audioRevision, !stopping else {
            for stream in audio.streams { try? await stream.stopCapture() }
            throw CancellationError()
        }
        audioStream = audio.system; audioBridge = audio.systemBridge
        referenceStream = audio.reference; referenceBridge = audio.referenceBridge
        audioApplications = audio.applications
    }
    private func startCamera(_ c: StudioConfiguration) async throws {
        guard let inputs else { throw EngineError.message("Capture is not initialized") }
        let camera = makeCamera(inputs: inputs)
        let session = generation
        try await camera.start(id: c.cameraID)
        guard session == generation, !stopping else { await camera.stop(); throw CancellationError() }
        self.camera = camera
        cameraStatus = nil
    }
    private func makeCamera(inputs: RenderInputs) -> CameraCapture {
        CameraCapture(inputs: inputs) { [weak self] capture, status in
            Task { @MainActor [weak self] in
                guard let self, capture === self.camera || capture === self.previewCamera else { return }
                self.cameraStatus = status
            }
        }
    }
}

/// Lets the screen and audio filters of one session start share a single ScreenCaptureKit
/// enumeration; later updates still enumerate fresh.
@MainActor
final class ShareableContentOnce {
    private var content: SCShareableContent?
    static func content(_ shared: ShareableContentOnce?) async throws -> SCShareableContent {
        guard let shared else { return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
        if let content = shared.content { return content }
        let fresh = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        shared.content = fresh
        return fresh
    }
}

/// Explicit private-window rules take precedence over the broad app visibility toggle.
enum CaptureWindowPolicy {
    static func isVisible(windowID: CGWindowID, isOwnWindow: Bool, applicationExcluded: Bool,
                          configuration c: StudioConfiguration, annotationWindowID: CGWindowID?,
                          teleprompterWindowIDs: Set<CGWindowID>, cameraArrangeWindowID: CGWindowID? = nil) -> Bool {
        if windowID == cameraArrangeWindowID { return false }
        if teleprompterWindowIDs.contains(windowID) {
            return c.teleprompterInCapture && !c.excludedWindowIDs.contains(windowID)
        }
        if windowID == annotationWindowID { return true }
        if applicationExcluded || c.excludedWindowIDs.contains(windowID) { return false }
        return !isOwnWindow || c.showStreamAppWindows
    }
}

private final class CaptureBridge: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "streamapp.screen", qos: .userInitiated)
    let audioQueue = DispatchQueue(label: "streamapp.system-audio", qos: .userInitiated)
    private let inputs: RenderInputs
    private let output: MediaOutput
    private let audioOnly: Bool
    private let echoReference: Bool
    private let referenceOnly: Bool
    init(inputs: RenderInputs, output: MediaOutput, audioOnly: Bool = false, echoReference: Bool = false, referenceOnly: Bool = false) {
        self.inputs = inputs; self.output = output; self.audioOnly = audioOnly
        self.echoReference = echoReference; self.referenceOnly = referenceOnly
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if echoReference { output.appendEchoReference(sample) }
            if !referenceOnly { output.appendSystemAudio(sample) }
            return
        }
        guard !audioOnly, type == .screen, let image = sample.imageBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              (attachments.first?[.status] as? NSNumber)?.intValue == SCFrameStatus.complete.rawValue else { return }
        inputs.setScreen(image, captured: CMSampleBufferGetPresentationTimeStamp(sample).seconds)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // A reference-only failure must not stop or mute the user's microphone.
        // The mixer bypasses when its timestamped reference runs out.
        if !referenceOnly { inputs.fail("Capture stream stopped. Check permissions and selected sources, then restart.") }
    }
}

/// One camera for the life of a session or preview. Device loss suspends the frame and
/// reports a status; it never fails the session. The same device (or, for Automatic,
/// any camera) coming back resumes capture on its own.
private final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "streamapp.camera", qos: .userInitiated)
    private let inputs: RenderInputs
    private let onStatus: @Sendable (CameraCapture, String?) -> Void
    private var session: AVCaptureSession?
    private var device: AVCaptureDevice?
    private var requestedID = ""
    private var active = false
    private var observers: [NSObjectProtocol] = []
    private let startLock = NSLock()
    private var startCancelled = false
    func cancelStart() {
        startLock.lock(); startCancelled = true; startLock.unlock()
    }
    private func checkStart() throws {
        startLock.lock(); let cancelled = startCancelled; startLock.unlock()
        if cancelled { throw CancellationError() }
    }
    init(inputs: RenderInputs, onStatus: @escaping @Sendable (CameraCapture, String?) -> Void) {
        self.inputs = inputs; self.onStatus = onStatus
    }
    func start(id: String) async throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { throw EngineError.message("Camera access is off.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in queue.async {
            do {
                try self.checkStart()
                self.requestedID = id
                let session = try self.openSession()
                try self.checkStart()
                try self.run(session)
                self.active = true
                self.observe()
                continuation.resume()
            } catch { self.closeSession(); continuation.resume(throwing: error) }
        } }
    }
    func stop() async {
        cancelStart()
        await withCheckedContinuation { continuation in queue.async {
            self.active = false
            self.observers.forEach(NotificationCenter.default.removeObserver); self.observers = []
            self.closeSession()
            continuation.resume()
        } }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let session, session.outputs.contains(where: { $0 === output }),
              let clock = session.synchronizationClock, let image = sampleBuffer.imageBuffer else { return }
        let hostTime = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                                        from: clock, to: CMClockGetHostTimeClock())
        guard hostTime.isNumeric else { return }
        inputs.setCamera(image, captured: hostTime.seconds)
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private static func device(for id: String) -> AVCaptureDevice? {
        // Device lists load lazily, so camera start must itself run the discovery that publishes
        // Continuity Camera devices before resolving a saved or system-preferred camera.
        let discovered = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                          mediaType: .video, position: .unspecified).devices
        let device = id.isEmpty ? (AVCaptureDevice.systemPreferredCamera ?? AVCaptureDevice.default(for: .video))
            : discovered.first { $0.uniqueID == id } ?? AVCaptureDevice(uniqueID: id)
        return device?.isConnected == true ? device : nil
    }
    /// Queue-confined. Builds a configured, not yet running session for the requested device.
    private func openSession() throws -> AVCaptureSession {
        guard let device = Self.device(for: requestedID) else { throw EngineError.message("Selected camera is unavailable") }
        let session = AVCaptureSession(); session.beginConfiguration()
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw EngineError.message("Cannot open camera") }; session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        // Native YUV avoids a per-frame BGRA conversion; Core Image reads biplanar buffers directly.
        let available = output.availableVideoPixelFormatTypes
        let format = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            .first { available.contains($0) } ?? kCVPixelFormatType_32BGRA
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
        output.alwaysDiscardsLateVideoFrames = true; output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw EngineError.message("Cannot configure camera") }; session.addOutput(output)
        session.commitConfiguration()
        Self.capFrameRate(device)
        self.session = session; self.device = device
        return session
    }
    /// The renderer runs at 30 fps; faster camera formats only burn ISP and memory bandwidth.
    private static func capFrameRate(_ device: AVCaptureDevice) {
        let target = CMTime(value: 1, timescale: 30)
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameDuration <= target && target <= $0.maxFrameDuration }),
              (try? device.lockForConfiguration()) != nil else { return }
        device.activeVideoMinFrameDuration = target
        device.unlockForConfiguration()
    }
    private func run(_ session: AVCaptureSession) throws {
        session.startRunning()
        guard session.isRunning else { throw EngineError.message("Camera failed to start") }
    }
    private func closeSession() {
        session?.stopRunning(); session = nil; device = nil
        inputs.setCamera(nil)
    }
    private func resume(failure: String) {
        do { try run(try openSession()); onStatus(self, nil) }
        catch { closeSession(); onStatus(self, failure) }
    }
    private func observe() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
                guard let self, let id = (note.object as? AVCaptureDevice)?.uniqueID else { return }
                queue.async { self.deviceDisconnected(id) }
            },
            center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil) { [weak self] note in
                guard let self, let id = (note.object as? AVCaptureDevice)?.uniqueID else { return }
                queue.async { self.deviceConnected(id) }
            },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: nil) { [weak self] note in
                guard let self, let session = note.object as? AVCaptureSession else { return }
                let failed = ObjectIdentifier(session)
                queue.async { self.sessionFailed(failed) }
            }
        ]
    }
    private static let disconnected = "Camera disconnected — reconnect to resume"
    private func deviceDisconnected(_ id: String) {
        guard active, id == device?.uniqueID else { return }
        closeSession()
        if requestedID.isEmpty { resume(failure: Self.disconnected) } else { onStatus(self, Self.disconnected) }
    }
    private func deviceConnected(_ id: String) {
        guard active, session == nil, requestedID.isEmpty || requestedID == id else { return }
        resume(failure: "Camera unavailable — reconnect to resume")
    }
    private func sessionFailed(_ failed: ObjectIdentifier) {
        guard active, let session, ObjectIdentifier(session) == failed else { return }
        closeSession()
        onStatus(self, "Camera stopped — turn Webcam off and on to retry")
    }
}

enum EngineError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
