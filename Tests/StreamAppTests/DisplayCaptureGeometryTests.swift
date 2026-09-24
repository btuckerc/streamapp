import CoreGraphics
import Testing
@testable import StreamApp

struct DisplayCaptureGeometryTests {
    @Test func excludedMenuBarRemovesOnlyTopStrip() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(DisplayCaptureGeometry.crop(display, displayBounds: display, topInset: 33,
                                            includeMenuBar: true, dockHeightFraction: nil) == display)
        #expect(DisplayCaptureGeometry.crop(display, displayBounds: display, topInset: 33,
                                            includeMenuBar: false, dockHeightFraction: nil) == CGRect(x: 0, y: 33, width: 1512, height: 949))
    }

    @Test func dockAndMenuBoundariesIntersectWithoutDoubleCropping() {
        let display = CGRect(x: 100, y: 200, width: 1600, height: 1000)
        let expected = CGRect(x: 100, y: 240, width: 1600, height: 760)
        let cropped = DisplayCaptureGeometry.crop(display, displayBounds: display, topInset: 40,
                                                   includeMenuBar: false, dockHeightFraction: 0.8)
        #expect(cropped == expected)
        #expect(DisplayCaptureGeometry.crop(cropped, displayBounds: display, topInset: 40,
                                            includeMenuBar: false, dockHeightFraction: 0.8) == expected)
    }

    @Test func hiddenMenuAndInvalidInsetsDoNotInventCropping() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        for inset in [CGFloat(0), -1, .nan, .infinity, 1080] {
            #expect(DisplayCaptureGeometry.crop(display, displayBounds: display, topInset: inset,
                                                includeMenuBar: false, dockHeightFraction: nil) == display)
        }
    }
}
