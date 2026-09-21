import Foundation
import Testing
@testable import StreamApp

@MainActor
struct TwitchTestModeTests {
    @Test func testModeDisablesLiveViewingWithoutChangingSavedKey() throws {
        var configuration = StudioConfiguration()
        configuration.streamingEnabled = true
        configuration.streamURL = "rtmps://ingest.global-contribute.live-video.net/app"
        let key = "example-not-a-real-key"
        configuration.twitchTestMode = true
        let target = try MediaOutput.makeStreamTarget(configuration: configuration, streamKey: key)
        let url = try #require(URLComponents(string: target))
        #expect(url.path == "/app/" + key)
        #expect(url.queryItems == [URLQueryItem(name: "bandwidthtest", value: "true")])
        configuration.twitchTestMode = false
        let live = try MediaOutput.makeStreamTarget(configuration: configuration, streamKey: key)
        #expect(URLComponents(string: live)?.query == nil)
    }

    @Test func testModeRejectsNonTwitchTargetsAndOverrideQueries() {
        var configuration = StudioConfiguration()
        configuration.streamingEnabled = true
        configuration.twitchTestMode = true
        configuration.streamURL = "rtmps://ingest.contribute.live-video.net.example.com/app"
        #expect(throws: Error.self) { try MediaOutput.makeStreamTarget(configuration: configuration, streamKey: "example") }
        configuration.streamURL = "rtmps://ingest.global-contribute.live-video.net/app"
        #expect(throws: Error.self) { try MediaOutput.makeStreamTarget(configuration: configuration, streamKey: "example?bandwidthtest=false") }
    }

    @Test func missingServiceUsesTwitchButExplicitCustomChoiceSurvives() throws {
        let legacy = try JSONDecoder().decode(StudioConfiguration.self, from: Data(#"{"streamURL":"rtmps://example.com/app"}"#.utf8))
        #expect(legacy.streamService == .twitch)
        var custom = legacy
        custom.streamService = .custom
        let restored = try JSONDecoder().decode(StudioConfiguration.self, from: JSONEncoder().encode(custom))
        #expect(restored.streamService == .custom)
        #expect(restored.streamURL == "rtmps://example.com/app")
    }

    @Test func switchingServiceClearsPreviousValidationFailure() {
        let model = StudioModel(demo: true)
        model.configuration.streamingEnabled = true
        model.configuration.streamService = .custom
        model.configuration.streamURL = "rtmps://example.com/app"
        #expect(!model.validateStreamSetup())
        #expect(model.message != nil)
        model.configuration.streamService = .twitch
        #expect(model.message == nil)
        #expect(!model.validateStreamSetup())
        model.configuration.streamService = .custom
        #expect(model.message == nil)
        #expect(!model.validateStreamSetup())
    }
}
