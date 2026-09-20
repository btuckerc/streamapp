import AppKit
import Combine
import Darwin
import SwiftUI

/// Machine-local Dock changes are journaled separately from recording preferences.
@MainActor
final class DockCanvasFit: ObservableObject {
    @Published private(set) var displayID: UInt32?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private struct Saved: Codable {
        let displayID: UInt32
        let originalSize: Double
        var appliedSize: Double
    }
    private let domain = "com.apple.dock" as CFString
    private let backupURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/StreamApp/dock-size.json")
    private var saved: Saved?

    init() {
        if let data = try? Data(contentsOf: backupURL), let value = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = value; displayID = value.displayID
        }
    }

    func enable(displayID: UInt32) async throws {
        guard !busy, saved == nil else { return }
        busy = true; message = nil
        defer { busy = false }
        guard let screen = screen(displayID), let original = size(),
              (CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String ?? "bottom") == "bottom",
              !(CFPreferencesCopyAppValue("autohide" as CFString, domain) as? Bool ?? false) else {
            throw EngineError.message("Use a visible Dock at the bottom of this display first.")
        }
        let target = screen.frame.height - screen.frame.width * 9 / 16
        let current = screen.visibleFrame.minY - screen.frame.minY
        guard current > 0, target > 0 else {
            throw EngineError.message("This display cannot fit 16:9 by changing the Dock. Use a taller display with the Dock at the bottom.")
        }
        var candidate = original + target - current
        guard (16...128).contains(candidate) else {
            throw EngineError.message("The Dock cannot reach the size needed on this display.")
        }
        saved = Saved(displayID: displayID, originalSize: original, appliedSize: original)
        do { try save() } catch { saved = nil; throw error }
        do {
            // Measure after each change: Dock padding and display scaling vary by Mac.
            for _ in 0..<3 {
                guard let currentSize = size(), abs(currentSize - saved!.appliedSize) < 0.01 else {
                    throw EngineError.message("The Dock size changed elsewhere. Your newer setting was kept.")
                }
                saved!.appliedSize = candidate
                try save()
                try setSize(candidate)
                try await Task.sleep(for: .milliseconds(1500))
                guard let updated = self.screen(displayID) else { throw EngineError.message("The display disconnected.") }
                let measured = updated.visibleFrame.minY - updated.frame.minY
                if Self.fits(updated) {
                    self.displayID = displayID
                    message = target - measured > 1
                        ? "Dock fitted. A thin strip above it is outside the capture. Turning this off restores its previous size."
                        : "Dock fitted. Turning this off restores its previous size."
                    return
                }
                candidate += target - measured
                guard (16...128).contains(candidate) else { break }
            }
            throw EngineError.message("macOS could not fit the Dock closely enough on this display.")
        } catch {
            let failure = error
            try await restoreSaved()
            throw failure
        }
    }

    func disable() async throws {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        try await restoreSaved()
    }

    private func restoreSaved() async throws {
        guard let value = saved else { return }
        guard let current = size() else {
            throw EngineError.message("The current Dock size could not be read. Its saved size is still available; try again.")
        }
        if abs(current - value.appliedSize) < 0.01 {
            try setSize(value.originalSize)
            try await Task.sleep(for: .milliseconds(1500))
            guard let restored = size(), abs(restored - value.originalSize) < 0.01 else {
                throw EngineError.message("The Dock could not be restored. Its saved size is still available; try again.")
            }
            message = "Previous Dock size restored."
        } else {
            message = "Kept the Dock size you changed outside StreamApp."
        }
        try FileManager.default.removeItem(at: backupURL)
        saved = nil; displayID = nil
    }
    // Dock dimensions are quantized and may be capped by its contents. Keep the
    // capture exact; allow up to six output pixels of desktop below its edge.
    static func fits(_ screen: NSScreen) -> Bool {
        let target = screen.frame.height - screen.frame.width * 9 / 16
        let reserved = screen.visibleFrame.minY - screen.frame.minY
        let gap = target - reserved
        return reserved > 0 && gap >= 0 && gap * 1920 / screen.frame.width <= 6
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
    private func setSize(_ value: Double) throws {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            throw EngineError.message("The Dock is not running.")
        }
        CFPreferencesSetAppValue("tilesize" as CFString, NSNumber(value: value), domain)
        guard CFPreferencesAppSynchronize(domain) else { throw EngineError.message("macOS could not save the Dock size.") }
        guard kill(dock.processIdentifier, SIGTERM) == 0 else { throw EngineError.message("macOS could not restart the Dock. The previous size is saved.") }
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
            Toggle(compact ? "Fit 16:9" : "Fit desktop to 16:9", isOn: Binding(get: { fit.displayID != nil }, set: { enabled in
                if enabled { confirm = true }
                else { Task { await change(false) } }
            }))
            .disabled(model.busy || model.engine.isRunning || fit.busy || (fit.displayID == nil && model.configuration.windowID != nil))
            .help("Fit the desktop above the Dock to 16:9. Turning this off restores the previous Dock size.")
            if !compact {
                Text("Resizes the Dock and captures the area above it. Turning it off restores the old Dock size.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if fit.busy { ProgressView("Adjusting Dock…").controlSize(.small) }
            if let text = error ?? (compact ? nil : fit.message) {
                Text(text).font(.caption).foregroundStyle(error == nil ? Color.secondary : Color.orange)
            }
        }
        .alert("Resize your Dock?", isPresented: $confirm) {
            Button("Resize Dock") { Task { await change(true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Dock will briefly restart. Its current size will be saved so you can restore it. Use a visible Dock at the bottom of the selected display.")
        }
    }
    private func change(_ enabled: Bool) async {
        error = nil
        do {
            if enabled { try await fit.enable(displayID: model.configuration.displayID ?? CGMainDisplayID()) }
            else { try await fit.disable() }
            model.configuration.dockFitDisplayID = fit.displayID
        } catch { self.error = error.localizedDescription }
    }
}
