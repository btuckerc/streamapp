import AppKit
import WebKit

@MainActor
final class Chat: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let width: CGFloat
    private static let height: CGFloat = 1080

    let webView: WKWebView
    var error: Error?
    private(set) var snapshots = 0
    private(set) var connectionStatus = "CONNECTING"
    private let onImage: (CGImage) -> Void
    private let onStatus: (String) -> Void
    private let onTranscript: ((String) -> Void)?
    private let onEmoteStatus: ((String) -> Void)?
    private var emoteChannelID: String?
    private var emoteTask: Task<Void, Never>?
    private var pendingCatalog: ChatEmoteCatalog.Catalog?
    private var appearance: ChatAppearance
    private var appearanceDirty = true
    private var timer: Timer?
    private var ready = false
    private var dirty = true
    private var busy = false
    private var generation: UInt64 = 1
    private var imageScale: Double?
    private var stopped = false
    private var feed: TwitchChatFeed?
    private var pendingEvents: [[String: Any]] = []
    private var pendingStatus: String?
    private var renderTask: Task<Void, Never>?
    private var lastSnapshotAt: Date?
    private let snapshotInterval: TimeInterval = 1.0 / 30.0

    private final class WeakMessageProxy: NSObject, WKScriptMessageHandler {
        weak var owner: Chat?
        init(_ owner: Chat) { self.owner = owner }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            // WebKit may invoke this outside the actor's isolated context.
            Task { @MainActor [weak owner] in owner?.markDirty() }
        }
    }

    private var messageProxy: WeakMessageProxy!

    init(onImage: @escaping (CGImage) -> Void, channel: String, width: Int = 384, appearance: ChatAppearance, onStatus: @escaping (String) -> Void = { _ in }, onTranscript: ((String) -> Void)? = nil, onEmoteStatus: ((String) -> Void)? = nil) {
        self.onImage = onImage
        self.onStatus = onStatus
        self.onTranscript = onTranscript
        self.onEmoteStatus = onEmoteStatus
        self.appearance = appearance
        self.width = CGFloat(width)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: Int(Self.height)), configuration: configuration)
        super.init()
        messageProxy = WeakMessageProxy(self)
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .clear
        // Keep alpha when the user chooses the translucent terminal background.
        webView.setValue(false, forKey: "drawsBackground")
        configuration.userContentController.add(messageProxy, name: "chatDirty")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.dirtyScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        if let resource = Bundle.main.url(forResource: "chat", withExtension: "html", subdirectory: "StreamApp_StreamApp.bundle") ?? Bundle.module.url(forResource: "chat", withExtension: "html") {
            webView.loadFileURL(resource, allowingReadAccessTo: resource.deletingLastPathComponent())
        } else {
            error = SnapshotFailure.missingResource
        }
        feed = TwitchChatFeed(session: .shared, channel: channel, onEvent: { [weak self] event in
            guard let self, !self.stopped else { return }
            var value: [String: Any]
            switch event {
            case .channel(let channel, let id):
                value = ["type": "channel", "value": channel]
                if self.emoteChannelID != id {
                    self.emoteChannelID = id
                    self.pendingCatalog = ChatEmoteCatalog.Catalog()
                    self.loadEmotes()
                }
            case .message(let message):
                value = ["type": "message", "id": message.id, "userID": message.userID, "login": message.login,
                         "displayName": message.displayName, "text": message.text]
                if let color = message.color { value["color"] = color }
                if let source = message.sourceChannel { value["sourceChannel"] = source }
                if let timestamp = message.timestamp { value["timestamp"] = timestamp }
                value["fragments"] = message.fragments.map { fragment -> [String: Any] in
                    var part: [String: Any] = ["text": fragment.text, "mention": fragment.mention]
                    if let id = fragment.emoteID { part["emoteID"] = id }
                    return part
                }
            case .deleteMessage(let id): value = ["type": "delete", "value": id]
            case .clearUser(let id): value = ["type": "clearUser", "value": id]
            case .clear: value = ["type": "clear"]
            }
            // Bound native buffering as well as the DOM. A backlog drops history, never moderation.
            if self.pendingEvents.count >= 256 {
                self.pendingEvents.removeAll(keepingCapacity: true)
                self.pendingEvents.append(["type": "clear"])
            }
            self.pendingEvents.append(value)
            self.scheduleRender()
        }, onStatus: { [weak self] status in
            guard let self, !self.stopped else { return }
            self.connectionStatus = status
            self.onStatus(status)
            self.pendingStatus = status
            self.scheduleRender()
        })
    }

    func updateAppearance(_ value: ChatAppearance) {
        guard appearance != value else { return }
        let emotesChanged = appearance.emotes != value.emotes
        appearance = value
        appearanceDirty = true
        if emotesChanged { loadEmotes() }
        scheduleRender()
    }

    private func loadEmotes() {
        emoteTask?.cancel(); emoteTask = nil
        guard !stopped, appearance.emotes, let id = emoteChannelID else {
            onEmoteStatus?(appearance.emotes ? "Waiting for the chat channel." : "Emotes are off.")
            return
        }
        onEmoteStatus?("Loading Twitch, 7TV, BTTV and FFZ emotes…")
        emoteTask = Task { [weak self] in
            while !Task.isCancelled {
                let catalog = await ChatEmoteCatalog.shared.load(channelID: id)
                guard let self, !self.stopped, !Task.isCancelled, self.appearance.emotes, self.emoteChannelID == id else { return }
                self.pendingCatalog = catalog
                let loaded = "\(catalog.global.count) global and \(catalog.channel.count) channel emotes. Static images; refreshed every 30 minutes."
                self.onEmoteStatus?(catalog.unavailable.isEmpty ? loaded : loaded + " Unavailable: " + catalog.unavailable.joined(separator: ", ") + ". Unknown codes stay as text.")
                self.scheduleRender()
                do { try await Task.sleep(for: .seconds(1800)) } catch { return }
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        feed?.stop(); feed = nil
        emoteTask?.cancel(); emoteTask = nil; pendingCatalog = nil
        renderTask?.cancel(); renderTask = nil
        pendingEvents.removeAll(); pendingStatus = nil
        timer?.invalidate()
        timer = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "chatDirty")
        messageProxy.owner = nil
    }

    private func markDirty() {
        guard !stopped else { return }
        generation &+= 1
        dirty = true
        scheduleSnapshot()
    }

    private func scheduleSnapshot() {
        guard !stopped, ready, dirty, !busy, timer == nil else { return }
        let elapsed = lastSnapshotAt.map { Date().timeIntervalSince($0) } ?? snapshotInterval
        let delay = max(0, snapshotInterval - elapsed)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.timer = nil
                self.tick()
            }
        }
    }

    private func tick() {
        guard !stopped, ready, dirty, !busy else { return }
        dirty = false
        busy = true
        lastSnapshotAt = Date()
        let requestGeneration = generation
        let settings = WKSnapshotConfiguration()
        settings.rect = webView.bounds
        // The first image establishes the actual NSImage backing scale. WKWebView
        // takes this value in logical points; output uses the configured pixel width.
        if let scale = imageScale, scale > 0 {
            settings.snapshotWidth = NSNumber(value: Double(width) / scale)
        }
        webView.takeSnapshot(with: settings) { [weak self] image, snapshotError in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.busy = false
                guard let image,
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      cgImage.width > 0, cgImage.height > 0 else {
                    if let snapshotError { self.reportSnapshotFailure(snapshotError) }
                    else { self.reportSnapshotFailure(SnapshotFailure.invalidImage) }
                    // Keep this dirty so a transient WebKit failure can retry.
                    self.dirty = true
                    self.scheduleSnapshot()
                    return
                }
                if image.size.width > 0 {
                    self.imageScale = Double(cgImage.width) / Double(image.size.width)
                }
                // Do not publish the scale-discovery frame: callers always receive
                // the configured width × 1080 pixel image.
                guard cgImage.width == Int(self.width), cgImage.height == Int(Self.height) else {
                    self.dirty = true
                    self.scheduleSnapshot()
                    return
                }
                self.error = nil
                self.snapshots += 1
                self.onImage(cgImage)
                // A notification arriving while the snapshot was in flight must
                // survive completion; generation is intentionally monotonic.
                if self.generation != requestGeneration { self.dirty = true }
                self.scheduleSnapshot()
            }
        }
    }

    private func reportSnapshotFailure(_ failure: Error) {
        error = failure
        fputs("chat snapshot failed: \(failure)\n", stderr)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        markDirty()
        scheduleRender()
        feed?.start()
    }

    private func scheduleRender() {
        guard !stopped, ready, renderTask == nil else { return }
        renderTask = Task { [weak self] in
            guard let self else { return }
            defer { self.renderTask = nil }
            while !self.stopped && (!self.pendingEvents.isEmpty || self.pendingStatus != nil || self.appearanceDirty || self.pendingCatalog != nil) {
                let events = self.pendingEvents
                let status = self.pendingStatus ?? self.connectionStatus
                self.pendingEvents.removeAll()
                self.pendingStatus = nil
                if self.appearanceDirty {
                    self.appearanceDirty = false
                    if let data = try? JSONEncoder().encode(self.appearance),
                       let options = try? JSONSerialization.jsonObject(with: data) {
                        await self.runScript("window.configureChat(options)", arguments: ["options": options])
                    }
                }
                if let catalog = self.pendingCatalog {
                    self.pendingCatalog = nil
                    if let data = try? JSONEncoder().encode(catalog),
                       let value = try? JSONSerialization.jsonObject(with: data) {
                        await self.runScript("window.setEmoteCatalog(catalog)", arguments: ["catalog": value])
                    }
                }
                await self.runScript("window.applyChatEvents(events); window.setStatus(status); if (transcript) return window.chatTranscript()",
                                     arguments: ["events": events, "status": status, "transcript": self.onTranscript != nil])
            }
        }
    }


    private func runScript(_ script: String, arguments: [String: Any]) async {
        guard !stopped else { return }
        await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { [weak self] result in
                if case .failure(let error) = result { self?.error = error }
                if case .success(let text as String) = result, self?.stopped == false { self?.onTranscript?(text) }
                continuation.resume()
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error
        ready = false
        markDirty()
        fputs("chat navigation failed: \(error)\n", stderr)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
        ready = false
        markDirty()
        fputs("chat navigation failed: \(error)\n", stderr)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        markDirty()
    }

    // Text and static emotes only: no animation polling or perpetual snapshot loop.
    private static let dirtyScript = #"""
    (() => {
      const notify = () => window.webkit.messageHandlers.chatDirty.postMessage(1);
      new MutationObserver(notify).observe(document.documentElement, {
        subtree:true, childList:true, attributes:true, characterData:true
      });
      addEventListener('resize', notify, {passive:true});
      addEventListener('load', e => {
        if (e.target && e.target !== document) notify();
      }, true);
      if (document.fonts) document.fonts.ready.then(notify, notify);
      notify();
    })();
    """#

    private enum SnapshotFailure: Error { case invalidImage, missingResource }
}
