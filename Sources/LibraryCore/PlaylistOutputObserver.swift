import Foundation
import CoreAudio

/// Watches output identity/format while an idle playlist sweep has no playback engine.
/// No polling, output-device writes, or filesystem work occurs in the callback.
@MainActor final class PlaylistOutputObserver {
    private struct Registration {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var registrations: [Registration] = []
    private let changed: @MainActor () -> Void
    init(changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        install()
    }
    isolated deinit { remove() }
    private func remove() {
        for var registration in registrations {
            AudioObjectRemovePropertyListenerBlock(registration.object, &registration.address, .main, registration.block)
        }
        registrations.removeAll()
    }
    private func watch(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.remove(); self.install(); self.changed()
            }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            registrations.append(Registration(object: object, address: address, block: block))
        }
    }
    private func install() {
        watch(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return }
        watch(device, kAudioDevicePropertyNominalSampleRate)
        watch(device, kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
    }
}
