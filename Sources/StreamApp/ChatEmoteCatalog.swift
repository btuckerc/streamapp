import Foundation

/// Public catalogs only. Images remain CDN-cached in WebKit; no per-message API calls.
actor ChatEmoteCatalog {
    struct Emote: Codable, Sendable {
        let url: String
        let aspect: Double
        let zeroWidth: Bool
        let effects: Int
    }
    struct Catalog: Codable, Sendable {
        var global: [String: Emote] = [:]
        var channel: [String: Emote] = [:]
        var unavailable: [String] = []
    }
    private struct Cached {
        let emotes: [String: Emote]
        let expires: Date
        let failed: Bool
    }
    private enum Provider: String, CaseIterable, Sendable {
        // Later providers win equal-name collisions within the same scope.
        case bttv = "BTTV", ffz = "FFZ", seven = "7TV", twitch = "Twitch"
    }
    static let shared = ChatEmoteCatalog()
    private var cache: [String: Cached] = [:]
    private var order: [String] = []
    private var pending: [String: Task<Cached, Never>] = [:]

    func load(channelID: String) async -> Catalog {
        guard !channelID.isEmpty, channelID.utf8.count <= 32, channelID.utf8.allSatisfy({ (48...57).contains($0) }) else { return Catalog() }
        var result = Catalog()
        // Fetch providers concurrently; merge in deterministic scope/provider order.
        await withTaskGroup(of: (Provider, Cached, Cached).self) { group in
            for provider in Provider.allCases {
                group.addTask {
                    async let global = self.entries(provider, channelID: nil)
                    async let channel = self.entries(provider, channelID: channelID)
                    return await (provider, global, channel)
                }
            }
            var received: [Provider: (Cached, Cached)] = [:]
            for await (provider, global, channel) in group { received[provider] = (global, channel) }
            for provider in Provider.allCases {
                guard let (global, channel) = received[provider] else { continue }
                result.global.merge(global.emotes) { _, newer in newer }
                result.channel.merge(channel.emotes) { _, newer in newer }
                if global.failed || channel.failed { result.unavailable.append(provider.rawValue) }
            }
        }
        return result
    }

    private func entries(_ provider: Provider, channelID: String?) async -> Cached {
        let key = provider.rawValue + "/" + (channelID ?? "global")
        if let value = cache[key], value.expires > Date() {
            order.removeAll { $0 == key }; order.append(key)
            return value
        }
        if let task = pending[key] { return await task.value }
        let previous = cache[key]
        let task = Task { () -> Cached in
            do {
                let data: Data
                if provider == .twitch {
                    data = try await TwitchSession.shared.request(path: channelID == nil ? "/chat/emotes/global" : "/chat/emotes",
                        query: channelID.map { [URLQueryItem(name: "broadcaster_id", value: $0)] } ?? [])
                } else {
                    data = try await EmoteDownload.fetch(Self.endpoint(provider, channelID: channelID))
                }
                let emotes = try Self.parse(data, provider: provider, channel: channelID != nil)
                return Cached(emotes: emotes, expires: Date().addingTimeInterval(1800), failed: false)
            } catch EmoteDownload.Failure.notFound {
                // A channel not enrolled with this provider is a valid empty catalog.
                if channelID == nil { return Cached(emotes: previous?.emotes ?? [:], expires: Date().addingTimeInterval(300), failed: true) }
                return Cached(emotes: [:], expires: Date().addingTimeInterval(1800), failed: false)
            } catch {
                return Cached(emotes: previous?.emotes ?? [:], expires: Date().addingTimeInterval(300), failed: true)
            }
        }
        pending[key] = task
        let value = await task.value
        pending[key] = nil
        cache[key] = value
        order.removeAll { $0 == key }; order.append(key)
        while order.count > 36 { cache.removeValue(forKey: order.removeFirst()) }
        return value
    }

    private static func endpoint(_ provider: Provider, channelID: String?) -> URL {
        let path: String
        switch provider {
        case .seven: path = channelID.map { "https://7tv.io/v3/users/twitch/\($0)" } ?? "https://7tv.io/v3/emote-sets/global"
        case .bttv: path = channelID.map { "https://api.betterttv.net/3/cached/users/twitch/\($0)" } ?? "https://api.betterttv.net/3/cached/emotes/global"
        case .ffz: path = channelID.map { "https://api.frankerfacez.com/v1/room/id/\($0)" } ?? "https://api.frankerfacez.com/v1/set/global"
        case .twitch: preconditionFailure("Twitch uses the authenticated session")
        }
        return URL(string: path)!
    }

    private static func parse(_ data: Data, provider: Provider, channel: Bool) throws -> [String: Emote] {
        let json = try JSONSerialization.jsonObject(with: data)
        var result: [String: Emote] = [:]
        func add(_ code: String?, _ url: String?, aspect: Double = 1, zeroWidth: Bool = false, effects: Int = 0) {
            guard result.count < 8192, let code, !code.isEmpty, code.count <= 128,
                  !code.contains(where: \.isWhitespace), let url, let safe = safeImageURL(url),
                  aspect.isFinite, aspect > 0 else { return }
            result[code] = Emote(url: safe, aspect: min(6, max(0.25, aspect)), zeroWidth: zeroWidth, effects: effects & 0x500f)
        }
        switch provider {
        case .seven:
            guard let root = json as? [String: Any] else { throw EmoteDownload.Failure.invalidResponse }
            let set = channel ? root["emote_set"] as? [String: Any] : root
            guard let set else { return [:] }
            guard let emotes = set["emotes"] as? [[String: Any]] else { throw EmoteDownload.Failure.invalidResponse }
            for active in emotes.prefix(8192) {
                guard let data = active["data"] as? [String: Any], data["listed"] as? Bool != false,
                      ((data["flags"] as? Int ?? 0) & ((1 << 24) | 1)) == 0,
                      let host = data["host"] as? [String: Any], let base = host["url"] as? String,
                      let files = host["files"] as? [[String: Any]],
                      let file = files.first(where: { $0["name"] as? String == "2x.webp" }),
                      let name = file["static_name"] as? String, !name.contains("/"),
                      let width = file["width"] as? Double, let height = file["height"] as? Double,
                      width <= 1024, height > 0, height <= 256 else { continue }
                add(active["name"] as? String, base + "/" + name, aspect: width / height,
                    zeroWidth: ((active["flags"] as? Int ?? 0) & 1) != 0)
            }
        case .bttv:
            let emotes: [[String: Any]]
            if channel {
                guard let root = json as? [String: Any], let own = root["channelEmotes"] as? [[String: Any]],
                      let shared = root["sharedEmotes"] as? [[String: Any]] else { throw EmoteDownload.Failure.invalidResponse }
                emotes = own + shared
            } else {
                guard let all = json as? [[String: Any]] else { throw EmoteDownload.Failure.invalidResponse }
                emotes = all
            }
            for emote in emotes.prefix(8192) {
                guard let id = emote["id"] as? String, id.range(of: "^[a-zA-Z0-9]+$", options: .regularExpression) != nil else { continue }
                // BTTV's .webp route may animate; .png selects the still-image variant.
                add(emote["code"] as? String, "https://cdn.betterttv.net/emote/\(id)/2x.png", zeroWidth: emote["modifier"] as? Bool == true)
            }
        case .ffz:
            guard let root = json as? [String: Any], let sets = root["sets"] as? [String: Any] else { throw EmoteDownload.Failure.invalidResponse }
            let ids: [String]
            if channel {
                guard let room = root["room"] as? [String: Any], let id = room["set"] as? Int else { throw EmoteDownload.Failure.invalidResponse }
                ids = [String(id)]
            } else {
                guard let defaults = root["default_sets"] as? [Int] else { throw EmoteDownload.Failure.invalidResponse }
                ids = defaults.map(String.init)
            }
            for id in ids {
                guard let set = sets[id] as? [String: Any], let emotes = set["emoticons"] as? [[String: Any]] else { continue }
                for emote in emotes.prefix(8192) {
                    // FFZ public/hidden govern adding emotes and picker visibility, not rendering an active set.
                    guard let urls = emote["urls"] as? [String: String] else { continue }
                    let width = emote["width"] as? Double ?? 28, height = emote["height"] as? Double ?? 28
                    add(emote["name"] as? String, urls["2"] ?? urls["1"], aspect: width / max(1, height),
                        zeroWidth: emote["modifier"] as? Bool == true, effects: emote["modifier_flags"] as? Int ?? 0)
                }
            }
        case .twitch:
            guard let root = json as? [String: Any], let emotes = root["data"] as? [[String: Any]],
                  let template = root["template"] as? String else { throw EmoteDownload.Failure.invalidResponse }
            for emote in emotes.prefix(8192) {
                guard let id = emote["id"] as? String else { continue }
                let url = template.replacingOccurrences(of: "{{id}}", with: id).replacingOccurrences(of: "{{format}}", with: "static")
                    .replacingOccurrences(of: "{{theme_mode}}", with: "dark").replacingOccurrences(of: "{{scale}}", with: "2.0")
                add(emote["name"] as? String, url)
            }
        }
        return result
    }

    private static func safeImageURL(_ value: String) -> String? {
        let value = value.hasPrefix("//") ? "https:" + value : value
        guard let url = URL(string: value), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.query == nil, url.fragment == nil,
              ["static-cdn.jtvnw.net", "cdn.7tv.app", "cdn.betterttv.net", "cdn.frankerfacez.com"].contains(url.host ?? "") else { return nil }
        return url.absoluteString
    }
}

/// Cap decompressed catalog bytes during transfer, not after an unbounded download.
private final class EmoteDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Failure: Error { case notFound, invalidResponse, tooLarge }
    private let lock = NSLock()
    private var bytes = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var cancelled = false
    private static let limit = 8 * 1024 * 1024

    static func fetch(_ url: URL) async throws -> Data {
        let download = EmoteDownload()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { download.begin(url, continuation: $0) }
        } onCancel: { download.cancel() }
    }
    private func begin(_ url: URL, continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: url)
        lock.unlock()
        task.resume()
    }
    private func cancel() { lock.lock(); cancelled = true; lock.unlock(); finish(CancellationError()) }
    private func finish(_ error: Error?) {
        lock.lock()
        let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil
        let data = bytes; bytes = Data()
        lock.unlock()
        session?.invalidateAndCancel()
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume(returning: data) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            completionHandler(.cancel)
            finish((response as? HTTPURLResponse)?.statusCode == 404 ? Failure.notFound : Failure.invalidResponse)
            return
        }
        guard response.expectedContentLength <= Self.limit else { completionHandler(.cancel); finish(Failure.tooLarge); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let oversized = bytes.count + data.count > Self.limit
        if !oversized, continuation != nil { bytes.append(data) }
        lock.unlock()
        if oversized { finish(Failure.tooLarge) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { finish(error) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
