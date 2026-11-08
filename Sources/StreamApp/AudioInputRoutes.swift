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

/// Property listeners are removed with their owner. A list change rebuilds the
/// subscription via StudioModel's existing coalesced device refresh generation.
final class AudioInputRouteObserver: @unchecked Sendable {
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    init(changed: @escaping @Sendable () -> Void) {
        func observe(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
            if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr { listeners.append((object, address, block)) }
        }
        observe(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        observe(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        for device in AudioInputRoutes.devices {
            observe(device, kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
            observe(device, kAudioDevicePropertyTransportType)
        }
    }
    deinit {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
    }
}
