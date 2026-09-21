import SwiftUI
import AppKit

struct TwitchConnectionView: View {
    @ObservedObject var session: TwitchSession
    var locked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let account = session.account {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    Text("Connected as @\(account.login)")
                    connectionInfo
                    Spacer()
                    Button("Disconnect") { Task { await session.disconnect() } }.disabled(locked)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Button(session.connecting ? "Connecting to Twitch…" : "Connect with Twitch") { session.connect() }
                        .disabled(locked || session.connecting)
                    connectionInfo
                }
            }
            if let authorization = session.deviceAuthorization {
                Text("Enter code \(authorization.userCode) on Twitch").font(.headline).textSelection(.enabled)
                HStack {
                    Link("Open Twitch authorization", destination: authorization.verificationURL)
                    Button("Cancel sign-in") { session.cancelConnect() }
                }
            }
            if session.account == nil && session.status != "Not connected" || session.account != nil && !session.status.hasPrefix("Connected as ") {
                Text(session.status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var connectionInfo: some View {
        Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
            .help("Twitch lets this app read chat and get your stream key. It cannot post chat messages. Connecting does not start a stream.")
            .accessibilityLabel("About Twitch connection")
    }
}

struct TwitchChatSettings: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var engine: StudioEngine
    @ObservedObject private var session: TwitchSession
    @State private var channel = ""
    @State private var showingCheck = false
    @State private var channelError: String?
    @State private var checking = false

    init(model: StudioModel, engine: StudioEngine) {
        self.model = model
        self.engine = engine
        self.session = model.twitch
    }

    private var locked: Bool { model.demo || model.busy || engine.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(session.account.map { "Chat channel (default: \($0.login))" } ?? "Chat channel", text: $channel)
                .textFieldStyle(.roundedBorder).onSubmit { applyChannel() }.disabled(locked || checking)
                .onChange(of: channel) { _, _ in channelError = nil }
            HStack {
                if channel != model.configuration.twitchChatChannel {
                    Button(checking ? "Checking…" : "Apply") { applyChannel() }
                        .disabled(locked || checking)
                }
                Button("Test chat") { applyChannel(test: true) }
                    .disabled(locked || checking || session.account == nil)
                    .help("Shows chat without recording or streaming.")
            }
            if let channelError { Text(channelError).font(.caption).foregroundStyle(.orange) }
            ClickableDisclosure("Appearance") {
                ChatAppearanceControls(appearance: $model.configuration.chatAppearance)
                    .disabled(model.busy)
            }
            ClickableDisclosure("Bot commands") {
                Text("Handled by anglbot, not StreamApp.").foregroundStyle(.secondary)
                LabeledContent("!help", value: "List available commands")
                LabeledContent("!fish", value: "Catch a fish")
                LabeledContent("!fish help", value: "Fishing odds")
                Text("Also: !ping, !whoami, !groups, !history, !cowsay, !followage, !time, !song")
                    .foregroundStyle(.secondary).textSelection(.enabled)
                Text("The bot must be running in that channel. Its permissions, cooldowns, custom commands and profanity filter stay in anglbot. Charts and HTML replies are not embedded here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { channel = model.configuration.twitchChatChannel }
        .onChange(of: model.configuration.twitchChatChannel) { _, value in channel = value }
        .sheet(isPresented: $showingCheck) {
            TwitchChatCheck(channel: model.configuration.twitchChatChannel, width: Int(model.configuration.chatWidth),
                            appearance: $model.configuration.chatAppearance)
        }
    }

    private func applyChannel(test: Bool = false) {
        guard !locked, !checking else { return }
        let input = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = input.isEmpty ? "" : TwitchChatFeed.normalize(input) else {
            channelError = "Enter a Twitch username or channel link."
            return
        }
        channelError = nil
        checking = true
        Task { @MainActor in
            defer { checking = false }
            if !value.isEmpty, session.account != nil {
                do { _ = try await session.user(login: value) }
                catch TwitchSessionError.invalidRequest {
                    channelError = "Channel not found. Check the username."
                    return
                } catch {
                    channelError = "Couldn't check this channel. Try again."
                    return
                }
            }
            guard !locked else { return }
            channel = value
            model.configuration.twitchChatChannel = value
            if test { showingCheck = true }
        }
    }
}

private struct ChatAppearanceControls: View {
    @Binding var appearance: ChatAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Preset", selection: Binding<ChatAppearance.Preset?>(
                get: { appearance.preset },
                set: { if let preset = $0 { appearance = preset.appearance } }
            )) {
                if appearance.preset == nil { Text("Custom").tag(ChatAppearance.Preset?.none).disabled(true) }
                ForEach(ChatAppearance.Preset.allCases) { preset in Text(preset.title).tag(Optional(preset)) }
            }
            .help("Presets replace the appearance options below. Individual changes are kept as Custom.")
            HStack {
                Text("Text size")
                Slider(value: $appearance.fontSize, in: 20...48, step: 2)
                    .accessibilityLabel("Chat text size at 1080p")
                Text("\(Int(appearance.fontSize)) px").monospacedDigit().frame(width: 48, alignment: .trailing)
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                    .help("Pixels in the 1080p output, not the smaller preview. Default: 24 px. Smaller playback scales the text down too. Twitch has no prescribed overlay font size.")
                    .accessibilityLabel("About chat text size")
            }
            Toggle("Twitch name colors", isOn: $appearance.userColors)
                .help("Keeps Twitch colors when readable; brightens dark colors to reach 4.5:1 contrast. Names remain bold when colors are off.")
            Toggle("Emotes", isOn: $appearance.emotes)
                .help("Twitch plus global and channel emotes from 7TV, BetterTTV and FrankerFaceZ. Static images keep chat lightweight. Codes are case-sensitive; unavailable images stay as text. Private/personal packs are not included.")
            Toggle("Highlight commands & mentions", isOn: $appearance.highlights)
                .help("Styles !commands and Twitch mentions. Does not run commands or send replies.")
            Toggle("Timestamps", isOn: $appearance.timestamps)
                .help("Message time in your Mac’s local time zone.")
            Toggle("Channel heading", isOn: $appearance.showHeader)
            Toggle("Connection status", isOn: $appearance.showStatus)
            Toggle("Solid background", isOn: $appearance.solidBackground)
                .help("Off uses a 90% dark background. Both modes keep text contrast even over bright scenes.")
        }
    }
}

@MainActor
private final class TwitchChatCheckModel: ObservableObject {
    @Published var image: CGImage?
    @Published var status = "Connecting…"
    @Published var transcript = ""
    @Published var emoteStatus = "Loading emotes…"
    private var chat: Chat?

    func start(channel: String, width: Int, appearance: ChatAppearance) {
        guard chat == nil else { return }
        chat = Chat(onImage: { [weak self] image in self?.image = image }, channel: channel, width: width, appearance: appearance,
                    onStatus: { [weak self] status in self?.status = status },
                    onTranscript: { [weak self] text in self?.transcript = text },
                    onEmoteStatus: { [weak self] text in self?.emoteStatus = text })
    }
    func updateAppearance(_ appearance: ChatAppearance) { chat?.updateAppearance(appearance) }
    func stop() { chat?.stop(); chat = nil; image = nil; transcript = "" }
}

private struct TwitchChatCheck: View {
    let channel: String
    let width: Int
    @Binding var appearance: ChatAppearance
    @State private var textView = false
    @Environment(\.dismiss) private var dismiss
    @StateObject private var check = TwitchChatCheckModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Read-only Twitch chat").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(check.status).font(.caption).textSelection(.enabled)
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                    .help(check.emoteStatus).accessibilityLabel("Emote loading: \(check.emoteStatus)")
            }
            Picker("Chat view", selection: $textView) {
                Text("Overlay").tag(false)
                Text("Text").tag(true)
            }.pickerStyle(.segmented)
            if textView {
                ScrollView {
                    Text(check.transcript.isEmpty ? "Waiting for chat…" : check.transcript)
                        .font(.system(size: 18, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .help("Selectable live text. Scroll manually; messages are still removed when moderated.")
            } else {
                ScrollView {
                    if let image = check.image {
                        Image(decorative: image, scale: 1).resizable().frame(width: CGFloat(width), height: 1080)
                    } else { ProgressView().frame(width: CGFloat(width), height: 180) }
                }
                .defaultScrollAnchor(.bottom)
                .background(Color.black).clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Chat overlay preview. Choose Text for readable messages.")
            }
            ClickableDisclosure("Appearance") { ChatAppearanceControls(appearance: $appearance) }
            Text("Live reception only. No messages sent. No recording or broadcast.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: CGFloat(max(424, width + 40)), height: 760)
        .onAppear { check.start(channel: channel, width: width, appearance: appearance) }
        .onChange(of: appearance) { _, value in check.updateAppearance(value) }
        .onDisappear { check.stop() }
    }
}
