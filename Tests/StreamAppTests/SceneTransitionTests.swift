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

    @Test func webcamPunchKeepsItsCornerAndDoesNotDisplaceContent() {
        for corner in CameraCorner.allCases {
            for chatOnLeft in [false, true] {
                var c = StudioConfiguration()
                c.cameraEnabled = true
                c.cameraCorner = corner
                c.chatOnLeft = chatOnLeft
                c.cameraPunchInSize = 0.67
                let normal = SceneGeometry(configuration: c)
                c.cameraPunchIn = true
                let punched = SceneGeometry(configuration: c)
                #expect(punched.desktop == normal.desktop && punched.chat == normal.chat)
                #expect(punched.camera.width == punched.desktop.width * 0.67)
                #expect(abs(punched.camera.width / punched.camera.height - 16.0 / 9) < 0.000001)
                let left = corner == .bottomLeft || corner == .topLeft
                let top = corner == .topLeft || corner == .topRight
                #expect(left ? punched.camera.minX == normal.camera.minX : punched.camera.maxX == normal.camera.maxX)
                #expect(top ? punched.camera.maxY == normal.camera.maxY : punched.camera.minY == normal.camera.minY)
                c.cameraPunchIn = false
                #expect(SceneGeometry(configuration: c) == normal)
                c.cameraSize = 0.4
                c.cameraPunchInSize = 0.9
                c.cameraPunchIn = true
                let capped = SceneGeometry(configuration: c)
                #expect(capped.camera.width == capped.desktop.width * 0.9)
                #expect(capped.desktop.contains(capped.camera))
            }
        }
    }

    @Test func webcamMotionSettlesGentlyAndReversesWithoutJumping() {
        var c = StudioConfiguration()
        c.cameraEnabled = true
        let normal = SceneGeometry(configuration: c)
        c.cameraPunchIn = true
        let punched = SceneGeometry(configuration: c)
        var motion = SceneTransition()
        _ = motion.sample(target: normal, now: 0, reduceMotion: false)
        #expect(motion.sample(target: punched, now: 1, reduceMotion: false) == normal)
        let middle = motion.sample(target: punched, now: 1.3, reduceMotion: false)
        let settling = motion.sample(target: punched, now: 1.5, reduceMotion: false)
        #expect(middle.camera.width > (normal.camera.width + punched.camera.width) / 2)
        #expect(settling.camera.width > middle.camera.width && settling.camera.width < punched.camera.width)
        #expect(settling.desktop == normal.desktop && settling.chat == normal.chat)
        #expect(motion.sample(target: normal, now: 1.5, reduceMotion: false) == settling)
        let returning = motion.sample(target: normal, now: 1.8, reduceMotion: false)
        #expect(returning.camera.width < settling.camera.width && returning.camera.width > normal.camera.width)
        #expect(motion.sample(target: normal, now: 2.2, reduceMotion: false) == normal)
        _ = motion.sample(target: punched, now: 3, reduceMotion: false)
        #expect(motion.sample(target: punched, now: 3.1, reduceMotion: true) == punched)
    }

    @MainActor @Test func webcamPunchCannotReappearAfterCameraOffSceneChangeOrRelaunch() throws {
        let model = StudioModel(demo: true)
        model.configuration.cameraEnabled = true
        model.configuration.cameraPunchInSize = 0.7
        let normal = SceneGeometry(configuration: model.configuration)
        model.toggleCameraPunchIn()
        #expect(SceneGeometry(configuration: model.configuration).camera.width > normal.camera.width)
        let restored = try JSONDecoder().decode(StudioConfiguration.self, from: JSONEncoder().encode(model.configuration))
        #expect(SceneGeometry(configuration: restored) == normal)
        var emphasized = restored
        emphasized.cameraPunchIn = true
        #expect(SceneGeometry(configuration: emphasized).camera.width == normal.desktop.width * 0.7)
        model.configuration.cameraEnabled = false
        model.toggleCameraPunchIn()
        model.configuration.cameraEnabled = true
        #expect(SceneGeometry(configuration: model.configuration) == normal)
        model.toggleCameraPunchIn()
        model.configuration.layout = .justChatting
        model.toggleCameraPunchIn()
        model.configuration.layout = .desktopChat
        #expect(SceneGeometry(configuration: model.configuration) == normal)
        model.toggleCameraPunchIn()
        model.toggleCameraPunchIn()
        #expect(SceneGeometry(configuration: model.configuration) == normal)
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
