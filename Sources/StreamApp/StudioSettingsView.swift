import SwiftUI
import AppKit

private struct SliderValueRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let readout: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 96, alignment: .leading)
            Group {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
            }.accessibilityLabel(title)
            Text(readout).monospacedDigit().frame(width: 48, alignment: .trailing)
        }
    }
}

private struct SettingResetButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "arrow.counterclockwise") }
            .buttonStyle(.borderless)
            .help("Reset \(title) to default")
            .accessibilityLabel("Reset \(title) to default")
            .disabled(!enabled)
    }
}

struct StudioSettings: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: StudioEngine
    let openOnboarding: () -> Void
    @State private var confirmRestoreAll = false
    private let defaults = StudioConfiguration()

    var body: some View {
        VStack(spacing: 12) {
            TabView(selection: $model.settingsTab) {
                captureTab.tabItem { Label("Capture", systemImage: "display") }.tag(StudioModel.SettingsTab.sources)
                audioTab.tabItem { Label("Audio", systemImage: "waveform") }.tag(StudioModel.SettingsTab.audio)
                layoutTab.tabItem { Label("Layout", systemImage: "rectangle.3.group") }.tag(StudioModel.SettingsTab.layout)
                chatTab.tabItem { Label("Chat", systemImage: "bubble.left.and.text.bubble.right") }.tag(StudioModel.SettingsTab.chat)
                TeleprompterControls(model: model)
                    .tabItem { Label("Prompter", systemImage: "text.bubble") }.tag(StudioModel.SettingsTab.teleprompter)
                AnnotationSettingsView(settings: model.annotationSettings)
                    .tabItem { Label("Drawing", systemImage: "pencil.tip") }.tag(StudioModel.SettingsTab.drawing)
                outputTab.tabItem { Label("Output", systemImage: "antenna.radiowaves.left.and.right") }.tag(StudioModel.SettingsTab.outputs)
            }
            HStack {
                Button("Run Setup…", action: openOnboarding).disabled(engine.isRunning || model.busy)
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                Button("Restore Defaults…", role: .destructive) { confirmRestoreAll = true }
                    .disabled(model.busy || engine.isRunning)
            }
        }.padding(16).frame(width: 680, height: 620).disabled(model.busy)
        .alert("Restore all defaults?", isPresented: $confirmRestoreAll) {
            Button("Restore Defaults", role: .destructive) {
                Task { await model.restoreAllDefaults() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Recordings, credentials, and permissions are kept.")
        }
        .onAppear { model.loadDevices() }
        .task(id: model.settingsVisible && model.settingsTab == .layout && engine.videoPreviewMode != nil) {
            await engine.setSettingsPreview(
                visible: model.settingsVisible && model.settingsTab == .layout && engine.videoPreviewMode != nil,
                configuration: model.configuration, synthetic: model.demo)
        }
    }

    private func resetButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        SettingResetButton(title: title, enabled: enabled, action: action)
    }

    private func setting<Value: Equatable, Content: View>(_ title: String,
        _ key: WritableKeyPath<StudioConfiguration, Value>, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            content()
            resetButton(title, enabled: model.configuration[keyPath: key] != defaults[keyPath: key]) {
                model.configuration[keyPath: key] = defaults[keyPath: key]
            }
        }
    }
    private var sourceSelection: Binding<String> {
        Binding(get: {
            if let window = model.configuration.windowID { return "window:\(window)" }
            if let display = model.configuration.displayID { return "display:\(display)" }
            return ""
        }, set: { value in
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
            Section("Source") {
                CaptureAccessNotice(model: model, permission: .screen)
                HStack {
                    Picker("Capture", selection: sourceSelection) {
                        Text("Choose a source").tag("")
                        ForEach(model.sources, id: \.stableID) { Text($0.name).tag($0.stableID) }
                    }
                    Button { model.refreshSources() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh displays, windows, and apps").accessibilityLabel("Refresh sources")
                    resetButton("Capture source", enabled: model.configuration.displayID != defaults.displayID || model.configuration.windowID != defaults.windowID) {
                        model.configuration.displayID = defaults.displayID
                        model.configuration.windowID = defaults.windowID
                    }
                }.disabled(engine.isRunning || model.busy)
                setting("Include menu bar", \.includeMenuBar) {
                    Toggle("Include menu bar", isOn: $model.configuration.includeMenuBar)
                }.disabled(model.configuration.windowID != nil)
                setting("Show StreamApp windows", \.showStreamAppWindows) {
                    Toggle("Show StreamApp windows", isOn: $model.configuration.showStreamAppWindows)
                        .help("Menu and settings windows in display capture. The teleprompter has its own setting in Prompter.")
                }.disabled(model.busy || model.configuration.windowID != nil)
            }
            Section("Camera") {
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
                }
                setting("Mirror webcam", \.mirrorCamera) {
                    Toggle("Mirror", isOn: $model.configuration.mirrorCamera)
                }
                Button("Video Effects…") { model.showVideoEffects() }
                    .help("Portrait, Center Stage, and gesture reactions for your camera")
            }.disabled(engine.isRunning || model.busy)
            Section("Hide from capture") {
                ClickableDisclosure(disclosureTitle("Apps", hidden: model.configuration.excludedApplicationIDs.count)) {
                    ForEach(engine.captureApplications) { app in
                        Toggle(app.name, isOn: exclusion(\.excludedApplicationIDs, app.id))
                    }
                    ForEach(model.configuration.excludedApplicationIDs.filter { id in !engine.captureApplications.contains { $0.id == id } }, id: \.self) { id in
                        Toggle(id, isOn: exclusion(\.excludedApplicationIDs, id)).foregroundStyle(.secondary)
                    }
                }
                ClickableDisclosure(disclosureTitle("Windows", hidden: model.configuration.excludedWindowIDs.count)) {
                    ForEach(model.sources.filter { $0.kind == .window }, id: \.stableID) { source in
                        Toggle(source.name, isOn: exclusion(\.excludedWindowIDs, source.id))
                    }
                }.help("Window rules last until StreamApp quits.")
            }.disabled(engine.isRunning || model.configuration.windowID != nil)
        }.formStyle(.grouped)
        .task {
            if model.access(.screen) == .allowed && model.sources.isEmpty { model.refreshSources() }
        }
    }
    private func disclosureTitle(_ title: String, hidden: Int) -> String {
        hidden == 0 ? title : "\(title) · \(hidden) hidden"
    }
    private var audioTab: some View {
        Form {
            Section("App audio") {
                CaptureAccessNotice(model: model, permission: .screen)
                setting("Capture app audio", \.systemAudioEnabled) {
                    Toggle("Capture app audio", isOn: model.enabledBinding(for: .screen))
                }
                HStack {
                    SystemAudioSourcePicker(model: model, engine: engine)
                    resetButton("Audio source", enabled: model.configuration.systemAudioApplicationID != defaults.systemAudioApplicationID) {
                        model.configuration.systemAudioApplicationID = defaults.systemAudioApplicationID
                    }
                }
            }.disabled(engine.isRunning)
            Section("Microphone") {
                CaptureAccessNotice(model: model, permission: .microphone)
                setting("Use microphone", \.microphoneEnabled) {
                    Toggle("Use microphone", isOn: model.enabledBinding(for: .microphone))
                }
                setting("Microphone", \.microphoneID) {
                    Picker("Device", selection: $model.configuration.microphoneID) {
                        Text("System default").tag("")
                        ForEach(model.microphones) { Text($0.name).tag($0.id) }
                        if !model.configuration.microphoneID.isEmpty,
                           !model.microphones.contains(where: { $0.id == model.configuration.microphoneID }) {
                            Text("Unavailable microphone").tag(model.configuration.microphoneID)
                        }
                    }.help("With AirPods, pick the Mac or a USB mic to keep playback quality high.")
                }
            }.disabled(engine.isRunning)
            Section("Processing") {
                setting("Microphone compression", \.microphoneCompressionEnabled) {
                    Toggle("Compression", isOn: $model.configuration.microphoneCompressionEnabled)
                        .help("Softens loud speech: 3:1 above −18 dBFS.")
                }
                setting("Echo cancellation", \.microphoneEchoCancellationEnabled) {
                    Toggle("Echo cancellation", isOn: $model.configuration.microphoneEchoCancellationEnabled)
                        .help("Removes speaker playback from the mic. Makes the mic mono; may soften quiet speech or music.")
                }
                if model.configuration.microphoneEchoCancellationEnabled, let status = engine.echoCancellationStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                setting("Noise reduction", \.microphoneNoiseReductionEnabled) {
                    Toggle("Noise reduction", isOn: $model.configuration.microphoneNoiseReductionEnabled)
                        .help("Reduces hiss and fan noise. Makes the mic mono; adds about 7 ms delay.")
                }
            }
        }.formStyle(.grouped)
    }
    private var layoutTab: some View {
        VStack(spacing: 0) {
            StudioVideoPreview(model: model, engine: engine).padding(12)
            Form {
                Section("Scene") {
                    setting("Scene", \.layout) {
                        Picker("Scene", selection: $model.configuration.layout) { ForEach(SceneLayout.allCases) { Text($0.title).tag($0) } }
                    }
                    DockFitControl(model: model, fit: model.dockFit)
                }
                if model.configuration.layout == .desktopChat {
                    Section("Webcam") {
                        setting("Webcam frame", \.cameraFrame) {
                            Picker("Frame", selection: $model.configuration.cameraFrame) {
                                ForEach(CameraFrame.allCases) { Text($0.title).tag($0) }
                            }.pickerStyle(.segmented)
                        }
                        setting("Webcam corner", \.cameraCorner) {
                            Picker("Corner", selection: $model.configuration.cameraCorner) {
                                ForEach(CameraCorner.allCases) { Text($0.title).tag($0) }
                            }
                        }
                        setting("Webcam size", \.cameraSize) {
                            SliderValueRow(title: "Size", value: $model.configuration.cameraSize, range: 0.12...0.4,
                                           readout: model.configuration.cameraSize.formatted(.percent.precision(.fractionLength(0))))
                        }
                        setting("Punched-in size", \.cameraPunchInSize) {
                            SliderValueRow(title: "Punch-in size", value: $model.configuration.cameraPunchInSize, range: 0.4...0.9,
                                           readout: model.configuration.cameraPunchInSize.formatted(.percent.precision(.fractionLength(0))))
                        }
                    }
                }
                Section("Background") {
                    setting("Fill", \.backgroundStyle) {
                        Picker("Fill", selection: $model.configuration.backgroundStyle) {
                            ForEach(BackgroundStyle.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    if model.configuration.backgroundStyle == .image {
                        HStack {
                            Button(model.importingBackgroundImage ? "Importing…" : "Choose Image…") { model.chooseBackgroundImage() }
                                .disabled(model.importingBackgroundImage)
                            if let filename = model.backgroundImageFilename {
                                Text(filename).lineLimit(1).truncationMode(.middle).font(.caption)
                            }
                            Spacer()
                            resetButton("Background image", enabled: !model.configuration.backgroundImagePath.isEmpty || model.importingBackgroundImage) {
                                model.removeBackgroundImage()
                            }
                        }
                        if let error = model.backgroundImageError { Text(error).font(.caption).foregroundStyle(.secondary) }
                    }
                    if [.color, .image, .mirror].contains(model.configuration.backgroundStyle) {
                        HStack {
                            ColorPicker(model.configuration.backgroundStyle == .color ? "Color" : "Fallback color", selection: backgroundColor, supportsOpacity: false)
                            resetButton("Background color", enabled: model.configuration.backgroundRed != defaults.backgroundRed || model.configuration.backgroundGreen != defaults.backgroundGreen || model.configuration.backgroundBlue != defaults.backgroundBlue) {
                                var next = model.configuration
                                next.backgroundRed = defaults.backgroundRed
                                next.backgroundGreen = defaults.backgroundGreen
                                next.backgroundBlue = defaults.backgroundBlue
                                model.configuration = next
                            }
                        }
                    } else if model.configuration.backgroundStyle == .blur {
                        setting("Blur", \.backgroundBlurRadius) {
                            SliderValueRow(title: "Blur", value: $model.configuration.backgroundBlurRadius,
                                           range: 0...80, readout: "\(Int(model.configuration.backgroundBlurRadius))")
                        }
                    }
                }
            }.formStyle(.grouped)
                .overlay(alignment: .top) {
                    LinearGradient(colors: [.black.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 12).allowsHitTesting(false).accessibilityHidden(true)
                }
        }
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
    private var chatTab: some View {
        Form {
            Section("Chat") {
                setting("Render chat", \.chatEnabled) {
                    Toggle("Render chat", isOn: $model.configuration.chatEnabled)
                }
                TwitchChatSettings(model: model, engine: engine)
                setting("Chat side", \.chatOnLeft) {
                    Picker("Side", selection: $model.configuration.chatOnLeft) {
                        Text("Left").tag(true)
                        Text("Right").tag(false)
                    }.pickerStyle(.segmented).help("Desktop scene only")
                }
                setting("Chat width", \.chatWidth) {
                    SliderValueRow(title: "Width", value: $model.configuration.chatWidth,
                                   range: 288...576, step: 32, readout: "\(Int(model.configuration.chatWidth)) px")
                }
            }
            Section("Appearance") {
                ChatAppearanceControls(appearance: $model.configuration.chatAppearance)
            }
        }.formStyle(.grouped)
    }
    private var outputTab: some View {
        Form {
            Section("Session") {
                setting("Session mode", \.outputMode) {
                    Picker("When you start", selection: $model.configuration.outputMode) { ForEach(OutputMode.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented)
                }
                Text(model.configuration.outputSummary).font(.caption).foregroundStyle(.secondary)
            }
            Section("Recording") {
                setting("Recording folder", \.recordingDirectory) {
                    LabeledContent("Folder") {
                        HStack {
                            Text((model.configuration.recordingDirectory as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: 320, alignment: .trailing)
                            Button("Choose…") { model.chooseRecordingFolder() }
                        }
                    }.help("Existing recordings are never overwritten.")
                }
                setting("Recording format", \.recordingFormat) {
                    Picker("Format", selection: $model.configuration.recordingFormat) {
                        ForEach(RecordingFormat.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                }
                Text(model.configuration.recordingFormat == .mp4
                     ? "Opens in QuickTime, Finder, and editors. Crash-safe. H.264 6 Mb/s · AAC 160 kb/s."
                     : "Crash-safe, but QuickTime and Finder can't play it. H.264 6 Mb/s · AAC 160 kb/s.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Streaming") {
                Picker("Service", selection: $model.configuration.streamService) {
                    ForEach(StreamService.allCases) { Text($0.title).tag($0) }
                }
                if model.configuration.streamService == .twitch {
                    TwitchConnectionView(session: model.twitch, locked: model.demo || engine.isRunning || model.busy)
                } else {
                    setting("Server URL", \.streamURL) {
                        TextField("Server URL", text: $model.configuration.streamURL, prompt: Text("rtmp://… (without stream key)"))
                    }
                    HStack {
                        SecureField("Stream key", text: $model.streamKey)
                        Button(model.keySaved ? "Saved" : "Save to Keychain") { model.saveKey() }
                            .disabled(model.streamKey.isEmpty || model.demo)
                    }
                }
                setting("Twitch test stream", \.twitchTestMode) {
                    Toggle("Twitch test stream", isOn: $model.configuration.twitchTestMode)
                        .help("Sends video to Twitch without going live.")
                }
                if model.configuration.twitchTestMode {
                    Link("Open Twitch Inspector", destination: URL(string: "https://inspector.twitch.tv")!)
                }
            }
        }.formStyle(.grouped).disabled(engine.isRunning || model.busy)
    }
}

struct SystemAudioSourcePicker: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: StudioEngine

    var body: some View {
        HStack {
            Picker("Audio from", selection: $model.configuration.systemAudioApplicationID) {
                Text("All apps (includes alerts)").tag("")
                ForEach(engine.captureApplications) { Text($0.name).tag($0.id) }
                if !model.configuration.systemAudioApplicationID.isEmpty,
                   !engine.captureApplications.contains(where: { $0.id == model.configuration.systemAudioApplicationID }) {
                    Text("Unavailable: \(model.configuration.systemAudioApplicationID)").tag(model.configuration.systemAudioApplicationID)
                }
            }.help("Pick one app, such as Ableton, to leave out other apps and alerts. If it quits, capture stops.")
            Button { model.refreshSources() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh apps").accessibilityLabel("Refresh apps")
        }.disabled(engine.isRunning || model.busy)
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
    private func resetButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        SettingResetButton(title: title, enabled: enabled, action: action)
    }
    @State private var learning = false
    @State private var monitor: Any?
    @State private var learningAction: AnnotationPenAction = .none
    private var mappedButtons: [Int] { Array(1...31).filter { settings.penAction(for: $0) != .none }.sorted() }
    private func buttonLabel(_ button: Int) -> String { button == 1 ? "Secondary (Button 1)" : button == 2 ? "Middle (Button 2)" : "Button \(button)" }
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
            Section("Pen") {
                HStack {
                    Text("Smoothing")
                    Slider(value: $settings.smoothing, in: 0...1) { Text("Smoothing") } minimumValueLabel: {
                        Text("Off").font(.caption).foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text("Strong").font(.caption).foregroundStyle(.secondary)
                    }.labelsHidden().accessibilityValue(smoothingLabel)
                    resetButton("Smoothing", enabled: settings.smoothing != AnnotationSettings.defaultSmoothing) { settings.smoothing = AnnotationSettings.defaultSmoothing }
                }
                HStack { Text("Width"); Slider(value: $settings.strokeWidth, in: 1...24, step: 1).accessibilityLabel("Stroke width"); Text("\(settings.strokeWidth, specifier: "%.0f") pt").monospacedDigit(); resetButton("Stroke width", enabled: settings.strokeWidth != AnnotationSettings.defaultStrokeWidth) { settings.strokeWidth = AnnotationSettings.defaultStrokeWidth } }
            }
            Section("Colors") {
                HStack { ColorPicker("Stroke", selection: strokeColorBinding, supportsOpacity: false); resetButton("Stroke", enabled: settings.strokeColor != AnnotationSettings.defaultStrokeColor) { settings.strokeColor = AnnotationSettings.defaultStrokeColor } }
                HStack { ColorPicker("Highlighter", selection: highlighterColorBinding, supportsOpacity: false); resetButton("Highlighter", enabled: settings.highlighterColor != AnnotationSettings.defaultHighlighterColor) { settings.highlighterColor = AnnotationSettings.defaultHighlighterColor } }
                HStack {
                    ColorPicker("Fill", selection: fillColorBinding, supportsOpacity: true)
                    Button("No fill") { settings.fillColor = settings.fillColor.withAlphaComponent(0) }.disabled(settings.fillColor.alphaComponent == 0)
                    resetButton("Fill", enabled: settings.fillColor != AnnotationSettings.defaultFillColor) { settings.fillColor = AnnotationSettings.defaultFillColor }
                }
            }
            Section("Tools") {
                HStack { Toggle("Hold to straighten", isOn: $settings.holdToStraighten); resetButton("Hold to straighten", enabled: settings.holdToStraighten != AnnotationSettings.defaultHoldToStraighten) { settings.holdToStraighten = AnnotationSettings.defaultHoldToStraighten } }
                HStack {
                    Picker("Eraser", selection: $settings.eraseMode) {
                        ForEach(AnnotationEraseMode.allCases) { Text($0.title).tag($0) }
                    }.help("Object removes whole strokes; Partial rubs out only what you touch.")
                    resetButton("Eraser", enabled: settings.eraseMode != AnnotationSettings.defaultEraseMode) {
                        settings.eraseMode = AnnotationSettings.defaultEraseMode
                    }
                }
            }
            Section("Pen buttons") {
                ForEach(mappedButtons, id: \.self) { button in
                    HStack {
                        Text(buttonLabel(button))
                        Spacer()
                        Picker("", selection: actionBinding(for: button)) { ForEach(AnnotationPenAction.allCases) { Text($0.title).tag($0) } }.labelsHidden().fixedSize()
                        Button("Learn") { beginLearning(settings.penAction(for: button)) }.disabled(settings.penAction(for: button) == .none)
                        resetButton("Reset \(buttonLabel(button))", enabled: settings.penAction(for: button) != .none) { settings.setPenAction(.none, for: button) }
                    }
                }
                HStack {
                    Menu("Learn Button") {
                        ForEach(AnnotationPenAction.allCases.filter { $0 != .none }) { action in
                            Button(action.title) { beginLearning(action) }
                        }
                    }.fixedSize()
                    .help("If your tablet driver suppresses a button, set it to send a click first.")
                    Spacer()
                    Button("Reset Pen Buttons") { settings.restorePenDefaults() }
                }
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
    @ViewBuilder let content: () -> Content
    @State private var isExpanded = false

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
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
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                content().padding(.leading, 18)
            }
        }
    }
}
