import CoreGraphics
import Foundation
import Testing
@testable import StreamApp

struct SceneTransitionTests {
    @Test func interruptedMorphStartsFromVisibleGeometryAndSettlesExactly() {
        var c = StudioConfiguration()
        c.chatOnLeft = true
        let desktop = SceneGeometry(configuration: c)
        c.layout = .justChatting
        let full = SceneGeometry(configuration: c)
        var motion = SceneTransition()
        #expect(motion.sample(target: desktop, now: 0, reduceMotion: false) == desktop)
        #expect(motion.sample(target: full, now: 1, reduceMotion: false) == desktop)
        let middle = motion.sample(target: full, now: 1.14, reduceMotion: false)
        #expect(middle.camera.width > desktop.camera.width && middle.camera.width < full.camera.width)
        #expect(middle.chat.minX > desktop.chat.minX && middle.chat.minX < full.chat.minX)
        #expect(motion.sample(target: desktop, now: 1.14, reduceMotion: false) == middle)
        let returning = motion.sample(target: desktop, now: 1.25, reduceMotion: false)
        #expect(returning.camera.width < middle.camera.width)
        #expect(motion.sample(target: desktop, now: 2, reduceMotion: false) == desktop)
    }

    @Test func reducedMotionCutsEvenDuringAnActiveTransition() {
        var c = StudioConfiguration()
        let desktop = SceneGeometry(configuration: c)
        c.layout = .justChatting
        let full = SceneGeometry(configuration: c)
        var motion = SceneTransition()
        _ = motion.sample(target: desktop, now: 0, reduceMotion: false)
        _ = motion.sample(target: full, now: 1, reduceMotion: false)
        #expect(motion.sample(target: full, now: 1.1, reduceMotion: true) == full)
        #expect(motion.sample(target: full, now: 1.2, reduceMotion: false) == full)
    }

    @Test func disablingChatReclaimsDesktopWithoutMovingCameraOutsideFrame() {
        var c = StudioConfiguration()
        c.chatEnabled = false; c.chatOnLeft = true; c.cameraCorner = .topRight
        let scene = SceneGeometry(configuration: c)
        #expect(scene.desktop == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(scene.chat.width == 0)
        #expect(scene.desktop.contains(scene.camera))
        c.layout = .justChatting
        let full = SceneGeometry(configuration: c)
        #expect(full.camera == scene.desktop)
        #expect(full.chat.width == 0)
    }

    @Test func legacySettingsRetainChoicesAndWindowExclusionsDoNotSurviveRelaunch() throws {
        let data = Data(#"{"layout":"justChatting","cameraEnabled":true,"microphoneGain":0.75,"recordingDirectory":"/tmp/example","streamingEnabled":false}"#.utf8)
        var c = try JSONDecoder().decode(StudioConfiguration.self, from: data)
        #expect(c.layout == .justChatting && c.cameraEnabled)
        #expect(c.microphoneGain == 0.75 && c.recordingDirectory == "/tmp/example")
        #expect(!c.showStreamAppWindows)
        c.showStreamAppWindows = true
        c.chatEnabled = false; c.excludedApplicationIDs = ["example.private"]
        c.excludedWindowIDs = [1234]
        let restored = try JSONDecoder().decode(StudioConfiguration.self, from: JSONEncoder().encode(c))
        #expect(!restored.chatEnabled && restored.excludedApplicationIDs == ["example.private"])
        #expect(restored.excludedWindowIDs.isEmpty)
        #expect(restored.showStreamAppWindows)
    }
}
