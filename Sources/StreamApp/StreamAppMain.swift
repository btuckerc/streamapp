import AppKit
import SwiftUI
import Combine

@main
struct StreamAppMain {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = StudioApplication()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class StudioApplication: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var model: StudioModel!
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var inspectionWindow: NSWindow?
    private var stateSubscription: AnyCancellable?
    private var popoverHost: NSHostingController<StudioPopover>?
    private var onboardingWindow: NSWindow?
    private var closingOnboarding = false
    private var annotations: AnnotationOverlay?
    private var sceneSubscription: AnyCancellable?
    private var localPopoverMonitor: Any?
    private var globalPopoverMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        let smoke = arguments.contains("--smoke")
        model = StudioModel(demo: smoke || arguments.contains("--demo") || arguments.contains("--ui-smoke") || arguments.contains("--settings-smoke") || arguments.contains("--onboarding-smoke"))
        if smoke {
            Task { await runSmoke(arguments) }
            return
        }
        let annotations = AnnotationOverlay()
        self.annotations = annotations
        model.engine.annotationWindowID = annotations.canvasWindowID
        annotations.targetDisplay = { [weak self] in self?.model.configuration.displayID ?? CGMainDisplayID() }
        annotations.onToggleRequested = { [weak self] _ in
            guard let self else { return false }
            guard !model.busy, model.configuration.layout == .desktopChat, model.configuration.windowID == nil else {
                model.message = "Annotations require Desktop with a display source, not a single window."
                return false
            }
            return true
        }
        annotations.onCanvasShown = { [weak self, weak annotations] in
            guard let self, let annotations else { return }
            model.engine.annotationWindowID = annotations.canvasWindowID
            Task {
                do { try await self.model.engine.refreshCaptureFilter() }
                catch {
                    annotations.stopDrawing(); annotations.clear()
                    self.model.message = "Could not include annotation ink: \(error.localizedDescription)"
                }
            }
        }
        model.toggleAnnotations = { [weak self] in
            guard let self else { return }
            popover.performClose(nil)
            annotations.toggle(on: model.configuration.displayID ?? CGMainDisplayID())
        }
        model.clearAnnotations = { [weak annotations] in annotations?.clear() }
        if annotations.registrationFailed { model.message = "Drawing shortcut is already in use. Use Annotate desktop from the menu." }
        sceneSubscription = model.$configuration.sink { [weak annotations] c in
            if c.layout != .desktopChat || c.windowID != nil { annotations?.stopDrawing(); annotations?.clear() }
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "StreamApp.Studio"
        item.button?.image = StudioMark.idle
        item.button?.target = self; item.button?.action = #selector(togglePopover)
        item.button?.toolTip = "StreamApp — Idle"
        // Own dismissal so a status-button click cannot auto-close on mouse-down
        // and then reopen the same popover when its mouse-up action arrives.
        popover.behavior = .applicationDefined
        popover.delegate = self
        popover.animates = false
        let host = NSHostingController(rootView: controls)
        popoverHost = host
        popover.contentViewController = host
        stateSubscription = model.engine.$isRunning.sink { [weak self] running in
            self?.item.button?.image = running ? StudioMark.recording : StudioMark.idle
            self?.item.button?.toolTip = running ? "StreamApp — Session active" : "StreamApp — Idle"
        }
        if arguments.contains("--ui-smoke") || arguments.contains("--settings-smoke") {
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 420, height: 780), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = arguments.contains("--settings-smoke") ? "StreamApp Settings — Interface Check" : "StreamApp — Interface Check"
            if arguments.contains("--settings-smoke") { window.contentView = NSHostingView(rootView: StudioSettings(model: model, engine: model.engine, openOnboarding: { [weak self] in self?.showOnboarding() })) }
            else { window.contentView = NSHostingView(rootView: controls) }
            if let content = window.contentView { window.setContentSize(content.fittingSize) }
            window.isReleasedWhenClosed = false
            window.orderBack(nil)
            inspectionWindow = window
        }
        if arguments.contains("--onboarding-smoke") { showOnboarding(activate: false) }
        else if !model.demo && !model.onboardingCompleted { showOnboarding() }
        print("StreamApp ready — idle; no capture started")
        fflush(stdout)
    }

    func applicationDidBecomeActive(_ notification: Notification) { model?.refreshAuthorization() }

    private var controls: StudioPopover {
        StudioPopover(model: model, engine: model.engine, openSettings: { [weak self] in self?.showSettings() }, quit: { NSApplication.shared.terminate(nil) })
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            let anchor = button.window?.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = NSScreen.screens.first { screen in anchor.map { screen.frame.contains(NSPoint(x: $0.midX, y: $0.midY)) } ?? false } ?? NSScreen.main
            let height = min(600, max(260, (screen?.visibleFrame.height ?? 640) - 40))
            var content = controls
            content.availableHeight = height
            popoverHost?.rootView = content
            popoverHost?.view.setFrameSize(NSSize(width: 420, height: height))
            popoverHost?.view.layoutSubtreeIfNeeded()
            popover.contentSize = NSSize(width: 420, height: height)
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidShow(_ notification: Notification) {
        installPopoverDismissal()
        if let window = popoverHost?.view.window {
            window.makeKey()
            // Start with the panel, not the first scene button, as responder.
            // Tab still enters the ordinary keyboard navigation chain.
            window.makeFirstResponder(window)
        }
        Task { await model.engine.setMenuPreview(visible: true, configuration: model.configuration, synthetic: model.demo) }
    }

    func popoverDidClose(_ notification: Notification) {
        if let monitor = localPopoverMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalPopoverMonitor { NSEvent.removeMonitor(monitor) }
        localPopoverMonitor = nil
        globalPopoverMonitor = nil
        Task { await model.engine.setMenuPreview(visible: false, configuration: model.configuration, synthetic: model.demo) }
    }

    private func installPopoverDismissal() {
        guard localPopoverMonitor == nil else { return }
        localPopoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            guard NSApp.modalWindow == nil, self.popoverHost?.view.window?.attachedSheet == nil else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.popover.performClose(nil)
                    return nil
                }
                return event
            }
            if event.window === self.popoverHost?.view.window { return event }
            if self.pointerIsOverStatusItem { return event }
            self.popover.performClose(nil)
            return event
        }
        globalPopoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.pointerIsOverStatusItem else { return }
                self.popover.performClose(nil)
            }
        }
    }

    private var pointerIsOverStatusItem: Bool {
        guard let button = item.button, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(NSEvent.mouseLocation)
    }

    func applicationDidResignActive(_ notification: Notification) {
        if !pointerIsOverStatusItem { popover.performClose(nil) }
    }


    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 642, height: 620), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "StreamApp Settings"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: StudioSettings(model: model, engine: model.engine, openOnboarding: { [weak self] in self?.showOnboarding() }))
            window.center(); settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func showOnboarding(activate: Bool = true) {
        guard !model.engine.isRunning, !model.busy else {
            model.message = "Stop the current session before opening setup."
            return
        }
        popover.performClose(nil)
        if onboardingWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "StreamApp Setup"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: StudioOnboarding(model: model, engine: model.engine, onFinish: { [weak self] in
                self?.onboardingWindow?.performClose(nil)
            }))
            if let content = window.contentView { window.setContentSize(content.fittingSize) }
            window.center()
            onboardingWindow = window
        }
        if activate {
            onboardingWindow?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else { onboardingWindow?.orderBack(nil) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === onboardingWindow else { return true }
        if closingOnboarding { return false }
        if model.rehearsalActive || model.busy {
            closingOnboarding = true
            Task {
                await model.stopRehearsalAndWait()
                closingOnboarding = false
                sender.close()
            }
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === onboardingWindow {
            // Reopening setup starts at Connect while retaining saved choices.
            onboardingWindow = nil
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !model.onboardingCompleted { showOnboarding() }
        else { showSettings() }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model != nil, model.engine.isRunning || model.busy else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "Stop the session and quit?"
        alert.informativeText = "The recording will be finalized and any broadcast will end."
        alert.addButton(withTitle: "Stop and Quit"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        popover.performClose(nil)
        Task {
            while model.busy { try? await Task.sleep(for: .milliseconds(50)) }
            await model.engine.setMenuPreview(visible: false, configuration: model.configuration, synthetic: model.demo)
            await model.engine.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func runSmoke(_ arguments: [String]) async {
        do {
            guard let index = arguments.firstIndex(of: "--smoke"), arguments.indices.contains(index + 1) else { throw SmokeError.message("--smoke needs an output directory") }
            let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard Bundle.main.url(forResource: "chat", withExtension: "html", subdirectory: "StreamApp_StreamApp.bundle") != nil else { throw SmokeError.message("Packaged chat resource is missing") }
            var stageSeconds = 4.0
            if let i = arguments.firstIndex(of: "--smoke-stage-seconds"), arguments.indices.contains(i + 1) {
                guard let seconds = Double(arguments[i + 1]), seconds.isFinite, (1...120).contains(seconds) else { throw SmokeError.message("Smoke stage duration must be 1–120 seconds") }
                stageSeconds = seconds
            }
            var c = StudioConfiguration()
            c.recordingDirectory = directory.path
            c.cameraEnabled = true; c.microphoneEnabled = true; c.systemAudioEnabled = true
            if let i = arguments.firstIndex(of: "--smoke-rtmp"), arguments.indices.contains(i + 1) {
                let endpoint = arguments[i + 1]
                guard let url = URL(string: endpoint), ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""), url.scheme == "rtmp" else { throw SmokeError.message("Smoke RTMP must be loopback") }
                c.streamingEnabled = true; c.streamURL = endpoint
            }
            model.engine.previewFrames.request(.program)
            try await model.engine.start(configuration: c, streamKey: "", synthetic: true)
            for stage in 0..<4 {
                if stage == 1 { c.layout = .justChatting; c.chatEnabled = false }
                if stage == 2 { c.cameraEnabled = false; c.microphoneMuted = true; c.chatEnabled = true }
                if stage == 3 { c.layout = .desktopChat; c.cameraEnabled = true; c.chatEnabled = false; c.chatOnLeft = true; c.cameraCorner = .topLeft; c.microphoneMuted = false; c.systemAudioGain = 0.5 }
                try await model.engine.update(configuration: c)
                try await Task.sleep(for: .seconds(stageSeconds))
                guard model.engine.isRunning, model.engine.errorMessage == nil else { throw SmokeError.message(model.engine.errorMessage ?? "Session stopped") }
                print("OUTPUT HEALTH: \(model.engine.outputHealth)")
                guard let preview = model.engine.previewFrames.snapshot() else { throw SmokeError.message("No program preview") }
                let bitmap = NSBitmapImageRep(cgImage: preview)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SmokeError.message("Cannot encode preview") }
                try png.write(to: directory.appendingPathComponent("stage-\(stage).png"))
            }
            await model.engine.stop()
            if let error = model.engine.errorMessage { throw SmokeError.message(error) }
            // A second session catches stale clocks, device ownership and pipe cleanup.
            c.streamingEnabled = false
            try await model.engine.start(configuration: c, streamKey: "", synthetic: true)
            try await Task.sleep(for: .seconds(3))
            await model.engine.stop()
            if let error = model.engine.errorMessage { throw SmokeError.message(error) }
            print("SMOKE PASS: live scenes, chat toggle, camera toggle, audio controls, clean stop and restart")
            fflush(stdout)
            NSApplication.shared.terminate(nil)
        } catch {
            await model.engine.stop()
            fputs("SMOKE FAILED: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
private enum SmokeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
