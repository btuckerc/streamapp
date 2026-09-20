import AppKit
import WebKit

@MainActor
final class Chat: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let width: CGFloat
    private static let height: CGFloat = 1080

    let webView: WKWebView
    var error: Error?
    private(set) var snapshots = 0
    private let onImage: (CGImage) -> Void
    private var timer: Timer?
    private var ready = false
    private var dirty = true
    private var busy = false
    private var generation: UInt64 = 1
    private var imageScale: Double?
    private var stopped = false
    private var feedTask: Task<Void, Never>?
    private let feedURL: URL?
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

    init(onImage: @escaping (CGImage) -> Void, chatURL: String, width: Int = 384) {
        self.onImage = onImage
        self.width = CGFloat(width)
        self.feedURL = URL(string: chatURL)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: Int(Self.height)), configuration: configuration)
        super.init()
        messageProxy = WeakMessageProxy(self)
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .clear
        // macOS WebKit's snapshot backing otherwise stays opaque even with clear
        // CSS and underPageBackgroundColor. Keep text alpha for the GPU glass panel.
        webView.setValue(false, forKey: "drawsBackground")
        configuration.userContentController.add(messageProxy, name: "chatDirty")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.dirtyScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        if let resource = Bundle.main.url(forResource: "chat", withExtension: "html", subdirectory: "StreamApp_StreamApp.bundle") ?? Bundle.module.url(forResource: "chat", withExtension: "html") {
            webView.loadFileURL(resource, allowingReadAccessTo: resource.deletingLastPathComponent())
        } else {
            error = SnapshotFailure.missingResource
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        timer?.invalidate()
        timer = nil
        feedTask?.cancel(); feedTask = nil
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
        // takes this value in logical points; the resulting CGImage is 384x1080.
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
                // the contract's 384x1080 pixel image.
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
        startFeed()
    }

    private func startFeed() {
        guard feedTask == nil, let url = feedURL, ["http", "https"].contains(url.scheme ?? ""), url.host != nil else { return }
        feedTask = Task { [weak self] in
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            while !Task.isCancelled {
                do {
                    var request = URLRequest(url: url)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    await self?.runScript("window.setStatus('CONNECTED')", arguments: [:])
                    var decoder = SSEDecoder()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if let data = try decoder.append(byte),
                           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            await self?.runScript("window.render(message)", arguments: ["message": object])
                        }
                    }
                } catch { if Task.isCancelled { return } }
                await self?.runScript("window.setStatus('DISCONNECTED · RETRYING')", arguments: [:])
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func runScript(_ script: String, arguments: [String: Any]) async {
        guard !stopped else { return }
        await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { [weak self] result in
                if case .failure(let error) = result { self?.error = error }
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

    // The fixture is DOM-driven. Canvas/GIF/video paint changes are not generic
    // DOM invalidations and require explicit dirty signaling from their renderer.
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
      let raf = 0;
      let lastNotify = -Infinity;
      const pulse = now => {
        raf = 0;
        if (document.getAnimations().some(animation => animation.playState === 'running')) {
          if (now - lastNotify >= 33) { lastNotify = now; notify(); }
          raf = requestAnimationFrame(pulse);
        } else { notify(); }
      };
      const start = () => { notify(); if (!raf) raf = requestAnimationFrame(pulse); };
      const end = notify;
      addEventListener('animationstart', start, true);
      addEventListener('transitionstart', start, true);
      addEventListener('animationend', end, true);
      addEventListener('animationcancel', end, true);
      addEventListener('transitionend', end, true);
      addEventListener('transitioncancel', end, true);
      if (document.fonts) document.fonts.ready.then(notify, notify);
      start();
    })();
    """#

    private enum SnapshotFailure: Error { case invalidImage, missingResource }
}
