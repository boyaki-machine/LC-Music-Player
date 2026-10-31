import Foundation
import LibraryCore
import Observation
#if os(macOS)
import IOKit.ps
#else
import UIKit
#endif

/// Watches the power source and the output device while the radio cassette is on screen.
/// Nothing is watched while it is hidden.
@Observable @MainActor
final class RadioCassetteMonitor {
    private(set) var power = RadioCassetteStatus.Power.unknown
    private(set) var output: OutputDevice?
    @ObservationIgnored private var outputSystem: (any OutputVolumeSystem)?
    #if os(macOS)
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    #else
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    #endif
    var isRunning: Bool { outputSystem != nil }

    func start() {
        guard outputSystem == nil else { return }
        #if os(macOS)
        let system = CoreAudioOutputVolume(watchesDataSource: true)
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<RadioCassetteMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.readPower() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        #else
        let system = AudioSessionOutputVolume()
        BatteryMonitoring.request(true, by: ObjectIdentifier(self))
        observers = [UIDevice.batteryStateDidChangeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.readPower() }
            }
        }
        #endif
        system.onChange = { [weak self] in self?.readOutput() }
        outputSystem = system
        readPower(); readOutput()
    }

    func stop() {
        guard outputSystem != nil else { return }
        outputSystem?.onChange = nil; outputSystem = nil
        #if os(macOS)
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        powerSource = nil
        #else
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        BatteryMonitoring.request(false, by: ObjectIdentifier(self))
        #endif
    }

    isolated deinit { stop() }

    private func readOutput() {
        let next = outputSystem?.currentDevice
        // Devices compare by identity; the name and the speaker flag can change on their own.
        if next != output || next?.name != output?.name || next?.isBuiltInSpeaker != output?.isBuiltInSpeaker { output = next }
    }

    private func readPower() {
        let next: RadioCassetteStatus.Power
        #if os(macOS)
        // A Mac without a battery reports AC power.
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let type = info.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String? }
        next = type == kIOPMBatteryPowerKey ? .battery : type == nil ? .unknown : .external
        #else
        switch UIDevice.current.batteryState {
        case .unplugged: next = .battery
        case .charging, .full: next = .external
        default: next = .unknown
        }
        #endif
        if next != power { power = next }
    }
}
