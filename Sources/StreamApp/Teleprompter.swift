import Foundation
import AppKit
import Combine


@MainActor
final class TeleprompterModel: ObservableObject {
    static let contentWidth: CGFloat = 480
    static let lineHeight: CGFloat = 26
    static let transcriptLines = 3
    static let markdownTemplate = """
    <!--
    Write only the words you want to read. Separate cues with --- on its own line.
    Long cues wrap into three-line pages. Right arrow: next. Left arrow: previous.
    **Bold** and *italic* emphasis are supported. These comments are not displayed.
    -->

    Welcome! Today I want to share an idea with you.

    ---

    Start with the most important point.
    **Pause**, then explain why it matters.

    ---

    Thanks for watching. What would you like to explore next?
    """

    @Published private(set) var transcriptPage = NSAttributedString(string: "")
    @Published private(set) var pageIndex = 0
    @Published private(set) var pageCount = 0
    @Published private(set) var transcriptName = ""
    @Published private(set) var error: String?
    @Published private(set) var chatMessages: [TwitchChatFeed.TwitchChatMessage] = []
    @Published private(set) var chatStatus = "Chat off"

    private let session: TwitchSession
    private var feed: TwitchChatFeed?
    private var configuration: StudioConfiguration?
    private var pages: [NSAttributedString] = []
    private var loadedPath = ""
    private var chatGeneration: UInt64 = 0

    init(session: TwitchSession) { self.session = session }

    deinit {
        let activeFeed = feed
        Task { @MainActor in activeFeed?.stop() }
    }

    func configure(_ c: StudioConfiguration) {
        let old = configuration
        configuration = c
        let pathChanged = old?.transcriptPath != c.transcriptPath
        if pathChanged { loadTranscript(path: c.transcriptPath) }

        let shouldChat = c.teleprompterMode == .twitchChat
        let oldChat = old?.teleprompterMode == .twitchChat
        let channelChanged = old?.twitchChatChannel != c.twitchChatChannel
        if shouldChat && (!oldChat || channelChanged) {
            startChat(channel: c.twitchChatChannel)
        } else if !shouldChat && oldChat {
            stopChat()
        }
        if !shouldChat { chatStatus = "Chat off" }
    }

    func nextPage() { guard pageCount > 0 else { return }; pageIndex = min(pageIndex + 1, pageCount - 1); publishPage() }
    func previousPage() { guard pageCount > 0 else { return }; pageIndex = max(pageIndex - 1, 0); publishPage() }
    func restart() { pageIndex = 0; publishPage() }

    func reloadTranscript() {
        loadTranscript(path: configuration?.transcriptPath ?? loadedPath)
    }


    private func loadTranscript(path: String) {
        loadedPath = path
        pageIndex = 0; pages = []; pageCount = 0; transcriptPage = NSAttributedString(string: "")
        transcriptName = path.isEmpty ? "" : URL(fileURLWithPath: path).lastPathComponent
        error = nil
        guard !path.isEmpty else { error = "Choose a Markdown transcript file."; return }
        let url = URL(fileURLWithPath: path)
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            guard (attrs[.type] as? FileAttributeType) == .typeRegular else { throw LoaderError.empty }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_048_577) ?? Data()
            guard data.count <= 1_048_576 else { throw LoaderError.tooLarge }
            guard let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LoaderError.empty }
            pages = paginate(text)
            guard !pages.isEmpty else { throw LoaderError.empty }
            pageCount = pages.count; publishPage()
        } catch let e as LoaderError { error = e.description }
        catch { self.error = "Could not read transcript: \(error.localizedDescription)" }
    }

    private func publishPage() { transcriptPage = pages.isEmpty ? NSAttributedString(string: "") : pages[min(pageIndex, pages.count - 1)] }

    private func startChat(channel: String) {
        stopChat()
        let generation = chatGeneration
        chatMessages = []; chatStatus = "Connecting…"
        let newFeed = TwitchChatFeed(session: session, channel: channel, onEvent: { [weak self] event in
            guard let self, self.chatGeneration == generation else { return }
            self.receive(event)
        }, onStatus: { [weak self] status in
            guard let self, self.chatGeneration == generation else { return }
            self.chatStatus = status
        })
        feed = newFeed; newFeed.start()
    }

    private func stopChat() { chatGeneration &+= 1; feed?.stop(); feed = nil; chatMessages = [] }
    func receive(_ event: TwitchChatFeed.Event) {
        guard configuration?.teleprompterMode == .twitchChat else { return }
        switch event {
        case .message(let message):
            chatMessages.removeAll { $0.id == message.id }
            chatMessages.append(message)
            if chatMessages.count > 6 { chatMessages.removeFirst(chatMessages.count - 6) }
        case .deleteMessage(let id): chatMessages.removeAll { $0.id == id }
        case .clearUser(let userID): chatMessages.removeAll { $0.userID == userID }
        case .clear: chatMessages.removeAll()
        case .channel: break
        }
    }

    private enum LoaderError: Error, CustomStringConvertible {
        case tooLarge, empty
        var description: String { switch self { case .tooLarge: "Transcript is larger than 1 MiB."; case .empty: "Transcript has no readable cues." } }
    }

    private func paginate(_ source: String) -> [NSAttributedString] {
        let sanitized = source.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        let cues = sanitized.components(separatedBy: .newlines).reduce(into: [[String]]()) { result, line in
            let clean = line.trimmingCharacters(in: .whitespaces)
            if clean == "---" { if !result.isEmpty && !(result.last?.isEmpty ?? true) { result.append([]) }; return }
            if result.isEmpty { result.append([]) }
            result[result.count - 1].append(line)
        }.filter { !$0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var output: [NSAttributedString] = []
        for cue in cues {
            output.append(contentsOf: paginateCue(markdown(cue.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))))
        }
        return output
    }

    private func markdown(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let heading = line.range(of: "^\\s{0,3}#{1,6}\\s+", options: .regularExpression)
            let prepared = heading.map { String(line[$0.upperBound...]) }
                ?? line.replacingOccurrences(of: "^\\s*[-*+]\\s+", with: "• ", options: .regularExpression)
            let parsed = (try? AttributedString(markdown: prepared, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(prepared)
            for run in parsed.runs {
                let intent = run.inlinePresentationIntent ?? []
                var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: 18, weight: .regular) : NSFont.systemFont(ofSize: 18)
                if heading != nil || intent.contains(.stronglyEmphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                }
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                result.append(NSAttributedString(string: String(parsed[run.range].characters),
                    attributes: [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: Self.style]))
            }
            if index + 1 < lines.count {
                result.append(NSAttributedString(string: "\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.white, .paragraphStyle: Self.style]))
            }
        }
        return result
    }

    private static let style: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineHeight; p.maximumLineHeight = lineHeight
        p.lineBreakMode = .byWordWrapping
        return p
    }()

    private func paginateCue(_ input: NSAttributedString) -> [NSAttributedString] {
        let storage = NSTextStorage(attributedString: input)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: Self.contentWidth, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let glyphs = layout.glyphRange(for: container)
        var result: [NSAttributedString] = []
        var glyph = glyphs.location
        var pageStart = 0
        var lineCount = 0
        while glyph < NSMaxRange(glyphs) {
            var lineRange = NSRange()
            _ = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
            glyph = NSMaxRange(lineRange)
            lineCount += 1
            if lineCount == Self.transcriptLines || glyph == NSMaxRange(glyphs) {
                let end = NSMaxRange(layout.characterRange(forGlyphRange: lineRange, actualGlyphRange: nil))
                result.append(input.attributedSubstring(from: NSRange(location: pageStart, length: end - pageStart)))
                pageStart = end
                lineCount = 0
            }
        }
        return result
    }
}
