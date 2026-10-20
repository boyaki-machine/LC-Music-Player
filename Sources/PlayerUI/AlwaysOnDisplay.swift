import Foundation
import Observation

/// The device's battery as the always-on display needs it. `level` is nil when unknown (the simulator).
public struct PowerStatus: Equatable, Sendable {
    public var level: Float?
    public var charging: Bool
    public init(level: Float?, charging: Bool) { self.level = level; self.charging = charging }
}

/// Keeps the screen on while the animation is watched, e.g. with the iPhone on a stand.
/// The listener turns it on; it gives way to the normal auto-lock when the battery runs low
/// and the device is not charging. Turning it on is not kept across launches.
@Observable @MainActor
public final class AlwaysOnDisplay {
    /// At or below this battery level, and not charging, the screen may sleep again.
    public nonisolated static let minimumBatteryLevel: Float = 0.3

    public private(set) var isRequested = false
    public private(set) var power: PowerStatus
    /// True while the screen is actually kept on.
    public var keepsAwake: Bool { Self.keepsAwake(requested: isRequested, power: power) }
    /// Requested, but released because the battery is low.
    public var isHeldBackByBattery: Bool { isRequested && !keepsAwake }

    @ObservationIgnored private let monitor: (Bool) -> Void
    @ObservationIgnored private let apply: (Bool) -> Void
    @ObservationIgnored private var applied = false

    /// `monitor` starts or stops battery reports, which arrive through `powerChanged(_:)`;
    /// `apply` turns the system's auto-lock off (true) or back on (false).
    public init(power: PowerStatus, monitor: @escaping (Bool) -> Void, apply: @escaping (Bool) -> Void) {
        self.power = power; self.monitor = monitor; self.apply = apply
    }

    nonisolated static func keepsAwake(requested: Bool, power: PowerStatus) -> Bool {
        guard requested else { return false }
        if power.charging { return true }
        guard let level = power.level, level >= 0 else { return true }
        return level > minimumBatteryLevel
    }

    public func setRequested(_ requested: Bool) {
        guard requested != isRequested else { return }
        isRequested = requested
        monitor(requested)
        update()
    }
    public func powerChanged(_ status: PowerStatus) {
        power = status
        update()
    }
    private func update() {
        let next = keepsAwake
        guard next != applied else { return }
        applied = next
        apply(next)
    }
}

#if os(iOS)
import UIKit

extension AlwaysOnDisplay {
    /// The iPhone's battery and auto-lock. Battery reports are read only while always-on is requested.
    public static func device() -> AlwaysOnDisplay {
        let battery = DeviceBattery()
        let display = AlwaysOnDisplay(power: PowerStatus(level: nil, charging: false),
                                      monitor: { battery.monitor($0) }, apply: { UIApplication.shared.isIdleTimerDisabled = $0 })
        battery.display = display
        return display
    }
}

@MainActor private final class DeviceBattery {
    weak var display: AlwaysOnDisplay?
    private var observers: [NSObjectProtocol] = []

    func monitor(_ on: Bool) {
        UIDevice.current.isBatteryMonitoringEnabled = on
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard on else { return }
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            })
        }
        // Read the battery at once; the first notification can take a minute.
        report()
    }
    private func report() {
        let device = UIDevice.current, level = device.batteryLevel
        display?.powerChanged(PowerStatus(level: level < 0 ? nil : level,
                                          charging: device.batteryState == .charging || device.batteryState == .full))
    }
}
#endif
