import AppKit
import AVFoundation
import Combine
import ImageIO
import Security
import UniformTypeIdentifiers

@MainActor
final class StudioModel: ObservableObject {
    enum SettingsTab: Hashable { case sources, audio, layout, drawing, outputs }
    @Published var settingsTab: SettingsTab = .sources
    @Published var settingsVisible = false
    let engine = StudioEngine()
    let annotationSettings: AnnotationSettings
    let twitch: TwitchSession
    let dockFit = DockCanvasFit()
    @Published var configuration = StudioConfiguration() {
        didSet {
            if configuration.streamService != oldValue.streamService { message = nil }
            dockFit.configure(configuration)
            if configuration.backgroundImagePath != oldValue.backgroundImagePath {
                refreshBackgroundImageState()
            }
            scheduleSave()
            scheduleUpdate()
        }
    }
    @Published var sources: [CaptureSource] = []
    @Published var cameras: [DeviceOption] = []
    @Published var microphones: [DeviceOption] = []
    @Published var busy = false
    @Published var message: String?
    @Published var streamKey = ""
    @Published var keySaved = false
    @Published private(set) var rehearsalActive = false
    @Published var screenAuthorized = CGPreflightScreenCaptureAccess()
    @Published var cameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @Published var microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    /// Stored independently from the Codable broadcast settings for safe schema evolution.
    @Published private(set) var onboardingCompleted: Bool
    let demo: Bool
    @Published private(set) var backgroundImageAvailable = false
    @Published private(set) var backgroundImageError: String?
    @Published private(set) var importingBackgroundImage = false
    private var backgroundImportGeneration = 0
    var missingCapturePermissions: [String] {
        guard !demo else { return [] }
        var missing: [String] = []
        if !screenAuthorized { missing.append("Screen & system audio") }
        if !cameraAuthorized { missing.append("Camera") }
        if !microphoneAuthorized { missing.append("Microphone") }
        return missing
    }
    var toggleAnnotations: (() -> Void)?
    var clearAnnotations: (() -> Void)?
    private var saveTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var rehearsalStartTask: Task<Void, Never>?
    private var rehearsalStopTask: Task<Void, Never>?
    private var dockRegionSubscription: AnyCancellable?
    private var twitchSubscription: AnyCancellable?
    private var pendingUpdate = false
    private var loading = true
    private static let onboardingKey = "StreamApp.onboardingCompleted"
    private var persistenceURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StreamApp/settings.json")
    }

    init(demo: Bool = false) {
        self.demo = demo
        twitch = demo ? TwitchSession(persist: false) : .shared
        annotationSettings = AnnotationSettings(persist: !demo)
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
        refreshBackgroundImageState()
        loading = false
        // Device enumeration is non-capturing. Screen/window enumeration is explicit.
        cameras = engine.cameras(); microphones = engine.microphones()
        twitchSubscription = twitch.$account.dropFirst().sink { [weak self] account in
            guard let self, account == nil, self.engine.isRunning,
                  self.configuration.streamingEnabled, self.configuration.streamService == .twitch else { return }
            self.message = "Twitch disconnected. Stopping the session."
            self.stop()
        }
        if !demo { Task { await twitch.restore() } }
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
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            guard let self else { return }
            while self.pendingUpdate {
                self.pendingUpdate = false
                var next = self.configuration
                if self.rehearsalActive { next.streamingEnabled = false; next.recordingEnabled = true }
                do { try await self.engine.update(configuration: next) }
                catch { self.message = error.localizedDescription }
            }
            self.updateTask = nil
        }
    }

    func refreshAuthorization() {
        screenAuthorized = CGPreflightScreenCaptureAccess()
        cameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func refreshSources() {
        refreshAuthorization()
        cameras = engine.cameras(); microphones = engine.microphones()
        guard screenAuthorized else { message = "Grant Screen Recording access before listing displays and windows."; return }
        Task {
            do { sources = try await engine.sources() }
            catch { message = error.localizedDescription }
        }
    }

    func requestScreenPermission() {
        // Only called from the user's explicit permission button, never on launch.
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        screenAuthorized = CGPreflightScreenCaptureAccess()
    }

    func requestPermission(_ media: AVMediaType) {
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: media)
            if media == .video { cameraAuthorized = allowed } else { microphoneAuthorized = allowed }
            if !allowed {
                message = "Access denied. Enable StreamApp in System Settings → Privacy & Security."
                let pane = media == .video ? "Privacy_Camera" : "Privacy_Microphone"
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
            }
            cameras = engine.cameras(); microphones = engine.microphones()
        }
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
            if configuration.layout == .desktopChat && configuration.displayID == nil && configuration.windowID == nil {
                message = "Choose a display or window first."; return
            }
            if configuration.cameraEnabled && AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
                message = "Grant Camera access before enabling the webcam."; return
            }
            if configuration.microphoneEnabled && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                message = "Grant Microphone access before enabling microphone audio."; return
            }
        }
        if configuration.streamingEnabled {
            let mode = configuration.twitchTestMode ? "Twitch bandwidth test (not viewable live)" : "live broadcast"
            let host = configuration.streamService == .twitch
                ? "Twitch @\(twitch.account?.login ?? "")"
                : URL(string: configuration.streamURL)?.host ?? "the configured server"
            guard validateStreamSetup() else { return }
            let alert = NSAlert()
            alert.messageText = configuration.twitchTestMode ? "Start Twitch bandwidth test?" : "Start broadcasting?"
            alert.informativeText = "\(mode.capitalized) to \(host). Recording: \(configuration.recordingEnabled ? "on" : "off"). Your stream key is kept private."
            alert.addButton(withTitle: configuration.twitchTestMode ? "Start Bandwidth Test" : "Start Broadcast"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let approvedAccountID = twitch.account?.id
        let requestedConfiguration = configuration
        busy = true
        Task {
            defer { busy = false }
            do {
                var outputConfiguration = requestedConfiguration
                let key: String
                if !outputConfiguration.streamingEnabled {
                    key = ""
                } else if outputConfiguration.streamService == .twitch {
                    key = try await twitch.streamKey()
                    guard twitch.account?.id == approvedAccountID else {
                        message = "Twitch account changed. Review the destination and start again."
                        return
                    }
                    outputConfiguration.streamURL = "rtmps://ingest.global-contribute.live-video.net:443/app"
                } else {
                    key = streamKey.isEmpty && !demo ? try StreamCredential.load() : streamKey
                }
                try await engine.start(configuration: outputConfiguration, streamKey: key, synthetic: demo)
                if outputConfiguration.streamingEnabled, outputConfiguration.streamService == .twitch,
                   twitch.account?.id != approvedAccountID {
                    await engine.stop()
                    message = "Twitch account changed. Review the destination and start again."
                }
            } catch { message = error.localizedDescription }
        }
    }

    func stop() {
        guard !busy else { return }
        if rehearsalActive { stopRehearsal(); return }
        busy = true
        Task { await updateTask?.value; await engine.stop(); busy = false }
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
        removeBackgroundImage()
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
    var backgroundImageFilename: String? {
        guard !configuration.backgroundImagePath.isEmpty else { return nil }
        return URL(fileURLWithPath: configuration.backgroundImagePath).lastPathComponent
    }

    func refreshBackgroundImageState() {
        guard !configuration.backgroundImagePath.isEmpty else {
            backgroundImageAvailable = false
            backgroundImageError = nil
            return
        }
        let url = URL(fileURLWithPath: configuration.backgroundImagePath)
        backgroundImageAvailable = FileManager.default.fileExists(atPath: url.path)
        backgroundImageError = backgroundImageAvailable ? nil : "Image unavailable; using the fallback color."
    }

    func chooseBackgroundImage() {
        guard !importingBackgroundImage else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Image"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        backgroundImportGeneration += 1
        let generation = backgroundImportGeneration
        importingBackgroundImage = true
        backgroundImageError = nil
        let destination = demo
            ? FileManager.default.temporaryDirectory.appendingPathComponent("StreamApp-Demo/Backgrounds", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("StreamApp/Backgrounds", isDirectory: true)
        Task { [weak self] in
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    try importBackgroundImage(source: source, into: destination)
                }.value
                guard let self, self.backgroundImportGeneration == generation else { return }
                self.importingBackgroundImage = false
                self.configuration.backgroundImagePath = imported.path
            } catch {
                guard let self, self.backgroundImportGeneration == generation else { return }
                self.importingBackgroundImage = false
                self.backgroundImageError = "Could not import that image."
            }
        }
    }

    func removeBackgroundImage() {
        backgroundImportGeneration += 1
        importingBackgroundImage = false
        configuration.backgroundImagePath = ""
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
