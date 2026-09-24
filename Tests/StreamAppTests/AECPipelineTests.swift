import AVFoundation
import CoreMedia
import Testing
import EchoCancellation
@testable import StreamApp

struct AECPipelineTests {
    @Test func referenceNeverLeaksIntoSystemMixAndMissingReferencePreservesStereo() throws {
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        let mic = try sample(time: time, frames: 960, left: 0.2, right: -0.1)
        let reference = try sample(time: time, frames: 480, left: 0.5, right: 0.4)
        var c = configuration()
        let mixer = AudioMixer()
        mixer.reset(configuration: c, synthetic: false, epoch: time.seconds)
        try mixer.appendReference(reference)
        // Reference-only capture cannot be audible, even with system gain enabled.
        var output = [Float](repeating: 1, count: 960)
        output.withUnsafeMutableBufferPointer { mixer.pull(into: $0) }
        #expect(output.allSatisfy { $0 == 0 })
        mixer.reset(configuration: c, synthetic: false, epoch: time.seconds)
        try mixer.append(mic, microphone: true)
        output.withUnsafeMutableBufferPointer { mixer.pull(into: $0) }
        #expect(output[0] == 0.2 && output[1] == -0.1)
        c.microphoneEchoCancellationEnabled = false
        mixer.configure(c)
        output.withUnsafeMutableBufferPointer { mixer.pull(into: $0) }
        #expect(output[0] == 0.2 && output[1] == -0.1)
        #expect(mixer.echoCancellationStatus == nil)
    }

    @Test func processingIsIndependentOfPullBoundariesAndReferenceTailBypasses() throws {
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        let mic = try sample(time: time, frames: 1440, left: 0.2, right: -0.1)
        let reference = try sample(time: time, frames: 960, left: 0, right: 0)
        let whole = AudioMixer(), split = AudioMixer()
        for mixer in [whole, split] {
            mixer.reset(configuration: configuration(), synthetic: false, epoch: time.seconds)
            try mixer.append(mic, microphone: true)
            try mixer.appendReference(reference)
        }
        var expected = [Float](repeating: 0, count: 2880)
        expected.withUnsafeMutableBufferPointer { whole.pull(into: $0) }
        var actual: [Float] = []
        for frames in [137, 481, 22, 320, 480] {
            var part = [Float](repeating: 0, count: frames * 2)
            part.withUnsafeMutableBufferPointer { split.pull(into: $0) }
            actual.append(contentsOf: part)
        }
        #expect(actual == expected)
        #expect(actual[1918] == actual[1919]) // Cleaned microphone is mono.
        #expect(actual[1920] == 0.2 && actual[1921] == -0.1) // Expired reference is not replayed.
    }

    @Test func toggleCannotReuseOldReference() throws {
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        let mic = try sample(time: time, frames: 960, left: 0.2, right: -0.1)
        let reference = try sample(time: time, frames: 960, left: 0, right: 0)
        var c = configuration()
        let mixer = AudioMixer()
        mixer.reset(configuration: c, synthetic: false, epoch: time.seconds)
        try mixer.append(mic, microphone: true)
        try mixer.appendReference(reference)
        var block = [Float](repeating: 0, count: 960)
        block.withUnsafeMutableBufferPointer { mixer.pull(into: $0) }
        #expect(block[0] == block[1])
        c.microphoneEchoCancellationEnabled = false; mixer.configure(c)
        c.microphoneEchoCancellationEnabled = true; mixer.configure(c)
        block.withUnsafeMutableBufferPointer { mixer.pull(into: $0) }
        #expect(block[0] == 0.2 && block[1] == -0.1)
    }

    @Test func noiseReductionWithoutReferenceAndDisablingItRestoresRawStereo() throws {
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        var c = configuration()
        c.microphoneEchoCancellationEnabled = false
        c.microphoneNoiseReductionEnabled = true
        let mixer = AudioMixer()
        mixer.reset(configuration: c, synthetic: false, epoch: time.seconds)
        try mixer.append(sample(time: time, frames: 960, left: 0.2, right: -0.1), microphone: true)
        var output = [Float](repeating: 0, count: 960)
        output.withUnsafeMutableBufferPointer { mixer.pull(into: $0) }
        // No playback reference was supplied: NS must still process the mic,
        // rather than taking the asymmetric raw-stereo fallback used by AEC.
        for frame in 0..<480 {
            #expect(output[frame * 2].isFinite)
            #expect(output[frame * 2] == output[frame * 2 + 1])
        }
        #expect(output.contains { $0 != 0 })
        #expect(mixer.echoCancellationStatus == nil)
        c.microphoneNoiseReductionEnabled = false
        mixer.configure(c)
        output.withUnsafeMutableBufferPointer { mixer.pull(into: $0) }
        for frame in 0..<480 {
            #expect(output[frame * 2] == 0.2)
            #expect(output[frame * 2 + 1] == -0.1)
        }
        #expect(mixer.echoCancellationStatus == nil)
    }

    @Test func noiseTogglePreservesLearnedEchoCancellation() throws {
        let control = try #require(sa_aec_create(1, 0))
        defer { sa_aec_destroy(control) }
        let toggled = try #require(sa_aec_create(1, 0))
        defer { sa_aec_destroy(toggled) }
        var reference = [Float](repeating: 0, count: 960)
        var microphone = reference, expected = reference, actual = reference
        var seed: UInt32 = 4829
        for block in 0..<1500 {
            if block == 1000 { #expect(sa_aec_set_noise_reduction(toggled, 1) == 0) }
            if block == 1200 { #expect(sa_aec_set_noise_reduction(toggled, 0) == 0) }
            for frame in 0..<480 {
                seed = 1664525 &* seed &+ 1013904223
                let playback = (Float(seed >> 8) / 16_777_216 - 0.5) * 0.15
                let voice = Float(sin(Double(block * 480 + frame) * 0.047)) * 0.008
                reference[2 * frame] = playback; reference[2 * frame + 1] = playback
                microphone[2 * frame] = 0.3 * playback + voice
                microphone[2 * frame + 1] = microphone[2 * frame]
            }
            #expect(sa_aec_process(control, reference, microphone, &expected) == 0)
            #expect(sa_aec_process(toggled, reference, microphone, &actual) == 0)
            // Once optional cleanup is off, cancellation must immediately match
            // uninterrupted AEC—not restart its room-learning/convergence phase.
            if block < 1000 || block >= 1200 { #expect(actual == expected) }
        }
    }

    private func configuration() -> StudioConfiguration {
        var c = StudioConfiguration()
        c.microphoneEnabled = true; c.microphoneMuted = false; c.microphoneGain = 1
        c.microphoneCompressionEnabled = false; c.microphoneEchoCancellationEnabled = true
        c.microphoneNoiseReductionEnabled = false
        c.systemAudioEnabled = true; c.systemAudioMuted = false; c.systemAudioGain = 1
        return c
    }

    private func sample(time: CMTime, frames: Int, left: Float, right: Float) throws -> CMSampleBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        let values = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)[0].mData!.assumingMemoryBound(to: Float.self)
        for frame in 0..<frames { values[frame * 2] = left; values[frame * 2 + 1] = right }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        let status = CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                         formatDescription: format.formatDescription, sampleCount: frames,
                                         sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result)
        #expect(status == noErr)
        let buffer = try #require(result)
        #expect(CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                             flags: 0, bufferList: pcm.audioBufferList) == noErr)
        CMSampleBufferSetDataReady(buffer)
        return buffer
    }
}
