import AppKit
import Testing
@testable import StreamApp

@MainActor
struct AnnotationInkTests {
    @Test(arguments: [0.0, 1.0])
    func arrowheadIgnoresReleaseReversalButFollowsDeliberateTurn(smoothing: Double) {
        let settings = AnnotationSettings(persist: false)
        settings.strokeWidth = 4; settings.smoothing = smoothing
        let ink = AnnotationInk(settings: settings)
        ink.tool = .arrow
        ink.mouseDown(with: sample(.leftMouseDown, 20, 128))
        for x in stride(from: 30, through: 220, by: 10) {
            ink.mouseDragged(with: sample(.leftMouseDragged, CGFloat(x), 128))
        }
        ink.mouseUp(with: sample(.leftMouseUp, 219, 128, pressure: 0))
        // A right-pointing head has wings behind the tip, not beyond it.
        #expect(columnCoverage(ink, x: 212) > columnCoverage(ink, x: 100))
        #expect(columnCoverage(ink, x: 226) == 0)
        ink.clear()
        draw(ink, points: [CGPoint(x: 20, y: 128), CGPoint(x: 220, y: 128),
                           CGPoint(x: 200, y: 128), CGPoint(x: 180, y: 128)])
        #expect(columnCoverage(ink, x: 187) > columnCoverage(ink, x: 100))
    }

    @Test func straightPenAndArrowMatchFreehandAtTabletPressure() {
        let settings = AnnotationSettings(persist: false)
        settings.strokeWidth = 12; settings.smoothing = 0.5
        settings.holdToStraighten = false
        for tool in [AnnotationOverlay.Tool.pen, .arrow] {
            let ink = AnnotationInk(settings: settings)
            ink.tool = tool
            draw(ink, points: [CGPoint(x: 20, y: 128), CGPoint(x: 220, y: 128)], pressure: 0.25)
            let freehandWidth = columnCoverage(ink, x: 100)
            ink.clear(); ink.toggleStraight()
            draw(ink, points: [CGPoint(x: 20, y: 128), CGPoint(x: 220, y: 128)], pressure: 0.25)
            #expect(columnCoverage(ink, x: 100) == freehandWidth)
            // The width must still respond to pressure, not simply disable it in both modes.
            ink.clear()
            draw(ink, points: [CGPoint(x: 20, y: 128), CGPoint(x: 220, y: 128)], pressure: 1)
            #expect(columnCoverage(ink, x: 100) > freehandWidth)
        }
    }

    @Test func middleButtonHoldStraightensCurrentStrokeButReleaseDoesNotLatchNextStroke() {
        let settings = AnnotationSettings(persist: false)
        settings.strokeWidth = 8; settings.holdToStraighten = true
        let ink = AnnotationInk(settings: settings)
        ink.mouseDown(with: sample(.leftMouseDown, 20, 128))
        ink.mouseDragged(with: sample(.leftMouseDragged, 100, 50))
        ink.mouseDragged(with: sample(.leftMouseDragged, 220, 128))
        #expect(coverageHeight(ink) > 30)
        ink.otherMouseDown(with: sample(.otherMouseDown, 220, 128, button: 2))
        #expect(coverageHeight(ink) <= 8)
        ink.otherMouseUp(with: sample(.otherMouseUp, 220, 128, button: 2))
        ink.mouseUp(with: sample(.leftMouseUp, 220, 128, pressure: 0))
        #expect(coverageHeight(ink) <= 8)
        let straight = bitmapBytes(ink)
        draw(ink, points: [CGPoint(x: 20, y: 128), CGPoint(x: 100, y: 50), CGPoint(x: 220, y: 128)])
        #expect(coverageHeight(ink) > 30)
        ink.undo()
        #expect(bitmapBytes(ink) == straight)
    }

    @Test func rightButtonOpensPickerWithoutClearingInk() {
        let settings = AnnotationSettings(persist: false)
        let ink = AnnotationInk(settings: settings)
        var pickerCount = 0
        ink.onUpperPen = { _ in pickerCount += 1 }
        ink.mouseDown(with: sample(.leftMouseDown, 20, 128))
        ink.mouseDragged(with: sample(.leftMouseDragged, 100, 50))
        #expect(coverageHeight(ink) > 0)
        ink.rightMouseDown(with: sample(.rightMouseDown, 100, 50))
        #expect(pickerCount == 1)
        #expect(coverageHeight(ink) > 0)
        ink.mouseUp(with: sample(.leftMouseUp, 220, 128, pressure: 0))
        #expect(coverageHeight(ink) > 0)
    }

    @Test func unrelatedOtherButtonsAreIgnored() {
        let settings = AnnotationSettings(persist: false)
        settings.holdToStraighten = false
        let ink = AnnotationInk(settings: settings)
        ink.otherMouseDown(with: sample(.otherMouseDown, 20, 128, button: 1))
        ink.otherMouseUp(with: sample(.otherMouseUp, 20, 128, button: 1))
        draw(ink, points: [CGPoint(x: 20, y: 128), CGPoint(x: 100, y: 50), CGPoint(x: 220, y: 128)])
        #expect(coverageHeight(ink) > 30)
    }

    @Test func heldBeforeContactIsTemporaryAndEscapeReleasesIt() {
        let settings = AnnotationSettings(persist: false)
        settings.holdToStraighten = true
        let ink = AnnotationInk(settings: settings)
        let arc = [CGPoint(x: 20, y: 128), CGPoint(x: 100, y: 50), CGPoint(x: 220, y: 128)]
        ink.otherMouseDown(with: sample(.otherMouseDown, 20, 128, button: 2))
        draw(ink, points: arc)
        #expect(coverageHeight(ink) <= 8)
        ink.otherMouseUp(with: sample(.otherMouseUp, 220, 128, button: 2))
        ink.clear()
        draw(ink, points: arc)
        #expect(coverageHeight(ink) > 30)
        ink.clear()
        ink.otherMouseDown(with: sample(.otherMouseDown, 20, 128, button: 2))
        ink.endDrawing() // Escape/Done may happen before the physical button-up arrives.
        draw(ink, points: arc)
        #expect(coverageHeight(ink) > 30)
        ink.clear()
        settings.holdToStraighten = false
        ink.otherMouseDown(with: sample(.otherMouseDown, 20, 128, button: 2))
        ink.otherMouseUp(with: sample(.otherMouseUp, 20, 128, button: 2))
        draw(ink, points: arc)
        #expect(coverageHeight(ink) <= 8)
    }

    @Test func mappedPenButtonsUseMouseEventsNotTabletMasks() {
        let ink = AnnotationInk(settings: AnnotationSettings(persist: false))
        var pickerCount = 0
        ink.onUpperPen = { _ in pickerCount += 1 }
        ink.rightMouseDown(with: sample(.rightMouseDown, 220, 128, mask: [.penLowerSide]))
        #expect(pickerCount == 1)
        ink.rightMouseDown(with: sample(.rightMouseDown, 220, 128, mask: [.penLowerSide]))
        #expect(pickerCount == 1)
        ink.rightMouseUp(with: sample(.rightMouseUp, 220, 128, mask: [.penLowerSide]))
        ink.rightMouseDown(with: sample(.rightMouseDown, 220, 128, mask: [.penLowerSide]))
        #expect(pickerCount == 2)
    }

    @Test func repeatedTabletPacketsDoNotInferPenActions() {
        let settings = AnnotationSettings(persist: false)
        settings.holdToStraighten = true
        let ink = AnnotationInk(settings: settings)
        for _ in 0..<2 { ink.tabletPoint(with: sample(.tabletPoint, 20, 128, mask: [.penLowerSide])) }
        draw(ink, points: [CGPoint(x: 20, y: 128), CGPoint(x: 100, y: 50), CGPoint(x: 220, y: 128)])
        #expect(coverageHeight(ink) > 30)
    }
    @Test func independentPenAndHighlighterColorsSurviveSettingsChanges() {
        let settings = AnnotationSettings(persist: false)
        settings.strokeWidth = 10
        settings.strokeColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        settings.highlighterColor = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
        let ink = AnnotationInk(settings: settings)

        ink.tool = .pen
        draw(ink, points: [CGPoint(x: 64, y: 24), CGPoint(x: 64, y: 232)])
        settings.strokeColor = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        ink.tool = .highlighter
        draw(ink, points: [CGPoint(x: 184, y: 24), CGPoint(x: 184, y: 232)])

        let rep = bitmap(ink)
        let pen = pixel(rep, x: 64, y: 128)
        let highlighter = pixel(rep, x: 184, y: 128)
        #expect(pen.red > 0.8 && pen.green < 0.2 && pen.blue < 0.2)
        #expect(highlighter.red > 0.7 && highlighter.green > 0.7 && highlighter.blue < 0.2)
    }

    @Test func changingStrokeColorDoesNotRecolorAnExistingStroke() {
        let settings = AnnotationSettings(persist: false)
        settings.strokeWidth = 10
        settings.strokeColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let ink = AnnotationInk(settings: settings)

        draw(ink, points: [CGPoint(x: 24, y: 128), CGPoint(x: 112, y: 128)])
        settings.strokeColor = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        draw(ink, points: [CGPoint(x: 144, y: 128), CGPoint(x: 232, y: 128)])

        let rep = bitmap(ink)
        let oldStroke = pixel(rep, x: 72, y: 128)
        let newStroke = pixel(rep, x: 184, y: 128)
        #expect(oldStroke.red > 0.8 && oldStroke.green < 0.2 && oldStroke.blue < 0.2)
        #expect(newStroke.red < 0.2 && newStroke.green < 0.2 && newStroke.blue > 0.8)
    }

    @Test func rectangleFillIsTranslucentAndTransparentFillLeavesInteriorClear() {
        let settings = AnnotationSettings(persist: false)
        settings.strokeWidth = 6
        settings.strokeColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        settings.fillColor = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.5)
        let ink = AnnotationInk(settings: settings)
        ink.tool = .rectangle
        draw(ink, points: [CGPoint(x: 64, y: 64), CGPoint(x: 192, y: 192)])

        let filled = bitmap(ink)
        let interior = pixel(filled, x: 128, y: 128)
        let outline = pixel(filled, x: 64, y: 128)
        #expect(interior.blue > 0.4 && interior.red < 0.1 && interior.green < 0.1)
        #expect(interior.alpha > 0.4 && interior.alpha < 0.6)
        #expect(outline.red > 0.8 && outline.green < 0.2 && outline.blue < 0.2)

        let transparentSettings = AnnotationSettings(persist: false)
        transparentSettings.strokeWidth = 6
        transparentSettings.strokeColor = .systemRed
        transparentSettings.fillColor = .clear
        let transparent = AnnotationInk(settings: transparentSettings)
        transparent.tool = .rectangle
        draw(transparent, points: [CGPoint(x: 64, y: 64), CGPoint(x: 192, y: 192)])
        let clearInterior = pixel(bitmap(transparent), x: 128, y: 128)
        #expect(clearInterior.alpha == 0)
    }

    @Test func objectEraseHitsFilledInteriorButNotTransparentInterior() {
        let filledSettings = AnnotationSettings(persist: false)
        filledSettings.eraseMode = .object
        filledSettings.strokeWidth = 4
        filledSettings.smoothing = 0
        filledSettings.strokeColor = .systemRed
        filledSettings.fillColor = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.5)
        let filled = AnnotationInk(settings: filledSettings)
        filled.tool = .rectangle
        draw(filled, points: [CGPoint(x: 64, y: 64), CGPoint(x: 192, y: 192)])
        filled.tool = .eraser
        draw(filled, points: [CGPoint(x: 128, y: 128), CGPoint(x: 128, y: 128)])
        #expect(pixel(bitmap(filled), x: 128, y: 128).alpha == 0)

        let transparentSettings = AnnotationSettings(persist: false)
        transparentSettings.eraseMode = .object
        transparentSettings.strokeWidth = 4
        transparentSettings.smoothing = 0
        transparentSettings.strokeColor = .systemRed
        transparentSettings.fillColor = .clear
        let transparent = AnnotationInk(settings: transparentSettings)
        transparent.tool = .rectangle
        draw(transparent, points: [CGPoint(x: 64, y: 64), CGPoint(x: 192, y: 192)])
        let before = bitmapBytes(transparent)
        transparent.tool = .eraser
        draw(transparent, points: [CGPoint(x: 128, y: 128), CGPoint(x: 128, y: 128)])
        #expect(bitmapBytes(transparent) == before)
    }

    @Test func localShortcutRequiresExactModifiersAndInvokesOnce() {
        let ink = AnnotationInk(settings: AnnotationSettings(persist: false))
        var keys: [UInt16] = []
        ink.onLocalShortcut = { key, _ in keys.append(key); return true }
        ink.keyDown(with: keySample(8, modifiers: [.control, .option, .command]))
        ink.keyDown(with: keySample(8, modifiers: [.control, .option]))
        #expect(keys == [8])
    }
    
    @Test func objectEraseRemovesTouchedStrokeLeavesUnrelatedStrokeAndUndoRestoresBitmap() {
        let settings = AnnotationSettings(persist: false)
        settings.eraseMode = .object
        settings.strokeWidth = 4
        settings.smoothing = 0
        settings.holdToStraighten = false
        settings.strokeColor = .systemRed
        let ink = AnnotationInk(settings: settings)
        draw(ink, points: [CGPoint(x: 72, y: 24), CGPoint(x: 72, y: 232)])
        draw(ink, points: [CGPoint(x: 184, y: 24), CGPoint(x: 184, y: 232)])
        let before = bitmapBytes(ink)
        ink.tool = .eraser
        draw(ink, points: [CGPoint(x: 72, y: 128), CGPoint(x: 72, y: 128)])
        #expect(columnCoverage(ink, x: 72) == 0)

        #expect(columnCoverage(ink, x: 184) > 0)
        ink.undo()
        #expect(bitmapBytes(ink) == before)
    }

    @Test func sweptObjectEraseHitsThinStrokeBetweenDistantEventEndpoints() {
        let settings = AnnotationSettings(persist: false)
        settings.eraseMode = .object
        settings.strokeWidth = 2
        settings.smoothing = 0
        settings.holdToStraighten = false
        settings.strokeColor = .systemRed
        let ink = AnnotationInk(settings: settings)
        draw(ink, points: [CGPoint(x: 128, y: 24), CGPoint(x: 128, y: 232)])
        ink.tool = .eraser
        draw(ink, points: [CGPoint(x: 40, y: 128), CGPoint(x: 216, y: 128)])
        #expect(columnCoverage(ink, x: 128) == 0)
    }

    @Test func objectEraseTapInHollowEllipseCenterDoesNotEraseOutline() {
        let settings = AnnotationSettings(persist: false)
        settings.eraseMode = .object
        settings.strokeWidth = 4
        settings.smoothing = 0
        settings.holdToStraighten = false
        settings.strokeColor = .systemRed
        settings.fillColor = .clear
        let ink = AnnotationInk(settings: settings)
        ink.tool = .ellipse
        draw(ink, points: [CGPoint(x: 48, y: 48), CGPoint(x: 208, y: 208)])
        let before = bitmapBytes(ink)
        ink.tool = .eraser
        draw(ink, points: [CGPoint(x: 128, y: 128), CGPoint(x: 128, y: 128)])
        #expect(bitmapBytes(ink) == before)
    }

    @Test func objectEraseArrowheadCountsAsStrokeHit() {
        let settings = AnnotationSettings(persist: false)
        settings.eraseMode = .object
        settings.strokeWidth = 12
        settings.smoothing = 0
        settings.holdToStraighten = false
        settings.strokeColor = .systemRed
        let ink = AnnotationInk(settings: settings)
        ink.tool = .arrow
        draw(ink, points: [CGPoint(x: 40, y: 128), CGPoint(x: 200, y: 128)], pressure: 1)
        settings.strokeWidth = 1
        ink.tool = .eraser
        draw(ink, points: [CGPoint(x: 174, y: 143), CGPoint(x: 174, y: 143)])
        #expect(columnCoverage(ink, x: 100) == 0)
    }

    @Test func partialEraseClearsLocalAreaAndUndoRestoresBitmap() {
        let settings = AnnotationSettings(persist: false)
        settings.eraseMode = .partial
        settings.strokeWidth = 4
        settings.smoothing = 0
        settings.holdToStraighten = false
        settings.strokeColor = .systemRed
        let ink = AnnotationInk(settings: settings)
        draw(ink, points: [CGPoint(x: 24, y: 128), CGPoint(x: 232, y: 128)])
        let before = bitmapBytes(ink)
        ink.tool = .eraser
        draw(ink, points: [CGPoint(x: 128, y: 128), CGPoint(x: 128, y: 128)])
        #expect(columnCoverage(ink, x: 128) == 0)
        #expect(columnCoverage(ink, x: 40) > 0)
        ink.undo()
        #expect(bitmapBytes(ink) == before)
    }

    

    private func keySample(_ key: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        TabletInkEvent(kind: .keyDown, point: .zero, force: 0, button: 0, mask: [], key: key, modifiers: modifiers)
    }

    private func sample(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, pressure: Float = 0.5, button: Int = 0, mask: NSEvent.ButtonMask = []) -> NSEvent {
        TabletInkEvent(kind: type, point: CGPoint(x: x, y: y), force: pressure, button: button, mask: mask)
    }
    private func draw(_ ink: AnnotationInk, points: [CGPoint], pressure: Float = 0.5) {
        ink.mouseDown(with: sample(.leftMouseDown, points[0].x, points[0].y, pressure: pressure))
        for point in points.dropFirst() { ink.mouseDragged(with: sample(.leftMouseDragged, point.x, point.y, pressure: pressure)) }
        ink.mouseUp(with: sample(.leftMouseUp, points.last!.x, points.last!.y, pressure: 0))
    }
    private func bitmap(_ ink: AnnotationInk) -> NSBitmapImageRep {
        ink.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 1024, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        ink.draw(ink.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    private func bitmapBytes(_ ink: AnnotationInk) -> Data {
        let rep = bitmap(ink)
        return Data(bytes: rep.bitmapData!, count: 256 * 1024)
    }
    private struct Pixel {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }
    private func pixel(_ rep: NSBitmapImageRep, x: Int, y: Int) -> Pixel {
        let color = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        return Pixel(red: color.redComponent,
                     green: color.greenComponent,
                     blue: color.blueComponent,
                     alpha: color.alphaComponent)
    }


    private func columnCoverage(_ ink: AnnotationInk, x: Int) -> Int {
        let rep = bitmap(ink)
        return (0..<256).filter { rep.bitmapData![$0 * 1024 + x * 4 + 3] > 127 }.count
    }
    private func coverageHeight(_ ink: AnnotationInk) -> Int {
        let rep = bitmap(ink)
        var low = 256, high = -1
        for y in 0..<256 {
            for x in 0..<256 where rep.bitmapData![y * 1024 + x * 4 + 3] > 127 {
                low = min(low, y); high = max(high, y)
            }
        }
        return max(0, high - low + 1)
    }
}

private final class TabletInkEvent: NSEvent {
    let kind: NSEvent.EventType
    let point: CGPoint
    let force: Float
    let button: Int
    let mask: NSEvent.ButtonMask
    let key: UInt16
    let modifiers: NSEvent.ModifierFlags
    init(kind: NSEvent.EventType, point: CGPoint, force: Float, button: Int, mask: NSEvent.ButtonMask, key: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) {
        self.kind = kind; self.point = point; self.force = force; self.button = button; self.mask = mask; self.key = key; self.modifiers = modifiers
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Synthetic event is not archived") }
    override var type: NSEvent.EventType { kind }
    override var modifierFlags: NSEvent.ModifierFlags { modifiers }
    override var keyCode: UInt16 { key }
    override var subtype: NSEvent.EventSubtype {
        [.otherMouseDown, .otherMouseUp, .rightMouseDown, .rightMouseUp].contains(kind) ? .mouseEvent : .tabletPoint
    }
    override var buttonMask: NSEvent.ButtonMask { mask }
    override var locationInWindow: NSPoint { point }
    override var pressure: Float { force }
    override var buttonNumber: Int { button }
}
