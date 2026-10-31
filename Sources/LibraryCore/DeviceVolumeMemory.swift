import Foundation
import Observation
import PlaybackCore

/// The output device that plays the app's audio: its kind (built-in speaker, wired, Bluetooth…)
/// and an identifier of the individual device. The name and the speaker flag are for display;
/// a device is the same device whatever they say (a Mac's headphone jack keeps its identifier).
public struct OutputDevice: Equatable, Sendable {
    public var kind: String
    public var identifier: String
    /// The name the system shows, e.g. the Bluetooth headphones' name; nil when unknown.
    public var name: String?
    /// The device's own loudspeaker (not headphones on its jack).
    public var isBuiltInSpeaker: Bool
    public init(kind: String, identifier: String, name: String? = nil, isBuiltInSpeaker: Bool = false) {
        self.kind = kind; self.identifier = identifier; self.name = name; self.isBuiltInSpeaker = isBuiltInSpeaker
    }
    var key: String { "\(kind)|\(identifier)" }
    public static func == (a: OutputDevice, b: OutputDevice) -> Bool { a.key == b.key }
}

/// The platform's output device and system (OS) volume.
@MainActor public protocol OutputVolumeSystem: AnyObject {
    var currentDevice: OutputDevice? { get }
    /// 0...1, or nil when the device has no readable volume.
    var systemVolume: Float? { get }
    /// Whether `setSystemVolume` can change the system volume at all.
    var canSetSystemVolume: Bool { get }
    func setSystemVolume(_ value: Float)
    /// Called when the output device or its system volume changes.
    var onChange: (@MainActor () -> Void)? { get set }
}

/// Remembers the app volume and the system volume of each output device, and restores them when
/// the same device plays again, so a device that comes back louder does not play loudly.
///
/// Where the system volume can be set (iPhone), it is set back to the remembered value. Elsewhere
/// (Mac, or when setting fails) the app volume makes up for the difference, so that system × app
/// stays at the remembered loudness. The system volume is never written on the Mac.
///
/// For a short time after the device changes or playback starts, a system volume that jumps up by
/// more than a volume-button step is taken as the OS resetting the device and is undone. Other
/// changes, and every app volume change, are the listener's own and update the record.
@MainActor public final class DeviceVolumeMemory {
    struct Record: Equatable { var app: Float; var system: Float? }
    static let preferenceKey = "deviceVolumes"
    private let playback: PlaybackController
    private let system: any OutputVolumeSystem
    private let preferences: any PreferenceStoring
    private let settleDuration: Duration
    private let now: () -> ContinuousClock.Instant
    private var records: [String: Record]
    private var device: OutputDevice?
    private var settlesUntil: ContinuousClock.Instant?
    private var setAttempts = 0
    private var applying = false
    private var wasPlaying = false

    public init(playback: PlaybackController, system: any OutputVolumeSystem, preferences: any PreferenceStoring = UserDefaults.standard,
                settleDuration: Duration = .seconds(3), now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.playback = playback; self.system = system; self.preferences = preferences
        self.settleDuration = settleDuration; self.now = now
        let stored = preferences.object(forKey: Self.preferenceKey) as? [String: [String: Double]] ?? [:]
        records = stored.compactMapValues { values in
            values["app"].map { Record(app: Float($0), system: values["system"].map(Float.init)) }
        }
        system.onChange = { [weak self] in self?.systemChanged() }
        playback.onVolumeChange = { [weak self] in self?.appVolumeChanged() }
        device = system.currentDevice
        restore()
        observePlayback()
    }

    func record(for device: OutputDevice) -> Record? { records[device.key] }

    private func save() {
        preferences.set(records.mapValues { record -> [String: Double] in
            var values = ["app": Double(record.app)]
            if let system = record.system { values["system"] = Double(system) }
            return values
        }, forKey: Self.preferenceKey)
    }
    private var settling: Bool { settlesUntil.map { now() < $0 } ?? false }

    /// Restores the current device's record, or makes one from the current volumes.
    private func restore() {
        guard let device else { return }
        settlesUntil = now() + settleDuration; setAttempts = 0
        guard records[device.key] != nil else { remember(); return }
        correct()
    }
    /// Brings the volumes back to the record without changing it. The app volume makes up for a
    /// system volume that differs from the record (system × app stays at the remembered loudness);
    /// while this app plays, the system volume is also set back where possible, and the app volume
    /// returns to the record once the system volume has followed.
    private func correct() {
        guard let device, let record = records[device.key] else { return }
        let current = system.systemVolume
        var app = record.app, setsSystem = false
        if let target = record.system, let current, abs(current - target) > 0.005 {
            if current > 0 { app = min(1, record.app * target / current) }
            setsSystem = system.canSetSystemVolume && playback.state == .playing && setAttempts < 3
        }
        // The app volume first: setting the system volume may report the change (and correct again) at once.
        setApp(app)
        if setsSystem, let target = record.system {
            setAttempts += 1
            system.setSystemVolume(target)
        }
    }
    private func remember() {
        guard let device, !playback.isMuted else { return }
        records[device.key] = Record(app: playback.volume, system: system.systemVolume)
        save()
    }
    private func setApp(_ value: Float) {
        guard !playback.isMuted, abs(playback.volume - value) > 0.0001 else { return }
        applying = true; defer { applying = false }
        playback.setVolume(value)
    }

    private func appVolumeChanged() {
        guard !applying, device != nil, !playback.isMuted else { return }
        // The listener's own app volume, set against the system volume heard now. While the OS
        // volume is still being set back, the remembered system volume stays.
        if settling, system.canSetSystemVolume, let device, var record = records[device.key] {
            record.app = playback.volume; records[device.key] = record; save()
        } else { remember() }
    }
    private func systemChanged() {
        let next = system.currentDevice
        if next != device {
            device = next; restore(); return
        }
        if settling, isResetOrSettled { correct() } else { remember() }
    }
    /// A system volume that jumped up by more than a volume-button step is the OS resetting the
    /// device; one that reached the remembered value is the system volume set back. Anything else,
    /// such as pressing a volume button right after starting playback, is the listener's own.
    private var isResetOrSettled: Bool {
        guard let device, let target = records[device.key]?.system, let current = system.systemVolume else { return false }
        return current > target + Self.resetThreshold || abs(current - target) <= 0.005
    }
    static let resetThreshold: Float = 0.1
    /// Starting playback may make the OS reset the device volume; treat that time like a device change.
    private func observePlayback() {
        withObservationTracking { _ = playback.state } onChange: { [weak self] in
            Task { @MainActor in self?.playbackChanged(); self?.observePlayback() }
        }
    }
    private func playbackChanged() {
        let playing = playback.state == .playing
        defer { wasPlaying = playing }
        guard playing, !wasPlaying, device != nil else { return }
        settlesUntil = now() + settleDuration; setAttempts = 0
        correct()
    }
}
