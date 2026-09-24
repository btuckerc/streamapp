// Latency stimulus for bench/run.py. An opaque mid-grey backdrop covers the whole main display
// (above the menu bar and Dock) so every trial captures the same content regardless of what the
// Mac was showing. A centred square flips between two greys at seeded, jittered intervals, and a
// short 2 kHz tone burst is scheduled for the same host time as each dark→light flip. Every flip
// is logged with the display-link target time (CLOCK_UPTIME_RAW ns, the same clock as bench/probe
// and the harness), so recordings and a loopback receiver can be aligned to "glass" time.
// --motion scrolls a blocky noise pattern across the backdrop so every captured frame changes
// (the "active content" profile).
//
//   stimulus --events PATH [--seconds N] [--size PT] [--seed N] [--min-interval S] [--max-interval S] [--no-audio] [--motion]
//
// Output (JSON lines): a header {"start_ns","screen":{"w","h","scale"},"rect":[x,y,w,h],...} with the
// square in top-left-origin points, then {"i","level","t_ns","now_ns","tone"} per flip.
// Exits 0 after --seconds (0 = until SIGTERM/SIGINT or the parent process exits).
import AppKit
import AVFoundation
import QuartzCore

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / 9_007_199_254_740_992 }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("stimulus: \(message)\n".utf8)); exit(2)
}

var eventsPath: String?
var seconds = 0.0, size = 320.0, minInterval = 0.9, maxInterval = 1.7
var seed: UInt64 = 1
var tone = true, motion = false
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let flag = arguments.next() {
    if flag == "--no-audio" { tone = false; continue }
    if flag == "--motion" { motion = true; continue }
    guard let text = arguments.next() else { fail("missing value for \(flag)") }
    switch flag {
    case "--events": eventsPath = text
    case "--seconds": seconds = Double(text) ?? -1
    case "--size": size = Double(text) ?? -1
    case "--seed": seed = UInt64(text) ?? 0
    case "--min-interval": minInterval = Double(text) ?? -1
    case "--max-interval": maxInterval = Double(text) ?? -1
    default: fail("unknown argument \(flag)")
    }
}
guard let eventsPath else { fail("--events PATH is required") }
guard seconds >= 0, size >= 32, minInterval >= 0.2, maxInterval >= minInterval else { fail("invalid argument values") }

/// Schedules a Hann-windowed 2 kHz burst so its first sample plays at a CLOCK_UPTIME_RAW instant.
final class TonePlayer {
    static let duration = 0.010
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let burst: AVAudioPCMBuffer
    private let timebase: mach_timebase_info_data_t

    init() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let count = AVAudioFrameCount(48_000 * Self.duration)
        burst = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        burst.frameLength = count
        let samples = burst.floatChannelData![0]
        for i in 0..<Int(count) {
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(count - 1))
            samples[i] = Float(0.5 * hann * sin(2 * Double.pi * 2000 * Double(i) / 48_000))
        }
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info); timebase = info
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        player.play()
    }
    func play(atUptimeNs ns: UInt64) {
        let ticks = ns * UInt64(timebase.denom) / UInt64(timebase.numer)
        player.scheduleBuffer(burst, at: AVAudioTime(hostTime: ticks))
    }
    func stop() { player.stop(); engine.stop() }
}

let log: FileHandle = {
    guard FileManager.default.createFile(atPath: eventsPath, contents: nil), let handle = FileHandle(forWritingAtPath: eventsPath) else {
        fail("cannot write \(eventsPath)")
    }
    return handle
}()
func write(_ record: [String: Any]) {
    log.write(try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
    log.write(Data([0x0A]))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let mainID = CGMainDisplayID()
guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == mainID }) else {
    fail("main display not found")
}
let coverLevel = NSWindow.Level.screenSaver
func coverPanel(_ rect: NSRect, level: NSWindow.Level) -> NSPanel {
    let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = level
    panel.ignoresMouseEvents = true
    panel.hasShadow = false
    panel.isOpaque = true
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    return panel
}

/// A horizontally periodic pattern of 8-pt grey blocks, twice as wide as one period past the
/// screen edge, scrolled by exactly one period per loop so the animation is seamless.
func noiseLayer(size: NSSize, seed: UInt64) -> CALayer {
    let block = 8, period = 256, columns = (Int(size.width) + period) / block + 1, rows = Int(size.height) / block + 1
    var random = SplitMix64(state: seed ^ 0x9E37_79B9_7F4A_7C15)
    let periodColumns = period / block
    var column = [[UInt8]](repeating: [], count: periodColumns)
    for i in 0..<periodColumns { column[i] = (0..<rows).map { _ in UInt8(40 + random.uniform() * 175) } }
    var pixels = [UInt8](repeating: 0, count: columns * rows)
    for y in 0..<rows { for x in 0..<columns { pixels[y * columns + x] = column[x % periodColumns][y] } }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: columns,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                        decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let layer = CALayer()
    layer.contents = image
    layer.magnificationFilter = .nearest
    layer.anchorPoint = .zero
    layer.frame = CGRect(x: 0, y: 0, width: CGFloat(columns * block), height: CGFloat(rows * block))
    let scroll = CABasicAnimation(keyPath: "position.x")
    scroll.fromValue = 0
    scroll.toValue = -period
    scroll.duration = 2  // 128 pt/s: every display frame differs
    scroll.repeatCount = .infinity
    scroll.timingFunction = CAMediaTimingFunction(name: .linear)
    layer.add(scroll, forKey: "scroll")
    return layer
}

let backdrop = coverPanel(screen.frame, level: coverLevel)
let backdropView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
backdropView.wantsLayer = true
backdropView.layer!.backgroundColor = CGColor(gray: 0.5, alpha: 1)
if motion { backdropView.layer!.addSublayer(noiseLayer(size: screen.frame.size, seed: seed)) }
backdrop.contentView = backdropView
backdrop.setFrame(screen.frame, display: true)
backdrop.orderFrontRegardless()

let frame = NSRect(x: screen.frame.midX - size / 2, y: screen.frame.midY - size / 2, width: size, height: size)
let panel = coverPanel(frame, level: NSWindow.Level(rawValue: coverLevel.rawValue + 1))
let dark = CGColor(gray: 0.15, alpha: 1), light = CGColor(gray: 0.85, alpha: 1)

final class FlipView: NSView {
    var onFrame: ((CFTimeInterval) -> Void)?
    private var link: CADisplayLink?
    func start() {
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    @objc private func tick(_ link: CADisplayLink) { onFrame?(link.targetTimestamp) }
}
let view = FlipView(frame: NSRect(origin: .zero, size: frame.size))
view.wantsLayer = true
view.layer!.backgroundColor = dark
panel.contentView = view
panel.setFrame(frame, display: true)
panel.orderFrontRegardless()

let player: TonePlayer?
do { player = tone ? try TonePlayer() : nil } catch { fail("audio engine: \(error.localizedDescription)") }

write([
    "start_ns": clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
    "screen": ["w": Int(screen.frame.width), "h": Int(screen.frame.height), "scale": Double(screen.backingScaleFactor)],
    "rect": [Int(frame.minX - screen.frame.minX), Int(screen.frame.maxY - frame.maxY), Int(size), Int(size)],
    "levels": ["dark": 0.15, "light": 0.85], "backdrop": 0.5, "motion": motion, "seed": seed, "tone_hz": 2000, "tone_seconds": TonePlayer.duration,
])

var random = SplitMix64(state: seed)
var nextFlip = CACurrentMediaTime() + 1
var isLight = false
var index = 0
view.onFrame = { target in
    // CACurrentMediaTime and the display-link target share mach absolute time (= CLOCK_UPTIME_RAW).
    guard target >= nextFlip else { return }
    isLight.toggle()
    CATransaction.begin(); CATransaction.setDisableActions(true)
    view.layer!.backgroundColor = isLight ? light : dark
    CATransaction.commit()
    let targetNs = UInt64(target * 1e9)
    let withTone = isLight && player != nil
    if withTone { player!.play(atUptimeNs: targetNs) }
    write(["i": index, "level": isLight ? "light" : "dark", "t_ns": targetNs,
           "now_ns": clock_gettime_nsec_np(CLOCK_UPTIME_RAW), "tone": withTone])
    index += 1
    nextFlip = target + minInterval + (maxInterval - minInterval) * random.uniform()
}

func finish() -> Never {
    player?.stop()
    try? log.close()
    exit(0)
}
var signalSources: [DispatchSourceSignal] = []
for number in [SIGTERM, SIGINT] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { finish() }
    source.resume()
    signalSources.append(source)
}
if seconds > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish() } }
// The cover blocks the whole display, so never outlive the harness (e.g. if it is SIGKILLed).
let parent = getppid()
let parentWatch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
parentWatch.setEventHandler { finish() }
if parent > 1 { parentWatch.resume() }
if parent > 1 && getppid() != parent { finish() }
view.start()
app.run()
