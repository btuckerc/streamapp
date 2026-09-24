import Foundation
import Testing
@testable import StreamApp

struct AudioFaderTests {
    @Test func taperPreservesSavedGainsAndOrdering() {
        var previous = -Double.infinity
        for gain in stride(from: 0.0, through: 2.0, by: 0.002) {
            let position = AudioFaderScale.position(for: gain)
            #expect(position > previous)
            #expect(abs(AudioFaderScale.gain(at: position) - gain) < 1e-12)
            previous = position
        }
        #expect(AudioFaderScale.gain(at: 0) == 0)
        #expect(AudioFaderScale.gain(at: 1) == 2)
        #expect(AudioFaderScale.position(for: 1) > 0.75)
        #expect(AudioFaderScale.position(for: 1) < 0.85)
    }

    @Test func fineAdjustmentsAreDecibelsAndReversible() {
        let lower = AudioFaderScale.adjusted(1, by: -1)
        #expect(abs(20 * log10(lower) + 1) < 1e-12)
        #expect(abs(AudioFaderScale.adjusted(lower, by: 1) - 1) < 1e-12)
        #expect(AudioFaderScale.adjusted(2, by: 1) == 2)
    }

    @Test func fineAdjustmentCanLeaveSilenceAndNeverLowersOnIncrease() {
        #expect(AudioFaderScale.adjusted(0, by: -1) == 0)
        let firstAudible = AudioFaderScale.adjusted(0, by: 1)
        #expect(firstAudible == 0.001)
        #expect(AudioFaderScale.adjusted(firstAudible, by: -1) == 0)
        let nearlySilent = AudioFaderScale.gain(at: 0.01)
        #expect(AudioFaderScale.adjusted(nearlySilent, by: 1) > nearlySilent)
    }

    private static func level(shortTerm: Double, momentary: Double? = nil, peak: Double = -20) -> AudioLevel {
        AudioLevel(peak: Float(pow(10, peak / 20)), momentary: momentary ?? shortTerm, shortTerm: shortTerm)
    }

    @Test func verdictRidesThroughSpeechPausesButReportsLongSilence() {
        var tracker = AudioLevelTracker()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        tracker.record(Self.level(shortTerm: -16), at: start)
        #expect(tracker.zone == .good)
        // A pause drags the 3 s average down; the verdict keeps the last judgement meanwhile.
        for tick in 1...15 { tracker.record(Self.level(shortTerm: -24 - Double(tick) * 2), at: start + Double(tick) * 0.2) }
        #expect(tracker.zone == .good)
        tracker.record(Self.level(shortTerm: -70), at: start + 8.5)
        #expect(tracker.zone == .silent)
    }

    @Test func verdictJudgesRecentLoudnessAndLatchesClippingPeaks() {
        var tracker = AudioLevelTracker()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        tracker.record(Self.level(shortTerm: -30), at: start)
        #expect(tracker.zone == .quiet)
        tracker.record(Self.level(shortTerm: -16, peak: -0.5), at: start + 0.2)
        tracker.record(Self.level(shortTerm: -16), at: start + 0.4)
        #expect(tracker.zone == .clipping)
        // After the latch and the window pass, steady −10 LUFS is too loud even with safe peaks.
        for tick in 3...30 { tracker.record(Self.level(shortTerm: -10, peak: -3), at: start + Double(tick) * 0.2) }
        #expect(tracker.zone == .hot)
        #expect(abs(tracker.hold + 10) < 0.01)
    }
}
