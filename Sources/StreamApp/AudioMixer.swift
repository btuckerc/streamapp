import Foundation
import AVFoundation
import CoreMedia

/// Fixed-capacity, host-clock aligned audio. Late samples never replay later.
final class AudioMixer: @unchecked Sendable {
    private static let capacity = 96_000
    private let lock = NSLock()
    private var microphone = [Float](repeating: 0, count: capacity * 2)
    private var system = [Float](repeating: 0, count: capacity * 2)
    private var configuration = StudioConfiguration()
    private var cursor: Int64 = 0
    private var epoch = 0.0
    private var synthetic = false
    private var meters: (microphone: Float, system: Float, output: Float, gainReduction: Float) = (0, 0, 0, 0)
    private var pendingMeters: (microphone: Float, system: Float, output: Float, gainReduction: Float) = (0, 0, 0, 0)
    private var microphoneCompressor = StereoCompressor()
    private var outputProtectionGain: Float = 1
    private let meterReleasePerSample = exp(log(0.01) / (0.15 * 48_000))
    private let outputProtectionRelease: Float = Float(1 - exp(-1 / (0.150 * 48_000)))
    private let microphoneConverter = PCMConverter()
    private let systemConverter = PCMConverter()

    func reset(configuration: StudioConfiguration, synthetic: Bool, epoch: Double = CMClockGetTime(CMClockGetHostTimeClock()).seconds) {
        lock.lock(); defer { lock.unlock() }
        self.configuration = configuration; self.synthetic = synthetic
        cursor = 0; self.epoch = epoch
        microphone.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        system.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        microphoneCompressor.reset()
        outputProtectionGain = 1
        meters = (0, 0, 0, 0); pendingMeters = (0, 0, 0, 0)
    }
    func configure(_ configuration: StudioConfiguration) {
        lock.lock(); defer { lock.unlock() }
        if self.configuration.microphoneEnabled != configuration.microphoneEnabled {
            microphone.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        }
        if self.configuration.systemAudioEnabled != configuration.systemAudioEnabled {
            system.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        }
        if self.configuration.microphoneCompressionEnabled && !configuration.microphoneCompressionEnabled {
            microphoneCompressor.reset()
            meters.gainReduction = 0; pendingMeters.gainReduction = 0
        }
        if (!self.configuration.microphoneMuted && configuration.microphoneMuted) ||
            self.configuration.microphoneEnabled != configuration.microphoneEnabled {
            microphoneCompressor.reset()
            meters.microphone = 0; meters.gainReduction = 0
            pendingMeters.microphone = 0; pendingMeters.gainReduction = 0
        }
        if (!self.configuration.systemAudioMuted && configuration.systemAudioMuted) || self.configuration.systemAudioEnabled != configuration.systemAudioEnabled {
            meters.system = 0; pendingMeters.system = 0
        }
        self.configuration = configuration
    }
    func append(_ sample: CMSampleBuffer, microphone isMicrophone: Bool) throws {
        lock.lock()
        let enabled = isMicrophone ? configuration.microphoneEnabled : configuration.systemAudioEnabled
        lock.unlock()
        guard enabled else { return }
        let converter = isMicrophone ? microphoneConverter : systemConverter
        try converter.convert(sample) { pointer, frames in
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            lock.lock(); defer { lock.unlock() }
            guard isMicrophone ? configuration.microphoneEnabled : configuration.systemAudioEnabled else { return }
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            guard timestamp.isFinite, abs(timestamp - hostNow) < 10 else {
                throw OutputError.message("Audio device returned timestamps outside the host clock")
            }
            let first = Int64(((timestamp - epoch) * 48_000).rounded())
            for frame in 0..<frames {
                let position = first + Int64(frame)
                guard position >= cursor, position < cursor + Int64(Self.capacity) else { continue }
                let index = Int(position % Int64(Self.capacity)) * 2
                if isMicrophone { microphone[index] = pointer[frame * 2]; microphone[index + 1] = pointer[frame * 2 + 1] }
                else { system[index] = pointer[frame * 2]; system[index + 1] = pointer[frame * 2 + 1] }
            }
        }
    }

    /// Writer owns the reusable output buffer and advances one media clock.
    func pull(into destination: UnsafeMutableBufferPointer<Float>) {
        lock.lock(); defer { lock.unlock() }
        let c = configuration
        let frames = destination.count / 2
        let micGain = c.microphoneEnabled && !c.microphoneMuted ? Float(c.microphoneGain) : 0
        let sysGain = c.systemAudioEnabled && !c.systemAudioMuted ? Float(c.systemAudioGain) : 0
        var micPeak: Float = 0
        var sysPeak: Float = 0
        var outputPeak: Float = 0
        var minimumGain: Float = 1
        for frame in 0..<frames {
            let position = cursor + Int64(frame)
            let index = Int(position % Int64(Self.capacity)) * 2
            let micSignal = synthetic ? Float(sin(Double(position) * 2 * .pi * 440 / 48_000) * 0.12) : 0
            let sysSignal = synthetic ? Float(sin(Double(position) * 2 * .pi * 880 / 48_000) * 0.08) : 0
            var micLeft = (synthetic ? micSignal : microphone[index]) * micGain
            var micRight = (synthetic ? micSignal : microphone[index + 1]) * micGain
            if c.microphoneCompressionEnabled && micGain > 0 {
                let compressed = microphoneCompressor.process(left: micLeft, right: micRight)
                micLeft = compressed.left; micRight = compressed.right
                minimumGain = min(minimumGain, compressed.gain)
            }
            let sysLeft = (synthetic ? sysSignal : system[index]) * sysGain
            let sysRight = (synthetic ? sysSignal : system[index + 1]) * sysGain
            micPeak = max(micPeak, abs(micLeft), abs(micRight))
            sysPeak = max(sysPeak, abs(sysLeft), abs(sysRight))
            let sumLeft = micLeft + sysLeft
            let sumRight = micRight + sysRight
            let linkedPeak = max(abs(sumLeft), abs(sumRight))
            let desiredGain = linkedPeak > 0.89125 ? 0.89125 / linkedPeak : 1
            if desiredGain < outputProtectionGain {
                outputProtectionGain = desiredGain
            } else {
                outputProtectionGain += (1 - outputProtectionGain) * outputProtectionRelease
                outputProtectionGain = min(outputProtectionGain, desiredGain)
            }
            let outLeft = sumLeft * outputProtectionGain
            let outRight = sumRight * outputProtectionGain
            destination[frame * 2] = outLeft
            destination[frame * 2 + 1] = outRight
            outputPeak = max(outputPeak, abs(outLeft), abs(outRight))
            microphone[index] = 0; microphone[index + 1] = 0
            system[index] = 0; system[index + 1] = 0
        }
        cursor += Int64(frames)
        let reductionPeak = minimumGain < 1 ? -20 * log10(minimumGain) : 0
        let release = Float(pow(meterReleasePerSample, Double(frames)))
        meters.microphone = max(micPeak, meters.microphone * release)
        meters.system = max(sysPeak, meters.system * release)
        meters.output = max(outputPeak, meters.output * release)
        meters.gainReduction = max(reductionPeak, meters.gainReduction * release)
        pendingMeters.microphone = max(pendingMeters.microphone, micPeak)
        pendingMeters.system = max(pendingMeters.system, sysPeak)
        pendingMeters.output = max(pendingMeters.output, outputPeak)
        pendingMeters.gainReduction = max(pendingMeters.gainReduction, reductionPeak)
    }
    var levels: (microphone: Float, system: Float, output: Float, gainReduction: Float) {
        lock.lock(); defer { lock.unlock() }
        let result = (microphone: max(meters.microphone, pendingMeters.microphone),
                      system: max(meters.system, pendingMeters.system),
                      output: max(meters.output, pendingMeters.output),
                      gainReduction: max(meters.gainReduction, pendingMeters.gainReduction))
        pendingMeters = (0, 0, 0, 0)
        return result
    }
}

/// Stereo-linked soft-knee dynamics with no makeup gain.
private final class StereoCompressor {
    private var envelope: Float = 0
    private var gain: Float = 1
    private var targetGain: Float = 1
    private var controlCounter = 0
    private let attack: Float = Float(1 - exp(-1 / (0.010 * 48_000)))
    private let release: Float = Float(1 - exp(-1 / (0.150 * 48_000)))

    func reset() { envelope = 0; gain = 1; targetGain = 1; controlCounter = 0 }

    func process(left: Float, right: Float) -> (left: Float, right: Float, gain: Float) {
        let linked = max(abs(left), abs(right))
        envelope += (linked - envelope) * (linked > envelope ? attack : release)
        if controlCounter == 0 {
            let levelDB = envelope > 0.000001 ? 20 * log10(envelope) : -120
            let over = levelDB + 18
            let reduction: Float
            if over <= -3 { reduction = 0 }
            else if over >= 3 { reduction = over * (1 - 1 / 3) }
            else { let x = over + 3; reduction = (1 - 1 / 3) * x * x / 12 }
            targetGain = reduction > 0 ? pow(10, -reduction / 20) : 1
        }
        controlCounter = (controlCounter + 1) % 48
        gain += (targetGain - gain) * 0.15
        return (left * gain, right * gain, gain)
    }
}

/// Each source owns a converter; AVAudioConverter preserves resampling phase.
private final class PCMConverter: @unchecked Sendable {
    private let lock = NSLock()
    private var inputFormat: AVAudioFormat?
    private var inputDescription: CMAudioFormatDescription?
    private var converter: AVAudioConverter?
    private var input: AVAudioPCMBuffer?
    private var output: AVAudioPCMBuffer?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!

    func convert(_ sample: CMSampleBuffer, consume: (UnsafePointer<Float>, Int) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard let description = CMSampleBufferGetFormatDescription(sample) else { throw OutputError.message("Missing audio format") }
        if inputDescription == nil || !CMFormatDescriptionEqual(inputDescription!, otherFormatDescription: description) {
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            inputDescription = description; inputFormat = format
            converter = AVAudioConverter(from: format, to: target); input = nil; output = nil
        }
        guard let format = inputFormat else { throw OutputError.message("Missing audio format") }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= 192_000, format.sampleRate > 0 else { throw OutputError.message("Invalid audio buffer size") }
        guard let converter else { throw OutputError.message("Unsupported audio device format") }
        if input == nil || input!.frameCapacity < frames {
            input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        }
        let needed = AVAudioFrameCount(ceil(Double(frames) * 48_000 / format.sampleRate) + 64)
        if output == nil || output!.frameCapacity < needed { output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: needed) }
        guard let input, let output else { throw OutputError.message("Cannot allocate audio conversion buffers") }
        input.frameLength = AVAudioFrameCount(frames)
        let copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList)
        guard copied == noErr else { throw OutputError.message("Cannot read audio samples (\(copied))") }
        var provided = false; var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, state in
            if provided { state.pointee = .noDataNow; return nil }
            provided = true; state.pointee = .haveData; return input
        }
        guard result != .error else { throw error ?? OutputError.message("Audio conversion failed") as NSError }
        let buffer = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)[0]
        if output.frameLength > 0, let data = buffer.mData {
            try consume(data.assumingMemoryBound(to: Float.self), Int(output.frameLength))
        }
    }
}
