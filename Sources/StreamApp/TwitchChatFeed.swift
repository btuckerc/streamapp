import Foundation
import Combine

@MainActor
final class TwitchChatFeed {
    enum Event {
        case channel(String, id: String? = nil), message(TwitchChatMessage), deleteMessage(String), clearUser(String), clear
    }
    struct TwitchChatMessage {
        struct Fragment {
            let text: String
            let emoteID: String?
            let mention: Bool
        }
        let id: String
        let userID: String
        let login: String
        let displayName: String
        let color: String?
        let text: String
        let sourceChannel: String?
        let timestamp: String?
        let fragments: [Fragment]
    }
    private struct Connection {
        let socket: URLSessionWebSocketTask
        let id: String
        let timeout: TimeInterval
    }
    private enum FeedError: Error { case invalidMessage, revoked, invalidChannel }
    private let session: TwitchSession
    private let channel: String
    private let onEvent: (Event) -> Void
    private let onStatus: (String) -> Void
    private let network = URLSession(configuration: .ephemeral)
    private var accountSubscription: AnyCancellable?
    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var pendingSocket: URLSessionWebSocketTask?
    private var generation: UInt64 = 0
    private var seen = Set<String>()
    private var seenOrder: [String] = []
    private var seenCursor = 0
    private static let endpoint = URL(string: "wss://eventsub.wss.twitch.tv/ws")!
    private static let eventTypes = ["channel.chat.message", "channel.chat.message_delete", "channel.chat.clear_user_messages", "channel.chat.clear"]

    init(session: TwitchSession, channel: String, onEvent: @escaping (Event) -> Void, onStatus: @escaping (String) -> Void) {
        self.session = session
        self.channel = channel
        self.onEvent = onEvent
        self.onStatus = onStatus
    }

    deinit { network.invalidateAndCancel() }

    func start() {
        stop()
        accountSubscription = session.$account.removeDuplicates().sink { [weak self] account in
            self?.restart(account: account)
        }
    }

    func stop() {
        accountSubscription = nil
        cancelConnection()
    }

    private func cancelConnection() {
        generation &+= 1
        task?.cancel(); task = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        pendingSocket?.cancel(with: .goingAway, reason: nil); pendingSocket = nil
    }

    private func restart(account: TwitchAccount?) {
        cancelConnection()
        seen.removeAll(keepingCapacity: true); seenOrder.removeAll(keepingCapacity: true); seenCursor = 0
        onEvent(.clear)
        guard let account else {
            onEvent(.channel("chat")); onStatus("SIGN IN TO VIEW CHAT"); return
        }
        let input = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = Self.normalize(input.isEmpty ? account.login : input) else {
            onStatus("ERROR · INVALID CHANNEL"); return
        }
        onEvent(.channel(name))
        let g = generation
        task = Task { [weak self] in await self?.run(name: name, account: account, generation: g) }
    }

    private func run(name: String, account: TwitchAccount, generation g: UInt64) async {
        var delay: TimeInterval = 1
        while isCurrent(g) {
            var connection: Connection?
            do {
                onStatus("CONNECTING · #\(name)")
                let broadcaster = name == account.login ? account : try await session.user(login: name)
                try check(g)
                onEvent(.channel(name, id: broadcaster.id))
                let opened = try await open(Self.endpoint, generation: g)
                connection = opened
                onStatus("SUBSCRIBING · #\(name)")
                for type in Self.eventTypes {
                    try check(g)
                    let body: [String: Any] = ["type": type, "version": "1", "condition": ["broadcaster_user_id": broadcaster.id, "user_id": account.id], "transport": ["method": "websocket", "session_id": opened.id]]
                    _ = try await session.request(path: "/eventsub/subscriptions", method: "POST", body: JSONSerialization.data(withJSONObject: body))
                }
                try check(g)
                onStatus("LISTENING · #\(name) · WAITING FOR MESSAGES")
                var received = 0
                while let current = connection, isCurrent(g) {
                    let envelope = try await receive(current.socket, timeout: current.timeout)
                    try check(g)
                    let kind = (envelope["metadata"] as? [String: Any])?["message_type"] as? String
                    if kind == "session_reconnect" {
                        guard let payload = envelope["payload"] as? [String: Any], let info = payload["session"] as? [String: Any],
                              let value = info["reconnect_url"] as? String, let url = URL(string: value), Self.isSafeEndpoint(url) else { throw FeedError.invalidMessage }
                        onStatus("RECONNECTING · #\(name)")
                        connection = try await handoff(from: current, to: url, generation: g)
                        try check(g)
                        onStatus("LISTENING · #\(name)")
                    } else {
                        let delivered = try process(envelope)
                        if delivered {
                            received += 1
                            onStatus("LISTENING · #\(name) · \(received) RECEIVED")
                        }
                    }
                    delay = 1
                }
            } catch {
                connection?.socket.cancel(with: .goingAway, reason: nil)
                guard isCurrent(g) else { return }
                socket?.cancel(with: .goingAway, reason: nil); socket = nil
                pendingSocket?.cancel(with: .goingAway, reason: nil); pendingSocket = nil
                // A gap can hide moderation events. Never retain potentially deleted text across it.
                onEvent(.clear)
                if error is FeedError || isTerminal(error) {
                    onStatus(error is FeedError ? "CHAT SUBSCRIPTION ENDED · REOPEN TEST OR PREVIEW" : error.localizedDescription)
                    return
                }
                onStatus("DISCONNECTED · RETRYING IN \(Int(delay))s")
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                delay = min(delay * 2, 30)
            }
        }
    }

    private func open(_ endpoint: URL, generation g: UInt64, handoff: Bool = false, fallbackTimeout: TimeInterval = 10) async throws -> Connection {
        guard Self.isSafeEndpoint(endpoint) else { throw FeedError.invalidMessage }
        try check(g)
        let ws = network.webSocketTask(with: endpoint)
        ws.maximumMessageSize = 262_144
        if handoff { pendingSocket = ws } else { socket = ws }
        ws.resume()
        do {
            let welcome = try await receive(ws, timeout: 15)
            try check(g)
            guard let metadata = welcome["metadata"] as? [String: Any], metadata["message_type"] as? String == "session_welcome",
                  let payload = welcome["payload"] as? [String: Any], let info = payload["session"] as? [String: Any],
                  let id = info["id"] as? String, !id.isEmpty else { throw FeedError.invalidMessage }
            let timeout = (info["keepalive_timeout_seconds"] as? Double) ?? fallbackTimeout
            guard timeout >= 1, timeout <= 600 else { throw FeedError.invalidMessage }
            return Connection(socket: ws, id: id, timeout: timeout)
        } catch {
            ws.cancel(with: .goingAway, reason: nil)
            throw error
        }
    }

    private func handoff(from old: Connection, to endpoint: URL, generation g: UInt64) async throws -> Connection {
        // Continue consuming the old connection until the replacement sends Welcome.
        let drain = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.isCurrent(g) {
                let envelope = try await self.receive(old.socket, timeout: old.timeout)
                try self.check(g)
                _ = try self.process(envelope)
            }
        }
        do {
            let next = try await open(endpoint, generation: g, handoff: true, fallbackTimeout: old.timeout)
            try check(g)
            old.socket.cancel(with: .goingAway, reason: nil)
            drain.cancel()
            do { try await drain.value }
            catch let error as FeedError { throw error }
            catch { onEvent(.clear) }
            socket = next.socket; pendingSocket = nil
            return next
        } catch {
            drain.cancel()
            old.socket.cancel(with: .goingAway, reason: nil)
            throw error
        }
    }

    private func receive(_ ws: URLSessionWebSocketTask, timeout: TimeInterval) async throws -> [String: Any] {
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(timeout + 1)) } catch { return }
            ws.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        let frame = try await ws.receive()
        let data: Data
        switch frame {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: throw FeedError.invalidMessage
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["metadata"] is [String: Any] else { throw FeedError.invalidMessage }
        return object
    }

    private func process(_ envelope: [String: Any]) throws -> Bool {
        guard let metadata = envelope["metadata"] as? [String: Any], let kind = metadata["message_type"] as? String else { throw FeedError.invalidMessage }
        if kind == "revocation" { throw FeedError.revoked }
        guard kind == "notification", let id = metadata["message_id"] as? String, remember(id),
              let payload = envelope["payload"] as? [String: Any], let event = payload["event"] as? [String: Any] else { return false }
        switch metadata["subscription_type"] as? String {
        case "channel.chat.message":
            guard let mid = event["message_id"] as? String, let uid = event["chatter_user_id"] as? String,
                  let login = event["chatter_user_login"] as? String, let name = event["chatter_user_name"] as? String,
                  let message = event["message"] as? [String: Any], let text = message["text"] as? String else { return false }
            let fragments = (message["fragments"] as? [[String: Any]] ?? []).prefix(128).compactMap { fragment -> TwitchChatMessage.Fragment? in
                guard let text = fragment["text"] as? String else { return nil }
                let emote = fragment["type"] as? String == "emote" ? fragment["emote"] as? [String: Any] : nil
                return .init(text: text, emoteID: emote?["id"] as? String, mention: fragment["type"] as? String == "mention")
            }
            onEvent(.message(TwitchChatMessage(id: mid, userID: uid, login: login, displayName: name,
                                              color: event["color"] as? String, text: text,
                                              sourceChannel: event["source_broadcaster_user_login"] as? String,
                                              timestamp: metadata["message_timestamp"] as? String, fragments: fragments)))
            return true
        case "channel.chat.message_delete":
            if let mid = event["message_id"] as? String { onEvent(.deleteMessage(mid)) }
        case "channel.chat.clear_user_messages":
            if let uid = event["target_user_id"] as? String { onEvent(.clearUser(uid)) }
        case "channel.chat.clear": onEvent(.clear)
        default: break
        }
        return false
    }

    private func remember(_ id: String) -> Bool {
        guard seen.insert(id).inserted else { return false }
        if seenOrder.count < 2048 { seenOrder.append(id) }
        else { seen.remove(seenOrder[seenCursor]); seenOrder[seenCursor] = id; seenCursor = (seenCursor + 1) % 2048 }
        return true
    }
    private func isCurrent(_ g: UInt64) -> Bool { g == generation && !Task.isCancelled }
    private func check(_ g: UInt64) throws { if !isCurrent(g) { throw CancellationError() } }
    private func isTerminal(_ error: Error) -> Bool {
        guard let error = error as? TwitchSessionError else { return false }
        switch error {
        case .notConnected, .unauthorized, .denied, .expired, .invalidRequest, .invalidResponse: return true
        default: return false
        }
    }
    static func isSafeEndpoint(_ url: URL) -> Bool {
        url.scheme == "wss" && url.host == "eventsub.wss.twitch.tv" && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil && url.fragment == nil
    }
    static func normalize(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.contains("://") || text.hasPrefix("twitch.tv/") || text.hasPrefix("www.twitch.tv/") || text.hasPrefix("m.twitch.tv/") {
            let address = text.contains("://") ? text : "https://" + text
            guard let url = URLComponents(string: address),
                  ["https", "http"].contains(url.scheme ?? ""),
                  ["twitch.tv", "www.twitch.tv", "m.twitch.tv"].contains(url.host ?? ""),
                  url.user == nil, url.password == nil, url.port == nil else { return nil }
            let parts = url.path.split(separator: "/")
            guard parts.count == 1 else { return nil }
            text = String(parts[0])
        }
        if text.hasPrefix("#") || text.hasPrefix("@") { text.removeFirst() }
        guard !text.isEmpty, text.utf8.count <= 25,
              text.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else { return nil }
        return text
    }
}
