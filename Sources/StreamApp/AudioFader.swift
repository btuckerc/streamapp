import AppKit
import SwiftUI

/// Cubic audio taper: silence at the bottom, unity near 79%, and the existing 2× ceiling.
/// Configuration and the mixer continue to store linear amplitude, not fader position.
enum AudioFaderScale {
    static func position(for gain: Double) -> Double {
        pow(min(2, max(0, gain)) / 2, 1.0 / 3)
    }

    static func gain(at position: Double) -> Double {
        let position = min(1, max(0, position))
        return 2 * position * position * position
    }

    static func adjusted(_ gain: Double, by decibels: Double) -> Double {
        // A finite first step makes a 1 dB increase useful after dragging to silence.
        if gain <= 0 { return decibels > 0 ? 0.001 : 0 }
        let adjusted = gain * pow(10, decibels / 20)
        if decibels > 0 { return min(2, max(0.001, adjusted)) }
        return adjusted < 0.001 ? 0 : min(2, adjusted)
    }

    static func readout(_ gain: Double) -> String {
        guard gain > 0 else { return "−∞ dB" }
        let decibels = 20 * log10(gain)
        return abs(decibels) < 0.05 ? "0.0 dB" : String(format: "%+.1f dB", decibels)
    }
}

/// Loudness guidance in LUFS (ITU-R BS.1770). The band centres on −16 LUFS, the level AES TD1008
/// and Apple recommend for streamed programme audio (speech −18); platforms turn louder mixes
/// down, and quieter ones sound distant. Clipping is judged on sample peak, not loudness.
enum AudioLevelZone: Equatable {
    case silent, quiet, good, hot, clipping

    /// Meter scale in LUFS; a full-scale 1 kHz stereo tone reads 0.
    static let floor = -60.0
    static let target = -19.0 ... -13.0
    /// Sample peaks at or above this (dBFS) leave no headroom; true peak is not measured.
    static let clip = -1.0
    /// Short-term loudness below this is idle (room noise, pauses), not "too quiet".
    static let activity = -45.0

    init(loudness: Double) {
        switch loudness {
        case ..<Self.activity: self = .silent
        case ..<Self.target.lowerBound: self = .quiet
        case ...Self.target.upperBound: self = .good
        default: self = .hot
        }
    }

    var title: String {
        switch self {
        case .silent: return "No sound"
        case .quiet: return "Too quiet"
        case .good: return "Good"
        case .hot: return "Too loud"
        case .clipping: return "Clipping"
        }
    }

    var color: Color {
        switch self {
        case .silent: return .secondary
        case .quiet: return .orange
        case .good: return .green
        case .hot: return .yellow
        case .clipping: return .red
        }
    }

    static func decibels(_ level: Float) -> Double { level > 0 ? 20 * log10(Double(level)) : -.infinity }
    static func fraction(_ loudness: Double) -> CGFloat { CGFloat(min(1, max(0, (loudness - floor) / -floor))) }
    static func readout(_ loudness: Double) -> String {
        loudness > floor ? "\(Int(loudness.rounded())) LUFS".replacingOccurrences(of: "-", with: "−") : "−∞ LUFS"
    }
}

/// Turns 5 Hz level reads into a loudness-hold tick and a steady verdict. Updated only when a
/// new level arrives, so it adds no timers or redraws of its own.
struct AudioLevelTracker {
    private(set) var hold = -Double.infinity
    private var holdPeak = -Double.infinity
    private var holdAt = Date.distantPast
    private var bucket = -Double.infinity
    private var previousBucket = -Double.infinity
    private var bucketAt = Date.distantPast
    private var activeAt = Date.distantPast
    private var clippedAt = Date.distantPast
    private(set) var zone = AudioLevelZone.silent

    mutating func record(_ level: AudioLevel, at now: Date = .now) {
        // Hold the loudest momentary reading for 1.5 s, then fall at 24 dB/s.
        let decayed = holdPeak - max(0, now.timeIntervalSince(holdAt) - 1.5) * 24
        if level.momentary >= decayed { holdPeak = level.momentary; holdAt = now; hold = level.momentary } else { hold = decayed }
        // Verdict: loudest short-term (3 s) reading over a 2–4 s window, so the dip a pause
        // causes in the 3 s average doesn't flip it to "too quiet".
        let bucketAge = now.timeIntervalSince(bucketAt)
        if bucketAge > 2 {
            previousBucket = bucketAge > 4 ? -.infinity : bucket
            bucket = -.infinity
            bucketAt = now
        }
        if level.shortTerm >= AudioLevelZone.activity { bucket = max(bucket, level.shortTerm); activeAt = now }
        if AudioLevelZone.decibels(level.peak) >= AudioLevelZone.clip { clippedAt = now }
        if now.timeIntervalSince(clippedAt) < 2 { zone = .clipping }
        else if now.timeIntervalSince(activeAt) > 6 { zone = .silent }
        else { zone = AudioLevelZone(loudness: max(bucket, previousBucket)) }
    }
}

/// Loudness meter track: target band, colored momentary loudness, and hold tick.
struct AudioLevelTrack: View {
    let loudness: Double
    let hold: Double
    var height: CGFloat = 6

    private static let fill = LinearGradient(stops: [
        .init(color: .green.opacity(0.45), location: 0),
        .init(color: .green.opacity(0.45), location: AudioLevelZone.fraction(AudioLevelZone.target.lowerBound)),
        .init(color: .green, location: AudioLevelZone.fraction(AudioLevelZone.target.lowerBound)),
        .init(color: .green, location: AudioLevelZone.fraction(AudioLevelZone.target.upperBound)),
        .init(color: .yellow, location: AudioLevelZone.fraction(AudioLevelZone.target.upperBound)),
        .init(color: .yellow, location: 1)
    ], startPoint: .leading, endPoint: .trailing)

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let bandStart = AudioLevelZone.fraction(AudioLevelZone.target.lowerBound)
            let bandEnd = AudioLevelZone.fraction(AudioLevelZone.target.upperBound)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.1))
                Rectangle().fill(Color.green.opacity(0.22))
                    .frame(width: width * (bandEnd - bandStart))
                    .offset(x: width * bandStart)
                Self.fill.mask(alignment: .leading) {
                    Rectangle().frame(width: width * AudioLevelZone.fraction(loudness))
                }
                .animation(.linear(duration: 0.2), value: loudness)
                if hold > AudioLevelZone.floor {
                    Rectangle().fill(AudioLevelZone(loudness: hold).color)
                        .frame(width: 2)
                        .offset(x: max(0, width * AudioLevelZone.fraction(hold) - 2))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Gain fader drawn over its source's level meter, so dragging shows its effect immediately.
/// Drag is relative (no jump on click); Shift drags finely; double-click or Option-click resets
/// to 0 dB, and dragging snaps to 0 dB with a trackpad detent.
struct AudioLevelFader: View {
    let title: String
    @Binding var gain: Double
    let loudness: Double
    let hold: Double

    @Environment(\.isEnabled) private var isEnabled
    @State private var dragPosition: Double?
    @State private var lastTranslation: CGFloat = 0
    @State private var lastClick: (time: Date, location: CGPoint)?
    @State private var resetPress = false

    private static let thumb: CGFloat = 14
    private static let snapDecibels = 0.6

    var body: some View {
        GeometryReader { geometry in
            let inset = Self.thumb / 2
            let travel = max(1, geometry.size.width - Self.thumb)
            let centerY = geometry.size.height / 2
            ZStack(alignment: .topLeading) {
                AudioLevelTrack(loudness: loudness, hold: hold, height: 8)
                    .padding(.horizontal, inset)
                    .position(x: geometry.size.width / 2, y: centerY)
                // 0 dB detent mark, just above the thumb's reach.
                Rectangle().fill(Color.secondary)
                    .frame(width: 1, height: 3)
                    .position(x: inset + travel * AudioFaderScale.position(for: 1), y: centerY - Self.thumb / 2 - 2)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .position(x: inset + travel * AudioFaderScale.position(for: gain), y: centerY)
            }
            .contentShape(Rectangle())
            .gesture(press(travel: travel))
        }
        .frame(height: 20)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { AudioFaderScale.position(for: gain) },
                                  set: { gain = AudioFaderScale.gain(at: $0) }), in: 0...1)
                .accessibilityLabel("\(title) gain")
                .accessibilityValue(AudioFaderScale.readout(gain))
                .accessibilityAdjustableAction { direction in
                    gain = AudioFaderScale.adjusted(gain, by: direction == .increment ? 1 : -1)
                }
                .accessibilityAction(named: "Reset to 0 dB") { reset() }
        }
        .help("Drag to set \(title.lowercased()) gain (Shift for fine). Double-click for 0 dB. Aim for the green band.")
    }

    /// One press gesture handles drag, double-click, and Option-click. Double-clicks are detected
    /// here rather than with `TapGesture(count: 2)` so they can't lose arbitration to the drag;
    /// only a stationary click followed by a second press at the same spot counts.
    private func press(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragPosition == nil {
                    let now = Date.now
                    let repeated = lastClick.map {
                        now.timeIntervalSince($0.time) < NSEvent.doubleClickInterval
                            && abs($0.location.x - value.startLocation.x) < 4
                    } ?? false
                    lastClick = nil
                    dragPosition = AudioFaderScale.position(for: gain)
                    lastTranslation = 0
                    resetPress = repeated || NSEvent.modifierFlags.contains(.option)
                    if resetPress { reset() }
                }
                guard !resetPress, let start = dragPosition else { return }
                let scale = NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1
                let next = min(1, max(0, start + Double((value.translation.width - lastTranslation) / travel) * scale))
                dragPosition = next
                lastTranslation = value.translation.width
                if next != start { setGain(AudioFaderScale.gain(at: next)) }
            }
            .onEnded { value in
                let stationary = abs(value.translation.width) < 3 && abs(value.translation.height) < 3
                lastClick = stationary && !resetPress ? (Date.now, value.startLocation) : nil
                dragPosition = nil
                resetPress = false
            }
    }

    private func setGain(_ proposed: Double) {
        let snapped = proposed > 0 && abs(20 * log10(proposed)) < Self.snapDecibels
        if snapped && gain != 1 {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        gain = snapped ? 1 : proposed
    }

    private func reset() {
        guard isEnabled else { return }
        gain = 1
    }
}

/// Short verdict shown beside a source name.
struct AudioLevelVerdict: View {
    let zone: AudioLevelZone

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(zone.color).frame(width: 6, height: 6)
            Text(zone.title)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(zone == .silent ? Color.secondary : zone.color)
        .help("Loudness target: about −16 LUFS (green band, −19 to −13). Clipping: peaks reach −1 dBFS.")
        .accessibilityElement(children: .combine)
    }
}
