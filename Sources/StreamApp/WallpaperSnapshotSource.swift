import AppKit
import ScreenCaptureKit

/// Captures only the wallpaper window macOS is actually rendering, never a guessed asset.
/// A still snapshot is refreshed on desktop changes; this does not run a second video stream.
@MainActor
final class WallpaperSnapshotSource {
    private struct Target: Equatable {
        let displayID: CGDirectDisplayID?
        let windowID: CGWindowID?
        let dockRegion: DockCaptureRegion?
        init(_ configuration: StudioConfiguration) {
            displayID = configuration.displayID
            windowID = configuration.windowID
            dockRegion = configuration.dockFitRegion
        }
    }

    private var target: Target
    private let onChange: (CGImage?) -> Void
    private var revision: UInt64 = 0
    private var stopped = false
    private var captureTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var storeWatches: [DispatchSourceFileSystemObject] = []
    private var displayObserver: NSObjectProtocol?

    init(configuration: StudioConfiguration, onChange: @escaping (CGImage?) -> Void) {
        target = Target(configuration)
        self.onChange = onChange
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(after: .milliseconds(500)) }
            })
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(after: .milliseconds(500)) }
        }
        watchStore()
        refresh(after: .zero)
    }

    func configure(_ configuration: StudioConfiguration) {
        let next = Target(configuration)
        guard next != target else { return }
        target = next
        refresh(after: .zero)
    }

    func stop() {
        stopped = true
        revision &+= 1
        captureTask?.cancel()
        captureTask = nil
        storeWatches.forEach { $0.cancel() }
        storeWatches.removeAll()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        displayObserver = nil
    }

    deinit {
        captureTask?.cancel()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        storeWatches.forEach { $0.cancel() }
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
    }

    private func watchStore() {
        storeWatches.forEach { $0.cancel() }
        storeWatches.removeAll()
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store")
        for url in [directory, directory.appendingPathComponent("Index.plist")] {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            watch.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { return }
                    self.refresh(after: .milliseconds(350))
                    self.watchStore()
                }
            }
            watch.setCancelHandler { close(descriptor) }
            watch.resume()
            storeWatches.append(watch)
        }
    }

    private func refresh(after delay: Duration) {
        guard !stopped else { return }
        revision &+= 1
        let token = revision
        let requested = target
        captureTask?.cancel()
        onChange(nil)
        captureTask = Task { [weak self] in
            do {
                if delay > .zero { try await Task.sleep(for: delay) }
                // Preview never opens a permission prompt on the user's behalf.
                guard CGPreflightScreenCaptureAccess() else { return }
                let image = try await Self.capture(requested)
                guard !Task.isCancelled, let self, !self.stopped, self.revision == token else { return }
                self.onChange(image)
            } catch {
                // Fail closed: leave the configured solid fill, never capture the whole desktop
                // or substitute NSWorkspace's stale/default image URL.
            }
        }
    }

    private static func capture(_ target: Target) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let sourceWindow = target.windowID.flatMap { id in content.windows.first { $0.windowID == id } }
        if target.windowID != nil && sourceWindow == nil { return nil }
        let display: SCDisplay?
        if let sourceWindow {
            display = content.displays.filter { $0.frame.intersects(sourceWindow.frame) }.max {
                let a = $0.frame.intersection(sourceWindow.frame)
                let b = $1.frame.intersection(sourceWindow.frame)
                return a.width * a.height < b.width * b.height
            }
        } else {
            display = content.displays.first { $0.displayID == (target.displayID ?? CGMainDisplayID()) }
        }
        guard let display else { return nil }
        // WallpaperAgent identity is an observed macOS implementation detail, not a public
        // semantic wallpaper API. Require one exact display-sized, on-screen desktop window.
        // Unknown providers, ambiguous windows, and missing displays deliberately return nil.
        let candidates = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == "com.apple.wallpaper.agent"
                && $0.isOnScreen && $0.windowLayer < 0
                && abs($0.frame.minX - display.frame.minX) < 1
                && abs($0.frame.minY - display.frame.minY) < 1
                && abs($0.frame.width - display.frame.width) < 1
                && abs($0.frame.height - display.frame.height) < 1
        }
        guard candidates.count == 1, let wallpaper = candidates.first else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: wallpaper)
        let options = SCStreamConfiguration()
        let scale = min(2, 2048 / max(display.frame.width, display.frame.height))
        options.width = max(2, Int(display.frame.width * scale))
        options.height = max(2, Int(display.frame.height * scale))
        options.showsCursor = false
        options.includeChildWindows = false
        options.ignoreShadowsSingleWindow = true
        options.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: options)
        try Task.checkCancellation()
        // Use the same top-left display crop as desktop capture, including Dock-fit height.
        // This preserves wallpaper alignment instead of re-cropping it by aspect ratio.
        let full = CGRect(origin: .zero, size: display.frame.size)
        let crop: CGRect
        if let sourceWindow {
            crop = sourceWindow.frame.intersection(display.frame).offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        } else {
            crop = target.dockRegion?.crop(full, selectedDisplayID: target.displayID, windowID: nil) ?? full
        }
        let pixels = CGRect(x: crop.minX / full.width * CGFloat(image.width),
                            y: crop.minY / full.height * CGFloat(image.height),
                            width: crop.width / full.width * CGFloat(image.width),
                            height: crop.height / full.height * CGFloat(image.height)).integral
        return image.cropping(to: pixels)
    }
}
