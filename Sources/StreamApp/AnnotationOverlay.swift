import AppKit
import Combine
enum AnnotationColorTarget: Int { case stroke, fill, highlighter }


/// Public ink and private controls remain separate windows. No idle rendering timer.
@MainActor
final class AnnotationOverlay: NSObject, ObservableObject {
    enum Tool { case pen, highlighter, eraser, arrow, ellipse, rectangle }
    @Published private(set) var canvasWindowID: CGWindowID = 0
    @Published private(set) var isDrawing = false
    var onToggleRequested: ((CGDirectDisplayID) -> Bool)?
    var onCanvasShown: (() -> Void)?
    private let canvas = AnnotationWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
    private let ink: AnnotationInk
    private let toolbar = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 411, height: 52), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var screenObserver: NSObjectProtocol?
    private var displayID: CGDirectDisplayID?
    private weak var previousApplication: NSRunningApplication?
    private var toolButtons: [NSButton] = []
    private let straightButton = NSButton(title: "Straight", target: nil, action: nil)
    private var clearButton: NSButton?

    init(settings: AnnotationSettings) {
        ink = AnnotationInk(settings: settings)
        super.init()
        canvas.isOpaque = false; canvas.backgroundColor = .clear; canvas.hasShadow = false
        canvas.level = .floating; canvas.ignoresMouseEvents = true; canvas.isReleasedWhenClosed = false
        canvas.acceptsMouseMovedEvents = true
        canvas.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        canvas.contentView = ink
        ink.onEscape = { [weak self] in self?.stopDrawing() }
        ink.onUpperPen = { [weak self] point in self?.beginToolGesture(at: point) }
        ink.onToolsReleased = { [weak self] in self?.finishToolGesture() }
        ink.onLocalShortcut = { [weak self] key, point in self?.handleLocalShortcut(key, at: point) ?? false }
        ink.onLimit = { [weak self] in
            self?.clearButton?.contentTintColor = .systemOrange
            self?.clearButton?.toolTip = "Ink limit reached. Clear all annotations to continue."
        }
        canvasWindowID = CGWindowID(max(0, canvas.windowNumber))
        toolbar.isOpaque = false; toolbar.backgroundColor = .clear; toolbar.hasShadow = true
        toolbar.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        toolbar.hidesOnDeactivate = false; toolbar.isReleasedWhenClosed = false
        toolbar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let box = NSVisualEffectView(); box.material = .hudWindow; box.state = .active
        box.wantsLayer = true; box.layer?.cornerRadius = 10
        let tools = NSStackView(); tools.orientation = .horizontal; tools.spacing = 5
        let items = [
            ("Pen", "pencil.tip", "Pen — draw freehand strokes."),
            ("Highlight", "highlighter", "Highlight — mark with broad, translucent ink."),
            ("Erase", "eraser", "Erase — remove whole objects by default. Choose Partial in Drawing settings to rub out smaller areas."),
            ("Arrow", "arrow.up.right", "Arrow — draw a freehand stroke with an arrowhead."),
            ("Ellipse", "circle", "Ellipse — drag an oval. Hold Shift for a circle."),
            ("Rectangle", "rectangle", "Rectangle — drag a rectangle. Hold Shift for a square."),
            ("Undo", "arrow.uturn.backward", "Undo the last stroke, shape, or erasure."),
            ("Clear", "trash", "Clear all annotations."),
            ("Done", "checkmark", "Done — leave drawing mode and keep the ink. Escape also finishes.")
        ]
        for (index, (title, symbol, help)) in items.enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(action(_:)))
            button.tag = index
            configureIcon(button, symbol: symbol)
            button.toolTip = help
            button.setAccessibilityHelp(help)
            if index == 7 { clearButton = button }
            if index == 6 {
                let divider = NSBox(); divider.boxType = .separator
                divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
                divider.heightAnchor.constraint(equalToConstant: 24).isActive = true
                tools.addArrangedSubview(divider)
            }
            if index < 6 {
                button.setButtonType(.toggle)
                toolButtons.append(button)
            }
            tools.addArrangedSubview(button)
        }
        setSelected(toolButtons[0], true)
        straightButton.target = self; straightButton.action = #selector(toggleStraight)
        straightButton.setButtonType(.toggle)
        configureIcon(straightButton, symbol: "line.diagonal")
        straightButton.toolTip = "Straight — toggle straight pen lines and arrows. Your mapped Straighten button follows Hold to straighten in Drawing settings."
        straightButton.setAccessibilityHelp(straightButton.toolTip)
        tools.insertArrangedSubview(straightButton, at: 6)
        let colorButton = NSButton(title: "Colors", target: self, action: #selector(openColors))
        configureIcon(colorButton, symbol: "paintpalette")
        colorButton.toolTip = "Colors — independent stroke, highlighter, and shape fill."
        tools.insertArrangedSubview(colorButton, at: 6)
        ink.onStraightChanged = { [weak self] enabled in
            guard let self else { return }
            self.setSelected(self.straightButton, enabled)
        }
        tools.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(tools)
        NSLayoutConstraint.activate([
            tools.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            tools.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            tools.centerYAnchor.constraint(equalTo: box.centerYAnchor)
        ])
        toolbar.contentView = box
        toolbar.setContentSize(NSSize(width: tools.fittingSize.width + 20, height: 52))
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.displayID != nil else { return }
                self.stopDrawing(); self.clear(); self.canvas.orderOut(nil); self.displayID = nil
            }
        }
    }
    private var picker: NSPanel?
    private var pickerMonitor: Any?
    private var paletteTarget = AnnotationColorTarget.stroke
    private weak var noFillButton: NSButton?
    private func dismissPicker() {
        if let pickerMonitor { NSEvent.removeMonitor(pickerMonitor) }
        pickerMonitor = nil
        picker?.orderOut(nil); picker = nil
    }
    private var toolTimer: Timer?
    private var toolMonitor: Any?
    private var toolDeactivateObserver: NSObjectProtocol?
    private var toolGestureStart: TimeInterval?
    private var toolGesturePoint = NSPoint.zero
    private var radialPanel: NSPanel?
    private var radialView: AnnotationRadialView?

    private func beginToolGesture(at point: NSPoint) {
        guard isDrawing, toolGestureStart == nil else { return }
        dismissPicker(); ink.finishStroke()
        toolGestureStart = ProcessInfo.processInfo.systemUptime
        toolGesturePoint = point
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showRadial() }
        }
        toolTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        toolDeactivateObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelToolGesture() }
        }
        toolMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .rightMouseDragged, .otherMouseDragged, .tabletPoint, .rightMouseUp, .otherMouseUp, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                switch event.type {
                case .rightMouseUp: self.ink.rightMouseUp(with: event); return true
                case .otherMouseUp: self.ink.otherMouseUp(with: event); return true
                case .leftMouseDown, .leftMouseDragged, .leftMouseUp: return true
                case .keyDown:
                    if event.keyCode == 53 { self.cancelToolGesture(); return true }
                default:
                    if let panel = self.radialPanel, let view = self.radialView {
                        view.updateHover(at: panel.convertPoint(fromScreen: NSEvent.mouseLocation))
                    }
                }
                return false
            }
            return consumed ? nil : event
        }
    }
    private func showRadial() {
        guard isDrawing, toolGestureStart != nil, radialPanel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = true; panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: canvas.level.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = AnnotationRadialView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        panel.contentView = view; radialView = view; radialPanel = panel
        place(panel, near: toolGesturePoint); panel.orderFrontRegardless()
    }
    private func finishToolGesture() {
        guard let started = toolGestureStart else { return }
        let tapped = ProcessInfo.processInfo.systemUptime - started < 0.25
        let selected = radialView?.selectedIndex
        let point = toolGesturePoint
        cancelToolGesture()
        guard isDrawing else { return }
        if tapped { selectTool(ink.tool == .pen ? 2 : 0) }
        else if let selected { chooseRadialItem(selected, at: point) }
    }
    private func chooseRadialItem(_ index: Int, at point: NSPoint) {
        switch index {
        case 0: showColorPicker(at: point)
        case 6: dismissPicker(); undo()
        default:
            let toolIndices = [1: 0, 2: 3, 3: 5, 4: 4, 5: 2, 7: 1]
            if let tool = toolIndices[index] { dismissPicker(); selectTool(tool) }
        }
    }
    @objc private func openColors() {
        cancelToolGesture()
        showColorPicker(at: NSPoint(x: ink.bounds.midX, y: ink.bounds.midY))
    }
    @objc private func backToTools() {
        guard let picker else { return }
        let point = canvas.convertPoint(fromScreen: NSPoint(x: picker.frame.midX, y: picker.frame.midY))
        dismissPicker()
        let panel = AnnotationPickerPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.onEscape = { [weak self] in self?.cancelPicker() }
        let view = AnnotationRadialView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        view.onSelect = { [weak self] index in
            guard let self else { return }
            if let index { self.chooseRadialItem(index, at: point) } else { self.cancelPicker() }
        }
        panel.contentView = view; self.picker = panel; presentPicker(panel, at: point)
    }
    private func cancelToolGesture() {
        guard toolGestureStart != nil else { return }
        ink.endDrawing() // A release outside the app must not leave a mapped button latched.
        toolTimer?.invalidate(); toolTimer = nil; toolGestureStart = nil
        if let toolMonitor { NSEvent.removeMonitor(toolMonitor) }
        toolMonitor = nil
        if let toolDeactivateObserver { NotificationCenter.default.removeObserver(toolDeactivateObserver) }
        toolDeactivateObserver = nil
        radialPanel?.orderOut(nil); radialPanel = nil; radialView = nil
    }
    @objc private func cancelPicker() { dismissPicker(); canvas.makeKeyAndOrderFront(nil); canvas.makeFirstResponder(ink) }
    private func selectTool(_ index: Int) {
        let tools: [Tool] = [.pen, .highlighter, .eraser, .arrow, .ellipse, .rectangle]
        ink.finishStroke(); ink.tool = tools[index]
        toolButtons.enumerated().forEach { setSelected($0.element, $0.offset == index) }
    }
    private func handleLocalShortcut(_ key: UInt16, at point: NSPoint) -> Bool {
        guard isDrawing else { return false }
        cancelToolGesture()
        switch key {
        case 8: showColorPicker(at: point)
        case 13: showWidthPicker(at: point)
        case 7: dismissPicker(); clear()
        default: return false
        }
        return true
    }
    private func showColorPicker(at point: NSPoint) {
        dismissPicker(); ink.finishStroke()
        paletteTarget = ink.tool == .highlighter ? .highlighter : .stroke
        let panel = AnnotationPickerPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.onEscape = { [weak self] in self?.cancelPicker() }
        let host = AnnotationPaletteView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let title = NSTextField(labelWithString: "Colors")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.alignment = .center; title.frame = NSRect(x: 110, y: 237, width: 180, height: 26)
        host.addSubview(title)
        let targets = NSSegmentedControl(labels: ["Stroke", "Highlighter", "Fill"], trackingMode: .selectOne, target: self, action: #selector(colorTargetChanged(_:)))
        targets.frame = NSRect(x: 88, y: 199, width: 224, height: 28)
        targets.selectedSegment = paletteTarget == .highlighter ? 1 : 0
        targets.setAccessibilityLabel("Color to change"); host.addSubview(targets)
        let none = NSButton(title: "No fill", target: self, action: #selector(removeFill))
        none.bezelStyle = .rounded; none.frame = NSRect(x: 154, y: 163, width: 92, height: 28)
        none.isHidden = paletteTarget != .fill; host.addSubview(none); noFillButton = none
        let back = NSButton(title: "‹ Tools", target: self, action: #selector(backToTools))
        back.bezelStyle = .rounded; back.frame = NSRect(x: 150, y: 127, width: 100, height: 28)
        host.addSubview(back)
        for (i, color) in Self.paletteColors.enumerated() {
            let angle = CGFloat.pi / 2 - CGFloat(i) * .pi / 4
            let b = NSButton(title: "●", target: self, action: #selector(colorChoice(_:)))
            b.attributedTitle = NSAttributedString(string: "●", attributes: [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: color])
            b.bezelStyle = .regularSquare; b.isBordered = false; b.tag = i
            let x = 200 + cos(angle) * 150, y = 200 + sin(angle) * 150
            b.frame = NSRect(x: x - 28, y: y - 18, width: 56, height: 48)
            let name = Self.paletteNames[i]
            b.setAccessibilityLabel(name); b.toolTip = name; host.addSubview(b)
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 11, weight: .medium); label.alignment = .center
            label.frame = NSRect(x: x - 36, y: y - 34, width: 72, height: 16)
            host.addSubview(label)
        }
        panel.contentView = host; picker = panel; presentPicker(panel, at: point)
    }
    private static let paletteColors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .white, .black]
    private static let paletteNames = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "White", "Black"]
    @objc private func colorTargetChanged(_ control: NSSegmentedControl) {
        let targets: [AnnotationColorTarget] = [.stroke, .highlighter, .fill]
        guard targets.indices.contains(control.selectedSegment) else { return }
        let target = targets[control.selectedSegment]
        paletteTarget = target; noFillButton?.isHidden = target != .fill
    }
    @objc private func removeFill() { ink.setColor(.clear, target: .fill); cancelPicker() }
    @objc private func colorChoice(_ button: NSButton) {
        ink.setColor(Self.paletteColors[button.tag], target: paletteTarget); cancelPicker()
    }
    private func showWidthPicker(at point: NSPoint) {
        dismissPicker(); ink.finishStroke()
        let panel = AnnotationPickerPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 184), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.onEscape = { [weak self] in self?.cancelPicker() }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 184))
        for width in 1...24 {
            let b = NSButton(title: "\(width)", target: self, action: #selector(widthChoice(_:)))
            b.tag = width; b.bezelStyle = .rounded
            b.frame = NSRect(x: 8 + ((width - 1) % 6) * 54, y: 140 - ((width - 1) / 6) * 42, width: 54, height: 36)
            b.setAccessibilityLabel("Stroke width \(width)")
            host.addSubview(b)
        }
        panel.contentView = host; picker = panel; presentPicker(panel, at: point)
    }
    @objc private func widthChoice(_ button: NSButton) { ink.finishStroke(); ink.setWidth(Double(button.tag)); cancelPicker() }
    private func presentPicker(_ panel: NSPanel, at point: NSPoint) {
        panel.level = NSWindow.Level(rawValue: canvas.level.rawValue + 2)
        panel.hasShadow = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        place(panel, near: point); panel.orderFrontRegardless()
        pickerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseUp, .otherMouseUp]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if event.type == .rightMouseUp { self.ink.rightMouseUp(with: event) }
                if event.type == .otherMouseUp { self.ink.otherMouseUp(with: event) }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.cancelPicker(); return true }
                    if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option, .command],
                       self.handleLocalShortcut(event.keyCode, at: self.canvas.mouseLocationOutsideOfEventStream) { return true }
                }
                if event.type == .leftMouseDown, event.window === self.canvas { self.cancelPicker(); return true }
                return false
            }
            return consumed ? nil : event
        }
    }
    private func place(_ panel: NSPanel, near point: NSPoint) {
        let location = canvas.convertPoint(toScreen: point)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) ?? canvas.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? canvas.frame
        panel.setFrameOrigin(NSPoint(x: min(max(location.x - panel.frame.width / 2, visible.minX), visible.maxX - panel.frame.width),
                                     y: min(max(location.y - panel.frame.height / 2, visible.minY), visible.maxY - panel.frame.height)))
    }
    deinit {
        toolTimer?.invalidate()
        if let toolMonitor { NSEvent.removeMonitor(toolMonitor) }
        if let toolDeactivateObserver { NotificationCenter.default.removeObserver(toolDeactivateObserver) }
        if let pickerMonitor { NSEvent.removeMonitor(pickerMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
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
        cancelToolGesture()
        dismissPicker()
        ink.endDrawing(); isDrawing = false
        canvas.ignoresMouseEvents = true; toolbar.orderOut(nil); canvas.resignKey()
        NSCursor.arrow.set()
        if previousApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApplication?.activate() }
    }
    func clear() {
        ink.clear()
        clearButton?.contentTintColor = .labelColor
        clearButton?.toolTip = "Clear all annotations."
    }
    func undo() { ink.undo() }
    private func configureIcon(_ button: NSButton, symbol: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.title)
        button.imagePosition = .imageOnly
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.contentTintColor = .labelColor
        button.toolTip = button.title
        button.setAccessibilityLabel(button.title)
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
    }
    private func setSelected(_ button: NSButton, _ selected: Bool) {
        button.state = selected ? .on : .off
        button.layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : NSColor.clear.cgColor
        button.layer?.borderColor = selected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        button.layer?.borderWidth = selected ? 1.5 : 0
    }
    @objc private func toggleStraight() { ink.toggleStraight() }
    @objc private func action(_ button: NSButton) {
        switch button.tag {
        case 0...5:
            cancelToolGesture(); selectTool(button.tag)
        case 6: undo()
        case 7: clear()
        default: stopDrawing()
        }
    }
}

private final class AnnotationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
private final class AnnotationPickerPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

private final class AnnotationPaletteView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.98).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 88, dy: 88)).stroke()
    }
}

/// Event-driven radial sectors; the canvas retains input until the held button is released.
private final class AnnotationRadialView: NSView {
    private(set) var selectedIndex: Int?
    var onSelect: ((Int?) -> Void)?
    // Clockwise from north: palette, drawing, shapes, corrections, highlight.
    private let labels = ["Colors", "Pen", "Arrow", "Rectangle", "Ellipse", "Erase", "Undo", "Highlight"]
    private let symbols = ["paintpalette", "pencil.tip", "arrow.up.right", "rectangle", "circle", "eraser", "arrow.uturn.backward", "highlighter"]
    override func mouseDown(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
        onSelect?(selectedIndex)
    }
    override var isOpaque: Bool { false }

    func updateHover(at point: NSPoint) {
        let dx = point.x - bounds.midX, dy = point.y - bounds.midY
        let index: Int?
        if hypot(dx, dy) < 36 { index = nil }
        else {
            let angle = .pi / 2 - atan2(dy, dx)
            index = (Int(floor((angle + .pi / 8) / (.pi / 4))) + 8) % 8
        }
        guard index != selectedIndex else { return }
        selectedIndex = index; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        for index in labels.indices {
            let angle = 90 - CGFloat(index) * 45
            let sector = NSBezierPath()
            sector.appendArc(withCenter: center, radius: 142, startAngle: angle - 21.5, endAngle: angle + 21.5)
            sector.appendArc(withCenter: center, radius: 38, startAngle: angle + 21.5, endAngle: angle - 21.5, clockwise: true)
            sector.close()
            (selectedIndex == index ? NSColor.controlAccentColor : NSColor.windowBackgroundColor.withAlphaComponent(0.96)).setFill()
            sector.fill()
            let radians = angle * .pi / 180
            let location = NSPoint(x: center.x + cos(radians) * 94, y: center.y + sin(radians) * 94)
            let color = selectedIndex == index ? NSColor.white : NSColor.labelColor
            if let image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: labels[index]) {
                let configuration = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
                image.withSymbolConfiguration(configuration)?.draw(in: NSRect(x: location.x - 13, y: location.y, width: 26, height: 26))
            }
            let text = labels[index] as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: color]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: location.x - size.width / 2, y: location.y - 20), withAttributes: attributes)
        }
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 34, y: center.y - 34, width: 68, height: 68)).fill()
        let cancel = "Cancel" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        let size = cancel.size(withAttributes: attributes)
        cancel.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
    }
}

final class AnnotationInk: NSView {
    private struct Sample {
        var point: CGPoint
        var radius: CGFloat
        func interpolated(to other: Sample, by t: CGFloat) -> Sample {
            Sample(point: CGPoint(x: point.x + (other.point.x - point.x) * t, y: point.y + (other.point.y - point.y) * t), radius: radius + (other.radius - radius) * t)
        }
        var bounds: CGRect { CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2) }
    }
    private final class Stroke {
        let tool: AnnotationOverlay.Tool
        let color: CGColor
        let fillColor: CGColor?
        var fillPath: CGPath?
        let width: CGFloat
        let smoothing: CGFloat
        let objectEraser: Bool
        var erased = false
        var erasedObjects: [Stroke] = []
        let start: CGPoint
        var straight: Bool
        var arrowhead: CGPath?
        var arrowBounds = CGRect.null
        var length: CGFloat = 0
        var direction = CGPoint.zero
        var headingAnchor: CGPoint
        var path = CGMutablePath()
        var preview = CGMutablePath()
        var bounds = CGRect.null
        var previewBounds = CGRect.null
        var pieces = 0
        var filtered: Sample
        var anchor: Sample
        var raw: Sample
        var isShape: Bool { tool == .ellipse || tool == .rectangle || (straight && (tool == .pen || tool == .arrow)) }
        @MainActor
        init(tool: AnnotationOverlay.Tool, settings: AnnotationSettings, sample: Sample, straight: Bool) {
            self.tool = tool
            self.straight = straight
            color = (tool == .highlighter ? settings.highlighterColor.withAlphaComponent(0.3) : settings.strokeColor).cgColor
            fillColor = (tool == .ellipse || tool == .rectangle) && settings.fillColor.alphaComponent > 0
                ? settings.fillColor.cgColor : nil
            width = CGFloat(settings.strokeWidth)
            smoothing = CGFloat(settings.smoothing)
            objectEraser = tool == .eraser && settings.eraseMode == .object
            start = sample.point; filtered = sample; anchor = sample; raw = sample
            headingAnchor = sample.point
        }
        var displayBounds: CGRect { bounds.union(previewBounds).union(arrowBounds).insetBy(dx: -2, dy: -2) }
    }
    var tool: AnnotationOverlay.Tool = .pen
    var onEscape: (() -> Void)?
    var onUpperPen: ((NSPoint) -> Void)?
    var onToolsReleased: (() -> Void)?
    var onLocalShortcut: ((UInt16, NSPoint) -> Bool)?
    var onLimit: (() -> Void)?
    var onStraightChanged: ((Bool) -> Void)?
    private var straightMode = false
    private var straightHeld = false
    private let settings: AnnotationSettings
    private var strokes: [Stroke] = []
    private var active: Stroke?
    private var pointCount = 0
    private var lastPressure: CGFloat = 1
    private let pointLimit = 100_000

    init(settings: AnnotationSettings) { self.settings = settings; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("AnnotationInk is created programmatically") }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.control, .option, .command], onLocalShortcut?(event.keyCode, window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow) == true { return }
        super.keyDown(with: event)
    }
    func setColor(_ color: NSColor, target: AnnotationColorTarget) {
        finishStroke()
        switch target {
        case .stroke: settings.strokeColor = color
        case .highlighter: settings.highlighterColor = color
        case .fill:
            let opacity = settings.fillColor.alphaComponent
            settings.fillColor = color.alphaComponent == 0 ? .clear : color.withAlphaComponent(opacity > 0 ? opacity : 1)
        }
    }
    func setWidth(_ width: Double) { finishStroke(); settings.strokeWidth = min(24, max(1, width)) }
    func toggleStraight() {
        finishStroke()
        straightMode.toggle()
        onStraightChanged?(straightMode || straightHeld)
    }
    override func rightMouseDown(with event: NSEvent) {
        handlePenAction(button: 1, event: event)
    }
    override func rightMouseUp(with event: NSEvent) {
        endPenAction(button: 1)
    }
    override func otherMouseDown(with event: NSEvent) {
        handlePenAction(button: event.buttonNumber, event: event)
    }
    override func otherMouseUp(with event: NSEvent) {
        endPenAction(button: event.buttonNumber)
    }
    private var penActions: [Int: AnnotationPenAction] = [:]
    private func handlePenAction(button: Int, event: NSEvent) {
        guard penActions[button] == nil else { return }
        let action = settings.penAction(for: button)
        penActions[button] = action
        switch action {
        case .straighten: beginStraightening(event)
        case .tools:
            if !penActions.contains(where: { $0.key != button && $0.value == .tools }) {
                onUpperPen?(event.locationInWindow)
            }
        case .color: _ = onLocalShortcut?(8, event.locationInWindow)
        case .strokeWidth: _ = onLocalShortcut?(13, event.locationInWindow)
        case .none: break
        }
    }
    private func endPenAction(button: Int) {
        guard let action = penActions.removeValue(forKey: button) else { return }
        if action == .straighten { endStraightening() }
        if action == .tools, !penActions.values.contains(.tools) { onToolsReleased?() }
    }
    private func beginStraightening(_ event: NSEvent) {
        guard settings.holdToStraighten else { toggleStraight(); return }
        straightHeld = true
        if let stroke = active, !stroke.straight, stroke.tool == .pen || stroke.tool == .arrow {
            // Convert the in-progress gesture once. Releasing does not bend it back.
            stroke.straight = true
            let oldBounds = stroke.displayBounds
            pointCount -= stroke.pieces - 1; stroke.pieces = 1
            stroke.preview = CGMutablePath(); stroke.previewBounds = .null
            updateShape(stroke, to: stroke.raw.point, shift: event.modifierFlags.contains(.shift))
            setNeedsDisplay(oldBounds)
        }
        onStraightChanged?(true)
    }
    private func endStraightening() {
        guard straightHeld else { return }
        straightHeld = false
        onStraightChanged?(active?.straight ?? straightMode)
    }
    func endDrawing() {
        finishStroke()
        penActions.removeAll()
        straightHeld = false
        onStraightChanged?(straightMode)
    }
    override func flagsChanged(with event: NSEvent) {
        if let active, active.isShape { updateShape(active, to: active.raw.point, shift: event.modifierFlags.contains(.shift)) }
    }
    override func mouseDown(with event: NSEvent) {
        finishStroke()
        let objectErasing = tool == .eraser && settings.eraseMode == .object
        guard objectErasing || (strokes.count < 512 && pointCount < pointLimit) else { onLimit?(); return }
        lastPressure = 1
        let pressure = pressure(for: event)
        let radius = radius(for: tool, width: CGFloat(settings.strokeWidth), pressure: pressure)
        let sample = Sample(point: convert(event.locationInWindow, from: nil), radius: radius)
        let stroke = Stroke(tool: tool, settings: settings, sample: sample, straight: straightMode || straightHeld)
        active = stroke
        if stroke.objectEraser {
            eraseObjects(from: sample, to: sample, gesture: stroke)
            return
        }
        stroke.path.addEllipse(in: sample.bounds)
        stroke.bounds = sample.bounds; stroke.pieces = 1; pointCount += 1
        if stroke.isShape { updateShape(stroke, to: sample.point, shift: event.modifierFlags.contains(.shift)) }
        setNeedsDisplay(stroke.displayBounds)
        onStraightChanged?(stroke.straight)
    }
    override func mouseDragged(with event: NSEvent) {
        append(event)
    }
    override func mouseUp(with event: NSEvent) {
        append(event); finishStroke()
    }

    private func pressure(for event: NSEvent) -> CGFloat {
        // Mouse-up often reports zero after the nib leaves the tablet. Keep the last contact width.
        if event.subtype == .tabletPoint, event.type != .leftMouseUp {
            lastPressure = min(1, max(0.05, CGFloat(event.pressure)))
        }
        return lastPressure
    }
    private func radius(for tool: AnnotationOverlay.Tool, width: CGFloat, pressure: CGFloat) -> CGFloat {
        width * (tool == .highlighter || tool == .eraser ? 2.5 : 0.5) * (0.25 + 0.75 * pressure)
    }
    private func append(_ event: NSEvent) {
        guard let stroke = active else { return }
        let point = convert(event.locationInWindow, from: nil)
        let radius = radius(for: stroke.tool, width: stroke.width, pressure: pressure(for: event))
        if stroke.objectEraser {
            let next = Sample(point: point, radius: radius)
            eraseObjects(from: stroke.raw, to: next, gesture: stroke)
            stroke.raw = next
            return
        }
        if stroke.isShape {
            stroke.raw.radius = radius
            updateShape(stroke, to: point, shift: event.modifierFlags.contains(.shift)); return
        }
        let raw = Sample(point: point, radius: radius)
        let distance = hypot(point.x - stroke.raw.point.x, point.y - stroke.raw.point.y)
        guard distance >= 0.35 || event.type == .leftMouseUp else { return }
        let oldTail = stroke.previewBounds
        let remaining = pointLimit - pointCount
        guard remaining > 0 else { onLimit?(); return }
        let filtered = stroke.filtered.interpolated(to: raw, by: 1 - stroke.smoothing * 0.65)
        let end = stroke.smoothing == 0 ? raw : stroke.filtered.interpolated(to: filtered, by: 0.5)
        let control = stroke.smoothing == 0 ? stroke.anchor.interpolated(to: end, by: 0.5) : stroke.filtered
        let added = addCurve(to: stroke.path, from: stroke.anchor, control: control, end: end, budget: remaining)
        stroke.pieces += added; pointCount += added
        let segmentBounds = stroke.anchor.bounds.union(control.bounds).union(end.bounds)
        stroke.bounds = stroke.bounds.union(segmentBounds)
        stroke.anchor = end; stroke.filtered = filtered; stroke.raw = raw
        // Only the short, unfinished tail is rebuilt. Its endpoint stays under the nib.
        stroke.preview = CGMutablePath()
        _ = addCurve(to: stroke.preview, from: end, control: filtered, end: raw, budget: 32)
        stroke.previewBounds = end.bounds.union(filtered.bounds).union(raw.bounds)
        let oldHead = stroke.arrowBounds
        if stroke.tool == .arrow {
            stroke.length += distance
            // A short spatial trail steadies heading even when release jitters backward.
            // Unlike a sample average, this is independent of event rate and needs no buffer.
            let dx = raw.point.x - stroke.headingAnchor.x, dy = raw.point.y - stroke.headingAnchor.y
            let headingDistance = hypot(dx, dy)
            if headingDistance > 0.01 { stroke.direction = CGPoint(x: dx, y: dy) }
            if headingDistance > 6 {
                stroke.headingAnchor = CGPoint(x: raw.point.x - dx * 6 / headingDistance,
                                               y: raw.point.y - dy * 6 / headingDistance)
            }
            stroke.arrowhead = arrowhead(at: raw.point, direction: stroke.direction, length: stroke.length, width: raw.radius * 2)
            stroke.arrowBounds = stroke.arrowhead?.boundingBoxOfPath ?? .null
            setNeedsDisplay(oldHead.union(stroke.arrowBounds).insetBy(dx: -2, dy: -2))
        }
        setNeedsDisplay(oldTail.union(segmentBounds).union(stroke.previewBounds).insetBy(dx: -2, dy: -2))
    }
    private func eraseObjects(from start: Sample, to end: Sample, gesture: Stroke) {
        // Test the swept tip, not just event points, so fast passes cannot skip thin ink.
        let sweepBounds = start.bounds.union(end.bounds)
        let sweep = CGMutablePath()
        sweep.addEllipse(in: start.bounds)
        _ = addCurve(to: sweep, from: start, control: start.interpolated(to: end, by: 0.5), end: end, budget: 1)
        for (index, candidate) in strokes.enumerated()
            where !candidate.erased && candidate.tool != .eraser && candidate.displayBounds.intersects(sweepBounds) {
            var hit = candidate.path.intersection(sweep, using: .winding)
            if let head = candidate.arrowhead, candidate.arrowBounds.intersects(sweepBounds) {
                hit = hit.union(head.intersection(sweep, using: .winding), using: .winding)
            }
            if let fill = candidate.fillPath {
                hit = hit.union(fill.intersection(sweep, using: .winding), using: .winding)
            }
            guard !hit.isEmpty else { continue }
            // Previously rubbed-out pixels are not a target for whole-object erasing.
            for later in strokes[(index + 1)...]
                where later.tool == .eraser && !later.objectEraser && later.displayBounds.intersects(sweepBounds) {
                hit = hit.subtracting(later.path, using: .winding)
                if hit.isEmpty { break }
            }
            guard !hit.isEmpty else { continue }
            candidate.erased = true
            gesture.erasedObjects.append(candidate)
            gesture.bounds = gesture.bounds.union(candidate.displayBounds)
            setNeedsDisplay(candidate.displayBounds)
        }
    }
    /// Quadratic centerline and radius interpolation; bounded adaptive tessellation into filled ink.
    private func addCurve(to path: CGMutablePath, from start: Sample, control: Sample, end: Sample, budget: Int) -> Int {
        let length = hypot(control.point.x - start.point.x, control.point.y - start.point.y) + hypot(end.point.x - control.point.x, end.point.y - control.point.y)
        let steps = min(budget, min(32, max(1, Int(ceil(length / 2)))))
        guard steps > 0 else { return 0 }
        var previous = start
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let next = start.interpolated(to: control, by: t).interpolated(to: control.interpolated(to: end, by: t), by: t)
            let dx = next.point.x - previous.point.x, dy = next.point.y - previous.point.y
            let length = hypot(dx, dy)
            if length > 0.0001 {
                let nx = -dy / length, ny = dx / length
                // Match the ellipse winding so overlaps are a union under nonzero fill.
                path.move(to: CGPoint(x: previous.point.x + nx * previous.radius, y: previous.point.y + ny * previous.radius))
                path.addLine(to: CGPoint(x: previous.point.x - nx * previous.radius, y: previous.point.y - ny * previous.radius))
                path.addLine(to: CGPoint(x: next.point.x - nx * next.radius, y: next.point.y - ny * next.radius))
                path.addLine(to: CGPoint(x: next.point.x + nx * next.radius, y: next.point.y + ny * next.radius))
                path.closeSubpath()
            }
            path.addEllipse(in: next.bounds)
            previous = next
        }
        return steps
    }
    private func updateShape(_ stroke: Stroke, to raw: CGPoint, shift: Bool) {
        let old = stroke.displayBounds
        stroke.raw.point = raw
        let a = stroke.start
        var b = raw
        let dx = b.x - a.x, dy = b.y - a.y
        if shift {
            if stroke.tool == .arrow || stroke.tool == .pen {
                let length = hypot(dx, dy), step = CGFloat.pi / 12
                let angle = (atan2(dy, dx) / step).rounded() * step
                b = CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
            } else {
                let side = max(abs(dx), abs(dy))
                b = CGPoint(x: a.x + (dx < 0 ? -side : side), y: a.y + (dy < 0 ? -side : side))
            }
        }
        if stroke.tool == .arrow {
            let dx = b.x - a.x, dy = b.y - a.y
            stroke.arrowhead = arrowhead(at: b, direction: CGPoint(x: dx, y: dy), length: hypot(dx, dy), width: stroke.raw.radius * 2)
            stroke.arrowBounds = stroke.arrowhead?.boundingBoxOfPath ?? .null
        }
        stroke.path = CGMutablePath()
        stroke.fillPath = nil
        if stroke.tool == .pen || stroke.tool == .arrow {
            let start = Sample(point: a, radius: stroke.raw.radius)
            let end = Sample(point: b, radius: stroke.raw.radius)
            stroke.path.addEllipse(in: start.bounds)
            _ = addCurve(to: stroke.path, from: start, control: start.interpolated(to: end, by: 0.5), end: end, budget: 32)
        } else if hypot(b.x - a.x, b.y - a.y) < 0.001 {
            stroke.path.addEllipse(in: CGRect(x: a.x - stroke.width / 2, y: a.y - stroke.width / 2, width: stroke.width, height: stroke.width))
        } else {
            let centerline = CGMutablePath()
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            if stroke.tool == .ellipse { centerline.addEllipse(in: rect) } else { centerline.addRect(rect) }
            if stroke.fillColor != nil { stroke.fillPath = centerline }
            stroke.path.addPath(centerline.copy(strokingWithWidth: stroke.width, lineCap: .round, lineJoin: .round, miterLimit: 2))
        }
        stroke.bounds = stroke.path.boundingBoxOfPath
        setNeedsDisplay(old.union(stroke.displayBounds))
    }
    private func arrowhead(at tip: CGPoint, direction: CGPoint, length: CGFloat, width: CGFloat) -> CGPath? {
        let magnitude = hypot(direction.x, direction.y)
        guard magnitude > 0.001, length > 0.001 else { return nil }
        let head = min(max(10, width * 4), length * 0.45)
        let ux = direction.x / magnitude, uy = direction.y / magnitude
        let back = head * cos(CGFloat.pi / 6), wing = head * sin(CGFloat.pi / 6)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: tip.x - ux * back - uy * wing, y: tip.y - uy * back + ux * wing))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: tip.x - ux * back + uy * wing, y: tip.y - uy * back - ux * wing))
        return path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 2)
    }
    func finishStroke() {
        guard let stroke = active else { return }
        if stroke.objectEraser {
            if !stroke.erasedObjects.isEmpty { strokes.append(stroke) }
            active = nil
            return
        }
        // Retain the exact preview on mouse-up, Escape, or tool change; no endpoint jump.
        stroke.path.addPath(stroke.preview)
        stroke.bounds = stroke.bounds.union(stroke.previewBounds)
        stroke.preview = CGMutablePath(); stroke.previewBounds = .null
        strokes.append(stroke); active = nil
        onStraightChanged?(straightMode || straightHeld)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        for stroke in strokes where stroke.displayBounds.intersects(dirtyRect) { draw(stroke, in: context) }
        if let active, active.displayBounds.intersects(dirtyRect) { draw(active, in: context) }
    }
    private func draw(_ stroke: Stroke, in context: CGContext) {
        guard !stroke.erased, !stroke.objectEraser else { return }
        context.saveGState()
        context.setBlendMode(stroke.tool == .eraser ? .clear : .normal)
        if let fill = stroke.fillPath, let color = stroke.fillColor {
            context.setFillColor(color); context.addPath(fill); context.fillPath()
        }
        context.setFillColor(stroke.color)
        context.addPath(stroke.path); context.addPath(stroke.preview)
        context.fillPath() // One fill keeps overlapping highlighter segments at uniform alpha.
        if let head = stroke.arrowhead { context.addPath(head); context.fillPath() }
        context.restoreGState()
    }
    func clear() {
        strokes.removeAll(keepingCapacity: true); active = nil; pointCount = 0; needsDisplay = true
        onStraightChanged?(straightMode || straightHeld)
    }
    func undo() {
        finishStroke()
        guard let stroke = strokes.popLast() else { return }
        for object in stroke.erasedObjects { object.erased = false }
        pointCount -= stroke.pieces
        setNeedsDisplay(stroke.displayBounds)
    }
}
