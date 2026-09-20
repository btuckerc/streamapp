import AVFoundation
import CoreMedia
import Testing
@testable import StreamApp

struct AudioMixerTests {
    @Test(arguments: [false, true])
    func preservesStereoAcrossPCMLayouts(interleaved: Bool) throws {
        let mixer = AudioMixer()
        var settings = StudioConfiguration(); settings.microphoneEnabled = true
        settings.microphoneCompressionEnabled = false
        mixer.reset(configuration: settings, synthetic: false)
        try mixer.append(try sample(interleaved: interleaved, left: 0.25, right: -0.5), microphone: true)
        var output = [Float](repeating: 0, count: 9600)
        output.withUnsafeMutableBufferPointer { mixer.pull(into: $0) }
        let left = stride(from: 0, to: output.count, by: 2).map { output[$0] }
        let right = stride(from: 1, to: output.count, by: 2).map { output[$0] }
        #expect(abs((left.max() ?? 0) - 0.25) < 0.001)
        #expect(abs((right.min() ?? 0) + 0.5) < 0.001)
        #expect(left.filter { $0 > 0.2 }.count >= 800)
        #expect(right.filter { $0 < -0.4 }.count >= 800)
    }

    @Test func muteDoesNotReplayBufferedAudioAndLateSamplesAreDiscarded() throws {
        let mixer = AudioMixer()
        var settings = StudioConfiguration(); settings.microphoneEnabled = true
        mixer.reset(configuration: settings, synthetic: false)
        let original = try sample(interleaved: false, left: 0.8, right: 0.8)
        try mixer.append(original, microphone: true)
        settings.microphoneMuted = true; mixer.configure(settings)
        var output = [Float](repeating: 1, count: 9600)
        output.withUnsafeMutableBufferPointer { mixer.pull(into: $0) }
        #expect(output.allSatisfy { $0 == 0 })
        settings.microphoneMuted = false; mixer.configure(settings)
        try mixer.append(original, microphone: true) // Timestamp is behind consumed media time.
        output.withUnsafeMutableBufferPointer { mixer.pull(into: $0) }
        #expect(output.allSatisfy { $0 == 0 })
    }

    @Test func mixedPeaksAreBounded() throws {
        let mixer = AudioMixer()
        var settings = StudioConfiguration(); settings.microphoneEnabled = true; settings.systemAudioEnabled = true
        mixer.reset(configuration: settings, synthetic: false)
        let buffer = try sample(interleaved: true, left: 0.8, right: -0.8)
        try mixer.append(buffer, microphone: true); try mixer.append(buffer, microphone: false)
        var output = [Float](repeating: 0, count: 9600)
        output.withUnsafeMutableBufferPointer { mixer.pull(into: $0) }
        #expect((output.max() ?? 0) > 0.88); #expect((output.min() ?? 0) < -0.88)
        #expect(output.allSatisfy { $0.isFinite && abs($0) <= 0.89126 })
    }

    @Test func meterPreservesBriefPeakUntilReadAndMuteClearsIt() throws {
        let mixer = AudioMixer()
        var settings = StudioConfiguration(); settings.microphoneEnabled = true; settings.microphoneCompressionEnabled = false
        let input = try sample(interleaved: true, left: 0.5, right: -0.25)
        mixer.reset(configuration: settings, synthetic: false, epoch: CMSampleBufferGetPresentationTimeStamp(input).seconds)
        try mixer.append(input, microphone: true)
        var block = [Float](repeating: 0, count: 1920)
        for _ in 0..<12 { block.withUnsafeMutableBufferPointer { mixer.pull(into: $0) } }
        let levels = mixer.levels
        #expect(abs(levels.microphone - 0.5) < 0.001)
        #expect(abs(levels.output - 0.5) < 0.001)
        settings.microphoneMuted = true; mixer.configure(settings)
        #expect(mixer.levels.microphone == 0)
    }

    @Test func compressionIsStereoLinkedAndIndependentOfPullBoundaries() throws {
        var settings = StudioConfiguration(); settings.microphoneEnabled = true
        let input = try sample(interleaved: true, left: 0.8, right: -0.4, frames: 48000)
        let whole = AudioMixer(); let split = AudioMixer()
        for mixer in [whole, split] {
            mixer.reset(configuration: settings, synthetic: false, epoch: CMSampleBufferGetPresentationTimeStamp(input).seconds)
            try mixer.append(input, microphone: true)
        }
        var all = [Float](repeating: 0, count: 96000)
        all.withUnsafeMutableBufferPointer { whole.pull(into: $0) }
        var blocks = [Float]()
        var block = [Float](repeating: 0, count: 1920)
        for _ in 0..<50 { block.withUnsafeMutableBufferPointer { split.pull(into: $0) }; blocks.append(contentsOf: block) }
        #expect(all == blocks)
        #expect(all[90000] < 0.4 && all[90000] > 0.1)
        #expect(abs(all[90001] / all[90000] + 0.5) < 0.001)
        #expect(whole.levels.gainReduction > 6)
    }

    private func sample(interleaved: Bool, left: Float, right: Float, frames: Int = 960) throws -> CMSampleBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        let buffers = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        if interleaved {
            let values = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<frames { values[i * 2] = left; values[i * 2 + 1] = right }
        } else {
            buffers[0].mData!.assumingMemoryBound(to: Float.self).initialize(repeating: left, count: frames)
            buffers[1].mData!.assumingMemoryBound(to: Float.self).initialize(repeating: right, count: frames)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        let created = CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                          formatDescription: format.formatDescription, sampleCount: frames,
                                          sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result)
        #expect(created == noErr)
        let sample = try #require(result)
        let copied = CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList)
        #expect(copied == noErr); CMSampleBufferSetDataReady(sample)
        return sample
    }
}
