import SwiftUI
import AVFoundation
import AppKit

struct StudioPopover: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: StudioEngine
    let openSettings: () -> Void
    let openStreamingSetup: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CaptureAccessBanner(model: model)
            Group {
                HStack(spacing: 8) {
                    Picker("Scene", selection: $model.configuration.layout) {
                        ForEach(SceneLayout.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                    Spacer(minLength: 0)
                    PreviewModePicker(model: model, engine: engine).pickerStyle(.menu).fixedSize()
                }.controlSize(.small)
                if engine.videoPreviewMode != nil {
                    StudioVideoPreview(model: model, engine: engine, compact: true)
                }
                controlStrip
                MixerSection(model: model, meters: engine.meters)
            }.disabled(model.busy)
            if let warning = model.message ?? engine.errorMessage ?? engine.cameraStatus
                ?? engine.meterPreviewError ?? engine.videoPreviewError {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2).textSelection(.enabled)
            }
            if model.demo {
                Text("Demo · sample video and audio").font(.caption2).foregroundStyle(.secondary)
            }
            sessionSection
            HStack {
                Button("Settings…", systemImage: "gearshape", action: openSettings)
                Spacer()
                if !engine.isRunning, let recording = engine.lastRecordingURL {
                    Button("Show Recording", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([recording])
                    }.help("Reveal \(recording.lastPathComponent) in Finder")
                }
                Button(action: quit) { Image(systemName: "power") }
                    .help("Quit StreamApp").accessibilityLabel("Quit StreamApp")
            }.buttonStyle(.borderless).controlSize(.small)
        }.padding(14).frame(width: 384)
    }

    private var controlStrip: some View {
        HStack(spacing: 6) {
            let camera = model.enabledBinding(for: .camera)
            ControlTile(title: "Webcam", symbol: model.configuration.cameraEnabled ? "video.fill" : "video.slash",
                        isOn: model.configuration.cameraEnabled) { camera.wrappedValue.toggle() }
                .help("Show the webcam in the scene")
                .accessibilityValue(model.configuration.cameraEnabled ? "On" : "Off")
            ControlTile(title: model.configuration.cameraPunchIn ? "Punch out" : "Punch in",
                        symbol: model.configuration.cameraPunchIn ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        isOn: model.configuration.cameraPunchIn) { model.toggleCameraPunchIn() }
                .disabled(!model.canPunchInCamera)
                .help("Webcam punch-in (⌃⌥⌘V)")
                .accessibilityLabel(model.configuration.cameraPunchIn ? "Punch out webcam" : "Punch in webcam")
                .accessibilityHint("Keyboard shortcut Control-Option-Command-V")
            ControlTile(title: "Chat", symbol: "bubble.left.and.bubble.right.fill",
                        isOn: model.configuration.chatEnabled) { model.configuration.chatEnabled.toggle() }
                .help("Show the chat column in the scene")
                .accessibilityValue(model.configuration.chatEnabled ? "On" : "Off")
            ControlTile(title: "Annotate", symbol: "pencil.tip") { model.toggleAnnotations?() }
                .disabled(model.configuration.layout != .desktopChat || model.configuration.windowID != nil)
                .help("Annotate desktop (⌃⌥⌘D)")
                .accessibilityHint("Keyboard shortcut Control-Option-Command-D")
            ControlTile(title: "Clear", symbol: "eraser") { model.clearAnnotations?() }
                .help("Clear annotations").accessibilityLabel("Clear annotations")
        }
    }

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if engine.isRunning {
                    Label(engine.outputHealth, systemImage: "waveform.path.ecg")
                        .font(.caption2).lineLimit(1).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !model.rehearsalActive {
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
                } else {
                    Spacer(minLength: 0)
                }
                Button {
                    if engine.isRunning { model.stop() }
                    else if model.configuration.streamingEnabled && !model.validateStreamSetup() { openStreamingSetup() }
                    else { model.start() }
                } label: {
                    HStack(spacing: 5) {
                        if model.busy { ProgressView().controlSize(.small) }
                        Image(systemName: engine.isRunning ? "stop.fill" : "play.fill")
                        Text(model.busy ? "Please wait…" : (engine.isRunning ? "Stop" : "Start")).fontWeight(.semibold)
                    }.frame(minWidth: 84)
                }.buttonStyle(.borderedProminent).tint(engine.isRunning ? .red : .accentColor).disabled(model.busy)
            }
            if model.rehearsalActive {
                Text("Local rehearsal").font(.caption).foregroundStyle(.secondary)
            } else if model.configuration.streamingEnabled && model.configuration.twitchTestMode {
                Text("Test stream · not live").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The only popover content that observes the 5 Hz meters, so level updates redraw these rows
/// rather than the whole panel.
private struct MixerSection: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var meters: AudioMeters

    var body: some View {
        VStack(spacing: 8) {
            AudioChannelView(title: "Microphone", symbol: "mic.fill", mutedSymbol: "mic.slash.fill",
                             enabled: model.enabledBinding(for: .microphone),
                             gain: $model.configuration.microphoneGain, muted: $model.configuration.microphoneMuted,
                             level: meters.microphone)
            AudioChannelView(title: "App audio", symbol: "speaker.wave.2.fill", mutedSymbol: "speaker.slash.fill",
                             enabled: model.enabledBinding(for: .screen),
                             gain: $model.configuration.systemAudioGain, muted: $model.configuration.systemAudioMuted,
                             level: meters.system)
            AudioMixRow(level: meters.output)
        }
    }
}

/// Microphone and app-audio meters for setup screens; observes only the meters.
struct SourceLevelMeters: View {
    @ObservedObject var meters: AudioMeters

    var body: some View {
        HStack {
            AudioLevelMeter(title: "Mic", level: meters.microphone)
            AudioLevelMeter(title: "System", level: meters.system)
        }
    }
}

private struct ControlTile: View {
    let title: String
    let symbol: String
    var isOn = false
    let action: @MainActor () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 15)).frame(height: 18)
                Text(title).font(.caption2).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .foregroundStyle(isOn ? Color.accentColor : .primary)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(isOn ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06)))
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// Compact loudness meter: momentary bar against the target band, short-term LUFS readout.
struct AudioLevelMeter: View {
    let title: String
    let level: AudioLevel
    var body: some View {
        let readout = AudioLevelZone.readout(level.shortTerm)
        VStack(spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(readout).monospacedDigit()
            }.font(.caption2).foregroundStyle(.secondary)
            AudioLevelTrack(loudness: level.momentary, hold: -.infinity, height: 5)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title) loudness \(readout)")
            .help("\(title): \(readout) over the last 3 s. Aim for the green band.")
    }
}

struct AudioChannelView: View {
    let title: String
    let symbol: String
    let mutedSymbol: String
    @Binding var enabled: Bool
    @Binding var gain: Double
    @Binding var muted: Bool
    let level: AudioLevel
    @State private var tracker = AudioLevelTracker()

    private var live: Bool { enabled && !muted }

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 6) {
                Button { muted.toggle() } label: {
                    Image(systemName: muted || !enabled ? mutedSymbol : symbol)
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(muted && enabled ? Color.orange : .secondary)
                .accessibilityLabel("\(muted ? "Unmute" : "Mute") \(title)")
                .help("\(muted ? "Unmute" : "Mute") \(title). Muting keeps the gain and the device open.")
                .disabled(!enabled)
                if live {
                    AudioLevelVerdict(zone: level.peak > 0 ? tracker.zone : .silent)
                } else if enabled {
                    Text("Muted").font(.caption2.weight(.medium)).foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
                Text(AudioFaderScale.readout(gain))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(enabled ? .primary : .secondary)
                Toggle("Enable \(title)", isOn: $enabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .help("Enable \(title.lowercased()). Off releases the device; mute only silences the mix.")
            }
            AudioLevelFader(title: title, gain: $gain, loudness: live ? level.momentary : -.infinity,
                            hold: live && level.peak > 0 ? tracker.hold : -.infinity)
                .padding(.leading, 28)
                .disabled(!enabled)
        }
        .onChange(of: level) { _, value in tracker.record(value) }
        .onChange(of: live) { _, _ in tracker = AudioLevelTracker() }
    }
}

/// Program mix after gain, mute, and protection: the level viewers actually hear.
private struct AudioMixRow: View {
    let level: AudioLevel
    @State private var tracker = AudioLevelTracker()

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "waveform").foregroundStyle(.secondary).frame(width: 22)
                AudioLevelVerdict(zone: level.peak > 0 ? tracker.zone : .silent)
                Spacer(minLength: 0)
                Text(AudioLevelZone.readout(level.shortTerm))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .help("Short-term loudness: the last 3 s, per ITU-R BS.1770.")
            }
            // Same geometry as the fader tracks above, so the green bands line up.
            AudioLevelTrack(loudness: level.momentary, hold: level.peak > 0 ? tracker.hold : -.infinity, height: 5)
                .padding(.leading, 28 + 7).padding(.trailing, 7)
        }
        .onChange(of: level) { _, value in tracker.record(value) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mix level")
        .accessibilityValue(level.peak > 0 ? "\(tracker.zone.title), \(AudioLevelZone.readout(level.shortTerm))" : "Silent")
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
                        let cameraSize: CGSize = {
                            let size = CGFloat(sceneConfiguration.effectiveCameraSize)
                            if sceneConfiguration.cameraFrame != .widescreen {
                                let cameraHeight = min(height * size, height - 10)
                                return CGSize(width: cameraHeight * sceneConfiguration.cameraFrame.aspectRatio,
                                              height: cameraHeight)
                            }
                            let cameraWidth = min(stageWidth * size,
                                                  (height - 10) * sceneConfiguration.cameraFrame.aspectRatio)
                            return CGSize(width: cameraWidth,
                                          height: cameraWidth / sceneConfiguration.cameraFrame.aspectRatio)
                        }()
                        let cameraWidth = cameraSize.width
                        let cameraHeight = cameraSize.height
                        let left = sceneConfiguration.cameraCorner == .bottomLeft || sceneConfiguration.cameraCorner == .topLeft
                        let top = sceneConfiguration.cameraCorner == .topLeft || sceneConfiguration.cameraCorner == .topRight
                        let cameraShape = sceneConfiguration.cameraFrame == .circle
                            ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 4))
                        panel("person.fill", color: .indigo).frame(width: cameraWidth, height: cameraHeight)
                            .clipShape(cameraShape)
                            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                            .offset(x: stageX + (left ? 5 : stageWidth - cameraWidth - 5),
                                    y: top ? 5 : height - cameraHeight - 5)
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
    private func panel(_ icon: String, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.55)).overlay(Image(systemName: icon).font(.system(size: 20)).foregroundStyle(.white.opacity(0.8)))
    }
}

/// Off / Layout / Webcam; the caller picks the picker style.
struct PreviewModePicker: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: StudioEngine
    var body: some View {
        Picker("Preview", selection: Binding<PreviewFrames.Mode?>(
            get: { engine.videoPreviewMode },
            set: { mode in Task { await engine.setVideoPreviewMode(mode) } }
        )) {
            Text("Off").tag(Optional<PreviewFrames.Mode>.none)
            Text("Layout").tag(Optional(PreviewFrames.Mode.program))
            Text("Webcam").tag(Optional(PreviewFrames.Mode.camera))
        }.disabled(model.busy)
    }
}

struct StudioVideoPreview: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: StudioEngine
    /// Popover form: no picker or captions (the popover hosts its own); just the frame.
    var compact = false
    var body: some View {
        VStack(spacing: 8) {
            if !compact {
                PreviewModePicker(model: model, engine: engine).pickerStyle(.segmented).labelsHidden()
            }
            if let mode = engine.videoPreviewMode {
                GPUPreview(frames: engine.previewFrames, mode: mode)
                    .aspectRatio(16/9, contentMode: .fit)
                    // Fixed height in the popover: the representable has no intrinsic size, and
                    // preferred-content-size sizing would otherwise collapse it to zero.
                    .frame(minHeight: compact ? 200 : 0, maxHeight: compact ? 200 : 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(mode == .program ? "Live layout preview" : "Live webcam preview")
            }
            if !compact {
                if let error = engine.videoPreviewError {
                    Text(error).font(.caption2).foregroundStyle(.orange)
                }
                if model.demo {
                    Text("Demo · sample video and audio").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
