import CoreImage
import CoreVideo
import Metal
import Testing
@testable import StreamApp

/// The compositor writes encoder frames as 4:2:0 directly; a wrong tag would shift every
/// viewer's colours or make the program preview drift from what is encoded.
struct EncoderColorTests {
    private let context = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [.cacheIntermediates: false])
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    private func frame(_ r: Double, _ g: Double, _ b: Double) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer)
        let pixel = try #require(buffer)
        CVBufferSetAttachments(pixel, VideoEncoder.colorAttachments, .shouldPropagate)
        let image = CIImage(color: try #require(CIColor(red: r, green: g, blue: b, colorSpace: srgb))).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        context.render(image, to: pixel, bounds: CGRect(x: 0, y: 0, width: 64, height: 64), colorSpace: srgb)
        return pixel
    }

    private func ycbcr(_ pixel: CVPixelBuffer) -> [Int] {
        CVPixelBufferLockBaseAddress(pixel, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let y = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt8.self)
        let c = CVPixelBufferGetBaseAddressOfPlane(pixel, 1)!.assumingMemoryBound(to: UInt8.self)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0), cRow = CVPixelBufferGetBytesPerRowOfPlane(pixel, 1)
        return [Int(y[32 * yRow + 32]), Int(c[16 * cRow + 32]), Int(c[16 * cRow + 33])]
    }

    /// Reads like the program preview, after VideoToolbox has tagged the submitted buffer with the session's transfer function.
    private func readBack(_ pixel: CVPixelBuffer) -> [Int] {
        CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        var rgba = [UInt8](repeating: 0, count: 4)
        context.render(PreviewFrames.image(pixel, program: true), toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: 32, y: 32, width: 1, height: 1), format: .RGBA8, colorSpace: srgb)
        return rgba.prefix(3).map(Int.init)
    }

    @Test(arguments: [(1.0, 1.0, 1.0), (0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0), (0.5, 0.5, 0.5), (0.2, 0.6, 0.3)])
    func compositeIsBT709VideoRangeAndPreviewRoundTrips(_ color: (Double, Double, Double)) throws {
        let (r, g, b) = color
        let pixel = try frame(r, g, b)
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let expected = [16 + 219 * luma, 128 + 224 * (b - luma) / 1.8556, 128 + 224 * (r - luma) / 1.5748].map { Int($0.rounded()) }
        for (actual, wanted) in zip(ycbcr(pixel), expected) { #expect(abs(actual - wanted) <= 1, "YCbCr \(ycbcr(pixel)) != \(expected)") }
        let source = [r, g, b].map { Int(($0 * 255).rounded()) }
        for (actual, wanted) in zip(readBack(pixel), source) { #expect(abs(actual - wanted) <= 3, "preview \(readBack(pixel)) != \(source)") }
    }
}
