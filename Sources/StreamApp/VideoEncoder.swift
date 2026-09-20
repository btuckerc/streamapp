import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import IOSurface
import EncodedMuxer
import Darwin


final class VideoEncoder: @unchecked Sendable {
    enum EncoderError: Error, CustomStringConvertible, LocalizedError {
        case status(String, OSStatus)
        case message(String)
        case muxer(String, Int32)
        var errorDescription: String? { description }
        var description: String {
            switch self {
            case let .status(name, status): return "\(name) failed (\(status))"
            case let .message(text): return text
            case let .muxer(text, status): return "\(text) (\(status))"
            }
        }
    }

    private var session: VTCompressionSession?
    private var pool: CVPixelBufferPool?
    private let allocationHints = [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary
    private var muxErrorText = [CChar](repeating: 0, count: 512)
    private var muxer: OpaquePointer?
    private let outputFD: Int32
    private let stateLock = NSLock()
    private let muxLock = NSLock()
    private let slots = DispatchSemaphore(value: 3)
    private var closed = false
    private var finishing = false
    private var _frames = 0
    private var _bytes = 0
    private var _hardware = false
    private var _error: Error?

    init(outputFD: Int32 = STDOUT_FILENO) throws {
        self.outputFD = outputFD
        let attrs: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ] as CFDictionary
        let spec: CFDictionary = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] as CFDictionary
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: 1920, height: 1080,
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
            imageBufferAttributes: attrs, compressedDataAllocator: nil,
            outputCallback: videoEncoderCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &created)
        guard status == noErr, let created else { throw EncoderError.status("VTCompressionSessionCreate", status) }
        session = created
        do {
            try set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
            try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
            try set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
            try set(kVTCompressionPropertyKey_ConstantBitRate, 6_000_000 as CFTypeRef)
            try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 60 as CFTypeRef)
            try set(kVTCompressionPropertyKey_ExpectedFrameRate, 30 as CFTypeRef)
            try set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2 as CFTypeRef)
            try set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2 as CFTypeRef)
            try set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as CFTypeRef)
            let prepare = VTCompressionSessionPrepareToEncodeFrames(created)
            guard prepare == noErr else { throw EncoderError.status("VTCompressionSessionPrepareToEncodeFrames", prepare) }
            let (propertyStatus, usesHardware) = withUnsafeTemporaryAllocation(of: CFTypeRef?.self, capacity: 1) { storage in
                storage.initialize(repeating: nil); defer { storage.deinitialize() }
                let result = VTSessionCopyProperty(created, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: storage.baseAddress!)
                return (result, (storage[0] as? NSNumber)?.boolValue == true)
            }
            guard propertyStatus == noErr, usesHardware else { throw EncoderError.message("hardware H.264 encoder unavailable") }
            stateLock.lock(); _hardware = true; stateLock.unlock()
            pool = VTCompressionSessionGetPixelBufferPool(created)
            guard pool != nil else { throw EncoderError.message("encoder did not provide a pixel buffer pool") }
        } catch {
            VTCompressionSessionInvalidate(created); session = nil; throw error
        }
    }

    private func set(_ key: CFString, _ value: CFTypeRef) throws {
        guard let session else { throw EncoderError.message("encoder is closed") }
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw EncoderError.status("VTSessionSetProperty \(key)", status) }
    }

    func makePixelBuffer() throws -> CVPixelBuffer {
        stateLock.lock(); let pool = self.pool; let failed = _error; let done = closed; stateLock.unlock()
        if let failed { throw failed }
        guard !done, let pool else { throw EncoderError.message("encoder is closed") }
        var pixel: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, allocationHints, &pixel)
        guard status == kCVReturnSuccess, let pixel else { throw EncoderError.status("CVPixelBufferPoolCreatePixelBuffer", status) }
        return pixel
    }

    func encode(_ pixel: CVPixelBuffer, pts: CMTime) throws {
        guard CVPixelBufferGetWidth(pixel) == 1920, CVPixelBufferGetHeight(pixel) == 1080,
              CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA else {
            throw EncoderError.message("pixel buffer is not 1920x1080 BGRA")
        }
        guard slots.wait(timeout: .now() + 1.0) == .success else { throw EncoderError.message("encoder buffer timeout") }
        stateLock.lock()
        if let error = _error { stateLock.unlock(); slots.signal(); throw error }
        guard let session, !closed, !finishing else { stateLock.unlock(); slots.signal(); throw EncoderError.message("encoder is closed") }
        stateLock.unlock()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixel, presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: 30), frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
        guard status == noErr else {
            fail(EncoderError.status("VTCompressionSessionEncodeFrame", status))
            slots.signal()
            throw EncoderError.status("VTCompressionSessionEncodeFrame", status)
        }
    }

    func finish() throws {
        stateLock.lock()
        if closed { let error = _error; stateLock.unlock(); if let error { throw error }; return }
        finishing = true; let session = self.session; stateLock.unlock()
        let completeStatus: OSStatus
        if let session {
            completeStatus = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        } else { completeStatus = noErr }
        if completeStatus != noErr { fail(EncoderError.status("VTCompressionSessionCompleteFrames", completeStatus)) }
        stateLock.lock(); closed = true; self.session = nil; let existing = _error; stateLock.unlock()
        muxLock.lock()
        var closeError: EncoderError?
        if muxer != nil {
            var text = [CChar](repeating: 0, count: 512)
            let result = sa_mux_close(&muxer, &text, text.count)
            if result != 0 { closeError = .muxer(String(cString: text), result) }
        }
        muxLock.unlock()
        if let closeError { fail(closeError); throw closeError }
        if let existing { throw existing }
    }

    private func fail(_ error: Error) {
        stateLock.lock(); if _error == nil { _error = error }; stateLock.unlock()
    }

    fileprivate func callback(status: OSStatus, sample: CMSampleBuffer?) {
        defer { slots.signal() }
        guard status == noErr, let sample, CMSampleBufferDataIsReady(sample) else {
            fail(EncoderError.status("compression callback", status == noErr ? -1 : status)); return
        }
        guard let format = CMSampleBufferGetFormatDescription(sample) else { fail(EncoderError.message("missing H.264 format description")); return }
        muxLock.lock(); defer { muxLock.unlock() }
        if muxer == nil {
            var spsPtr: UnsafePointer<UInt8>?; var spsSize = 0; var ppsPtr: UnsafePointer<UInt8>?; var ppsSize = 0
            var spsCount = 0; var ppsCount = 0
            var nal: Int32 = 0
            let a = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: &nal)
            let b = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 1, parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize, parameterSetCountOut: &ppsCount, nalUnitHeaderLengthOut: &nal)
            guard a == noErr, b == noErr, let spsPtr, let ppsPtr else {
                fail(EncoderError.status("H.264 parameter sets", a != noErr ? a : b)); return
            }
            guard nal == 4 else { fail(EncoderError.message("encoder returned non-AVCC H.264")); return }
            var opened: OpaquePointer?
            var text = [CChar](repeating: 0, count: 512)
            let result = sa_mux_open(&opened, spsPtr, spsSize, ppsPtr, ppsSize, 1920, 1080, 30, outputFD, &text, text.count)
            guard result == 0, let opened else { fail(EncoderError.muxer(String(cString: text), result)); return }; muxer = opened
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { fail(EncoderError.message("missing compressed data")); return }
        var length = 0; var total = 0; var pointer: UnsafeMutablePointer<Int8>?
        let pointerStatus = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length,
                                                        totalLengthOut: &total, dataPointerOut: &pointer)
        guard pointerStatus == kCMBlockBufferNoErr, total > 0 else { fail(EncoderError.status("CMBlockBufferGetDataPointer", pointerStatus)); return }
        let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
        let decode = CMSampleBufferGetDecodeTimeStamp(sample)
        guard presentation.isNumeric else { fail(EncoderError.message("invalid encoded timestamp")); return }
        let pts = CMTimeConvertScale(presentation, timescale: 30, method: .roundHalfAwayFromZero).value
        let dts = decode.isNumeric ? CMTimeConvertScale(decode, timescale: 30, method: .roundHalfAwayFromZero).value : pts
        let key = ((CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        let result: Int32
        if let pointer, length == total {
            result = sa_mux_write(muxer, UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
                                  total, pts, dts, key ? 1 : 0, &muxErrorText, 512)
        } else {
            var copy = [UInt8](repeating: 0, count: total)
            let copyStatus = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: &copy)
            guard copyStatus == kCMBlockBufferNoErr else { fail(EncoderError.status("CMBlockBufferCopyDataBytes", copyStatus)); return }
            result = copy.withUnsafeBufferPointer { buffer in
                sa_mux_write(muxer, buffer.baseAddress!, total, pts, dts, key ? 1 : 0, &muxErrorText, 512)
            }
        }
        guard result == 0 else { fail(EncoderError.muxer(String(cString: muxErrorText), result)); return }
        stateLock.lock(); _frames += 1; _bytes += total; stateLock.unlock()
    }

    deinit { if !closed { try? finish() } }
}

private func videoEncoderCallback(_ refcon: UnsafeMutableRawPointer?, _ sourceFrameRefcon: UnsafeMutableRawPointer?, _ status: OSStatus, _ infoFlags: VTEncodeInfoFlags, _ sampleBuffer: CMSampleBuffer?) {
    guard let refcon else { return }
    Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue().callback(status: status, sample: sampleBuffer)
}
