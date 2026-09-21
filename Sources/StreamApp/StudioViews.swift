import SwiftUI
import AVFoundation
import AppKit

struct StudioPopover: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: StudioEngine
    let openSettings: () -> Void
    let openOnboarding: () -> Void
    let openStreamingSetup: () -> Void
    let quit: () -> Void
    var availableHeight: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                PermissionSetupPrompt(missing: model.missingCapturePermissions,
                                      disabled: model.busy || engine.isRunning, action: openOnboarding)
                HStack(spacing: 12) {
                    AudioLevelMeter(title: "Mic", level: engine.microphoneLevel)
                    AudioLevelMeter(title: "System", level: engine.systemLevel)
                    AudioLevelMeter(title: "Mix", level: engine.outputLevel)
                }
                if let error = engine.meterPreviewError {
                    Text(error).font(.caption2).foregroundStyle(.orange)
                }
                StudioVideoPreview(model: model, engine: engine)
            }.padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sceneSection
                    cameraSection
                    Divider()
                    mixerSection
                    if let message = model.message ?? engine.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }.padding(20)
            }.frame(maxHeight: .infinity).disabled(model.busy)
            Divider()
            outputSection.padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            HStack {
                Button(action: openSettings) { Label("Settings", systemImage: "slider.horizontal.3") }
                Spacer()
                Text("1080p · 30 fps · Hardware H.264").font(.system(size: 10)).foregroundStyle(.secondary)
                Button(action: quit) { Image(systemName: "power") }.help("Quit StreamApp")
            }.buttonStyle(.borderless).padding(.horizontal, 20).padding(.vertical, 12)
        }.frame(width: 420, height: availableHeight)
    }


    private var sceneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("SCENES", detail: "Switch live")
            HStack(spacing: 10) {
                ForEach(SceneLayout.allCases) { scene in
                    Button { model.configuration.layout = scene } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            SceneDiagram(configuration: model.configuration, layout: scene).aspectRatio(16/9, contentMode: .fit)
                            HStack {
                                Text(scene.title).font(.system(size: 12, weight: .semibold))
                                Spacer(minLength: 1)
                                if model.configuration.layout == scene { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                            }
                        }.padding(8).background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
                    }.buttonStyle(.plain).accessibilityLabel("Select \(scene.title)")
                }
            }
            HStack {
                Toggle("Render chat", isOn: $model.configuration.chatEnabled)
                Spacer()
                DockFitControl(model: model, fit: model.dockFit, compact: true)
            }.toggleStyle(.switch).controlSize(.small)
            HStack {
                Button("Annotate desktop  ⌃⌥⌘D") { model.toggleAnnotations?() }
                    .disabled(model.configuration.layout != .desktopChat || model.configuration.windowID != nil)
                Spacer()
                Button("Clear", systemImage: "eraser") { model.clearAnnotations?() }
                    .help("Clear annotations").accessibilityLabel("Clear annotations")
            }
        }
    }


    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $model.configuration.cameraEnabled) {
                Label("Webcam", systemImage: model.configuration.cameraEnabled ? "video.fill" : "video.slash")
            }.toggleStyle(.switch).controlSize(.small)
                .disabled(!model.demo && !model.cameraAuthorized)
            if model.configuration.cameraEnabled && model.configuration.layout == .desktopChat {
                Picker("Position", selection: $model.configuration.cameraCorner) {
                    ForEach(CameraCorner.allCases) { Text($0.title).tag($0) }
                }.controlSize(.small)
                HStack {
                    Text("Normal size").font(.caption)
                    Slider(value: $model.configuration.cameraSize, in: 0.12...0.4)
                        .accessibilityLabel("Normal webcam size")
                    Text(model.configuration.cameraSize.formatted(.percent.precision(.fractionLength(0)))).font(.caption).monospacedDigit()
                    Button(model.configuration.cameraPunchIn ? "Punch out" : "Punch in") {
                        model.toggleCameraPunchIn()
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.canPunchInCamera)
                    .help("Webcam punch-in (⌃⌥⌘V)")
                    .accessibilityLabel(model.configuration.cameraPunchIn ? "Punch out webcam" : "Punch in webcam")
                    .accessibilityHint("Keyboard shortcut Control-Option-Command-V")
                }
                HStack {
                    Text("Punched-in size").font(.caption)
                    Slider(value: $model.configuration.cameraPunchInSize, in: 0.4...0.9)
                        .accessibilityLabel("Punched-in webcam size")
                    Text(model.configuration.cameraPunchInSize.formatted(.percent.precision(.fractionLength(0)))).font(.caption).monospacedDigit()
                }
            }
        }
    }

    private var mixerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AudioChannelView(title: "Microphone", symbol: "mic.fill", enabled: $model.configuration.microphoneEnabled,
                             gain: $model.configuration.microphoneGain, muted: $model.configuration.microphoneMuted,
                             canEnable: model.demo || model.microphoneAuthorized)
            AudioChannelView(title: "System audio", symbol: "speaker.wave.2.fill", enabled: $model.configuration.systemAudioEnabled,
                             gain: $model.configuration.systemAudioGain, muted: $model.configuration.systemAudioMuted,
                             canEnable: model.demo || model.screenAuthorized,
                             openSettings: {
                                 model.settingsTab = .audio
                                 openSettings()
                             })
            Toggle("Microphone compression", isOn: $model.configuration.microphoneCompressionEnabled)
                .toggleStyle(.switch).controlSize(.small)
            Text(String(format: "Gentle 3:1 · −18 dBFS · %.1f dB reduction", engine.gainReduction))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var outputSection: some View {
        VStack(spacing: 10) {
            if engine.isRunning {
                Label(engine.outputHealth, systemImage: "waveform.path.ecg")
                    .font(.caption2).textSelection(.enabled)
            }
            if !engine.isRunning && !model.rehearsalActive {
                Picker("Session mode", selection: Binding(
                    get: { model.configuration.outputMode },
                    set: { mode in
                        model.configuration.outputMode = mode
                        model.message = nil
                        if mode != .record && !model.validateStreamSetup() { openStreamingSetup() }
                    }
                )) {
                    ForEach(OutputMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().disabled(model.busy)
            }
            if model.rehearsalActive {
                Text("Local rehearsal").font(.caption).foregroundStyle(.secondary)
            } else if model.configuration.streamingEnabled && model.configuration.twitchTestMode {
                Text("Twitch bandwidth test · Not live").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                if engine.isRunning { model.stop() }
                else if model.configuration.streamingEnabled && !model.validateStreamSetup() { openStreamingSetup() }
                else { model.start() }
            } label: {
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    Image(systemName: engine.isRunning ? "stop.fill" : "play.fill")
                    Text(model.busy ? "Please wait…" : (engine.isRunning ? "Stop" : "Start"))
                        .fontWeight(.semibold)
                }.frame(maxWidth: .infinity).padding(.vertical, 5)
            }.buttonStyle(.borderedProminent).tint(engine.isRunning ? .red : .accentColor).disabled(model.busy)
        }
    }
    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack { Text(title).font(.system(size: 10, weight: .semibold)).tracking(1); Spacer(); Text(detail).font(.system(size: 10)) }.foregroundStyle(.secondary)
    }
}

private struct PermissionSetupPrompt: View {
    let missing: [String]
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Button(action: action) {
                    Label("Finish permissions setup…", systemImage: "checklist")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.borderedProminent).disabled(disabled)
                Text("Missing: " + missing.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
                if disabled {
                    Text("Stop the session to finish setup.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct AudioLevelMeter: View {
    let title: String
    let level: Float
    private var decibels: Double { level > 0 ? 20 * log10(Double(level)) : -.infinity }
    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(level > 0.000_001 ? String(format: "%.1f dBFS", decibels) : "−∞ dBFS").monospacedDigit()
            }.font(.caption2).foregroundStyle(.secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(decibels > -1 ? Color.red : decibels > -12 ? .yellow : .green)
                        .frame(width: geometry.size.width * CGFloat(min(1, max(0, (decibels + 60) / 60))))
                }
            }.frame(height: 5)
            HStack { Text("−60"); Spacer(); Text("−30"); Spacer(); Text("0") }
                .font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title) peak \(level > 0.000_001 ? String(format: "%.1f", decibels) : "minus infinity") dBFS")
    }
}

struct AudioChannelView: View {
    let title: String
    let symbol: String
    @Binding var enabled: Bool
    @Binding var gain: Double
    @Binding var muted: Bool
    let canEnable: Bool
    var openSettings: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Toggle(isOn: $enabled) { Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium)) }
                    .toggleStyle(.switch).controlSize(.mini).disabled(!canEnable)
                if let openSettings {
                    Button(action: openSettings) { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless)
                        .help("Audio settings")
                        .accessibilityLabel("Audio settings")
                }
                Spacer()
                Button { muted.toggle() } label: { Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2") }
                    .buttonStyle(.borderless).foregroundStyle(muted ? Color.red : .secondary)
                    .accessibilityLabel("\(muted ? "Unmute" : "Mute") \(title)").disabled(!enabled)
            }
            HStack(spacing: 8) {
                Slider(value: $gain, in: 0...2).disabled(!enabled).accessibilityLabel("\(title) gain")
                Text(gain == 0 ? "−∞ dB" : String(format: "%+.0f dB", 20 * log10(gain)))
                    .font(.system(size: 10, design: .monospaced)).frame(width: 45, alignment: .trailing)
            }
        }
    }
}

struct SceneDiagram: View {
    let configuration: StudioConfiguration
    let layout: SceneLayout
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let sceneConfiguration: StudioConfiguration = {
                var scene = configuration
                scene.layout = layout
                return scene
            }()
            let chat = sceneConfiguration.chatEnabled ? width * sceneConfiguration.chatWidth / 1920 : 0
            let stageWidth = width - chat
            let stageX = sceneConfiguration.chatOnLeft ? chat : 0
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.85))
                if layout == .justChatting {
                    panel("person.fill", color: .indigo).frame(width: width, height: height)
                    if !sceneConfiguration.cameraEnabled { Text("CAMERA OFF").font(.system(size: 8, weight: .bold)).foregroundStyle(.white).frame(width: width, height: height) }
                    if sceneConfiguration.chatEnabled {
                        VStack(spacing: 4) {
                            ForEach(0..<6) { row in Capsule().fill(Color.white.opacity(row.isMultiple(of: 2) ? 0.8 : 0.4)).frame(height: 2) }
                        }.padding(5).frame(width: chat, height: height - 10)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .offset(x: width - chat - 5, y: 5)
                    }
                } else {
                    panel("display", color: .blue).frame(width: stageWidth, height: height).offset(x: stageX)
                    if sceneConfiguration.chatEnabled {
                        VStack(spacing: 4) {
                            ForEach(0..<6) { row in Capsule().fill(Color.white.opacity(row.isMultiple(of: 2) ? 0.45 : 0.2)).frame(height: 2) }
                        }.padding(5).frame(width: chat, height: height).background(Color.teal.opacity(0.65)).offset(x: sceneConfiguration.chatOnLeft ? 0 : stageWidth)
                    }
                    if sceneConfiguration.cameraEnabled {
                        let cameraWidth = stageWidth * CGFloat(sceneConfiguration.effectiveCameraSize)
                        let left = sceneConfiguration.cameraCorner == .bottomLeft || sceneConfiguration.cameraCorner == .topLeft
                        let top = sceneConfiguration.cameraCorner == .topLeft || sceneConfiguration.cameraCorner == .topRight
                        panel("person.fill", color: .indigo).frame(width: cameraWidth, height: cameraWidth * 9 / 16)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.8), lineWidth: 1))
                            .offset(x: stageX + (left ? 5 : stageWidth - cameraWidth - 5), y: top ? 5 : height - cameraWidth * 9 / 16 - 5)
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
    private func panel(_ icon: String, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.55)).overlay(Image(systemName: icon).font(.system(size: 20)).foregroundStyle(.white.opacity(0.8)))
    }
}

struct StudioVideoPreview: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: StudioEngine
    var body: some View {
        VStack(spacing: 8) {
            Picker("Preview", selection: Binding<PreviewFrames.Mode?>(
                get: { engine.videoPreviewMode },
                set: { mode in Task { await engine.setVideoPreviewMode(mode) } }
            )) {
                Text("Off").tag(Optional<PreviewFrames.Mode>.none)
                Text("Layout").tag(Optional(PreviewFrames.Mode.program))
                Text("Webcam").tag(Optional(PreviewFrames.Mode.camera))
            }.pickerStyle(.segmented).labelsHidden().disabled(model.busy)
            if let mode = engine.videoPreviewMode {
                GPUPreview(frames: engine.previewFrames, mode: mode)
                    .aspectRatio(16/9, contentMode: .fit)
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(mode == .program ? "Live layout preview" : "Live webcam preview")
            }
            if let error = engine.videoPreviewError {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
            if model.demo {
                Text("Demo · sample video and audio").font(.caption2).foregroundStyle(.secondary)
            }
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
            HStack {
                Text("Your studio").font(.headline)
                Spacer()
                if model.missingCapturePermissions.isEmpty {
                    Button("Setup & Twitch…", action: openOnboarding).disabled(engine.isRunning || model.busy)
                }
            }
            PermissionSetupPrompt(missing: model.missingCapturePermissions,
                                  disabled: model.busy || engine.isRunning, action: openOnboarding)
            TabView(selection: $model.settingsTab) {
                sourcesTab.tabItem { Label("Sources", systemImage: "display") }.tag(StudioModel.SettingsTab.sources)
                audioTab.tabItem { Label("Audio", systemImage: "waveform") }.tag(StudioModel.SettingsTab.audio)
                layoutTab.tabItem { Label("Layout", systemImage: "rectangle.3.group") }.tag(StudioModel.SettingsTab.layout)
                TeleprompterControls(model: model)
                    .tabItem { Label("Prompter", systemImage: "text.bubble") }.tag(StudioModel.SettingsTab.teleprompter)
                drawingTab.tabItem { Label("Drawing", systemImage: "pencil.tip") }.tag(StudioModel.SettingsTab.drawing)
                outputTab.tabItem { Label("Outputs", systemImage: "antenna.radiowaves.left.and.right") }.tag(StudioModel.SettingsTab.outputs)
            }
            Button("Restore All Defaults…", role: .destructive) { confirmRestoreAll = true }
                .disabled(model.busy || engine.isRunning)
                .help("Restore StreamApp preferences and Dock fit settings. Recordings, credentials, and permissions are kept.")
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.padding(16).frame(width: 610, height: 620).disabled(model.busy)
        .alert("Restore all defaults?", isPresented: $confirmRestoreAll) {
            Button("Restore Defaults", role: .destructive) {
                Task { await model.restoreAllDefaults() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This resets StreamApp preferences and Dock fit settings. Recordings, saved credentials, onboarding, and macOS permissions are not deleted.")
        }
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
    private var sourcesTab: some View {
        Form {
            Section("Display or window") {
                HStack {
                    Picker("Capture", selection: sourceSelection) {
                        Text("Choose a source").tag("")
                        ForEach(model.sources, id: \.stableID) { Text($0.name).tag($0.stableID) }
                    }.disabled(engine.isRunning || model.busy)
                    resetButton("Capture source", enabled: model.configuration.displayID != StudioConfiguration().displayID || model.configuration.windowID != StudioConfiguration().windowID) {
                        model.configuration.displayID = StudioConfiguration().displayID
                        model.configuration.windowID = StudioConfiguration().windowID
                    }
                }.disabled(engine.isRunning || model.busy)
                HStack {
                    Button("Refresh Sources") { model.refreshSources() }.disabled(engine.isRunning)
                    Spacer()
                }
            }
            Section("StreamApp windows") {
                HStack {
                    Toggle("Show StreamApp windows", isOn: $model.configuration.showStreamAppWindows).toggleStyle(.switch)
                    resetButton("Show StreamApp windows", enabled: model.configuration.showStreamAppWindows != StudioConfiguration().showStreamAppWindows) { model.configuration.showStreamAppWindows = StudioConfiguration().showStreamAppWindows }
                }
                Text("Teleprompter visibility is controlled separately in Prompter settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy || model.configuration.windowID != nil)
            Section("Exclude from display capture") {
                Text("Refresh after reopening excluded apps. Window rules last until StreamApp quits. This is not a system-wide privacy boundary.")
                Button("Refresh apps and windows") { model.refreshSources() }
                    .disabled(model.busy)
                ForEach(engine.captureApplications) { app in
                    HStack {
                        Toggle(app.name, isOn: Binding(get: { model.configuration.excludedApplicationIDs.contains(app.id) }, set: { excluded in
                            if excluded { model.configuration.excludedApplicationIDs.append(app.id) } else { model.configuration.excludedApplicationIDs.removeAll { $0 == app.id } }
                        }))
                        resetButton("\(app.name) exclusion", enabled: model.configuration.excludedApplicationIDs.contains(app.id)) {
                            model.configuration.excludedApplicationIDs.removeAll { $0 == app.id }
                        }
                    }
                }
                ForEach(model.configuration.excludedApplicationIDs.filter { id in !engine.captureApplications.contains { $0.id == id } }, id: \.self) { id in
                    Button("Remove unavailable app rule: \(id)") { model.configuration.excludedApplicationIDs.removeAll { $0 == id } }
                }
                ClickableDisclosure("Individual windows") {
                    ForEach(model.sources.filter { $0.kind == .window }, id: \.stableID) { source in
                        HStack {
                            Toggle(source.name, isOn: Binding(get: { model.configuration.excludedWindowIDs.contains(source.id) }, set: { excluded in
                                if excluded { model.configuration.excludedWindowIDs.append(source.id) } else { model.configuration.excludedWindowIDs.removeAll { $0 == source.id } }
                            }))
                            resetButton("\(source.name) exclusion", enabled: model.configuration.excludedWindowIDs.contains(source.id)) {
                                model.configuration.excludedWindowIDs.removeAll { $0 == source.id }
                            }
                        }
                    }
                }
            }.disabled(engine.isRunning || model.configuration.windowID != nil)
            Section("Camera") {
                HStack {
                    Picker("Camera", selection: $model.configuration.cameraID) {
                        Text("Default camera").tag("")
                        ForEach(model.cameras) { Text($0.name).tag($0.id) }
                    }
                    resetButton("Camera", enabled: model.configuration.cameraID != StudioConfiguration().cameraID) { model.configuration.cameraID = StudioConfiguration().cameraID }
                }
                HStack {
                    Toggle("Mirror webcam", isOn: $model.configuration.mirrorCamera)
                    resetButton("Mirror webcam", enabled: model.configuration.mirrorCamera != StudioConfiguration().mirrorCamera) { model.configuration.mirrorCamera = StudioConfiguration().mirrorCamera }
                }
            }.disabled(engine.isRunning || model.busy)
            Section("Chat") {
                setting("Render chat", \.chatEnabled) {
                    Toggle("Render chat", isOn: $model.configuration.chatEnabled)
                }
                TwitchConnectionView(session: model.twitch, locked: model.demo || engine.isRunning || model.busy)
                TwitchChatSettings(model: model, engine: engine)
            }
        }.formStyle(.grouped)
    }
    private var audioTab: some View {
        Form {
            Section("Music / app audio") {
                setting("Capture app audio", \.systemAudioEnabled) {
                    Toggle("Capture app audio", isOn: $model.configuration.systemAudioEnabled)
                }
                HStack(alignment: .top) {
                    SystemAudioSourcePicker(model: model, engine: engine)
                    resetButton("Audio source", enabled: model.configuration.systemAudioApplicationID != defaults.systemAudioApplicationID) {
                        model.configuration.systemAudioApplicationID = defaults.systemAudioApplicationID
                    }
                }
            }.disabled(engine.isRunning)
            Section("Voice") {
                setting("Enable microphone", \.microphoneEnabled) {
                    Toggle("Enable microphone", isOn: $model.configuration.microphoneEnabled)
                }
                setting("Microphone", \.microphoneID) {
                    Picker("Microphone", selection: $model.configuration.microphoneID) {
                        Text("Default microphone at capture start").tag("")
                        ForEach(model.microphones) { Text($0.name).tag($0.id) }
                        if !model.configuration.microphoneID.isEmpty,
                           !model.microphones.contains(where: { $0.id == model.configuration.microphoneID }) {
                            Text("Unavailable: \(model.configuration.microphoneID)").tag(model.configuration.microphoneID)
                        }
                    }
                }
                Text("With AirPods, select the Mac or a USB mic explicitly. Mute only silences the mix: Disable microphone releases the device. An enabled mic is opened for the visible menu's level check, too.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(engine.isRunning)
            Section("Ableton checklist") {
                Text("AirPods: use as output only. Bluetooth adds monitoring latency; use wired headphones for playing or recording live instruments. Another app opening the AirPods mic can change playback quality.")
                Text("Speakers: disable the microphone for clean music. With voice enabled, speakers can bleed into the mic and create delayed doubling. StreamApp does not monitor audio to speakers or cancel acoustic echo.")
                Text("Monitor directly in Ableton, not through the stream. Do not capture the same mic both through Ableton and StreamApp. Keep music in stereo, leave headroom, and test a recording before going live.")
                Text("For musical input, set Ableton's macOS Mic Mode to Standard; Voice Isolation can remove instruments. Begin around 128–256 samples and raise Ableton's buffer if the real set crackles under capture load.")
                Text("Output is 48 kHz stereo with peak protection, not LUFS normalization. Choose Ableton's intended main stereo output. Cue / headphone buses, plug-in helper processes and interface loopback need a private recording check.")
                Text("Stop before changing devices, sample rates, or virtual routing. Check meters and replay the saved file after reconnecting. Visual exclusions do not exclude audio in All other apps mode.")
            }.font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
    private var layoutTab: some View {
        VStack(spacing: 0) {
            StudioVideoPreview(model: model, engine: engine).padding(12)
            Form {
                Section("Desktop canvas") {
                    DockFitControl(model: model, fit: model.dockFit)
                    setting("Include menu bar", \.includeMenuBar) {
                        Toggle("Include menu bar", isOn: $model.configuration.includeMenuBar)
                    }.disabled(model.configuration.windowID != nil)
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
                            Text("Blur")
                            Slider(value: $model.configuration.backgroundBlurRadius, in: 0...80)
                            Text("\(Int(model.configuration.backgroundBlurRadius))").monospacedDigit()
                        }
                    }
                }
                Section("Program layout") {
                    setting("Scene", \.layout) {
                        Picker("Scene", selection: $model.configuration.layout) { ForEach(SceneLayout.allCases) { Text($0.title).tag($0) } }
                    }
                    setting("Render chat", \.chatEnabled) {
                        Toggle("Render chat", isOn: $model.configuration.chatEnabled)
                    }
                    setting("Desktop chat on left", \.chatOnLeft) {
                        Toggle("Desktop chat on left", isOn: $model.configuration.chatOnLeft)
                    }
                    setting("Chat width", \.chatWidth) {
                        Text("Chat width"); Slider(value: $model.configuration.chatWidth, in: 288...576, step: 32)
                        Text("\(Int(model.configuration.chatWidth)) px").monospacedDigit()
                    }
                    setting("Webcam corner", \.cameraCorner) {
                        Picker("Webcam corner", selection: $model.configuration.cameraCorner) { ForEach(CameraCorner.allCases) { Text($0.title).tag($0) } }
                    }
                    setting("Webcam size", \.cameraSize) {
                        Text("Webcam size")
                        Slider(value: $model.configuration.cameraSize, in: 0.12...0.4)
                            .accessibilityLabel("Normal webcam size")
                        Text(model.configuration.cameraSize.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                        Button(model.configuration.cameraPunchIn ? "Punch out" : "Punch in") {
                            model.toggleCameraPunchIn()
                        }
                        .buttonStyle(.borderless)
                        .disabled(!model.canPunchInCamera)
                        .help("Webcam punch-in (⌃⌥⌘V)")
                        .accessibilityLabel(model.configuration.cameraPunchIn ? "Punch out webcam" : "Punch in webcam")
                        .accessibilityHint("Keyboard shortcut Control-Option-Command-V")
                    }
                    setting("Punched-in size", \.cameraPunchInSize) {
                        Text("Punched-in size")
                        Slider(value: $model.configuration.cameraPunchInSize, in: 0.4...0.9)
                            .accessibilityLabel("Punched-in webcam size")
                        Text(model.configuration.cameraPunchInSize.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
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
    private var drawingTab: some View {
        AnnotationSettingsView(settings: model.annotationSettings)
    }
    private var outputTab: some View {
        Form {
            Section("Session mode") {
                HStack {
                    Picker("When you start", selection: $model.configuration.outputMode) { ForEach(OutputMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    resetButton("Session mode", enabled: model.configuration.outputMode != StudioConfiguration().outputMode) { model.configuration.outputMode = StudioConfiguration().outputMode }
                }
                Text(model.configuration.outputSummary).font(.caption).foregroundStyle(.secondary)
                Text("Choose Record for a local file even with streaming configured. Both streams and saves a local copy.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Recording") {
                setting("Recording folder", \.recordingDirectory) {
                    Text(model.configuration.recordingDirectory).lineLimit(2).font(.caption)
                    Spacer()
                    Button("Choose…") { model.chooseRecordingFolder() }
                }
                Text("Matroska · H.264 6 Mb/s · AAC 160 kb/s. Unique filenames; existing recordings are never overwritten.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Streaming") {
                Picker("Service", selection: $model.configuration.streamService) {
                    ForEach(StreamService.allCases) { Text($0.title).tag($0) }
                }
                if model.configuration.streamService == .twitch {
                    TwitchConnectionView(session: model.twitch, locked: model.demo || engine.isRunning || model.busy)
                    Text("Broadcasts to the connected account. StreamApp retrieves its stream key when you start; the chat channel is independent.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    setting("Server URL", \.streamURL) {
                        TextField("Server URL (without stream key)", text: $model.configuration.streamURL).textFieldStyle(.roundedBorder)
                    }
                    SecureField("Stream key", text: $model.streamKey).textFieldStyle(.roundedBorder)
                    HStack { Button("Save Key in Keychain") { model.saveKey() }.disabled(model.streamKey.isEmpty || model.demo); if model.keySaved { Text("Saved").font(.caption).foregroundStyle(.secondary) } }
                }
                setting("Twitch test stream", \.twitchTestMode) {
                    Toggle("Twitch test stream", isOn: $model.configuration.twitchTestMode)
                }
                if model.configuration.twitchTestMode {
                    Text("Test your connection without going live. Use a Twitch server.").font(.caption).foregroundStyle(.secondary)
                    Link("View test results in Twitch Inspector", destination: URL(string: "https://inspector.twitch.tv")!)
                }
                Text("Saved streaming details stay available in every mode. Record never uses the server or stream key. Streaming and bandwidth tests always ask for confirmation.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Output and device settings lock during a session. Scenes, camera enable, gains and mutes remain live. Stop waits for the recording to finalize.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).disabled(engine.isRunning || model.busy)
    }
}

struct SystemAudioSourcePicker: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: StudioEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Audio from", selection: $model.configuration.systemAudioApplicationID) {
                Text("All other apps — includes alerts").tag("")
                ForEach(engine.captureApplications) { Text($0.name).tag($0.id) }
                if !model.configuration.systemAudioApplicationID.isEmpty,
                   !engine.captureApplications.contains(where: { $0.id == model.configuration.systemAudioApplicationID }) {
                    Text("Unavailable: \(model.configuration.systemAudioApplicationID)").tag(model.configuration.systemAudioApplicationID)
                }
            }
            Button("Refresh Apps & Devices") { model.refreshSources() }
            Text("For music, open Ableton, refresh, and select it here to exclude other apps and alerts. Audio follows this choice across scenes. If the selected app closes, capture stops rather than switching to all apps.")
                .font(.caption).foregroundStyle(.secondary)
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
    @State private var learnMessage = "Move the pen over this app and press the desired button."
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
            Section("Stroke style") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("Smoothing"); Spacer(); Text(smoothingLabel).foregroundStyle(.secondary); resetButton("Smoothing", enabled: settings.smoothing != AnnotationSettings.defaultSmoothing) { settings.smoothing = AnnotationSettings.defaultSmoothing } }
                    HStack(spacing: 8) {
                        Text("Off").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $settings.smoothing, in: 0...1).labelsHidden().accessibilityLabel("Smoothing")
                        Text("Strong").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack { Text("Width"); Slider(value: $settings.strokeWidth, in: 1...24, step: 1).accessibilityLabel("Stroke width"); Text("\(settings.strokeWidth, specifier: "%.0f") pt").monospacedDigit(); resetButton("Stroke width", enabled: settings.strokeWidth != AnnotationSettings.defaultStrokeWidth) { settings.strokeWidth = AnnotationSettings.defaultStrokeWidth } }
                HStack { ColorPicker("Stroke", selection: strokeColorBinding, supportsOpacity: false); resetButton("Stroke", enabled: settings.strokeColor != AnnotationSettings.defaultStrokeColor) { settings.strokeColor = AnnotationSettings.defaultStrokeColor } }
                HStack { ColorPicker("Highlighter", selection: highlighterColorBinding, supportsOpacity: false); resetButton("Highlighter", enabled: settings.highlighterColor != AnnotationSettings.defaultHighlighterColor) { settings.highlighterColor = AnnotationSettings.defaultHighlighterColor } }
                HStack {
                    ColorPicker("Fill", selection: fillColorBinding, supportsOpacity: true)
                    Button("No fill") { settings.fillColor = settings.fillColor.withAlphaComponent(0) }.disabled(settings.fillColor.alphaComponent == 0)
                    resetButton("Fill", enabled: settings.fillColor != AnnotationSettings.defaultFillColor) { settings.fillColor = AnnotationSettings.defaultFillColor }
                }
            }
            Section("Shapes") {
                HStack { Toggle("Hold to straighten", isOn: $settings.holdToStraighten); resetButton("Hold to straighten", enabled: settings.holdToStraighten != AnnotationSettings.defaultHoldToStraighten) { settings.holdToStraighten = AnnotationSettings.defaultHoldToStraighten } }
            }
            Section("Eraser") {
                HStack {
                    Picker("Erase", selection: $settings.eraseMode) {
                        ForEach(AnnotationEraseMode.allCases) { Text($0.title).tag($0) }
                    }
                    resetButton("Eraser", enabled: settings.eraseMode != AnnotationSettings.defaultEraseMode) {
                        settings.eraseMode = AnnotationSettings.defaultEraseMode
                    }
                }
                Text("Object removes a whole stroke. Partial rubs out only what you touch.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Pen buttons") {
                Text("Mappings use the standard event button number, not a physical pen position. If a driver suppresses a button, configure it to emit a click in Tablet Companion or the tablet driver first.").font(.caption).foregroundStyle(.secondary)
                Text("Tool picker: tap for Pen/Erase; hold, hover, and release to choose. Colors at the top opens a palette for Stroke, Highlighter, or Fill.").font(.caption).foregroundStyle(.secondary)
                ForEach(mappedButtons, id: \.self) { button in
                    HStack {
                        Text(buttonLabel(button))
                        Picker("", selection: actionBinding(for: button)) { ForEach(AnnotationPenAction.allCases) { Text($0.title).tag($0) } }.labelsHidden()
                        Button("Learn") { beginLearning(settings.penAction(for: button)) }.disabled(settings.penAction(for: button) == .none)
                        resetButton("Reset \(buttonLabel(button))", enabled: settings.penAction(for: button) != .none) { settings.setPenAction(.none, for: button) }
                    }
                }
                ForEach(AnnotationPenAction.allCases.filter { $0 != .none }) { action in
                    Button("Learn \(action.title) button") { beginLearning(action) }
                }
                Button("Reset pen buttons") { settings.restorePenDefaults() }
            }
        }.formStyle(.grouped)
        .sheet(isPresented: $learning, onDismiss: endLearning) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Learn pen button").font(.headline)
                Text(learnMessage)
                Text("Escape cancels. Primary/nib and unsupported button numbers are ignored.").font(.caption).foregroundStyle(.secondary)
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
