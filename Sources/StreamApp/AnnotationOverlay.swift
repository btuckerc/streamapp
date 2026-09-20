import AppKit
import Combine
import Carbon.HIToolbox

/// Two windows: public ink, private controls. Capture excludes this app and
/// explicitly includes only canvasWindowID. No renderer or timer runs while idle.
@MainActor
final class AnnotationOverlay: NSObject, ObservableObject {
    enum Tool { case pen, highlighter, eraser }
    @Published private(set) var canvasWindowID: CGWindowID = 0
    @Published private(set) var isDrawing = false
    @Published private(set) var registrationFailed = false
    var onToggleRequested: ((CGDirectDisplayID) -> Bool)?
    var targetDisplay: (() -> CGDirectDisplayID?)?
    var onCanvasShown: (() -> Void)?
    private let canvas = AnnotationWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
    private let ink = AnnotationInk()
    private let toolbar = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 52), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let status = NSTextField(labelWithString: "Ink is recorded · Esc to finish")
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var screenObserver: NSObjectProtocol?
    private var displayID: CGDirectDisplayID?
    private weak var previousApplication: NSRunningApplication?

    override init() {
        super.init()
        canvas.isOpaque = false; canvas.backgroundColor = .clear; canvas.hasShadow = false
        canvas.level = .floating; canvas.ignoresMouseEvents = true; canvas.isReleasedWhenClosed = false
        canvas.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        canvas.contentView = ink
        ink.onEscape = { [weak self] in self?.stopDrawing() }
        ink.onLimit = { [weak self] in self?.status.stringValue = "Ink limit reached · Clear to continue" }
        canvasWindowID = CGWindowID(max(0, canvas.windowNumber))
        toolbar.isOpaque = false; toolbar.backgroundColor = .clear; toolbar.hasShadow = true
        toolbar.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        toolbar.hidesOnDeactivate = false; toolbar.isReleasedWhenClosed = false
        toolbar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let box = NSVisualEffectView(); box.material = .hudWindow; box.state = .active
        box.wantsLayer = true; box.layer?.cornerRadius = 10
        let stack = NSStackView(); stack.orientation = .horizontal; stack.spacing = 6
        status.font = .systemFont(ofSize: 11); stack.addArrangedSubview(status)
        for (index, title) in ["Pen", "Highlight", "Erase", "Undo", "Clear", "Done"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(action(_:)))
            button.tag = index; stack.addArrangedSubview(button)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10), stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10), stack.centerYAnchor.constraint(equalTo: box.centerYAnchor)])
        toolbar.contentView = box
        registerShortcut()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let id = self.displayID else { return }
                let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
                guard screen?.frame != self.canvas.frame else { return }
                self.stopDrawing(); self.clear(); self.canvas.orderOut(nil); self.displayID = nil
            }
        }
    }
    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
    func toggle(on id: CGDirectDisplayID) {
        if isDrawing { stopDrawing(); return }
        guard onToggleRequested?(id) ?? true,
              let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) else { return }
        if displayID != id || canvas.frame != screen.frame { clear() }
        displayID = id
        previousApplication = NSWorkspace.shared.frontmostApplication
        canvas.setFrame(screen.frame, display: true)
        canvas.ignoresMouseEvents = false
        NSApplication.shared.activate(ignoringOtherApps: true)
        canvas.makeKeyAndOrderFront(nil); canvas.makeFirstResponder(ink)
        canvas.invalidateCursorRects(for: ink)
        canvasWindowID = CGWindowID(canvas.windowNumber)
        toolbar.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - toolbar.frame.width / 2, y: screen.visibleFrame.maxY - toolbar.frame.height - 12))
        toolbar.orderFrontRegardless(); isDrawing = true
        onCanvasShown?()
    }
    func stopDrawing() {
        guard isDrawing else { return }
        ink.finishStroke(); isDrawing = false
        canvas.ignoresMouseEvents = true; toolbar.orderOut(nil); canvas.resignKey()
        NSCursor.arrow.set()
        if previousApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApplication?.activate() }
    }
    func clear() { ink.clear(); status.stringValue = "Ink is recorded · Esc to finish" }
    func undo() { ink.undo() }
    @objc private func action(_ button: NSButton) {
        switch button.tag {
        case 0: ink.tool = .pen
        case 1: ink.tool = .highlighter
        case 2: ink.tool = .eraser
        case 3: undo()
        case 4: clear()
        default: stopDrawing()
        }
    }
    private func registerShortcut() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, pointer in
            guard let pointer else { return noErr }
            MainActor.assumeIsolated {
                let owner = Unmanaged<AnnotationOverlay>.fromOpaque(pointer).takeUnretainedValue()
                owner.toggle(on: owner.targetDisplay?() ?? CGMainDisplayID())
            }
            return noErr
        }
        let installed = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { registrationFailed = true; return }
        let id = EventHotKeyID(signature: 0x5354524D, id: 1)
        registrationFailed = RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKey) != noErr
    }
}

private final class AnnotationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class AnnotationInk: NSView {
    private final class Stroke {
        let path = CGMutablePath()
        let tool: AnnotationOverlay.Tool
        var bounds = CGRect.null
        var points = 0
        init(_ tool: AnnotationOverlay.Tool) { self.tool = tool }
    }
    var tool: AnnotationOverlay.Tool = .pen
    var onEscape: (() -> Void)?
    var onLimit: (() -> Void)?
    private var strokes: [Stroke] = []
    private var active: Stroke?
    private var previous: CGPoint?
    private var previousRadius: CGFloat = 1
    private var pointCount = 0
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) } }
    override func mouseDown(with event: NSEvent) {
        finishStroke()
        guard strokes.count < 512, pointCount < 100_000 else { onLimit?(); return }
        active = Stroke(tool); previous = nil; append(event)
    }
    override func mouseDragged(with event: NSEvent) { append(event) }
    override func mouseUp(with event: NSEvent) { append(event); finishStroke() }
    func finishStroke() {
        if let active { strokes.append(active) }
        active = nil; previous = nil
    }
    private func append(_ event: NSEvent) {
        guard let active else { return }
        guard pointCount < 100_000 else { onLimit?(); return }
        let point = convert(event.locationInWindow, from: nil)
        let pressure = event.subtype == .tabletPoint ? max(0.05, CGFloat(event.pressure)) : 1
        let radius: CGFloat = (active.tool == .pen ? 2 : 10) * (0.25 + pressure * 0.75)
        var dirty = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        if let last = previous {
            let dx = point.x - last.x, dy = point.y - last.y
            let length = hypot(dx, dy)
            if length < 0.5 { return }
            let nx = -dy / length, ny = dx / length
            active.path.move(to: CGPoint(x: last.x + nx * previousRadius, y: last.y + ny * previousRadius))
            active.path.addLine(to: CGPoint(x: last.x - nx * previousRadius, y: last.y - ny * previousRadius))
            active.path.addLine(to: CGPoint(x: point.x - nx * radius, y: point.y - ny * radius))
            active.path.addLine(to: CGPoint(x: point.x + nx * radius, y: point.y + ny * radius))
            active.path.closeSubpath()
            dirty = dirty.union(CGRect(x: last.x - previousRadius, y: last.y - previousRadius, width: previousRadius * 2, height: previousRadius * 2))
        }
        active.path.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        active.bounds = active.bounds.union(dirty)
        active.points += 1; pointCount += 1; previous = point; previousRadius = radius
        setNeedsDisplay(dirty.insetBy(dx: -2, dy: -2))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        for stroke in strokes where stroke.bounds.intersects(dirtyRect) { draw(stroke, in: context) }
        if let active, active.bounds.intersects(dirtyRect) { draw(active, in: context) }
    }
    private func draw(_ stroke: Stroke, in context: CGContext) {
        context.saveGState()
        context.setBlendMode(stroke.tool == .eraser ? .clear : .normal)
        context.setFillColor((stroke.tool == .highlighter ? NSColor.systemYellow.withAlphaComponent(0.3) : NSColor.systemRed).cgColor)
        context.addPath(stroke.path); context.fillPath()
        context.restoreGState()
    }
    func clear() { strokes.removeAll(keepingCapacity: true); active = nil; previous = nil; pointCount = 0; needsDisplay = true }
    func undo() {
        finishStroke()
        guard let stroke = strokes.popLast() else { return }
        pointCount -= stroke.points; setNeedsDisplay(stroke.bounds.insetBy(dx: -2, dy: -2))
    }
}
