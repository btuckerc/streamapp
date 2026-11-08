import Foundation
import CoreImage
import CoreVideo
import CoreText
import Vision
import Testing
@testable import StreamApp

struct PrivacyPipelineTests {
    @Test func pcmDelayExactWraparoundAndFlush() {
        var ring = PCMDelayRing(delaySamples: 4, blockSamples: 2)
        var output = [Float](repeating: 0, count: 2)
        var received: [Float] = []
        for start in stride(from: 0, to: 10, by: 2) {
            let input = [Float(start), Float(start + 1)]
            let count = input.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { ring.append(input, output: $0) }
            }
            if start < 4 { #expect(count == 0) } else { #expect(count == 2) }
            received += output.prefix(count)
        }
        #expect(received == [0, 1, 2, 3, 4, 5])
        while ring.bufferedSamples > 0 {
            let count = output.withUnsafeMutableBufferPointer { ring.flush(into: $0) }
            received += output.prefix(count)
        }
        #expect(received == (0..<10).map(Float.init))
        #expect(output.withUnsafeMutableBufferPointer { ring.flush(into: $0) } == 0)
    }
    @Test func pcmShortSessionFlushesWithoutLeadingSilence() {
        var ring = PCMDelayRing(delaySamples: 10, blockSamples: 2)
        let input: [Float] = [7, 8]
        var output = [Float](repeating: 0, count: 2)
        #expect(input.withUnsafeBufferPointer { input in output.withUnsafeMutableBufferPointer { ring.append(input, output: $0) } } == 0)
        #expect(output.withUnsafeMutableBufferPointer { ring.flush(into: $0) } == 2)
        #expect(output == input)
    }
    @Test func everyCensorStyleHidesTheSourceCompletely() throws {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        // An interior box and one clipped at the source corner. Interior corners may be rounded (they cut
        // only scanner padding, excluded here); the clipped corner must be covered all the way in.
        let box = CGRect(x: 0.2, y: 0.3, width: 0.5, height: 0.3), edge = CGRect(x: 0, y: 0, width: 0.5, height: 0.2)
        let regions = [CGRect(x: 40, y: 30, width: 100, height: 30).insetBy(dx: 8, dy: 6), CGRect(x: 0, y: 0, width: 90, height: 15)]
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let noise = try #require(CIFilter(name: "CIRandomGenerator")?.outputImage).cropped(to: bounds)
        let white = CIImage(color: .white).cropped(to: bounds)
        func pixels(_ image: CIImage) -> [[UInt8]] {
            regions.map { region in
                var bytes = [UInt8](repeating: 0, count: Int(region.width * region.height) * 4)
                context.render(image, toBitmap: &bytes, rowBytes: Int(region.width) * 4, bounds: region, format: .RGBA8, colorSpace: nil)
                return bytes
            }
        }
        for style in PrivacyCensorStyle.allCases {
            for (red, green, blue) in [(0.06, 0.06, 0.06), (1.0, 1.0, 1.0), (0.9, 0.2, 0.1)] {
                var c = StudioConfiguration()
                c.privacyCensorStyle = style; c.privacyCensorRed = red; c.privacyCensorGreen = green; c.privacyCensorBlue = blue
                let fromNoise = pixels(FrameRenderer.redact(noise, rects: [box, edge], configuration: c))
                let fromWhite = pixels(FrameRenderer.redact(white, rects: [box, edge], configuration: c)), raw = pixels(noise)
                for i in regions.indices {
                    #expect(fromNoise[i] == fromWhite[i], "\(style) \(red) region \(i)")
                    #expect(fromNoise[i] != raw[i], "\(style) \(red) region \(i)")
                }
            }
        }
    }
    @Test func guardMaskCoversExactlyItsTilesHowEverFragmented() throws {
        // A checkerboard of single-tile runs (over 140, with holes between) on a canvas whose width and
        // height are not multiples of 16, so the right and bottom tiles are partial.
        let bounds = CGRect(x: 0, y: 0, width: 410, height: 200)
        var tiles: [CGRect] = []
        for row in 0..<13 {
            for column in stride(from: row % 2, to: 26, by: 2) {
                tiles.append(CGRect(x: column * 16, y: row * 16, width: min(16, 410 - column * 16), height: min(16, 200 - row * 16)))
            }
        }
        #expect(tiles.count > 140)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let noise = try #require(CIFilter(name: "CIRandomGenerator")?.outputImage).cropped(to: bounds)
        func pixels(_ image: CIImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 410 * 200 * 4)
            context.render(image, toBitmap: &bytes, rowBytes: 410 * 4, bounds: bounds, format: .RGBA8, colorSpace: nil)
            return bytes
        }
        var c = StudioConfiguration(); c.privacyCensorRed = 0.9; c.privacyCensorGreen = 0.2; c.privacyCensorBlue = 0.1
        // Rendered rows run top-down like the tiles. Inside a tile only the colour shows (within rounding);
        // outside, the source exactly.
        let guarded = pixels(FrameRenderer.guarded(noise, mask: FrameRenderer.guardMask(tiles, extent: bounds), configuration: c))
        let source = pixels(noise), color: [Int] = [229, 51, 26]
        var wrong = 0
        for y in 0..<200 {
            for x in 0..<410 {
                let i = (y * 410 + x) * 4
                if tiles.contains(where: { $0.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) }) {
                    if (0..<3).contains(where: { abs(Int(guarded[i + $0]) - color[$0]) > 1 }) { wrong += 1 }
                } else if guarded[i..<(i + 4)] != source[i..<(i + 4)] { wrong += 1 }
            }
        }
        #expect(wrong == 0)
    }
    @Test func visionDetectsRenderedFakeCredentials() throws {
        let width = 1600, height = 400
        var pixel: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
        let buffer = try #require(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        do {
            let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let font = CTFontCreateWithName("Menlo-Bold" as CFString, 32, nil)
            for (text, y) in [("AKIA" + "IOSFODNN7EXAMPLE", 250), ("sk-proj-" + "aB3cD4eF5gH6iJ7kL8mN9pQ0rS1tU2vW", 100)] {
                let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
                context.textPosition = CGPoint(x: 50, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let aspect = CGFloat(height) / CGFloat(width)
        let rects = PrivacyScanner.redactions(try PrivacyScanner.observe(buffer, hidesPersonalInfo: false), aspect: aspect)
        for y in [100.0, 250.0] {
            let line = CGRect(x: 50.0 / Double(width), y: y / Double(height), width: 0.7, height: 32.0 / Double(height))
            if !rects.contains(where: { $0.intersects(line) }) {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .fast; request.usesLanguageCorrection = false
                try VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
                let recognized = request.results?.compactMap { $0.topCandidates(3).map(\.string).joined(separator: " / ") } ?? []
                #expect(Bool(false), "Missing credential at y=\(y); boxes=\(rects); OCR=\(recognized)")
            }
        }
        // A region rescan (from 420f, as the scanner's history copies are) reports its text in
        // whole-image coordinates, where a whole-image scan put it.
        var converted: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &converted) == kCVReturnSuccess)
        let yuv = try #require(converted)
        CIContext().render(CIImage(cvPixelBuffer: buffer), to: yuv)
        // Two regions, packed side by side into one atlas.
        let regions = [CGRect(x: 0.02, y: 60.0 / Double(height), width: 0.8, height: 100.0 / Double(height)),
                       CGRect(x: 0.02, y: 220.0 / Double(height), width: 0.5, height: 100.0 / Double(height))]
        let partial = PrivacyScanner.redactions(try PrivacyScanner.observe(yuv, hidesPersonalInfo: false, regions: regions), aspect: aspect)
        #expect(partial.count == rects.count && rects.count == 2)
        for whole in rects {
            #expect(partial.contains { abs($0.minX - whole.minX) < 0.01 && abs($0.minY - whole.minY) < 0.02 && abs($0.width - whole.width) < 0.02 },
                    "\(whole) in \(partial)")
        }
    }
    @Test func rescanRegionsNeverCutCachedTextAndFallBackWhenLarge() throws {
        let size = CGSize(width: 1000, height: 1000)
        // A text line (x 0.1–0.6, y 0.53–0.56) cut by the padded region around a change just below it.
        let record = PrivacyScanner.OCRRecord(line: .init(box: CGRect(x: 0.1, y: 0.53, width: 0.5, height: 0.03)), matches: [])
        let regions = try #require(PrivacyScanner.regions(around: [CGRect(x: 100, y: 424, width: 16, height: 16)], records: [record], size: size))
        #expect(regions.count == 1 && regions[0].insetBy(dx: 0.007, dy: 0.007).contains(record.extent))
        #expect(regions[0].minX > 0.05 && regions[0].maxX < 0.7 && regions[0].maxY < 0.62)
        // Atlas boxes map back exactly. One reaching an inner edge of its own slot throws (whole-image
        // read), even where an overlapping region's slot holds the same pixels clear of its edges;
        // one reaching an image border does not.
        var blank: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 1000, 1000, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &blank) == kCVReturnSuccess)
        let atlas = try PrivacyScanner.Atlas([CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.1), CGRect(x: 0.4, y: 0.1, width: 0.1, height: 0.8),
                                              CGRect(x: 0, y: 0, width: 0.2, height: 0.1)], of: try #require(blank))
        let wide = try #require(atlas.slots.first { abs($0.source.width - 0.8) < 0.01 })
        let corner = try #require(atlas.slots.first { abs($0.source.width - 0.2) < 0.01 })
        func place(_ r: CGRect, in slot: (source: CGRect, place: CGRect)) -> CGRect {
            let sx = slot.place.width / slot.source.width, sy = slot.place.height / slot.source.height
            return CGRect(x: slot.place.minX + (r.minX - slot.source.minX) * sx, y: slot.place.minY + (r.minY - slot.source.minY) * sy,
                          width: r.width * sx, height: r.height * sy)
        }
        let inside = CGRect(x: 0.42, y: 0.45, width: 0.06, height: 0.02), boxed = place(inside, in: wide)
        let mapped = try atlas.mapping(for: boxed)(boxed)
        #expect(abs(mapped.minX - inside.minX) < 1e-9 && abs(mapped.minY - inside.minY) < 1e-9 && abs(mapped.maxX - inside.maxX) < 1e-9 && abs(mapped.maxY - inside.maxY) < 1e-9)
        #expect(throws: PrivacyScanner.Atlas.Spill.self) { try atlas.mapping(for: place(CGRect(x: 0.42, y: 0.48, width: 0.06, height: 0.02), in: wide)) }
        _ = try atlas.mapping(for: place(CGRect(x: 0, y: 0, width: 0.1, height: 0.05), in: corner))
        // A moved window's outline stays strips: its interior is never read.
        let outline = [CGRect(x: 200, y: 200, width: 600, height: 16), CGRect(x: 200, y: 784, width: 600, height: 16),
                       CGRect(x: 200, y: 216, width: 16, height: 568), CGRect(x: 784, y: 216, width: 16, height: 568)]
        let strips = try #require(PrivacyScanner.regions(around: outline, records: [], size: size))
        #expect(strips.count == 4 && !strips.contains { $0.contains(CGPoint(x: 0.5, y: 0.5)) })
        #expect(PrivacyScanner.regions(around: [CGRect(x: 0, y: 0, width: 800, height: 800)], records: [], size: size) == nil)
        // Rounding leaves a boundary grown to exactly 8 px from text "near" it: growth must still end.
        let edge = PrivacyScanner.OCRRecord(line: .init(box: CGRect(x: 0.1, y: 0.48, width: 0.5, height: 0.49999999999999994 - 0.48)), matches: [])
        let grown = try #require(PrivacyScanner.regions(around: [CGRect(x: 100, y: 500, width: 16, height: 16)], records: [edge], size: size))
        #expect(grown.count == 1 && grown[0].minY < 0.48 && grown[0].maxY > 0.5)
    }
}
