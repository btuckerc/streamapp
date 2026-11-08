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
                SceneStage(model: model, engine: engine)
                controlStrip
                MixerSection(model: model, meters: engine.meters)
            }.disabled(model.busy)
            if let warning = model.message ?? engine.errorMessage ?? engine.cameraStatus
                ?? engine.microphoneStatus ?? engine.meterPreviewError ?? engine.videoPreviewError ?? model.microphoneRouteWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2).textSelection(.enabled)
            }
            if model.demo {
                Text("Demo · sample video and audio").font(.caption2).foregroundStyle(.secondary)
            }
            sessionSection
            if !engine.isRunning, !model.busy, let recording = engine.lastRecording {
                SavedRecordingRow(recording: recording)
            }
            HStack {
                Button("Settings…", systemImage: "gearshape", action: openSettings)
                Spacer()
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
                .contextMenu {
                    Button("Arrange on Desktop…") { model.toggleCameraArrange?() }
                        .disabled(!model.canArrangeCamera)
                        .help(model.configuration.windowID != nil ? "Window capture: drag the webcam in the scene card instead." : "Arrange webcam (⌃⌥⌘M)")
                    ForEach(CameraPreset.allCases) { preset in
                        Button(preset.title) { model.configuration.cameraAnchor = preset.anchor }
                            .disabled(!model.configuration.cameraEnabled || model.configuration.layout != .desktopChat)
                    }
                }
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
                .disabled(!model.configuration.layout.showsDesktop || model.configuration.windowID != nil)
                .help("Annotate desktop (⌃⌥⌘D)")
                .accessibilityHint("Keyboard shortcut Control-Option-Command-D")
            ControlTile(title: "Clear", symbol: "eraser") { model.clearAnnotations?() }
                .help("Clear annotations").accessibilityLabel("Clear annotations")
        }
    }

    private var sessionSection: some View {
        let cancellable = model.sessionStage == .streamKey
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if engine.isRunning {
                    Label(engine.outputHealth, systemImage: "waveform.path.ecg")
                        .font(.caption2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
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
                    model.toggleSession(openStreamingSetup: openStreamingSetup)
                } label: {
                    HStack(spacing: 5) {
                        if model.busy { ProgressView().controlSize(.small) }
                        else { Image(systemName: engine.isRunning ? "stop.fill" : "play.fill") }
                        Text(cancellable ? "Cancel" : model.sessionStage?.title ?? (model.busy ? "Please wait…" : (engine.isRunning ? "Stop" : "Start")))
                            .fontWeight(.semibold)
                    }.frame(minWidth: 84)
                }.buttonStyle(.borderedProminent).tint(engine.isRunning ? .red : .accentColor)
                    .disabled(model.busy && !cancellable)
                    .help(cancellable ? "Getting the stream key. Cancel the start." : (engine.isRunning ? "Stop (⌃⌥⌘R)" : "Start (⌃⌥⌘R)"))
                    .accessibilityHint("Keyboard shortcut Control-Option-Command-R")
            }
            if cancellable {
                Text("Getting stream key…").font(.caption2).foregroundStyle(.secondary)
            }
            if let privacy = engine.privacyStatus, engine.isRunning {
                Label(privacy, systemImage: "checkmark.shield")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if model.rehearsalActive {
                Text("Rehearsal · nothing is sent online").font(.caption).foregroundStyle(.secondary)
            } else if model.configuration.streamingEnabled && model.configuration.twitchTestMode {
                Text("Test stream · not public").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The last session's file: what was saved and one click to play or find it.
private struct SavedRecordingRow: View {
    let recording: StudioEngine.RecordingResult

    var body: some View {
        let size = ByteCountFormatter.string(fromByteCount: recording.bytes, countStyle: .file)
        HStack(spacing: 6) {
            Label(recording.complete ? "Saved · \(MediaOutput.clock(recording.seconds)) · \(size)" : "May be incomplete · \(size)",
                  systemImage: recording.complete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(recording.complete ? Color.secondary : Color.orange)
                .lineLimit(1).help(recording.url.lastPathComponent)
            Spacer(minLength: 0)
            Button("Open") { NSWorkspace.shared.open(recording.url) }
                .help("Open \(recording.url.lastPathComponent)")
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([recording.url]) }
                .labelStyle(.iconOnly).help("Show \(recording.url.lastPathComponent) in Finder")
        }.font(.caption).buttonStyle(.borderless).controlSize(.small)
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
                             level: meters.microphone,
                             awayMuted: model.configuration.awaySilencesMicrophone)
            AudioChannelView(title: "App audio", symbol: "speaker.wave.2.fill", mutedSymbol: "speaker.slash.fill",
                             enabled: model.enabledBinding(for: .screen),
                             gain: $model.configuration.systemAudioGain, muted: $model.configuration.systemAudioMuted,
                             level: meters.system)
            AudioMixRow(level: meters.output, limiterReduction: meters.limiterReduction)
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

/// The scene card: the live program or webcam — or, with the preview off, a diagram of the
/// scene — joined to the scene buttons, so choosing a scene and seeing it share one place.
struct SceneStage: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: StudioEngine
    /// Fixed: the GPU view has no intrinsic size, and preferred-content-size sizing would
    /// otherwise collapse it.
    var monitorHeight: CGFloat = 200
    /// Settings has the width to list scenes beside the monitor; the menu stacks them below.
    var scenesBeside = false

    var body: some View {
        let width = monitorHeight * 16 / 9
        let screen = monitor
            .frame(width: width, height: monitorHeight)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 9, bottomLeadingRadius: scenesBeside ? 9 : 0,
                                              bottomTrailingRadius: 0, topTrailingRadius: scenesBeside ? 0 : 9))
            .overlay(alignment: .topTrailing) { previewMenu.padding(6) }
            .overlay(alignment: .topLeading) {
                if engine.isRunning { sessionBadge.padding(8) }
            }
        Group {
            if scenesBeside {
                HStack(spacing: 0) {
                    screen
                    SceneBar(model: model, vertical: true).padding(5).frame(width: 170, height: monitorHeight)
                }
            } else {
                VStack(spacing: 0) {
                    screen
                    SceneBar(model: model).padding(5)
                }.frame(width: width)
            }
        }
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private var monitor: some View {
        if engine.videoPreviewMode == .camera && !model.configuration.cameraEnabled {
            // Nothing to show: say why instead of an empty black monitor.
            monitorNote("Webcam is off", symbol: "video.slash")
        } else if let mode = engine.videoPreviewMode {
            // The surface stays clear until its first frame, so the note behind it shows while the webcam starts.
            GPUPreview(frames: engine.previewFrames, mode: mode)
                .background { if mode == .camera { monitorNote("Starting webcam…", symbol: "video") } else { Color.black } }
                .overlay {
                    if mode == .program && model.configuration.layout == .desktopChat && model.configuration.cameraEnabled {
                        CameraDragOverlay(model: model, engine: engine, configuration: model.configuration)
                    }
                }
                .accessibilityLabel(mode == .program ? "Scene preview" : "Webcam preview")
        } else {
            SceneDiagram(model: model, layout: model.configuration.layout)
                .accessibilityLabel("\(model.configuration.layout.title) scene diagram")
        }
    }
    private func monitorNote(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.35))
    }

    private var previewMode: Binding<PreviewFrames.Mode?> {
        Binding(get: { engine.videoPreviewMode }, set: { mode in Task { await engine.setVideoPreviewMode(mode) } })
    }
    private var previewMenu: some View {
        let mode = engine.videoPreviewMode
        return Menu {
            Picker("Preview", selection: previewMode) {
                Label("Preview", systemImage: "play.rectangle").tag(Optional(PreviewFrames.Mode.program))
                Label("Webcam only", systemImage: "video").tag(Optional(PreviewFrames.Mode.camera))
                Label("Off", systemImage: "rectangle.dashed").tag(Optional<PreviewFrames.Mode>.none)
            }.pickerStyle(.inline).labelsHidden()
        } label: {
            Label(mode == .program ? "Preview" : mode == .camera ? "Webcam" : "Preview off",
                  systemImage: mode == .camera ? "video" : "eye")
        } primaryAction: {
            previewMode.wrappedValue = mode == nil ? .program : nil
        }
        .menuStyle(.borderlessButton).fixedSize()
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .help(mode == nil ? "Show the preview" : "Turn the preview off to save power")
        .accessibilityLabel("Preview")
        .accessibilityValue(mode == .program ? "On" : mode == .camera ? "Webcam only" : "Off")
    }
    private var sessionBadge: some View {
        let c = model.configuration
        let test = c.streamingEnabled && c.twitchTestMode
        let title = model.rehearsalActive || c.outputMode == .record ? "REC"
            : test ? (c.outputMode == .both ? "TEST · REC" : "TEST")
            : c.outputMode == .both ? "LIVE · REC" : "LIVE"
        return Text(title)
            .font(.caption2.weight(.heavy)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(test ? Color.orange : Color.red, in: Capsule())
            .accessibilityLabel("Session active: \(title)")
    }
}

/// One button per scene, each a thumbnail of what choosing it gives.
/// ⌃⌥⌘1–4 select the same scenes in this order from any app.
struct SceneBar: View {
    @ObservedObject var model: StudioModel
    /// A column of rows beside the monitor instead of a strip below it.
    var vertical = false

    var body: some View {
        let stack = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        stack {
            ForEach(Array(SceneLayout.allCases.enumerated()), id: \.element) { index, layout in
                let selected = model.configuration.layout == layout
                let available = model.canSelectScene(layout)
                Button { model.selectScene(layout) } label: {
                    let label = vertical ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 3))
                    label {
                        SceneSchematic(configuration: outcome(layout))
                            .overlay(alignment: .topTrailing) {
                                if !available {
                                    Image(systemName: "video.slash.fill").font(.system(size: 9))
                                        .foregroundStyle(.white).padding(2).background(.black.opacity(0.65), in: Circle())
                                }
                            }
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(height: vertical ? 30 : 24)
                        Text(layout.title)
                            .font((vertical ? Font.callout : .caption2).weight(selected ? .semibold : .regular))
                            .lineLimit(1)
                        if vertical { Spacer(minLength: 0) }
                    }
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(maxWidth: .infinity, maxHeight: vertical ? .infinity : nil)
                    .padding(.vertical, 4).padding(.horizontal, vertical ? 6 : 0)
                    .background(selected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .opacity(available ? 1 : 0.4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Unavailable scenes stay clickable so the click explains itself (beep and message)
                // and the tooltip still shows.
                .help(available ? "\(layout.title) (⌃⌥⌘\(index + 1))"
                      : "\(layout.title) needs the webcam. Turn it on to use this scene. (⌃⌥⌘\(index + 1))")
                .accessibilityLabel("\(layout.title) scene")
                .accessibilityValue(available ? "" : "Needs the webcam")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityHint("Keyboard shortcut Control-Option-Command-\(index + 1)")
            }
        }
    }
    /// Draw the scene as if its webcam were enabled so unavailable scenes remain recognizable.
    private func outcome(_ layout: SceneLayout) -> StudioConfiguration {
        var c = model.configuration
        c.layout = layout
        if layout.usesCamera { c.cameraEnabled = true }
        return c
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
    /// The Away scene is silencing this source without changing its own mute.
    var awayMuted = false
    @State private var tracker = AudioLevelTracker()

    private var live: Bool { enabled && !muted && !awayMuted }

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 6) {
                Button { muted.toggle() } label: {
                    Image(systemName: live ? symbol : mutedSymbol)
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
                    Text(muted ? "Muted" : "Muted while away").font(.caption2.weight(.medium)).foregroundStyle(.orange)
                        .lineLimit(1)
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
    let limiterReduction: Float
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
                Text(String(format: "Limit −%.1f dB", limiterReduction))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(limiterReduction > 1 ? .orange : .secondary)
                    .help("Final sample-peak limiter reduction, separate from microphone compression. Not true-peak protection.")
            }
            // Same geometry as the fader tracks above, so the green bands line up.
            AudioLevelTrack(loudness: level.momentary, hold: level.peak > 0 ? tracker.hold : -.infinity, height: 5)
                .padding(.leading, 28 + 7).padding(.trailing, 7)
        }
        .onChange(of: level) { _, value in tracker.record(value) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mix level")
        .accessibilityValue((level.peak > 0 ? "\(tracker.zone.title), \(AudioLevelZone.readout(level.shortTerm))" : "Silent") +
                            String(format: ", final limiter reduction %.1f dB", limiterReduction))
    }
}

/// Static schematic of a scene from the same geometry the compositor uses: desktop (fitted 16:9),
/// Split's column, webcam with its frame and border, the Away card, and chat.
struct SceneSchematic: View {
    let configuration: StudioConfiguration
    /// Larger diagrams label each region with a symbol.
    var detailed = false

    var body: some View {
        GeometryReader { proxy in
            let c = configuration
            let g = SceneGeometry(configuration: c)
            let scale = proxy.size.width / SceneGeometry.canvas.width
            ZStack(alignment: .topLeading) {
                Color.black
                if g.away < 1 {
                    let screen = CameraDisplayMapping.fitted(source: SceneGeometry.canvas.size, in: g.desktop)
                    panel("display", color: .blue).placed(screen, scale: scale)
                }
                // The Split column and chat stay in the view, parked outside the frame when unused, so they slide.
                Rectangle().fill(Color(red: 0.07, green: 0.09, blue: 0.13)).placed(g.sidebar, scale: scale)
                if c.cameraEnabled, g.away < 1, g.camera.width >= 1, g.camera.height >= 1 {
                    let floating = g.overlay < 1
                    let shape = c.cameraFrame == .circle && floating ? AnyShape(Circle())
                        : AnyShape(RoundedRectangle(cornerRadius: floating ? min(g.camera.width, g.camera.height) * 0.08 * scale : 0))
                    panel("person.fill", color: .indigo)
                        .clipShape(shape)
                        .overlay {
                            if floating, c.cameraBorder != .none {
                                shape.stroke(Color(red: c.cameraBorderRed, green: c.cameraBorderGreen, blue: c.cameraBorderBlue),
                                             lineWidth: max(1, c.cameraBorder.width * scale))
                            }
                        }
                        .placed(g.camera, scale: scale)
                }
                let spec = AwayCardSpec(c)
                let ink: Color = spec.background == .color && AwayCard.prefersDarkText(red: spec.red, green: spec.green, blue: spec.blue)
                    ? Color(red: 0.07, green: 0.07, blue: 0.09) : .white
                (spec.background == .color ? Color(red: spec.red, green: spec.green, blue: spec.blue) : Color(red: 0.086, green: 0.094, blue: 0.11))
                    .overlay {
                        // The card is type only; small thumbnails stand it in with a line of "text".
                        VStack(spacing: max(2, 22 * scale)) {
                            if detailed {
                                Text(spec.title).font(.system(size: max(8, 72 * scale), weight: .semibold)).lineLimit(1)
                                    .foregroundStyle(ink.opacity(0.96))
                                if !spec.subtitle.isEmpty {
                                    Text(spec.subtitle).font(.system(size: max(7, 30 * scale))).lineLimit(1)
                                        .foregroundStyle(ink.opacity(0.62))
                                }
                            } else {
                                Capsule().fill(ink.opacity(0.85)).frame(width: 560 * scale, height: max(2, 64 * scale))
                            }
                        }
                        .padding(.horizontal, 120 * scale)
                        .frame(width: (SceneGeometry.canvas.width - spec.chatWidth) * scale)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .offset(y: -0.02 * SceneGeometry.canvas.height * scale)
                    }
                    // Like the program, the card waits above the frame and lifts off the top when leaving.
                    .offset(y: -(1 - g.away) * SceneGeometry.canvas.height * scale)
                panel("text.bubble", color: .teal).placed(g.chat, scale: scale)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: detailed ? 5 : 4))
    }
    private func panel(_ icon: String, color: Color) -> some View {
        RoundedRectangle(cornerRadius: detailed ? 4 : 1.5).fill(color.opacity(0.55)).overlay {
            if detailed { Image(systemName: icon).font(.system(size: 20)).foregroundStyle(.white.opacity(0.8)) }
        }
    }
}

private extension View {
    /// Places a view at a canvas rectangle (bottom-left origin) inside a top-left SwiftUI frame.
    func placed(_ rect: CGRect, scale: CGFloat) -> some View {
        frame(width: rect.width * scale, height: rect.height * scale)
            .offset(x: rect.minX * scale, y: (SceneGeometry.canvas.height - rect.maxY) * scale)
    }
}

struct SceneDiagram: View {
    @ObservedObject var model: StudioModel
    @ObservedObject private var engine: StudioEngine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let layout: SceneLayout
    init(model: StudioModel, layout: SceneLayout) {
        self.model = model; self.engine = model.engine; self.layout = layout
    }
    var body: some View {
        let c: StudioConfiguration = {
            var c = model.configuration; c.layout = layout
            c.cameraAnchor = engine.cameraDragAnchor ?? engine.cameraDodgeAnchor ?? c.cameraAnchor
            return c
        }()
        // Scene and source changes move like the program's own transition (Away covers at once);
        // drags track directly.
        let motion: Animation? = reduceMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: SceneTransition.duration)
        SceneSchematic(configuration: c, detailed: true)
            .animation(layout == .away ? nil : motion, value: c.layout)
            .animation(motion, value: c.cameraEnabled)
            .animation(motion, value: c.chatEnabled)
            .overlay {
                if c.cameraEnabled && layout == .desktopChat {
                    CameraDragOverlay(model: model, engine: model.engine, configuration: c)
                }
            }
    }
}
