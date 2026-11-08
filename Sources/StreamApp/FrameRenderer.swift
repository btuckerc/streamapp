import AppKit
import ImageIO
import CoreImage
import CoreMedia
import CoreVideo
import CoreText
import Metal

/// Live slots off/idle; bounded app-owned history during shielded output.
final class RenderInputs: @unchecked Sendable {
    struct Snapshot {
        let configuration: StudioConfiguration
        let screen: CVPixelBuffer?
        let plan: PrivacyTimeline.Plan
        let camera: CVPixelBuffer?
        let chat: CGImage?
        let backgroundImage: CGImage?
        let awayCard: AwayCardBake?
        let generation: UInt64
        let sourceGeneration: UInt64
        let cameraDrag: CameraAnchor?
        let cameraDodge: CameraAnchor?
    }
    private let lock = NSLock()
    private let imageQueue = DispatchQueue(label: "streamapp.background-image-loader", qos: .utility)
    private var configuration = StudioConfiguration()
    private var screen: CVPixelBuffer?
    private var camera: CVPixelBuffer?
    private var chat: CGImage?
    private var backgroundImage: CGImage?
    private var backgroundImagePath = ""
    private var imageRequest: UInt64 = 0
    private var wallpaperRequest: UInt64 = 0
    private var wallpaperSource: WallpaperSnapshotSource?
    /// The Away card is drawn off the compositor whenever its look changes, so entering Away never
    /// stalls a frame on text layout or an image decode.
    private var awayCardSpec: AwayCardSpec?
    private var awayCard: AwayCardBake?
    private func bakeAwayCard(_ spec: AwayCardSpec) {
        imageQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let current = self.awayCardSpec == spec; self.lock.unlock()
            guard current else { return }
            let backdrop = spec.imagePath.isEmpty ? nil : AwayCard.preparedBackdrop(spec.imagePath, load: Self.loadBackgroundImage)
            guard let image = AwayCard.render(spec, backdrop: backdrop) else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.awayCardSpec == spec else { return }
            self.awayCard = AwayCardBake(spec: spec, image: image); self.generation &+= 1
        }
    }
    private var generation: UInt64 = 0
    /// Bumped per screen or camera frame, separately from `generation`, so a scene that hides
    /// both can ignore them.
    private var sourceGeneration: UInt64 = 0
    private var failure: String?
    private var cameraDrag: CameraAnchor?
    private var cameraDragCommit: CameraAnchor?
    private var cameraDodge: CameraAnchor?
    func setCameraDrag(_ anchor: CameraAnchor?) {
        lock.lock(); defer { lock.unlock() }
        cameraDrag = anchor; cameraDragCommit = nil; cameraDodge = nil; generation &+= 1
    }
    func finishCameraDrag(committing anchor: CameraAnchor) {
        lock.lock(); cameraDragCommit = anchor; generation &+= 1; lock.unlock()
    }
    func setCameraDodge(_ anchor: CameraAnchor?) {
        lock.lock(); defer { lock.unlock() }
        guard cameraDodge != anchor else { return }
        cameraDodge = anchor; generation &+= 1
    }
    private let historyEnabled: Bool
    private let timeline = PrivacyTimeline()
    // Each pool is confined to its respective capture callback queue.
    private let screenPool = PrivacyBufferPool()
    private let cameraPool = PrivacyBufferPool()
    private var screenSequence: UInt64 = 0
    private var screenFrame: ScreenFrame?
    private var captureGeometry: CaptureGeometry?
    private var privacyScanner: PrivacyScanner?
    private var cameraHistory: [(time: TimeInterval, buffer: CVPixelBuffer)] = []
    private var cameraRevision: UInt64 = 0
    private var cameraConsumed = -Double.infinity
    private var excludedPIDs: Set<pid_t> = []
    private var captureExcludedWindows: Set<CGWindowID> = []
    func setCaptureExcludedWindows(_ ids: Set<CGWindowID>) {
        lock.lock(); captureExcludedWindows = ids; lock.unlock()
    }
    init(historyEnabled: Bool = false) { self.historyEnabled = historyEnabled }
    func setCaptureGeometry(_ geometry: CaptureGeometry) {
        lock.lock()
        if captureGeometry != geometry {
            captureGeometry = geometry; screenFrame = nil
            _ = timeline.reset(); generation &+= 1
        }
        lock.unlock()
    }
    func privacyTick() {
        lock.lock(); let scanner = privacyScanner
        var expired: [CheckedContinuation<Void, Never>] = []
        if !screenWaiters.isEmpty {
            for index in screenWaiters.indices { screenWaiters[index].ticks -= 1 }
            expired = screenWaiters.filter { $0.ticks <= 0 }.map(\.continuation)
            screenWaiters.removeAll { $0.ticks <= 0 }
        }
        lock.unlock()
        scanner?.tick()
        for continuation in expired { continuation.resume() }
    }
    private var screenWaiters: [(mark: UInt64, ticks: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var screenWaitsClosed = false
    /// The newest screen frame so far; pass it to `waitForScreen(after:)`.
    func screenMark() -> UInt64 { lock.lock(); defer { lock.unlock() }; return screenSequence }
    /// Returns once a screen frame newer than `mark` is what the renderer would draw (after the
    /// privacy shield's selection), or after `ticks` render ticks. Render ticks drive both, so this
    /// adds no timer; `closeScreenWaits` ends waits once no renderer will tick these inputs again.
    func waitForScreen(after mark: UInt64, ticks: Int = 45) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if screenWaitsClosed { lock.unlock(); continuation.resume(); return }
            screenWaiters.append((mark, ticks, continuation)); lock.unlock()
        }
    }
    func closeScreenWaits() {
        lock.lock(); screenWaitsClosed = true; let waiters = screenWaiters; screenWaiters = []; lock.unlock()
        for waiter in waiters { waiter.continuation.resume() }
    }
    private func resolveScreenWaiters(through sequence: UInt64) {
        lock.lock()
        guard screenWaiters.contains(where: { $0.mark < sequence }) else { lock.unlock(); return }
        let ready = screenWaiters.filter { $0.mark < sequence }.map(\.continuation)
        screenWaiters.removeAll { $0.mark < sequence }
        lock.unlock()
        for continuation in ready { continuation.resume() }
    }
    func configure(_ value: StudioConfiguration) {
        let excluded: Set<pid_t> = value.privacyShieldEnabled ? Set(value.excludedApplicationIDs.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier)
        }) : []
        lock.lock()
        // A queued configuration from before mouse-up must not restore the old position.
        if cameraDragCommit == value.cameraAnchor {
            cameraDrag = nil; cameraDragCommit = nil
        }
        if !value.cameraEnabled || value.layout != .desktopChat {
            cameraDrag = nil; cameraDragCommit = nil; cameraDodge = nil
        }
        let wallpaperChanged = configuration.backgroundStyle != value.backgroundStyle || configuration.displayID != value.displayID || configuration.windowID != value.windowID || configuration.dockFitRegion != value.dockFitRegion
        let imageChanged = configuration.backgroundStyle != value.backgroundStyle || configuration.backgroundImagePath != value.backgroundImagePath
        if (value.backgroundStyle == .mirror && wallpaperChanged) || (value.backgroundStyle != .mirror && imageChanged) {
            backgroundImage = nil
            backgroundImagePath = ""
        }
        let privacyChanged = configuration.privacyShieldEnabled != value.privacyShieldEnabled
            || configuration.privacyHidesPersonalInfo != value.privacyHidesPersonalInfo
        configuration = value; excludedPIDs = excluded
        if privacyChanged { _ = timeline.reset(); screenFrame = nil }
        if value.privacyShieldEnabled && privacyScanner == nil {
            privacyScanner = PrivacyScanner { [weak self] result in self?.timeline.complete(result) }
        }
        privacyScanner?.configure(enabled: value.privacyShieldEnabled, hidesPersonalInfo: value.privacyHidesPersonalInfo)
        generation &+= 1
        if imageChanged { imageRequest &+= 1 }
        if wallpaperChanged { wallpaperRequest &+= 1 }
        let request = imageRequest
        let wallpaperRequest = self.wallpaperRequest
        let needsSourceReset = wallpaperChanged
        if !value.cameraEnabled { camera = nil; cameraHistory.removeAll(); cameraRevision &+= 1 }
        let awaySpec = AwayCardSpec(value)
        let awayChanged = awaySpec != awayCardSpec
        if awayChanged { awayCardSpec = awaySpec }
        lock.unlock()
        if awayChanged { bakeAwayCard(awaySpec) }

        // All WallpaperAgent/AppKit work is owned by the main queue. A new
        // token makes callbacks from a previous source harmless.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.imageRequest == request, self.wallpaperRequest == wallpaperRequest else { self.lock.unlock(); return }
            let existing = self.wallpaperSource
            if value.backgroundStyle != .mirror {
                self.wallpaperSource = nil
                self.lock.unlock()
                existing?.stop()
                self.prepareImage(path: value.backgroundStyle == .image ? value.backgroundImagePath : "", request: request)
                return
            }
            if let existing, !needsSourceReset {
                self.lock.unlock()
                existing.configure(value)
                return
            }
            self.wallpaperSource = nil
            self.lock.unlock()
            existing?.stop()
            // Initial nil is synchronous; construct outside the lock.
            let source = WallpaperSnapshotSource(configuration: value) { [weak self] image in
                self?.acceptWallpaper(image, request: wallpaperRequest)
            }
            self.lock.lock()
            guard self.imageRequest == request, self.wallpaperRequest == wallpaperRequest else { self.lock.unlock(); source.stop(); return }
            self.wallpaperSource = source
            self.lock.unlock()
        }
    }
    private func prepareImage(path: String, request: UInt64) {
        lock.lock()
        guard imageRequest == request else { lock.unlock(); return }
        guard backgroundImagePath != path else { lock.unlock(); return }
        backgroundImagePath = path
        backgroundImage = nil
        generation &+= 1
        lock.unlock()
        guard !path.isEmpty else { return }
        imageQueue.async { [weak self] in
            guard let self else { return }
            let image = Self.loadBackgroundImage(at: path)
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.backgroundImagePath == path, self.imageRequest == request else { return }
            self.backgroundImage = image
            self.generation &+= 1
        }
    }
    private func acceptWallpaper(_ image: CGImage?, request: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard wallpaperRequest == request, configuration.backgroundStyle == .mirror else { return }
        backgroundImage = image
        backgroundImagePath = ""
        generation &+= 1
    }
    private static func loadBackgroundImage(at path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048
        ] as CFDictionary)
    }
    func setScreen(_ value: CVPixelBuffer?, captured: TimeInterval = CMClockGetTime(CMClockGetHostTimeClock()).seconds) {
        lock.lock()
        screen = value; sourceGeneration &+= 1
        guard let value else {
            screenFrame = nil; _ = timeline.reset()
            lock.unlock(); return
        }
        screenSequence &+= 1
        let sequence = screenSequence, epoch = timeline.currentEpoch
        let c = configuration, scanner = privacyScanner, excluded = excludedPIDs
        let excludedWindows = captureExcludedWindows
        let geometry = captureGeometry ?? CaptureGeometry(
            size: CGSize(width: CVPixelBufferGetWidth(value), height: CVPixelBufferGetHeight(value)),
            globalRect: .zero, tracksWindows: false)
        lock.unlock()
        guard c.privacyShieldEnabled else { return }
        guard Int(geometry.size.width) == CVPixelBufferGetWidth(value),
              Int(geometry.size.height) == CVPixelBufferGetHeight(value) else {
            // A queued callback from before an SCK geometry update is not new-epoch evidence.
            if historyEnabled { timeline.recordGap(at: captured, epoch: epoch) }
            return
        }
        let windows = geometry.tracksWindows ? Self.windowSnapshot(geometry: geometry, configuration: c, excluded: excluded, excludedWindows: excludedWindows) : nil
        let buffer: CVPixelBuffer
        if historyEnabled {
            guard let copy = screenPool.copy(value) else {
                timeline.recordGap(at: captured, epoch: epoch); return
            }
            buffer = copy
        } else { buffer = value }
        let record = ScreenFrame(sequence: sequence, captured: captured, buffer: buffer, windows: windows, geometry: geometry, epoch: epoch)
        lock.lock()
        guard epoch == timeline.currentEpoch else { lock.unlock(); return }
        screenFrame = record
        lock.unlock()
        if historyEnabled { timeline.record(record) }
        scanner?.submit(record)
    }
    private static func windowSnapshot(geometry: CaptureGeometry, configuration c: StudioConfiguration, excluded: Set<pid_t>, excludedWindows: Set<CGWindowID>) -> WindowSnapshot? {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return WindowSnapshot(windows: rows.compactMap { row in
            guard let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0,
                  !excluded.contains(pid), !c.excludedWindowIDs.contains(id), !excludedWindows.contains(id),
                  (pid != ownPID || c.showStreamAppWindows),
                  rect.intersects(geometry.globalRect) else { return nil }
            return WindowSnapshot.Window(id: id, frame: geometry.pixels(fromGlobal: rect),
                layer: (row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0)
        })
    }
    func setCamera(_ value: CVPixelBuffer?, captured: TimeInterval = CMClockGetTime(CMClockGetHostTimeClock()).seconds) {
        lock.lock()
        camera = value; sourceGeneration &+= 1
        guard let value else { cameraHistory.removeAll(); cameraRevision &+= 1; lock.unlock(); return }
        let keep = historyEnabled && configuration.privacyShieldEnabled && configuration.cameraEnabled
        let revision = cameraRevision
        lock.unlock()
        guard keep, let copy = cameraPool.copy(value) else { return }
        lock.lock()
        if revision == cameraRevision, configuration.cameraEnabled {
            cameraHistory.append((captured, copy))
            while cameraHistory.count > 1, cameraHistory[1].time <= cameraConsumed { cameraHistory.removeFirst() }
        }
        lock.unlock()
    }
    func setChat(_ value: CGImage?) { lock.lock(); chat = value; generation &+= 1; lock.unlock() }
    func fail(_ message: String) { lock.lock(); if failure == nil { failure = message }; lock.unlock(); closeScreenWaits() }
    var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
    func snapshot(contentTime: TimeInterval? = nil) -> Snapshot {
        lock.lock()
        let c = configuration, liveScreen = screen, liveCamera = camera, liveFrame = screenFrame, liveSequence = screenSequence
        let chat = self.chat, background = backgroundImage, away = awayCard, generation = self.generation, sourceGeneration = self.sourceGeneration
        let drag = cameraDrag, dodge = cameraDodge
        var selectedCamera = liveCamera
        if let contentTime, c.privacyShieldEnabled {
            cameraConsumed = contentTime
            while cameraHistory.count > 1, cameraHistory[1].time <= contentTime { cameraHistory.removeFirst() }
            selectedCamera = c.cameraEnabled ? cameraHistory.last { $0.time <= contentTime }?.buffer : nil
        }
        lock.unlock()
        var selectedScreen = liveScreen
        var selectedSequence: UInt64? = liveScreen == nil ? nil : liveSequence
        var plan = PrivacyTimeline.Plan()
        if c.privacyShieldEnabled {
            if let contentTime {
                let selection = timeline.select(at: contentTime)
                selectedScreen = selection.frame?.buffer; plan = selection.plan
                selectedSequence = plan.waiting ? nil : selection.frame?.sequence
            } else {
                // The preview shows only the frame its plan describes; none (reset, mismatch) shows no screen.
                selectedScreen = liveFrame?.buffer
                selectedSequence = liveFrame?.sequence
                if let liveFrame {
                    plan = timeline.preview(frame: liveFrame, now: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
                    if plan.waiting { selectedScreen = nil; selectedSequence = nil }
                }
            }
        }
        if let selectedSequence { resolveScreenWaiters(through: selectedSequence) }
        return Snapshot(configuration: c, screen: selectedScreen, plan: plan, camera: selectedCamera,
            chat: chat, backgroundImage: background, awayCard: away, generation: generation, sourceGeneration: sourceGeneration,
            cameraDrag: drag, cameraDodge: dodge)
    }
}

final class FrameRenderer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "streamapp.compositor", qos: .userInitiated)
    private let inputs: RenderInputs
    private let preview: PreviewFrames
    private let encoder: VideoEncoder?
    private let context: CIContext
    private let synthetic: Bool
    private var timer: DispatchSourceTimer?
    private var frame: Int64 = 0
    private var startedAt: TimeInterval?
    private let presentationDelay: TimeInterval
    private var stopFrames: Int64?
    private var pendingFinish: (@Sendable () -> Void)?
    private var renderedScreen: CVPixelBuffer?
    private var renderedCamera: CVPixelBuffer?
    private var renderedPlan = PrivacyTimeline.Plan()
    private let statusLock = NSLock()
    private var coveringChanges = false
    private var composite: CVPixelBuffer?
    private var previewPool: CVPixelBufferPool?
    private var renderedGeneration: UInt64?
    private var renderedSourceGeneration: UInt64?
    private var transition = SceneTransition()
    /// Static backgrounds (mirrored wallpaper, chosen image) are baked once per source/geometry
    /// change into GPU memory, so recomposed frames neither re-upload nor re-scale them.
    private struct BackgroundKey: Equatable {
        let style: BackgroundStyle
        let imageID: ObjectIdentifier?
        let canvas: CGRect
        let sourceExtent: CGRect
        let red: Double
        let green: Double
        let blue: Double
    }
    private var backgroundKey: BackgroundKey?
    /// Retained so `imageID` cannot be reused by a different image.
    private var backgroundSourceImage: CGImage?
    private var bakedBackground: CIImage?
    /// The last guard mask, rebuilt only when the plan's guards change.
    private var guardMask: (tiles: [CGRect], extent: CGRect, image: CIImage)?
    /// The latest chat snapshot, uploaded once rather than on every composed frame. When the chat
    /// page is redrawn at a new size (its slot changed scene), the previous upload is kept so the
    /// moving panel can hand over from one to the other as its size passes between them.
    private var chatSource: CGImage?
    private var chatImage: CIImage?
    private var chatPrevious: CIImage?
    private var chatPool: CVPixelBufferPool?
    private var chatPoolSize = CGSize.zero
    /// One camera-local geometry recipe, never a captured or composed frame.
    private struct CameraSurfaceKey: Equatable {
        let size: CGSize
        let radius: CGFloat
        let border: CameraBorderStyle
    }
    private struct CameraSurface {
        let key: CameraSurfaceKey
        let mask: CIImage
        let shadow: CIImage
        let ring: CIImage?
    }
    private struct CameraBorderStyle: Equatable {
        let width: CGFloat
        let red: Double
        let green: Double
        let blue: Double
    }
    private var cameraSurface: CameraSurface?
    /// The Away card uploaded to GPU memory, and the drawing it came from (retained so its identity
    /// cannot be reused).
    private var away: (source: CGImage, image: CIImage)?
    /// Chat column and Split sidebar fill.
    private let panelColor = CIImage(color: CIColor(red: 0.07, green: 0.09, blue: 0.13))
    private var renderedGeometry: SceneGeometry?
    private let extent = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let color = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Under everything: gaps a moving layout opens show the chat panels' colour, never black.
    private lazy var stage = panelColor.cropped(to: extent)
    private let black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private lazy var waiting = resident(Self.slate("WAITING FOR SOURCE", subtitle: "No screen image is being substituted", width: 1920, height: 1080, color: (0.05, 0.08, 0.12)))
    private lazy var chatWaiting = resident(Self.slate("CHAT", subtitle: "Connecting…", width: 384, height: 1080, color: (0, 0, 0), transparent: true))
    private lazy var syntheticDesktop = resident(Self.slate("SYNTHETIC DESKTOP", subtitle: "StreamApp · 1920 × 1080 · 30 fps", width: 1920, height: 1080, color: (0.03, 0.12, 0.22)))
    private lazy var syntheticFace = resident(Self.slate("SYNTHETIC CAMERA", subtitle: "No camera device is open", width: 1920, height: 1080, color: (0.28, 0.12, 0.42), textured: true))
    private lazy var syntheticChat = resident(Self.slate("# CHAT", subtitle: "Crisp over blurred video", width: 384, height: 1080, color: (0, 0, 0), transparent: true))

    init(inputs: RenderInputs, preview: PreviewFrames, outputFD: Int32?, synthetic: Bool) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw EngineError.message("Metal is unavailable") }
        self.inputs = inputs; self.preview = preview; self.synthetic = synthetic
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let configuration = inputs.snapshot().configuration
        encoder = try outputFD.map { try VideoEncoder(outputFD: $0) }
        presentationDelay = outputFD != nil && configuration.privacyShieldEnabled ? PrivacyTimeline.delay : 0
    }
    

    func start(epoch: TimeInterval) {
        startedAt = epoch
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        timer.schedule(deadline: .now() + max(0, epoch + presentationDelay - now), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.render() }
        self.timer = timer; timer.resume()
    }
    var privacyStatus: String? {
        guard presentationDelay > 0 else { return nil }
        statusLock.lock(); defer { statusLock.unlock() }
        return coveringChanges ? "Privacy shield: unresolved text placement" : "Privacy shield active · 0.5 s delay"
    }
    func finish(clearingPreview: Bool = true, onStopped: @escaping @Sendable (Int64) -> Void = { _ in }) async throws -> Int64 {
        let stoppedAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let target = self.presentationDelay > 0
                    ? Int64(ceil(max(0, stoppedAt - (self.startedAt ?? stoppedAt)) * 30)) : self.frame
                self.stopFrames = max(self.frame, target)
                onStopped(self.stopFrames!)
                self.pendingFinish = {
                    let frames = self.frame
                    self.timer?.cancel(); self.timer = nil
                    self.composite = nil; self.renderedScreen = nil; self.renderedCamera = nil
                    self.inputs.closeScreenWaits()
                    if clearingPreview { self.preview.publish(nil) }
                    continuation.resume(with: Result { try self.encoder?.finish(); return frames })
                }
                self.finishIfReady()
            }
        }
    }
    private func finishIfReady() {
        guard let stopFrames, frame >= stopFrames || inputs.error != nil else { return }
        let finish = pendingFinish; pendingFinish = nil; finish?()
    }
    private func render() {
        defer { finishIfReady() }
        guard inputs.error == nil else { return }
        if let stopFrames, frame >= stopFrames { return }
        inputs.privacyTick()
        let contentTime = presentationDelay > 0 ? (startedAt ?? 0) + Double(frame) / 30 : nil
        let snapshot = inputs.snapshot(contentTime: contentTime)
        statusLock.lock(); coveringChanges = snapshot.plan.degraded; statusLock.unlock()
        if encoder == nil {
            guard let mode = preview.mode else { return }
            if mode == .camera && !synthetic {
                preview.publish(snapshot.configuration.cameraEnabled ? snapshot.camera : nil, mirrored: snapshot.configuration.mirrorCamera)
                return
            }
        }
        do {
            let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            if startedAt == nil { startedAt = now }
            if encoder != nil && now - startedAt! - presentationDelay - Double(frame) / 30 >= 0.2 {
                throw EngineError.message("Video timing fell behind; stopping to preserve audio synchronization")
            }
            var placement = snapshot.configuration
            placement.cameraAnchor = snapshot.cameraDrag ?? snapshot.cameraDodge ?? placement.cameraAnchor
            let cameraReady = placement.cameraEnabled && (synthetic || snapshot.camera != nil)
            let target = SceneGeometry(configuration: placement, cameraReady: cameraReady)
            let dragging = snapshot.cameraDrag != nil
            let geometry = transition.sample(target: target, now: now, dragging: dragging)
            // Behind a settled Away card new screen or camera frames change nothing on screen, so the
            // last composite is re-encoded as is (chat and configuration still bump `generation`).
            let sourcesVisible = geometry.away < 1
            let sourcesChanged = sourcesVisible && (renderedSourceGeneration != snapshot.sourceGeneration
                || renderedScreen !== snapshot.screen || renderedCamera !== snapshot.camera) || renderedPlan != snapshot.plan
            if synthetic || composite == nil || renderedGeneration != snapshot.generation || renderedGeometry != geometry || sourcesChanged {
                let buffer: CVPixelBuffer
                if let encoder { buffer = try encoder.makePixelBuffer() }
                else {
                    guard let available = try makePreviewBuffer() else { return }
                    buffer = available
                }
                let image = compose(snapshot, geometry: geometry, settled: geometry == target)
                context.render(image, to: buffer, bounds: extent, colorSpace: color)
                composite = buffer
                renderedGeneration = snapshot.generation; renderedSourceGeneration = snapshot.sourceGeneration
                renderedGeometry = geometry
                renderedScreen = snapshot.screen; renderedCamera = snapshot.camera; renderedPlan = snapshot.plan
            }
            guard let composite else { throw EngineError.message("No composed frame") }
            try encoder?.encode(composite, pts: CMTime(value: frame, timescale: 30))
            frame += 1
            if let mode = preview.mode {
                switch mode {
                case .program: preview.publish(composite, program: true)
                case .camera:
                    let live = inputs.snapshot()
                    preview.publish(live.configuration.cameraEnabled ? live.camera : nil, mirrored: live.configuration.mirrorCamera)
                }
            }
        } catch { inputs.fail("Video pipeline: \(error)") }
    }
    private func compose(_ snapshot: RenderInputs.Snapshot, geometry g: SceneGeometry, settled: Bool) -> CIImage {
        let c = snapshot.configuration
        var camera = c.cameraEnabled && g.showsCamera ? (synthetic ? syntheticFace : snapshot.camera.map { CIImage(cvPixelBuffer: $0) }) : nil
        if let image = camera, c.mirrorCamera {
            camera = image.transformed(by: CGAffineTransform(translationX: image.extent.minX + image.extent.maxX, y: 0).scaledBy(x: -1, y: 1))
        }
        // Leaving Away for a desktop-less scene (Full Camera, or a webcam returning in it) only the
        // stage is under the lifting card, never a desktop frame kept from an earlier scene. A scene
        // chosen mid-lift over the Desktop morphs on from the desktop already uncovered instead.
        let stageOnly = g.away > 0 && g.overlay >= 1 && !c.layout.showsDesktop
        // A settled Away card or full-frame camera hides the desktop completely: skip its capture
        // upload, privacy redaction, and background (blur) work rather than drawing it underneath.
        let desktopHidden = stageOnly || g.away >= 1 || (camera != nil && g.overlay >= 1 && g.camera.contains(extent))
        // At rest the desktop (beside Split's column) fills the frame; the stage is needed only mid-move.
        let covered = settled && (g.desktop.contains(extent) || (g.sidebar.intersects(extent) && g.desktop.union(g.sidebar).contains(extent)))
        var image = desktopHidden ? stage : covered ? composeDesktop(snapshot, geometry: g, settled: settled)
            : composeDesktop(snapshot, geometry: g, settled: settled).composited(over: stage)
        if g.sidebar.intersects(extent) {
            image = panelColor.cropped(to: g.sidebar).composited(over: image)
        }
        if let camera, g.overlay >= 1 {
            image = fit(camera, into: g.camera, fill: true).composited(over: image)
        } else if let camera {
            let strength = max(0, min(1, 1 - g.overlay))
            let shortSide = min(g.camera.width, g.camera.height)
            let radius = (c.cameraFrame == .circle ? shortSide / 2 : shortSide * 0.08) * strength
            let border = CameraBorderStyle(width: c.cameraBorder.width * strength, red: c.cameraBorderRed, green: c.cameraBorderGreen, blue: c.cameraBorderBlue)
            let geometry = cameraSurfaceGeometry(size: g.camera.size, radius: radius, border: border)
            let placement = CGAffineTransform(translationX: g.camera.midX, y: g.camera.midY)
            let shadow = opacity(geometry.shadow, 0.18 * strength).transformed(by: placement)
            image = shadow.composited(over: image)
            if let ring = geometry.ring { image = ring.transformed(by: placement).composited(over: image) }
            let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: g.camera)
            let rounded = fit(camera, into: g.camera, fill: true)
                .applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: transparent,
                    kCIInputMaskImageKey: geometry.mask.transformed(by: placement)
                ])
            image = rounded.composited(over: image)
        }
        if g.away > 0 {
            var card = awayCard(c, baked: snapshot.awayCard)
            if g.awaySettle > 0 {
                // Landing: the card covers at once at 103% and settles to its size.
                let scale = 1 + 0.03 * g.awaySettle
                card = card.transformed(by: CGAffineTransform(translationX: extent.midX, y: extent.midY)
                    .scaledBy(x: scale, y: scale).translatedBy(x: -extent.midX, y: -extent.midY))
            }
            if g.away < 1 {
                // Leaving: the card lifts off the top, its lower edge casting a soft shadow on the scene.
                let edge = (1 - g.away) * extent.height
                card = card.transformed(by: CGAffineTransform(translationX: 0, y: edge))
                image = liftShadow.transformed(by: CGAffineTransform(translationX: 0, y: edge - Self.liftShadowHeight)).composited(over: image)
            }
            image = card.cropped(to: extent).composited(over: image)
        }
        return composeChat(snapshot, geometry: g, over: image).cropped(to: extent)
    }
    /// Chat slides in and out at full size, so it is drawn while any of it is on screen (just after
    /// it is turned off, from the last page it showed). The page is drawn 1:1, pinned to the panel's
    /// lower-left corner, so its text keeps its configured pixel size in every scene and mid-move.
    private func composeChat(_ snapshot: RenderInputs.Snapshot, geometry g: SceneGeometry, over image: CIImage) -> CIImage {
        let c = snapshot.configuration
        guard g.chat.intersects(extent), g.chat.width >= 1, g.chat.height >= 1 else {
            // Chat that is off and gone from the frame lets go of its last page and its buffers.
            if !c.chatEnabled, chatImage != nil { chatImage = nil; chatPrevious = nil; chatSource = nil; chatPool = nil }
            return image
        }
        let page: CIImage? = synthetic ? nil : c.chatEnabled ? snapshot.chat.map(residentChat) : chatImage
        var content: CIImage
        if let page {
            content = pinned(page, in: g.chat)
            if let previous = chatPrevious {
                // Changing scene redraws the page at its new slot's size. The old page shows until the
                // move is under way and the panel is wide enough for the new page's lines (only its
                // padding may still be cropped at the side), then the new one, in a single step: the two
                // layouts never show at once. The moving panel's edges still crop either page while it travels.
                let handover = Self.handover(from: previous.extent.size, to: page.extent.size, at: g.chat.size)
                if handover >= 1 || (handover > 0 && g.chat.width >= page.extent.width - Self.chatPadding) { chatPrevious = nil }
                else { content = pinned(previous, in: g.chat) }
            }
        } else if synthetic || c.chatEnabled {
            content = fit(synthetic ? syntheticChat : chatWaiting, into: g.chat, fill: false)
        } else {
            return image
        }
        var panel = panelColor.cropped(to: g.chat)
        if g.overlay > 0 {
            let glass = CIImage(color: CIColor(red: 0.025, green: 0.035, blue: 0.06, alpha: 0.48))
                .cropped(to: g.chat).composited(over: blurred(image, in: g.chat))
            panel = opacity(glass, g.overlay).composited(over: panel)
        }
        var chat = content.composited(over: panel)
        let framing = g.chatFraming
        if framing > 0 {
            // Split's card and Full Camera's panel share the webcam card's rounded corners.
            let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: g.chat)
            chat = chat.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: transparent,
                kCIInputMaskImageKey: chatMask(g.chat, radius: Self.chatRadius * framing)
            ])
        }
        if framing < 1 {
            // A flush column is separated from the desktop by a hairline on its inner edge.
            let x = c.chatOnLeft ? g.chat.maxX - 1 : g.chat.minX
            chat = opacity(divider, 1 - framing).cropped(to: CGRect(x: x, y: g.chat.minY, width: 1, height: g.chat.height)).composited(over: chat)
        }
        return chat.composited(over: image)
    }
    /// The Split webcam card's corner radius at its widescreen size (315-pixel short side × 0.08).
    private static let chatRadius: CGFloat = 25
    /// The chat page's side padding (`.messages` in chat.html): text never reaches its last 16 px.
    private static let chatPadding: CGFloat = 16
    private let divider = CIImage(color: CIColor(red: 0.32, green: 0.38, blue: 0.455))
    private static let liftShadowHeight: CGFloat = 48
    private lazy var liftShadow = CIFilter(name: "CILinearGradient", parameters: [
        "inputPoint0": CIVector(x: 0, y: Self.liftShadowHeight), "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0.35),
        "inputPoint1": CIVector(x: 0, y: 0), "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)
    ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 1920, height: Self.liftShadowHeight))
    private var chatMaskCache: (rect: CGRect, radius: CGFloat, image: CIImage)?
    private func chatMask(_ rect: CGRect, radius: CGFloat) -> CIImage {
        if let cache = chatMaskCache, cache.rect == rect, cache.radius == radius { return cache.image }
        let image = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect), kCIInputRadiusKey: radius, "inputColor": CIColor.white
        ])!.outputImage!.cropped(to: rect)
        chatMaskCache = (rect, radius, image)
        return image
    }
    /// How far a panel of size `s` has come from the old page's size `a` to the new page's `b`
    /// (along whichever side changes more); 1 once the panel is within a pixel of the new page,
    /// since WebKit can return a page a pixel off an odd slot height.
    static func handover(from a: CGSize, to b: CGSize, at s: CGSize) -> CGFloat {
        if abs(s.width - b.width) <= 1 && abs(s.height - b.height) <= 1 { return 1 }
        let dw = b.width - a.width, dh = b.height - a.height
        let p = abs(dw) >= abs(dh) ? (s.width - a.width) / dw : (s.height - a.height) / dh
        return p.isFinite ? max(0, min(1, p)) : 1
    }
    private func pinned(_ page: CIImage, in rect: CGRect) -> CIImage {
        page.transformed(by: CGAffineTransform(translationX: rect.minX - page.extent.minX, y: rect.minY - page.extent.minY)).cropped(to: rect)
    }
    /// Captured (or waiting) desktop with privacy redaction, fitted over the configured background.
    private func composeDesktop(_ snapshot: RenderInputs.Snapshot, geometry g: SceneGeometry, settled: Bool) -> CIImage {
        let c = snapshot.configuration
        var desktop = synthetic ? syntheticDesktop : snapshot.screen.map { CIImage(cvPixelBuffer: $0) } ?? waiting
        if synthetic {
            let marker = CIImage(color: CIColor(red: 0.1, green: 0.8, blue: 0.8)).cropped(to: CGRect(x: CGFloat((frame * 8) % 1800), y: 140, width: 90, height: 90))
            desktop = marker.composited(over: desktop)
        }
        if c.privacyShieldEnabled {
            // Timeline pixels use top-left origin; redact consumes normalized CI coordinates.
            func normalized(_ rects: [CGRect]) -> [CGRect] {
                rects.map { CGRect(x: $0.minX / desktop.extent.width,
                    y: 1 - $0.maxY / desktop.extent.height,
                    width: $0.width / desktop.extent.width, height: $0.height / desktop.extent.height) }
            }
            let boxes = normalized(snapshot.plan.boxes), uncertain = normalized(snapshot.plan.uncertainRows)
            desktop = Self.redact(desktop, rects: boxes, configuration: c)
            var solid = c; solid.privacyCensorStyle = .solid
            desktop = Self.redact(desktop, rects: uncertain, configuration: solid)
            if !snapshot.plan.guards.isEmpty {
                if guardMask?.tiles != snapshot.plan.guards || guardMask?.extent != desktop.extent {
                    guardMask = (snapshot.plan.guards, desktop.extent, Self.guardMask(snapshot.plan.guards, extent: desktop.extent))
                }
                if let mask = guardMask?.image { desktop = Self.guarded(desktop, mask: mask, configuration: c) }
            }
        }
        var preparedBackground: CIImage?
        if DesktopBackgroundRenderer.isStatic(c.backgroundStyle) {
            // Mid-transition the canvas moves every frame; draw the recipe directly then.
            if settled {
                let key = BackgroundKey(style: c.backgroundStyle, imageID: snapshot.backgroundImage.map { ObjectIdentifier($0) }, canvas: g.desktop, sourceExtent: desktop.extent, red: c.backgroundRed, green: c.backgroundGreen, blue: c.backgroundBlue)
                if key != backgroundKey {
                    backgroundKey = key
                    backgroundSourceImage = snapshot.backgroundImage
                    bakedBackground = Self.resident(DesktopBackgroundRenderer.background(source: desktop, in: g.desktop, configuration: c, image: snapshot.backgroundImage),
                                                    in: g.desktop, context: context, colorSpace: color)
                }
                preparedBackground = bakedBackground
            }
        } else {
            backgroundKey = nil
            backgroundSourceImage = nil
            bakedBackground = nil
        }
        return DesktopBackgroundRenderer.compose(source: desktop, in: g.desktop, configuration: c, image: snapshot.backgroundImage, preparedBackground: preparedBackground)
    }
    /// The Away card in GPU memory. `RenderInputs` draws it ahead of time; until a changed look lands
    /// the previous card stays up, and only a first card wanted before then is drawn here, without its image.
    private func awayCard(_ c: StudioConfiguration, baked: AwayCardBake?) -> CIImage {
        let spec = AwayCardSpec(c)
        let prepared = baked?.spec == spec ? baked?.image : nil
        if let away, prepared == nil || away.source === prepared { return away.image }
        guard let source = prepared ?? AwayCard.render(spec, backdrop: spec.imagePath.isEmpty ? nil : AwayCard.cachedBackdrop(spec.imagePath)) else { return black }
        let card = resident(CIImage(cgImage: source))
        away = (source, card)
        return card
    }
    private func cameraSurfaceGeometry(size: CGSize, radius: CGFloat, border: CameraBorderStyle) -> CameraSurface {
        let key = CameraSurfaceKey(size: size, radius: radius, border: border)
        if let cameraSurface, cameraSurface.key == key { return cameraSurface }
        let aperture = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        let shadowBounds = aperture.insetBy(dx: -38, dy: -38)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: shadowBounds)
        let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: aperture),
            kCIInputRadiusKey: radius,
            "inputColor": CIColor.white
        ])!.outputImage!.composited(over: clear).cropped(to: shadowBounds)
        let shadow = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 12])
            .transformed(by: CGAffineTransform(translationX: 0, y: -2))
            .cropped(to: shadowBounds)
        // The ring sits under the camera, so only its outer band (and the mask's soft edge) shows.
        let ring: CIImage? = border.width > 0.5 ? CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: aperture.insetBy(dx: -border.width, dy: -border.width)),
            kCIInputRadiusKey: radius + border.width,
            "inputColor": CIColor(red: border.red, green: border.green, blue: border.blue)
        ])!.outputImage!.cropped(to: shadowBounds) : nil
        let surface = CameraSurface(key: key, mask: mask, shadow: shadow, ring: ring)
        cameraSurface = surface
        return surface
    }
    private func opacity(_ image: CIImage, _ value: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: value)])
    }
    /// Blur only the panel plus its kernel halo, at quarter resolution on Metal.
    /// The full camera stays sharp and the chat foreground never enters this filter.
    private func blurred(_ image: CIImage, in rect: CGRect) -> CIImage {
        let region = rect.insetBy(dx: -48, dy: -48).intersection(extent)
        let small = image.cropped(to: region).clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 5])
        return small.transformed(by: CGAffineTransform(scaleX: 4, y: 4)).cropped(to: rect)
    }
    private func fit(_ image: CIImage, into rect: CGRect, fill: Bool) -> CIImage {
        let x = rect.width / image.extent.width; let y = rect.height / image.extent.height
        let scale = fill ? max(x, y) : min(x, y)
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        return normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: rect.minX + (rect.width - image.extent.width * scale) / 2, y: rect.minY + (rect.height - image.extent.height * scale) / 2)).cropped(to: rect)
    }
    private func resident(_ image: CIImage) -> CIImage {
        Self.resident(image, in: image.extent, context: context, colorSpace: color)
    }
    private func residentChat(_ source: CGImage) -> CIImage {
        if let chatImage, chatSource === source { return chatImage }
        let size = CGSize(width: source.width, height: source.height)
        if chatPool == nil || chatPoolSize != size {
            // A new size is a new scene's page: keep the one on screen for the hand-over. Its buffer
            // stays out of the new pool, so the next upload cannot overwrite it.
            if let chatImage, chatImage.extent.size != size { chatPrevious = chatImage }
            var attributes = Self.residentAttributes
            attributes[kCVPixelBufferWidthKey as String] = source.width
            attributes[kCVPixelBufferHeightKey as String] = source.height
            attributes[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_32BGRA
            chatPool = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &chatPool)
            chatPoolSize = size
        }
        let image = Self.resident(CIImage(cgImage: source), in: CGRect(origin: .zero, size: size), context: context, colorSpace: color, pool: chatPool)
        chatSource = source; chatImage = image
        return image
    }
    private static let residentAttributes: [String: Any] = [
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
    ]
    /// Renders a static layer once into an IOSurface so later frames sample GPU memory instead of
    /// re-uploading a CPU bitmap (about 1 ms of CPU per 1080p layer per frame). Falls back to the
    /// recipe itself if a buffer cannot be allocated.
    static func resident(_ image: CIImage, in rect: CGRect, context: CIContext, colorSpace: CGColorSpace, pool: CVPixelBufferPool? = nil) -> CIImage {
        let bounds = rect.integral
        guard bounds.width > 0, bounds.height > 0 else { return image }
        var buffer: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
        else { CVPixelBufferCreate(nil, Int(bounds.width), Int(bounds.height), kCVPixelFormatType_32BGRA, residentAttributes as CFDictionary, &buffer) }
        guard let buffer else { return image }
        let toOrigin = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
        context.render(image.transformed(by: toOrigin), to: buffer, bounds: CGRect(origin: .zero, size: bounds.size), colorSpace: colorSpace)
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: colorSpace])
            .transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
    }
    private static func slate(_ title: String, subtitle: String, width: Int, height: Int, color: (CGFloat, CGFloat, CGFloat), transparent: Bool = false, textured: Bool = false) -> CIImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if !transparent {
            context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        if textured {
            context.setFillColor(CGColor(red: 0.55, green: 0.3, blue: 0.65, alpha: 1))
            for x in stride(from: 0, to: width, by: 24) { context.fill(CGRect(x: x, y: 0, width: 8, height: height)) }
            context.setFillColor(CGColor(red: 0.18, green: 0.45, blue: 0.55, alpha: 1))
            for y in stride(from: 0, to: height, by: 64) { context.fill(CGRect(x: 0, y: y, width: width, height: 12)) }
        }
        for (index, (text, size, y)) in [(title, CGFloat(width > 500 ? 52 : 30), CGFloat(height) * 0.55), (subtitle, CGFloat(width > 500 ? 28 : 18), CGFloat(height) * 0.45)].enumerated() {
            let font = NSFont.systemFont(ofSize: size, weight: index == 0 ? .semibold : .regular)
            let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.9, alpha: 1)])
            let line = CTLineCreateWithAttributedString(string)
            let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.textPosition = CGPoint(x: max(12, (Double(width) - textWidth) / 2), y: y)
            CTLineDraw(line, context)
        }
        return CIImage(cgImage: context.makeImage()!)
    }
    /// Opaque cover in the configured style: no source detail survives over the detected text.
    static func redact(_ source: CIImage, rects: [CGRect], configuration c: StudioConfiguration) -> CIImage {
        let bounds = source.extent
        let color = CIColor(red: c.privacyCensorRed, green: c.privacyCensorGreen, blue: c.privacyCensorBlue)
        // Stripes alternate the chosen colour with a lighter (or, for light colours, darker) shade.
        let shift = 0.2126 * c.privacyCensorRed + 0.7152 * c.privacyCensorGreen + 0.0722 * c.privacyCensorBlue > 0.5 ? -0.25 : 0.25
        let stripe = CIColor(red: min(1, max(0, c.privacyCensorRed + shift)), green: min(1, max(0, c.privacyCensorGreen + shift)), blue: min(1, max(0, c.privacyCensorBlue + shift)))
        var output = source
        for normalized in rects {
            let rect = CGRect(x: bounds.minX + normalized.minX * bounds.width, y: bounds.minY + normalized.minY * bounds.height, width: normalized.width * bounds.width, height: normalized.height * bounds.height).intersection(bounds).integral
            guard !rect.isNull, !rect.isEmpty else { continue }
            let cover: CIImage
            switch c.privacyCensorStyle {
            case .solid:
                cover = CIImage(color: color).cropped(to: rect)
            case .rounded:
                // Interior corner cuts stay inside the scanner's padding around the text. Clipping at the
                // source edge removed that padding, so the shape extends past each edge it touches and
                // only its interior corners are rounded.
                let radius = min(rect.width, rect.height) * 0.2
                var shape = rect
                if rect.minX <= bounds.minX { shape.origin.x -= radius; shape.size.width += radius }
                if rect.maxX >= bounds.maxX { shape.size.width += radius }
                if rect.minY <= bounds.minY { shape.origin.y -= radius; shape.size.height += radius }
                if rect.maxY >= bounds.maxY { shape.size.height += radius }
                cover = (CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                    "inputExtent": CIVector(cgRect: shape), "inputRadius": radius, "inputColor": color,
                ])?.outputImage ?? CIImage(color: color)).cropped(to: rect)
            case .striped:
                cover = (CIFilter(name: "CIStripesGenerator", parameters: [
                    "inputColor0": color, "inputColor1": stripe, "inputWidth": 8, "inputSharpness": 1,
                ])?.outputImage ?? CIImage(color: color))
                    .transformed(by: CGAffineTransform(rotationAngle: .pi / 4)).cropped(to: rect)
            }
            output = cover.composited(over: output)
        }
        return output.cropped(to: bounds)
    }
    /// Guard tiles (top-left pixels on `changedTiles`' 16-pixel grid) as one mask at tile resolution,
    /// scaled up without interpolation: a constant graph however fragmented the changes, where one node
    /// per rectangle once made composition take ~70 ms at 100+ rectangles.
    static func guardMask(_ tiles: [CGRect], extent: CGRect) -> CIImage {
        let columns = Int((extent.width / 16).rounded(.up)), rows = Int((extent.height / 16).rounded(.up))
        var bytes = [UInt8](repeating: 0, count: columns * rows)
        for t in tiles {
            let top = max(0, Int(t.minY) / 16), bottom = min(rows, Int((t.maxY / 16).rounded(.up)))
            let left = max(0, Int(t.minX) / 16), right = min(columns, Int((t.maxX / 16).rounded(.up)))
            guard top < bottom, left < right else { continue }
            for row in top..<bottom { for column in left..<right { bytes[row * columns + column] = 255 } }
        }
        // Bitmap rows run top-down; Core Image's y runs up from the extent's bottom.
        return CIImage(bitmapData: Data(bytes), bytesPerRow: columns, size: CGSize(width: columns, height: rows), format: .L8, colorSpace: nil)
            .samplingNearest()
            .transformed(by: CGAffineTransform(a: 16, b: 0, c: 0, d: 16, tx: extent.minX, ty: extent.maxY - CGFloat(rows * 16)))
    }
    /// Solid censor colour wherever `mask` is set; the source elsewhere.
    static func guarded(_ source: CIImage, mask: CIImage, configuration c: StudioConfiguration) -> CIImage {
        CIImage(color: CIColor(red: c.privacyCensorRed, green: c.privacyCensorGreen, blue: c.privacyCensorBlue))
            .cropped(to: source.extent)
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: source, kCIInputMaskImageKey: mask])
            .cropped(to: source.extent)
    }

    private func makePreviewBuffer() throws -> CVPixelBuffer? {
        if previewPool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: 1920,
                kCVPixelBufferHeightKey as String: 1080,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &previewPool) == kCVReturnSuccess else {
                throw EngineError.message("Could not create preview buffers")
            }
        }
        var buffer: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 4] as CFDictionary
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, previewPool!, limits, &buffer)
        if result == kCVReturnWouldExceedAllocationThreshold { return nil }
        guard result == kCVReturnSuccess else { throw EngineError.message("Could not allocate preview frame") }
        return buffer
    }
}
