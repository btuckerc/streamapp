import CoreImage
import Metal
import Testing
@testable import StreamApp

struct DesktopBackgroundTests {
    private let context = CIContext(options: [.workingColorSpace: NSNull()])
    private let canvas = CGRect(x: 10, y: 20, width: 120, height: 80)

    private func pixels(_ image: CIImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 120 * 80 * 4)
        bytes.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: 120 * 4,
                           bounds: canvas, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return bytes
    }

    @Test func fillsOnlyUnusedSpaceAndKeepsForegroundSharp() throws {
        let sourceRect = CGRect(x: 7, y: 11, width: 120, height: 40)
        let source = CIImage(color: .red).cropped(to: sourceRect)
            .composited(over: CIImage(color: .black).cropped(to: sourceRect))
        let picture = try #require(context.createCGImage(CIImage(color: CIColor(red: 1, green: 0, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 20, height: 40)), from: CGRect(x: 0, y: 0, width: 20, height: 40)))
        for style in BackgroundStyle.allCases {
            var c = StudioConfiguration()
            c.backgroundStyle = style
            c.backgroundRed = 0; c.backgroundGreen = 1; c.backgroundBlue = 0
            let result = pixels(DesktopBackgroundRenderer.compose(source: source, in: canvas, configuration: c, image: picture))
            // Every interior foreground pixel remains red, including under blur.
            #expect((22..<58).allSatisfy { y in
                (2..<118).allSatisfy { x in
                    let p = (y * 120 + x) * 4
                    return result[p] == 255 && result[p + 1] == 0 && result[p + 2] == 0
                }
            })
            let bar = (5 * 120 + 60) * 4
            let expected: [UInt8]
            switch style {
            case .black: expected = [0, 0, 0, 255]
            case .color: expected = [0, 255, 0, 255]
            case .image, .mirror: expected = [255, 0, 255, 255]
            case .blur: expected = [255, 0, 0, 255]
            }
            #expect(Array(result[bar..<bar + 4]) == expected)
        }
    }

    @Test func mirroredWallpaperRepeatsWithoutLeakingCapturedContent() throws {
        let wallpaper = CIImage(color: .red).cropped(to: CGRect(x: 7, y: 11, width: 10, height: 80))
            .composited(over: CIImage(color: .blue).cropped(to: CGRect(x: 7, y: 11, width: 20, height: 80)))
        let picture = try #require(context.createCGImage(wallpaper, from: wallpaper.extent))
        let source = CIImage(color: .green).cropped(to: wallpaper.extent)
        var c = StudioConfiguration(); c.backgroundStyle = .mirror
        let result = pixels(DesktopBackgroundRenderer.compose(source: source, in: canvas, configuration: c, image: picture))
        for x in 0..<120 {
            if (50..<70).contains(x) {
                let p = (40 * 120 + x) * 4
                #expect(Array(result[p..<p + 4]) == [0, 255, 0, 255])
                continue
            }
            let phase = ((x - 50) % 40 + 40) % 40
            let reflected = phase < 20 ? phase : 39 - phase
            // Avoid the interpolation seam between the two source colors.
            if reflected == 9 || reflected == 10 { continue }
            let p = (40 * 120 + x) * 4
            #expect(result[p] == (reflected < 10 ? 255 : 0))
            #expect(result[p + 2] == (reflected < 10 ? 0 : 255))
            #expect(result[p + 3] == 255)
        }
    }

    @Test func unavailableWallpaperNeverFallsBackToCapturedPixels() {
        let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 20, height: 80))
        var c = StudioConfiguration(); c.backgroundStyle = .mirror
        c.backgroundRed = 0; c.backgroundGreen = 0; c.backgroundBlue = 1
        let result = pixels(DesktopBackgroundRenderer.compose(source: source, in: canvas, configuration: c))
        let bar = (40 * 120 + 5) * 4
        #expect(Array(result[bar..<bar + 4]) == [0, 0, 255, 255])
    }

    @Test func residentLayerRendersLikeItsRecipe() throws {
        // Production path: Metal context, linear working space, sRGB output, translucent
        // content at a non-zero origin (chat over video, an offset desktop canvas).
        let gpu = CIContext(mtlDevice: try #require(MTLCreateSystemDefaultDevice()), options: [.cacheIntermediates: false])
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let layer = CIImage(color: CIColor(red: 0.9, green: 0.2, blue: 0.4, alpha: 0.5)).cropped(to: CGRect(x: 10, y: 20, width: 60, height: 80))
            .composited(over: CIImage(color: CIColor(red: 0.1, green: 0.6, blue: 0.3)).cropped(to: CGRect(x: 70, y: 20, width: 60, height: 80)))
        let resident = FrameRenderer.resident(layer, in: canvas, context: gpu, colorSpace: srgb)
        let backdrop = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.8)).cropped(to: canvas)
        func render(_ image: CIImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 120 * 80 * 4)
            bytes.withUnsafeMutableBytes {
                gpu.render(image.composited(over: backdrop), toBitmap: $0.baseAddress!, rowBytes: 120 * 4,
                           bounds: canvas, format: .RGBA8, colorSpace: srgb)
            }
            return bytes
        }
        let expected = render(layer), actual = render(resident)
        #expect(expected[(40 * 120 + 30) * 4] > 150)
        #expect(zip(expected, actual).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    }
}
