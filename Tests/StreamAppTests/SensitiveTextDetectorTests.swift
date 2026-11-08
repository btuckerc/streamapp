import Foundation
import Testing
@testable import StreamApp

struct SensitiveTextDetectorTests {
    private let detector = SensitiveTextDetector()

    private func detected(_ text: String, personal: Bool = true) -> [String] {
        detector.ranges(in: text, hidesPersonalInfo: personal).map { String(text[$0]) }
    }

    @Test func detectsCredentialFamiliesAndWholeAssignments() {
        #expect(!detected("AWS key AKIA" + "IOSFODNN7EXAMPLE").isEmpty)
        #expect(!detected("sk-proj-" + String(repeating: "aB3_", count: 8)).isEmpty)
        #expect(!detected("Authorization: Bearer " + String(repeating: "Q7x", count: 12)).isEmpty)
        #expect(detected("password = hunter2") == ["password = hunter2"])
        #expect(detected("ordinary prose about password safety").isEmpty)
    }

    @Test func hidesTheWholeNameOfIdentifierStyleAssignments() {
        // The name is hidden with its value, so no `typesafe_` or `OPENROUTER_A` prefix survives.
        #expect(detected("typesafe_api_key=7f3a9c2be81d", personal: false) == ["typesafe_api_key=7f3a9c2be81d"])
        let openRouter = "export OPENROUTER_API_KEY=sk-or-v1-" + String(repeating: "9fQ2", count: 6)
        #expect(detected(openRouter, personal: false) == [String(openRouter.dropFirst("export ".count))])
        #expect(detected("STRIPE_SECRET_KEY = sk_livex9Qx9Qx9Qx9Q") == ["STRIPE_SECRET_KEY = sk_livex9Qx9Qx9Qx9Q"])
        #expect(detected("\"client_secret\": \"Zq8vT3mP0xL7cW2nB5yH\",") == ["client_secret\": \"Zq8vT3mP0xL7cW2nB5yH"])
        #expect(detected("aws_secret_access_key = abc/def") == ["aws_secret_access_key = abc/def"])
        // Fast OCR split a key with spaces; whitespace-compacted matching still finds all of it.
        let split = "OPENAI_API_KEY=sk-pro j-Q2xh9Tq7"
        #expect(detector.ocrRanges(in: split, hidesPersonalInfo: false).ranges.contains { String(split[$0]) == split })
        // Real fast-OCR output from a recording: `_` read as a space and `=` as `-`.
        let misread = "typesaf e api_key-7f 3a9c2be81d4e6fa0b5c7d9elf 3a5b7"
        #expect(detector.ocrRanges(in: misread, hidesPersonalInfo: false).ranges.contains { String(misread[$0]) == misread })
    }

    @Test func hidesAnOCRLineFromItsCredentialToTheEnd() {
        // Real fast-OCR output of a synthetic `.env`: a misread `]` ends the regex match inside the value.
        let misread = "type5afe api key-tsk AQf5NSZ16tbg6zKPAFBnCk70DaP] IrKhNtqfRYM ec7f74ea402d70t8253e34ab55"
        let found = detector.ocrRanges(in: misread, hidesPersonalInfo: false)
        #expect(found.endsInCredential)
        #expect(found.ranges.map { String(misread[$0]) } == ["type5afe api key-tsk AQf5NSZ16tbg6zKPAFBnCk70DaP] IrKhNtqfRYM ec7f74ea402d70t8253e34ab55"])
        // One identifier word before the credential is the rest of a split name; other text before it stays.
        let named = "$ OPENROUTER API_KEY=sk-or-v1-9fQ29fQ2 # local"
        #expect(detector.ocrRanges(in: named, hidesPersonalInfo: false).ranges.map { String(named[$0]) } == ["OPENROUTER API_KEY=sk-or-v1-9fQ29fQ2 # local"])
        // Real fast-OCR output with a pointer over the name: the line starts mid-name, so no name
        // matches, and the value's head before OCR's split is hidden from the assignment.
        let cut = "pi key=tsk ofX3Mj 6jCivpabCET7zqLTDbgReWle5klmFurN2 97252abae7b329dc379090a52930395"
        #expect(detector.ocrRanges(in: cut, hidesPersonalInfo: false).ranges.map { String(cut[$0]) } == [String(cut.dropFirst(7))])
        let email = detector.ocrRanges(in: "mail ada@example.com", hidesPersonalInfo: true)
        #expect(email.ranges.count == 1 && !email.endsInCredential, "personal info hides only itself")
        let plain = detector.ocrRanges(in: "ordinary prose about password safety", hidesPersonalInfo: true)
        #expect(plain.ranges.isEmpty && !plain.endsInCredential)
        // Real fast-OCR misreads of small terminal text: `61` for `GI` and `&` for `8` inside a token;
        // `8pi` for `api`, with the value split into short words. The first row of a wrapped key whose
        // value has an `_` before the row ends is hidden past the `_` to the row's end.
        for line in ["61THUB_TOKEN-ghp_DxOWq&OXEMp678cOYIKKnnXLFnBy4DZQvdX9R",
                     "types8fe 8pi key=tsk rUdYwsNKNYGdDpvrz0U jMpr5i99pcraLrSc5QRU ab14fda9dc38ac9b18e3aab3a8",
                     "typesafe_api_key=tsk_ofX3Mj6jCivpabCET7zqLTDbgReW1e5klmFurN2_97252abae7b329dc379090a529",
                     "typesafe_api_key=tsk_ofX3Mj6jCivpabCET7zqLTDbgReW1e5klmFurN2_"] {
            let found = detector.ocrRanges(in: line, hidesPersonalInfo: false)
            #expect(found.ranges.map { String(line[$0]) } == [line] && found.endsInCredential, "\(line)")
        }
        for prose in ["api-key-rotation docs", "password-reset-flow", "secret-manager v2"] {
            #expect(detected(prose, personal: false).isEmpty, "\(prose)")
        }
    }

    @Test func recognizesLabelsWhoseValueIsASeparateLine() {
        let labels = [
            "aws_sec ret_access_key": "aws_sec ret_access_key", "aws_secret_access_key =": "aws_secret_access_key =",
            "'client sec ret": "sec ret", "\"client_secret\":": "\"client_secret\":", "DB PASSWORD": "DB PASSWORD",
            "export OPENROUTER API KEY": "OPENROUTER API KEY", "  let aws access_key": "let aws access_key",
        ]
        for (line, label) in labels {
            #expect(detector.secretLabelRange(in: line).map { String(line[$0]) } == label, "\(line)")
        }
        for line in ["DB PASSWORD=Tr0ub4dor", "password safety and The Quick Brown Fox 2026", "Settings", ""] {
            #expect(detector.secretLabelRange(in: line) == nil, "\(line)")
        }
    }

    /// `to`'s row run from `from`'s end: a hidden line includes the gap back to what it continues.
    private func run(_ from: CGRect, _ to: CGRect) -> CGRect {
        CGRect(x: from.maxX, y: to.minY, width: to.maxX - from.maxX, height: to.height)
    }

    @Test func hidesOnlyTheNearestSameRowLineRightOfALabel() {
        typealias Line = PrivacyScanner.OCRLine
        let label = CGRect(x: 0.05, y: 0.50, width: 0.20, height: 0.03)
        let name = CGRect(x: 0.10, y: 0.50, width: 0.15, height: 0.03)
        let value = CGRect(x: 0.27, y: 0.50, width: 0.30, height: 0.03)
        let farther = CGRect(x: 0.65, y: 0.50, width: 0.10, height: 0.03)
        let nextRow = CGRect(x: 0.27, y: 0.45, width: 0.30, height: 0.03)
        let distant = CGRect(x: 0.70, y: 0.40, width: 0.10, height: 0.03)
        let lines = [Line(box: label, labelBox: name), Line(box: farther), Line(box: value), Line(box: nextRow)]
        #expect(PrivacyScanner.contextualRedactions(lines, aspect: 1) == [run(name, value), name])
        #expect(PrivacyScanner.contextualRedactions([Line(box: label, labelBox: name), Line(box: distant)], aspect: 1).isEmpty)
        #expect(PrivacyScanner.contextualRedactions([Line(box: label), Line(box: value)], aspect: 1).isEmpty)
        // On a 16:9 buffer one text height is 0.5625 as wide: a value 3 heights away still pairs, 5 does not.
        let near = CGRect(x: label.maxX + 3 * 0.03 * 0.5625, y: 0.50, width: 0.2, height: 0.03)
        let far = CGRect(x: label.maxX + 5 * 0.03 * 0.5625, y: 0.50, width: 0.2, height: 0.03)
        #expect(PrivacyScanner.contextualRedactions([Line(box: label, labelBox: name), Line(box: near)], aspect: 0.5625) == [run(name, near), name])
        #expect(PrivacyScanner.contextualRedactions([Line(box: label, labelBox: name), Line(box: far)], aspect: 0.5625).isEmpty)
    }

    @Test func chainsACredentialAlongItsRowAcrossSplitObservations() {
        typealias Line = PrivacyScanner.OCRLine
        func box(_ x: Double, _ width: Double) -> CGRect { CGRect(x: x, y: 0.50, width: width, height: 0.03) }
        // Fast OCR split a value at a misread character: the rest of the row continues it, each part
        // within two text heights of the last; text farther along is other content.
        let key = Line(box: box(0.05, 0.40), secret: box(0.05, 0.40), endsInCredential: true)
        let rest = [box(0.48, 0.20), box(0.725, 0.10), box(0.92, 0.05)]
        #expect(PrivacyScanner.contextualRedactions([key] + rest.map { Line(box: $0) }, aspect: 1) == [run(key.box, rest[0]), run(rest[0], rest[1])])
        // A secret ending before its line's end (an email, a match inside prose) does not chain.
        let inner = Line(box: box(0.05, 0.40), secret: box(0.05, 0.20))
        #expect(PrivacyScanner.contextualRedactions([inner, Line(box: rest[0])], aspect: 1).isEmpty)
        // A label's value chains the same way.
        let label = Line(box: box(0.05, 0.20), labelBox: box(0.05, 0.20))
        let value = box(0.27, 0.18)
        #expect(PrivacyScanner.contextualRedactions([label, Line(box: value), Line(box: rest[0])], aspect: 1)
            == [run(box(0.05, 0.20), value), run(value, rest[0]), box(0.05, 0.20)])
        // A pointer resting on the value splits its row: the text under it, between the parts, is hidden.
        let left = Line(box: box(0.05, 0.30), labelBox: box(0.05, 0.18), endsInCredential: true)
        let right = box(0.37, 0.40)
        #expect(PrivacyScanner.contextualRedactions([left, Line(box: right)], aspect: 1) == [run(left.box, right)])
    }

    @Test func followsAWrappedSecretDownUntilANonTokenLine() {
        typealias Line = PrivacyScanner.OCRLine
        func row(_ y: Double, x: Double = 0.02, width: Double = 0.6) -> CGRect { CGRect(x: x, y: y, width: width, height: 0.03) }
        func seed(_ r: CGRect) -> Line { Line(box: r, secret: r) }
        func token(_ r: CGRect) -> Line { Line(box: r, continuations: [r]) }
        let lines = [
            seed(row(0.60)),
            token(row(0.565)),
            token(row(0.53, width: 0.1)),
            Line(box: row(0.495)),                       // OPENROUTER_API_KEY=…: not a continuation
            token(row(0.46)),
            token(row(0.70)),                            // above the secret
        ]
        #expect(PrivacyScanner.contextualRedactions(lines, aspect: 1) == [row(0.565), row(0.53, width: 0.1)])
        #expect(PrivacyScanner.contextualRedactions([Line(box: row(0.60)), token(row(0.565))], aspect: 1).isEmpty)
        // A wrap restarts at the start of the secret's text: an indented token is other text. Editors
        // break at a hyphen (`OPENROUTER_API_KEY=sk-or-`), so the wrap may be wider than the line above.
        let first = seed(row(0.60, width: 0.3))
        #expect(PrivacyScanner.contextualRedactions([first, token(row(0.565, x: 0.3, width: 0.2))], aspect: 1).isEmpty)
        #expect(PrivacyScanner.contextualRedactions([first, token(row(0.565, width: 0.7))], aspect: 1) == [row(0.565, width: 0.7)])
        // The row starts at a label left of a split value: a short wrap below the label continues the value.
        let value = Line(box: row(0.60, x: 0.25, width: 0.37))
        let label = Line(box: row(0.60, width: 0.2), labelBox: row(0.60, width: 0.2))
        #expect(PrivacyScanner.contextualRedactions([label, value, token(row(0.565, width: 0.2))], aspect: 1)
            == [run(label.box, value.box), row(0.565, width: 0.2), row(0.60, width: 0.2)])
        // Text of a window to the left is not a label, so it does not move the row start left of the
        // secret's column; the wrap below is the token in that column, not the sidebar's text.
        let sidebar = Line(box: CGRect(x: 0.104, y: 0.425, width: 0.014, height: 0.011))
        let key = seed(CGRect(x: 0.140, y: 0.425, width: 0.311, height: 0.016))
        let column = CGRect(x: 0.140, y: 0.404, width: 0.113, height: 0.015)
        let sidebarBelow = token(CGRect(x: 0.104, y: 0.406, width: 0.031, height: 0.009))
        #expect(PrivacyScanner.contextualRedactions([sidebar, key, sidebarBelow, token(column)], aspect: 0.5625) == [column])
        // Lines joined with another window's text: the secret's own box is the geometry, and only the
        // part of the line below inside the secret's window (split at the window edge) is hidden.
        let joined = Line(box: CGRect(x: 0.103, y: 0.487, width: 0.70, height: 0.024),
            secret: CGRect(x: 0.140, y: 0.487, width: 0.31, height: 0.019))
        let hex = CGRect(x: 0.140, y: 0.469, width: 0.202, height: 0.015)
        let prose = Line(box: CGRect(x: 0.103, y: 0.465, width: 0.70, height: 0.024), continuations: [hex])
        #expect(PrivacyScanner.contextualRedactions([joined, prose], aspect: 0.5625) == [hex])
        // A window edge listed a little off splits the remainder in two: both parts are hidden.
        let left = CGRect(x: 0.103, y: 0.469, width: 0.06, height: 0.015), right = CGRect(x: 0.165, y: 0.469, width: 0.18, height: 0.015)
        let split = Line(box: CGRect(x: 0.103, y: 0.465, width: 0.70, height: 0.024), continuations: [left, right])
        #expect(PrivacyScanner.contextualRedactions([joined, split], aspect: 0.5625) == [left, right])
        // Another window's text farther left on the same row does not move the row start.
        let other = Line(box: row(0.60, x: 0.0, width: 0.05))
        let secret = seed(row(0.60, x: 0.3, width: 0.3))
        let wrap = row(0.565, x: 0.3, width: 0.3)
        #expect(PrivacyScanner.contextualRedactions([other, secret, token(wrap)], aspect: 1) == [wrap])
        // A secret box placed too far left by interpolation across joined text: the wrap starting at
        // the window edge, left of the secret's middle, still continues it.
        let skewed = seed(CGRect(x: 0.066, y: 0.487, width: 0.39, height: 0.019))
        let edge = CGRect(x: 0.138, y: 0.466, width: 0.202, height: 0.015)
        #expect(PrivacyScanner.contextualRedactions([skewed, token(edge)], aspect: 0.5625) == [edge])
        // A label ending its line with the value wrapped below hides both; with no wrap, nothing.
        let name = row(0.60, x: 0.02, width: 0.25)
        let trailing = Line(box: row(0.60, width: 0.3), labelBox: name)
        #expect(PrivacyScanner.contextualRedactions([trailing, token(row(0.565, width: 0.4))], aspect: 1) == [row(0.565, width: 0.4), name])
        #expect(PrivacyScanner.contextualRedactions([trailing, Line(box: row(0.565, width: 0.4))], aspect: 1).isEmpty)
        #expect(detector.couldContinueSecret("abe93d495da192419d43e73314dd2e2f204544170ab"))
        #expect(detector.couldContinueSecret("314dd2e2f 204544170ab"), "fast OCR splits hex runs")
        #expect(detector.couldContinueSecret("c2VjcmV0=="))
        #expect(detector.couldContinueSecret("QmFzZTYVGFpbEubHkXq"), "a long mixed-case tail without digits")
        #expect(detector.couldContinueSecret("dledd"), "a wrap's last few characters, misread as letters")
        #expect(!detector.couldContinueSecret("so..."))
        #expect(!detector.couldContinueSecret("NODE_ENV=production"))
        #expect(!detector.couldContinueSecret("13:"), "grep -n style line numbers below a secret")
        #expect(!detector.couldContinueSecret("32: benign terminal output NODE ENV-production"), "a numbered line misread without its `=`")
        #expect(!detector.couldContinueSecret("so I skipped it"))
        #expect(!detector.couldContinueSecret("so I Skipped It Again"), "several OCR words need a digit")
        #expect(!detector.couldContinueSecret("Configuration"))
    }

    @Test func mergesFragmentsOfOneRowAndPadsByTextHeight() {
        // Two fragments of one row 0.5 text heights apart, and the row below.
        let left = CGRect(x: 0.10, y: 0.50, width: 0.20, height: 0.04)
        let right = CGRect(x: 0.32, y: 0.505, width: 0.10, height: 0.04)
        let below = CGRect(x: 0.10, y: 0.455, width: 0.30, height: 0.04)
        let boxes = PrivacyScanner.mergeRows([left, right, below], aspect: 1)
        #expect(boxes.count == 2)
        let row = left.union(right)
        let padded = row.insetBy(dx: -0.4 * row.height, dy: -0.25 * row.height)
        #expect(boxes.contains { abs($0.minX - padded.minX) < 1e-9 && abs($0.maxX - padded.maxX) < 1e-9 && abs($0.maxY - padded.maxY) < 1e-9 })
        #expect(boxes.contains { abs($0.width - (0.30 + 0.8 * 0.04)) < 1e-9 && abs($0.height - 0.06) < 1e-9 })
        // Fragments farther apart than one text height stay separate; padding never leaves the frame.
        let apart = PrivacyScanner.mergeRows([left, CGRect(x: 0.35, y: 0.50, width: 0.1, height: 0.04)], aspect: 1)
        #expect(apart.count == 2)
        let corner = PrivacyScanner.mergeRows([CGRect(x: 0, y: 0, width: 0.1, height: 0.04)], aspect: 1)
        #expect(corner.count == 1 && corner[0].minX == 0 && corner[0].minY == 0)
        #expect(abs(corner[0].maxX - 0.116) < 1e-9 && abs(corner[0].maxY - 0.05) < 1e-9)
    }

    @Test func rejectsNearMissesAndInvalidCards() {
        #expect(detected("git commit " + String(repeating: "a", count: 40)).isEmpty)
        #expect(detected("UUID 123e4567-e89b-12d3-a456-426614174000").isEmpty)
        #expect(detected("version 2026.10.24 and timestamp 12:34:56").isEmpty)
        #expect(detected("card 4111 1111 1111 1112").isEmpty)
        // A path of CamelCase names is long and mixed but not random: a whole OCR line would hide.
        #expect(detected("Sources/StreamApp/PrivacyScanner.swift | 12 ++++++------").isEmpty)
        #expect(!detected("token Zq8vT3mP0xL7cW2nB5yHk9Rr4Tt6Uu1V").isEmpty)
    }

    @Test func personalInformationIsOptional() {
        #expect(!detected("Contact a.person@example.org").isEmpty)
        #expect(detected("Contact a.person@example.org", personal: false).isEmpty)
        for text in ["password = hunter2", "Authorization: Bearer foobar", "https://user:pass@example.org", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig"] {
            #expect(!detected(text, personal: false).isEmpty)
        }
        #expect(!detected("card 4111 1111 1111 1111").isEmpty)
        #expect(detected("card 4111 1111 1111 1112").isEmpty)
    }
}
