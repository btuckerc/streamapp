import Foundation
import AVFoundation
import CoreMedia
import EchoCancellation

/// Level of one mixer channel, read at the UI poll: sample peak for headroom, and ITU-R BS.1770
/// loudness (LUFS) as EBU Tech 3341 meters it — momentary is the last 400 ms, short-term 3 s.
struct AudioLevel: Equatable, Sendable {
    var peak: Float = 0
    var momentary = -Double.infinity
    var shortTerm = -Double.infinity
    static let silent = AudioLevel()
}

/// Fixed-capacity, host-clock aligned audio. Late samples never replay later.
final class AudioMixer: @unchecked Sendable {
    typealias Levels = (microphone: AudioLevel, system: AudioLevel, output: AudioLevel, gainReduction: Float, limiterReduction: Float)
    private static let capacity = 96_000
    private let lock = NSLock()
    private var microphone = [Float](repeating: 0, count: capacity * 2)
    private var system = [Float](repeating: 0, count: capacity * 2)
    private var configuration = StudioConfiguration()
    /// The newest configuration requested while a session runs; every applied one is masked by it.
    private var requested: StudioConfiguration?
    private var cursor: Int64 = 0
    private var epoch = 0.0
    private var synthetic = false
    private var meters: (microphone: Float, system: Float, output: Float, gainReduction: Float, limiterReduction: Float) = (0, 0, 0, 0, 0)
    private var pendingMeters: (microphone: Float, system: Float, output: Float, gainReduction: Float, limiterReduction: Float) = (0, 0, 0, 0, 0)
    private var microphoneCompressor = StereoCompressor()
    private var ducker = Ducker()
    private var outputProtectionGain: Float = 1
    private let meterReleasePerSample = exp(log(0.01) / (0.15 * 48_000))
    private let outputProtectionRelease: Float = Float(1 - exp(-1 / (0.150 * 48_000)))
    private let microphoneLoudness = LoudnessMeter()
    private let systemLoudness = LoudnessMeter()
    private let outputLoudness = LoudnessMeter()
    private let microphoneConverter = PCMConverter()
    private let systemConverter = PCMConverter()
    private let referenceConverter = PCMConverter()
    private var reference: [Float] = []
    private var referencePositions: [Int64] = []
    private var microphonePositions: [Int64] = []
    private var referenceBlock = [Float](repeating: 0, count: 960)
    private var microphoneBlock = [Float](repeating: 0, count: 960)
    private var cleanedBlock = [Float](repeating: 0, count: 960)
    private var cleanedStart: Int64 = -1
    private var nextBlock: Int64 = 0
    private var canceller: OpaquePointer?
    private var nextMicrophonePosition: Int64?
    private var nextReferencePosition: Int64?
    private var echoStatus: String?
    private var revision: UInt64 = 0

    deinit { if let canceller { sa_aec_destroy(canceller) } }

    var echoCancellationStatus: String? {
        lock.lock(); defer { lock.unlock() }
        return configuration.microphoneEchoCancellationEnabled ? echoStatus : nil
    }

    /// A vanished device must not leave queued speech or DSP history audible.
    /// The program cursor keeps advancing; returning host timestamps rejoin it.
    func silenceMicrophone() {
        // Never acquire a converter lock while holding the mixer lock: conversion
        // calls its consumer with that lock held in the opposite order.
        microphoneConverter.reset()
        lock.lock(); defer { lock.unlock() }
        microphone.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        microphoneCompressor.reset()
        meters.microphone = 0; pendingMeters.microphone = 0
        meters.gainReduction = 0; pendingMeters.gainReduction = 0
        microphoneLoudness.reset()
        resetEcho()
    }
    private func resetEcho() {
        revision &+= 1
        let echo = configuration.microphoneEchoCancellationEnabled
        let noise = configuration.microphoneNoiseReductionEnabled
        let processing = echo || noise
        referencePositions.removeAll(keepingCapacity: echo)
        microphonePositions.removeAll(keepingCapacity: processing)
        reference.removeAll(keepingCapacity: echo)
        cleanedStart = -1; nextBlock = max(0, cursor - AudioSync.frames(configuration.microphoneSyncOffsetMs))
        nextMicrophonePosition = nil; nextReferencePosition = nil
        if let canceller { sa_aec_destroy(canceller); self.canceller = nil }
        echoStatus = nil
        guard processing else { return }
        guard configuration.microphoneEnabled else {
            if echo { echoStatus = "Waiting for microphone" }
            return
        }
        if echo {
            reference = [Float](repeating: 0, count: Self.capacity * 2)
            referencePositions = [Int64](repeating: -1, count: Self.capacity)
        }
        microphonePositions = [Int64](repeating: -1, count: Self.capacity)
        canceller = sa_aec_create(echo ? 1 : 0, noise ? 1 : 0)
        if echo { echoStatus = canceller == nil ? "Bypassed: echo processor unavailable" : "Waiting for playback reference" }
    }

    /// Separate routing: reference audio never enters the broadcast system bus.
    func appendReference(_ sample: CMSampleBuffer) throws {
        lock.lock()
        let enabled = configuration.microphoneEnabled && configuration.microphoneEchoCancellationEnabled
        let revision = self.revision
        lock.unlock()
        guard enabled else { return }
        try referenceConverter.convert(sample) { pointer, frames in
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            lock.lock(); defer { lock.unlock() }
            guard revision == self.revision else { return }
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            guard timestamp.isFinite, abs(timestamp - hostNow) < 10 else {
                throw OutputError.message("Reference timestamps are outside the host clock")
            }
            var first = Int64(((timestamp - epoch) * 48_000).rounded())
            // Adjacent buffers from independent capture clocks can round one or
            // two frames apart. Larger discontinuities remain actual gaps.
            if let nextReferencePosition, abs(first - nextReferencePosition) <= 2 { first = nextReferencePosition }
            nextReferencePosition = first + Int64(frames)
            let boundary = max(0, cursor - AudioSync.frames(configuration.microphoneSyncOffsetMs))
            for frame in 0..<frames {
                let position = first + Int64(frame)
                guard position >= boundary, position < boundary + Int64(Self.capacity) else { continue }
                let slot = Int(position % Int64(Self.capacity))
                referencePositions[slot] = position
                reference[slot * 2] = pointer[frame * 2]
                reference[slot * 2 + 1] = pointer[frame * 2 + 1]
            }
        }
    }

    /// Cache one complete DSP block, independent of the caller's pull size.
    /// Incomplete blocks bypass in place; no samples are delayed or replayed.
    private func prepareEchoBlock(at start: Int64) {
        cleanedStart = -1; nextBlock = start + 480
        guard let canceller else { return }
        let echo = configuration.microphoneEchoCancellationEnabled
        var hasMicrophone = true
        var hasReference = true
        for frame in 0..<480 {
            let position = start + Int64(frame)
            let slot = Int(position % Int64(Self.capacity))
            let micValid = microphonePositions[slot] == position
            let refValid = echo && referencePositions[slot] == position
            hasMicrophone = hasMicrophone && micValid
            hasReference = hasReference && (!echo || refValid)
            microphoneBlock[frame * 2] = micValid ? microphone[slot * 2] : 0
            microphoneBlock[frame * 2 + 1] = micValid ? microphone[slot * 2 + 1] : 0
            referenceBlock[frame * 2] = refValid ? reference[slot * 2] : 0
            referenceBlock[frame * 2 + 1] = refValid ? reference[slot * 2 + 1] : 0
        }
        // Advance DSP time through gaps; AEC still requires complete reference
        // coverage to publish. NS alone never consumes playback reference.
        let result = referenceBlock.withUnsafeBufferPointer { reference in
            microphoneBlock.withUnsafeBufferPointer { microphone in
                cleanedBlock.withUnsafeMutableBufferPointer { output in
                    sa_aec_process(canceller, echo ? reference.baseAddress! : nil, microphone.baseAddress!, output.baseAddress!)
                }
            }
        }
        guard result == 0 else {
            echoStatus = echo ? "Bypassed: echo processor failed" : nil; return
        }
        guard hasMicrophone else { echoStatus = echo ? "Bypassed: waiting for microphone audio" : nil; return }
        guard hasReference else { echoStatus = "Bypassed: playback reference missing or stale"; return }
        cleanedStart = start; echoStatus = echo ? "Active" : nil
    }

    func reset(configuration: StudioConfiguration, synthetic: Bool, epoch: Double = CMClockGetTime(CMClockGetHostTimeClock()).seconds) {
        lock.lock(); defer { lock.unlock() }
        self.configuration = configuration; self.synthetic = synthetic; requested = nil
        cursor = 0; self.epoch = epoch
        microphone.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        system.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        microphoneCompressor.reset(); ducker.reset()
        outputProtectionGain = 1
        meters = (0, 0, 0, 0, 0); pendingMeters = (0, 0, 0, 0, 0)
        microphoneLoudness.reset(); systemLoudness.reset(); outputLoudness.reset()
        resetEcho()
    }
    /// Silences the microphone now when `newer` does, ahead of the queued update that commits it, and
    /// keeps it silent through older updates committing first (see `StudioConfiguration.hiding(as:)`).
    /// If that update fails, the mask stays until the next request: failing safe, like the video mask.
    func hide(as newer: StudioConfiguration) {
        lock.lock(); requested = newer; let current = configuration; lock.unlock()
        configure(current)
    }
    func configure(_ next: StudioConfiguration) {
        lock.lock(); defer { lock.unlock() }
        let configuration = requested.map { next.hiding(as: $0) } ?? next
        if self.configuration.microphoneEnabled != configuration.microphoneEnabled || self.configuration.microphoneID != configuration.microphoneID ||
            self.configuration.microphoneChannels != configuration.microphoneChannels ||
            self.configuration.microphoneSyncOffsetMs != configuration.microphoneSyncOffsetMs {
            microphone.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        }
        if self.configuration.systemAudioEnabled != configuration.systemAudioEnabled ||
            self.configuration.systemAudioSyncOffsetMs != configuration.systemAudioSyncOffsetMs {
            system.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        }
        if self.configuration.microphoneCompressionEnabled && !configuration.microphoneCompressionEnabled {
            microphoneCompressor.reset()
            meters.gainReduction = 0; pendingMeters.gainReduction = 0
        }
        if configuration.systemAudioDucking == .off { ducker.reset() }
        if (!self.configuration.microphoneSilenced && configuration.microphoneSilenced) ||
            self.configuration.microphoneEnabled != configuration.microphoneEnabled {
            microphoneCompressor.reset()
            meters.microphone = 0; meters.gainReduction = 0
            pendingMeters.microphone = 0; pendingMeters.gainReduction = 0
            microphoneLoudness.reset()
        }
        if (!self.configuration.systemAudioMuted && configuration.systemAudioMuted) || self.configuration.systemAudioEnabled != configuration.systemAudioEnabled {
            meters.system = 0; pendingMeters.system = 0
            systemLoudness.reset()
        }
        let resetEchoState = self.configuration.microphoneEchoCancellationEnabled != configuration.microphoneEchoCancellationEnabled ||
            self.configuration.microphoneEnabled != configuration.microphoneEnabled ||
            self.configuration.microphoneID != configuration.microphoneID ||
            self.configuration.microphoneChannels != configuration.microphoneChannels ||
            self.configuration.microphoneSyncOffsetMs != configuration.microphoneSyncOffsetMs
        let noiseChanged = self.configuration.microphoneNoiseReductionEnabled != configuration.microphoneNoiseReductionEnabled
        self.configuration = configuration
        if resetEchoState {
            resetEcho()
        } else if noiseChanged {
            if configuration.microphoneEnabled && configuration.microphoneEchoCancellationEnabled, let canceller {
                // Keep the learned echo filter, queued reference and current cached
                // block. NS takes effect on the next complete processing block.
                if sa_aec_set_noise_reduction(canceller, configuration.microphoneNoiseReductionEnabled ? 1 : 0) != 0 {
                    sa_aec_destroy(canceller); self.canceller = nil
                    cleanedStart = -1
                    echoStatus = "Bypassed: echo processor failed"
                }
            } else {
                resetEcho()
            }
        }
    }
    func append(_ sample: CMSampleBuffer, microphone isMicrophone: Bool, hostTimestamp: Double? = nil) throws {
        lock.lock()
        let enabled = isMicrophone ? configuration.microphoneEnabled : configuration.systemAudioEnabled
        let selection = isMicrophone ? configuration.microphoneChannels : .deviceDefault
        let revision = self.revision
        lock.unlock()
        guard enabled else { return }
        let converter = isMicrophone ? microphoneConverter : systemConverter
        try converter.convert(sample, selection: selection) { pointer, frames in
            let timestamp = hostTimestamp ?? CMSampleBufferGetPresentationTimeStamp(sample).seconds
            lock.lock(); defer { lock.unlock() }
            guard isMicrophone ? configuration.microphoneEnabled : configuration.systemAudioEnabled else { return }
            guard revision == self.revision else { return }
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            guard timestamp.isFinite, abs(timestamp - hostNow) < 10 else {
                throw OutputError.message("Audio device returned timestamps outside the host clock")
            }
            var first = Int64(((timestamp - epoch) * 48_000).rounded())
            if isMicrophone && (configuration.microphoneEchoCancellationEnabled || configuration.microphoneNoiseReductionEnabled) {
                if let nextMicrophonePosition, abs(first - nextMicrophonePosition) <= 2 { first = nextMicrophonePosition }
                nextMicrophonePosition = first + Int64(frames)
            }
            let boundary = max(0, cursor - AudioSync.frames(isMicrophone ? configuration.microphoneSyncOffsetMs : configuration.systemAudioSyncOffsetMs))
            for frame in 0..<frames {
                let position = first + Int64(frame)
                guard position >= boundary, position < boundary + Int64(Self.capacity) else { continue }
                let index = Int(position % Int64(Self.capacity)) * 2
                if isMicrophone {
                    microphone[index] = pointer[frame * 2]; microphone[index + 1] = pointer[frame * 2 + 1]
                    if !microphonePositions.isEmpty { microphonePositions[index / 2] = position }
                }
                else { system[index] = pointer[frame * 2]; system[index + 1] = pointer[frame * 2 + 1] }
            }
        }
    }

    /// Writer owns the reusable output buffer and advances one media clock.
    func pull(into destination: UnsafeMutableBufferPointer<Float>) {
        lock.lock(); defer { lock.unlock() }
        let c = configuration
        let frames = destination.count / 2
        let micGain = c.microphoneEnabled && !c.microphoneSilenced ? Float(c.microphoneGain) : 0
        let sysGain = c.systemAudioEnabled && !c.systemAudioMuted ? Float(c.systemAudioGain) : 0
        let ducking = c.systemAudioDucking != .off
        let duckedGain = Float(pow(10, -c.systemAudioDucking.depth / 20))
        var micPeak: Float = 0
        var sysPeak: Float = 0
        var outputPeak: Float = 0
        var minimumGain: Float = 1
        var minimumLimiterGain: Float = 1
        let micOffset = AudioSync.frames(c.microphoneSyncOffsetMs)
        let sysOffset = AudioSync.frames(c.systemAudioSyncOffsetMs)
        let processingEnabled = c.microphoneEnabled && (c.microphoneEchoCancellationEnabled || c.microphoneNoiseReductionEnabled) && !synthetic
        var offset = 0
        while offset < frames {
            // AEC's microphone and private reference always use the same raw time.
            // Presentation offsets move the processed bus, never the echo path.
            let start = cursor + Int64(offset) - micOffset
            if processingEnabled && start >= 0 && start >= nextBlock { prepareEchoBlock(at: start) }
            let end = processingEnabled && start >= 0 ? min(frames, offset + Int(nextBlock - start)) :
                (processingEnabled && start < 0 ? min(frames, offset + Int(-start)) : frames)
            for frame in offset..<end {
            let position = cursor + Int64(frame)
            let micPosition = position - micOffset
            let sysPosition = position - sysOffset
            let micIndex = Int(max(0, micPosition) % Int64(Self.capacity)) * 2
            let sysIndex = Int(max(0, sysPosition) % Int64(Self.capacity)) * 2
            let micSignal = synthetic ? Float(sin(Double(micPosition) * 2 * .pi * 440 / 48_000) * 0.12) : 0
            let sysSignal = synthetic ? Float(sin(Double(sysPosition) * 2 * .pi * 880 / 48_000) * 0.08) : 0
            let cleanedOffset = Int(micPosition - cleanedStart) * 2
            let useCleaned = processingEnabled && cleanedStart >= 0 && cleanedOffset >= 0 && cleanedOffset < 960
            var micLeft = micPosition < 0 ? 0 : (synthetic ? micSignal : (useCleaned ? cleanedBlock[cleanedOffset] : microphone[micIndex])) * micGain
            var micRight = micPosition < 0 ? 0 : (synthetic ? micSignal : (useCleaned ? cleanedBlock[cleanedOffset + 1] : microphone[micIndex + 1])) * micGain
            if c.microphoneCompressionEnabled && micGain > 0 {
                let compressed = microphoneCompressor.process(left: micLeft, right: micRight)
                micLeft = compressed.left; micRight = compressed.right
                minimumGain = min(minimumGain, compressed.gain)
            }
            var sysLeft = sysPosition < 0 ? 0 : (synthetic ? sysSignal : system[sysIndex]) * sysGain
            var sysRight = sysPosition < 0 ? 0 : (synthetic ? sysSignal : system[sysIndex + 1]) * sysGain
            if ducking {
                let duck = ducker.process(trigger: max(abs(micLeft), abs(micRight)), duckedGain: duckedGain)
                sysLeft *= duck; sysRight *= duck
            }
            micPeak = max(micPeak, abs(micLeft), abs(micRight))
            sysPeak = max(sysPeak, abs(sysLeft), abs(sysRight))
            microphoneLoudness.process(left: micLeft, right: micRight)
            systemLoudness.process(left: sysLeft, right: sysRight)
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
            minimumLimiterGain = min(minimumLimiterGain, outputProtectionGain)
            let outLeft = sumLeft * outputProtectionGain
            let outRight = sumRight * outputProtectionGain
            destination[frame * 2] = outLeft
            destination[frame * 2 + 1] = outRight
            outputPeak = max(outputPeak, abs(outLeft), abs(outRight))
            outputLoudness.process(left: outLeft, right: outRight)
            if micPosition >= 0 { microphone[micIndex] = 0; microphone[micIndex + 1] = 0 }
            if sysPosition >= 0 { system[sysIndex] = 0; system[sysIndex + 1] = 0 }
            }
            offset = end
        }
        cursor += Int64(frames)
        let reductionPeak = minimumGain < 1 ? -20 * log10(minimumGain) : 0
        let limiterPeak = minimumLimiterGain < 1 ? -20 * log10(minimumLimiterGain) : 0
        let release = Float(pow(meterReleasePerSample, Double(frames)))
        meters.microphone = max(micPeak, meters.microphone * release)
        meters.system = max(sysPeak, meters.system * release)
        meters.output = max(outputPeak, meters.output * release)
        meters.gainReduction = max(reductionPeak, meters.gainReduction * release)
        pendingMeters.microphone = max(pendingMeters.microphone, micPeak)
        pendingMeters.system = max(pendingMeters.system, sysPeak)
        pendingMeters.output = max(pendingMeters.output, outputPeak)
        pendingMeters.gainReduction = max(pendingMeters.gainReduction, reductionPeak)
        meters.limiterReduction = max(limiterPeak, meters.limiterReduction * release)
        pendingMeters.limiterReduction = max(pendingMeters.limiterReduction, limiterPeak)
    }
    var levels: Levels {
        lock.lock(); defer { lock.unlock() }
        func level(_ peak: Float, _ loudness: LoudnessMeter) -> AudioLevel {
            AudioLevel(peak: peak, momentary: loudness.momentary, shortTerm: loudness.shortTerm)
        }
        let result = (microphone: level(max(meters.microphone, pendingMeters.microphone), microphoneLoudness),
                      system: level(max(meters.system, pendingMeters.system), systemLoudness),
                      output: level(max(meters.output, pendingMeters.output), outputLoudness),
                      gainReduction: max(meters.gainReduction, pendingMeters.gainReduction),
                      limiterReduction: max(meters.limiterReduction, pendingMeters.limiterReduction))
        pendingMeters = (0, 0, 0, 0, 0)
        return result
    }
}

/// ITU-R BS.1770 loudness for 48 kHz stereo, metered per EBU Tech 3341 (ungated): K-weighted
/// mean square in 100 ms blocks, averaged over the last 400 ms (momentary) or 3 s (short-term).
/// Two biquads per channel per sample; readers only sum 30 block values.
final class LoudnessMeter {
    private struct Biquad {
        let b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }
    // BS.1770 K-weighting at 48 kHz: head-effect shelf, then RLB high-pass.
    private static let shelf = Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
                                      a1: -1.69065929318241, a2: 0.73248077421585)
    private static let highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: -1.99004745483398, a2: 0.99007225036621)
    private static let blockFrames = 4_800
    private var leftShelf = shelf, leftHighPass = highPass
    private var rightShelf = shelf, rightHighPass = highPass
    private var sum = 0.0
    private var count = 0
    private var blocks = [Double](repeating: 0, count: 30)
    private var next = 0
    private var filled = 0

    func process(left: Float, right: Float) {
        let l = leftHighPass.process(leftShelf.process(Double(left)))
        let r = rightHighPass.process(rightShelf.process(Double(right)))
        sum += l * l + r * r
        count += 1
        guard count == Self.blockFrames else { return }
        blocks[next] = sum / Double(Self.blockFrames)
        next = (next + 1) % blocks.count
        filled = min(filled + 1, blocks.count)
        sum = 0; count = 0
    }

    var momentary: Double { loudness(blocks: 4) }
    var shortTerm: Double { loudness(blocks: 30) }

    private func loudness(blocks wanted: Int) -> Double {
        let n = min(wanted, filled)
        guard n > 0 else { return -.infinity }
        var total = 0.0
        for age in 1...n { total += blocks[(next - age + blocks.count) % blocks.count] }
        return total > 0 ? -0.691 + 10 * log10(total / Double(n)) : -.infinity
    }

    func reset() {
        leftShelf = Self.shelf; leftHighPass = Self.highPass
        rightShelf = Self.shelf; rightHighPass = Self.highPass
        sum = 0; count = 0; next = 0; filled = 0
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

/// Voice-keyed ducker for the app-audio bus. A sample peak above −36 dBFS on the mixed microphone
/// (OBS's documented sidechain threshold) marks speech and holds it for 200 ms so gaps between words
/// do not pump. Gain moves toward the ducked level with a 50 ms time constant and recovers with
/// 600 ms (OBS's documented release), within published 20–100 ms attack / 250–800 ms release ranges.
private struct Ducker {
    private var gain: Float = 1
    private var holdRemaining = 0
    private let threshold: Float = 0.015_849 // −36 dBFS
    private let holdSamples = 9_600
    private let attack: Float = Float(1 - exp(-1 / (0.050 * 48_000)))
    private let release: Float = Float(1 - exp(-1 / (0.600 * 48_000)))

    mutating func reset() { gain = 1; holdRemaining = 0 }

    mutating func process(trigger: Float, duckedGain: Float) -> Float {
        if trigger > threshold { holdRemaining = holdSamples } else if holdRemaining > 0 { holdRemaining -= 1 }
        let target: Float = holdRemaining > 0 ? duckedGain : 1
        gain += (target - gain) * (target < gain ? attack : release)
        return gain
    }
}

/// Each source owns a converter; AVAudioConverter preserves resampling phase.
private final class PCMConverter: @unchecked Sendable {
    private let lock = NSLock()
    private var inputFormat: AVAudioFormat?
    private var layoutConverter: AVAudioConverter?
    private var planarInput: AVAudioPCMBuffer?
    private var inputDescription: CMAudioFormatDescription?
    private var selection: AudioChannelSelection = .deviceDefault
    private var converter: AVAudioConverter?
    private var input: AVAudioPCMBuffer?
    private var output: AVAudioPCMBuffer?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!

    func reset() {
        lock.lock(); defer { lock.unlock() }
        converter?.reset()
        layoutConverter?.reset()
    }

    func convert(_ sample: CMSampleBuffer, selection: AudioChannelSelection = .deviceDefault,
                 consume: (UnsafePointer<Float>, Int) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard let description = CMSampleBufferGetFormatDescription(sample) else { throw OutputError.message("Missing audio format") }
        if inputDescription == nil || !CMFormatDescriptionEqual(inputDescription!, otherFormatDescription: description) || self.selection != selection {
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            inputDescription = description; inputFormat = format
            let map = selection.channelMap(channelCount: Int(format.channelCount))
            // Core Audio's channel-map fast path mis-strides interleaved multichannel
            // input when reducing channel count. Normalize layout (not routing) first;
            // the mapping converter still selects native channels before downmix/SRC.
            var mappedFormat = format
            layoutConverter = nil; planarInput = nil
            if map != nil && format.isInterleaved && format.channelCount > 2 {
                let layout = format.channelLayout ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | format.channelCount)!
                mappedFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, interleaved: false, channelLayout: layout)
                layoutConverter = AVAudioConverter(from: format, to: mappedFormat)
                guard layoutConverter != nil else { throw OutputError.message("Unsupported interleaved device layout") }
            }
            converter = AVAudioConverter(from: mappedFormat, to: target); input = nil; output = nil
            self.selection = selection
            if let map { converter?.channelMap = map }
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
        var conversionInput = input
        if let layoutConverter {
            if planarInput == nil || planarInput!.frameCapacity < frames {
                planarInput = AVAudioPCMBuffer(pcmFormat: layoutConverter.outputFormat, frameCapacity: AVAudioFrameCount(frames))
            }
            guard let planarInput else { throw OutputError.message("Cannot allocate device layout buffer") }
            try layoutConverter.convert(to: planarInput, from: input)
            conversionInput = planarInput
        }
        var provided = false; var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, state in
            if provided { state.pointee = .noDataNow; return nil }
            provided = true; state.pointee = .haveData; return conversionInput
        }
        guard result != .error else { throw error ?? OutputError.message("Audio conversion failed") as NSError }
        let buffer = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)[0]
        if output.frameLength > 0, let data = buffer.mData {
            try consume(data.assumingMemoryBound(to: Float.self), Int(output.frameLength))
        }
    }
}
