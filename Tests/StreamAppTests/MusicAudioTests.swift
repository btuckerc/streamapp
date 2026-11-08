import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import StreamApp

struct MusicAudioTests {
    @Test func configurationDefaultsUnknownValuesAndBounds() throws {
        let old = try JSONDecoder().decode(StudioConfiguration.self, from: Data("{}".utf8))
        #expect(old.microphoneChannels == .deviceDefault)
        #expect(old.recordingAudioBitrateKbps == .standard)
        #expect(old.microphoneSyncOffsetMs == 0 && old.systemAudioSyncOffsetMs == 0)
        #expect(old.systemAudioDucking == .off)
        let future = try JSONDecoder().decode(StudioConfiguration.self, from: Data(#"{"microphoneChannels":{"future":{}},"recordingAudioBitrateKbps":999,"microphoneSyncOffsetMs":-999,"systemAudioSyncOffsetMs":9999,"systemAudioDucking":"future"}"#.utf8))
        #expect(future.microphoneChannels == .deviceDefault && future.recordingAudioBitrateKbps == .standard)
        #expect(future.microphoneSyncOffsetMs == -500 && future.systemAudioSyncOffsetMs == 1000)
        #expect(future.systemAudioDucking == .off)
        var c = old; c.microphoneChannels = .stereo(3, 4); c.recordingAudioBitrateKbps = .highest
        c.microphoneSyncOffsetMs = -120; c.systemAudioSyncOffsetMs = 340
        #expect(try JSONDecoder().decode(StudioConfiguration.self, from: JSONEncoder().encode(c)) == c)
    }

    @Test func channelSelectionFallsBackWhenDeviceShrinks() {
        #expect(AudioChannelSelection.mono(4).validated(channelCount: 2) == .deviceDefault)
        #expect(AudioChannelSelection.stereo(3, 4).validated(channelCount: 3) == .deviceDefault)
        #expect(AudioChannelSelection.mono(0).validated(channelCount: 4) == .deviceDefault)
        #expect(AudioChannelSelection.stereo(2, 4).validated(channelCount: 4) == .deviceDefault)
        #expect(AudioChannelSelection.stereo(3, 4).validated(channelCount: 4) == .stereo(3, 4))
        #expect(AudioChannelSelection.choices(channelCount: 4) == [.deviceDefault, .mono(1), .mono(2), .mono(3), .mono(4), .stereo(1, 2), .stereo(3, 4)])
    }

    @Test(arguments: [false, true], [44_100.0, 48_000.0, 96_000.0])
    func mapsNativeInterfaceChannelsBeforeMixing(interleaved: Bool, rate: Double) throws {
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        let input = try sample(time: time, values: [0.11, 0.22, -0.33, 0.44], frames: Int(rate / 10), rate: rate, interleaved: interleaved)
        for selection in [AudioChannelSelection.mono(2), .stereo(3, 4)] {
            var c = configuration(); c.microphoneChannels = selection
            let mixer = AudioMixer(); mixer.reset(configuration: c, synthetic: false, epoch: time.seconds)
            try mixer.append(input, microphone: true)
            let output = pull(mixer, frames: 4800)
            // Ignore SRC priming/tail: the sustained middle must contain only the selected channels.
            let expected: (Float, Float) = selection == .mono(2) ? (0.22, 0.22) : (-0.33, 0.44)
            for frame in 1000..<3000 {
                #expect(abs(output[frame * 2] - expected.0) < 0.001)
                #expect(abs(output[frame * 2 + 1] - expected.1) < 0.001)
            }
        }
    }

    @Test func deliveredChannelCountAlsoValidatesSavedMap() throws {
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        var c = configuration(); c.microphoneChannels = .stereo(3, 4)
        let mixer = AudioMixer(); mixer.reset(configuration: c, synthetic: false, epoch: time.seconds)
        try mixer.append(sample(time: time, values: [0.2, -0.3], frames: 960), microphone: true)
        let result = pull(mixer, frames: 960)
        #expect(result[0] == 0.2 && result[1] == -0.3)
    }

    @Test(arguments: [-500, -10, 0, 10, 1000], [false, true])
    func offsetsMoveExactSamplesAndNeverReplay(milliseconds: Int, microphone: Bool) throws {
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        var c = configuration()
        if microphone { c.microphoneSyncOffsetMs = milliseconds } else { c.systemAudioSyncOffsetMs = milliseconds }
        let mixer = AudioMixer(); mixer.reset(configuration: c, synthetic: false, epoch: time.seconds)
        let input = try sample(time: CMTimeAdd(time, CMTime(value: 30_000, timescale: 48_000)), values: [0.25, -0.125], frames: 960)
        try mixer.append(input, microphone: microphone)
        let expected = 30_000 + milliseconds * 48
        var output: [Float] = []
        // Odd pull sizes exercise cached DSP/ring boundaries as well as normal 20 ms blocks.
        while output.count / 2 < 80_000 { output += pull(mixer, frames: 137) }
        #expect(output[..<(expected * 2)].allSatisfy { $0 == 0 })
        #expect(output[((expected + 960) * 2)...].allSatisfy { $0 == 0 })
        #expect(stride(from: expected * 2, to: (expected + 960) * 2, by: 2).allSatisfy {
            output[$0] == 0.25 && output[$0 + 1] == -0.125
        })
        try mixer.append(input, microphone: microphone) // consumed, even for a delayed source
        #expect(pull(mixer, frames: 96_001).allSatisfy { $0 == 0 })
    }

    @Test func extremeLookaheadKeepsIndependentSourceWindowsInsideRingsAcrossWrap() throws {
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        var c = configuration(); c.microphoneSyncOffsetMs = 1000; c.systemAudioSyncOffsetMs = -500
        #expect(AudioSync.playoutMilliseconds(c) == 600)
        let mixer = AudioMixer(); mixer.reset(configuration: c, synthetic: false, epoch: time.seconds)
        _ = pull(mixer, frames: 100_000)
        // At program frame 100000, reads span raw 52000...124000 (1.5 s).
        try mixer.append(sample(time: CMTimeAdd(time, CMTime(value: 52_000, timescale: 48_000)), values: [0.2, 0], frames: 960), microphone: true)
        try mixer.append(sample(time: CMTimeAdd(time, CMTime(value: 124_000, timescale: 48_000)), values: [0, 0.3], frames: 960), microphone: false)
        let result = pull(mixer, frames: 960)
        #expect(result[0] == 0.2 && result[1] == 0.3)
        #expect(result[1918] == 0.2 && result[1919] == 0.3)
        #expect(pull(mixer, frames: 96_001).allSatisfy { $0 == 0 })
        c.microphoneEnabled = false; c.systemAudioSyncOffsetMs = 0
        #expect(AudioSync.playoutMilliseconds(c) == 100)
    }

    @Test(arguments: [false, true])
    func initiallyDisabledAdvancedSourceReservesTransportLookahead(microphone: Bool) throws {
        var c = configuration(); c.microphoneEnabled = false; c.systemAudioEnabled = false
        if microphone { c.microphoneSyncOffsetMs = -500 } else { c.systemAudioSyncOffsetMs = -500 }
        let initialPlayout = AudioSync.playoutMilliseconds(c)
        let initialArgs = MediaOutput.ffmpegArguments(configuration: c, videoPath: "video.flv", audioPath: "audio.f32",
                                                      recordingPath: "record.mp4", streamTarget: nil)
        #expect(initialPlayout == 600)
        #expect(initialArgs[initialArgs.firstIndex(of: "-thread_queue_size")! + 1] == "26")
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        let mixer = AudioMixer(); mixer.reset(configuration: c, synthetic: false, epoch: time.seconds)
        if microphone { c.microphoneEnabled = true } else { c.systemAudioEnabled = true }
        mixer.configure(c)
        #expect(AudioSync.playoutMilliseconds(c) == initialPlayout)
        #expect(MediaOutput.ffmpegArguments(configuration: c, videoPath: "video.flv", audioPath: "audio.f32",
                                            recordingPath: "record.mp4", streamTarget: nil) == initialArgs)
        // The reserved 600 ms includes 100 ms delivery headroom for raw frame 24000.
        try mixer.append(sample(time: CMTimeAdd(time, CMTime(value: 24_000, timescale: 48_000)),
                                values: [0.25, -0.125], frames: 960), microphone: microphone)
        let result = pull(mixer, frames: 960)
        #expect(stride(from: 0, to: result.count, by: 2).allSatisfy { result[$0] == 0.25 && result[$0 + 1] == -0.125 })
    }

    @Test(arguments: [false, true], [0.0, PrivacyTimeline.delay])
    func advancedFinalIntervalUsesPostStopCaptureAndSurvivesPrivacyDrain(microphone: Bool, privacySeconds: Double) throws {
        var c = configuration()
        if microphone { c.microphoneSyncOffsetMs = -500 } else { c.systemAudioSyncOffsetMs = -500 }
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        let mixer = AudioMixer(); mixer.reset(configuration: c, synthetic: false, epoch: time.seconds)
        let finalProgramFrames = 60_000
        let advance = 24_000
        try mixer.append(sample(time: time, values: [0.2, -0.1], frames: finalProgramFrames), microphone: microphone)
        var program = pull(mixer, frames: finalProgramFrames - advance)
        // Video is now frozen at 60000. Capture must remain open to supply the
        // raw interval 60000...84000, rather than turning the last 500 ms silent.
        try mixer.append(sample(time: CMTimeAdd(time, CMTime(value: Int64(finalProgramFrames), timescale: 48_000)),
                                values: [0.2, -0.1], frames: advance), microphone: microphone)
        program += pull(mixer, frames: advance)
        var ring = PCMDelayRing(delaySamples: Int(privacySeconds * 48_000) * 2, blockSamples: 1920)
        var block = [Float](repeating: 0, count: 1920)
        var emitted: [Float] = []
        program.withUnsafeBufferPointer { input in
            for start in stride(from: 0, to: input.count, by: 1920) {
                let count = block.withUnsafeMutableBufferPointer {
                    ring.append(UnsafeBufferPointer(rebasing: input[start..<min(start + 1920, input.count)]), output: $0)
                }
                emitted.append(contentsOf: block[..<count])
            }
        }
        while ring.bufferedSamples > 0 {
            let count = block.withUnsafeMutableBufferPointer { ring.flush(into: $0) }
            emitted.append(contentsOf: block[..<count])
        }
        #expect(emitted.count == finalProgramFrames * 2)
        #expect(stride(from: 0, to: emitted.count, by: 2).allSatisfy { emitted[$0] == 0.2 && emitted[$0 + 1] == -0.1 })
        #expect(pull(mixer, frames: 960).allSatisfy { $0 == 0 }) // no replay after the frozen length
    }

    @Test(arguments: [-500, 0, 1000])
    func echoReferenceStaysAtRawMicrophoneTime(milliseconds: Int) throws {
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        var c = configuration(); c.microphoneSyncOffsetMs = milliseconds; c.microphoneEchoCancellationEnabled = true
        let shifted = AudioMixer(); shifted.reset(configuration: c, synthetic: false, epoch: time.seconds)
        c.microphoneSyncOffsetMs = 0
        let control = AudioMixer(); control.reset(configuration: c, synthetic: false, epoch: time.seconds)
        let start: Int64 = 28_800 // A complete 10 ms block, after the maximum advance.
        let stamp = CMTimeAdd(time, CMTime(value: start, timescale: 48_000))
        for mixer in [shifted, control] {
            try mixer.append(sample(time: stamp, values: [0.2, -0.1], frames: 960), microphone: true)
            try mixer.appendReference(sample(time: stamp, values: [0, 0], frames: 960))
        }
        _ = pull(control, frames: Int(start))
        _ = pull(shifted, frames: Int(start) + milliseconds * 48)
        let expected = pull(control, frames: 960)
        let actual = pull(shifted, frames: 960)
        #expect(actual == expected)
        #expect(actual[0] == actual[1]) // Processing, not raw stereo fallback.
        #expect(shifted.echoCancellationStatus == "Active")
    }

    @Test func missingMicDoesNotStopProgramClockAndReconnectUsesCurrentHostTime() throws {
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        let mixer = AudioMixer(); mixer.reset(configuration: configuration(), synthetic: false, epoch: time.seconds)
        try mixer.append(sample(time: time, values: [0.25, 0.25], frames: 960), microphone: true)
        #expect(pull(mixer, frames: 960)[0] == 0.25)
        mixer.silenceMicrophone()
        #expect(pull(mixer, frames: 48_000).allSatisfy { $0 == 0 })
        // A different source continues; returning mic joins at frame 48960, not frame zero.
        let resumed = CMTimeAdd(time, CMTime(value: 48_960, timescale: 48_000))
        try mixer.append(sample(time: resumed, values: [0.1, 0.1], frames: 960), microphone: false)
        try mixer.append(sample(time: resumed, values: [0.2, 0.2], frames: 960), microphone: true)
        #expect(abs(pull(mixer, frames: 960)[0] - 0.3) < 0.00001)
        #expect(pull(mixer, frames: 96_001).allSatisfy { $0 == 0 })
    }

    @Test func finalLimiterReductionIsIndependentAndHeldUntilAtomicRead() throws {
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        let mixer = AudioMixer(); mixer.reset(configuration: configuration(), synthetic: false, epoch: time.seconds)
        let input = try sample(time: time, values: [0.8, -0.8], frames: 960)
        try mixer.append(input, microphone: true); try mixer.append(input, microphone: false)
        let result = pull(mixer, frames: 960)
        #expect(result.allSatisfy { abs($0) <= 0.89126 })
        _ = pull(mixer, frames: 48_000)
        let meters = mixer.levels
        #expect(meters.gainReduction == 0)
        #expect(meters.limiterReduction > 5 && meters.limiterReduction < 6)
    }

    @Test(arguments: RecordingAudioBitrate.allCases, RecordingFormat.allCases)
    func ffmpegMapsRecordingAndStreamBitrates(bitrate: RecordingAudioBitrate, format: RecordingFormat) {
        var c = configuration(); c.recordingAudioBitrateKbps = bitrate; c.recordingFormat = format
        for mode in OutputMode.allCases {
            c.outputMode = mode
            let args = MediaOutput.ffmpegArguments(configuration: c, videoPath: "video.flv", audioPath: "audio.f32",
                recordingPath: c.recordingEnabled ? "/tmp/record | quote's.\(format.fileExtension)" : nil,
                streamTarget: c.streamingEnabled ? "rtmp://localhost/live/test" : nil)
            let split = mode == .both && bitrate != .standard
            #expect(args.filter { $0 == "1:a" }.count == (split ? 2 : 1))
            #expect(args[args.firstIndex(of: "-b:a:0")! + 1] == (mode == .record ? "\(bitrate.rawValue)k" : "160k"))
            #expect(args.contains("-b:a:1") == split)
            let tee = args.last!
            #expect(tee.contains("select=") == split)
            if split { #expect(tee.contains("a:1") && tee.contains("a:0")) }
            if c.recordingEnabled { #expect(tee.contains("record \\| quote\\'s")) }
        }
    }

    /// Opt-in end-to-end mux check, using this build's minimal FFmpeg and an externally
    /// generated H.264 FLV fixture (the bundled executable deliberately has no lavfi).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STREAMAPP_FFMPEG_PATH"] != nil &&
                   ProcessInfo.processInfo.environment["STREAMAPP_AUDIO_FIXTURE_VIDEO"] != nil,
                   "Requires bundled FFmpeg and an H.264 FLV fixture"))
    func bundledFFmpegAcceptsDualBitrateTee() throws {
        let env = ProcessInfo.processInfo.environment
        let executable = try #require(env["STREAMAPP_FFMPEG_PATH"])
        let video = try #require(env["STREAMAPP_AUDIO_FIXTURE_VIDEO"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StreamApp-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pcm = directory.appendingPathComponent("audio.f32")
        let angularStep = 2.0 * Double.pi * 1000.0 / 48_000.0
        let samples: [Float] = (0..<96_000).map { index in
            Float(sin(Double(index / 2) * angularStep) * 0.1)
        }
        try samples.withUnsafeBytes { try Data($0).write(to: pcm) }
        for format in RecordingFormat.allCases {
            var c = configuration(); c.outputMode = .both; c.recordingAudioBitrateKbps = .highest; c.recordingFormat = format
            let recording = directory.appendingPathComponent("record | quote's.\(format.fileExtension)")
            let stream = directory.appendingPathComponent("stream-\(format.rawValue).flv")
            let args = MediaOutput.ffmpegArguments(configuration: c, videoPath: video, audioPath: pcm.path,
                recordingPath: recording.path, streamTarget: stream.path)
            print("BUNDLED FFMPEG ARGS: \(args)")
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            // File stderr avoids pipe backpressure while waiting for the finite fixture.
            let log = directory.appendingPathComponent("ffmpeg-\(format.rawValue).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log); process.standardError = handle
            try process.run(); process.waitUntilExit(); try handle.close()
            print(try String(contentsOf: log, encoding: .utf8))
            #expect(process.terminationStatus == 0)
            for output in [recording, stream] {
                let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
                #expect((attributes[.size] as? NSNumber)?.intValue ?? 0 > 1000)
            }
        }
    }

    private func configuration() -> StudioConfiguration {
        var c = StudioConfiguration(); c.microphoneEnabled = true; c.systemAudioEnabled = true
        c.microphoneCompressionEnabled = false
        return c
    }
    private func pull(_ mixer: AudioMixer, frames: Int) -> [Float] {
        var output = [Float](repeating: 0, count: frames * 2)
        output.withUnsafeMutableBufferPointer { mixer.pull(into: $0) }
        return output
    }
    private func sample(time: CMTime, values: [Float], frames: Int, rate: Double = 48_000, interleaved: Bool = true) throws -> CMSampleBuffer {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(values.count)))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: interleaved, channelLayout: layout)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        let buffers = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        for channel in values.indices {
            let pointer = buffers[interleaved ? 0 : channel].mData!.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames { pointer[interleaved ? frame * values.count + channel : frame] = values[channel] }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        #expect(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format.formatDescription, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result) == noErr)
        let sample = try #require(result)
        #expect(CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, bufferList: pcm.audioBufferList) == noErr)
        CMSampleBufferSetDataReady(sample)
        return sample
    }
}
