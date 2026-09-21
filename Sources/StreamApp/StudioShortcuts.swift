import AppKit
import Carbon.HIToolbox

/// Owns the application's global Carbon hot keys and routes them by hot-key ID.
@MainActor
final class StudioShortcuts {
    enum Registration: String { case annotation, cameraPunchIn, transcriptNext, transcriptPrevious }

    var onAnnotation: (() -> Void)?
    var onCameraPunchIn: (() -> Void)?
    var onTranscriptNext: (() -> Void)?
    var onTranscriptPrevious: (() -> Void)?
    var onRegistrationFailure: ((Registration, OSStatus) -> Void)?

    private var handler: EventHandlerRef?
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var pressed = Set<UInt32>()
    private let signature: OSType = 0x5354524D

    init() {}

    func start() {
        guard handler == nil, hotKeys.isEmpty else { return }
        install()
    }

    /// Reserve unmodified arrows only while a transcript is being presented.
    func setTranscriptEnabled(_ enabled: Bool) {
        if enabled {
            guard handler != nil else { return }
            if hotKeys[3] == nil { register(keyCode: UInt32(kVK_RightArrow), id: 3, registration: .transcriptNext, modifiers: 0) }
            if hotKeys[4] == nil { register(keyCode: UInt32(kVK_LeftArrow), id: 4, registration: .transcriptPrevious, modifiers: 0) }
        } else {
            for id: UInt32 in [3, 4] {
                if let ref = hotKeys.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
                pressed.remove(id)
            }
        }
    }
    deinit {
        for ref in hotKeys.values { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    private func install() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let callback: EventHandlerUPP = { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<StudioShortcuts>.fromOpaque(pointer).takeUnretainedValue()
            return MainActor.assumeIsolated { owner.handle(event) }
        }
        let status = InstallEventHandler(GetApplicationEventTarget(), callback, types.count, &types,
                                         Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            onRegistrationFailure?(.annotation, status)
            onRegistrationFailure?(.cameraPunchIn, status)
            return
        }
        register(keyCode: UInt32(kVK_ANSI_D), id: 1, registration: .annotation)
        register(keyCode: UInt32(kVK_ANSI_V), id: 2, registration: .cameraPunchIn)
    }

    private func register(keyCode: UInt32, id: UInt32, registration: Registration, modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey)) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            onRegistrationFailure?(registration, status)
            return
        }
        hotKeys[id] = ref
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID), nil,
                                       MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        guard status == noErr, hotKeyID.signature == signature, hotKeys[hotKeyID.id] != nil else {
            return OSStatus(eventNotHandledErr)
        }
        let id = hotKeyID.id
        let kind = GetEventKind(event)
        if kind == UInt32(kEventHotKeyReleased) {
            pressed.remove(id)
            return noErr
        }
        guard kind == UInt32(kEventHotKeyPressed) else { return OSStatus(eventNotHandledErr) }
        guard pressed.insert(id).inserted else { return noErr }
        switch id {
        case 1: onAnnotation?()
        case 2: onCameraPunchIn?()
        case 3: onTranscriptNext?()
        case 4: onTranscriptPrevious?()
        default: return OSStatus(eventNotHandledErr)
        }
        return noErr
    }
}
