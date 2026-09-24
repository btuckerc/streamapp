import Foundation
import CoreGraphics

// Shared value contract for the menu, capture engine, and output worker.
enum SceneLayout: String, Codable, CaseIterable, Identifiable {
    case desktopChat, justChatting
    var id: String { rawValue }
    var title: String { self == .desktopChat ? "Desktop" : "Full Camera" }
}
enum CameraCorner: String, Codable, CaseIterable, Identifiable {
    case bottomRight, bottomLeft, topRight, topLeft
    var id: String { rawValue }
    var title: String { switch self { case .bottomRight: "Bottom right"; case .bottomLeft: "Bottom left"; case .topRight: "Top right"; case .topLeft: "Top left" } }
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
    var title: String { self == .twitch ? "Twitch account" : "Custom RTMP" }
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
struct DeviceOption: Identifiable, Hashable { let id: String; let name: String }
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
            case .terminal: "Terminal"
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
    var cameraCorner: CameraCorner = .bottomRight
    var cameraSize = 0.25
    var cameraFrame: CameraFrame = .widescreen
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
    // Empty follows the signed-in account; selecting chat never changes the broadcast target.
    var twitchChatChannel = ""
    var chatAppearance = ChatAppearance()
    var teleprompterMode: TeleprompterMode = .off
    var teleprompterInCapture = false
    var transcriptPath = ""
    var microphoneEnabled = false
    var microphoneID = ""
    var microphoneGain = 1.0
    var microphoneMuted = false
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
    var recordingEnabled = true
    var recordingDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/StreamApp").path
    var recordingFormat: RecordingFormat = .mp4
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

    var outputMode: OutputMode {
        get { streamingEnabled ? (recordingEnabled ? .both : .stream) : .record }
        set {
            recordingEnabled = newValue != .stream
            streamingEnabled = newValue != .record
        }
    }
    var outputSummary: String {
        if streamingEnabled && twitchTestMode {
            return recordingEnabled ? "Twitch test + local recording · Not live" : "Twitch test only · Not live"
        }
        switch outputMode {
        case .record: return "Local recording only · Nothing sent online"
        case .stream: return "Stream only · No local recording"
        case .both: return "Stream + local recording"
        }
    }

    init() {}
    private enum CodingKeys: String, CodingKey {
        case layout, displayID, windowID, cameraEnabled, cameraID, cameraCorner, cameraSize, mirrorCamera, chatOnLeft, chatWidth, chatEnabled, twitchChatChannel, microphoneEnabled, microphoneID, microphoneGain, microphoneMuted, microphoneCompressionEnabled, microphoneEchoCancellationEnabled, microphoneNoiseReductionEnabled, systemAudioEnabled, systemAudioGain, systemAudioMuted, recordingEnabled, recordingDirectory, streamingEnabled, streamService, streamURL, twitchTestMode, excludedApplicationIDs
        case cameraFrame, cameraPunchInSize
        case showStreamAppWindows
        case chatAppearance
        case teleprompterMode, teleprompterInCapture, transcriptPath
        case systemAudioApplicationID
        case recordingFormat
        case includeMenuBar
        case backgroundStyle, backgroundRed, backgroundGreen, backgroundBlue, backgroundBlurRadius, backgroundImagePath
    }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        layout = try values.decodeIfPresent(SceneLayout.self, forKey: .layout) ?? layout
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
        cameraCorner = try values.decodeIfPresent(CameraCorner.self, forKey: .cameraCorner) ?? cameraCorner
        cameraSize = try values.decodeIfPresent(Double.self, forKey: .cameraSize) ?? cameraSize
        cameraPunchInSize = min(0.9, max(0.4, try values.decodeIfPresent(Double.self, forKey: .cameraPunchInSize) ?? cameraPunchInSize))
        cameraFrame = try values.decodeIfPresent(CameraFrame.self, forKey: .cameraFrame) ?? cameraFrame
        mirrorCamera = try values.decodeIfPresent(Bool.self, forKey: .mirrorCamera) ?? mirrorCamera
        chatOnLeft = try values.decodeIfPresent(Bool.self, forKey: .chatOnLeft) ?? chatOnLeft
        chatWidth = try values.decodeIfPresent(Double.self, forKey: .chatWidth) ?? chatWidth
        chatEnabled = try values.decodeIfPresent(Bool.self, forKey: .chatEnabled) ?? chatEnabled
        twitchChatChannel = try values.decodeIfPresent(String.self, forKey: .twitchChatChannel) ?? twitchChatChannel
        chatAppearance = try values.decodeIfPresent(ChatAppearance.self, forKey: .chatAppearance) ?? chatAppearance
        teleprompterMode = try values.decodeIfPresent(TeleprompterMode.self, forKey: .teleprompterMode) ?? teleprompterMode
        teleprompterInCapture = try values.decodeIfPresent(Bool.self, forKey: .teleprompterInCapture) ?? teleprompterInCapture
        transcriptPath = try values.decodeIfPresent(String.self, forKey: .transcriptPath) ?? transcriptPath
        microphoneEnabled = try values.decodeIfPresent(Bool.self, forKey: .microphoneEnabled) ?? microphoneEnabled
        microphoneID = try values.decodeIfPresent(String.self, forKey: .microphoneID) ?? microphoneID
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
    }
}
