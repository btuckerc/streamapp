import AppKit
import Testing
@testable import StreamApp

struct AnnotationSettingsTests {
    @MainActor @Test func editingStyleNormalizesWithoutRecursivePublication() throws {
        let settings = AnnotationSettings(persist: false)
        // Published-property normalization must converge, not recursively set forever.
        settings.smoothing = 0.7
        settings.strokeWidth = 12
        settings.strokeColor = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 0.3)
        #expect(settings.smoothing == 0.7)
        #expect(settings.strokeWidth == 12)
        let rgb = try #require(settings.strokeColor.usingColorSpace(.sRGB))
        #expect(abs(rgb.redComponent - 0.2) < 0.001)
        #expect(abs(rgb.blueComponent - 0.8) < 0.001)
        #expect(rgb.alphaComponent == 1)
        settings.smoothing = .nan
        settings.strokeWidth = 100
        #expect(settings.smoothing.isFinite && (0...1).contains(settings.smoothing))
        #expect(settings.strokeWidth == 24)
    }

    @MainActor @Test func toolColorsRemainIndependentAndNormalizeTheirAlpha() throws {
        let settings = AnnotationSettings(persist: false)
        settings.strokeColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.2)
        settings.highlighterColor = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 0.2)
        settings.fillColor = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.5)

        let stroke = try #require(settings.strokeColor.usingColorSpace(.sRGB))
        let highlighter = try #require(settings.highlighterColor.usingColorSpace(.sRGB))
        let fill = try #require(settings.fillColor.usingColorSpace(.sRGB))
        #expect(stroke.alphaComponent == 1)
        #expect(highlighter.alphaComponent == 1)
        #expect(fill.alphaComponent == 0.5)
        #expect(stroke.redComponent == 1 && stroke.blueComponent == 0)
        #expect(highlighter.redComponent == 1 && highlighter.greenComponent == 1)
        #expect(fill.blueComponent == 1 && fill.redComponent == 0)
    }
}
