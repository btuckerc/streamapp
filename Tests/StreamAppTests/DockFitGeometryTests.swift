import CoreGraphics
import Testing
@testable import StreamApp

struct DockFitGeometryTests {
    @Test func chatReducesDockTargetAndImpossibleHeightStopsAtMinimum() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 1200)
        var c = StudioConfiguration()
        c.chatEnabled = false
        let withoutChat = SceneGeometry(configuration: c).desktop
        c.chatEnabled = true
        let withChat = SceneGeometry(configuration: c).desktop
        let plainTarget = DockCanvasFit.targetReservedHeight(frame: frame, desktopAspect: withoutChat.width / withoutChat.height)
        let chatTarget = DockCanvasFit.targetReservedHeight(frame: frame, desktopAspect: withChat.width / withChat.height)
        #expect(plainTarget == 349.5)
        #expect(chatTarget == 136.875)
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(DockCanvasFit.targetReservedHeight(frame: laptop, desktopAspect: withChat.width / withChat.height) == 0)
    }

    @Test func changingDockHeightPreservesWholeDesktopAndDoesNotCropOtherSources() {
        let full = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let before = DockCaptureRegion(displayID: 1, heightFraction: 854.0 / 982)
        let after = DockCaptureRegion(displayID: 1, heightFraction: 900.0 / 982)
        let first = before.crop(full, selectedDisplayID: 1, windowID: nil)
        let second = after.crop(full, selectedDisplayID: 1, windowID: nil)
        #expect(abs(first.height - 854) < 0.001)
        #expect(abs(second.height - 900) < 0.001)
        #expect(first.width == full.width && second.width == full.width)
        #expect(first.minY == full.minY && second.minY == full.minY)
        #expect(after.crop(full, selectedDisplayID: 2, windowID: nil) == full)
        #expect(after.crop(full, selectedDisplayID: 1, windowID: 42) == full)
    }
}
