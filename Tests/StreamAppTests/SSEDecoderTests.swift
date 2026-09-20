import Foundation
import Testing
@testable import StreamApp

struct SSEDecoderTests {
    @Test func blankLinesDispatchMultilineEventsWithoutMergingMessages() throws {
        var decoder = SSEDecoder()
        let input = ": keepalive\r\ndata: {\"content\":\r\ndata: \"hello\"}\r\n\r\ndata:{\"content\":\"next\"}\n\n"
        var messages: [[String: String]] = []
        for byte in input.utf8 {
            if let data = try decoder.append(byte) { messages.append(try JSONDecoder().decode([String: String].self, from: data)) }
        }
        #expect(messages == [["content": "hello"], ["content": "next"]])
    }
    @Test func oversizedNetworkLineFailsBeforeUnboundedAllocation() {
        var decoder = SSEDecoder()
        #expect(throws: URLError.self) {
            for _ in 0...65_536 { _ = try decoder.append(65) }
        }
    }
}
