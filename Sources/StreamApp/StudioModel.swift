import AppKit
import AVFoundation
import Combine
import Security

@MainActor
final class StudioModel: ObservableObject {
    let engine = StudioEngine()
    let dockFit = DockCanvasFit()
    @Published var configuration = StudioConfiguration() { didSet { scheduleSave(); scheduleUpdate() } }
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
    var toggleAnnotations: (() -> Void)?
    var clearAnnotations: (() -> Void)?
    private var saveTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var rehearsalStartTask: Task<Void, Never>?
    private var rehearsalStopTask: Task<Void, Never>?
    private var pendingUpdate = false
    private var loading = true
    private static let onboardingKey = "StreamApp.onboardingCompleted"
    private var persistenceURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StreamApp/settings.json")
    }

    init(demo: Bool = false) {
        self.demo = demo
        onboardingCompleted = demo ? false : UserDefaults.standard.bool(forKey: Self.onboardingKey)
        if !demo, let data = try? Data(contentsOf: persistenceURL), let saved = try? JSONDecoder().decode(StudioConfiguration.self, from: data) {
            configuration = saved
            configuration.cameraSize = min(0.4, max(0.12, saved.cameraSize))
            configuration.chatWidth = min(576, max(288, saved.chatWidth))
            configuration.microphoneGain = min(2, max(0, saved.microphoneGain))
            configuration.systemAudioGain = min(2, max(0, saved.systemAudioGain))
        }
        configuration.dockFitDisplayID = demo ? nil : dockFit.displayID
        if demo { configuration.recordingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("StreamApp-Demo").path }
        loading = false
        // Device enumeration is non-capturing. Screen/window enumeration is explicit.
        cameras = engine.cameras(); microphones = engine.microphones()
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
            let host = URL(string: configuration.streamURL)?.host ?? "the configured server"
            let candidateKey = streamKey.isEmpty && !demo ? (try? StreamCredential.load()) ?? "" : streamKey
            do { _ = try MediaOutput.makeStreamTarget(configuration: configuration, streamKey: candidateKey) }
            catch { message = error.localizedDescription; return }
            let alert = NSAlert()
            alert.messageText = configuration.twitchTestMode ? "Start Twitch bandwidth test?" : "Start broadcasting?"
            alert.informativeText = "\(mode.capitalized) to \(host). Recording: \(configuration.recordingEnabled ? "on" : "off"). Your stream key is kept private."
            alert.addButton(withTitle: configuration.twitchTestMode ? "Start Bandwidth Test" : "Start Broadcast"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                let key = configuration.streamingEnabled ? (streamKey.isEmpty && !demo ? try StreamCredential.load() : streamKey) : ""
                try await engine.start(configuration: configuration, streamKey: key, synthetic: demo)
            } catch { message = error.localizedDescription }
        }
    }

    func stop() {
        guard !busy else { return }
        if rehearsalActive { stopRehearsal(); return }
        busy = true
        Task { await updateTask?.value; await engine.stop(); busy = false }
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
