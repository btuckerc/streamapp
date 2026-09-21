import AppKit
import Combine

enum AnnotationPenAction: String, CaseIterable, Identifiable {
    case none
    case straighten
    case tools
    case color
    case strokeWidth

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .straighten: return "Straighten"
        case .tools: return "Tool picker"
        case .color: return "Color"
        case .strokeWidth: return "Stroke width"
        }
    }
}

enum AnnotationEraseMode: String, CaseIterable, Identifiable {
    case object, partial
    var id: String { rawValue }
    var title: String { self == .object ? "Object" : "Partial" }
}

@MainActor
final class AnnotationSettings: ObservableObject {
    static let defaultSmoothing = 0.5
    static let defaultStrokeWidth = 6.0
    static let defaultStrokeColor = NSColor.systemRed
    static let defaultHighlighterColor = NSColor.systemYellow
    static let defaultFillColor = NSColor.clear
    static let defaultHoldToStraighten = true
    static let defaultEraseMode: AnnotationEraseMode = .object

    @Published var smoothing: Double {
        didSet { let clamped = Self.clamp(smoothing, to: 0...1); if smoothing != clamped { smoothing = clamped }; persistValue(smoothing, forKey: Self.smoothingKey) }
    }
    @Published var strokeWidth: Double {
        didSet { let clamped = Self.clamp(strokeWidth, to: 1...24); if strokeWidth != clamped { strokeWidth = clamped }; persistValue(strokeWidth, forKey: Self.strokeWidthKey) }
    }
    @Published var strokeColor: NSColor {
        didSet { let normalized = Self.sanitizeColor(strokeColor, fallback: Self.defaultStrokeColor, preservesAlpha: false); if !strokeColor.isEqual(normalized) { strokeColor = normalized }; persistColor(strokeColor, keys: Self.strokeColorKeys) }
    }
    @Published var highlighterColor: NSColor {
        didSet { let normalized = Self.sanitizeColor(highlighterColor, fallback: Self.defaultHighlighterColor, preservesAlpha: false); if !highlighterColor.isEqual(normalized) { highlighterColor = normalized }; persistColor(highlighterColor, keys: Self.highlighterColorKeys) }
    }
    @Published var fillColor: NSColor {
        didSet { let normalized = Self.sanitizeColor(fillColor, fallback: Self.defaultFillColor, preservesAlpha: true); if !fillColor.isEqual(normalized) { fillColor = normalized }; persistColor(fillColor, keys: Self.fillColorKeys) }
    }
    @Published var holdToStraighten: Bool {
        didSet { guard persist else { return }; UserDefaults.standard.set(holdToStraighten, forKey: Self.holdToStraightenKey) }
    }
    @Published var eraseMode: AnnotationEraseMode {
        didSet { guard persist else { return }; UserDefaults.standard.set(eraseMode.rawValue, forKey: Self.eraseModeKey) }
    }
    @Published private(set) var penActions: [Int: AnnotationPenAction]

    private let persist: Bool
    private static let smoothingKey = "StreamApp.annotation.smoothing"
    private static let strokeWidthKey = "StreamApp.annotation.strokeWidth"
    private static let holdToStraightenKey = "StreamApp.annotation.holdToStraighten"
    private static let penActionsKey = "StreamApp.annotation.penActions"
    private static let eraseModeKey = "StreamApp.annotation.eraseMode"
    private static let redKey = "StreamApp.annotation.color.red"
    private static let greenKey = "StreamApp.annotation.color.green"
    private static let blueKey = "StreamApp.annotation.color.blue"
    private static let highlighterRedKey = "StreamApp.annotation.highlighter.red"
    private static let highlighterGreenKey = "StreamApp.annotation.highlighter.green"
    private static let highlighterBlueKey = "StreamApp.annotation.highlighter.blue"
    private static let fillRedKey = "StreamApp.annotation.fill.red"
    private static let fillGreenKey = "StreamApp.annotation.fill.green"
    private static let fillBlueKey = "StreamApp.annotation.fill.blue"
    private static let fillAlphaKey = "StreamApp.annotation.fill.alpha"
    private static let strokeColorKeys = (red: redKey, green: greenKey, blue: blueKey, alpha: nil as String?)
    private static let highlighterColorKeys = (red: highlighterRedKey, green: highlighterGreenKey, blue: highlighterBlueKey, alpha: nil as String?)
    private static let fillColorKeys = (red: fillRedKey, green: fillGreenKey, blue: fillBlueKey, alpha: fillAlphaKey as String?)

    init(persist: Bool = true) {
        self.persist = persist
        let defaults = UserDefaults.standard
        let savedSmoothing = defaults.object(forKey: Self.smoothingKey) as? NSNumber
        let savedWidth = defaults.object(forKey: Self.strokeWidthKey) as? NSNumber
        smoothing = Self.clamp(savedSmoothing?.doubleValue ?? Self.defaultSmoothing, to: 0...1)
        strokeWidth = Self.clamp(savedWidth?.doubleValue ?? Self.defaultStrokeWidth, to: 1...24)
        holdToStraighten = defaults.object(forKey: Self.holdToStraightenKey) as? Bool ?? Self.defaultHoldToStraighten
        eraseMode = defaults.string(forKey: Self.eraseModeKey).flatMap(AnnotationEraseMode.init(rawValue:)) ?? Self.defaultEraseMode
        var loaded: [Int: AnnotationPenAction] = [1: .tools, 2: .straighten]
        if let saved = defaults.dictionary(forKey: Self.penActionsKey) as? [String: String] {
            let sanitized = saved.reduce(into: [Int: AnnotationPenAction]()) { result, pair in
                guard let button = Int(pair.key), (1...31).contains(button),
                      let action = AnnotationPenAction(rawValue: pair.value), action != .none else { return }
                result[button] = action
            }
            if !saved.isEmpty && sanitized.isEmpty {
                loaded = [1: .tools, 2: .straighten]
            } else {
                loaded = sanitized
            }
        }
        penActions = loaded
        strokeColor = Self.loadColor(default: Self.defaultStrokeColor, keys: Self.strokeColorKeys, preservesAlpha: false)
        highlighterColor = Self.loadColor(default: Self.defaultHighlighterColor, keys: Self.highlighterColorKeys, preservesAlpha: false)
        fillColor = Self.loadColor(default: Self.defaultFillColor, keys: Self.fillColorKeys, preservesAlpha: true)
    }
    func penAction(for button: Int) -> AnnotationPenAction {
        guard (1...31).contains(button) else { return .none }
        return penActions[button] ?? .none
    }

    func setPenAction(_ action: AnnotationPenAction, for button: Int) {
        guard (1...31).contains(button) else { return }
        if action == .none { penActions.removeValue(forKey: button) } else { penActions[button] = action }
        persistPenActions()
    }
    func restorePenDefaults() {
        penActions = [1: .tools, 2: .straighten]
        persistPenActions()
    }

    func restoreDefaults() {
        smoothing = Self.defaultSmoothing; strokeWidth = Self.defaultStrokeWidth
        strokeColor = Self.defaultStrokeColor; highlighterColor = Self.defaultHighlighterColor; fillColor = Self.defaultFillColor
        holdToStraighten = Self.defaultHoldToStraighten
        eraseMode = Self.defaultEraseMode
        penActions = [1: .tools, 2: .straighten]
        persistPenActions()
    }

    private func persistValue(_ value: Double, forKey key: String) { guard persist else { return }; UserDefaults.standard.set(value, forKey: key) }
    private func persistColor(_ value: NSColor, keys: (red: String, green: String, blue: String, alpha: String?)) {
        guard persist, let rgba = Self.rgbaComponents(value) else { return }
        let defaults = UserDefaults.standard
        defaults.set(Double(rgba.red), forKey: keys.red); defaults.set(Double(rgba.green), forKey: keys.green); defaults.set(Double(rgba.blue), forKey: keys.blue)
        if let alpha = keys.alpha { defaults.set(Double(rgba.alpha), forKey: alpha) }
    }
    private func persistPenActions() { guard persist else { return }; UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: penActions.map { (String($0.key), $0.value.rawValue) }), forKey: Self.penActionsKey) }
    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double { guard value.isFinite else { return range.lowerBound }; return min(range.upperBound, max(range.lowerBound, value)) }
    private static func loadColor(default fallback: NSColor, keys: (red: String, green: String, blue: String, alpha: String?), preservesAlpha: Bool) -> NSColor {
        let defaults = UserDefaults.standard
        guard let red = defaults.object(forKey: keys.red) as? NSNumber,
              let green = defaults.object(forKey: keys.green) as? NSNumber,
              let blue = defaults.object(forKey: keys.blue) as? NSNumber else { return fallback }
        let alpha: Double
        if let alphaKey = keys.alpha {
            guard let savedAlpha = defaults.object(forKey: alphaKey) as? NSNumber else { return fallback }
            alpha = savedAlpha.doubleValue
        } else {
            alpha = 1
        }
        let values = [red.doubleValue, green.doubleValue, blue.doubleValue, alpha]
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return fallback }
        return NSColor(red: CGFloat(values[0]), green: CGFloat(values[1]), blue: CGFloat(values[2]), alpha: CGFloat(preservesAlpha ? values[3] : 1))
    }
    private static func sanitizeColor(_ value: NSColor, fallback: NSColor, preservesAlpha: Bool) -> NSColor {
        guard let rgba = rgbaComponents(value) else { return fallback }
        return NSColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: preservesAlpha ? rgba.alpha : 1)
    }
    private static func rgbaComponents(_ value: NSColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        guard let rgb = value.usingColorSpace(.sRGB) else { return nil }
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
        guard components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
    }
}
