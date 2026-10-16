import Foundation
import Observation
import PlaybackCore

public enum ExtensionSection: String, CaseIterable {
    case playlist = "リスト", source = "音源", visualization = "表示", settings = "設定"
}

@Observable @MainActor
public final class PlayerPresentation {
    public var seekVisible = false {
        didSet { if seekVisible { scheduleSeekHide() } else { cancelSeekHide() } }
    }
    @ObservationIgnored private var seekHideTask: Task<Void, Never>?
    private let seekHideDelay: Duration
    public var volumeVisible = false {
        didSet {
            if volumeVisible { scheduleVolumeHide() }
            else { volumeTracking = false; cancelVolumeHide() }
        }
    }
    @ObservationIgnored private var volumeHideTask: Task<Void, Never>?
    private let volumeHideDelay: Duration
    @ObservationIgnored private var volumeTracking = false
    public private(set) var extensionVisible = false
    public var section: ExtensionSection = .playlist
    public var selectingFile = false
    @ObservationIgnored public let visualizationDriver = VisualizationDriver()
    public var visualizationVisible = true {
        didSet {
            // Stop immediately, even if an ordered-out hosting view no longer updates.
            if !visualizationVisible { visualizationDriver.synchronize(activity: .inactive, visible: false) }
        }
    }
    public init(seekHideDelay: Duration = .seconds(2), volumeHideDelay: Duration = .seconds(15)) {
        self.seekHideDelay = seekHideDelay; self.volumeHideDelay = volumeHideDelay
    }
    private func cancelVolumeHide() { volumeHideTask?.cancel(); volumeHideTask = nil }
    public func volumeInteraction() { scheduleVolumeHide() }
    public func trackVolume(_ tracking: Bool) {
        volumeTracking = tracking
        if tracking { cancelVolumeHide() } else { scheduleVolumeHide() }
    }
    private func scheduleVolumeHide() {
        cancelVolumeHide()
        guard volumeVisible, !volumeTracking else { return }
        let delay = volumeHideDelay
        volumeHideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.volumeVisible = false
        }
    }
    public func cancelSeekHide() { seekHideTask?.cancel(); seekHideTask = nil }
    public func scheduleSeekHide() {
        cancelSeekHide()
        guard seekVisible else { return }
        let delay = seekHideDelay
        seekHideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.seekVisible = false
        }
    }
    public func toggleExtension() {
        extensionVisible.toggle()
        if extensionVisible { section = .playlist }
    }
    public func closeOverlays() { volumeVisible = false; seekVisible = false }
}
