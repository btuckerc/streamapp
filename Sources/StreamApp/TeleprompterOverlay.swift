import AppKit
import SwiftUI

/// Stable body and handle windows let capture rules retain their IDs for the app lifetime.
@MainActor
final class TeleprompterOverlay {
    private let model: TeleprompterModel
    private let panel: TeleprompterPanel
    private let hosting: NSHostingView<TeleprompterPanelContent>
    private let handlePanel: TeleprompterPanel
    private let handleHosting: NSHostingView<TeleprompterHandle>
    private var animationGeneration: UInt64 = 0
    private var screenObserver: NSObjectProtocol?
    private var configuration = StudioConfiguration()
    private var isPresented = false
    private var collapsed = false
    var onPresentationChanged: (() -> Void)?
    var isExpanded: Bool { isPresented && !collapsed }
    var windowIDs: Set<CGWindowID> {
        [CGWindowID(max(0, panel.windowNumber)), CGWindowID(max(0, handlePanel.windowNumber))]
    }

    init(model: TeleprompterModel) {
        self.model = model
        panel = TeleprompterPanel(contentRect: .zero,
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        hosting = NSHostingView(rootView: TeleprompterPanelContent(model: model, mode: .off))
        hosting.sizingOptions = []
        handlePanel = TeleprompterPanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        handleHosting = NSHostingView(rootView: TeleprompterHandle())
        handleHosting.sizingOptions = []

        for window in [panel, handlePanel] {
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.sharingType = .readOnly
            window.onClick = { [weak self] in self?.toggleCollapsed() }
        }
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.contentView = hosting
        panel.title = "StreamApp Teleprompter"
        // The chevron never participates in the content panel's animation.
        handlePanel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        handlePanel.contentView = handleHosting
        handlePanel.title = "StreamApp Teleprompter Handle"
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPresented else { return }
                self.update(configuration: self.configuration)
            }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func update(configuration: StudioConfiguration) {
        if configuration.teleprompterMode != self.configuration.teleprompterMode { collapsed = false }
        self.configuration = configuration
        guard configuration.teleprompterMode != .off else { hide(); return }
        isPresented = true
        place(animated: false)
        onPresentationChanged?()
    }

    private func toggleCollapsed() {
        guard isPresented else { return }
        collapsed.toggle()
        place(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        onPresentationChanged?()
    }

    private func place(animated: Bool) {
        animationGeneration &+= 1
        let generation = animationGeneration
        let screen = targetScreen(configuration: configuration)
        let lineCount = configuration.teleprompterMode == .transcript ? TeleprompterModel.transcriptLines : 6
        let topInset = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        let cameraLeft = screen.auxiliaryTopLeftArea?.maxX ?? screen.frame.midX - 90
        let cameraRight = screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX + 90
        let cameraWidth = max(0, cameraRight - cameraLeft)
        let shoulder = NotchSilhouette.shoulderRadius
        let width = (collapsed ? cameraWidth : TeleprompterModel.contentWidth + 40) + shoulder * 2
        let height = collapsed ? topInset : topInset + CGFloat(lineCount) * TeleprompterModel.lineHeight + 24
        hosting.rootView = TeleprompterPanelContent(model: model, mode: configuration.teleprompterMode,
            topInset: topInset, collapsed: collapsed, animated: animated)
        handleHosting.rootView = TeleprompterHandle(collapsed: collapsed,
            toggle: { [weak self] in self?.toggleCollapsed() })
        // Bridge the left safe-area edge, ending beneath the camera itself.
        // Extending to the right safe-area edge would square off the native notch corner.
        handlePanel.setFrame(NSRect(x: cameraLeft - 28 - shoulder,
            y: screen.frame.maxY - topInset, width: cameraWidth / 2 + 28 + shoulder, height: topInset), display: true)
        handlePanel.orderFrontRegardless()
        if !collapsed || animated { panel.orderFrontRegardless() }
        // The top stays attached to the screen edge throughout expansion and contraction.
        let frame = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.animationGeneration == generation, self.collapsed else { return }
                    self.panel.orderOut(nil)
                }
            }
        } else {
            panel.setFrame(frame, display: true)
            if collapsed { panel.orderOut(nil) }
        }
    }

    func hide() {
        isPresented = false
        animationGeneration &+= 1
        panel.orderOut(nil)
        handlePanel.orderOut(nil)
        onPresentationChanged?()
    }

    private func targetScreen(configuration: StudioConfiguration) -> NSScreen {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) { return notched }
        if let id = configuration.displayID,
           let selected = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) {
            return selected
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }
}

private final class TeleprompterPanel: NSPanel {
    var onClick: (() -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { onClick?(); return }
        super.sendEvent(event)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Concave shoulders meet the screen edge; convex lower corners round the hanging body.
private struct NotchSilhouette: Shape {
    static let shoulderRadius: CGFloat = 8
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let s = min(Self.shoulderRadius, min(rect.width / 4, rect.height / 2))
        let b = min(bottomRadius, min((rect.width - s * 2) / 2, rect.height - s))
        let k: CGFloat = 0.5522847498
        let left = rect.minX + s, right = rect.maxX - s
        let top = rect.minY, bottom = rect.maxY
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: top))
        path.addCurve(to: CGPoint(x: right, y: top + s),
                      control1: CGPoint(x: rect.maxX - k * s, y: top),
                      control2: CGPoint(x: right, y: top + s - k * s))
        path.addLine(to: CGPoint(x: right, y: bottom - b))
        path.addCurve(to: CGPoint(x: right - b, y: bottom),
                      control1: CGPoint(x: right, y: bottom - b + k * b),
                      control2: CGPoint(x: right - b + k * b, y: bottom))
        path.addLine(to: CGPoint(x: left + b, y: bottom))
        path.addCurve(to: CGPoint(x: left, y: bottom - b),
                      control1: CGPoint(x: left + b - k * b, y: bottom),
                      control2: CGPoint(x: left, y: bottom - b + k * b))
        path.addLine(to: CGPoint(x: left, y: top + s))
        path.addCurve(to: CGPoint(x: rect.minX, y: top),
                      control1: CGPoint(x: left, y: top + s - k * s),
                      control2: CGPoint(x: rect.minX + k * s, y: top))
        path.closeSubpath()
        return path
    }
}

private struct TeleprompterHandle: View {
    var collapsed = false
    var toggle: (() -> Void)?
    var body: some View {
        Button { toggle?() } label: {
            Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 28)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, NotchSilhouette.shoulderRadius)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1))
        .clipShape(NotchSilhouette(bottomRadius: collapsed ? 8 : 0))
        .accessibilityLabel(collapsed ? "Expand teleprompter" : "Collapse teleprompter")
        .help(collapsed ? "Expand teleprompter" : "Click anywhere to collapse")
        .transaction { $0.animation = nil }
    }
}

private struct TeleprompterPanelContent: View {
    @ObservedObject var model: TeleprompterModel
    let mode: TeleprompterMode
    var topInset: CGFloat = 0
    var collapsed = false
    var animated = false
    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .top) {
                if !collapsed {
                    content
                        .frame(width: TeleprompterModel.contentWidth + 40,
                               height: (mode == .twitchChat ? 6 : 3) * TeleprompterModel.lineHeight + 24)
                        .padding(.top, topInset)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1))
            .clipShape(NotchSilhouette(bottomRadius: collapsed ? 8 : 20))
            .animation(animated ? .easeInOut(duration: 0.24) : nil, value: collapsed)
        }
        .preferredColorScheme(.dark)
    }

    private var content: some View {
        VStack(spacing: 0) {
            if mode == .twitchChat {
                VStack(alignment: .leading, spacing: 0) {
                    if model.chatMessages.isEmpty {
                        Text(model.chatStatus).font(.system(size: 16)).foregroundStyle(.white.opacity(0.7))
                            .frame(height: TeleprompterModel.lineHeight, alignment: .leading)
                    }
                    ForEach(model.chatMessages, id: \.id) { message in
                        HStack(spacing: 6) {
                            Text(message.displayName).fontWeight(.semibold).foregroundStyle(.cyan).lineLimit(1)
                                .frame(maxWidth: 140, alignment: .leading)
                            Text(message.text).lineLimit(1).truncationMode(.tail)
                        }
                        .font(.system(size: 16)).foregroundStyle(.white)
                        .frame(height: TeleprompterModel.lineHeight, alignment: .leading)
                    }
                    ForEach(max(1, model.chatMessages.count)..<6, id: \.self) { _ in
                        Color.clear.frame(height: TeleprompterModel.lineHeight)
                    }
                }.padding(.horizontal, 20)
            } else if let error = model.error, !error.isEmpty {
                Text(error).font(.system(size: 16)).foregroundStyle(.white).lineLimit(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.horizontal, 20)
            } else if model.pageCount == 0 {
                Text("Choose a Markdown transcript in Teleprompter settings.")
                    .font(.system(size: 16)).foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.horizontal, 20)
            } else {
                AttributedTextView(text: model.transcriptPage)
                    .frame(width: TeleprompterModel.contentWidth, height: TeleprompterModel.lineHeight * CGFloat(TeleprompterModel.transcriptLines), alignment: .topLeading)
                    .padding(.horizontal, 20)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 16)
    }
}

private struct AttributedTextView: NSViewRepresentable {
    let text: NSAttributedString
    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(frame: .zero)
        view.isEditable = false; view.isSelectable = false; view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        view.textStorage?.setAttributedString(text)
    }
}

struct TeleprompterControls: View {
    @ObservedObject var model: StudioModel
    @ObservedObject private var teleprompter: TeleprompterModel

    init(model: StudioModel) {
        self.model = model
        _teleprompter = ObservedObject(wrappedValue: model.teleprompter)
    }

    private var mode: Binding<TeleprompterMode> {
        Binding(get: { model.configuration.teleprompterMode }, set: { model.configuration.teleprompterMode = $0 })
    }
    var body: some View {
        Form {
            Section("Camera / notch teleprompter") {
                Picker("Mode", selection: mode) {
                    ForEach(TeleprompterMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityLabel("Teleprompter mode")
                Text("Three transcript lines or six chat messages, just below the display camera. Click the panel to collapse; use the chevron beside the notch to expand.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Visible in stream and recording", isOn: $model.configuration.teleprompterInCapture)
                    .accessibilityLabel("Teleprompter visible in stream and recording")
                Text(model.configuration.teleprompterInCapture
                     ? "Visible in StreamApp display capture on the panel’s display. Full Camera and other single-window sources do not include it."
                     : "Private in StreamApp, even with Show StreamApp windows enabled. This does not hide it from other recording apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Markdown transcript") {
                Text(teleprompter.transcriptName.isEmpty ? "No transcript selected" : teleprompter.transcriptName)
                    .font(.headline).lineLimit(1)
                HStack {
                    Button("Open Markdown…") { model.chooseTranscript() }
                    Button("Reload") { model.reloadTranscript() }.disabled(model.configuration.transcriptPath.isEmpty)
                    Button("Save Template…") { model.saveTranscriptTemplate() }
                }
                if let error = teleprompter.error { Text(error).font(.caption).foregroundStyle(.orange) }
                pageControls
                Text("Put --- on its own line between cues. Longer cues wrap into three-line pages. Left and Right arrows move between pages globally while expanded in Transcript mode; they are paused while editing StreamApp settings or choosing files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.configuration.teleprompterMode == .twitchChat {
                Section("Twitch chat") {
                    Text(model.configuration.twitchChatChannel.isEmpty ? "Follows your connected Twitch account" : "Channel: \(model.configuration.twitchChatChannel)")
                    Text(teleprompter.chatStatus).font(.caption).foregroundStyle(.secondary)
                    Text("Connect Twitch or choose a channel in Sources. This panel works independently of Render chat.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
        .accessibilityElement(children: .contain)
    }

    private var pageControls: some View {
        HStack {
            Button("Previous") { teleprompter.previousPage() }.disabled(teleprompter.pageIndex == 0)
            Button("Restart") { teleprompter.restart() }.disabled(teleprompter.pageIndex == 0)
            Text(teleprompter.pageCount == 0 ? "No pages" : "\(teleprompter.pageIndex + 1) / \(teleprompter.pageCount)")
                .font(.caption).monospacedDigit()
            Spacer(minLength: 0)
            Button("Next →") { teleprompter.nextPage() }
                .disabled(teleprompter.pageCount == 0 || teleprompter.pageIndex + 1 >= teleprompter.pageCount)
        }
    }
}
