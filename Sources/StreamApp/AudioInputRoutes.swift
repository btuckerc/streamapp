import AVFoundation
import CoreAudio

/// Non-capturing hardware metadata; no route names or polling heuristics.
enum AudioInputRoutes {
    static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, into value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutableBytes(of: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) == noErr
        }
    }
    static var devices: [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        guard size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = result.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? result : []
    }
    static func option(_ device: AVCaptureDevice) -> DeviceOption {
        var defaultID = AudioObjectID(0)
        _ = scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, into: &defaultID)
        let object = devices.first { object in
            var uid: CFString = "" as CFString
            return scalar(object, kAudioDevicePropertyDeviceUID, into: &uid) && uid as String == device.uniqueID
        }
        var channels = 0
        var transport: UInt32 = 0
        if let object {
            _ = scalar(object, kAudioDevicePropertyTransportType, into: &transport)
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            if AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 {
                let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
                defer { storage.deallocate() }
                if AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage) == noErr {
                    channels = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
                }
            }
        }
        if channels == 0, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription) {
            channels = Int(asbd.pointee.mChannelsPerFrame)
        }
        return DeviceOption(id: device.uniqueID, name: device.localizedName, inputChannels: channels,
                            bluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                            isDefaultInput: object == defaultID)
    }
}

/// Long-lived HAL route listeners, registered once per object. Never rebuild these per
/// notification: on macOS 27 each AudioObjectRemovePropertyListenerBlock leaves residue in the
/// object's listener list, so add/remove churn grows every later add/remove until the main
/// thread spends all its time scanning that list. `sync()` only touches devices that appeared
/// or vanished. Callbacks run on main; the owner coalesces bursts into one refresh.
@MainActor
final class AudioInputRouteObserver {
    private typealias Listener = (address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)
    private let changed: () -> Void
    private var listeners: [AudioObjectID: [Listener]] = [:]

    init(changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        let system = AudioObjectID(kAudioObjectSystemObject)
        listeners[system] = [observe(system, kAudioHardwarePropertyDefaultInputDevice),
                             observe(system, kAudioHardwarePropertyDevices)].compactMap { $0 }
        sync()
    }

    /// Adds listeners for new devices and drops vanished ones; present devices are untouched.
    func sync() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let current = Set(AudioInputRoutes.devices)
        for (object, registered) in listeners where object != system && !current.contains(object) {
            for listener in registered { remove(object, listener) }
            listeners[object] = nil
        }
        for device in current where listeners[device] == nil {
            listeners[device] = [observe(device, kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput),
                                 observe(device, kAudioDevicePropertyTransportType)].compactMap { $0 }
        }
    }

    private func observe(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Listener? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.changed() }
        }
        return AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr ? (address, block) : nil
    }

    private func remove(_ object: AudioObjectID, _ listener: Listener) {
        var address = listener.address
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, listener.block)
    }

    isolated deinit {
        for (object, registered) in listeners { for listener in registered { remove(object, listener) } }
    }
}
