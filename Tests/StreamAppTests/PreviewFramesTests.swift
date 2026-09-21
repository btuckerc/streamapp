import Foundation
import Testing
@testable import StreamApp

struct PreviewFramesTests {
    @Test func closingOnePreviewKeepsTheOtherRequested() {
        let frames = PreviewFrames()
        let menu = NSObject()
        let settings = NSObject()
        frames.requestSurface(ObjectIdentifier(menu), mode: .program)
        frames.requestSurface(ObjectIdentifier(settings), mode: .program)
        frames.requestSurface(ObjectIdentifier(menu), mode: nil)
        #expect(frames.mode == .program)
        frames.requestSurface(ObjectIdentifier(settings), mode: nil)
        #expect(frames.mode == nil)
    }
}
