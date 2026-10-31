import Foundation
#if os(macOS)
import CoreAudio

/// The Mac's default output device and its volume, read through Core Audio. The device is known by
/// its UID and transport type. The system volume is only read: the app never writes it.
@MainActor public final class CoreAudioOutputVolume: OutputVolumeSystem {
    private struct Registration {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    public var onChange: (@MainActor () -> Void)?
    public var canSetSystemVolume: Bool { false }
    private var registrations: [Registration] = []
    private let watchesDataSource: Bool
    /// `watchesDataSource` also reports headphones plugged into the built-in jack, for showing the device;
    /// the volume memory does not need it, since the device stays the same.
    public init(watchesDataSource: Bool = false) { self.watchesDataSource = watchesDataSource; install() }
    isolated deinit { remove() }

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
    private var defaultDevice: AudioObjectID? {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }
    public var currentDevice: OutputDevice? {
        guard let device = defaultDevice else { return nil }
        var address = Self.address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        var transport: UInt32 = 0, transportSize = UInt32(MemoryLayout<UInt32>.size)
        address = Self.address(kAudioDevicePropertyTransportType)
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &transportSize, &transport)
        var name: Unmanaged<CFString>?, nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address = Self.address(kAudioObjectPropertyName)
        let named = AudioObjectGetPropertyData(device, &address, 0, nil, &nameSize, &name) == noErr
        // A built-in device plays through the speaker unless headphones take its data source.
        var source: UInt32 = 0, sourceSize = UInt32(MemoryLayout<UInt32>.size)
        address = Self.address(kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)
        let hasSource = AudioObjectGetPropertyData(device, &address, 0, nil, &sourceSize, &source) == noErr
        let speaker = transport == kAudioDeviceTransportTypeBuiltIn && (!hasSource || source == Self.internalSpeaker)
        return OutputDevice(kind: Self.fourCC(transport), identifier: uid.takeRetainedValue() as String,
                            name: named ? name?.takeRetainedValue() as String? : nil, isBuiltInSpeaker: speaker)
    }
    /// The built-in output's data source code for the internal speaker ('ispk').
    private static let internalSpeaker: UInt32 = 0x6973_706B
    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
    private func scalar(_ device: AudioObjectID, element: AudioObjectPropertyElement) -> Float? {
        var address = Self.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
    /// The main volume, or the mean of the first two channels on devices without one.
    public var systemVolume: Float? {
        guard let device = defaultDevice else { return nil }
        if let main = scalar(device, element: kAudioObjectPropertyElementMain) { return main }
        let channels = [1, 2].compactMap { scalar(device, element: AudioObjectPropertyElement($0)) }
        return channels.isEmpty ? nil : channels.reduce(0, +) / Float(channels.count)
    }
    public func setSystemVolume(_ value: Float) {}

    private func remove() {
        for var registration in registrations {
            AudioObjectRemovePropertyListenerBlock(registration.object, &registration.address, .main, registration.block)
        }
        registrations.removeAll()
    }
    private func watch(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, reinstall: Bool) {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if reinstall { self.remove(); self.install() }
                self.onChange?()
            }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            registrations.append(Registration(object: object, address: address, block: block))
        }
    }
    private func install() {
        watch(AudioObjectID(kAudioObjectSystemObject), Self.address(kAudioHardwarePropertyDefaultOutputDevice), reinstall: true)
        guard let device = defaultDevice else { return }
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            watch(device, Self.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element), reinstall: false)
        }
        if watchesDataSource { watch(device, Self.address(kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput), reinstall: false) }
    }
}
#else
import AVFAudio

/// The iPhone's audio route and system volume. The route's first output names the device: its
/// port type is the kind and its UID the individual device. iOS has no public way to set the system
/// volume, so the app passes in `setter` (it moves the slider of a hidden system volume view).
@MainActor public final class AudioSessionOutputVolume: OutputVolumeSystem {
    public var onChange: (@MainActor () -> Void)?
    private let setter: (@MainActor (Float) -> Void)?
    private var token: (any NSObjectProtocol)?
    private var volumeObservation: NSKeyValueObservation?
    public init(setter: (@MainActor (Float) -> Void)? = nil) {
        self.setter = setter
        let session = AVAudioSession.sharedInstance()
        token = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        volumeObservation = session.observe(\.outputVolume) { [weak self] _, _ in
            Task { @MainActor in self?.onChange?() }
        }
    }
    isolated deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    public var currentDevice: OutputDevice? {
        AVAudioSession.sharedInstance().currentRoute.outputs.first.map {
            OutputDevice(kind: $0.portType.rawValue, identifier: $0.uid, name: $0.portName, isBuiltInSpeaker: $0.portType == .builtInSpeaker)
        }
    }
    public var systemVolume: Float? { AVAudioSession.sharedInstance().outputVolume }
    public var canSetSystemVolume: Bool { setter != nil }
    public func setSystemVolume(_ value: Float) { setter?(value) }
}
#endif
