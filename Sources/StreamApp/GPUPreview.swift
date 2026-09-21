import SwiftUI
import MetalKit
import CoreImage

/// A single retained IOSurface, never a queue of raw frames or CPU images.
final class PreviewFrames: @unchecked Sendable {
    enum Mode: Hashable { case program, camera }
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var serial: UInt64 = 0
    private var requested: Mode?
    private var mirrored = false
    private var surfaces: [ObjectIdentifier: Mode] = [:]
    func requestSurface(_ owner: ObjectIdentifier, mode: Mode?) {
        lock.lock(); defer { lock.unlock() }
        surfaces[owner] = mode
        let next = mode ?? surfaces.values.first
        guard requested != next else { return }
        requested = next; buffer = nil; serial &+= 1
    }
    var mode: Mode? { lock.lock(); defer { lock.unlock() }; return requested }
    func request(_ mode: Mode?) {
        lock.lock(); defer { lock.unlock() }
        requested = mode; buffer = nil; serial &+= 1
    }
    func publish(_ value: CVPixelBuffer?, mirrored: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard requested != nil else { return }
        if buffer === value, self.mirrored == mirrored { return }
        buffer = value; self.mirrored = mirrored; serial &+= 1
    }
    func latest() -> (CVPixelBuffer?, UInt64, Bool) {
        lock.lock(); defer { lock.unlock() }; return (buffer, serial, mirrored)
    }
    // Explicit diagnostic export only; never called by the presentation loop.
    func snapshot() -> CGImage? {
        guard let buffer = latest().0 else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return CIContext().createCGImage(image, from: image.extent)
    }
}

struct GPUPreview: NSViewRepresentable {
    let frames: PreviewFrames
    var mode: PreviewFrames.Mode = .program
    func makeNSView(context: Context) -> PreviewSurface { PreviewSurface(frames: frames, mode: mode) }
    func updateNSView(_ view: PreviewSurface, context: Context) { view.setMode(mode); view.refreshVisibility() }
    static func dismantleNSView(_ view: PreviewSurface, coordinator: ()) { view.stop() }
}

final class PreviewSurface: MTKView, MTKViewDelegate {
    private let frames: PreviewFrames
    private var mode: PreviewFrames.Mode
    private let imageContext: CIContext
    private let commands: MTLCommandQueue
    private let slots = DispatchSemaphore(value: 1)
    private var lastSerial: UInt64?
    private var observers: [NSObjectProtocol] = []
    private var active = false
    private let color = CGColorSpace(name: CGColorSpace.sRGB)!

    init(frames: PreviewFrames, mode: PreviewFrames.Mode) {
        let device = MTLCreateSystemDefaultDevice()!
        self.frames = frames; self.mode = mode
        commands = device.makeCommandQueue()!
        imageContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        super.init(frame: .zero, device: device)
        framebufferOnly = false; colorPixelFormat = .bgra8Unorm
        presentsWithTransaction = true
        preferredFramesPerSecond = 30; isPaused = true
        enableSetNeedsDisplay = false; delegate = self
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSView.boundsDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshVisibility() })
        }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
        refreshVisibility()
    }
    override func viewDidHide() { super.viewDidHide(); refreshVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshVisibility() }
    func setMode(_ mode: PreviewFrames.Mode) {
        guard self.mode != mode else { return }
        self.mode = mode
        lastSerial = nil
        if active { frames.requestSurface(ObjectIdentifier(self), mode: mode) }
    }
    
    func refreshVisibility() {
        let visible = window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
        guard visible != active else { return }
        active = visible; isPaused = !visible; lastSerial = nil
        frames.requestSurface(ObjectIdentifier(self), mode: visible ? mode : nil)
    }
    func stop() {
        isPaused = true; delegate = nil
        frames.requestSurface(ObjectIdentifier(self), mode: nil); active = false
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { lastSerial = nil }
    func draw(in view: MTKView) {
        guard active, slots.wait(timeout: .now()) == .success else { return }
        let (buffer, serial, mirror) = frames.latest()
        guard serial != lastSerial, let drawable = currentDrawable, let command = commands.makeCommandBuffer() else { slots.signal(); return }
        let bounds = CGRect(origin: .zero, size: drawableSize)
        var image = CIImage(color: .black).cropped(to: bounds)
        if let buffer {
            var source = CIImage(cvPixelBuffer: buffer)
            if mirror { source = source.transformed(by: CGAffineTransform(translationX: source.extent.width, y: 0).scaledBy(x: -1, y: 1)) }
            let scale = min(bounds.width / source.extent.width, bounds.height / source.extent.height)
            source = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            source = source.transformed(by: CGAffineTransform(translationX: (bounds.width - source.extent.width) / 2, y: (bounds.height - source.extent.height) / 2))
            image = source.composited(over: image)
        }
        imageContext.render(image, to: drawable.texture, commandBuffer: command, bounds: bounds, colorSpace: color)
        let slots = self.slots
        command.addCompletedHandler { [buffer] _ in withExtendedLifetime(buffer) { _ = slots.signal() } }
        lastSerial = serial
        command.commit()
        command.waitUntilScheduled()
        drawable.present()
    }
}
