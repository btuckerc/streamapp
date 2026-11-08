import AppKit
import CoreGraphics
import CoreImage
import CoreText
import CoreVideo
import ImageIO
import Testing
import Darwin
@testable import StreamApp

struct PrivacyEvaluation {
    private static let width = 1662
    private static let height = 1080
    private static let scale: CGFloat = 1.0992
    private static let fps = 30
    /// Frames rendered past each scenario so its last scored frames get the scans live capture would give them.
    private static let tail = 24
    private static let key = "typesafe_api_key=tsk_ofX3Mj6jCivpabCET7zqLTDbgReW1e5klmFurN2_97252abae7b329dc379090a52930395cf4218f08b1289aaf9dfbce07e1950e9f"
    private static let openrouter = "OPENROUTER_API_KEY=sk-or-v1-" + String(repeating: "aB3cD4eF", count: 8)
    private static let aws = "aws_secret_access_key = Zq8vT3mP0xL7cW2nB5yHr4Ks9Df1Gj6"

    private struct Cell { let rect: CGRect; let secret: Bool }
    private struct SceneFrame { let frame: ScreenFrame; let cells: [Cell] }
    /// One frame of the synthetic terminal: its lines (text, holds a secret value), window frame in
    /// points, opacity, and content scrolled up by `scroll` points.
    private struct Layout {
        var lines: [(String, Bool)]
        var x: CGFloat = 240, y: CGFloat = 180, w: CGFloat = 1040, h: CGFloat = 620
        var alpha: CGFloat = 1, scroll: CGFloat = 0
        var listed = true, snapshot = true
        var sidebar = false, secondWindow = false
    }
    /// Misses are empty OCR results on changed input; failures publish no result.
    private struct Scenario {
        let name: String; let duration: Int
        var missed: Set<Int> = [], failed: Set<Int> = []
        var phase = 0, completion: Double? = nil
        let make: (Int) -> Layout
    }
    private struct Row: Encodable {
        let scenario: String; let policy: String; let delay: Double
        let leakFrames: Int; let leakCharFrames: Int; let firstLeak: Int?; let lastLeak: Int?
        let benignCovered: Double; let meanArea: Double; let maxArea: Double; let meanExcess: Double; let maxExcess: Double
        let scans: Int; let fullReads: Int; let regionReads: Int; let visionMSPerSecond: Double
        let trackingCPUAvgMS: Double; let trackingWallP95MS: Double; let trackingWallP99MS: Double
        let maxRectangles: Int
        let waitingFrames: Int
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["STREAMAPP_PRIVACY_EVAL"] != nil))
    func evaluate() throws {
        let output = ProcessInfo.processInfo.environment["STREAMAPP_PRIVACY_EVAL"]!
        var rows: [Row] = []
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // STREAMAPP_PRIVACY_EVAL_ONLY=name,name runs a subset of scenarios.
        let only = ProcessInfo.processInfo.environment["STREAMAPP_PRIVACY_EVAL_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        for scenario in scenarios where only?.contains(scenario.name) ?? true {
            let scene = try render(scenario)
            let scans = recognize(scene, scenario: scenario)
            // A no-cover positive control guards against accidentally empty ground truth.
            let positive = metrics(scene, scans: [], policy: "none", delay: 0.5, name: scenario.name)
            #expect(positive.leakFrames > 0, "Ground truth positive control failed for \(scenario.name)")
            for delay in [0.5] {
                for policy in ["current", "boxesOnly", "replacement"] {
                    rows.append(metrics(scene, scans: scans, policy: policy, delay: delay, name: scenario.name))
                }
            }
            // Keep completed scenarios if a long evaluation is interrupted.
            try encoder.encode(rows).write(to: URL(fileURLWithPath: output), options: .atomic)
            // The replacement's first leak, else the middle frame.
            let worst = metrics(scene, scans: scans, policy: "replacement", delay: 0.5, name: scenario.name).firstLeak
            let shown = worst ?? scenario.duration / 2
            try writePNG(scene: scene[shown], covers: covers(scene, shown, scans: scans, policy: "replacement", delay: 0.5),
                name: scenario.name)
        }
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output), options: .atomic)
        print("scenario policy delay leakF leakCF benign% area-mean/max excess-mean/max tracking-cpu-avg/wall-p95/p99-ms rects")
        for r in rows {
            print(String(format: "%@ %@ %.1f %d %d %.3f %.5f/%.5f %.5f/%.5f %.4f/%.4f/%.4f %d",
                r.scenario as NSString, r.policy as NSString, r.delay, r.leakFrames, r.leakCharFrames,
                r.benignCovered * 100, r.meanArea, r.maxArea, r.meanExcess, r.maxExcess,
                r.trackingCPUAvgMS, r.trackingWallP95MS, r.trackingWallP99MS, r.maxRectangles))
        }
    }

    private var scenarios: [Scenario] {
        let staticLines: [(String, Bool)] = [("$ cat .env", false), (Self.key, true), (Self.openrouter, true), (Self.aws, true),
            ("NODE_ENV=production", false), ("# deployment credentials", false)]
        let fade = { (i: Int) -> CGFloat in max(0, i < 6 ? CGFloat(i + 1) / 6 : (i > 173 ? CGFloat(180 - i) / 6 : 1)) }
        return [
            Scenario(name: "static", duration: 180) { _ in Layout(lines: staticLines) },
            Scenario(name: "static-miss", duration: 180, missed: [5, 6]) { _ in Layout(lines: staticLines) },
            Scenario(name: "drag-smooth", duration: 180) { i in Layout(lines: staticLines, x: 120 + 2.2 * CGFloat(min(i, 90))) },
            Scenario(name: "drag-fast", duration: 150) { i in Layout(lines: staticLines, x: 120 + 2.2 * CGFloat(min(i, 18))) },
            Scenario(name: "appear-close", duration: 180) { i in Layout(lines: staticLines, alpha: fade(i)) },
            Scenario(name: "appear-miss", duration: 180, missed: [0]) { i in Layout(lines: staticLines, alpha: fade(i)) },
            Scenario(name: "resize", duration: 180) { i in
                Layout(lines: staticLines, w: 1040 - 6 * CGFloat(min(max(i - 30, 0), 70)))
            },
            Scenario(name: "scroll-slow", duration: 180) { i in Layout(lines: Self.scrollLines(i / 3)) },
            Scenario(name: "scroll-fast", duration: 180) { i in Layout(lines: Self.scrollLines(i)) },
            Scenario(name: "scroll-pixel", duration: 180) { i in Layout(lines: Self.scrollLines(0, count: 120), scroll: 3 * CGFloat(i)) },
            Scenario(name: "scroll-pixel-fast", duration: 180) { i in Layout(lines: Self.scrollLines(0, count: 120), scroll: 12 * CGFloat(i)) },
            Scenario(name: "typing", duration: 180) { i in
                let prefix = "export OPENAI_API_KEY="
                let text = "sk-proj-" + String(repeating: "7cQ9mA2x", count: 8)
                let n = min(text.count, max(0, (i - 30) / 3))
                return Layout(lines: [(prefix + String(text.prefix(n)), n > 0), ("$ echo done", false)])
            }
        ] + [1, 2, 3, 5, 7].enumerated().map { index, count in
            Scenario(name: "flash-\(count)", duration: 150) { i in
                let phase = 30 + index * 19
                let active = i >= phase && i < phase + count
                return Layout(lines: active ? [(Self.key, true)] : [("NODE_ENV=production", false)])
            }
        } + [
            Scenario(name: "adjacent", duration: 180) { _ in Layout(lines: [(Self.key, true), ("NODE_ENV=production", false), ("release build ready", false)]) },
            Scenario(name: "cursor", duration: 180) { _ in Layout(lines: staticLines) },
            // An arrow pointer over the secret rows: sweeping, and resting where scans read it.
            Scenario(name: "cursor-arrow-sweep", duration: 180) { _ in Layout(lines: staticLines) },
            Scenario(name: "cursor-arrow-rest", duration: 180) { _ in Layout(lines: staticLines) },
            Scenario(name: "bare", duration: 120) { _ in Layout(lines: Self.bareLines) },
            Scenario(name: "cursor-arrow-bare-rest", duration: 180) { _ in Layout(lines: Self.bareLines) }
        ] + extraScenarios(staticLines)
    }
    /// Unlabeled tokens alone on their rows.
    private static let bareLines: [(String, Bool)] = [("$ cat notes.txt", false),
        ("ghp_" + "R8kq2LmZ7xVn4Tw9Pb3Hc6Jd1Fs5Gy0Ae2Ku", true),
        ("sk-proj-" + String(repeating: "7cQ9mA2x", count: 6), true),
        ("xoxb-" + "2817364509-7718293045-Zk3mQ8wR5tY1uI9oP4aS6dF2", true)]

    private static func scrollLines(_ offset: Int, count: Int = 18) -> [(String, Bool)] {
        (0..<count).map { i in
            let line = (i + offset) % 60
            switch line { case 12: return (PrivacyEvaluation.key, true); case 31: return (PrivacyEvaluation.openrouter, true)
            case 48: return (PrivacyEvaluation.aws, true); default: return ("\(line): benign terminal output NODE_ENV=production", false) }
        }
    }

    private func extraScenarios(_ lines: [(String, Bool)]) -> [Scenario] {
        var result: [Scenario] = []
        for speed in [0.5, 1.0] {
            result.append(Scenario(name: "scroll-pixel-\(speed)", duration: 96) { i in
                Layout(lines: Self.scrollLines(0, count: 120), scroll: speed * CGFloat(i))
            })
        }
        result += [
            Scenario(name: "scroll-reversal", duration: 120) { i in
                Layout(lines: Self.scrollLines(0, count: 120), scroll: 6 * CGFloat(i < 60 ? i : max(0, 120 - i)))
            },
            Scenario(name: "drag-scroll", duration: 120) { i in
                Layout(lines: Self.scrollLines(0, count: 120), x: 100 + CGFloat(min(i, 90)), scroll: 3 * CGFloat(i))
            },
            Scenario(name: "scroll-sidebar", duration: 96) { i in
                Layout(lines: Self.scrollLines(0, count: 120), scroll: 3 * CGFloat(i), sidebar: true)
            },
            Scenario(name: "scroll-repeated", duration: 96) { i in
                let repeated = (0..<100).map { row in row == 12 || row == 31 ? (Self.key, true) : ("ordinary equal length terminal output", false) }
                return Layout(lines: repeated, scroll: 3 * CGFloat(i))
            },
            Scenario(name: "two-windows", duration: 96) { i in
                Layout(lines: Self.scrollLines(0, count: 120), x: 60, w: 760, scroll: 3 * CGFloat(i), secondWindow: true)
            },
            Scenario(name: "edge-top", duration: 96) { i in
                Layout(lines: [(Self.key, true)] + lines, scroll: 22 + CGFloat(i % 16) / 2)
            },
            Scenario(name: "edge-bottom", duration: 96) { i in
                Layout(lines: Array(repeating: ("ordinary prose", false), count: 19) + [(Self.key, true)],
                    scroll: CGFloat(i) / 2)
            },
            Scenario(name: "resize-widen", duration: 120) { i in
                Layout(lines: lines, w: 620 + 6 * CGFloat(min(i, 70)))
            },
            Scenario(name: "changed-miss-1", duration: 120, missed: [5]) { i in
                Layout(lines: lines + [("counter \(i)", false)], scroll: CGFloat(min(i, 60)) / 2)
            },
            Scenario(name: "changed-miss-2", duration: 120, missed: [5, 6]) { i in
                Layout(lines: lines + [("counter \(i)", false)], scroll: CGFloat(min(i, 60)) / 2)
            },
            Scenario(name: "thrown-scan", duration: 96, failed: [4, 5]) { i in
                Layout(lines: lines + [("counter \(i)", false)])
            },
            Scenario(name: "nil-scan", duration: 96, failed: [4]) { i in
                Layout(lines: lines + [("counter \(i)", false)])
            },
            Scenario(name: "early-owner-gone", duration: 96) { i in
                Layout(lines: lines, x: i < 46 ? 240 : 250, alpha: i < 48 ? 1 : 0, listed: i < 47)
            },
            Scenario(name: "missing-snapshot", duration: 96) { i in
                Layout(lines: lines, snapshot: i < 38 || i > 46)
            },
            Scenario(name: "hide-unhide", duration: 96) { i in
                Layout(lines: lines, alpha: (40..<55).contains(i) ? 0 : 1, listed: !(40..<55).contains(i))
            },
            Scenario(name: "deadline-before", duration: 96, completion: 0.499) { _ in Layout(lines: lines) },
            Scenario(name: "deadline-after", duration: 96, completion: 0.501) { _ in Layout(lines: lines) },
            Scenario(name: "wide-interior-only", duration: 96, failed: [4, 5, 6, 7]) { i in
                Layout(lines: (33..<55).contains(i) ? [(Self.key, true)] : [("ordinary prose", false)])
            }
        ]
        // Eight relative capture phases, including discontinuous one-row-per-frame jumps.
        for phase in 0..<8 {
            result.append(Scenario(name: "scroll-phase-\(phase)", duration: 96, phase: phase) { i in
                Layout(lines: Self.scrollLines(i))
            })
        }
        // The renderer's wrap layout uses 92 cells at this width; runtime infers its own grid.
        let calibration = String(String(repeating: "ordinary prose calibration ", count: 5).prefix(92))
        for count in [1, 2, 4, 8] {
            let wrapped = "TOKEN=" + String(String(repeating: "aB3cD4eF", count: 11).prefix(86)) + String(repeating: "F", count: count)
            result.append(Scenario(name: "wrap-tail-\(count)", duration: 48) { _ in
                Layout(lines: [(calibration, false), (wrapped, true)])
            })
        }
        for (name, following) in [("prose", "ordinary following prose must remain visible"),
                                   ("blank", ""), ("prompt", "$ echo ordinary following prose")] {
            result.append(Scenario(name: "wrap-control-\(name)", duration: 48) { _ in
                Layout(lines: [(calibration, false), ("TOKEN=" + String(String(repeating: "aB3cD4eF", count: 11).prefix(86)), true), (following, false)])
            })
        }
        return result
    }

    private func pixelBuffer() throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferCGImageCompatibilityKey as String: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, Self.width, Self.height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs as CFDictionary, &result) == kCVReturnSuccess,
              let result else { throw NSError(domain: "PrivacyEvaluation", code: 1) }
        return result
    }

    private func render(_ scenario: Scenario) throws -> [SceneFrame] {
        let font = CTFontCreateWithName("Menlo" as CFString, 18 * Self.scale, nil)
        let titleFont = CTFontCreateWithName("Menlo" as CFString, 13 * Self.scale, nil)
        let geometry = CaptureGeometry(size: CGSize(width: Self.width, height: Self.height),
            globalRect: CGRect(x: 0, y: 0, width: Self.width, height: Self.height), tracksWindows: true)
        var result: [SceneFrame] = []; result.reserveCapacity(scenario.duration + Self.tail)
        for i in 0..<(scenario.duration + Self.tail) {
            let layout = scenario.make(i)
            let (lines, xPoints, yPoints, wPoints, hPoints, alpha) = (layout.lines, layout.x, layout.y, layout.w, layout.h, layout.alpha)
            var rgba: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, Self.width, Self.height, kCVPixelFormatType_32BGRA, nil, &rgba) == kCVReturnSuccess, let rgba else { throw NSError(domain: "PrivacyEvaluation", code: 2) }
            CVPixelBufferLockBaseAddress(rgba, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(rgba), width: Self.width, height: Self.height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(rgba), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(CGColor(gray: 0.08, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
            ctx.setFillColor(CGColor(gray: 0.12, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: Self.width, height: 70))
            let wx = xPoints * Self.scale, wy = yPoints * Self.scale, ww = wPoints * Self.scale, wh = hPoints * Self.scale
            let window = CGRect(x: wx, y: CGFloat(Self.height) - wy - wh, width: ww, height: wh)
            ctx.setAlpha(alpha); ctx.setFillColor(CGColor(gray: 0.035, alpha: 1)); ctx.fill(window)
            ctx.setFillColor(CGColor(gray: 0.18, alpha: 1)); ctx.fill(CGRect(x: wx, y: window.maxY - 30 * Self.scale, width: ww, height: 30 * Self.scale))
            ctx.setAlpha(1)
            let chatText = "chat: meeting moved to 3pm — benign conversation"
            let chatY = 90 + CGFloat(i / 15 % 4) * 25
            let chatFont = CTFontCreateWithName("Menlo" as CFString, 17, nil)
            draw(chatText, x: 28, y: chatY, font: chatFont, context: ctx, color: CGColor(gray: 0.68, alpha: 1))
            draw(".env — Terminal", x: wx + 12, y: window.maxY - 21 * Self.scale, font: titleFont, context: ctx, color: CGColor(gray: 1, alpha: 1))
            // Ground truth is each drawn glyph's typographic box (ascent to descent) in top-down pixels.
            // Only the value after `=` is secret; the variable name is neutral, neither secret nor benign.
            var cells = glyphBoxes(chatText, x: 28, baseline: CGFloat(Self.height) - chatY, font: chatFont)
                .filter { !$0.isNull }.map { Cell(rect: $0, secret: false) }
            let lineHeight = 24 * Self.scale
            // Text scrolls inside the content area below the title bar and is clipped to it.
            let sidebarWidth: CGFloat = layout.sidebar ? 180 : 0
            let content = CGRect(x: wx + sidebarWidth, y: wy + 30 * Self.scale, width: ww - sidebarWidth, height: wh - 30 * Self.scale)
            if layout.sidebar {
                for row in 0..<16 {
                    let text = "file_\(row).swift", baseline = window.maxY - 65 - CGFloat(row) * lineHeight
                    draw(text, x: wx + 8, y: baseline, font: font, context: ctx, color: CGColor(gray: 0.65, alpha: 1))
                    cells += glyphBoxes(text, x: wx + 8, baseline: CGFloat(Self.height) - baseline, font: font).filter { !$0.isNull }.map { Cell(rect: $0, secret: false) }
                }
            }
            ctx.setAlpha(alpha)
            ctx.saveGState(); ctx.clip(to: CGRect(x: content.minX, y: window.minY, width: content.width, height: content.height))
            var row = 0
            for line in lines {
                let top = wy + 42 * Self.scale - layout.scroll * Self.scale
                let maxChars = max(1, Int((content.width - 24 * Self.scale) / (CTFontGetSize(font) * 0.61)))
                let valueStart: Int = {
                    guard line.1, let eq = line.0.firstIndex(of: "=") else { return line.1 ? 0 : Int.max }
                    var n = line.0.distance(from: line.0.startIndex, to: eq) + 1
                    while n < line.0.count, line.0[line.0.index(line.0.startIndex, offsetBy: n)] == " " { n += 1 }
                    return n
                }()
                for chunkStart in stride(from: 0, to: line.0.count, by: maxChars) {
                    defer { row += 1 }
                    let rowTop = top + CGFloat(row) * lineHeight
                    guard rowTop + lineHeight > content.minY - lineHeight, rowTop < content.maxY + lineHeight else { continue }
                    let chunk = String(line.0.dropFirst(chunkStart).prefix(maxChars))
                    let lineY = CGFloat(Self.height) - top - CGFloat(row + 1) * lineHeight
                    draw(chunk, x: content.minX + 12 * Self.scale, y: lineY, font: font, context: ctx, color: line.1 ? .white : CGColor(gray: 0.72, alpha: 1))
                    let boxes = glyphBoxes(chunk, x: content.minX + 12 * Self.scale, baseline: CGFloat(Self.height) - lineY, font: font)
                    for (index, glyph) in boxes.enumerated() where !glyph.isNull {
                        let rect = glyph.intersection(content)
                        guard !rect.isEmpty, alpha > 0 else { continue }
                        let charIndex = chunkStart + index
                        if !line.1 { cells.append(Cell(rect: rect, secret: false)) }
                        else if charIndex >= valueStart { cells.append(Cell(rect: rect, secret: true)) }
                    }
                }
            }
            ctx.restoreGState(); ctx.setAlpha(1)
            if scenario.name == "cursor" {
                let cursorX = wx + 90 + CGFloat(i % 90) * 7
                ctx.setStrokeColor(CGColor(gray: 0, alpha: 1)); ctx.setLineWidth(5)
                ctx.move(to: CGPoint(x: cursorX, y: window.maxY - 75)); ctx.addLine(to: CGPoint(x: cursorX, y: window.maxY - 100)); ctx.strokePath()
                ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(2)
                ctx.move(to: CGPoint(x: cursorX, y: window.maxY - 75)); ctx.addLine(to: CGPoint(x: cursorX, y: window.maxY - 100)); ctx.strokePath()
            }
            if scenario.name.hasPrefix("cursor-arrow") {
                // Hotspot in top-down pixels: the rows after the first, across their values.
                let rest = scenario.name.hasSuffix("rest")
                let step = rest ? i / 20 : i / 60, along = rest ? CGFloat(step * 97 % 600) : CGFloat(i % 60) * 10
                let hot = CGPoint(x: wx + 160 * Self.scale + along, y: wy + 42 * Self.scale + (1.5 + CGFloat(step % 3)) * lineHeight)
                let arrow: [CGPoint] = [(0, 0), (0, 17), (4, 13), (7, 20), (9, 19), (6, 12), (11, 12)].map {
                    CGPoint(x: hot.x + $0.0 * Self.scale, y: CGFloat(Self.height) - hot.y - $0.1 * Self.scale)
                }
                ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(1.5)
                ctx.addLines(between: arrow); ctx.closePath(); ctx.drawPath(using: .fillStroke)
            }
            var windows: [WindowSnapshot.Window] = []
            if layout.secondWindow {
                let other = CGRect(x: 1000, y: 520, width: 620, height: 200)
                ctx.setFillColor(CGColor(gray: 0.035, alpha: 1))
                ctx.fill(CGRect(x: other.minX, y: CGFloat(Self.height) - other.maxY, width: other.width, height: other.height))
                let text = "token=Zq8vT3mP0xL7cW2nB5yHr4Ks9Df1Gj6", baseline: CGFloat = 510
                draw(text, x: 1012, y: baseline, font: font, context: ctx, color: .white)
                cells += glyphBoxes(text, x: 1012, baseline: CGFloat(Self.height) - baseline, font: font).enumerated()
                    .filter { $0.offset >= 6 && !$0.element.isNull }.map { Cell(rect: $0.element, secret: true) }
                windows.append(.init(id: 2, frame: other, layer: 0))
            }
            CVPixelBufferUnlockBaseAddress(rgba, [])
            let converted = try convert(rgba)
            let wf = CGRect(x: wx, y: wy, width: ww, height: wh)
            let screen = ScreenFrame(sequence: UInt64(i + 1), captured: Double(i) / Double(Self.fps), buffer: converted,
                windows: layout.snapshot ? WindowSnapshot(windows: windows + (layout.listed ? [WindowSnapshot.Window(id: 1, frame: wf, layer: 0)] : [])) : nil,
                geometry: geometry, epoch: 0)
            result.append(SceneFrame(frame: screen, cells: cells))
        }
        return result
    }

    private func convert(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let ci = CIImage(cvPixelBuffer: source); let context = imageContext
        let result = try pixelBuffer(); context.render(ci, to: result); return result
    }
    private let imageContext = CIContext(options: [.cacheIntermediates: false])

    private func draw(_ text: String, x: CGFloat, y: CGFloat, font: CTFont, context: CGContext, color: CGColor) {
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs)); context.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, context)
    }

    /// One top-down box per character of `text` drawn at `x` on `baseline`; `.null` for spaces.
    private func glyphBoxes(_ text: String, x: CGFloat, baseline: CGFloat, font: CTFont) -> [CGRect] {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        return text.indices.map { index in
            guard text[index] != " " else { return .null }
            let start = text.utf16.distance(from: text.startIndex, to: index)
            let end = start + text[index].utf16.count
            let x0 = CTLineGetOffsetForStringIndex(line, start, nil), x1 = CTLineGetOffsetForStringIndex(line, end, nil)
            return CGRect(x: x + x0, y: baseline - ascent, width: x1 - x0, height: ascent + descent)
        }
    }

    private func recognize(_ scene: [SceneFrame], scenario: Scenario) -> [ScanResult] {
        let scanner = PrivacyScanner(publish: { _ in }), timeline = PrivacyTimeline()
        scanner.recognized = nil
        readStats.completionOffsets.removeAll(); readStats.tracker.reset()
        var scans: [ScanResult] = []; var nextStart = Double(scenario.phase) / 30
        var busyUntil = 0.0, attempt = 0
        var reads: [UInt64: (Bool, Double)] = [:]
        for item in scene {
            let t = item.frame.captured
            if t >= nextStart && t >= busyUntil {
                if scenario.failed.contains(attempt) {
                    attempt += 1; nextStart = t + PrivacyScanner.interval; busyUntil = t
                    continue
                }
                let size = item.frame.geometry.size
                let old = scanner.recognized
                let tiles = old.map { changedTiles(item.frame.buffer, $0.buffer, in: CGRect(origin: .zero, size: size)) } ?? []
                let windows = (item.frame.windows?.windows ?? []).map { w in
                    CGRect(x: w.frame.minX / size.width, y: 1 - w.frame.maxY / size.height,
                        width: w.frame.width / size.width, height: w.frame.height / size.height)
                }
                let start = ProcessInfo.processInfo.systemUptime
                if let rects = scanner.recognize(item.frame, windows: windows, personal: false, revision: 0) {
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    busyUntil = t + (scenario.completion ?? elapsed); nextStart = t + PrivacyScanner.interval
                    if old == nil || !tiles.isEmpty {
                        let region = old != nil && PrivacyScanner.regions(around: tiles, records: old!.records, size: size) != nil
                        reads[item.frame.sequence] = (region, elapsed)
                    }
                    if busyUntil <= t + 1 {
                        let raw = scanner.scanResult(frame: item.frame, rects: scenario.missed.contains(attempt) ? [] : rects)
                        if let published = timeline.complete(raw) { scans.append(published) }
                        readStats.completionOffsets[item.frame.sequence] = busyUntil - t
                    }
                    attempt += 1
                } else { nextStart = t + PrivacyScanner.interval }
            }
        }
        // Kept in a side table by frame sequence for metrics in a separate map.
        readStats.values = reads
        return scans
    }
    private final class ReadStats {
        var values: [UInt64: (Bool, Double)] = [:]
        var completionOffsets: [UInt64: Double] = [:]
        var waiting = false
        let tracker = PrivacyMotionTracker()
    }
    private let readStats = ReadStats()

    /// Covers the renderer would draw for frame `i` when emitting it `delay` after capture: only scans
    /// finished by then exist.
    private func covers(_ scene: [SceneFrame], _ i: Int, scans: [ScanResult], policy: String, delay: Double) -> [CGRect] {
        readStats.waiting = false
        let current = scene[i]
        let available = scans.filter {
            $0.captured + (readStats.completionOffsets[$0.sequence] ?? .infinity) <= current.frame.captured + delay
        }
        if policy == "none" { return [] }
        if policy == "replacement" {
            let plan = PrivacyTimeline.plan(for: current.frame, previous: i > 0 ? scene[i - 1].frame : nil,
                next: i + 1 < scene.count ? scene[i + 1].frame : nil, scans: available, tracker: readStats.tracker)
            readStats.waiting = plan.waiting
            return plan.boxes + plan.uncertainRows + plan.guards
        }
        let plan = PrivacyLegacyEvaluation.plan(for: current.frame, previous: i > 0 ? scene[i - 1].frame : nil,
            next: i + 1 < scene.count ? scene[i + 1].frame : nil, scans: available)
        return policy == "current" ? plan.boxes + plan.guards : plan.boxes
    }

    /// Scores the first `scene.count - tail` frames; the tail only supplies later scans, as live capture would.
    private func metrics(_ scene: [SceneFrame], scans: [ScanResult], policy: String, delay: Double, name: String) -> Row {
        var leaks = 0, leakChars = 0, first: Int?, last: Int?, benignCovered = 0, benignTotal = 0
        var area = 0.0, maxArea = 0.0, excess = 0.0, maxExcess = 0.0
        var cpu = 0.0, durations: [Double] = [], maxRectangles = 0
        var waiting = 0
        func cpuTime() -> Double {
            var t = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
            return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
        }
        let measured = scene.count - Self.tail
        // Each policy run starts cold, as a fresh recording would.
        readStats.tracker.reset()
        for i in 0..<measured {
            let current = scene[i]
            let started = ProcessInfo.processInfo.systemUptime, cpuStarted = cpuTime()
            let drawn = covers(scene, i, scans: scans, policy: policy, delay: delay)
            cpu += cpuTime() - cpuStarted
            durations.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            maxRectangles = max(maxRectangles, drawn.count)
            if readStats.waiting { waiting += 1; continue }
            let secret = current.cells.filter(\.secret), benign = current.cells.filter { !$0.secret }
            let leaked = secret.filter { coverage($0.rect, by: drawn) < 0.9 }.count
            leakChars += leaked
            if leaked > 0 { leaks += 1; first = first ?? i; last = i }
            benignCovered += benign.filter { coverage($0.rect, by: drawn) >= 0.5 }.count
            benignTotal += benign.count
            let (covered, outside) = Self.rasterArea(drawn, gold: secret.map { $0.rect.insetBy(dx: -6, dy: -6) })
            area += covered; maxArea = max(maxArea, covered)
            excess += outside; maxExcess = max(maxExcess, outside)
        }
        let reads = readStats.values
        let full = reads.values.filter { !$0.0 }.count, region = reads.values.filter { $0.0 }.count
        let ms = reads.values.reduce(0.0) { $0 + $1.1 * 1000 } / max(0.001, Double(scene.count) / Double(Self.fps))
        return Row(scenario: name, policy: policy, delay: delay, leakFrames: leaks, leakCharFrames: leakChars,
            firstLeak: first, lastLeak: last, benignCovered: Double(benignCovered) / Double(max(1, benignTotal)),
            meanArea: area / Double(measured), maxArea: maxArea,
            meanExcess: excess / Double(measured), maxExcess: maxExcess,
            scans: scans.count, fullReads: full, regionReads: region, visionMSPerSecond: ms,
            trackingCPUAvgMS: cpu * 1000 / Double(measured),
            trackingWallP95MS: durations.sorted()[min(measured - 1, Int(Double(measured) * 0.95))],
            trackingWallP99MS: durations.sorted()[min(measured - 1, Int(Double(measured) * 0.99))],
            maxRectangles: maxRectangles, waitingFrames: waiting)
    }

    /// Screen fractions covered by the union of `covers`, and covered outside the union of `gold`, on a 4 px grid.
    private static func rasterArea(_ covers: [CGRect], gold: [CGRect]) -> (Double, Double) {
        guard !covers.isEmpty else { return (0, 0) }
        let step = 4, cols = width / step, rows = height / step
        var grid = [UInt8](repeating: 0, count: cols * rows)
        func paint(_ rects: [CGRect], _ bit: UInt8) {
            for r in rects {
                let x0 = max(0, Int(r.minX) / step), x1 = min(cols, Int(r.maxX.rounded(.up)) / step + 1)
                let y0 = max(0, Int(r.minY) / step), y1 = min(rows, Int(r.maxY.rounded(.up)) / step + 1)
                guard x0 < x1, y0 < y1 else { continue }
                for y in y0..<y1 { for x in x0..<x1 { grid[y * cols + x] |= bit } }
            }
        }
        paint(covers, 1); paint(gold, 2)
        var covered = 0, outside = 0
        for v in grid where v & 1 != 0 { covered += 1; if v & 2 == 0 { outside += 1 } }
        return (Double(covered) / Double(grid.count), Double(outside) / Double(grid.count))
    }

    private func coverage(_ rect: CGRect, by boxes: [CGRect]) -> Double {
        let area = rect.width * rect.height
        guard area > 0 else { return 0 }
        // Rectangular union coverage by sweep in x; cells are tiny and policy boxes are few.
        let xs = ([rect.minX, rect.maxX] + boxes.flatMap { [max(rect.minX, $0.minX), min(rect.maxX, $0.maxX)] }).filter { $0 >= rect.minX && $0 <= rect.maxX }.sorted()
        var sum: CGFloat = 0
        for pair in zip(xs, xs.dropFirst()) where pair.1 > pair.0 {
            let mid = (pair.0 + pair.1) / 2
            let spans = boxes.filter { $0.minX <= mid && $0.maxX >= mid && $0.intersects(rect) }.map { (max(rect.minY, $0.minY), min(rect.maxY, $0.maxY)) }.sorted { $0.0 < $1.0 }
            var y: CGFloat = rect.minY, height: CGFloat = 0
            for span in spans { if span.1 > y { height += max(0, span.1 - max(y, span.0)); y = span.1 } }
            sum += (pair.1 - pair.0) * height
        }
        return Double(sum / area)
    }

    private func writePNG(scene: SceneFrame, covers: [CGRect], name: String) throws {
        let url = URL(fileURLWithPath: "/tmp/privacy-eval-\(name).png")
        let image = CIImage(cvPixelBuffer: scene.frame.buffer); let ci = CIContext()
        guard let source = ci.createCGImage(image, from: CGRect(x: 0, y: 0, width: Self.width, height: Self.height)),
              let context = CGContext(data: nil, width: Self.width, height: Self.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "PrivacyEvaluation", code: 3)
        }
        context.draw(source, in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        // Translucent covers over red (secret) and green (benign) ground-truth outlines, to check alignment.
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: CGFloat(Self.height) - r.maxY, width: r.width, height: r.height) }
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 1, alpha: 0.45))
        for rect in covers { context.fill(flip(rect)) }
        context.setLineWidth(1)
        for cell in scene.cells {
            context.setStrokeColor(cell.secret ? CGColor(red: 1, green: 0, blue: 0, alpha: 1) : CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            context.stroke(flip(cell.rect))
        }
        guard let result = context.makeImage() else { throw NSError(domain: "PrivacyEvaluation", code: 4) }
        CGImageDestinationAddImage(destination, result, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "PrivacyEvaluation", code: 5) }
    }
}
