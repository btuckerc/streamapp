import AppKit
import AVFoundation
import Combine
import ImageIO
import Security
import SwiftUI
import UniformTypeIdentifiers

enum CapturePermission: CaseIterable, Hashable {
    case screen, camera, microphone
    var title: String { switch self { case .screen: "Screen Recording"; case .camera: "Camera"; case .microphone: "Microphone" } }
    var privacyPane: String { switch self { case .screen: "Privacy_ScreenCapture"; case .camera: "Privacy_Camera"; case .microphone: "Privacy_Microphone" } }
    fileprivate var mediaType: AVMediaType? { switch self { case .screen: nil; case .camera: .video; case .microphone: .audio } }
    fileprivate var configurationKey: WritableKeyPath<StudioConfiguration, Bool> {
        switch self { case .screen: \.systemAudioEnabled; case .camera: \.cameraEnabled; case .microphone: \.microphoneEnabled }
    }
}

enum CaptureAccess: Equatable { case notDetermined, allowed, denied, restricted }

@MainActor
final class StudioModel: ObservableObject {
    enum SettingsTab: Hashable, CaseIterable { case sources, audio, layout, chat, teleprompter, drawing, outputs }
    @Published var settingsTab: SettingsTab = .sources
    @Published var settingsVisible = false
    let engine = StudioEngine()
    let annotationSettings: AnnotationSettings
    let twitch: TwitchSession
    let teleprompter: TeleprompterModel
    let dockFit = DockCanvasFit()
    @Published var configuration = StudioConfiguration() {
        didSet {
            // Bindings often write back an unchanged value; don't save or reconfigure capture then.
            guard configuration != oldValue else { return }
            if configuration.streamService != oldValue.streamService { message = nil }
            if configuration.cameraEnabled, message?.hasPrefix(Self.webcamNudge) == true { message = nil }
            if configuration.microphoneID != oldValue.microphoneID {
                validateMicrophoneChannels()
            }
            if configuration.microphoneEnabled { loadDevices() }
            if configuration.layout.usesCamera && !configuration.cameraEnabled {
                configuration.awayCoversWebcam = configuration.layout.withoutCamera == .away
                configuration.layout = configuration.layout.withoutCamera
            } else if configuration.awayCoversWebcam && configuration.layout != .away {
                configuration.awayCoversWebcam = false
            }
            if (!configuration.cameraEnabled || configuration.layout != .desktopChat) && configuration.cameraPunchIn {
                configuration.cameraPunchIn = false
            }
            dockFit.configure(configuration)
            for slot in ImageSlot.allCases where configuration[keyPath: slot.path] != oldValue[keyPath: slot.path] {
                refreshImageState(slot)
            }
            if configuration.teleprompterMode != oldValue.teleprompterMode ||
                configuration.teleprompterInCapture != oldValue.teleprompterInCapture {
                hideTeleprompter?()
            }
            teleprompter.configure(configuration)
            scheduleSave()
            scheduleUpdate()
        }
    }
    @Published var sources: [CaptureSource] = []
    @Published var cameras: [DeviceOption] = []
    @Published var microphones: [DeviceOption] = []
    var selectedMicrophone: DeviceOption? {
        if !configuration.microphoneID.isEmpty { return microphones.first { $0.id == configuration.microphoneID } }
        if let id = engine.resolvedMicrophoneID { return microphones.first { $0.id == id } }
        return microphones.first(where: \.isDefaultInput)
    }
    var microphoneRouteWarning: String? {
        configuration.microphoneEnabled && selectedMicrophone?.bluetooth == true ?
            "Bluetooth microphone selected. Playback quality may drop. Disable or reselect the mic to release it; muting does not." : nil
    }
    private func validateMicrophoneChannels() {
        guard let device = selectedMicrophone, device.inputChannels > 0 else { return }
        configuration.microphoneChannels = configuration.microphoneChannels.validated(channelCount: device.inputChannels)
    }
    @Published var busy = false
    /// What a session start or stop is waiting on, for the session button.
    enum SessionStage: Equatable {
        case streamKey, starting, stopping(recording: Bool)
        var title: String {
            switch self {
            case .streamKey: "Getting key…"
            case .starting: "Starting…"
            case .stopping(let recording): recording ? "Saving…" : "Stopping…"
            }
        }
    }
    @Published private(set) var sessionStage: SessionStage?
    private(set) var startTask: Task<Void, Never>?
    @Published var message: String?
    @Published var streamKey = ""
    @Published var keySaved = false
    @Published private(set) var rehearsalActive = false
    @Published private(set) var captureAccess = StudioModel.currentAccess()
    /// Stored independently from the Codable broadcast settings for safe schema evolution.
    @Published private(set) var onboardingCompleted: Bool
    let demo: Bool
    /// Pictures the user imports: the scene background and the Away card's backdrop.
    enum ImageSlot: CaseIterable {
        case background, away
        var path: WritableKeyPath<StudioConfiguration, String> {
            switch self { case .background: \.backgroundImagePath; case .away: \.awayImagePath }
        }
        var missing: String {
            switch self { case .background: "Image unavailable; using the fallback color."; case .away: "Image unavailable; using Dark." }
        }
    }
    @Published private(set) var imageErrors: [ImageSlot: String] = [:]
    @Published private(set) var importingImages: Set<ImageSlot> = []
    private var imageImportGeneration: [ImageSlot: Int] = [:]
    func access(_ permission: CapturePermission) -> CaptureAccess { captureAccess[permission] ?? .notDetermined }
    /// Permissions the current configuration needs but lacks.
    var captureAccessIssues: [CapturePermission] {
        guard !demo else { return [] }
        let c = configuration
        return CapturePermission.allCases.filter { permission in
            let needed: Bool = switch permission {
            case .screen: c.layout.showsDesktop || c.systemAudioEnabled
            case .camera: c.cameraEnabled
            case .microphone: c.microphoneEnabled
            }
            return needed && access(permission) != .allowed
        }
    }
    var toggleAnnotations: (() -> Void)?
    var clearAnnotations: (() -> Void)?
    var hideTeleprompter: (() -> Void)?
    var updateTeleprompter: ((StudioConfiguration) -> Void)?
    var toggleCameraArrange: (() -> Void)?
    var canArrangeCamera: Bool {
        configuration.cameraEnabled && configuration.layout == .desktopChat && configuration.windowID == nil && !busy
    }
    func commitCameraDrag(_ anchor: CameraAnchor) {
        engine.finishCameraDrag(committing: anchor)
        let unchanged = configuration.cameraAnchor == anchor
        configuration.cameraAnchor = anchor
        // An unchanged release still acknowledges the override through configure.
        if unchanged { scheduleUpdate() }
    }
    @Published var choosingTranscript = false

    var canPunchInCamera: Bool {
        configuration.layout == .desktopChat && configuration.cameraEnabled && !busy
    }

    func toggleCameraPunchIn() {
        guard canPunchInCamera else { return }
        configuration.cameraPunchIn.toggle()
    }
    private var saveTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var rehearsalStartTask: Task<Void, Never>?
    private var rehearsalStopTask: Task<Void, Never>?
    private var dockRegionSubscription: AnyCancellable?
    private var twitchSubscription: AnyCancellable?
    private var deviceSubscription: AnyCancellable?
    private var audioRouteObserver: AudioInputRouteObserver?
    private var devicesLoaded = false
    private var deviceGeneration = 0
    private var pendingUpdate = false
    private var loading = true
    private static let onboardingKey = "StreamApp.onboardingCompleted"
    /// CGPreflight cannot distinguish "never asked" from "denied"; remember our first request.
    private nonisolated static let screenRequestedKey = "StreamApp.screenCaptureRequested"
    private var persistenceURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StreamApp/settings.json")
    }

    init(demo: Bool = false) {
        self.demo = demo
        twitch = demo ? TwitchSession(persist: false) : .shared
        annotationSettings = AnnotationSettings(persist: !demo)
        teleprompter = TeleprompterModel(session: twitch)
        onboardingCompleted = demo ? false : UserDefaults.standard.bool(forKey: Self.onboardingKey)
        if !demo, let data = try? Data(contentsOf: persistenceURL), let saved = try? JSONDecoder().decode(StudioConfiguration.self, from: data) {
            configuration = saved
            configuration.cameraSize = min(0.4, max(0.12, saved.cameraSize))
            configuration.chatWidth = min(576, max(288, saved.chatWidth))
            configuration.microphoneGain = min(2, max(0, saved.microphoneGain))
            configuration.systemAudioGain = min(2, max(0, saved.systemAudioGain))
        }
        dockFit.configure(configuration)
        dockRegionSubscription = dockFit.$region.sink { [weak self] region in
            guard let self, self.configuration.dockFitRegion != region else { return }
            self.configuration.dockFitRegion = region
        }
        if demo { configuration.recordingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("StreamApp-Demo").path }
        for slot in ImageSlot.allCases { refreshImageState(slot) }
        teleprompter.configure(configuration)
        loading = false
        // Device enumeration is non-capturing and deferred to the views that list devices
        // (loadDevices). Screen/window enumeration is explicit.
        if !demo {
            deviceSubscription = NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)
                .merge(with: NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification))
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshDevices() }
        }
        twitchSubscription = twitch.$account.dropFirst().sink { [weak self] account in
            guard let self, account == nil, self.engine.isRunning,
                  self.configuration.streamingEnabled, self.configuration.streamService == .twitch else { return }
            self.message = "Twitch disconnected. Stopping the session."
            self.stop()
        }
        if !demo { Task { await twitch.restore() } }
        if !demo && configuration.microphoneEnabled { loadDevices() }
    }

    func completeOnboarding() {
        onboardingCompleted = true
        guard !demo else { return }
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
    }

    /// Starts a deliberate local rehearsal. It never loads a key or sends a network stream.
    func startRehearsal() {
        guard !busy, !engine.isRunning, rehearsalStopTask == nil else { return }
        var rehearsal = configuration
        rehearsal.streamingEnabled = false
        rehearsal.recordingEnabled = true
        message = nil
        busy = true
        rehearsalActive = true
        rehearsalStartTask = Task { [weak self] in
            guard let self else { return }
            defer { rehearsalStartTask = nil; if rehearsalStopTask == nil { busy = false } }
            do {
                try await engine.start(configuration: rehearsal, streamKey: "", synthetic: demo)
            } catch {
                rehearsalActive = false
                message = error.localizedDescription
            }
        }
    }

    func stopRehearsal() {
        Task { await stopRehearsalAndWait() }
    }

    /// One finalization owner, including close while a device is still starting.
    func stopRehearsalAndWait() async {
        if let task = rehearsalStopTask { await task.value; return }
        guard rehearsalActive || rehearsalStartTask != nil else { return }
        busy = true
        let task = Task { [self] in
            await rehearsalStartTask?.value
            await updateTask?.value
            await engine.stop()
            rehearsalActive = false
            busy = false
        }
        rehearsalStopTask = task
        await task.value
        rehearsalStopTask = nil
    }

    private func scheduleSave() {
        guard !loading, !demo else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self else { return }
            do {
                let url = self.persistenceURL
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(self.configuration).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { self.message = "Could not save settings: \(error.localizedDescription)" }
        }
    }

    private func scheduleUpdate() {
        guard !loading, !busy else { return }
        pendingUpdate = true
        // Hiding reaches the renderer now, not after an update still applying an older change.
        engine.request(configuration)
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            guard let self else { return }
            while self.pendingUpdate {
                self.pendingUpdate = false
                var next = self.configuration
                if self.rehearsalActive { next.streamingEnabled = false; next.recordingEnabled = true }
                do {
                    try await self.engine.update(configuration: next)
                    if next.teleprompterMode == self.configuration.teleprompterMode,
                       next.teleprompterInCapture == self.configuration.teleprompterInCapture {
                        self.updateTeleprompter?(self.configuration)
                    }
                }
                catch { self.message = error.localizedDescription }
            }
            self.updateTask = nil
        }
    }

    private nonisolated static func currentAccess() -> [CapturePermission: CaptureAccess] {
        var result: [CapturePermission: CaptureAccess] = [:]
        for permission in CapturePermission.allCases {
            guard let media = permission.mediaType else {
                result[permission] = CGPreflightScreenCaptureAccess() ? .allowed
                    : UserDefaults.standard.bool(forKey: screenRequestedKey) ? .denied : .notDetermined
                continue
            }
            result[permission] = switch AVCaptureDevice.authorizationStatus(for: media) {
            case .authorized: .allowed
            case .denied: .denied
            case .restricted: .restricted
            case .notDetermined: .notDetermined
            @unknown default: .notDetermined
            }
        }
        return result
    }

    func refreshAuthorization() {
        let current = Self.currentAccess()
        if current != captureAccess { captureAccess = current }
    }

    /// Settings/setup and an enabled mic need non-capturing route metadata.
    func loadDevices() {
        guard !devicesLoaded else { return }
        devicesLoaded = true
        refreshDevices()
    }

    private func refreshDevices() {
        guard devicesLoaded else { return }
        deviceGeneration &+= 1
        let generation = deviceGeneration
        if !demo {
            audioRouteObserver = AudioInputRouteObserver { [weak self] in
                Task { @MainActor in self?.refreshDevices() }
            }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let cameras = StudioEngine.cameras(), microphones = StudioEngine.microphones()
            await self?.applyDevices(cameras: cameras, microphones: microphones, generation: generation)
        }
    }

    private func applyDevices(cameras: [DeviceOption], microphones: [DeviceOption], generation: Int) {
        guard deviceGeneration == generation else { return }  // a newer refresh supersedes this one
        if self.cameras != cameras { self.cameras = cameras }
        if self.microphones != microphones { self.microphones = microphones }
        validateMicrophoneChannels()
    }

    func refreshSources() {
        refreshAuthorization()
        guard access(.screen) == .allowed else { message = "Screen Recording access is off."; return }
        Task {
            do { sources = try await engine.sources() }
            catch { message = error.localizedDescription }
        }
    }

    /// Source toggle that asks for access in context. Turning off never asks.
    func enabledBinding(for permission: CapturePermission) -> Binding<Bool> {
        let key = permission.configurationKey
        return Binding(
            get: { [weak self] in self?.configuration[keyPath: key] ?? false },
            set: { [weak self] on in
                guard let self else { return }
                if on { enable(permission) } else { configuration[keyPath: key] = false }
            })
    }

    /// Turns a source on, asking for access in context; `alongside` lands in the same change
    /// once access allows, and not at all if it is refused.
    func enable(_ permission: CapturePermission, alongside change: ((inout StudioConfiguration) -> Void)? = nil) {
        let key = permission.configurationKey
        let apply = { [weak self] in
            guard let self else { return }
            var next = configuration
            next[keyPath: key] = true
            change?(&next)
            configuration = next
        }
        guard !demo else { apply(); return }
        switch access(permission) {
        case .allowed: apply()
        case .notDetermined:
            Task { [weak self] in
                guard let self, await promptForAccess(permission) else { return }
                apply()
            }
        case .denied, .restricted: presentAccessAlert(permission)
        }
    }

    func canSelectScene(_ layout: SceneLayout) -> Bool {
        !layout.usesCamera || configuration.cameraEnabled
    }
    private static let webcamNudge = "Turn on the webcam to use"
    func selectScene(_ layout: SceneLayout) {
        guard canSelectScene(layout) else {
            NSSound.beep()
            message = "\(Self.webcamNudge) \(layout.title)."
            return
        }
        configuration.layout = layout
        configuration.awayCoversWebcam = false
        if message?.hasPrefix(Self.webcamNudge) == true { message = nil }
    }

    /// Explicit button: prompt once, afterwards send the user to the Privacy pane.
    func requestAccess(_ permission: CapturePermission) {
        switch access(permission) {
        case .allowed: return
        case .notDetermined: Task { _ = await promptForAccess(permission) }
        case .denied, .restricted: openPrivacySettings(permission)
        }
    }

    func openPrivacySettings(_ permission: CapturePermission) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permission.privacyPane)")!)
    }

    func showVideoEffects() { AVCaptureDevice.showSystemUserInterface(.videoEffects) }

    /// Shows the system prompt. Never opens System Settings afterwards: a fresh "Don't Allow" must not be nagged.
    private func promptForAccess(_ permission: CapturePermission) async -> Bool {
        let allowed: Bool
        if let media = permission.mediaType {
            allowed = await AVCaptureDevice.requestAccess(for: media)
        } else {
            UserDefaults.standard.set(true, forKey: Self.screenRequestedKey)
            allowed = CGRequestScreenCaptureAccess()
        }
        refreshAuthorization()
        return allowed
    }

    private func presentAccessAlert(_ permission: CapturePermission) {
        let alert = NSAlert()
        alert.messageText = "\(permission.title) access is off"
        if access(permission) == .restricted {
            alert.informativeText = "\(permission.title) access is restricted on this Mac."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        alert.informativeText = "Allow StreamApp in System Settings › Privacy & Security › \(permission.title)."
        alert.addButton(withTitle: "Open System Settings"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { openPrivacySettings(permission) }
    }

    func validateStreamSetup() -> Bool {
        guard configuration.streamingEnabled else { message = nil; return true }
        if configuration.streamService == .twitch {
            guard twitch.account != nil else { message = "Connect your Twitch account before streaming."; return false }
            message = nil
            return true
        }
        let key = streamKey.isEmpty && !demo ? (try? StreamCredential.load()) ?? "" : streamKey
        do {
            _ = try MediaOutput.makeStreamTarget(configuration: configuration, streamKey: key)
            message = nil
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func start() {
        guard !busy, !engine.isRunning else { return }
        guard !dockFit.busy else { message = "Wait for the Dock adjustment to finish."; return }
        message = nil
        if !demo {
            if configuration.layout.showsDesktop && configuration.displayID == nil && configuration.windowID == nil {
                message = "Choose a display or window first."; return
            }
            if configuration.cameraEnabled && access(.camera) != .allowed { message = "Camera access is off."; return }
            if configuration.microphoneEnabled && access(.microphone) != .allowed { message = "Microphone access is off."; return }
        }
        let approvedAccountID = twitch.account?.id
        var prefetchedKey: Task<String, Error>?
        if configuration.streamingEnabled {
            let mode = configuration.twitchTestMode ? "Test stream (not public)" : "Live broadcast"
            let host = configuration.streamService == .twitch
                ? "Twitch @\(twitch.account?.login ?? "")"
                : URL(string: configuration.streamURL)?.host ?? "the configured server"
            guard validateStreamSetup() else { return }
            // Fetch the Twitch key while the confirmation is open; Cancel discards it.
            if configuration.streamService == .twitch { prefetchedKey = Task { try await twitch.streamKey() } }
            let alert = NSAlert()
            alert.messageText = configuration.twitchTestMode ? "Start test stream?" : "Start broadcasting?"
            alert.informativeText = "\(mode) to \(host). Recording: \(configuration.recordingEnabled ? "on" : "off"). Your stream key is kept private."
            alert.addButton(withTitle: configuration.twitchTestMode ? "Start Test Stream" : "Start Broadcast"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn, !busy, !engine.isRunning else { prefetchedKey?.cancel(); return }
        }
        let requestedConfiguration = configuration
        busy = true
        sessionStage = prefetchedKey == nil ? .starting : .streamKey
        startTask = Task {
            // cancelStart() has already returned the model to idle for a cancelled start.
            defer { if !Task.isCancelled { busy = false; sessionStage = nil; startTask = nil } }
            do {
                var outputConfiguration = requestedConfiguration
                let key: String
                if !outputConfiguration.streamingEnabled {
                    key = ""
                } else if let prefetchedKey {
                    key = try await withTaskCancellationHandler { try await prefetchedKey.value } onCancel: { prefetchedKey.cancel() }
                    try Task.checkCancellation()
                    guard twitch.account?.id == approvedAccountID else {
                        message = "Twitch account changed. Review the destination and start again."
                        return
                    }
                    outputConfiguration.streamURL = "rtmps://ingest.global-contribute.live-video.net:443/app"
                } else {
                    key = streamKey.isEmpty && !demo ? try StreamCredential.load() : streamKey
                }
                sessionStage = .starting
                try await engine.start(configuration: outputConfiguration, streamKey: key, synthetic: demo)
                if outputConfiguration.streamingEnabled, outputConfiguration.streamService == .twitch,
                   twitch.account?.id != approvedAccountID {
                    await engine.stop()
                    message = "Twitch account changed. Review the destination and start again."
                }
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }

    /// Cancels a start that is still fetching its stream key; capture has not begun then.
    /// Returns to idle at once: the key request may be waiting on a shared Twitch token
    /// refresh that does not observe cancellation.
    func cancelStart() {
        guard sessionStage == .streamKey, let startTask else { return }
        startTask.cancel()
        self.startTask = nil; busy = false; sessionStage = nil
    }

    /// The session button and ⌃⌥⌘R: Cancel while fetching the key, else Stop or Start.
    func toggleSession(openStreamingSetup: () -> Void) {
        if sessionStage == .streamKey { cancelStart() }
        else if engine.isRunning { stop() }
        else if configuration.streamingEnabled && !validateStreamSetup() { openStreamingSetup() }
        else { start() }
    }

    func stop() {
        guard !busy else { return }
        if rehearsalActive { stopRehearsal(); return }
        busy = true
        sessionStage = .stopping(recording: configuration.recordingEnabled)
        Task { await updateTask?.value; await engine.stop(); busy = false; sessionStage = nil }
    }

    /// Restores persisted preferences while leaving credentials, recordings, onboarding,
    /// permissions, and runtime window state untouched.
    func restoreAllDefaults() async {
        guard !busy, !engine.isRunning else { return }
        guard !dockFit.busy else {
            message = "Wait for the Dock adjustment to finish."
            return
        }
        busy = true
        defer { busy = false; scheduleUpdate() }

        do {
            // Restore the Dock before replacing configuration so a failure cannot
            // discard the journal needed to recover its previous state.
            try await dockFit.disable()
        } catch {
            message = error.localizedDescription
            return
        }

        await updateTask?.value
        for slot in ImageSlot.allCases { removeImage(slot) }
        configuration = StudioConfiguration()
        annotationSettings.restoreDefaults()
        message = nil
    }

    func saveKey() {
        guard !demo, !streamKey.isEmpty else { return }
        do { try StreamCredential.save(streamKey); keySaved = true; streamKey = "" }
        catch { message = "Keychain: \(error.localizedDescription)" }
    }

    func chooseRecordingFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { configuration.recordingDirectory = url.path }
    }
    func chooseTranscript() {
        choosingTranscript = true
        defer { choosingTranscript = false }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Open Transcript"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if configuration.transcriptPath == url.path { teleprompter.reloadTranscript() }
        else { configuration.transcriptPath = url.path }
    }

    func reloadTranscript() { teleprompter.reloadTranscript() }

    func saveTranscriptTemplate() {
        choosingTranscript = true
        defer { choosingTranscript = false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Transcript.md"
        panel.prompt = "Save Template"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try TeleprompterModel.markdownTemplate.write(to: url, atomically: true, encoding: .utf8)
            configuration.transcriptPath = url.path
            teleprompter.reloadTranscript()
        } catch { message = "Could not save transcript template: \(error.localizedDescription)" }
    }
    func imageFilename(_ slot: ImageSlot) -> String? {
        let path = configuration[keyPath: slot.path]
        return path.isEmpty ? nil : URL(fileURLWithPath: path).lastPathComponent
    }

    func refreshImageState(_ slot: ImageSlot) {
        let path = configuration[keyPath: slot.path]
        imageErrors[slot] = path.isEmpty || FileManager.default.fileExists(atPath: path) ? nil : slot.missing
    }

    func chooseImage(_ slot: ImageSlot) {
        guard !importingImages.contains(slot) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Image"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let generation = (imageImportGeneration[slot] ?? 0) + 1
        imageImportGeneration[slot] = generation
        importingImages.insert(slot)
        imageErrors[slot] = nil
        let destination = demo
            ? FileManager.default.temporaryDirectory.appendingPathComponent("StreamApp-Demo/Backgrounds", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("StreamApp/Backgrounds", isDirectory: true)
        Task { [weak self] in
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    try importBackgroundImage(source: source, into: destination)
                }.value
                guard let self, self.imageImportGeneration[slot] == generation else { return }
                self.importingImages.remove(slot)
                self.configuration[keyPath: slot.path] = imported.path
            } catch {
                guard let self, self.imageImportGeneration[slot] == generation else { return }
                self.importingImages.remove(slot)
                self.imageErrors[slot] = "Could not import that image."
            }
        }
    }

    func removeImage(_ slot: ImageSlot) {
        imageImportGeneration[slot, default: 0] += 1
        importingImages.remove(slot)
        configuration[keyPath: slot.path] = ""
    }
}

private enum BackgroundImageImportError: Error {
    case invalid
    case write
}

private func importBackgroundImage(source: URL, into directory: URL) throws -> URL {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: 2048
    ]
    guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
    else { throw BackgroundImageImportError.invalid }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let base = source.deletingPathExtension().lastPathComponent
        .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    let readableName = String(base.map { Character(String($0)) }).prefix(48)
    let name = readableName.isEmpty ? "Background" : String(readableName)
    let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(name)").appendingPathExtension("png")
    let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
    guard let writer = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw BackgroundImageImportError.write
    }
    CGImageDestinationAddImage(writer, image, nil)
    guard CGImageDestinationFinalize(writer) else {
        try? FileManager.default.removeItem(at: temporary)
        throw BackgroundImageImportError.write
    }
    try FileManager.default.moveItem(at: temporary, to: destination)
    return destination
}

private enum StreamCredential {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.streamapp.broadcast", kSecAttrAccount as String: "stream-key"]
    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil); guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    static func load() throws -> String {
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw failure(status) }
        return value
    }
    static func failure(_ status: OSStatus) -> NSError { NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain operation failed"]) }
}
