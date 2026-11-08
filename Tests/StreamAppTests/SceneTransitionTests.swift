import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import StreamApp

struct SceneTransitionTests {
    @Test func interruptedMorphStartsFromVisibleGeometryAndSettlesExactly() {
        var c = StudioConfiguration()
        c.chatOnLeft = true; c.cameraEnabled = true
        let desktop = SceneGeometry(configuration: c)
        c.layout = .justChatting
        let full = SceneGeometry(configuration: c)
        var motion = SceneTransition()
        #expect(motion.sample(target: desktop, now: 0) == desktop)
        #expect(motion.sample(target: full, now: 1) == desktop)
        let middle = motion.sample(target: full, now: 1.14)
        #expect(middle.camera.width > desktop.camera.width && middle.camera.width < full.camera.width)
        #expect(middle.chat.minX > desktop.chat.minX && middle.chat.minX < full.chat.minX)
        #expect(motion.sample(target: desktop, now: 1.14) == middle)
        let returning = motion.sample(target: desktop, now: 1.25)
        #expect(returning.camera.width < middle.camera.width)
        #expect(motion.sample(target: desktop, now: 2) == desktop)
    }

    /// Chat follows the layout a beat later, and turning it off or on slides it out of or into
    /// the frame at full size instead of squeezing it.
    @Test func chatFollowsTheLayoutAndSlidesInAndOutAtFullSize() {
        var c = StudioConfiguration()
        let on = SceneGeometry(configuration: c)
        c.chatEnabled = false
        let off = SceneGeometry(configuration: c)
        #expect(off.chat.size == on.chat.size && !off.chat.intersects(SceneGeometry.canvas))
        var motion = SceneTransition()
        _ = motion.sample(target: on, now: 0)
        _ = motion.sample(target: off, now: 1)
        let leaving = motion.sample(target: off, now: 1.04)
        #expect(leaving.desktop.width > on.desktop.width && leaving.chat == on.chat)
        let sliding = motion.sample(target: off, now: 1.2)
        #expect(sliding.chat.size == on.chat.size && sliding.chat.minX > on.chat.minX && sliding.chat.minX < off.chat.minX)
        #expect(motion.sample(target: off, now: 1.6) == off)
    }

    /// Privacy never animates: the Away card covers on the next frame and a hidden webcam is gone,
    /// while chat keeps moving beside them.
    @Test func awayCoversAtOnceAndSettlesThenLiftsOffTheSceneAlreadyInPlace() {
        var c = StudioConfiguration()
        c.cameraEnabled = true
        let desktop = SceneGeometry(configuration: c)
        c.layout = .away
        let away = SceneGeometry(configuration: c)
        var motion = SceneTransition()
        _ = motion.sample(target: desktop, now: 0)
        let landed = motion.sample(target: away, now: 1)
        #expect(landed.away == 1 && landed.awaySettle == 1 && !landed.showsCamera && landed.chat == desktop.chat)
        let settling = motion.sample(target: away, now: 1.2)
        #expect(settling.away == 1 && settling.awaySettle > 0 && settling.awaySettle < 1)
        #expect(settling.chat != desktop.chat && settling.chat != away.chat)
        #expect(motion.sample(target: away, now: 2) == away)
        // Leaving, the desktop and webcam are already where they belong; the card lifts, accelerating.
        let lifting = motion.sample(target: desktop, now: 3)
        #expect(lifting.away == 1 && lifting.desktop == desktop.desktop && lifting.camera == desktop.camera)
        let early = motion.sample(target: desktop, now: 3.1), late = motion.sample(target: desktop, now: 3.25)
        #expect(1 - early.away < late.away - 0 && early.away > late.away && late.away > 0)
        #expect(motion.sample(target: desktop, now: 4) == desktop)
        // A webcam turned off mid-move vanishes at once while the rest keeps moving.
        c.layout = .sideBySide
        let split = SceneGeometry(configuration: c)
        _ = motion.sample(target: split, now: 5)
        c.cameraEnabled = false
        let hidden = motion.sample(target: SceneGeometry(configuration: c), now: 5.1)
        #expect(!hidden.showsCamera && hidden.sidebar != split.sidebar)
    }

    /// A scene chosen while the Away card is lifting moves on from what is already uncovered.
    @Test func aSceneChosenWhileAwayLiftsMovesOnFromWhatIsVisible() {
        var c = StudioConfiguration()
        c.cameraEnabled = true
        let desktop = SceneGeometry(configuration: c)
        c.layout = .away
        let away = SceneGeometry(configuration: c)
        c.layout = .sideBySide
        let split = SceneGeometry(configuration: c)
        var motion = SceneTransition()
        _ = motion.sample(target: away, now: 0)
        _ = motion.sample(target: desktop, now: 1)
        let lifting = motion.sample(target: desktop, now: 1.2)
        #expect(lifting.away > 0 && lifting.away < 1 && lifting.desktop == desktop.desktop)
        let turned = motion.sample(target: split, now: 1.2)
        #expect(turned.desktop == desktop.desktop && turned.away == lifting.away)
        let moving = motion.sample(target: split, now: 1.3)
        #expect(moving.desktop.width < desktop.desktop.width && moving.desktop.width > split.desktop.width && moving.away < lifting.away)
        #expect(motion.sample(target: split, now: 2.2) == split)
    }

    /// Chat that is off waits out of sight, and moving between scenes it never crosses the frame.
    @Test func parkedChatNeverCrossesTheFrame() {
        for chatOnLeft in [false, true] {
            var c = StudioConfiguration()
            c.cameraEnabled = true; c.chatEnabled = false; c.chatOnLeft = chatOnLeft
            var motion = SceneTransition()
            var now = 0.0
            for layout in [SceneLayout.sideBySide, .justChatting, .desktopChat, .sideBySide, .away, .desktopChat, .justChatting, .sideBySide] {
                c.layout = layout
                let target = SceneGeometry(configuration: c)
                for _ in 0..<30 {
                    #expect(!motion.sample(target: target, now: now).chat.intersects(SceneGeometry.canvas), "\(layout), left: \(chatOnLeft)")
                    now += 1.0 / 30
                }
            }
        }
    }

    @Test func disablingChatReclaimsDesktopWithoutMovingCameraOutsideFrame() {
        var c = StudioConfiguration()
        c.chatEnabled = false; c.chatOnLeft = true; c.cameraEnabled = true; c.cameraAnchor = CameraAnchor(x: 1, y: 0)
        let scene = SceneGeometry(configuration: c)
        #expect(scene.desktop == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(!scene.chat.intersects(SceneGeometry.canvas))
        #expect(scene.desktop.contains(scene.camera))
        c.layout = .justChatting
        let full = SceneGeometry(configuration: c)
        #expect(full.camera == scene.desktop)
        #expect(!full.chat.intersects(SceneGeometry.canvas))
    }

    /// The chat page is drawn at its slot's exact size in every scene, so its text is never scaled.
    @Test func chatPageMatchesItsSlotAndHandsOverAsThePanelResizes() {
        var c = StudioConfiguration()
        c.cameraEnabled = true; c.chatWidth = 384
        #expect(SceneGeometry.chatSize(c) == CGSize(width: 384, height: 1080))
        c.layout = .sideBySide
        let split = SceneGeometry.chatSize(c)
        #expect(split == CGSize(width: 560, height: 705))
        c.chatEnabled = false
        #expect(SceneGeometry.chatSize(c) == split)
        c.layout = .justChatting; c.chatEnabled = true
        #expect(SceneGeometry.chatSize(c) == CGSize(width: 384, height: 1032))
        let column = CGSize(width: 384, height: 1080)
        #expect(FrameRenderer.handover(from: column, to: split, at: column) == 0)
        #expect(FrameRenderer.handover(from: column, to: split, at: CGSize(width: 472, height: 892.5)) == 0.5)
        #expect(FrameRenderer.handover(from: column, to: split, at: split) == 1)
        // A page a pixel short of an odd slot height (WebKit rounds in points) still takes over.
        #expect(FrameRenderer.handover(from: column, to: CGSize(width: 560, height: 704), at: split) == 1)
        #expect(FrameRenderer.handover(from: split, to: split, at: column) == 1)
    }
    @Test func desktopWebcamFramesChangeCropGeometryWithoutAffectingFullCamera() {
        var c = StudioConfiguration()
        c.cameraEnabled = true
        c.chatEnabled = false
        let wide = SceneGeometry(configuration: c)
        #expect(abs(wide.camera.width / wide.camera.height - 16.0 / 9) < 0.000001)

        c.cameraFrame = .square
        let square = SceneGeometry(configuration: c)
        #expect(square.camera.width == square.camera.height)
        #expect(square.camera.height == square.desktop.height * 0.25)

        c.cameraPunchIn = true
        c.cameraPunchInSize = 0.5
        let punchedSquare = SceneGeometry(configuration: c)
        #expect(punchedSquare.camera.height == punchedSquare.desktop.height * 0.5)
        #expect(punchedSquare.camera.width == punchedSquare.camera.height)

        c.cameraFrame = .circle
        let punchedCircle = SceneGeometry(configuration: c)
        #expect(punchedCircle.camera == punchedSquare.camera)
        #expect(punchedCircle.desktop.contains(punchedCircle.camera))

        c.cameraPunchIn = false
        let circle = SceneGeometry(configuration: c)
        #expect(circle.camera == square.camera)


        c.layout = .justChatting
        #expect(SceneGeometry(configuration: c).camera == circle.desktop)
    }


    @Test func webcamPunchKeepsItsCornerAndDoesNotDisplaceContent() {
        for corner in [CameraPreset.topLeft, .topRight, .bottomLeft, .bottomRight] {
            for chatOnLeft in [false, true] {
                var c = StudioConfiguration()
                c.cameraEnabled = true
                c.cameraAnchor = corner.anchor
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
        #expect(normal.camera.width == normal.desktop.width * 0.25)
        var motion = SceneTransition()
        #expect(punched.camera.width == punched.desktop.width * 0.5)
        _ = motion.sample(target: normal, now: 0)
        #expect(motion.sample(target: punched, now: 1) == normal)
        let middle = motion.sample(target: punched, now: 1.3)
        let settling = motion.sample(target: punched, now: 1.5)
        #expect(middle.camera.width > (normal.camera.width + punched.camera.width) / 2)
        #expect(settling.camera.width > middle.camera.width && settling.camera.width < punched.camera.width)
        #expect(settling.desktop == normal.desktop && settling.chat == normal.chat)
        #expect(motion.sample(target: normal, now: 1.5) == settling)
        let returning = motion.sample(target: normal, now: 1.8)
        #expect(returning.camera.width < settling.camera.width && returning.camera.width > normal.camera.width)
        #expect(motion.sample(target: normal, now: 2.2) == normal)
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
        #expect(!c.showStreamAppWindows && !c.microphoneNoiseReductionEnabled)
        c.showStreamAppWindows = true
        c.chatEnabled = false; c.excludedApplicationIDs = ["example.private"]
        c.excludedWindowIDs = [1234]
        let restored = try JSONDecoder().decode(StudioConfiguration.self, from: JSONEncoder().encode(c))
        #expect(!restored.chatEnabled && restored.excludedApplicationIDs == ["example.private"])
        #expect(restored.excludedWindowIDs.isEmpty)
        #expect(restored.showStreamAppWindows)
        c.cameraFrame = .circle
        let styled = try JSONDecoder().decode(StudioConfiguration.self, from: JSONEncoder().encode(c))
        #expect(styled.cameraFrame == .circle)
    }

    @Test func splitStacksCameraOverChatInAColumnBesideTheDesktop() {
        var c = StudioConfiguration()
        c.layout = .sideBySide; c.cameraEnabled = true
        let split = SceneGeometry(configuration: c)
        #expect(split.sidebar.width == SceneGeometry.sidebarWidth && split.sidebar.maxX == 1920)
        #expect(split.desktop.minX == 0 && split.desktop.maxX == split.sidebar.minX && split.desktop.height == 1080)
        #expect(split.sidebar.contains(split.camera) && split.sidebar.contains(split.chat))
        #expect(!split.camera.intersects(split.chat) && split.camera.minY > split.chat.maxY)
        #expect(abs(split.camera.width / split.camera.height - 16.0 / 9) < 0.000001)

        c.chatOnLeft = true
        let left = SceneGeometry(configuration: c)
        #expect(left.sidebar.minX == 0 && left.desktop.minX == left.sidebar.maxX)

        c.chatEnabled = false
        let portrait = SceneGeometry(configuration: c)
        #expect(portrait.camera == portrait.sidebar.insetBy(dx: SceneGeometry.sidebarMargin, dy: SceneGeometry.sidebarMargin))
        c.cameraFrame = .circle
        let circle = SceneGeometry(configuration: c)
        #expect(circle.camera.width == circle.camera.height && circle.sidebar.contains(circle.camera))

        // Nothing to put in the column: the desktop takes the whole frame.
        c.cameraEnabled = false
        let bare = SceneGeometry(configuration: c)
        #expect(bare.desktop == SceneGeometry.canvas && !bare.sidebar.intersects(SceneGeometry.canvas))
        // Chat that is off stays wholly outside the frame (its last page is kept for sliding out),
        // on either side, at any width, including when the webcam is lost.
        c.cameraEnabled = true
        for left in [false, true] {
            for width in [288.0, 384, 576] {
                c.chatOnLeft = left; c.chatWidth = width
                #expect(!SceneGeometry(configuration: c, cameraReady: false).chat.intersects(SceneGeometry.canvas))
            }
        }
    }

    @Test func awayCoversEverythingButChat() {
        var c = StudioConfiguration()
        c.cameraEnabled = true; c.layout = .away
        let away = SceneGeometry(configuration: c)
        c.layout = .justChatting
        #expect(away.away == 1 && away.camera.width == 0 && away.chat == SceneGeometry(configuration: c).chat)
    }

    @Test func newScenesAndBorderRoundTripAndUnknownSceneKeepsOtherSettings() throws {
        var c = StudioConfiguration()
        c.layout = .sideBySide; c.cameraEnabled = true; c.cameraBorder = .bold; c.cameraBorderRed = 0.2
        c.awayMessage = "Back in five"; c.awayMutesMicrophone = false
        let restored = try JSONDecoder().decode(StudioConfiguration.self, from: JSONEncoder().encode(c))
        #expect(restored == c)
        let future = Data(#"{"layout":"pictureInPicture","microphoneGain":0.6,"cameraBorder":"neon"}"#.utf8)
        let fallback = try JSONDecoder().decode(StudioConfiguration.self, from: future)
        #expect(fallback.layout == .desktopChat && fallback.cameraBorder == .none && fallback.microphoneGain == 0.6)
    }

    @Test func awayLookRoundTripsAndOlderSettingsKeepTheirSceneBackdrop() throws {
        var c = StudioConfiguration()
        c.awaySubtitle = "Back in 5"; c.awayBackground = .color; c.awayRed = 0.9; c.awayImagePath = "/tmp/a.png"
        #expect(try JSONDecoder().decode(StudioConfiguration.self, from: JSONEncoder().encode(c)) == c)
        // Before the Away card had its own background it drew on the scene's image or colour.
        let image = try JSONDecoder().decode(StudioConfiguration.self, from: Data(#"{"backgroundStyle":"image","backgroundImagePath":"/tmp/b.png"}"#.utf8))
        #expect(image.awayBackground == .image && image.awayImagePath == "/tmp/b.png")
        let color = try JSONDecoder().decode(StudioConfiguration.self, from: Data(#"{"backgroundStyle":"color","backgroundRed":0.5}"#.utf8))
        #expect(color.awayBackground == .color && color.awayRed == 0.5)
        let mirror = try JSONDecoder().decode(StudioConfiguration.self, from: Data(#"{"backgroundStyle":"mirror"}"#.utf8))
        #expect(mirror.awayBackground == .dark)
        // A saved Away choice wins over the scene background.
        let chosen = try JSONDecoder().decode(StudioConfiguration.self, from: Data(#"{"backgroundStyle":"color","awayBackground":"dark"}"#.utf8))
        #expect(chosen.awayBackground == .dark)
    }

    @Test func awayTypeSwitchesToDarkOnlyWhereItReadsBetter() {
        #expect(!AwayCard.prefersDarkText(red: 0.11, green: 0.14, blue: 0.22))
        #expect(AwayCard.prefersDarkText(red: 0.95, green: 0.9, blue: 0.8))
        #expect(!AwayCard.prefersDarkText(red: 0.2, green: 0.2, blue: 0.8))
    }

    @MainActor @Test func webcamScenesNeedTheWebcamAndTurningItOffNeverShowsTheDesktop() throws {
        let model = StudioModel(demo: true)
        model.configuration.cameraEnabled = false
        model.configuration.layout = .away
        // A webcam scene is unavailable: choosing it changes nothing, least of all the webcam.
        model.selectScene(.justChatting)
        model.selectScene(.sideBySide)
        #expect(model.configuration.layout == .away && !model.configuration.cameraEnabled && model.message != nil)
        model.configuration.cameraEnabled = true
        #expect(model.message == nil)
        model.selectScene(.justChatting)
        #expect(model.configuration.layout == .justChatting)
        // Turning the webcam off in Full Camera covers it with Away, not the desktop, and keeps the
        // microphone live; turning it back on never changes the scene.
        model.configuration.cameraEnabled = false
        #expect(model.configuration.layout == .away && !model.configuration.microphoneSilenced)
        model.configuration.cameraEnabled = true
        #expect(model.configuration.layout == .away && !model.configuration.microphoneSilenced)
        // Away chosen on purpose silences the room as configured.
        model.selectScene(.away)
        #expect(model.configuration.microphoneSilenced)
        model.selectScene(.sideBySide)
        model.configuration.cameraEnabled = false
        #expect(model.configuration.layout == .desktopChat)
        // Settings saved in a webcam scene with the webcam off open in that scene's fallback. A relaunch
        // starts afresh, so Away then silences the room as configured, and the menu says so.
        let split = try JSONDecoder().decode(StudioConfiguration.self, from: Data(#"{"layout":"sideBySide","cameraEnabled":false,"chatEnabled":true}"#.utf8))
        #expect(split.layout == .desktopChat && split.chatEnabled)
        let full = try JSONDecoder().decode(StudioConfiguration.self, from: Data(#"{"layout":"justChatting","cameraEnabled":false}"#.utf8))
        #expect(full.layout == .away && full.microphoneSilenced)
        var fallback = StudioConfiguration(); fallback.layout = .away; fallback.awayCoversWebcam = true
        #expect(try JSONDecoder().decode(StudioConfiguration.self, from: JSONEncoder().encode(fallback)).microphoneSilenced)
    }

    /// A privacy change queued behind a slower switch is masked onto whatever is on air.
    @Test func aQueuedPrivacyChangeHidesAtOnceAndShowingMoreWaits() {
        var fullCamera = StudioConfiguration()
        fullCamera.cameraEnabled = true; fullCamera.layout = .justChatting
        var desktop = fullCamera; desktop.layout = .desktopChat
        var away = fullCamera; away.layout = .away
        var webcamOff = desktop; webcamOff.cameraEnabled = false
        #expect(fullCamera.hiding(as: away).layout == .away)
        #expect(desktop.hiding(as: away).layout == .away)
        #expect(!fullCamera.hiding(as: webcamOff).cameraEnabled && fullCamera.hiding(as: webcamOff).layout == .justChatting)
        #expect(desktop.hiding(as: fullCamera).layout == .justChatting)
        #expect(fullCamera.hiding(as: desktop) == fullCamera)
        #expect(away.hiding(as: fullCamera) == away)
    }

    @Test func aWebcamWithoutFramesNeverLeavesAnEmptyCameraSlot() {
        var c = StudioConfiguration()
        c.cameraEnabled = true; c.chatEnabled = true
        c.layout = .justChatting
        #expect(SceneGeometry(configuration: c, cameraReady: false).away == 1)
        #expect(SceneGeometry(configuration: c).showsCamera)
        c.layout = .sideBySide
        let split = SceneGeometry(configuration: c, cameraReady: false)
        #expect(!split.showsCamera && split.chat.height > 900)
        c.layout = .desktopChat
        let ready = SceneGeometry(configuration: c), waiting = SceneGeometry(configuration: c, cameraReady: false)
        #expect(!waiting.showsCamera && waiting.camera.midX == ready.camera.midX && waiting.camera.midY == ready.camera.midY)
    }

    /// Away → Full Camera lifts the Away card off a webcam already in place, never uncovering the
    /// desktop kept from an earlier Desktop scene.
    @Test func returningFromAwayToFullCameraNeverUncoversTheDesktop() async throws {
        let inputs = RenderInputs()
        var c = StudioConfiguration()
        c.cameraEnabled = true; c.chatEnabled = false; c.layout = .desktopChat
        inputs.configure(c)
        let frames = PreviewFrames(); frames.request(.program)
        let renderer = try FrameRenderer(inputs: inputs, preview: frames, outputFD: nil, synthetic: true)
        renderer.start(epoch: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
        // Green minus red at the top-left corner: the synthetic desktop is blue-green, the Away card
        // neutral, the synthetic webcam purple.
        func cornerTint() -> Int? {
            guard let buffer = frames.latest().buffer else { return nil }
            CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let row = base.advanced(by: 8 * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)
            return Int(row[8 * 4 + 1]) - Int(row[8 * 4 + 2])
        }
        for layout in [SceneLayout.desktopChat, .justChatting, .away] {
            c.layout = layout; inputs.configure(c)
            try await Task.sleep(for: .milliseconds(600))
        }
        let card = cornerTint()
        c.layout = .justChatting; inputs.configure(c)
        var tints: [Int] = []
        for _ in 0..<60 {
            if let tint = cornerTint() { tints.append(tint) }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await renderer.finish()
        // The card was up before, the webcam fills the frame after, and nothing in between leans desktop.
        #expect(card.map { abs($0) < 5 } == true)
        #expect(tints.count >= 20 && (tints.last ?? 0) < -5)
        #expect(tints.allSatisfy { $0 < 5 })
    }

    /// Full Camera chosen while the Away card lifts off the Desktop: the desktop already uncovered
    /// stays until the webcam grows over it, never swapped for the stage and then shown again.
    @Test func fullCameraChosenWhileAwayLiftsOffTheDesktopNeverFlashesTheDesktopBack() async throws {
        let inputs = RenderInputs()
        var c = StudioConfiguration()
        c.cameraEnabled = true; c.chatEnabled = false; c.layout = .desktopChat
        inputs.configure(c)
        let frames = PreviewFrames(); frames.request(.program)
        let renderer = try FrameRenderer(inputs: inputs, preview: frames, outputFD: nil, synthetic: true)
        renderer.start(epoch: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
        // Green minus red at the bottom-left corner, which the lifting card uncovers first: about 5
        // for the card and stage, 30–40 for the synthetic desktop, 77 for the synthetic webcam there.
        func cornerTint() -> Int? {
            guard let buffer = frames.latest().buffer else { return nil }
            CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let row = base.advanced(by: (CVPixelBufferGetHeight(buffer) - 9) * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)
            return Int(row[8 * 4 + 1]) - Int(row[8 * 4 + 2])
        }
        try await Task.sleep(for: .milliseconds(600))
        c.layout = .away; inputs.configure(c)
        try await Task.sleep(for: .milliseconds(700))
        c.layout = .desktopChat; inputs.configure(c)
        var tints: [Int] = []
        for _ in 0..<30 where tints.last.map({ $0 < 10 }) ?? true {
            if let tint = cornerTint() { tints.append(tint) }
            try await Task.sleep(for: .milliseconds(10))
        }
        c.layout = .justChatting; inputs.configure(c)
        for _ in 0..<80 {
            if let tint = cornerTint() { tints.append(tint) }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await renderer.finish()
        let desktop = tints.map { (10..<60).contains($0) }
        let runs = zip([false] + desktop, desktop).filter { !$0 && $1 }.count
        // The desktop shows once (uncovered before the switch), then the webcam fills the frame.
        #expect(desktop.contains(true) && runs == 1)
        #expect((tints.last ?? 0) >= 60)
    }
}
