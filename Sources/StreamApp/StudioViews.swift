import SwiftUI
import AVFoundation

struct StudioPopover: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: StudioEngine
    let openSettings: () -> Void
    let quit: () -> Void
    var availableHeight: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    AudioLevelMeter(title: "Mic", level: engine.microphoneLevel)
                    AudioLevelMeter(title: "System", level: engine.systemLevel)
                    AudioLevelMeter(title: "Mix", level: engine.outputLevel)
                }
                if let error = engine.meterPreviewError {
                    Text(error).font(.caption2).foregroundStyle(.orange)
                }
                previewSection
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

    private var previewSection: some View {
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

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $model.configuration.cameraEnabled) {
                Label("Webcam", systemImage: model.configuration.cameraEnabled ? "video.fill" : "video.slash")
            }.toggleStyle(.switch).controlSize(.small)
                .disabled(!model.demo && !model.cameraAuthorized)
            if !model.cameraAuthorized && !model.demo {
                Button("Grant Camera Access…") { model.requestPermission(.video) }.font(.caption)
            }
            if model.configuration.cameraEnabled && model.configuration.layout == .desktopChat {
                Picker("Position", selection: $model.configuration.cameraCorner) {
                    ForEach(CameraCorner.allCases) { Text($0.title).tag($0) }
                }.controlSize(.small)
                HStack { Text("Size").font(.caption); Slider(value: $model.configuration.cameraSize, in: 0.12...0.4) }
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
                             canEnable: model.demo || model.screenAuthorized)
            Toggle("Microphone compression", isOn: $model.configuration.microphoneCompressionEnabled)
                .toggleStyle(.switch).controlSize(.small)
            Text(String(format: "Gentle 3:1 · −18 dBFS · %.1f dB reduction", engine.gainReduction))
                .font(.caption2).foregroundStyle(.secondary)
            if !model.microphoneAuthorized && !model.demo {
                Button("Grant Microphone Access…") { model.requestPermission(.audio) }.font(.caption)
            }
        }
    }

    private var outputSection: some View {
        VStack(spacing: 10) {
            if engine.isRunning {
                Label(engine.outputHealth, systemImage: "waveform.path.ecg")
                    .font(.caption2).textSelection(.enabled)
            }
            HStack {
                Label(model.configuration.recordingEnabled || model.rehearsalActive ? "Record" : "No recording", systemImage: "record.circle")
                Spacer()
                Label(model.configuration.streamingEnabled && !model.rehearsalActive ? (model.configuration.twitchTestMode ? "Twitch test" : "Stream") : "Local only", systemImage: "antenna.radiowaves.left.and.right")
            }.font(.caption).foregroundStyle(.secondary)
            Button { engine.isRunning ? model.stop() : model.start() } label: {
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    Image(systemName: engine.isRunning ? "stop.fill" : "play.fill")
                    Text(model.busy ? "Please wait…" : (engine.isRunning ? "Stop Session" : (model.configuration.streamingEnabled ? (model.configuration.twitchTestMode ? "Start Test Stream…" : "Start Broadcast…") : "Start Recording")))
                        .fontWeight(.semibold)
                }.frame(maxWidth: .infinity).padding(.vertical, 5)
            }.buttonStyle(.borderedProminent).tint(engine.isRunning ? .red : .accentColor).disabled(model.busy)
        }
    }
    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack { Text(title).font(.system(size: 10, weight: .semibold)).tracking(1); Spacer(); Text(detail).font(.system(size: 10)) }.foregroundStyle(.secondary)
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
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Toggle(isOn: $enabled) { Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium)) }
                    .toggleStyle(.switch).controlSize(.mini).disabled(!canEnable)
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
            let chat = configuration.chatEnabled ? width * configuration.chatWidth / 1920 : 0
            let stageWidth = width - chat
            let stageX = configuration.chatOnLeft ? chat : 0
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.85))
                if layout == .justChatting {
                    panel("person.fill", color: .indigo).frame(width: width, height: height)
                    if !configuration.cameraEnabled { Text("CAMERA OFF").font(.system(size: 8, weight: .bold)).foregroundStyle(.white).frame(width: width, height: height) }
                    if configuration.chatEnabled {
                    VStack(spacing: 4) {
                        ForEach(0..<6) { row in Capsule().fill(Color.white.opacity(row.isMultiple(of: 2) ? 0.8 : 0.4)).frame(height: 2) }
                    }.padding(5).frame(width: chat, height: height - 10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .offset(x: width - chat - 5, y: 5)
                    }
                } else {
                    panel("display", color: .blue).frame(width: stageWidth, height: height).offset(x: stageX)
                    if configuration.chatEnabled {
                    VStack(spacing: 4) {
                        ForEach(0..<6) { row in Capsule().fill(Color.white.opacity(row.isMultiple(of: 2) ? 0.45 : 0.2)).frame(height: 2) }
                    }.padding(5).frame(width: chat, height: height).background(Color.teal.opacity(0.65)).offset(x: configuration.chatOnLeft ? 0 : stageWidth)
                    }
                    if configuration.cameraEnabled {
                        let cameraWidth = stageWidth * configuration.cameraSize
                        let left = configuration.cameraCorner == .bottomLeft || configuration.cameraCorner == .topLeft
                        let top = configuration.cameraCorner == .topLeft || configuration.cameraCorner == .topRight
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

struct StudioSettings: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: StudioEngine
    let openOnboarding: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Your studio").font(.headline)
                Spacer()
                Button("Setup & Twitch…", action: openOnboarding).disabled(engine.isRunning || model.busy)
            }
            TabView {
                sourcesTab.tabItem { Label("Sources", systemImage: "display") }
                layoutTab.tabItem { Label("Layout", systemImage: "rectangle.3.group") }
                outputTab.tabItem { Label("Outputs", systemImage: "antenna.radiowaves.left.and.right") }
            }
        }.padding(16).frame(width: 610, height: 580).disabled(model.busy)
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
                Picker("Capture", selection: sourceSelection) {
                    Text("Choose a source").tag("")
                    ForEach(model.sources, id: \.stableID) { Text($0.name).tag($0.stableID) }
                }.disabled(engine.isRunning || model.busy)
                HStack {
                    Button("Refresh Sources") { model.refreshSources() }.disabled(engine.isRunning)
                    if !model.screenAuthorized { Button("Grant Screen Recording Access…") { model.requestScreenPermission() } }
                }
                Text("The menu preview uses your selected source. Recording starts only when you press Start.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Exclude from display capture") {
                Text("StreamApp controls are excluded; annotation ink is included. Refresh after reopening excluded apps. Window rules last until StreamApp quits. This is not a system-wide privacy boundary.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(engine.captureApplications) { app in
                    Toggle(app.name, isOn: Binding(get: { model.configuration.excludedApplicationIDs.contains(app.id) }, set: { excluded in
                        if excluded { model.configuration.excludedApplicationIDs.append(app.id) }
                        else { model.configuration.excludedApplicationIDs.removeAll { $0 == app.id } }
                    }))
                }
                ForEach(model.configuration.excludedApplicationIDs.filter { id in !engine.captureApplications.contains { $0.id == id } }, id: \.self) { id in
                    Button("Remove unavailable app rule: \(id)") { model.configuration.excludedApplicationIDs.removeAll { $0 == id } }
                }
                DisclosureGroup("Individual windows") {
                    ForEach(model.sources.filter { $0.kind == .window }, id: \.stableID) { source in
                        Toggle(source.name, isOn: Binding(get: { model.configuration.excludedWindowIDs.contains(source.id) }, set: { excluded in
                            if excluded { model.configuration.excludedWindowIDs.append(source.id) }
                            else { model.configuration.excludedWindowIDs.removeAll { $0 == source.id } }
                        }))
                    }
                }
            }.disabled(engine.isRunning || model.configuration.windowID != nil)
            Section("Camera & microphone") {
                Picker("Camera", selection: $model.configuration.cameraID) {
                    Text("Default camera").tag("")
                    ForEach(model.cameras) { Text($0.name).tag($0.id) }
                }
                Picker("Microphone", selection: $model.configuration.microphoneID) {
                    Text("Default microphone").tag("")
                    ForEach(model.microphones) { Text($0.name).tag($0.id) }
                }
                Toggle("Mirror webcam", isOn: $model.configuration.mirrorCamera)
                HStack {
                    Button(model.cameraAuthorized ? "Camera allowed" : "Grant Camera Access…") { model.requestPermission(.video) }.disabled(model.cameraAuthorized)
                    Button(model.microphoneAuthorized ? "Microphone allowed" : "Grant Microphone Access…") { model.requestPermission(.audio) }.disabled(model.microphoneAuthorized)
                }
            }.disabled(engine.isRunning || model.busy)
            Section("Chat") {
                Toggle("Render chat", isOn: $model.configuration.chatEnabled)
                TextField("SSE URL", text: $model.configuration.chatURL)
                    .textFieldStyle(.roundedBorder).disabled(engine.isRunning)
                Text("Connect the existing anglbot Message SSE endpoint. Chat is safe-text rendered locally; no login or synthetic messages are injected.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private var layoutTab: some View {
        Form {
            Section("Desktop canvas") {
                DockFitControl(model: model, fit: model.dockFit)
            }
            Section("Program layout") {
                Picker("Scene", selection: $model.configuration.layout) { ForEach(SceneLayout.allCases) { Text($0.title).tag($0) } }
                SceneDiagram(configuration: model.configuration, layout: model.configuration.layout).frame(height: 190)
                Toggle("Render chat", isOn: $model.configuration.chatEnabled)
                Toggle("Desktop chat on left", isOn: $model.configuration.chatOnLeft)
                HStack { Text("Chat width"); Slider(value: $model.configuration.chatWidth, in: 288...576, step: 32); Text("\(Int(model.configuration.chatWidth)) px").monospacedDigit() }
                Picker("Webcam corner", selection: $model.configuration.cameraCorner) { ForEach(CameraCorner.allCases) { Text($0.title).tag($0) } }
                HStack { Text("Webcam size"); Slider(value: $model.configuration.cameraSize, in: 0.12...0.4) }
                Text("Desktop is aspect-fit; webcam is aspect-fill. Just Chatting keeps chat crisp over a blurred right-side camera panel. Shared camera and chat elements morph between scenes; Reduce Motion uses a cut. Turning the camera off removes its image immediately.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private var outputTab: some View {
        Form {
            Section("Recording") {
                Toggle("Record locally", isOn: $model.configuration.recordingEnabled)
                HStack { Text(model.configuration.recordingDirectory).lineLimit(2).font(.caption); Spacer(); Button("Choose…") { model.chooseRecordingFolder() } }
                Text("Matroska · H.264 6 Mb/s · AAC 160 kb/s. Unique filenames; existing recordings are never overwritten.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Streaming") {
                Toggle("Stream to RTMP / RTMPS", isOn: $model.configuration.streamingEnabled)
                Toggle("Twitch test stream", isOn: $model.configuration.twitchTestMode)
                    .disabled(!model.configuration.streamingEnabled)
                if model.configuration.twitchTestMode {
                    Text("Test your connection without going live. Use a Twitch server.").font(.caption).foregroundStyle(.secondary)
                    Link("View test results in Twitch Inspector", destination: URL(string: "https://inspector.twitch.tv")!)
                }
                TextField("Server URL (without stream key)", text: $model.configuration.streamURL).textFieldStyle(.roundedBorder)
                SecureField("Stream key", text: $model.streamKey).textFieldStyle(.roundedBorder)
                HStack { Button("Save Key in Keychain") { model.saveKey() }.disabled(model.streamKey.isEmpty || model.demo); if model.keySaved { Text("Saved").font(.caption).foregroundStyle(.secondary) } }
                Text("The server address is stored in settings; put credentials only in the key field. A blank key uses the saved Keychain key. Start Broadcast always asks for confirmation.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Output and device settings lock during a session. Scenes, camera enable, gains and mutes remain live. Stop waits for the recording to finalize.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).disabled(engine.isRunning || model.busy)
    }
}
