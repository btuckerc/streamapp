import SwiftUI
import AppKit
import AVFoundation

/// Compact first-run setup. Every permission and capture action is user initiated.
struct StudioOnboarding: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: StudioEngine
    let onFinish: () -> Void
    var streamingOnly = false

    private enum Step: Int, CaseIterable { case connect, prepare, tryIt
        var title: String { switch self { case .connect: "Connect"; case .prepare: "Prepare"; case .tryIt: "Try it" } }
    }
    @State private var step: Step = .connect

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !streamingOnly { header }
            Divider()
            ScrollView {
                Group {
                    if streamingOnly {
                        streamingSetup
                    } else {
                    switch step {
                    case .connect: connect
                    case .prepare: prepare
                    case .tryIt: tryIt
                    }
                    }
                }.padding(24)
            }
            Divider()
            if streamingOnly {
                HStack {
                    Button("Cancel", action: onFinish)
                    Spacer()
                    Button("Done") {
                        guard model.validateStreamSetup() else { return }
                        if model.configuration.streamService == .custom && !model.demo && !model.streamKey.isEmpty {
                            model.saveKey()
                            guard model.streamKey.isEmpty else { return }
                        }
                        onFinish()
                    }.buttonStyle(.borderedProminent)
                }.padding(16).disabled(model.busy)
            } else {
                footer.padding(16)
            }
        }
        .frame(width: 520, height: 560)
        .onAppear { model.refreshAuthorization() }
        .onDisappear { if model.rehearsalActive { model.stopRehearsal() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "dot.radiowaves.left.and.right").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up your studio").font(.headline)
                    Text("Choose only what you need. You can change everything later in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 5) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule().fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.2)).frame(height: 4)
                    Text(item.title).font(.caption2).foregroundStyle(item == step ? .primary : .secondary)
                }
            }
        }.padding(20)
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: 18) {
            intro("Connect your sources", "Nothing starts until you press a button. You can finish with a local-only setup.")
            permissionRow("Screen Recording", detail: model.screenAuthorized ? "Ready to select a display or window" : "Optional — needed for desktop capture", icon: "rectangle.on.rectangle", ready: model.screenAuthorized) {
                model.requestScreenPermission()
            }
            permissionRow("Camera", detail: model.cameraAuthorized ? "Ready" : "Optional — needed for webcam", icon: "video", ready: model.cameraAuthorized) {
                model.requestPermission(.video)
            }
            permissionRow("Microphone", detail: model.microphoneAuthorized ? "Ready" : "Optional — needed for mic audio", icon: "mic", ready: model.microphoneAuthorized) {
                model.requestPermission(.audio)
            }
            Button("Refresh status") { model.refreshAuthorization(); model.refreshSources() }.buttonStyle(.borderless)
            if let message = model.message { Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
        }
    }

    private var prepare: some View {
        VStack(alignment: .leading, spacing: 16) {
            intro("Prepare your scene", "Pick a layout and the devices you want. Camera, microphone, Twitch, and screen capture are all optional.")
            Picker("Scene", selection: $model.configuration.layout) {
                ForEach(SceneLayout.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            scenePreview
            if model.configuration.layout == .desktopChat {
                sourcePicker
            }
            Toggle(isOn: $model.configuration.cameraEnabled) { Label("Camera", systemImage: "video") }
                .disabled(!model.cameraAuthorized)
            if model.configuration.cameraEnabled { devicePicker("Camera", devices: model.cameras) }
            Toggle(isOn: $model.configuration.microphoneEnabled) { Label("Microphone", systemImage: "mic") }
                .disabled(!model.microphoneAuthorized)
            if model.configuration.microphoneEnabled { devicePicker("Microphone", devices: model.microphones) }
            Toggle(isOn: $model.configuration.systemAudioEnabled) { Label("System audio", systemImage: "speaker.wave.2") }
                .disabled(engine.isRunning || model.busy)
            if model.configuration.systemAudioEnabled {
                SystemAudioSourcePicker(model: model, engine: engine)
                if !model.screenAuthorized {
                    Text("Allow Screen Recording in Connect to capture system audio.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ClickableDisclosure("Twitch account & chat (optional)") {
                TwitchConnectionView(session: model.twitch, locked: model.demo || engine.isRunning || model.busy)
                TwitchChatSettings(model: model, engine: engine)
            }
        }.disabled(model.busy)
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text("Screen source").font(.subheadline.weight(.medium)); Spacer(); Button("Refresh") { model.refreshSources() }.buttonStyle(.borderless) }
            if model.sources.isEmpty { Text("No source selected. Refresh after granting Screen Recording, or use Just Chatting.").font(.caption).foregroundStyle(.secondary) }
            else { Picker("Source", selection: Binding(get: { model.configuration.windowID.map { "window:\($0)" } ?? model.configuration.displayID.map { "display:\($0)" } ?? "" }, set: { value in
                guard let source = model.sources.first(where: { $0.stableID == value }) else { return }
                model.configuration.displayID = source.kind == .display ? source.id : nil
                model.configuration.windowID = source.kind == .window ? source.id : nil
            })) { Text("Choose a source").tag(""); ForEach(model.sources, id: \.stableID) { Text($0.name).tag($0.stableID) } }.labelsHidden() }
        }.disabled(engine.isRunning || model.busy)
    }
    private func finish() {
        Task {
            await model.stopRehearsalAndWait()
            model.completeOnboarding()
            onFinish()
        }
    }

    private func devicePicker(_ title: String, devices: [DeviceOption]) -> some View {
        Picker(title, selection: Binding(get: {
            title == "Camera" ? model.configuration.cameraID : model.configuration.microphoneID
        }, set: { value in
            if title == "Camera" { model.configuration.cameraID = value } else { model.configuration.microphoneID = value }
        })) { Text("Default device").tag(""); ForEach(devices) { Text($0.name).tag($0.id) } }.disabled(engine.isRunning || model.busy)
    }


    private var streamingSetup: some View {
        VStack(alignment: .leading, spacing: 16) {
            intro("Connect streaming", "Use Twitch or another RTMP/RTMPS platform.")
            Picker("Service", selection: $model.configuration.streamService) {
                ForEach(StreamService.allCases) { Text($0.title).tag($0) }
            }
            if model.configuration.streamService == .twitch {
                TwitchConnectionView(session: model.twitch, locked: model.demo || engine.isRunning || model.busy)
                TwitchChatSettings(model: model, engine: engine)
            } else {
                streamConnectionFields
            }
            Toggle("Twitch bandwidth test", isOn: $model.configuration.twitchTestMode)
            Text("Return to the menu and press Start when ready.").font(.caption).foregroundStyle(.secondary)
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var streamConnectionFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Server URL (rtmp:// or rtmps://)", text: $model.configuration.streamURL)
                .textFieldStyle(.roundedBorder)
            SecureField("Stream key", text: $model.streamKey).textFieldStyle(.roundedBorder)
            HStack {
                Button("Save key securely") { model.saveKey() }.disabled(model.streamKey.isEmpty || model.demo)
                if model.keySaved { Label("Saved", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 14) {
            intro("Try it locally", "Rehearsal uses selected sources and records locally. It cannot broadcast.")
            Picker("Scene", selection: $model.configuration.layout) { ForEach(SceneLayout.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).disabled(model.busy)
            HStack {
                Toggle(isOn: $model.configuration.cameraEnabled) { Label("Camera", systemImage: "video") }.disabled(!model.cameraAuthorized || model.busy)
                Toggle(isOn: $model.configuration.microphoneEnabled) { Label("Microphone", systemImage: "mic") }.disabled(!model.microphoneAuthorized || model.busy)
            }
            HStack {
                Text(model.configuration.recordingDirectory).font(.caption).lineLimit(1)
                Spacer()
                Button("Choose…") { model.chooseRecordingFolder() }.buttonStyle(.borderless).disabled(model.busy || engine.isRunning)
                Button("Open folder") { NSWorkspace.shared.open(URL(fileURLWithPath: model.configuration.recordingDirectory)) }.buttonStyle(.borderless)
            }
            scenePreview
        }
    }

    private var scenePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.rehearsalActive ? model.stopRehearsal() : model.startRehearsal()
            } label: {
                Text(model.rehearsalActive ? "Stop preview" : "Start local preview").frame(width: 140)
            }.buttonStyle(.bordered).disabled(model.busy)
            if engine.isRunning {
                GPUPreview(frames: engine.previewFrames).aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Live scene preview")
            } else {
                SceneDiagram(configuration: model.configuration, layout: model.configuration.layout)
                    .aspectRatio(16 / 9, contentMode: .fit).accessibilityLabel("Scene layout preview")
            }
            HStack {
                Toggle("Render chat", isOn: $model.configuration.chatEnabled)
                if step == .prepare {
                    Spacer()
                    DockFitControl(model: model, fit: model.dockFit, compact: true)
                }
            }.toggleStyle(.switch)
            HStack { meter("Mic", engine.microphoneLevel); meter("System", engine.systemLevel) }
            Text(model.rehearsalActive ? "LOCAL REC · Preview is live. Nothing is sent to Twitch." : "Preview records a local rehearsal using your selected sources. Nothing is sent to Twitch.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = model.message ?? engine.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { if let previous = Step(rawValue: step.rawValue - 1) { step = previous } }
                .disabled(step == .connect || model.busy || model.rehearsalActive)
            Spacer()
            if step == .tryIt {
                Button("Finish") { finish() }.buttonStyle(.borderedProminent).disabled(model.busy)
            } else {
                Button("Continue") { if let next = Step(rawValue: step.rawValue + 1) { step = next } }
                    .buttonStyle(.borderedProminent).disabled(model.busy)
            }
        }
    }

    private func intro(_ title: String, _ detail: String) -> some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.title3.weight(.semibold)); Text(detail).font(.callout).foregroundStyle(.secondary) } }
    private func permissionRow(_ title: String, detail: String, icon: String, ready: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) { Image(systemName: icon).frame(width: 24).foregroundStyle(.tint); VStack(alignment: .leading) { Text(title).font(.subheadline.weight(.medium)); Text(detail).font(.caption).foregroundStyle(.secondary) }; Spacer(); if ready { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } else { Button("Allow…", action: action).buttonStyle(.bordered) } }
    }
    private func meter(_ title: String, _ value: Float) -> some View { AudioLevelMeter(title: title, level: value) }
}
