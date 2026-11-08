import AppKit
import Combine

/// A private, non-video control surface. Retain one panel for the entire application
/// lifetime so ScreenCaptureKit never sees a recycled or unregistered window ID.
@MainActor
final class CameraArrangeOverlay {
    private let panel = CameraArrangePanel(contentRect: CGRect(x: 0, y: 0, width: 1, height: 1),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let handle = CameraArrangeHandle()
    private weak var model: StudioModel?
    private var configuration: StudioConfiguration
    private var subscriptions = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var mapping: CameraDisplayMapping?
    private var dragStart: (point: CGPoint, rect: CGRect)?
    private var anchor: CameraAnchor?
    private var shown = false
    var windowID: CGWindowID { CGWindowID(max(0, panel.windowNumber)) }

    init(model: StudioModel) {
        self.model = model; configuration = model.configuration
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.contentView = handle
        handle.onDown = { [weak self] point in self?.begin(at: point) }
        handle.onDrag = { [weak self] point, free in self?.drag(to: point, free: free) }
        handle.onUp = { [weak self] in self?.finish() }
        handle.onDone = { [weak self] in self?.hide() }
        model.$configuration.sink { [weak self] c in
            self?.configuration = c
            self?.place()
        }.store(in: &subscriptions)
        Publishers.CombineLatest(model.engine.$cameraDragAnchor, model.engine.$cameraDodgeAnchor).sink { [weak self] drag, dodge in
            guard let self, self.dragStart == nil else { return }
            self.anchor = drag ?? dodge; self.place()
        }.store(in: &subscriptions)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }
    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
    func toggle() {
        if shown { hide(); return }
        guard model?.canArrangeCamera == true else { return }
        shown = true
        model?.engine.setCameraArrangementActive(true)
        place()
        guard shown else { return }
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(handle)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if [UInt16(53), 36, 76].contains(event.keyCode) { self?.hide(); return nil }
            return event
        }
    }
    private func hide() {
        finish(); shown = false; panel.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model?.engine.setCameraArrangementActive(false)
    }
    private func place() {
        guard shown else { return }
        guard let model, configuration.cameraEnabled, configuration.layout == .desktopChat,
              configuration.windowID == nil, let mapping = model.engine.cameraDisplayMapping(configuration: configuration) else {
            hide(); return
        }
        self.mapping = mapping
        let g = SceneGeometry(configuration: configuration)
        let camera = CameraPlacement.rect(anchor: anchor ?? configuration.cameraAnchor, size: g.camera.size, desktop: g.desktop)
        handle.cameraFrame = configuration.cameraFrame
        panel.setFrame(mapping.toDisplay(camera), display: true)
        handle.needsDisplay = true
    }
    private func begin(at point: CGPoint) {
        guard let mapping else { return }
        let g = SceneGeometry(configuration: configuration)
        dragStart = (mapping.toCanvas(point), CameraPlacement.rect(anchor: anchor ?? configuration.cameraAnchor, size: g.camera.size, desktop: g.desktop))
        NSCursor.closedHand.set()
    }
    private func drag(to point: CGPoint, free: Bool) {
        guard let mapping, let start = dragStart else { return }
        let p = mapping.toCanvas(point)
        let origin = CGPoint(x: start.rect.minX + p.x - start.point.x, y: start.rect.minY + p.y - start.point.y)
        anchor = CameraPlacement.anchor(origin: origin, size: start.rect.size,
                                        desktop: SceneGeometry(configuration: configuration).desktop, snapping: !free)
        model?.engine.setCameraDrag(anchor); place()
    }
    private func finish() {
        guard dragStart != nil else { return }
        dragStart = nil
        if let anchor { model?.commitCameraDrag(anchor) }
        anchor = nil; NSCursor.openHand.set()
    }
}

private final class CameraArrangePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class CameraArrangeHandle: NSView {
    var cameraFrame: CameraFrame = .widescreen
    var onDown: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint, Bool) -> Void)?
    var onUp: (() -> Void)?
    var onDone: (() -> Void)?
    private let done = NSButton(title: "Done", target: nil, action: nil)
    override var acceptsFirstResponder: Bool { true }
    override init(frame: CGRect) {
        super.init(frame: frame)
        done.target = self; done.action = #selector(finish)
        done.bezelStyle = .inline; done.contentTintColor = .controlAccentColor
        addSubview(done)
        setAccessibilityLabel("Arrange webcam")
        setAccessibilityHelp("Drag to move. Hold Option for free placement. Escape or Return finishes.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        done.frame = CGRect(x: bounds.midX - 24, y: max(8, bounds.midY - 27), width: 48, height: 22)
    }
    @objc private func finish() { onDone?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { onDown?(NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { onDrag?(NSEvent.mouseLocation, event.modifierFlags.contains(.option)) }
    override func mouseUp(with event: NSEvent) { onUp?() }
    override func keyDown(with event: NSEvent) {
        if [UInt16(53), 36, 76].contains(event.keyCode) { onDone?() } else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: CGRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let path = cameraFrame == .circle ? NSBezierPath(ovalIn: rect) : NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        NSColor.controlAccentColor.withAlphaComponent(0.13).setFill(); path.fill()
        NSColor.controlAccentColor.setStroke(); path.lineWidth = 2; path.setLineDash([6, 4], count: 2, phase: 0); path.stroke()
        let text = "Drag · ⌥ free · esc done"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY + 3), withAttributes: attributes)
    }
}
