import Foundation
import CoreGraphics

// Shared value contract for the menu, capture engine, and output worker.
enum SceneLayout: String, Codable, CaseIterable, Identifiable {
    case desktopChat, sideBySide, justChatting, away
    var id: String { rawValue }
    var title: String {
        switch self { case .desktopChat: "Desktop"; case .sideBySide: "Split"; case .justChatting: "Full Camera"; case .away: "Away" }
    }
    /// Scenes that show the captured display or window.
    var showsDesktop: Bool { self == .desktopChat || self == .sideBySide }
    /// Scenes built around the webcam; unavailable while it is off.
    var usesCamera: Bool { self == .sideBySide || self == .justChatting }
    var withoutCamera: SceneLayout {
        switch self {
        case .justChatting: .away
        case .sideBySide: .desktopChat
        default: self
        }
    }
}
/// Accent ring drawn around the webcam in Desktop and Split.
enum CameraBorder: String, Codable, CaseIterable, Identifiable {
    case none, thin, bold
    var id: String { rawValue }
    var title: String { switch self { case .none: "None"; case .thin: "Thin"; case .bold: "Bold" } }
    /// Ring width in program pixels (1080p canvas).
    var width: CGFloat { switch self { case .none: 0; case .thin: 4; case .bold: 10 } }
}
enum CameraFrame: String, Codable, CaseIterable, Identifiable {
    case widescreen, square, circle
    var id: String { rawValue }
    var title: String {
        switch self { case .widescreen: "Wide"; case .square: "Square"; case .circle: "Circle" }
    }
    var aspectRatio: CGFloat { self == .widescreen ? 16 / 9 : 1 }
}
enum OutputMode: String, CaseIterable, Identifiable {
    case record, stream, both
    var id: String { rawValue }
    var title: String { switch self { case .record: "Record"; case .stream: "Stream"; case .both: "Both" } }
}
enum StreamService: String, Codable, CaseIterable, Identifiable {
    case twitch, custom
    var id: String { rawValue }
    var title: String { self == .twitch ? "Twitch" : "Custom RTMP" }
}
/// Local recording container. Both hold the same H.264 + AAC streams and survive a crash mid-recording.
enum RecordingFormat: String, Codable, CaseIterable, Identifiable {
    /// FFmpeg `hybrid_fragmented`: written as fragmented MP4 (recoverable), finalized as a regular MP4
    /// that QuickTime, Finder previews, Photos, and editors open directly.
    case mp4
    /// Matroska: recoverable, but QuickTime and Finder cannot play it.
    case mkv
    var id: String { rawValue }
    var title: String { self == .mp4 ? "MP4" : "MKV" }
    var fileExtension: String { rawValue }
    /// Tee-muxer slave options for the recording output.
    var teeOptions: String { self == .mp4 ? "f=mp4:movflags=+hybrid_fragmented" : "f=matroska" }
}
enum TeleprompterMode: String, Codable, CaseIterable, Identifiable {
    case off, transcript, twitchChat
    var id: String { rawValue }
    var title: String {
        switch self { case .off: "Off"; case .transcript: "Transcript"; case .twitchChat: "Twitch chat" }
    }
}
/// Broadcast-only ducking: app audio drops by a fixed depth while the microphone carries speech.
/// Depths follow published starting points: ~6 dB for narration over music, up to 12 dB in the
/// creator range, and ~18 dB where OBS's documented sidechain preset lands for normal speech.
enum AudioDucking: String, Codable, CaseIterable, Identifiable {
    case off, light, medium, deep
    var id: String { rawValue }
    var title: String {
        switch self { case .off: "Off"; case .light: "Light"; case .medium: "Medium"; case .deep: "Deep" }
    }
    /// Attenuation applied to app audio while speaking, in dB (0 when off).
    var depth: Double {
        switch self { case .off: 0; case .light: 6; case .medium: 12; case .deep: 18 }
    }
}
/// Channel numbers are one-based in settings; converter maps are zero-based.
enum AudioChannelSelection: Hashable, Codable {
    case deviceDefault, mono(Int), stereo(Int, Int)

    var title: String {
        switch self {
        case .deviceDefault: "Device default"
        case .mono(let channel): "Mono \(channel) · centered"
        case .stereo(let left, let right): "Stereo \(left)/\(right)"
        }
    }
    func validated(channelCount: Int) -> Self {
        switch self {
        case .deviceDefault: return self
        case .mono(let channel): return (1...max(1, channelCount)).contains(channel) && channelCount > 0 ? self : .deviceDefault
        case .stereo(let left, let right): return left > 0 && right == left + 1 && right <= channelCount ? self : .deviceDefault
        }
    }
    func channelMap(channelCount: Int) -> [NSNumber]? {
        switch validated(channelCount: channelCount) {
        case .deviceDefault: return nil
        case .mono(let channel): return [NSNumber(value: channel - 1), NSNumber(value: channel - 1)]
        case .stereo(let left, let right): return [NSNumber(value: left - 1), NSNumber(value: right - 1)]
        }
    }
    static func choices(channelCount: Int) -> [Self] {
        guard channelCount > 0 else { return [.deviceDefault] }
        return [.deviceDefault] + (1...channelCount).map { .mono($0) } +
            stride(from: 1, to: channelCount, by: 2).map { .stereo($0, $0 + 1) }
    }
}
enum RecordingAudioBitrate: Int, Codable, CaseIterable, Identifiable {
    case standard = 160, high = 256, highest = 320
    var id: Int { rawValue }
}
enum AudioSync {
    static func bounded(_ milliseconds: Int) -> Int { min(1000, max(-500, milliseconds)) }
    static func frames(_ milliseconds: Int) -> Int64 { Int64(bounded(milliseconds)) * 48 }
    static func playoutMilliseconds(_ configuration: StudioConfiguration) -> Int {
        // Enable/mute can change live, but the transport clock and video queue cannot.
        // Reserve every configured advance even for sources initially disabled.
        100 + max(-bounded(configuration.microphoneSyncOffsetMs),
                  -bounded(configuration.systemAudioSyncOffsetMs), 0)
    }
}
struct DeviceOption: Identifiable, Hashable {
    let id: String
    let name: String
    var inputChannels: Int = 0
    var bluetooth: Bool = false
    var isDefaultInput: Bool = false
}
struct CaptureSource: Identifiable, Hashable {
    enum Kind: String { case display, window }
    let id: UInt32
    let kind: Kind
    let name: String
    var stableID: String { "\(kind.rawValue):\(id)" }
}
enum BackgroundStyle: String, Codable, CaseIterable, Identifiable {
    case black, color, image, blur, mirror
    var id: String { rawValue }
    var title: String {
        switch self {
        case .black: "Black"
        case .color: "Color"
        case .image: "Image"
        case .blur: "Blurred desktop"
        case .mirror: "Mirrored wallpaper"
        }
    }
}
/// What the Away card sits on: flat, quiet surfaces only, so the message is the whole card.
enum AwayBackground: String, Codable, CaseIterable, Identifiable {
    case dark, color, image
    var id: String { rawValue }
    var title: String {
        switch self { case .dark: "Dark"; case .color: "Color"; case .image: "Image" }
    }
}
/// Every style is opaque: blur and pixellation keep recoverable detail, so neither is offered.
enum PrivacyCensorStyle: String, Codable, CaseIterable, Identifiable {
    case solid, rounded, striped
    var id: String { rawValue }
    var title: String {
        switch self {
        case .solid: "Solid bar"
        case .rounded: "Rounded bar"
        case .striped: "Striped"
        }
    }
}

struct ChatAppearance: Codable, Equatable {
    var fontSize = 24.0
    var userColors = true
    var timestamps = false
    var showHeader = true
    var showStatus = false
    var solidBackground = true
    var emotes = true
    var highlights = true

    enum Preset: String, CaseIterable, Identifiable {
        case terminal, compact, largeText, monochrome
        var id: String { rawValue }
        var title: String {
            switch self {
            case .terminal: "Standard"
            case .compact: "Compact"
            case .largeText: "Large text"
            case .monochrome: "Monochrome"
            }
        }
        var appearance: ChatAppearance {
            var value = ChatAppearance()
            switch self {
            case .terminal: break
            case .compact: value.fontSize = 20
            case .largeText: value.fontSize = 32
            case .monochrome:
                value.userColors = false
                value.emotes = false
                value.highlights = false
            }
            return value
        }
    }
    var preset: Preset? { Preset.allCases.first { $0.appearance == self } }

    init() {}
    private enum CodingKeys: String, CodingKey {
        case fontSize, userColors, timestamps, showHeader, showStatus, solidBackground, emotes, highlights
    }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = min(48, max(20, try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize))
        userColors = try values.decodeIfPresent(Bool.self, forKey: .userColors) ?? userColors
        timestamps = try values.decodeIfPresent(Bool.self, forKey: .timestamps) ?? timestamps
        showHeader = try values.decodeIfPresent(Bool.self, forKey: .showHeader) ?? showHeader
        showStatus = try values.decodeIfPresent(Bool.self, forKey: .showStatus) ?? showStatus
        solidBackground = try values.decodeIfPresent(Bool.self, forKey: .solidBackground) ?? solidBackground
        emotes = try values.decodeIfPresent(Bool.self, forKey: .emotes) ?? emotes
        highlights = try values.decodeIfPresent(Bool.self, forKey: .highlights) ?? highlights
    }
}

struct StudioConfiguration: Codable, Equatable {
    var layout: SceneLayout = .desktopChat
    var displayID: UInt32? = nil
    // Machine-local journal, never portable recording preferences.
    var dockFitRegion: DockCaptureRegion? = nil
    var includeMenuBar = true
    var backgroundStyle: BackgroundStyle = .black
    var backgroundRed = 0.08
    var backgroundGreen = 0.08
    var backgroundBlue = 0.08
    var backgroundBlurRadius = 30.0
    var backgroundImagePath = ""
    var windowID: UInt32? = nil
    var cameraEnabled = false
    var cameraID = ""
    var cameraAnchor: CameraAnchor = .bottomRight
    var cameraAvoidCursor = false
    var cameraSize = 0.25
    var cameraFrame: CameraFrame = .widescreen
    var cameraBorder: CameraBorder = .none
    var cameraBorderRed = 1.0
    var cameraBorderGreen = 1.0
    var cameraBorderBlue = 1.0
    var cameraPunchInSize = 0.5
    /// Session-only emphasis; intentionally excluded from Codable persistence.
    var cameraPunchIn = false
    var effectiveCameraSize: Double {
        let base = min(0.4, max(0.12, cameraSize))
        guard cameraPunchIn, layout == .desktopChat, cameraEnabled else { return base }
        return min(0.9, max(0.4, cameraPunchInSize))
    }
    var mirrorCamera = true
    var chatOnLeft = false
    var chatWidth = 384.0
    var chatEnabled = true
    /// Away scene: the full-frame card text, and whether the microphone goes silent while it is live.
    var awayMessage = "Be right back"
    /// Optional smaller line under the message; empty shows only the message.
    var awaySubtitle = ""
    var awayBackground: AwayBackground = .dark
    var awayRed = 0.11
    var awayGreen = 0.14
    var awayBlue = 0.22
    var awayImagePath = ""
    var awayMutesMicrophone = true
    /// Away was reached by turning the webcam off in Full Camera, not chosen: the microphone stays
    /// live. Turning the webcam back on never changes the scene. Not saved: a relaunch starts afresh,
    /// and Away then silences the room per its setting, showing so in the menu.
    var awayCoversWebcam = false
    /// The Away scene silences the room only when the user chose it.
    var awaySilencesMicrophone: Bool { layout == .away && awayMutesMicrophone && !awayCoversWebcam }
    // Empty follows the signed-in account; selecting chat never changes the broadcast target.
    var twitchChatChannel = ""
    var chatAppearance = ChatAppearance()
    var teleprompterMode: TeleprompterMode = .off
    var teleprompterInCapture = false
    var transcriptPath = ""
    var microphoneEnabled = false
    var microphoneID = ""
    var microphoneChannels: AudioChannelSelection = .deviceDefault
    var microphoneSyncOffsetMs = 0
    var microphoneGain = 1.0
    var microphoneMuted = false
    /// What the mixer applies: an explicit mute, or the Away scene silencing the room.
    var microphoneSilenced: Bool { microphoneMuted || awaySilencesMicrophone }
    /// This configuration with the webcam, desktop, and microphone hidden wherever `newer` hides them,
    /// so a privacy change queued behind a slower switch goes on air at once. Away hides the webcam
    /// and desktop, and silences the room unless it only covers a lost webcam. Anything shown or
    /// heard again waits for its own update to commit.
    func hiding(as newer: StudioConfiguration) -> StudioConfiguration {
        var masked = self
        if !newer.cameraEnabled { masked.cameraEnabled = false }
        if newer.layout == .away || (layout.showsDesktop && !newer.layout.showsDesktop) {
            masked.layout = newer.layout
            masked.awayCoversWebcam = newer.awayCoversWebcam; masked.awayMutesMicrophone = newer.awayMutesMicrophone
        }
        if (microphoneSilenced || newer.microphoneSilenced) && !masked.microphoneSilenced { masked.microphoneMuted = true }
        return masked
    }
    var microphoneCompressionEnabled = true
    // Optional AEC3 cleanup for the mic; the raw system-broadcast tap is never altered.
    var microphoneEchoCancellationEnabled = false
    // Optional hiss/fan reduction, independent of echo cancellation and compression.
    var microphoneNoiseReductionEnabled = false
    var systemAudioEnabled = true
    // Empty captures all other apps; a bundle ID isolates music from unrelated apps.
    var systemAudioApplicationID = ""
    var systemAudioGain = 1.0
    var systemAudioMuted = false
    var systemAudioDucking: AudioDucking = .off
    var systemAudioSyncOffsetMs = 0
    var recordingEnabled = true
    var recordingDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/StreamApp").path
    var recordingFormat: RecordingFormat = .mp4
    var recordingAudioBitrateKbps: RecordingAudioBitrate = .standard
    var streamingEnabled = false
    var streamService: StreamService = .twitch
    var streamURL = ""
    /// Sends to Twitch's ingest endpoint with `bandwidthtest=true`, which is
    /// not viewable as a live broadcast (Twitch Inspector measures the result).
    var twitchTestMode = false
    var excludedApplicationIDs: [String] = []
    var showStreamAppWindows = false
    // Window IDs are session-local; never persist these or match recycled IDs on relaunch.
    var excludedWindowIDs: [UInt32] = []
    // Output-time privacy buffering; these settings are locked for an active session.
    var privacyShieldEnabled = false
    var privacyHidesPersonalInfo = true
    var privacyCensorStyle: PrivacyCensorStyle = .solid
    var privacyCensorRed = 0.06
    var privacyCensorGreen = 0.06
    var privacyCensorBlue = 0.06

    var outputMode: OutputMode {
        get { streamingEnabled ? (recordingEnabled ? .both : .stream) : .record }
        set {
            recordingEnabled = newValue != .stream
            streamingEnabled = newValue != .record
        }
    }
    var outputSummary: String {
        if streamingEnabled && twitchTestMode {
            return recordingEnabled ? "Test stream + local recording · Not public" : "Test stream only · Not public"
        }
        switch outputMode {
        case .record: return "Local recording only · Nothing sent online"
        case .stream: return "Stream only · No local recording"
        case .both: return "Stream + local recording"
        }
    }

    init() {}
    private enum CodingKeys: String, CodingKey {
        case layout, displayID, windowID, cameraEnabled, cameraID, cameraAnchor, cameraAvoidCursor, cameraSize, mirrorCamera, chatOnLeft, chatWidth, chatEnabled, twitchChatChannel, microphoneEnabled, microphoneID, microphoneGain, microphoneMuted, microphoneCompressionEnabled, microphoneEchoCancellationEnabled, microphoneNoiseReductionEnabled, systemAudioEnabled, systemAudioGain, systemAudioMuted, recordingEnabled, recordingDirectory, streamingEnabled, streamService, streamURL, twitchTestMode, excludedApplicationIDs
        case cameraFrame, cameraPunchInSize
        case cameraBorder, cameraBorderRed, cameraBorderGreen, cameraBorderBlue
        case awayMessage, awayMutesMicrophone, awaySubtitle, awayBackground, awayRed, awayGreen, awayBlue, awayImagePath
        case showStreamAppWindows
        case chatAppearance
        case teleprompterMode, teleprompterInCapture, transcriptPath
        case systemAudioApplicationID, systemAudioDucking
        case recordingFormat
        case microphoneChannels, microphoneSyncOffsetMs, systemAudioSyncOffsetMs, recordingAudioBitrateKbps
        case includeMenuBar
        case backgroundStyle, backgroundRed, backgroundGreen, backgroundBlue, backgroundBlurRadius, backgroundImagePath
        case privacyShieldEnabled, privacyHidesPersonalInfo
        case privacyCensorStyle, privacyCensorRed, privacyCensorGreen, privacyCensorBlue
    }
    private enum LegacyKeys: String, CodingKey { case cameraCorner }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown scene (settings from a newer build) falls back rather than discarding every setting.
        layout = (try? values.decodeIfPresent(SceneLayout.self, forKey: .layout)) ?? layout
        displayID = try values.decodeIfPresent(UInt32.self, forKey: .displayID)
        includeMenuBar = try values.decodeIfPresent(Bool.self, forKey: .includeMenuBar) ?? includeMenuBar
        backgroundStyle = try values.decodeIfPresent(BackgroundStyle.self, forKey: .backgroundStyle) ?? backgroundStyle
        backgroundRed = min(1, max(0, try values.decodeIfPresent(Double.self, forKey: .backgroundRed) ?? backgroundRed))
        backgroundGreen = min(1, max(0, try values.decodeIfPresent(Double.self, forKey: .backgroundGreen) ?? backgroundGreen))
        backgroundBlue = min(1, max(0, try values.decodeIfPresent(Double.self, forKey: .backgroundBlue) ?? backgroundBlue))
        backgroundBlurRadius = min(80, max(0, try values.decodeIfPresent(Double.self, forKey: .backgroundBlurRadius) ?? backgroundBlurRadius))
        backgroundImagePath = try values.decodeIfPresent(String.self, forKey: .backgroundImagePath) ?? backgroundImagePath
        windowID = try values.decodeIfPresent(UInt32.self, forKey: .windowID)
        cameraEnabled = try values.decodeIfPresent(Bool.self, forKey: .cameraEnabled) ?? cameraEnabled
        cameraID = try values.decodeIfPresent(String.self, forKey: .cameraID) ?? cameraID
        if values.contains(.cameraAnchor) {
            cameraAnchor = (try? values.decode(CameraAnchor.self, forKey: .cameraAnchor)) ?? .bottomRight
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            cameraAnchor = CameraAnchor.legacy(try? legacy.decode(String.self, forKey: .cameraCorner))
        }
        cameraAvoidCursor = (try? values.decodeIfPresent(Bool.self, forKey: .cameraAvoidCursor)) ?? false
        cameraSize = try values.decodeIfPresent(Double.self, forKey: .cameraSize) ?? cameraSize
        cameraPunchInSize = min(0.9, max(0.4, try values.decodeIfPresent(Double.self, forKey: .cameraPunchInSize) ?? cameraPunchInSize))
        cameraFrame = try values.decodeIfPresent(CameraFrame.self, forKey: .cameraFrame) ?? cameraFrame
        cameraBorder = (try? values.decodeIfPresent(CameraBorder.self, forKey: .cameraBorder)) ?? cameraBorder
        cameraBorderRed = min(1, max(0, try values.decodeIfPresent(Double.self, forKey: .cameraBorderRed) ?? cameraBorderRed))
        cameraBorderGreen = min(1, max(0, try values.decodeIfPresent(Double.self, forKey: .cameraBorderGreen) ?? cameraBorderGreen))
        cameraBorderBlue = min(1, max(0, try values.decodeIfPresent(Double.self, forKey: .cameraBorderBlue) ?? cameraBorderBlue))
        mirrorCamera = try values.decodeIfPresent(Bool.self, forKey: .mirrorCamera) ?? mirrorCamera
        chatOnLeft = try values.decodeIfPresent(Bool.self, forKey: .chatOnLeft) ?? chatOnLeft
        chatWidth = try values.decodeIfPresent(Double.self, forKey: .chatWidth) ?? chatWidth
        chatEnabled = try values.decodeIfPresent(Bool.self, forKey: .chatEnabled) ?? chatEnabled
        awayMessage = try values.decodeIfPresent(String.self, forKey: .awayMessage) ?? awayMessage
        awaySubtitle = try values.decodeIfPresent(String.self, forKey: .awaySubtitle) ?? awaySubtitle
        if values.contains(.awayBackground) {
            awayBackground = (try? values.decode(AwayBackground.self, forKey: .awayBackground)) ?? awayBackground
            awayRed = min(1, max(0, try values.decodeIfPresent(Double.self, forKey: .awayRed) ?? awayRed))
            awayGreen = min(1, max(0, try values.decodeIfPresent(Double.self, forKey: .awayGreen) ?? awayGreen))
            awayBlue = min(1, max(0, try values.decodeIfPresent(Double.self, forKey: .awayBlue) ?? awayBlue))
            awayImagePath = try values.decodeIfPresent(String.self, forKey: .awayImagePath) ?? awayImagePath
        } else if backgroundStyle == .image, !backgroundImagePath.isEmpty {
            // Older builds drew the Away card on the scene background; keep the look they chose.
            awayBackground = .image; awayImagePath = backgroundImagePath
        } else if backgroundStyle == .color {
            awayBackground = .color; awayRed = backgroundRed; awayGreen = backgroundGreen; awayBlue = backgroundBlue
        }
        awayMutesMicrophone = try values.decodeIfPresent(Bool.self, forKey: .awayMutesMicrophone) ?? awayMutesMicrophone
        twitchChatChannel = try values.decodeIfPresent(String.self, forKey: .twitchChatChannel) ?? twitchChatChannel
        chatAppearance = try values.decodeIfPresent(ChatAppearance.self, forKey: .chatAppearance) ?? chatAppearance
        teleprompterMode = try values.decodeIfPresent(TeleprompterMode.self, forKey: .teleprompterMode) ?? teleprompterMode
        teleprompterInCapture = try values.decodeIfPresent(Bool.self, forKey: .teleprompterInCapture) ?? teleprompterInCapture
        transcriptPath = try values.decodeIfPresent(String.self, forKey: .transcriptPath) ?? transcriptPath
        microphoneEnabled = try values.decodeIfPresent(Bool.self, forKey: .microphoneEnabled) ?? microphoneEnabled
        microphoneID = try values.decodeIfPresent(String.self, forKey: .microphoneID) ?? microphoneID
        microphoneChannels = (try? values.decodeIfPresent(AudioChannelSelection.self, forKey: .microphoneChannels)) ?? .deviceDefault
        microphoneSyncOffsetMs = AudioSync.bounded(try values.decodeIfPresent(Int.self, forKey: .microphoneSyncOffsetMs) ?? 0)
        systemAudioSyncOffsetMs = AudioSync.bounded(try values.decodeIfPresent(Int.self, forKey: .systemAudioSyncOffsetMs) ?? 0)
        recordingAudioBitrateKbps = (try? values.decodeIfPresent(RecordingAudioBitrate.self, forKey: .recordingAudioBitrateKbps)) ?? .standard
        microphoneGain = try values.decodeIfPresent(Double.self, forKey: .microphoneGain) ?? microphoneGain
        microphoneMuted = try values.decodeIfPresent(Bool.self, forKey: .microphoneMuted) ?? microphoneMuted
        microphoneCompressionEnabled = try values.decodeIfPresent(Bool.self, forKey: .microphoneCompressionEnabled) ?? microphoneCompressionEnabled
        microphoneEchoCancellationEnabled = try values.decodeIfPresent(Bool.self, forKey: .microphoneEchoCancellationEnabled) ?? microphoneEchoCancellationEnabled
        microphoneNoiseReductionEnabled = try values.decodeIfPresent(Bool.self, forKey: .microphoneNoiseReductionEnabled) ?? microphoneNoiseReductionEnabled
        systemAudioApplicationID = try values.decodeIfPresent(String.self, forKey: .systemAudioApplicationID) ?? systemAudioApplicationID
        // Older audio followed visual exclusions/window selection. Require explicit
        // re-enabling rather than silently expanding that scope to all applications.
        let audioEnabled = try values.decodeIfPresent(Bool.self, forKey: .systemAudioEnabled) ?? systemAudioEnabled
        systemAudioEnabled = values.contains(.systemAudioApplicationID) && audioEnabled
        systemAudioGain = try values.decodeIfPresent(Double.self, forKey: .systemAudioGain) ?? systemAudioGain
        systemAudioMuted = try values.decodeIfPresent(Bool.self, forKey: .systemAudioMuted) ?? systemAudioMuted
        systemAudioDucking = (try? values.decodeIfPresent(AudioDucking.self, forKey: .systemAudioDucking)) ?? systemAudioDucking
        recordingEnabled = try values.decodeIfPresent(Bool.self, forKey: .recordingEnabled) ?? recordingEnabled
        recordingDirectory = try values.decodeIfPresent(String.self, forKey: .recordingDirectory) ?? recordingDirectory
        // An unknown format (settings from a newer build) falls back rather than discarding every setting.
        recordingFormat = (try? values.decodeIfPresent(RecordingFormat.self, forKey: .recordingFormat)) ?? recordingFormat
        streamingEnabled = try values.decodeIfPresent(Bool.self, forKey: .streamingEnabled) ?? streamingEnabled
        streamService = try values.decodeIfPresent(StreamService.self, forKey: .streamService) ?? .twitch
        if !recordingEnabled && !streamingEnabled { recordingEnabled = true }
        streamURL = try values.decodeIfPresent(String.self, forKey: .streamURL) ?? streamURL
        twitchTestMode = try values.decodeIfPresent(Bool.self, forKey: .twitchTestMode) ?? twitchTestMode
        excludedApplicationIDs = try values.decodeIfPresent([String].self, forKey: .excludedApplicationIDs) ?? excludedApplicationIDs
        showStreamAppWindows = try values.decodeIfPresent(Bool.self, forKey: .showStreamAppWindows) ?? showStreamAppWindows
        privacyShieldEnabled = try values.decodeIfPresent(Bool.self, forKey: .privacyShieldEnabled) ?? privacyShieldEnabled
        privacyHidesPersonalInfo = try values.decodeIfPresent(Bool.self, forKey: .privacyHidesPersonalInfo) ?? privacyHidesPersonalInfo
        privacyCensorStyle = (try? values.decodeIfPresent(PrivacyCensorStyle.self, forKey: .privacyCensorStyle)) ?? privacyCensorStyle
        privacyCensorRed = min(1, max(0, try values.decodeIfPresent(Double.self, forKey: .privacyCensorRed) ?? privacyCensorRed))
        privacyCensorGreen = min(1, max(0, try values.decodeIfPresent(Double.self, forKey: .privacyCensorGreen) ?? privacyCensorGreen))
        privacyCensorBlue = min(1, max(0, try values.decodeIfPresent(Double.self, forKey: .privacyCensorBlue) ?? privacyCensorBlue))
        if layout.usesCamera && !cameraEnabled { layout = layout.withoutCamera }
    }
}
