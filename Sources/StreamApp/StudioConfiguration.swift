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
struct DeviceOption: Identifiable, Hashable { let id: String; let name: String }
struct CaptureSource: Identifiable, Hashable {
    enum Kind: String { case display, window }
    let id: UInt32
    let kind: Kind
    let name: String
    var stableID: String { "\(kind.rawValue):\(id)" }
}
struct StudioConfiguration: Codable, Equatable {
    var layout: SceneLayout = .desktopChat
    var displayID: UInt32? = nil
    // Machine-local journal, never portable recording preferences.
    var dockFitDisplayID: UInt32? = nil
    var windowID: UInt32? = nil
    var cameraEnabled = false
    var cameraID = ""
    var cameraCorner: CameraCorner = .bottomRight
    var cameraSize = 0.22
    var mirrorCamera = true
    var chatOnLeft = false
    var chatWidth = 384.0
    var chatEnabled = true
    var chatURL = "http://127.0.0.1:8080/events"
    var microphoneEnabled = false
    var microphoneID = ""
    var microphoneGain = 1.0
    var microphoneMuted = false
    var microphoneCompressionEnabled = true
    var systemAudioEnabled = false
    var systemAudioGain = 1.0
    var systemAudioMuted = false
    var recordingEnabled = true
    var recordingDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/StreamApp").path
    var streamingEnabled = false
    var streamURL = ""
    /// Sends to Twitch's ingest endpoint with `bandwidthtest=true`, which is
    /// not viewable as a live broadcast (Twitch Inspector measures the result).
    var twitchTestMode = false
    var excludedApplicationIDs: [String] = []
    // Window IDs are session-local; never persist these or match recycled IDs on relaunch.
    var excludedWindowIDs: [UInt32] = []

    init() {}
    private enum CodingKeys: String, CodingKey {
        case layout, displayID, windowID, cameraEnabled, cameraID, cameraCorner, cameraSize, mirrorCamera, chatOnLeft, chatWidth, chatEnabled, chatURL, microphoneEnabled, microphoneID, microphoneGain, microphoneMuted, microphoneCompressionEnabled, systemAudioEnabled, systemAudioGain, systemAudioMuted, recordingEnabled, recordingDirectory, streamingEnabled, streamURL, twitchTestMode, excludedApplicationIDs
    }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        layout = try values.decodeIfPresent(SceneLayout.self, forKey: .layout) ?? layout
        displayID = try values.decodeIfPresent(UInt32.self, forKey: .displayID)
        windowID = try values.decodeIfPresent(UInt32.self, forKey: .windowID)
        cameraEnabled = try values.decodeIfPresent(Bool.self, forKey: .cameraEnabled) ?? cameraEnabled
        cameraID = try values.decodeIfPresent(String.self, forKey: .cameraID) ?? cameraID
        cameraCorner = try values.decodeIfPresent(CameraCorner.self, forKey: .cameraCorner) ?? cameraCorner
        cameraSize = try values.decodeIfPresent(Double.self, forKey: .cameraSize) ?? cameraSize
        mirrorCamera = try values.decodeIfPresent(Bool.self, forKey: .mirrorCamera) ?? mirrorCamera
        chatOnLeft = try values.decodeIfPresent(Bool.self, forKey: .chatOnLeft) ?? chatOnLeft
        chatWidth = try values.decodeIfPresent(Double.self, forKey: .chatWidth) ?? chatWidth
        chatEnabled = try values.decodeIfPresent(Bool.self, forKey: .chatEnabled) ?? chatEnabled
        chatURL = try values.decodeIfPresent(String.self, forKey: .chatURL) ?? chatURL
        microphoneEnabled = try values.decodeIfPresent(Bool.self, forKey: .microphoneEnabled) ?? microphoneEnabled
        microphoneID = try values.decodeIfPresent(String.self, forKey: .microphoneID) ?? microphoneID
        microphoneGain = try values.decodeIfPresent(Double.self, forKey: .microphoneGain) ?? microphoneGain
        microphoneMuted = try values.decodeIfPresent(Bool.self, forKey: .microphoneMuted) ?? microphoneMuted
        microphoneCompressionEnabled = try values.decodeIfPresent(Bool.self, forKey: .microphoneCompressionEnabled) ?? microphoneCompressionEnabled
        systemAudioEnabled = try values.decodeIfPresent(Bool.self, forKey: .systemAudioEnabled) ?? systemAudioEnabled
        systemAudioGain = try values.decodeIfPresent(Double.self, forKey: .systemAudioGain) ?? systemAudioGain
        systemAudioMuted = try values.decodeIfPresent(Bool.self, forKey: .systemAudioMuted) ?? systemAudioMuted
        recordingEnabled = try values.decodeIfPresent(Bool.self, forKey: .recordingEnabled) ?? recordingEnabled
        recordingDirectory = try values.decodeIfPresent(String.self, forKey: .recordingDirectory) ?? recordingDirectory
        streamingEnabled = try values.decodeIfPresent(Bool.self, forKey: .streamingEnabled) ?? streamingEnabled
        streamURL = try values.decodeIfPresent(String.self, forKey: .streamURL) ?? streamURL
        twitchTestMode = try values.decodeIfPresent(Bool.self, forKey: .twitchTestMode) ?? twitchTestMode
        excludedApplicationIDs = try values.decodeIfPresent([String].self, forKey: .excludedApplicationIDs) ?? excludedApplicationIDs
    }
}
