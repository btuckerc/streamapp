import AppKit
import ApplicationServices
import Combine
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
        // Optional only to recover journals written by the previous release.
        var originalControl: Double?
        var appliedControl: Double?
        var pendingControl: Double?
        var originalAutohide: Bool?
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
        if let id = saved?.displayID, let measured = measurement(id) { publish(measured, displayID: id) }
    }

    nonisolated static func targetReservedHeight(frame: CGRect, desktopAspect: Double) -> Double {
        max(0, frame.height - frame.width / desktopAspect)
    }

    func enable(displayID: UInt32) async throws {
        guard !busy, saved == nil else { return }
        CFPreferencesAppSynchronize(domain)
        guard (CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String ?? "bottom") == "bottom",
              NSScreen.screens.contains(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }),
              let original = size() else {
            throw EngineError.message("Use a bottom Dock on an available display first.")
        }
        busy = true; message = nil; externallyChanged = false
        defer { busy = false }
        let originalControl = try control(allowPrompt: true)
        let originalAutohide = try autohide(allowPrompt: true)
        saved = Saved(displayID: displayID, originalSize: original, appliedSize: original, originalControl: originalControl, appliedControl: originalControl, originalAutohide: originalAutohide)
        do { try save() } catch { saved = nil; throw error }
        self.displayID = displayID
        defer { if saved != nil { startMonitor() } }
        do {
            if originalAutohide {
                try setAutohide(false, allowPrompt: true)
            }
            // Showing the Dock can change its layout and normalize its size.
            // Wait for two equal visible measurements, not merely the first frame.
            var previous: Measurement?
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(200))
                let current = measurement(displayID)
                if let current, current == previous { break }
                previous = current
            }
            guard measurement(displayID) != nil else {
                throw EngineError.message("Move the Dock to the selected display before fitting it.")
            }
            if originalAutohide {
                guard let applied = size() else {
                    throw EngineError.message("Cannot read the visible Dock size. Its previous settings are saved.")
                }
                saved!.appliedSize = applied
                saved!.appliedControl = try control(allowPrompt: true)
                try save()
            }
            try await adjust(allowPrompt: true)
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

    private func restoreSize(_ value: Saved) async throws {
        guard let current = size() else { throw EngineError.message("Cannot read the Dock size. Its saved size is retained.") }
        var ownsSize = abs(current - value.appliedSize) < 0.1
        if !externallyChanged, value.appliedControl != nil || value.pendingControl != nil {
            let actualControl = try control(allowPrompt: true)
            ownsSize = value.appliedControl.map { abs($0 - actualControl) < 0.001 } == true
                || value.pendingControl.map { abs($0 - actualControl) <= 1.0 / 112 + 0.000001 } == true
        }
        if !externallyChanged && ownsSize {
            if let original = value.originalControl {
                saved!.pendingControl = original
                try save()
                try setControl(original, allowPrompt: true)
                try await Task.sleep(for: .milliseconds(350))
            }
            if size().map({ abs($0 - value.originalSize) >= 0.1 }) ?? true {
                // The normalized float can round down on write. Recover the
                // exact saved tile size, including for older tile-only journals.
                var low = 0.0, high = 1.0
                for _ in 0..<14 {
                    let middle = (low + high) / 2
                    saved!.pendingControl = middle
                    try save()
                    try setControl(middle, allowPrompt: true)
                    try await Task.sleep(for: .milliseconds(100))
                    guard let actual = size() else { break }
                    if abs(actual - value.originalSize) < 0.1 { break }
                    if actual < value.originalSize { low = middle } else { high = middle }
                }
            }
            guard let actual = size(), abs(actual - value.originalSize) < 0.1 else {
                throw EngineError.message("The saved Dock size could not be restored. The recovery journal was kept.")
            }
            message = "Previous Dock size restored."
        } else {
            message = "Kept the Dock size you changed outside StreamApp."
        }
    }

    private func restoreSaved() async throws {
        guard let value = saved else { return }
        var sizeFailure: Error?
        do { try await restoreSize(value) } catch { sizeFailure = error }
        // Restore visibility independently, including after a failed size restore.
        // True is a newer/manual hidden state: never turn it back off on exit.
        if let original = value.originalAutohide {
            let current = try autohide(allowPrompt: true)
            if !current && original {
                try setAutohide(true, allowPrompt: true)
                guard try autohide(allowPrompt: true) else {
                    throw EngineError.message("Dock auto-hide could not be restored. The recovery journal was kept.")
                }
                message = (message ?? "Dock recovery pending.") + " Previous auto-hide setting restored."
            }
        }
        if let sizeFailure { throw sizeFailure }
        try FileManager.default.removeItem(at: backupURL)
        saved = nil; displayID = nil; region = nil
        monitor?.cancel(); monitor = nil; lastMeasurement = nil
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
        guard let measured = measurement(value.displayID) else {
            region = nil
            message = "Fit needs a visible bottom Dock on its selected display. Your saved size is retained."
            lastMeasurement = nil
            return
        }
        publish(measured, displayID: value.displayID)
        if let current = size(), abs(current - value.appliedSize) >= 0.1 {
            do {
                let actualControl = try control(allowPrompt: false)
                if value.appliedControl.map({ abs($0 - actualControl) < 0.001 }) == true
                    || value.pendingControl.map({ abs($0 - actualControl) <= 1.0 / 112 + 0.000001 }) == true {
                    saved!.appliedSize = current
                    saved!.appliedControl = actualControl; saved!.pendingControl = nil
                    try save()
                } else {
                    externallyChanged = true
                    message = "Your newer Dock size is kept. Capture still follows the area above it."
                }
            } catch { message = error.localizedDescription; return }
        }
        guard measured != lastMeasurement else { return }
        lastMeasurement = measured
        guard !externallyChanged else { return }
        busy = true
        defer { busy = false }
        do { try await adjust(allowPrompt: false) }
        catch { message = error.localizedDescription }
    }

    private func adjust(allowPrompt: Bool) async throws {
        guard let id = saved?.displayID else { return }
        var previousHeight: Double?
        for _ in 0..<4 {
            guard let measured = measurement(id) else { break }
            publish(measured, displayID: id)
            let target = Self.targetReservedHeight(frame: measured.frame, desktopAspect: desktopAspect)
            let error = target - measured.reserved
            if abs(error) <= 1 || previousHeight == measured.reserved { break }
            let current = try control(allowPrompt: allowPrompt)
            // Feedback, not a promise that the slider maps linearly to height.
            // macOS may cap physical height to fit all running/Handoff items.
            let next = min(1, max(0, current + error / 112))
            if abs(next - current) < 0.001 { break }
            guard let tile = size(), abs(tile - saved!.appliedSize) < 0.1 else {
                externallyChanged = true
                throw EngineError.message("The Dock size changed elsewhere. Your newer setting was kept.")
            }
            previousHeight = measured.reserved
            saved!.pendingControl = next
            try save()
            try setControl(next, allowPrompt: allowPrompt)
            try await Task.sleep(for: .milliseconds(350))
            // System Events may quantize/clamp the requested value. This is our
            // write, not evidence of a user override. Compare subsequent changes
            // against the accepted readback instead of the requested float.
            let accepted = try control(allowPrompt: false)
            guard let applied = size() else {
                throw EngineError.message("Cannot read the adjusted Dock size. Its previous settings are saved.")
            }
            saved!.appliedSize = applied
            saved!.appliedControl = accepted; saved!.pendingControl = nil
            try save()
        }
        if let measured = measurement(id) {
            publish(measured, displayID: id)
            lastMeasurement = measured
            message = nil
        }
    }

    private func publish(_ measured: Measurement, displayID: UInt32) {
        let next = DockCaptureRegion(displayID: displayID, heightFraction: (measured.frame.height - measured.reserved) / measured.frame.height)
        if region != next { region = next }
    }

    private func measurement(_ id: UInt32) -> Measurement? {
        CFPreferencesAppSynchronize(domain)
        guard (CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String ?? "bottom") == "bottom",
              !(CFPreferencesCopyAppValue("autohide" as CFString, domain) as? Bool ?? false),
              let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) else { return nil }
        let reserved = screen.visibleFrame.minY - screen.frame.minY
        guard reserved > 0, reserved < screen.frame.height else { return nil }
        return Measurement(frame: screen.frame, reserved: reserved, aspect: desktopAspect)
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
    private func script(_ command: String, allowPrompt: Bool) throws -> NSAppleEventDescriptor {
        if !allowPrompt {
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
            guard AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) == noErr else {
                throw EngineError.message("Allow StreamApp to control System Events to automatically fit the Dock. Capture continues without resizing it.")
            }
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: "tell application \"System Events\" to \(command)")!.executeAndReturnError(&error)
        if error != nil { throw EngineError.message("Dock sizing needs Automation access to System Events. Allow it in System Settings → Privacy & Security → Automation, then try again.") }
        return result
    }
    private func control(allowPrompt: Bool) throws -> Double {
        let value = try script("get dock size of dock preferences", allowPrompt: allowPrompt).doubleValue
        guard value.isFinite, (0...1).contains(value) else { throw EngineError.message("macOS returned an invalid Dock size.") }
        return value
    }
    private func setControl(_ value: Double, allowPrompt: Bool) throws {
        _ = try script("set dock size of dock preferences to \(value)", allowPrompt: allowPrompt)
    }
    private func autohide(allowPrompt: Bool) throws -> Bool {
        try script("get autohide of dock preferences", allowPrompt: allowPrompt).booleanValue
    }
    private func setAutohide(_ enabled: Bool, allowPrompt: Bool) throws {
        _ = try script("set autohide of dock preferences to \(enabled ? "true" : "false")", allowPrompt: allowPrompt)
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
            HStack {
                Toggle("Fit 16:9", isOn: Binding(get: { fit.displayID != nil }, set: { enabled in
                    if enabled { confirm = true } else { Task { await change(false) } }
                }))
                if !compact {
                    Button { Task { await change(false) } } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless)
                        .help("Restore the previous Dock size and auto-hide setting")
                        .accessibilityLabel("Restore previous Dock settings")
                        .disabled(fit.displayID == nil || fit.busy)
                }
            }
            .disabled(model.busy || model.engine.isRunning || fit.busy || (fit.displayID == nil && model.configuration.windowID != nil))
            .help("Temporarily shows and resizes the Dock to fit the desktop to the scene, accounting for chat. Remembers the Dock’s previous size and auto-hide setting and restores them when turned off.")
            if fit.busy { ProgressView("Adjusting Dock…").controlSize(.small) }
            if let text = error ?? (compact ? nil : fit.message) {
                Text(text).font(.caption).foregroundStyle(error == nil ? Color.secondary : Color.orange)
            }
        }
        .alert("Fit the Dock to your scene?", isPresented: $confirm) {
            Button("Fit Dock") { Task { await change(true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS may ask you to allow StreamApp to control System Events. Fit temporarily shows and resizes the Dock, remembering its previous size and auto-hide setting. Handoff and Dock items stay untouched.")
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
