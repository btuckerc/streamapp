import CoreGraphics
import Foundation
import Testing
@testable import StreamApp

struct CameraPlacementTests {
    @Test func decodingPrefersClampedAnchorAndMigratesOnlyAbsentKey() throws {
        func decode(_ json: String) throws -> StudioConfiguration { try JSONDecoder().decode(StudioConfiguration.self, from: Data(json.utf8)) }
        for preset in [CameraPreset.topLeft, .topRight, .bottomLeft, .bottomRight] {
            #expect(try decode("{\"cameraCorner\":\"\(preset.rawValue)\"}").cameraAnchor == preset.anchor)
        }
        #expect(try decode(#"{"cameraCorner":"future"}"#).cameraAnchor == .bottomRight)
        #expect(try decode(#"{"cameraAnchor":{"x":-2,"y":8},"cameraCorner":"topRight"}"#).cameraAnchor == CameraAnchor(x: 0, y: 1))
        for malformed in ["null", "3", #"{"x":0}"#, #"{"x":"bad","y":0}"#] {
            #expect(try decode("{\"cameraAnchor\":\(malformed),\"cameraCorner\":\"topLeft\"}").cameraAnchor == .bottomRight)
        }
        let c = try decode(#"{"cameraAnchor":{"x":0.23,"y":0.68},"cameraAvoidCursor":true}"#)
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(StudioConfiguration.self, from: data).cameraAnchor == c.cameraAnchor)
        #expect(try JSONDecoder().decode(StudioConfiguration.self, from: data).cameraAvoidCursor)
        #expect(!String(decoding: data, as: UTF8.self).contains("cameraCorner"))
        #expect(try !decode("{}").cameraAvoidCursor)
        #expect(CameraAnchor(x: .nan, y: .infinity) == .bottomRight)
    }

    @Test func cornerRectsExactlyMatchLegacyForEveryFrameSizeAndScene() {
        for preset in [CameraPreset.topLeft, .topRight, .bottomLeft, .bottomRight] {
            for frame in CameraFrame.allCases {
                for size in [0.12, 0.25, 0.4] {
                    for punchSize in [0.4, 0.5, 0.67, 0.9] {
                        for punch in [false, true] {
                            for side in [false, true] {
                                for chatWidth in [0.0, 288, 384, 576] {
                                    var c = StudioConfiguration()
                                    c.cameraEnabled = true; c.cameraFrame = frame; c.cameraAnchor = preset.anchor
                                    c.cameraSize = size; c.cameraPunchInSize = punchSize; c.cameraPunchIn = punch
                                    c.chatEnabled = chatWidth > 0; c.chatWidth = chatWidth; c.chatOnLeft = side
                                    let g = SceneGeometry(configuration: c)
                                    let effective = CGFloat(punch ? punchSize : size)
                                    let w: CGFloat, h: CGFloat
                                    if frame != .widescreen {
                                        h = min(1080 * effective, 1032); w = h * frame.aspectRatio
                                    } else {
                                        w = min(g.desktop.width * effective, 1032 * frame.aspectRatio); h = w / frame.aspectRatio
                                    }
                                    let expected = CGRect(x: preset.anchor.x == 0 ? g.desktop.minX + 24 : g.desktop.maxX - w - 24,
                                        y: preset.anchor.y == 0 ? 1080 - h - 24 : 24, width: w, height: h)
                                    #expect(g.camera == expected)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func inverseRoundTripsCustomPositionsAndClampsTravel() {
        var c = StudioConfiguration()
        for frame in CameraFrame.allCases {
            c.cameraFrame = frame
            for preset in CameraPreset.allCases {
                let g = SceneGeometry(configuration: c)
                let rect = CameraPlacement.rect(anchor: preset.anchor, size: g.camera.size, desktop: g.desktop)
                #expect(CameraPlacement.anchor(origin: rect.origin, size: rect.size, desktop: g.desktop) == preset.anchor)
            }
            let g = SceneGeometry(configuration: c)
            let a = CameraAnchor(x: 0.231, y: 0.678)
            let rect = CameraPlacement.rect(anchor: a, size: g.camera.size, desktop: g.desktop)
            let result = CameraPlacement.anchor(origin: rect.origin, size: rect.size, desktop: g.desktop, snapping: false)
            #expect(abs(result.x - a.x) < 1e-12 && abs(result.y - a.y) < 1e-12)
            #expect(CameraPlacement.anchor(origin: CGPoint(x: -10000, y: 10000), size: rect.size, desktop: g.desktop) == CameraAnchor(x: 0, y: 0))
        }
    }

    @Test func snappingUsesCanvasPixelsOnEachAxisAndOptionBypasses() {
        let desktop = CGRect(x: 384, y: 0, width: 1536, height: 1080)
        let size = CGSize(width: 300, height: 200)
        for preset in CameraPreset.allCases {
            let rect = CameraPlacement.rect(anchor: preset.anchor, size: size, desktop: desktop)
            let signX: CGFloat = preset.anchor.x == 1 ? -1 : 1
            let signY: CGFloat = preset.anchor.y == 0 ? -1 : 1
            let near = CGPoint(x: rect.minX + signX * 23, y: rect.minY + signY * 23)
            #expect(CameraPlacement.anchor(origin: near, size: size, desktop: desktop) == preset.anchor)
            #expect(CameraPlacement.anchor(origin: near, size: size, desktop: desktop, snapping: false) != preset.anchor)
            let outside = CGPoint(x: rect.minX + signX * 25, y: rect.minY + signY * 25)
            #expect(CameraPlacement.anchor(origin: outside, size: size, desktop: desktop) != preset.anchor)
        }
    }

    @Test func canvasDisplayRoundTripIncludesCropLetterboxingAndGlobalOffset() {
        let frame = CGRect(x: -1728, y: 200, width: 1728, height: 1117)
        for menu in [false, true] {
            for dock in [nil, 0.8] as [Double?] {
                let full = CGRect(origin: .zero, size: frame.size)
                let region = DisplayCaptureGeometry.crop(full, displayBounds: full, topInset: 38, includeMenuBar: menu, dockHeightFraction: dock)
                let mapping = CameraDisplayMapping(region: region, displayFrame: frame,
                    desktop: CGRect(x: 384, y: 0, width: 1536, height: 1080),
                    sourceSize: DisplayCaptureGeometry.outputSize(region: region, pixelScale: 2))
                let topLeft = mapping.toDisplay(CGPoint(x: mapping.content.minX, y: mapping.content.maxY))
                #expect(abs(topLeft.x - frame.minX - region.minX) < 1e-9)
                #expect(abs(topLeft.y - frame.maxY + region.minY) < 1e-9)
                for point in [CGPoint.zero, CGPoint(x: 1920, y: 1080), CGPoint(x: 987.5, y: 432.1)] {
                    let result = mapping.toCanvas(mapping.toDisplay(point))
                    #expect(abs(result.x - point.x) < 1e-9 && abs(result.y - point.y) < 1e-9)
                }
            }
        }
    }

    @Test func privateHandleNeverEntersCaptureEvenWithAllVisibilityEnabled() {
        var c = StudioConfiguration(); c.showStreamAppWindows = true; c.teleprompterInCapture = true
        #expect(!CaptureWindowPolicy.isVisible(windowID: 21, isOwnWindow: true, applicationExcluded: false,
            configuration: c, annotationWindowID: 21, teleprompterWindowIDs: [21], cameraArrangeWindowID: 21))
    }

    @Test func cursorDodgeHasHysteresisAndRejectsOverlapAndDisabledStates() {
        let home = CGRect(x: 700, y: 24, width: 200, height: 200)
        let dodge = CGRect(x: 24, y: 24, width: 200, height: 200)
        let near = CGPoint(x: 680, y: 100), between = CGPoint(x: 660, y: 100), far = CGPoint(x: 650, y: 100)
        #expect(CameraPlacement.shouldDodge(cursor: near, home: home, dodge: dodge, dodging: false, enabled: true))
        #expect(!CameraPlacement.shouldDodge(cursor: between, home: home, dodge: dodge, dodging: false, enabled: true))
        #expect(CameraPlacement.shouldDodge(cursor: between, home: home, dodge: dodge, dodging: true, enabled: true))
        #expect(!CameraPlacement.shouldDodge(cursor: far, home: home, dodge: dodge, dodging: true, enabled: true))
        #expect(!CameraPlacement.shouldDodge(cursor: near, home: home, dodge: home.offsetBy(dx: 100, dy: 0), dodging: true, enabled: true))
        #expect(!CameraPlacement.shouldDodge(cursor: near, home: home, dodge: dodge, dodging: true, enabled: false))
        #expect(CameraPlacement.dodgeAnchor(home: CameraAnchor(x: 0.5, y: 1)) == CameraAnchor(x: 0.5, y: 0))
        #expect(CameraPlacement.dodgeAnchor(home: CameraAnchor(x: 0.9, y: 1)).x < 0.11)
    }

    @Test func dragOverrideSurvivesStaleConfigurationAndCutsMotionUntilCommit() {
        let inputs = RenderInputs()
        var c = StudioConfiguration(); c.cameraEnabled = true
        inputs.configure(c)
        let old = SceneGeometry(configuration: c)
        let a = CameraAnchor(x: 0.35, y: 0.4)
        inputs.setCameraDrag(a)
        let generation = inputs.snapshot().generation
        inputs.finishCameraDrag(committing: a)
        inputs.configure(c)
        #expect(inputs.snapshot().cameraDrag == a && inputs.snapshot().generation > generation)
        c.cameraAnchor = a; inputs.configure(c)
        #expect(inputs.snapshot().cameraDrag == nil && inputs.snapshot().configuration.cameraAnchor == a)
        var motion = SceneTransition()
        _ = motion.sample(target: old, now: 0)
        let next = SceneGeometry(configuration: c)
        #expect(motion.sample(target: next, now: 0.01, dragging: true) == next)
        #expect(motion.sample(target: next, now: 0.02) == next)
    }
}
