import AppKit
import Foundation
import Testing
@testable import StreamApp

@MainActor
struct TeleprompterTests {
    @Test func wrappedPagesPreserveEveryCharacterAndFitThreeLines() throws {
        let source = "Opening\n\n" + String(repeating: "A long cue with café and 日本語. ", count: 30)
            + String(repeating: "unbroken", count: 40) + "\nThe end."
        try withTranscript(source) { model, _ in
            var recovered = ""
            for _ in 0..<model.pageCount {
                let page = model.transcriptPage
                recovered += page.string
                let storage = NSTextStorage(attributedString: page)
                let layout = NSLayoutManager()
                let container = NSTextContainer(size: NSSize(width: 480, height: CGFloat.greatestFiniteMagnitude))
                container.lineFragmentPadding = 0
                layout.addTextContainer(container); storage.addLayoutManager(layout)
                layout.ensureLayout(for: container)
                // TextKit's extra empty fragment after a final newline contains no glyphs.
                layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, _, _ in
                    #expect(rect.maxY <= 78.01)
                }
                model.nextPage()
            }
            #expect(recovered == source)
            #expect(model.pageIndex == model.pageCount - 1)
            model.restart(); model.previousPage()
            #expect(model.pageIndex == 0)
        }
    }

    @Test func markdownCueBoundariesAndEmphasisSurvivePagingAndModeChanges() throws {
        try withTranscript("<!-- instructions -->\n# Opening\n**Bold** and *italic*.\n---\nFinal cue.") { model, url in
            #expect(model.pageCount == 2)
            #expect(model.transcriptPage.string == "Opening\nBold and italic.")
            let font = try #require(model.transcriptPage.attribute(.font, at: 8, effectiveRange: nil) as? NSFont)
            #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
            model.nextPage()
            #expect(model.transcriptPage.string == "Final cue.")
            var c = StudioConfiguration(); c.transcriptPath = url.path; c.teleprompterMode = .off
            model.configure(c)
            c.teleprompterMode = .transcript; c.teleprompterInCapture = true
            model.configure(c)
            #expect(model.transcriptPage.string == "Final cue.")
            #expect(model.pageIndex == 1)
        }
    }

    @Test func failedReloadClearsStaleTranscriptAndSuccessfulReloadRestarts() throws {
        try withTranscript("First\n---\nSecond") { model, url in
            model.nextPage()
            try "Replacement".write(to: url, atomically: true, encoding: .utf8)
            model.reloadTranscript()
            #expect(model.pageIndex == 0)
            #expect(model.transcriptPage.string == "Replacement")
            try Data(repeating: 65, count: 1_048_577).write(to: url)
            model.reloadTranscript()
            #expect(model.pageCount == 0)
            #expect(model.transcriptPage.string.isEmpty)
            #expect(model.error != nil)
            try FileManager.default.removeItem(at: url)
            model.reloadTranscript()
            #expect(model.pageCount == 0)
            #expect(model.error != nil)
        }
    }

    @Test func chatKeepsSixMessagesAndAppliesModerationBeforeModeExit() {
        let model = TeleprompterModel(session: TwitchSession(persist: false))
        var c = StudioConfiguration(); c.teleprompterMode = .twitchChat
        model.configure(c)
        func send(_ id: Int) {
            model.receive(.message(.init(id: "\(id)", userID: id.isMultiple(of: 2) ? "even" : "odd",
                login: "viewer", displayName: "Viewer", color: nil, text: "Message \(id)",
                sourceChannel: nil, timestamp: nil, fragments: [])))
        }
        for id in 1...7 { send(id) }
        #expect(model.chatMessages.map(\.id) == ["2", "3", "4", "5", "6", "7"])
        model.receive(.deleteMessage("4"))
        model.receive(.clearUser("even"))
        #expect(model.chatMessages.map(\.id) == ["3", "5", "7"])
        model.receive(.clear)
        #expect(model.chatMessages.isEmpty)
        send(8)
        c.teleprompterMode = .off
        model.configure(c)
        send(9)
        #expect(model.chatMessages.isEmpty)
    }

    private func withTranscript(_ source: String, body: (TeleprompterModel, URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("md")
        defer { try? FileManager.default.removeItem(at: url) }
        try source.write(to: url, atomically: true, encoding: .utf8)
        let model = TeleprompterModel(session: TwitchSession(persist: false))
        var c = StudioConfiguration(); c.transcriptPath = url.path; c.teleprompterMode = .transcript
        model.configure(c)
        try body(model, url)
    }
}
