import SwiftUI
import AppKit
import Combine

extension StudioModel.SettingsTab {
    var title: String {
        switch self {
        case .sources: "Capture"
        case .audio: "Audio"
        case .layout: "Scene"
        case .chat: "Chat"
        case .teleprompter: "Prompter"
        case .drawing: "Drawing"
        case .outputs: "Output"
        }
    }
    var symbol: String {
        switch self {
        case .sources: "display"
        case .audio: "waveform"
        case .layout: "rectangle.3.group"
        case .chat: "bubble.left.and.text.bubble.right"
        case .teleprompter: "text.bubble"
        case .drawing: "pencil.tip"
        case .outputs: "antenna.radiowaves.left.and.right"
        }
    }
}

/// Settings window in the system Settings idiom: AppKit's toolbar-style tab controller
/// supplies the preference toolbar, pane selection and window title; each pane is SwiftUI.
/// Pane views load on first selection, and all panes share one size so switching never resizes.
@MainActor
final class StudioSettingsController: NSTabViewController {
    private let model: StudioModel
    private var previewSubscription: AnyCancellable?

    init(model: StudioModel, openOnboarding: @escaping () -> Void) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        model.loadDevices()
        tabStyle = .toolbar
        transitionOptions = [] // switch panes immediately, without a crossfade
        for tab in StudioModel.SettingsTab.allCases {
            let host = NSHostingController(rootView: StudioSettings(model: model, engine: model.engine, tab: tab, openOnboarding: openOnboarding))
            host.sizingOptions = [.preferredContentSize]
            host.title = tab.title // the tab controller shows the selected pane's title in the window, as system Settings does
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)
            addTabViewItem(item)
        }
        selectedTabViewItemIndex = StudioModel.SettingsTab.allCases.firstIndex(of: model.settingsTab) ?? 0
        // The Layout pane's preview runs only while that pane is showing in a visible window.
        let engine = model.engine
        previewSubscription = Publishers.CombineLatest3(model.$settingsVisible, model.$settingsTab, engine.$videoPreviewMode)
            .map { visible, tab, mode in visible && tab == .layout && mode != nil }
            .removeDuplicates()
            .sink { [weak model] visible in
                guard let model else { return }
                Task { await engine.setSettingsPreview(visible: visible, configuration: model.configuration, synthetic: model.demo) }
            }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        let tabs = StudioModel.SettingsTab.allCases
        if tabs.indices.contains(selectedTabViewItemIndex) { model.settingsTab = tabs[selectedTabViewItemIndex] }
    }

    func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: self)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        return window
    }
}

/// Slider with its value: one fixed width everywhere, so sliders line up across panes.
struct SliderValue: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let readout: String

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
            }.frame(width: 220).accessibilityLabel(title).accessibilityValue(readout)
            Text(readout).monospacedDigit().frame(width: 64, alignment: .trailing)
        }
    }
}

/// A settings row: label left, control right. Once the value differs from its default a reset
/// arrow appears beside the label, so the control itself never moves.
struct SettingRow<Content: View>: View {
    let title: String
    var changed = false
    var reset: () -> Void = {}
    @ViewBuilder let content: () -> Content

    var body: some View {
        LabeledContent {
            content().labelsHidden().toggleStyle(.switch)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if changed {
                    Button(action: reset) { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless).controlSize(.small)
                        .help("Reset \(title) to default")
                        .accessibilityLabel("Reset \(title) to default")
                }
            }
        }
    }
}

struct StudioSettings: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: StudioEngine
    let tab: StudioModel.SettingsTab
    let openOnboarding: () -> Void
    @State private var confirmRestoreAll = false
    private let defaults = StudioConfiguration()

    var body: some View {
        VStack(spacing: 0) {
            pane
            Divider()
            HStack {
                Button("Setup Assistant…", action: openOnboarding).disabled(engine.isRunning || model.busy)
                    .help("Walk through permissions, sources, and a test recording again.")
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                Button("Restore Defaults…", role: .destructive) { confirmRestoreAll = true }
                    .disabled(model.busy || engine.isRunning)
            }.padding(.horizontal, 20).padding(.vertical, 14)
        }.frame(width: 680, height: 580).disabled(model.busy)
        .alert("Restore all defaults?", isPresented: $confirmRestoreAll) {
            Button("Restore Defaults", role: .destructive) {
                Task { await model.restoreAllDefaults() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Recordings, credentials, and permissions are kept.")
        }
    }

    @ViewBuilder private var pane: some View {
        switch tab {
        case .sources: captureTab
        case .audio: audioTab
        case .layout: layoutTab
        case .chat: chatTab
        case .teleprompter: TeleprompterControls(model: model)
        case .drawing: AnnotationSettingsView(settings: model.annotationSettings)
        case .outputs: outputTab
        }
    }

    private func setting<Value: Equatable, Content: View>(_ title: String,
        _ key: WritableKeyPath<StudioConfiguration, Value>, @ViewBuilder content: @escaping () -> Content) -> some View {
        SettingRow(title: title, changed: model.configuration[keyPath: key] != defaults[keyPath: key],
                   reset: { model.configuration[keyPath: key] = defaults[keyPath: key] }, content: content)
    }
    /// Menu pickers list "Refresh List" last; choosing it reloads the list and keeps the selection.
    static let refreshTag = "\u{0}refresh"
    private var sourceSelection: Binding<String> {
        Binding(get: {
            if let window = model.configuration.windowID { return "window:\(window)" }
            if let display = model.configuration.displayID { return "display:\(display)" }
            return ""
        }, set: { value in
            if value == Self.refreshTag { model.refreshSources(); model.objectWillChange.send(); return }
            guard let source = model.sources.first(where: { $0.stableID == value }) else { return }
            model.configuration.displayID = source.kind == .display ? source.id : nil
            model.configuration.windowID = source.kind == .window ? source.id : nil
        })
    }
    private func exclusion<ID: Equatable>(_ ids: WritableKeyPath<StudioConfiguration, [ID]>, _ id: ID) -> Binding<Bool> {
        Binding(get: { model.configuration[keyPath: ids].contains(id) }, set: { excluded in
            var next = model.configuration[keyPath: ids].filter { $0 != id }
            if excluded { next.append(id) }
            model.configuration[keyPath: ids] = next
        })
    }

    private var captureTab: some View {
        Form {
            Section("Screen") {
                CaptureAccessNotice(model: model, permission: .screen)
                SettingRow(title: "Display or window",
                           changed: model.configuration.displayID != defaults.displayID || model.configuration.windowID != defaults.windowID,
                           reset: {
                               model.configuration.displayID = defaults.displayID
                               model.configuration.windowID = defaults.windowID
                           }) {
                    Picker("Display or window", selection: sourceSelection) {
                        Text("Choose display or window…").tag("")
                        ForEach([CaptureSource.Kind.display, .window], id: \.self) { kind in
                            let matches = model.sources.filter { $0.kind == kind }
                            if !matches.isEmpty {
                                Section(kind == .display ? "Displays" : "Windows") {
                                    ForEach(matches, id: \.stableID) { Text($0.name).tag($0.stableID) }
                                }
                            }
                        }
                        Divider()
                        Text("Refresh List").tag(Self.refreshTag)
                    }
                }.disabled(engine.isRunning || model.busy)
                if model.configuration.windowID == nil {
                    setting("Include menu bar", \.includeMenuBar) {
                        Toggle("Include menu bar", isOn: $model.configuration.includeMenuBar)
                    }
                    setting("Show StreamApp windows", \.showStreamAppWindows) {
                        Toggle("Show StreamApp windows", isOn: $model.configuration.showStreamAppWindows)
                    }.help("Menu and settings windows in display capture. The teleprompter has its own setting in Prompter.")
                    .disabled(model.busy)
                }
                // Stays visible for window capture: a Fit made earlier must remain reversible.
                DockFitControl(model: model, fit: model.dockFit)
            }
            if model.configuration.windowID == nil {
                Section {
                    ClickableDisclosure("Apps", detail: hiddenCount(model.configuration.excludedApplicationIDs.count)) {
                        ForEach(engine.captureApplications) { app in
                            Toggle(app.name, isOn: exclusion(\.excludedApplicationIDs, app.id))
                        }
                        ForEach(model.configuration.excludedApplicationIDs.filter { id in !engine.captureApplications.contains { $0.id == id } }, id: \.self) { id in
                            Toggle(id, isOn: exclusion(\.excludedApplicationIDs, id)).foregroundStyle(.secondary)
                        }
                    }
                    ClickableDisclosure("Windows", detail: hiddenCount(model.configuration.excludedWindowIDs.count)) {
                        ForEach(model.sources.filter { $0.kind == .window }, id: \.stableID) { source in
                            Toggle(source.name, isOn: exclusion(\.excludedWindowIDs, source.id))
                        }
                    }
                } header: {
                    Text("Hide from capture")
                } footer: {
                    Text("Hidden apps and windows never appear in the display capture. Window choices last until StreamApp quits.")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(engine.isRunning)
            }
            Section("Webcam") {
                CaptureAccessNotice(model: model, permission: .camera)
                setting("Camera", \.cameraID) {
                    Picker("Camera", selection: $model.configuration.cameraID) {
                        Text("Automatic").tag("")
                        ForEach(model.cameras) { Text($0.name).tag($0.id) }
                        if !model.configuration.cameraID.isEmpty,
                           !model.cameras.contains(where: { $0.id == model.configuration.cameraID }) {
                            Text("Unavailable camera").tag(model.configuration.cameraID)
                        }
                    }
                }.help("Automatic uses the camera macOS prefers.")
                setting("Mirror", \.mirrorCamera) {
                    Toggle("Mirror webcam", isOn: $model.configuration.mirrorCamera)
                }
            }.disabled(engine.isRunning || model.busy)
        }.formStyle(.grouped)
        .task {
            if model.access(.screen) == .allowed && model.sources.isEmpty { model.refreshSources() }
        }
    }
    private func hiddenCount(_ count: Int) -> String {
        count == 0 ? "None hidden" : "\(count) hidden"
    }
    private var audioTab: some View {
        Form {
            Section {
                CaptureAccessNotice(model: model, permission: .screen)
                setting("App audio", \.systemAudioEnabled) {
                    Toggle("Capture app audio", isOn: model.enabledBinding(for: .screen))
                }.help("Sound playing from apps on this Mac, such as music or a game.")
                if model.configuration.systemAudioEnabled {
                    setting("Capture audio from", \.systemAudioApplicationID) {
                        SystemAudioSourcePicker(model: model, engine: engine)
                    }
                }
            }.disabled(engine.isRunning)
            Section {
                CaptureAccessNotice(model: model, permission: .microphone)
                setting("Microphone", \.microphoneEnabled) {
                    Toggle("Use microphone", isOn: model.enabledBinding(for: .microphone))
                }
                if model.configuration.microphoneEnabled {
                    setting("Device", \.microphoneID) {
                        Picker("Microphone device", selection: $model.configuration.microphoneID) {
                            Text("System default").tag("")
                            ForEach(model.microphones) { Text($0.name).tag($0.id) }
                            if !model.configuration.microphoneID.isEmpty,
                               !model.microphones.contains(where: { $0.id == model.configuration.microphoneID }) {
                                Text("Unavailable microphone").tag(model.configuration.microphoneID)
                            }
                        }
                    }.help("With AirPods, pick the Mac or a USB mic to keep playback quality high.")
                    setting("Channels", \.microphoneChannels) {
                        Picker("Microphone channels", selection: $model.configuration.microphoneChannels) {
                            ForEach(AudioChannelSelection.choices(channelCount: model.selectedMicrophone?.inputChannels ?? 0), id: \.self) {
                                Text($0.title).tag($0)
                            }
                        }
                    }
                    if let warning = model.microphoneRouteWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
                }
            } footer: {
                if model.configuration.microphoneEnabled {
                    Text("If your DAW already sends this mic into app audio, turn the microphone off so it isn't heard twice.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(engine.isRunning)
            if model.configuration.microphoneEnabled {
                Section {
                    setting("Compression", \.microphoneCompressionEnabled) {
                        Toggle("Compression", isOn: $model.configuration.microphoneCompressionEnabled)
                    }.help("Softens loud speech: 3:1 above −18 dBFS.")
                    setting("Echo cancellation", \.microphoneEchoCancellationEnabled) {
                        Toggle("Echo cancellation", isOn: $model.configuration.microphoneEchoCancellationEnabled)
                    }.help("Removes speaker playback from the mic. May soften quiet speech or music.")
                    if model.configuration.microphoneEchoCancellationEnabled, let status = engine.echoCancellationStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    setting("Noise reduction", \.microphoneNoiseReductionEnabled) {
                        Toggle("Noise reduction", isOn: $model.configuration.microphoneNoiseReductionEnabled)
                    }.help("Reduces hiss and fan noise; adds about 7 ms delay.")
                } header: {
                    Text("Voice processing")
                } footer: {
                    Text("Leave these off for instruments. Echo cancellation and noise reduction make the mic mono.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                // Ducking follows the voice, so it only matters with both sources on.
                if model.configuration.systemAudioEnabled {
                    Section {
                        setting("Lower app audio", \.systemAudioDucking) {
                            Picker("Lower app audio while you talk", selection: $model.configuration.systemAudioDucking) {
                                ForEach(AudioDucking.allCases) { Text($0.title).tag($0) }
                            }.pickerStyle(.segmented)
                        }.help("Only the stream and recording change; you still hear app audio at full level.")
                    } header: {
                        Text("While you talk")
                    } footer: {
                        Text(duckingCaption).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if model.configuration.systemAudioEnabled || model.configuration.microphoneEnabled {
                Section {
                    if model.configuration.systemAudioEnabled { syncRow("Delay app audio", \.systemAudioSyncOffsetMs) }
                    if model.configuration.microphoneEnabled { syncRow("Delay microphone", \.microphoneSyncOffsetMs) }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("If sound and picture drift apart, line them up with a recorded clap. Positive values play a source later; negative, earlier.")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(engine.isRunning)
            }
        }.formStyle(.grouped)
    }
    private func syncRow(_ title: String, _ key: WritableKeyPath<StudioConfiguration, Int>) -> some View {
        setting(title, key) {
            HStack(spacing: 6) {
                Text("\(model.configuration[keyPath: key]) ms").monospacedDigit()
                Stepper(title, value: Binding(get: { model.configuration[keyPath: key] }, set: { model.configuration[keyPath: key] = $0 }),
                        in: -500...1000, step: 10)
            }
        }
    }
    private var startSummary: String {
        let stream = model.configuration.twitchTestMode ? "sends a test stream (not public)" : "goes live"
        switch model.configuration.outputMode {
        case .record: return "Start records to your folder. Nothing is sent online."
        case .stream: return "Start \(stream) without recording."
        case .both: return "Start \(stream) and records to your folder."
        }
    }
    private var duckingCaption: String {
        switch model.configuration.systemAudioDucking {
        case .off: "App audio stays at its level; suits music streams."
        case .light: "Drops app audio 6 dB; music stays present under your voice. With speakers, use headphones or Echo cancellation."
        case .medium: "Drops app audio 12 dB; game audio steps back for commentary. With speakers, use headphones or Echo cancellation."
        case .deep: "Drops app audio 18 dB; music tucks well under speech. With speakers, use headphones or Echo cancellation."
        }
    }
    private var layoutTab: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                SceneStage(model: model, engine: engine, monitorHeight: 216, scenesBeside: true)
                if let error = engine.videoPreviewError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }.padding(.top, 16).padding(.bottom, 12)
            Divider()
            Form {
                Section("Webcam") {
                    setting("Show webcam", \.cameraEnabled) {
                        Toggle("Show webcam", isOn: model.enabledBinding(for: .camera))
                    }
                    if model.configuration.cameraEnabled {
                        webcamRows
                    }
                }
                Section("Background") {
                    setting("Fill", \.backgroundStyle) {
                        Picker("Background fill", selection: $model.configuration.backgroundStyle) {
                            ForEach(BackgroundStyle.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    if model.configuration.backgroundStyle == .image {
                        imageRow(.background)
                    }
                    if [.color, .image, .mirror].contains(model.configuration.backgroundStyle) {
                        SettingRow(title: model.configuration.backgroundStyle == .color ? "Color" : "Fallback color",
                                   changed: model.configuration.backgroundRed != defaults.backgroundRed || model.configuration.backgroundGreen != defaults.backgroundGreen || model.configuration.backgroundBlue != defaults.backgroundBlue,
                                   reset: {
                                       var next = model.configuration
                                       next.backgroundRed = defaults.backgroundRed
                                       next.backgroundGreen = defaults.backgroundGreen
                                       next.backgroundBlue = defaults.backgroundBlue
                                       model.configuration = next
                                   }) {
                            ColorPicker("Background color", selection: backgroundColor, supportsOpacity: false)
                        }
                    } else if model.configuration.backgroundStyle == .blur {
                        setting("Blur", \.backgroundBlurRadius) {
                            SliderValue(title: "Blur", value: $model.configuration.backgroundBlurRadius,
                                        range: 0...80, readout: "\(Int(model.configuration.backgroundBlurRadius))")
                        }
                    }
                }
                Section {
                    setting("Message", \.awayMessage) {
                        TextField("Away message", text: $model.configuration.awayMessage, prompt: Text("Be right back"))
                    }
                    setting("Subtitle", \.awaySubtitle) {
                        TextField("Away subtitle", text: $model.configuration.awaySubtitle, prompt: Text("Optional, e.g. Back in 5 minutes"))
                    }
                    setting("Background", \.awayBackground) {
                        Picker("Away background", selection: $model.configuration.awayBackground) {
                            ForEach(AwayBackground.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                    }
                    if model.configuration.awayBackground == .color {
                        SettingRow(title: "Color",
                                   changed: model.configuration.awayRed != defaults.awayRed || model.configuration.awayGreen != defaults.awayGreen || model.configuration.awayBlue != defaults.awayBlue,
                                   reset: {
                                       var next = model.configuration
                                       next.awayRed = defaults.awayRed; next.awayGreen = defaults.awayGreen; next.awayBlue = defaults.awayBlue
                                       model.configuration = next
                                   }) {
                            ColorPicker("Away color", selection: awayColor, supportsOpacity: false)
                        }
                    } else if model.configuration.awayBackground == .image {
                        imageRow(.away)
                    }
                    setting("Mute microphone while away", \.awayMutesMicrophone) {
                        Toggle("Mute microphone while away", isOn: $model.configuration.awayMutesMicrophone)
                    }
                } header: {
                    Text("Away")
                } footer: {
                    Text("Away stops screen capture and hides the webcam; chat stays up. Your own mute button is left as it was.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }
    }
    @ViewBuilder private var webcamRows: some View {
        if model.configuration.layout.showsDesktop {
            setting("Frame", \.cameraFrame) {
                Picker("Webcam frame", selection: $model.configuration.cameraFrame) {
                    ForEach(CameraFrame.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
            }
            SettingRow(title: "Border",
                       changed: model.configuration.cameraBorder != defaults.cameraBorder || model.configuration.cameraBorderRed != defaults.cameraBorderRed || model.configuration.cameraBorderGreen != defaults.cameraBorderGreen || model.configuration.cameraBorderBlue != defaults.cameraBorderBlue,
                       reset: {
                           var next = model.configuration
                           next.cameraBorder = defaults.cameraBorder
                           next.cameraBorderRed = defaults.cameraBorderRed
                           next.cameraBorderGreen = defaults.cameraBorderGreen
                           next.cameraBorderBlue = defaults.cameraBorderBlue
                           model.configuration = next
                       }) {
                HStack {
                    if model.configuration.cameraBorder != .none {
                        ColorPicker("Border color", selection: borderColor, supportsOpacity: false)
                    }
                    Picker("Webcam border", selection: $model.configuration.cameraBorder) {
                        ForEach(CameraBorder.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).fixedSize()
                }
            }
        }
        if model.configuration.layout == .desktopChat {
            setting("Position", \.cameraAnchor) {
                Picker("Webcam position", selection: cameraPosition) {
                    if !CameraPreset.allCases.contains(where: { $0.anchor == model.configuration.cameraAnchor }) {
                        Text("Custom").tag("custom")
                    }
                    ForEach(CameraPreset.allCases) { Text($0.title).tag($0.rawValue) }
                    Divider()
                    Text("Arrange on Desktop… (⌃⌥⌘M)").tag(Self.arrangeTag).disabled(!model.canArrangeCamera)
                }.fixedSize()
            }.help(model.configuration.windowID != nil
                   ? "Pick a spot or drag the webcam in the preview above."
                   : "Pick a spot, drag the webcam in the preview above, or arrange it over your desktop.")
            setting("Size", \.cameraSize) {
                SliderValue(title: "Webcam size", value: $model.configuration.cameraSize, range: 0.12...0.4,
                            readout: model.configuration.cameraSize.formatted(.percent.precision(.fractionLength(0))))
            }
            setting("Size when punched in", \.cameraPunchInSize) {
                SliderValue(title: "Webcam size when punched in", value: $model.configuration.cameraPunchInSize, range: 0.4...0.9,
                            readout: model.configuration.cameraPunchInSize.formatted(.percent.precision(.fractionLength(0))))
            }.help("Punch in (⌃⌥⌘V or the menu's Punch in button) enlarges the webcam to this size.")
            setting("Move aside when the pointer is near", \.cameraAvoidCursor) {
                Toggle("Move aside when the pointer is near", isOn: $model.configuration.cameraAvoidCursor)
            }.help("The webcam steps to the other side while the pointer is close, then returns. Display capture only; paused during punch-in.")
        }
        // macOS shows its Video Effects panel only while this app has the camera open.
        LabeledContent("Video effects") {
            if engine.cameraOpen {
                Button("Open…") { model.showVideoEffects() }
            } else {
                Button("Turn On Preview") { Task { await engine.setVideoPreviewMode(.program) } }
            }
        }.help("Portrait, Center Stage, Studio Light, and gesture reactions for your camera. macOS offers them while a preview or session uses the webcam.")
    }
    /// A preset's name, "custom" for a dragged spot, or the arrange action, which keeps the position.
    private static let arrangeTag = "\u{0}arrange"
    private var cameraPosition: Binding<String> {
        Binding(get: { CameraPreset.allCases.first { $0.anchor == model.configuration.cameraAnchor }?.rawValue ?? "custom" },
                set: { value in
                    // Actions keep the selection; re-render so the menu shows the position again.
                    if value == Self.arrangeTag { model.toggleCameraArrange?(); model.objectWillChange.send() }
                    else if let preset = CameraPreset(rawValue: value) { model.configuration.cameraAnchor = preset.anchor }
                })
    }
    private var borderColor: Binding<Color> {
        Binding(
            get: { Color(red: model.configuration.cameraBorderRed, green: model.configuration.cameraBorderGreen, blue: model.configuration.cameraBorderBlue) },
            set: { color in
                guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return }
                var configuration = model.configuration
                configuration.cameraBorderRed = Double(resolved.redComponent)
                configuration.cameraBorderGreen = Double(resolved.greenComponent)
                configuration.cameraBorderBlue = Double(resolved.blueComponent)
                model.configuration = configuration
            }
        )
    }
    private var backgroundColor: Binding<Color> {
        Binding(
            get: { Color(red: model.configuration.backgroundRed, green: model.configuration.backgroundGreen, blue: model.configuration.backgroundBlue) },
            set: { color in
                guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return }
                var configuration = model.configuration
                configuration.backgroundRed = Double(resolved.redComponent)
                configuration.backgroundGreen = Double(resolved.greenComponent)
                configuration.backgroundBlue = Double(resolved.blueComponent)
                model.configuration = configuration
            }
        )
    }
    private var awayColor: Binding<Color> {
        Binding(
            get: { Color(red: model.configuration.awayRed, green: model.configuration.awayGreen, blue: model.configuration.awayBlue) },
            set: { color in
                guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return }
                var configuration = model.configuration
                configuration.awayRed = Double(resolved.redComponent)
                configuration.awayGreen = Double(resolved.greenComponent)
                configuration.awayBlue = Double(resolved.blueComponent)
                model.configuration = configuration
            }
        )
    }
    /// An imported picture: its name, Choose…, a reset that forgets it, and any import problem.
    @ViewBuilder private func imageRow(_ slot: StudioModel.ImageSlot) -> some View {
        let importing = model.importingImages.contains(slot)
        SettingRow(title: "Image", changed: !model.configuration[keyPath: slot.path].isEmpty || importing,
                   reset: { model.removeImage(slot) }) {
            HStack {
                if let filename = model.imageFilename(slot) {
                    Label(filename, systemImage: "photo").lineLimit(1).truncationMode(.middle)
                }
                Button(importing ? "Importing…" : "Choose…") { model.chooseImage(slot) }
                    .disabled(importing)
            }
        }
        if let error = model.imageErrors[slot] { Text(error).font(.caption).foregroundStyle(.secondary) }
    }
    private var censorColor: Binding<Color> {
        Binding(
            get: { Color(red: model.configuration.privacyCensorRed, green: model.configuration.privacyCensorGreen, blue: model.configuration.privacyCensorBlue) },
            set: { color in
                guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return }
                var configuration = model.configuration
                configuration.privacyCensorRed = Double(resolved.redComponent)
                configuration.privacyCensorGreen = Double(resolved.greenComponent)
                configuration.privacyCensorBlue = Double(resolved.blueComponent)
                model.configuration = configuration
            }
        )
    }
    private var chatTab: some View {
        Form {
            Section {
                TwitchConnectionView(session: model.twitch, locked: model.demo || engine.isRunning || model.busy)
                TwitchChatSettings(model: model, engine: engine)
            } header: {
                Text("Twitch chat")
            } footer: {
                Text("Leave Channel blank for your own. The Prompter's chat mode reads it too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("In the scene") {
                setting("Show chat", \.chatEnabled) {
                    Toggle("Show chat", isOn: $model.configuration.chatEnabled)
                }
                if model.configuration.chatEnabled {
                    setting("Side", \.chatOnLeft) {
                        Picker("Chat side", selection: $model.configuration.chatOnLeft) {
                            Text("Left").tag(true)
                            Text("Right").tag(false)
                        }.pickerStyle(.segmented).fixedSize()
                    }.help("Desktop and Split")
                    setting("Width", \.chatWidth) {
                        SliderValue(title: "Chat width", value: $model.configuration.chatWidth,
                                    range: 288...576, step: 32, readout: "\(Int(model.configuration.chatWidth)) px")
                    }.help("Split uses a fixed column.")
                }
            }
            if model.configuration.chatEnabled {
                Section {
                    ChatAppearanceControls(appearance: $model.configuration.chatAppearance, collapsesDetails: true)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text(chatPresetCaption)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
    }
    private var chatPresetCaption: String {
        switch model.configuration.chatAppearance.preset {
        case .terminal: "24 px text with name colors, emotes, and highlights."
        case .compact: "Smaller 20 px text fits more messages."
        case .largeText: "Bigger 32 px text, easier to read on small screens."
        case .monochrome: "Plain 24 px text: no name colors, emotes, or highlights."
        case nil: "Your own mix of details. Choose a preset to start over."
        }
    }
    private var outputTab: some View {
        Form {
            Section {
                setting("When you press Start", \.outputMode) {
                    Picker("When you press Start", selection: $model.configuration.outputMode) { ForEach(OutputMode.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).fixedSize()
                }
            } footer: {
                Text(startSummary).font(.caption).foregroundStyle(.secondary)
            }
            if model.configuration.outputMode != .stream {
                Section {
                    setting("Folder", \.recordingDirectory) {
                        HStack {
                            Label(FileManager.default.displayName(atPath: model.configuration.recordingDirectory), systemImage: "folder")
                                .lineLimit(1).truncationMode(.middle)
                                .help((model.configuration.recordingDirectory as NSString).abbreviatingWithTildeInPath)
                            Button("Choose…") { model.chooseRecordingFolder() }
                        }
                    }.help("Existing recordings are never overwritten.")
                    setting("Format", \.recordingFormat) {
                        Picker("Recording format", selection: $model.configuration.recordingFormat) {
                            ForEach(RecordingFormat.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).fixedSize()
                    }.help("Video is H.264 at 6 Mb/s in either format.")
                    setting("Audio bitrate", \.recordingAudioBitrateKbps) {
                        Picker("Recording audio bitrate", selection: $model.configuration.recordingAudioBitrateKbps) {
                            ForEach(RecordingAudioBitrate.allCases) { Text("\($0.rawValue) kb/s\($0 == .standard ? " (smallest files)" : $0 == .highest ? " (best quality)" : "")").tag($0) }
                        }
                    }.help("Higher keeps more detail in music; files grow slightly. Recordings only; streams always use 160 kb/s.")
                } header: {
                    Text("Recording")
                } footer: {
                    Text(model.configuration.recordingFormat == .mp4
                         ? "MP4 plays in QuickTime and most editors, and survives a crash."
                         : "MKV survives a crash, but QuickTime and Finder can't play it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.configuration.outputMode != .record {
                Section("Streaming") {
                    SettingRow(title: "Service") {
                        Picker("Streaming service", selection: $model.configuration.streamService) {
                            ForEach(StreamService.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    if model.configuration.streamService == .twitch {
                        TwitchConnectionView(session: model.twitch, locked: model.demo || engine.isRunning || model.busy)
                    } else {
                        setting("Server URL", \.streamURL) {
                            TextField("Server URL", text: $model.configuration.streamURL, prompt: Text("rtmp://… (without stream key)"))
                        }
                        SettingRow(title: "Stream key") {
                            HStack {
                                SecureField("Stream key", text: $model.streamKey)
                                Button(model.keySaved ? "Saved" : "Save to Keychain") { model.saveKey() }
                                    .disabled(model.streamKey.isEmpty || model.demo)
                            }
                        }
                    }
                    // The bandwidth test needs a Twitch ingest, which a custom server can also be.
                    if model.configuration.streamService == .twitch || model.configuration.twitchTestMode
                        || model.configuration.streamURL.contains("live-video.net") || model.configuration.streamURL.contains("twitch.tv") {
                        setting("Test stream (not public)", \.twitchTestMode) {
                            Toggle("Test stream (not public)", isOn: $model.configuration.twitchTestMode)
                        }.help("Sends video to Twitch without showing it to viewers.")
                        if model.configuration.twitchTestMode {
                            Link("Open Twitch Inspector", destination: URL(string: "https://inspector.twitch.tv")!)
                        }
                    }
                }
            }
            Section {
                setting("Privacy shield", \.privacyShieldEnabled) {
                    Toggle("Privacy shield", isOn: $model.configuration.privacyShieldEnabled)
                }.help("Output runs about 0.5 s behind while it's on. Small, brief, or stylized text can be missed.")
                if model.configuration.privacyShieldEnabled {
                    setting("Also hide email, phone, card, and SSN", \.privacyHidesPersonalInfo) {
                        Toggle("Also hide email, phone, card, and SSN patterns", isOn: $model.configuration.privacyHidesPersonalInfo)
                    }
                    SettingRow(title: "Cover with",
                               changed: model.configuration.privacyCensorStyle != defaults.privacyCensorStyle || model.configuration.privacyCensorRed != defaults.privacyCensorRed || model.configuration.privacyCensorGreen != defaults.privacyCensorGreen || model.configuration.privacyCensorBlue != defaults.privacyCensorBlue,
                               reset: {
                                   var next = model.configuration
                                   next.privacyCensorStyle = defaults.privacyCensorStyle
                                   next.privacyCensorRed = defaults.privacyCensorRed
                                   next.privacyCensorGreen = defaults.privacyCensorGreen
                                   next.privacyCensorBlue = defaults.privacyCensorBlue
                                   model.configuration = next
                               }) {
                        HStack {
                            ColorPicker("Cover color", selection: censorColor, supportsOpacity: false)
                            Picker("Cover with", selection: $model.configuration.privacyCensorStyle) {
                                ForEach(PrivacyCensorStyle.allCases) { Text($0.title).tag($0) }
                            }.fixedSize()
                        }
                    }
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Hides API keys, tokens, and private keys that appear on screen\(model.configuration.privacyShieldEnabled ? "; output runs about 0.5 s behind" : ""). A safety net, not a guarantee.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).disabled(engine.isRunning || model.busy)
    }
}

struct SystemAudioSourcePicker: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: StudioEngine

    private var selection: Binding<String> {
        Binding(get: { model.configuration.systemAudioApplicationID }, set: { value in
            if value == StudioSettings.refreshTag { model.refreshSources(); model.objectWillChange.send() } else { model.configuration.systemAudioApplicationID = value }
        })
    }
    var body: some View {
        Picker("Audio from", selection: selection) {
            Text("All apps").tag("")
            ForEach(engine.captureApplications) { Text($0.name).tag($0.id) }
            if !model.configuration.systemAudioApplicationID.isEmpty,
               !engine.captureApplications.contains(where: { $0.id == model.configuration.systemAudioApplicationID }) {
                Text("Unavailable: \(model.configuration.systemAudioApplicationID)").tag(model.configuration.systemAudioApplicationID)
            }
            Divider()
            Text("Refresh List").tag(StudioSettings.refreshTag)
        }
        .help("Pick one app, such as Ableton, to leave out other apps and alerts. If it quits, capture stops.")
        .disabled(engine.isRunning || model.busy)
    }
}

struct AnnotationSettingsView: View {
    @ObservedObject var settings: AnnotationSettings
    private var strokeColorBinding: Binding<Color> {
        Binding(get: { Color(nsColor: settings.strokeColor) }, set: { settings.strokeColor = NSColor($0) })
    }
    private var highlighterColorBinding: Binding<Color> {
        Binding(get: { Color(nsColor: settings.highlighterColor) }, set: { settings.highlighterColor = NSColor($0) })
    }
    private var fillColorBinding: Binding<Color> {
        Binding(get: { Color(nsColor: settings.fillColor) }, set: { settings.fillColor = NSColor($0) })
    }
    /// Off is a clear fill, as in the drawing palette; on starts from a translucent pen color.
    private var fillsShapes: Binding<Bool> {
        Binding(get: { settings.fillColor.alphaComponent > 0 },
                set: { settings.fillColor = $0 ? settings.strokeColor.withAlphaComponent(0.3) : .clear })
    }
    @State private var learning = false
    @State private var monitor: Any?
    @State private var learningAction: AnnotationPenAction = .none
    private var mappedButtons: [Int] { Array(1...31).filter { settings.penAction(for: $0) != .none }.sorted() }
    private func buttonLabel(_ button: Int) -> String { button == 1 ? "Right-click button" : button == 2 ? "Middle-click button" : "Button \(button)" }
    private func beginLearning(_ action: AnnotationPenAction) {
        learningAction = action
        learning = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .otherMouseDown, .keyDown]) { event in
            if event.type == .keyDown && event.keyCode == 53 { endLearning(); return nil }
            guard event.type != .keyDown, (1...31).contains(event.buttonNumber), learningAction != .none else { return event }
            settings.setPenAction(learningAction, for: event.buttonNumber)
            endLearning()
            return event
        }
    }
    private func endLearning() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        learning = false
        learningAction = .none
    }
    private func actionBinding(for button: Int) -> Binding<AnnotationPenAction> {
        Binding(get: { settings.penAction(for: button) }, set: { settings.setPenAction($0, for: button) })
    }
    var body: some View {
        Form {
            Section {
                SettingRow(title: "Width", changed: settings.strokeWidth != AnnotationSettings.defaultStrokeWidth,
                           reset: { settings.strokeWidth = AnnotationSettings.defaultStrokeWidth }) {
                    SliderValue(title: "Pen width", value: $settings.strokeWidth, range: 1...24, step: 1,
                                readout: "\(Int(settings.strokeWidth)) pt")
                }
                SettingRow(title: "Smoothing", changed: settings.smoothing != AnnotationSettings.defaultSmoothing,
                           reset: { settings.smoothing = AnnotationSettings.defaultSmoothing }) {
                    // Endpoint labels instead of a readout; the track lines up with the Width slider's.
                    HStack(spacing: 8) {
                        Text("Off").foregroundStyle(.secondary)
                        Slider(value: $settings.smoothing, in: 0...1).frame(width: 220)
                            .accessibilityLabel("Smoothing").accessibilityValue(smoothingLabel)
                        Text("Strong").foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                    }
                }
            } header: {
                Text("Pen")
            } footer: {
                Text("Smoothing steadies shaky strokes but adds slight lag.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Eraser") {
                SettingRow(title: "Erases", changed: settings.eraseMode != AnnotationSettings.defaultEraseMode,
                           reset: { settings.eraseMode = AnnotationSettings.defaultEraseMode }) {
                    Picker("Eraser", selection: $settings.eraseMode) {
                        Text("Whole strokes").tag(AnnotationEraseMode.object)
                        Text("Just what you touch").tag(AnnotationEraseMode.partial)
                    }.pickerStyle(.segmented).fixedSize()
                }
            }
            Section("Colors") {
                SettingRow(title: "Pen", changed: !AnnotationSettings.sameColor(settings.strokeColor, AnnotationSettings.defaultStrokeColor),
                           reset: { settings.strokeColor = AnnotationSettings.defaultStrokeColor }) {
                    ColorPicker("Pen color", selection: strokeColorBinding, supportsOpacity: false)
                }
                SettingRow(title: "Highlighter", changed: !AnnotationSettings.sameColor(settings.highlighterColor, AnnotationSettings.defaultHighlighterColor),
                           reset: { settings.highlighterColor = AnnotationSettings.defaultHighlighterColor }) {
                    ColorPicker("Highlighter color", selection: highlighterColorBinding, supportsOpacity: false)
                }
                SettingRow(title: "Fill shapes", changed: settings.fillColor.alphaComponent > 0,
                           reset: { settings.fillColor = AnnotationSettings.defaultFillColor }) {
                    Toggle("Fill shapes", isOn: fillsShapes)
                }.help("Fills rectangles and ellipses with a color.")
                if settings.fillColor.alphaComponent > 0 {
                    SettingRow(title: "Fill color") {
                        ColorPicker("Shape fill color", selection: fillColorBinding, supportsOpacity: true)
                    }
                }
            }
            Section {
                ForEach(mappedButtons, id: \.self) { button in
                    SettingRow(title: buttonLabel(button)) {
                        Picker(buttonLabel(button), selection: actionBinding(for: button)) {
                            ForEach(AnnotationPenAction.allCases) { Text($0 == .none ? "None (remove)" : $0.title).tag($0) }
                        }.fixedSize()
                    }
                }
                if mappedButtons.contains(where: { settings.penAction(for: $0) == .straighten }) {
                    SettingRow(title: "Straighten only while held", changed: settings.holdToStraighten != AnnotationSettings.defaultHoldToStraighten,
                               reset: { settings.holdToStraighten = AnnotationSettings.defaultHoldToStraighten }) {
                        Toggle("Straighten only while held", isOn: $settings.holdToStraighten)
                    }.help("On: lines are straight while you hold the Straighten button. Off: each press turns straight lines on or off.")
                }
                HStack {
                    if !settings.penActionsAreDefault {
                        Button("Reset Pen Buttons") { settings.restorePenDefaults() }
                    }
                    Spacer()
                    Menu("Add Pen Button…") {
                        ForEach(AnnotationPenAction.allCases.filter { $0 != .none }) { action in
                            Button(action.title) { beginLearning(action) }
                        }
                    }.menuStyle(.button).fixedSize()
                    .help("If your tablet driver hides a button, set it to send a click first.")
                }
            } header: {
                Text("Pen buttons")
            } footer: {
                Text("Buttons on the side of your pen or stylus. To add one, choose its action, then press the button.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .sheet(isPresented: $learning, onDismiss: endLearning) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Learn pen button").font(.headline)
                Text("Press the pen button to assign. Esc cancels.")
                Button("Cancel") { endLearning() }
            }.padding(24).frame(width: 390)
        }
        .onDisappear { endLearning() }
    }

    private var smoothingLabel: String {
        switch settings.smoothing {
        case 0: return "Off"
        case ..<0.34: return "Light"
        case ..<0.67: return "Balanced"
        default: return "Strong"
        }
    }
}

struct ClickableDisclosure<Content: View>: View {
    let title: String
    /// Trailing summary of what's inside, such as "2 hidden".
    var detail: String?
    @ViewBuilder let content: () -> Content
    @State private var isExpanded = false

    init(_ title: String, detail: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Text(title)
                    Spacer(minLength: 0)
                    if let detail { Text(detail).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(detail ?? "")
            if isExpanded {
                content().padding(.leading, 18)
            }
        }
    }
}
