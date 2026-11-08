import AVFoundation
import CoreMedia
import Testing
@testable import StreamApp

struct AudioMixerTests {
    @Test func legacyVisualAudioScopeCannotExpandToAllAppsOnUpgrade() throws {
        let legacy = Data(#"{"systemAudioEnabled":true,"microphoneEnabled":true,"systemAudioGain":0.75,"excludedApplicationIDs":["private.app"]}"#.utf8)
        var settings = try JSONDecoder().decode(StudioConfiguration.self, from: legacy)
        #expect(!settings.systemAudioEnabled)
        #expect(settings.microphoneEnabled && settings.systemAudioGain == 0.75)
        settings.systemAudioApplicationID = "com.ableton.live"
        settings.systemAudioEnabled = true
        let restored = try JSONDecoder().decode(StudioConfiguration.self, from: JSONEncoder().encode(settings))
        #expect(restored.systemAudioEnabled && restored.systemAudioApplicationID == "com.ableton.live")
        settings.systemAudioApplicationID = ""
        let allApps = try JSONDecoder().decode(StudioConfiguration.self, from: JSONEncoder().encode(settings))
        #expect(allApps.systemAudioEnabled && allApps.systemAudioApplicationID.isEmpty)
    }

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

    @Test func awaySceneSilencesTheMicrophoneUnlessTurnedOff() throws {
        var settings = StudioConfiguration(); settings.microphoneEnabled = true; settings.microphoneCompressionEnabled = false
        settings.layout = .away
        let input = try sample(interleaved: true, left: 0.5, right: 0.5)
        for mutes in [true, false] {
            settings.awayMutesMicrophone = mutes
            let mixer = AudioMixer()
            mixer.reset(configuration: settings, synthetic: false, epoch: CMSampleBufferGetPresentationTimeStamp(input).seconds)
            try mixer.append(input, microphone: true)
            var block = [Float](repeating: 0, count: 1920)
            for _ in 0..<12 { block.withUnsafeMutableBufferPointer { mixer.pull(into: $0) } }
            #expect(abs(mixer.levels.output.peak - (mutes ? 0 : 0.5)) < 0.001)
        }
    }

    /// Away chosen while a slower switch (say, to Desktop) still waits for its source: the room is
    /// silent from the next block, stays silent while that older switch commits, and is heard again
    /// only once the change back to Desktop commits. Away that only covers a lost webcam stays live.
    @Test(arguments: [false, true])
    func awayRequestedBehindASlowerSwitchSilencesAtOnce(coversWebcam: Bool) throws {
        var fullCamera = StudioConfiguration(); fullCamera.microphoneEnabled = true; fullCamera.microphoneCompressionEnabled = false
        fullCamera.layout = .justChatting
        var desktop = fullCamera; desktop.layout = .desktopChat
        var away = fullCamera; away.layout = .away; away.awayCoversWebcam = coversWebcam
        let input = try sample(interleaved: true, left: 0.5, right: 0.5, frames: 48_000)
        let mixer = AudioMixer()
        mixer.reset(configuration: fullCamera, synthetic: false, epoch: CMSampleBufferGetPresentationTimeStamp(input).seconds)
        try mixer.append(input, microphone: true)
        var block = [Float](repeating: 0, count: 1920)
        func peak() -> Float {
            block.withUnsafeMutableBufferPointer { mixer.pull(into: $0) }
            return block.map(abs).max() ?? 0
        }
        #expect(abs(peak() - 0.5) < 0.001)
        mixer.hide(as: desktop) // Full Camera → Desktop requested; nothing to hide.
        #expect(abs(peak() - 0.5) < 0.001)
        mixer.hide(as: away) // Away requested before Desktop's source is ready.
        let live: Float = coversWebcam ? 0.5 : 0
        #expect(abs(peak() - live) < 0.001)
        mixer.configure(desktop) // The older Desktop update commits.
        #expect(abs(peak() - live) < 0.001)
        mixer.configure(away)
        #expect(abs(peak() - live) < 0.001)
        mixer.hide(as: desktop) // Back to Desktop: heard again only when it commits.
        #expect(abs(peak() - live) < 0.001)
        mixer.configure(desktop)
        #expect(abs(peak() - 0.5) < 0.001)
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
        #expect(abs(levels.microphone.peak - 0.5) < 0.001)
        #expect(abs(levels.output.peak - 0.5) < 0.001)
        settings.microphoneMuted = true; mixer.configure(settings)
        #expect(mixer.levels.microphone == .silent)
    }

    @Test func loudnessMatchesBS1770CalibrationAndEBUWindows() {
        // BS.1770: a 1 kHz sine in both channels reads its own dBFS level in LUFS.
        let meter = LoudnessMeter()
        for n in 0..<(3 * 48_000) {
            let value = Float(0.1 * sin(2 * Double.pi * 1_000 * Double(n) / 48_000))
            meter.process(left: value, right: value)
        }
        #expect(abs(meter.shortTerm + 20) < 0.1)
        #expect(abs(meter.momentary + 20) < 0.1)
        // 1.5 s of silence: momentary (400 ms) empties; short-term (3 s) keeps half the energy.
        for _ in 0..<(3 * 24_000) { meter.process(left: 0, right: 0) }
        #expect(meter.momentary < -60)
        #expect(abs(meter.shortTerm + 23.01) < 0.1)
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

    @Test(arguments: AudioDucking.allCases)
    func duckingLowersAppAudioOnlyWhileSpeakingThenRecovers(ducking: AudioDucking) throws {
        var settings = StudioConfiguration(); settings.microphoneEnabled = true; settings.systemAudioEnabled = true
        settings.microphoneCompressionEnabled = false; settings.systemAudioDucking = ducking
        let music = try sample(interleaved: true, left: 0.5, right: 0.5, frames: 72_000)
        let mixer = AudioMixer()
        mixer.reset(configuration: settings, synthetic: false, epoch: CMSampleBufferGetPresentationTimeStamp(music).seconds)
        try mixer.append(music, microphone: false)
        // 200 ms of speech at −20 dBFS, then silence.
        try mixer.append(try sample(interleaved: true, left: 0.1, right: 0.1, frames: 9_600), microphone: true)
        var output = [Float](repeating: 0, count: 144_000)
        output.withUnsafeMutableBufferPointer { mixer.pull(into: $0) }
        // Buffers carry creation-time stamps, so locate speech onset (music alone never exceeds 0.5).
        let onset = try #require(stride(from: 0, to: output.count, by: 2).first { output[$0] > 0.55 }) / 2
        func appGain(after frames: Int, speaking: Bool) -> Float { (output[(onset + frames) * 2] - (speaking ? 0.1 : 0)) / 0.5 }
        let ducked = Float(pow(10, -ducking.depth / 20))
        // 180 ms into speech the 50 ms attack has covered all but e^−3.6 of the dip.
        #expect(abs(appGain(after: 8_640, speaking: true) - ducked) < 0.03)
        // The 200 ms hold bridges pauses: still ducked 190 ms after speech stops.
        #expect(abs(appGain(after: 18_720, speaking: false) - ducked) < 0.03)
        // One 600 ms release time constant after the hold, 1 − 1/e of the dip has recovered.
        let recovered = 1 - (1 - ducked) * Float(exp(-1.0))
        #expect(abs(appGain(after: 47_990, speaking: false) - recovered) < 0.02)
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
