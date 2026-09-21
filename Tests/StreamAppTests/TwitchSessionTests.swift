import Foundation
import Testing
@testable import StreamApp

private final class TwitchHTTPFixture: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handle: ((URLRequest) -> (Int, [String: Any]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, object) = Self.handle!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) @MainActor
struct TwitchSessionTests {
    private func session() -> TwitchSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TwitchHTTPFixture.self]
        return TwitchSession(persist: false, urlSession: URLSession(configuration: config), openURL: { _ in })
    }
    private func waitForConnection(_ session: TwitchSession) async throws {
        for _ in 0..<100 {
            if !session.connecting { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Connection did not settle")
    }
    private static let scopes = ["user:read:chat", "channel:read:stream_key"]
    private static func response(_ request: URLRequest, wrongClient: Bool = false) -> (Int, [String: Any]) {
        switch request.url!.path {
        case "/oauth2/device":
            return (200, ["device_code": "secret-device", "user_code": "PUBLIC", "verification_uri": "https://www.twitch.tv/activate", "expires_in": 60, "interval": 1])
        case "/oauth2/token":
            return (200, ["access_token": "access", "refresh_token": "refresh", "scope": scopes])
        case "/oauth2/validate":
            return (200, ["client_id": wrongClient ? "another-client" : TwitchSession.clientID, "user_id": "123", "login": "viewer", "scopes": scopes])
        default: return (200, [:])
        }
    }

    @Test func rejectsTokensIssuedToAnotherClient() async throws {
        TwitchHTTPFixture.handle = { Self.response($0, wrongClient: true) }
        let auth = session()
        auth.connect()
        try await waitForConnection(auth)
        #expect(auth.account == nil)
        #expect(auth.deviceAuthorization == nil)
        await #expect(throws: TwitchSessionError.self) { try await auth.streamKey() }
    }

    @Test func cancelCannotPublishDelayedAuthorization() async throws {
        TwitchHTTPFixture.handle = { Self.response($0) }
        let auth = session()
        auth.connect()
        for _ in 0..<100 {
            if auth.deviceAuthorization != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(auth.deviceAuthorization != nil)
        auth.cancelConnect()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(auth.account == nil)
        #expect(!auth.connecting)
        #expect(auth.deviceAuthorization == nil)
    }

    @Test func concurrentUnauthorizedRequestsRotateOnceAndUseAccountKey() async throws {
        let lock = NSLock()
        nonisolated(unsafe) var rotations = 0
        TwitchHTTPFixture.handle = { request in
            if request.url!.path == "/helix/streams/key" {
                #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "broadcaster_id", value: "123")])
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer access" { return (401, [:]) }
                return (200, ["data": [["stream_key": "fixture-key"]]])
            }
            if request.url!.path == "/oauth2/token" {
                // URLProtocol may expose the POST body as a stream rather than Data.
                var body = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var bytes = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&bytes, maxLength: bytes.count)
                        if count <= 0 { break }
                        body.append(contentsOf: bytes.prefix(count))
                    }
                }
                let form = String(decoding: body, as: UTF8.self)
                #expect(!form.contains("PUBLIC"))
                if form.contains("grant_type=refresh_token") {
                    lock.lock(); rotations += 1; lock.unlock()
                    return (200, ["access_token": "replacement", "refresh_token": "rotated", "scope": Self.scopes])
                }
                #expect(form.contains("device_code=secret-device"))
            }
            return Self.response(request)
        }
        let auth = session()
        auth.connect()
        try await waitForConnection(auth)
        #expect(auth.account?.id == "123")
        async let first = auth.streamKey()
        async let second = auth.streamKey()
        let keys = try await [first, second]
        #expect(keys == ["fixture-key", "fixture-key"])
        #expect(rotations == 1)
        await auth.disconnect()
        #expect(auth.account == nil)
    }

    @Test func channelInputAcceptsSharedLinksButRejectsOtherSitesAndVideoPages() {
        #expect(TwitchChatFeed.normalize(" @Shroud ") == "shroud")
        #expect(TwitchChatFeed.normalize("https://www.twitch.tv/Shroud/?referrer=share") == "shroud")
        #expect(TwitchChatFeed.normalize("twitch.tv/shroud") == "shroud")
        #expect(TwitchChatFeed.normalize("https://twitch.tv.example.com/shroud") == nil)
        #expect(TwitchChatFeed.normalize("https://twitch.tv/videos/123") == nil)
        #expect(TwitchChatFeed.normalize("https://example.com@twitch.tv/shroud") == nil)
        #expect(TwitchChatFeed.normalize("A Display Name") == nil)
    }
}
