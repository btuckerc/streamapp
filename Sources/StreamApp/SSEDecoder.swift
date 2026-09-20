import Foundation

/// SSE framing must preserve blank lines; AsyncBytes.lines may discard them.
struct SSEDecoder {
    private var line = Data()
    private var event = Data()
    private static let prefix = Data("data:".utf8)
    private let limit = 65_536

    mutating func append(_ byte: UInt8) throws -> Data? {
        guard byte == 10 else {
            guard line.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            line.append(byte); return nil
        }
        if line.last == 13 { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            guard !event.isEmpty else { return nil }
            event.removeLast() // SSE joins data fields with a newline, excluding the last.
            let result = event
            event.removeAll(keepingCapacity: true)
            return result
        }
        if line.starts(with: Self.prefix) {
            var value = line.dropFirst(5)
            if value.first == 32 { value = value.dropFirst() }
            guard event.count + value.count + 1 <= limit else { throw URLError(.dataLengthExceedsMaximum) }
            event.append(contentsOf: value); event.append(10)
        }
        return nil
    }
}
