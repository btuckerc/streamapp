import AppKit
import Combine
import Foundation
import Security

struct TwitchAccount: Codable, Equatable, Sendable {
    let id: String
    let login: String
    let displayName: String
}

struct TwitchDeviceAuthorization: Equatable {
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
}

enum TwitchSessionError: Error, LocalizedError {
    case notConnected, cancelled, expired, denied, unavailable, invalidResponse, unauthorized, rateLimited, server, keychain, invalidRequest
    var errorDescription: String? {
        switch self {
        case .notConnected: "Twitch is not connected."
        case .cancelled: "Twitch connection was cancelled."
        case .expired: "The Twitch authorization code expired. Connect again."
        case .denied: "Twitch authorization was denied."
        case .unavailable: "Twitch is temporarily unavailable. Try again."
        case .invalidResponse: "Twitch returned an invalid response."
        case .unauthorized: "Twitch authorization is no longer valid. Connect again."
        case .rateLimited: "Twitch rate limit reached. Try again later."
        case .server: "Twitch returned a server error. Try again."
        case .keychain: "Unable to access secure Twitch credentials in Keychain."
        case .invalidRequest: "Twitch rejected the request. Check the channel and connection."
        }
    }
}

@MainActor
final class TwitchSession: ObservableObject {
    static let shared = TwitchSession()
    // Public application identifier, not a secret. Public clients use Device Code OAuth only.
    static let clientID = "8sg8h6ntpaavciqszm3gd5d32t41rd"
    private static let scopes = ["user:read:chat", "channel:read:stream_key"]
    @Published private(set) var account: TwitchAccount?
    @Published private(set) var connecting = false
    @Published private(set) var deviceAuthorization: TwitchDeviceAuthorization?
    @Published private(set) var status = "Not connected"
    private let persist: Bool
    private let network: URLSession
    private let openURL: (URL) -> Void
    private var credentials: TokenBundle?
    private var connectionTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Error>?
    private var validationTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var restored = false
    private var rateLimitUntil = Date.distantPast

    private struct TokenBundle: Codable {
        let accessToken: String
        let refreshToken: String
        let account: TwitchAccount
    }
    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let scope: [String]
    }
    private struct DeviceResponse: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: URL
        let expires_in: Double
        let interval: Double
    }
    private struct Validation: Decodable {
        let client_id: String
        let user_id: String
        let login: String
        let scopes: [String]
    }
    private enum PollError: Error { case pending, slowDown }

    init(persist: Bool = true, urlSession: URLSession? = nil, openURL: ((URL) -> Void)? = nil) {
        self.persist = persist
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        network = urlSession ?? URLSession(configuration: configuration, delegate: TwitchNoRedirects(), delegateQueue: nil)
        self.openURL = openURL ?? { NSWorkspace.shared.open($0) }
    }

    deinit { network.invalidateAndCancel() }

    func connect() {
        guard account == nil else { return }
        cancelWork()
        credentials = nil
        let g = generation
        connecting = true
        status = "Requesting Twitch authorization…"
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.oauth("device", values: ["client_id": Self.clientID, "scopes": Self.scopes.joined(separator: " ")])
                try self.check(g)
                let device = try JSONDecoder().decode(DeviceResponse.self, from: data)
                guard !device.device_code.isEmpty, !device.user_code.isEmpty,
                      device.expires_in > 0, device.expires_in <= 3600, device.interval >= 1, device.interval <= 60,
                      Self.validAuthorizationURL(device.verification_uri) else { throw TwitchSessionError.invalidResponse }
                let authorization = TwitchDeviceAuthorization(userCode: device.user_code, verificationURL: device.verification_uri, expiresAt: Date().addingTimeInterval(device.expires_in))
                self.deviceAuthorization = authorization
                self.status = "Approve StreamApp by btuckerc on Twitch."
                self.openURL(authorization.verificationURL)
                var interval = device.interval
                while Date() < authorization.expiresAt {
                    try await Task.sleep(for: .seconds(interval))
                    try self.check(g)
                    guard Date() < authorization.expiresAt else { throw TwitchSessionError.expired }
                    do {
                        let result = try await self.oauth("token", values: ["client_id": Self.clientID, "device_code": device.device_code,
                            "grant_type": "urn:ietf:params:oauth:grant-type:device_code", "scopes": Self.scopes.joined(separator: " ")])
                        try self.check(g)
                        let tokens = try self.parseTokens(result)
                        let identity = try await self.validate(tokens.access_token, expected: nil)
                        try self.check(g)
                        let bundle = TokenBundle(accessToken: tokens.access_token, refreshToken: tokens.refresh_token, account: identity)
                        try self.store(bundle)
                        self.credentials = bundle
                        self.account = identity
                        self.deviceAuthorization = nil
                        self.connecting = false
                        self.status = "Connected as @\(identity.login)."
                        self.scheduleValidation()
                        return
                    } catch PollError.pending { continue }
                    catch PollError.slowDown { interval = min(interval + 5, 120) }
                }
                throw TwitchSessionError.expired
            } catch {
                guard self.generation == g else { return }
                self.deviceAuthorization = nil; self.connecting = false
                self.status = Self.safeStatus(error)
            }
        }
    }

    func cancelConnect() {
        guard connecting else { return }
        cancelWork()
        deviceAuthorization = nil; connecting = false
        status = "Sign-in cancelled"
    }

    func restore() async {
        guard persist, !restored, !connecting else { return }
        restored = true
        let g = generation
        do {
            guard let bundle = try load() else { return }
            credentials = bundle
            status = "Validating Twitch authorization…"
            try await validateCurrent(g)
            try check(g)
            scheduleValidation()
        } catch {
            guard generation == g else { return }
            if Self.terminal(error) { terminate(Self.safeStatus(error)) }
            else { status = Self.safeStatus(error); scheduleValidation(retrySoon: true) }
        }
    }

    func disconnect() async {
        let token = credentials?.accessToken
        cancelWork()
        let g = generation
        credentials = nil; account = nil; deviceAuthorization = nil; connecting = false
        do { try deleteStored() }
        catch { status = "Disconnected, but saved Twitch credentials could not be removed from Keychain."; return }
        status = "Disconnected"
        guard let token else { return }
        do { _ = try await oauth("revoke", values: ["client_id": Self.clientID, "token": token]) }
        catch {
            guard generation == g else { return }
            status = "Disconnected locally. Twitch revocation failed; remove StreamApp in Twitch Connections to revoke remotely."
        }
    }

    func request(path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        let g = generation
        guard let current = credentials else { throw TwitchSessionError.notConnected }
        do {
            do {
                let data = try await helix(path: path, method: method, query: query, body: body, token: current.accessToken)
                try check(g)
                return data
            } catch TwitchSessionError.unauthorized {
                try check(g)
                // A late 401 for an old token must not rotate the new one a second time.
                try await refresh(failedToken: current.accessToken, generation: g)
                try check(g)
                guard let replacement = credentials else { throw TwitchSessionError.notConnected }
                let data = try await helix(path: path, method: method, query: query, body: body, token: replacement.accessToken)
                try check(g)
                return data
            }
        } catch {
            if generation == g, Self.terminal(error) { terminate(Self.safeStatus(error)) }
            throw error
        }
    }

    func user(login: String) async throws -> TwitchAccount {
        let data = try await request(path: "/users", query: [URLQueryItem(name: "login", value: login)])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let user = (root["data"] as? [[String: Any]])?.first,
              let id = user["id"] as? String, let login = user["login"] as? String, let name = user["display_name"] as? String else { throw TwitchSessionError.invalidRequest }
        return TwitchAccount(id: id, login: login, displayName: name)
    }

    func streamKey() async throws -> String {
        guard let account else { throw TwitchSessionError.notConnected }
        let data = try await request(path: "/streams/key", query: [URLQueryItem(name: "broadcaster_id", value: account.id)])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = (root["data"] as? [[String: Any]])?.first?["stream_key"] as? String, !key.isEmpty else { throw TwitchSessionError.invalidResponse }
        return key
    }

    private func refresh(failedToken: String, generation g: UInt64) async throws {
        if let refreshTask { try await refreshTask.value; try check(g); return }
        guard let current = credentials else { throw TwitchSessionError.notConnected }
        if current.accessToken != failedToken { return }
        let task = Task { @MainActor in
            let data = try await self.oauth("token", values: ["client_id": Self.clientID, "grant_type": "refresh_token", "refresh_token": current.refreshToken])
            try self.check(g)
            let tokens = try self.parseTokens(data)
            let replacement = TokenBundle(accessToken: tokens.access_token, refreshToken: tokens.refresh_token, account: current.account)
            // Device refresh tokens are single-use. Save the replacement before any further network await.
            try self.store(replacement)
            self.credentials = replacement
            let identity = try await self.validate(tokens.access_token, expected: current.account)
            try self.check(g)
            self.account = identity
        }
        refreshTask = task
        defer { if generation == g { refreshTask = nil } }
        try await task.value
    }

    private func validate(_ token: String, expected: TwitchAccount?) async throws -> TwitchAccount {
        var request = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/validate")!)
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        let data = try await raw(request)
        let validation = try JSONDecoder().decode(Validation.self, from: data)
        guard validation.client_id == Self.clientID, !validation.user_id.isEmpty, !validation.login.isEmpty,
              Set(validation.scopes) == Set(Self.scopes), expected == nil || validation.user_id == expected?.id else { throw TwitchSessionError.unauthorized }
        return TwitchAccount(id: validation.user_id, login: validation.login, displayName: validation.login)
    }

    private func validateCurrent(_ g: UInt64) async throws {
        guard let current = credentials else { throw TwitchSessionError.notConnected }
        do {
            let identity = try await validate(current.accessToken, expected: current.account)
            try check(g)
            account = identity
            status = "Connected as @\(identity.login)."
        } catch TwitchSessionError.unauthorized {
            try check(g)
            try await refresh(failedToken: current.accessToken, generation: g)
            try check(g)
            status = "Connected as @\(account?.login ?? "")."
        }
    }

    private func scheduleValidation(retrySoon: Bool = false) {
        validationTask?.cancel()
        let g = generation
        validationTask = Task { [weak self] in
            var interval: Double = retrySoon ? 30 : 3600
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self, self.generation == g else { return }
                if self.credentials == nil {
                    self.restored = false
                    await self.restore()
                    return
                }
                do { try await self.validateCurrent(g); interval = 3600 }
                catch {
                    guard self.generation == g else { return }
                    if Self.terminal(error) { self.terminate(Self.safeStatus(error)); return }
                    self.status = Self.safeStatus(error); interval = 30
                }
            }
        }
    }

    private func cancelWork() {
        generation &+= 1
        connectionTask?.cancel(); connectionTask = nil
        refreshTask?.cancel(); refreshTask = nil
        validationTask?.cancel(); validationTask = nil
    }
    private func terminate(_ message: String) {
        cancelWork()
        credentials = nil; account = nil; connecting = false; deviceAuthorization = nil
        do { try deleteStored(); status = message }
        catch { status = "\(message) Saved credentials could not be removed from Keychain." }
    }
    private func check(_ g: UInt64) throws { if generation != g || Task.isCancelled { throw CancellationError() } }
    private static func terminal(_ error: Error) -> Bool {
        guard let error = error as? TwitchSessionError else { return false }
        switch error { case .unauthorized, .denied: return true; default: return false }
    }
    private static func safeStatus(_ error: Error) -> String {
        (error as? TwitchSessionError)?.localizedDescription ?? "Twitch connection failed. Try again."
    }

    private func parseTokens(_ data: Data) throws -> TokenResponse {
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard !tokens.access_token.isEmpty, !tokens.refresh_token.isEmpty, Set(tokens.scope) == Set(Self.scopes) else { throw TwitchSessionError.unauthorized }
        return tokens
    }
    private static func validAuthorizationURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "www.twitch.tv" && url.path == "/activate" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }
    private func oauth(_ endpoint: String, values: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/\(endpoint)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = Data(values.sorted(by: { $0.key < $1.key }).map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
        return try await raw(request)
    }
    private func helix(path: String, method: String, query: [URLQueryItem], body: Data?, token: String) async throws -> Data {
        // These are owned API paths, not arbitrary URLs or user channel strings.
        let emotePath = path == "/chat/emotes" || path == "/chat/emotes/global"
        guard (emotePath && method == "GET") || (["/users", "/streams/key", "/eventsub/subscriptions"].contains(path) && ["GET", "POST", "DELETE"].contains(method)) else { throw TwitchSessionError.invalidRequest }
        guard Date() >= rateLimitUntil else { throw TwitchSessionError.rateLimited }
        var components = URLComponents(string: "https://api.twitch.tv/helix\(path)")!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method; request.httpBody = body
        request.setValue(Self.clientID, forHTTPHeaderField: "Client-Id")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return try await raw(request)
    }
    private func raw(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await network.data(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw TwitchSessionError.unavailable }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw TwitchSessionError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 400:
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = ((object?["error"] as? String) ?? (object?["message"] as? String) ?? "").lowercased()
            switch code {
            case "authorization_pending": throw PollError.pending
            case "slow_down": throw PollError.slowDown
            case "access_denied": throw TwitchSessionError.denied
            case "expired_token", "invalid device code": throw TwitchSessionError.expired
            case "invalid refresh token": throw TwitchSessionError.unauthorized
            default: throw TwitchSessionError.invalidRequest
            }
        case 401: throw TwitchSessionError.unauthorized
        case 403: throw TwitchSessionError.denied
        case 429:
            if request.url?.host == "api.twitch.tv" {
                let epoch = http.value(forHTTPHeaderField: "Ratelimit-Reset").flatMap(Double.init)
                rateLimitUntil = epoch.map { Date(timeIntervalSince1970: $0) } ?? Date().addingTimeInterval(60)
            }
            throw TwitchSessionError.rateLimited
        case 500..<600: throw TwitchSessionError.server
        default: throw TwitchSessionError.invalidResponse
        }
    }

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.streamapp.twitch.oauth", kSecAttrAccount as String: "token-bundle"]
    }
    private func store(_ bundle: TokenBundle) throws {
        guard persist else { return }
        let data = try JSONEncoder().encode(bundle)
        let result = SecItemUpdate(Self.keychainQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var query = Self.keychainQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw TwitchSessionError.keychain }
        } else if result != errSecSuccess { throw TwitchSessionError.keychain }
    }
    private func load() throws -> TokenBundle? {
        var query = Self.keychainQuery
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = result as? Data else { throw TwitchSessionError.keychain }
        return try JSONDecoder().decode(TokenBundle.self, from: data)
    }
    private func deleteStored() throws {
        guard persist else { return }
        let code = SecItemDelete(Self.keychainQuery as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else { throw TwitchSessionError.keychain }
    }
}

private final class TwitchNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
