
import SwiftUI

struct DockCaptureRegion: Equatable {
    let displayID: UInt32
    let heightFraction: Double

    func crop(_ full: CGRect, selectedDisplayID: UInt32?, windowID: UInt32?) -> CGRect {
        guard windowID == nil, selectedDisplayID == displayID else { return full }
        return CGRect(x: full.minX, y: full.minY, width: full.width, height: full.height * heightFraction)
    }
}

/// Owns Dock size and temporary visibility. Handoff, items and magnification are untouched.
@MainActor
final class DockCanvasFit: ObservableObject {
    @Published private(set) var displayID: UInt32?
    @Published private(set) var region: DockCaptureRegion?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private struct Saved: Codable {
        let displayID: UInt32
        let originalSize: Double
        var appliedSize: Double
        var originalAutohide: Bool?
        var originalReservedHeight: Double?
        var pendingSize: Double?
        var recovering: Bool?
        // Decode interrupted journals from the System Events implementation.
        var appliedControl: Double?
        var pendingControl: Double?
    }
    private struct Measurement: Equatable {
        let frame: CGRect
        let reserved: Double
        let aspect: Double
    }
    private let domain = "com.apple.dock" as CFString
    private let backupURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/StreamApp/dock-size.json")
    private var saved: Saved?
    private var monitor: Task<Void, Never>?
    private var desktopAspect = 16.0 / 9
    private var lastMeasurement: Measurement?
    private var externallyChanged = false

    init() {
        if let data = try? Data(contentsOf: backupURL), let value = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = value; displayID = value.displayID
            startMonitor()
        }
    }
    deinit { monitor?.cancel() }

    func configure(_ configuration: StudioConfiguration) {
        var desktop = configuration
        desktop.layout = .desktopChat
        let slot = SceneGeometry(configuration: desktop).desktop
        desktopAspect = slot.width / slot.height
        if saved?.recovering != true, let id = saved?.displayID, let measured = measurement(id) { publish(measured, displayID: id) }
    }

    nonisolated static func targetReservedHeight(frame: CGRect, desktopAspect: Double) -> Double {
        max(0, frame.height - frame.width / desktopAspect)
    }

    func enable(displayID: UInt32) async throws {
        guard !busy, saved == nil else { return }
        CFPreferencesAppSynchronize(domain)
        guard (CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String ?? "bottom") == "bottom",
              let screen = screen(displayID), let original = size() else {
            throw EngineError.message("Use a bottom Dock on an available display first.")
        }
        busy = true; message = nil; externallyChanged = false
        defer { busy = false }
        let reserved = screen.visibleFrame.minY - screen.frame.minY
        saved = Saved(displayID: displayID, originalSize: original, appliedSize: original,
                      originalAutohide: autohide(), originalReservedHeight: reserved)
        do { try save() } catch { saved = nil; throw error }
        self.displayID = displayID
        defer { if saved != nil { startMonitor() } }
        do {
            let target = Self.targetReservedHeight(frame: screen.frame, desktopAspect: desktopAspect)
            let candidate = target == 0 ? 16 : min(128, max(16, (original + target - reserved).rounded()))
            // Commit size and visibility together, not as separate work-area transitions.
            try await apply(size: candidate, autohide: false)
            try await adjust()
        } catch {
            let failure = error
            try await restoreSaved()
            throw failure
        }
    }

    func disable() async throws {
        guard !busy, saved != nil else { return }
        busy = true; message = nil
        defer { busy = false }
        try await restoreSaved()
    }

    private func restoreSaved() async throws {
        guard let value = saved else { return }
        guard let current = size() else {
            throw EngineError.message("Cannot read the Dock size. Its recovery journal was kept.")
        }
        let restoreSize = !externallyChanged && ownsSize(current, value)
        saved!.recovering = true
        try save()
        region = nil
        // A newer manually hidden Dock stays hidden. Legacy size-only journals
        // leave visibility untouched. Restore exact pixels, without slider rounding.
        try await apply(size: restoreSize ? value.originalSize : nil,
                        autohide: value.originalAutohide == true ? true : nil)
        if restoreSize, size().map({ abs($0 - value.originalSize) < 0.1 }) != true {
            throw EngineError.message("The saved Dock size could not be restored. The recovery journal was kept.")
        }
        if autohide() {
            let baseline = value.originalAutohide == true ? (value.originalReservedHeight ?? 0) : 0
            var released = false
            for _ in 0..<50 {
                guard let screen = screen(value.displayID) else {
                    // A disconnected display has no remaining work-area reservation.
                    released = true
                    break
                }
                if screen.visibleFrame.minY - screen.frame.minY <= baseline + 1 {
                    released = true
                    break
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard released else {
                throw EngineError.message("The Dock settings are restored, but macOS has not released its desktop space. Restore remains available; the recovery journal was kept.")
            }
        }
        try FileManager.default.removeItem(at: backupURL)
        saved = nil; displayID = nil; region = nil
        monitor?.cancel(); monitor = nil; lastMeasurement = nil
        message = restoreSize ? "Previous Dock settings and desktop space restored." : "Kept your newer Dock size. Previous visibility restored."
    }

    private func ownsSize(_ current: Double, _ value: Saved) -> Bool {
        if abs(current - value.appliedSize) < 0.1 { return true }
        if let pending = value.pendingSize, abs(current - pending) < 0.1 { return true }
        let control = (current - 16) / 112
        return value.appliedControl.map { abs(control - $0) < 0.001 } == true
            || value.pendingControl.map { abs(control - $0) <= 1.0 / 112 + 0.000001 } == true
    }

    private func startMonitor() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                await self?.refresh()
            }
        }
    }

    private func refresh() async {
        guard !busy, let value = saved else { return }
        guard value.recovering != true else {
            message = "Dock restoration is pending. Turn off Fit 16:9 to finish."
            return
        }
        guard let measured = measurement(value.displayID) else {
            region = nil
            message = "Fit needs a visible bottom Dock on its selected display. Your saved size is retained."
            lastMeasurement = nil
            return
        }
        publish(measured, displayID: value.displayID)
        if let current = size(), !ownsSize(current, value) {
            externallyChanged = true
            message = "Your newer Dock size is kept. Capture still follows the area above it."
        }
        guard measured != lastMeasurement else { return }
        lastMeasurement = measured
        guard !externallyChanged else { return }
        busy = true
        defer { busy = false }
        do { try await adjust() }
        catch { message = error.localizedDescription }
    }

    private func adjust() async throws {
        guard let id = saved?.displayID else { return }
        var previousHeight: Double?
        for _ in 0..<3 {
            guard let measured = measurement(id) else { break }
            publish(measured, displayID: id)
            let target = Self.targetReservedHeight(frame: measured.frame, desktopAspect: desktopAspect)
            let error = target - measured.reserved
            if abs(error) <= 1 || previousHeight == measured.reserved { break }
            guard let current = size(), let value = saved, ownsSize(current, value) else {
                externallyChanged = true
                throw EngineError.message("The Dock size changed elsewhere. Your newer setting was kept.")
            }
            let next = target == 0 ? 16 : min(128, max(16, (current + error).rounded()))
            if abs(next - current) < 0.1 { break }
            previousHeight = measured.reserved
            try await apply(size: next, autohide: nil)
        }
        guard let measured = measurement(id) else {
            throw EngineError.message("macOS has not reported the fitted Dock’s capture boundary on the selected display. Your previous settings are saved.")
        }
        publish(measured, displayID: id)
        lastMeasurement = measured
        message = nil
    }

    private func publish(_ measured: Measurement, displayID: UInt32) {
        guard measured.reserved > 0 else { return }
        let next = DockCaptureRegion(displayID: displayID, heightFraction: (measured.frame.height - measured.reserved) / measured.frame.height)
        if region != next { region = next }
    }

    private func measurement(_ id: UInt32) -> Measurement? {
        CFPreferencesAppSynchronize(domain)
        guard (CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String ?? "bottom") == "bottom",
              !(CFPreferencesCopyAppValue("autohide" as CFString, domain) as? Bool ?? false),
              let screen = screen(id) else { return nil }
        let reserved = screen.visibleFrame.minY - screen.frame.minY
        guard reserved > 0, reserved < screen.frame.height, dockIsOnDisplay(id) else { return nil }
        return Measurement(frame: screen.frame, reserved: reserved, aspect: desktopAspect)
    }

    private func dockIsOnDisplay(_ id: UInt32) -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return false }
        let display = CGDisplayBounds(id)
        let dockLevel = CGWindowLevelForKey(.dockWindow)
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == dock.processIdentifier,
                  (window[kCGWindowLayer as String] as? NSNumber)?.int32Value == dockLevel,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  !frame.isEmpty, !frame.isInfinite, !frame.isNull else { return false }
            return display.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
    }

    private func screen(_ id: UInt32) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }

    private func size() -> Double? {
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue("tilesize" as CFString, domain) as? NSNumber)?.doubleValue
    }
    private func save() throws {
        let directory = backupURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(saved).write(to: backupURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
    }
    private func autohide() -> Bool {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("autohide" as CFString, domain) as? Bool ?? false
    }

    private func apply(size requestedSize: Double?, autohide requestedAutohide: Bool?) async throws {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            throw EngineError.message("The Dock is not running. Its previous settings are saved.")
        }
        if let requestedSize {
            saved!.pendingSize = requestedSize
            try save()
            CFPreferencesSetAppValue("tilesize" as CFString, NSNumber(value: requestedSize), domain)
        }
        if let requestedAutohide {
            CFPreferencesSetAppValue("autohide" as CFString, NSNumber(value: requestedAutohide), domain)
        }
        guard CFPreferencesAppSynchronize(domain) else {
            throw EngineError.message("macOS could not save the Dock settings. The recovery journal was kept.")
        }
        // The original preference-write/SIGTERM mechanism, not an app-quit request.
        guard kill(dock.processIdentifier, SIGTERM) == 0 else {
            throw EngineError.message("macOS could not restart the Dock. The recovery journal was kept.")
        }
        var restarted = false
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(200))
            if let replacement = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
               replacement.processIdentifier != dock.processIdentifier {
                restarted = true
                break
            }
        }
        guard restarted else { throw EngineError.message("The Dock has not restarted. Its previous settings remain saved.") }
        // Dock startup and work-area publication are separate events.
        try await Task.sleep(for: .milliseconds(1500))
        if let requestedSize {
            guard let accepted = size(), abs(accepted - requestedSize) < 0.1 else {
                throw EngineError.message("The Dock size changed during adjustment. The recovery journal was kept.")
            }
            saved!.appliedSize = accepted
            saved!.pendingSize = nil
            saved!.appliedControl = nil; saved!.pendingControl = nil
            try save()
        }
        if let requestedAutohide, autohide() != requestedAutohide {
            throw EngineError.message("Dock visibility changed during adjustment. The recovery journal was kept.")
        }
        if saved?.recovering != true, let id = saved?.displayID {
            for _ in 0..<50 {
                if measurement(id) != nil { return }
                try await Task.sleep(for: .milliseconds(200))
            }
            throw EngineError.message("The visible Dock has not established a capture boundary on the selected display. Its previous settings remain saved.")
        }
    }
}

struct DockFitControl: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var fit: DockCanvasFit
    var compact = false
    @State private var confirm = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Fit 16:9", isOn: Binding(get: { fit.displayID != nil }, set: { enabled in
                if enabled { confirm = true } else { Task { await change(false) } }
            }))
            .disabled(model.busy || model.engine.isRunning || fit.busy || (fit.displayID == nil && model.configuration.windowID != nil))
            .help("Resizes the Dock so the desktop fits the scene. Turning it off restores your Dock.")
            if fit.busy { ProgressView("Adjusting Dock…").controlSize(.small) }
            if let text = error ?? (compact ? nil : fit.message) {
                Text(text).font(.caption).foregroundStyle(error == nil ? Color.secondary : Color.orange)
            }
        }
        .alert("Fit the Dock to your scene?", isPresented: $confirm) {
            Button("Fit Dock") { Task { await change(true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("StreamApp briefly restarts the Dock to resize it. Turning Fit off restores its previous size and auto-hide setting.")
        }
    }
    private func change(_ enabled: Bool) async {
        error = nil
        do {
            fit.configure(model.configuration)
            if enabled { try await fit.enable(displayID: model.configuration.displayID ?? CGMainDisplayID()) }
            else { try await fit.disable() }
        } catch { self.error = error.localizedDescription }
    }
}
