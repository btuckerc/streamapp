import Foundation

struct SensitiveTextDetector {
    private static let patterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END [A-Z ]+PRIVATE KEY(?: BLOCK)?-----)?"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\bgh[pousr]_[A-Za-z0-9_]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\bsk-(?:proj-)?[A-Za-z0-9_-]{16,}\b|\bsk-ant-[A-Za-z0-9_-]{12,}\b"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\b(?:sk|rk)_live_[A-Za-z0-9]{12,}\b"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\bxox[abprs]-[A-Za-z0-9-]{12,}\b|https://hooks\.slack\.com/services/[A-Za-z0-9/_-]+"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\bAIza[A-Za-z0-9_-]{35}\b"#),
        try! NSRegularExpression(pattern: #"\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#),
        try! NSRegularExpression(pattern: #"\bAuthorization\s*:\s*Bearer\s+\S+"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\b[a-z][a-z0-9+.-]*://[^\s/@:]+:[^\s/@]+@[^\s]+"#, options: [.caseInsensitive]),
        // `NAME = value`, or `NAME-value` with a digit in a value of 8+ characters: fast OCR misreads `=` as `-`.
        try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])[A-Za-z0-9_.-]*(?:api[_-]?key|secret|token|password|passwd|pwd|access[_-]?key|private[_-]?key)[A-Za-z0-9_.-]*(?:["']?\s*[:=]\s*["']?[^\s,;"']+|\s*-\s*(?=[A-Za-z0-9_+/]*\d)[A-Za-z0-9_+/]{8,})"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"(?<![\w-])(?:\+?\d[\d ().-]{8,}\d)(?![\w-])"#),
        try! NSRegularExpression(pattern: #"\b\d{3}-\d{2}-\d{4}\b"#),
        try! NSRegularExpression(pattern: #"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#)
    ]
    private static let entropyPattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])[A-Za-z0-9_+/=-]{32,}(?![A-Za-z0-9])"#)
    /// A label such as `aws_secret_access_key =` or `"client_secret":` with no value. Fast OCR
    /// returns the value beside it as a separate observation.
    private static let labelPattern = try! NSRegularExpression(pattern: #"(?:api[_-]?key|secret|token|password|passwd|pwd|access[_-]?key|private[_-]?key)[A-Za-z0-9_.-]*["']?[:=]?["']?$"#, options: [.caseInsensitive])
    private static let secretCount = 11

    func ranges(in line: String, hidesPersonalInfo: Bool = true, includesEntropy: Bool = true) -> [Range<String.Index>] {
        var output = credentialRanges(in: line, includesEntropy: includesEntropy)
        if hidesPersonalInfo { output += personalRanges(in: line) }
        output.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in output {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        return merged
    }

    private func matches(of patterns: ArraySlice<NSRegularExpression>, in line: String) -> [(pattern: Int, range: Range<String.Index>)] {
        guard !line.isEmpty else { return [] }
        let full = NSRange(location: 0, length: (line as NSString).length)
        return patterns.indices.flatMap { index in
            Self.patterns[index].matches(in: line, range: full).compactMap { match in
                guard match.range.location != NSNotFound, let range = Range(match.range, in: line) else { return nil }
                return (index, range)
            }
        }
    }
    private func credentialRanges(in line: String, includesEntropy: Bool) -> [Range<String.Index>] {
        matches(of: Self.patterns[..<Self.secretCount], in: line).map(\.range) + (includesEntropy ? Self.entropyRanges(in: line) : [])
    }
    private func personalRanges(in line: String) -> [Range<String.Index>] {
        matches(of: Self.patterns[Self.secretCount...], in: line).compactMap { match in
            let text = String(line[match.range])
            if match.pattern == 12, Self.digitCount(text) < 10 || Self.digitCount(text) > 12 { return nil }
            if match.pattern == 14, !Self.luhn(text) { return nil }
            return match.range
        }
    }

    /// Fast-OCR glyph confusions, one character for one: a symbol misread inside a token reads as a
    /// token character (`ghp_DxOWq&OXEM`, `PPYth)ig8`), and look-alike digits and symbols read as the
    /// letters of a credential name (`8pi k&y` for `api key`).
    private static let inToken: [Character: Character] = ["&": "x", "@": "x", "$": "x", "|": "x", "!": "x", "(": "x", ")": "x", "[": "x", "]": "x", "{": "x", "}": "x"]
    private static let asLetter: [Character: Character] = ["8": "a", "&": "e", "@": "a", "$": "s", "0": "o", "1": "l", "5": "s", "|": "l", "!": "l"]

    /// What to hide in one fast-OCR line, and whether the line ends in a credential. Credential
    /// patterns also run on the line with misread symbols read as token characters, and — because fast
    /// OCR inserts spaces inside machine-generated text — without whitespace, both as read and with
    /// look-alikes read as letters; matches map back to original characters. A credential is hidden
    /// from its start (taking in one identifier-like word before it, a name OCR split, and back to the
    /// value of an assignment it ends, which OCR split into more words) through the end of the line:
    /// misreads (`_` read as a space, `=` as `-`, a stray `]`) end a match inside its value, and what
    /// follows a credential on its line is more of it.
    func ocrRanges(in line: String, hidesPersonalInfo: Bool) -> (ranges: [Range<String.Index>], endsInCredential: Bool) {
        let personal = hidesPersonalInfo ? personalRanges(in: line) : []
        let all = Array(line.indices), characters = Array(line)
        let kept = characters.indices.filter { !characters[$0].isWhitespace }
        var starts = credentialRanges(in: line, includesEntropy: true).map(\.lowerBound)
        /// Credential starts in `variant` (one character per original character at `positions`).
        func add(_ variant: [Character], at positions: [Int], entropy: Bool) {
            let text = String(variant)
            for range in credentialRanges(in: text, includesEntropy: entropy) where !range.isEmpty {
                // Joining characters can merge clusters (a lone combining mark): skip what no longer maps.
                let offset = text.distance(from: text.startIndex, to: range.lowerBound)
                if offset < positions.count { starts.append(all[positions[offset]]) }
            }
        }
        /// A confusable reads as its replacement only beside a letter, digit or `_`: a lone `$` prompt stays.
        func read(_ map: [Character: Character]) -> (Int) -> Character {
            let beside = { (j: Int) in characters.indices.contains(j) && (characters[j].isLetter || characters[j].isNumber || characters[j] == "_") }
            return { i in map[characters[i]].flatMap { beside(i - 1) || beside(i + 1) ? $0 : nil } ?? characters[i] }
        }
        let token = characters.indices.map(read(Self.inToken))
        if token != characters { add(token, at: Array(characters.indices), entropy: true) }
        let compact = kept.map { token[$0] }, letters = kept.map(read(Self.asLetter))
        if kept.count != characters.count { add(compact, at: kept, entropy: false) }
        if letters != kept.map({ characters[$0] }) { add(letters, at: kept, entropy: false) }
        guard var start = starts.min() else { return (personal, false) }
        let head = line[..<start]
        if head.last?.isWhitespace == true, let end = head.lastIndex(where: { !$0.isWhitespace }) {
            let wordEnd = line.index(after: end)
            let wordStart = head[..<wordEnd].lastIndex { !($0.isLetter || $0.isNumber || "_.-".contains($0)) }.map { line.index(after: $0) } ?? line.startIndex
            if wordStart < wordEnd { start = wordStart }
        }
        // A pointer over the name cuts the line before it (`pi key=tsk ofX3Mj 6jCiv…`), leaving no name
        // match: the value's split-off head (`tsk`) is hidden from the assignment.
        if let op = line[..<start].lastIndex(where: { $0 == "=" || $0 == ":" }),
           line[line.index(after: op)..<start].allSatisfy({ $0.isWhitespace || $0.isLetter || $0.isNumber || "_.+/-".contains($0) }),
           let value = line[line.index(after: op)..<start].firstIndex(where: { !$0.isWhitespace }) {
            start = value
        }
        return (personal + [start..<line.endIndex], true)
    }

    /// The credential label ending a recognized line (`aws_secret_access_key =`, `"client_secret":`)
    /// with no value, or nil. The label is matched on the last two words joined, because fast OCR
    /// splits words (`sec ret`) but prose must not merge; the returned range also takes in one more
    /// identifier-like word to the left so a split name (`OPENROUTER API KEY`) is hidden whole.
    func secretLabelRange(in line: String) -> Range<String.Index>? {
        var words: [Range<String.Index>] = []
        var start: String.Index?
        for index in line.indices {
            if line[index].isWhitespace {
                if let s = start { words.append(s..<index); start = nil }
            } else if start == nil { start = index }
        }
        if let start { words.append(start..<line.endIndex) }
        guard !words.isEmpty else { return nil }
        let tail = words.suffix(2).map { line[$0] }.joined()
        guard Self.labelPattern.firstMatch(in: tail, range: NSRange(location: 0, length: (tail as NSString).length)) != nil else { return nil }
        var first = words.count - min(2, words.count)
        if first > 0, line[words[first - 1]].allSatisfy({ $0.isLetter || $0.isNumber || "_.-".contains($0) }) { first -= 1 }
        return words[first].lowerBound..<words[words.count - 1].upperBound
    }

    /// True for a line that could be the wrapped remainder of a secret: one token once the spaces fast
    /// OCR inserts are removed, not itself an assignment (`NAME=value`; trailing base64 `=` padding is
    /// allowed) nor holding a label or line number (`13:`, `Error: …`), and either holding a digit or, when
    /// OCR saw a single word, at least 12 characters of mixed case or at most 8 letters and digits (a
    /// wrap's last few characters, often all letters), so a prose line stops the chain.
    func couldContinueSecret(_ line: String) -> Bool {
        let words = line.split(whereSeparator: \.isWhitespace)
        let token = words.joined()
        guard !token.isEmpty, !words.contains(where: { $0.last == ":" }),
              !token.trimmingCharacters(in: CharacterSet(charactersIn: "=")).contains("=") else { return false }
        if token.contains(where: \.isNumber) { return true }
        guard words.count == 1 else { return false }
        if token.count <= 8 { return token.allSatisfy { $0.isLetter || $0.isNumber } }
        return token.count >= 12 && token.contains(where: \.isLowercase) && token.dropFirst().contains(where: \.isUppercase)
    }

    private static func digitCount(_ value: String) -> Int { value.reduce(0) { $0 + ($1.isNumber ? 1 : 0) } }
    private static func luhn(_ value: String) -> Bool {
        let digits = value.filter(\.isNumber).compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            let doubled = offset % 2 == 1 ? digit * 2 : digit
            sum += doubled > 9 ? doubled - 9 : doubled
        }
        return sum % 10 == 0
    }
    /// Random-looking tokens: 32+ token characters of three character classes with at least two digits
    /// (a path of CamelCase names has none), high entropy, and not a hex digest or UUID.
    private static func entropyRanges(in line: String) -> [Range<String.Index>] {
        let ns = line as NSString
        return Self.entropyPattern.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let range = Range(match.range, in: line) else { return nil }
            let text = String(line[range])
            let classes = [text.contains(where: \.isLowercase), text.contains(where: \.isUppercase), text.contains(where: \.isNumber), text.contains(where: { !($0.isLetter || $0.isNumber) })].filter { $0 }.count
            guard classes >= 3, Self.digitCount(text) >= 2, !Self.isHexDigest(text), !Self.isUUID(text), Self.entropy(text) >= 3.6 else { return nil }
            return range
        }
    }
    private static func entropy(_ value: String) -> Double {
        let counts = value.reduce(into: [Character: Int]()) { $0[$1, default: 0] += 1 }
        return counts.values.reduce(0.0) { total, count in
            let p = Double(count) / Double(value.count)
            return total - p * log2(p)
        }
    }
    private static func isHexDigest(_ value: String) -> Bool { value.count == 40 && value.allSatisfy(\.isHexDigit) }
    private static func isUUID(_ value: String) -> Bool { value.count == 36 && value.filter { $0 == "-" }.count == 4 }
}
