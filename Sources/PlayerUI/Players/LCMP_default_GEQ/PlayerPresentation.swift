import Foundation
import Observation
import LibraryCore
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
    @ObservationIgnored public let ermineChorusDriver = ErmineChorusDriver()
    public private(set) var visualizationDesign: VisualizationDesign
    @ObservationIgnored private let preferences: any PreferenceStoring
    public var visualizationVisible = true {
        didSet {
            // Stop immediately, even if an ordered-out hosting view no longer updates.
            if !visualizationVisible { stopVisualizations() }
        }
    }
    public init(seekHideDelay: Duration = .seconds(2), volumeHideDelay: Duration = .seconds(15),
                preferences: any PreferenceStoring = UserDefaults.standard) {
        self.seekHideDelay = seekHideDelay; self.volumeHideDelay = volumeHideDelay
        self.preferences = preferences
        visualizationDesign = (preferences.object(forKey: VisualizationDesign.preferenceKey) as? String)
            .flatMap(VisualizationDesign.init(rawValue:)) ?? .fluorescentLED
    }
    var activeVisualizationDriver: any PlayerVisualizationDriver { driver(for: visualizationDesign) }
    /// Views currently showing the visualization. Turning an iPhone replaces the player view, and
    /// the new view can appear before the old one disappears; only the last one to leave stops the drawing.
    @ObservationIgnored private var visualizationHosts = 0
    func visualizationHostAppeared() { visualizationHosts += 1 }
    /// Returns true when no view shows the visualization any more.
    func visualizationHostDisappeared() -> Bool {
        visualizationHosts = max(0, visualizationHosts - 1)
        return visualizationHosts == 0
    }
    private func driver(for design: VisualizationDesign) -> any PlayerVisualizationDriver {
        switch design {
        case .fluorescentLED: visualizationDriver
        case .ermineChorus: ermineChorusDriver
        }
    }
    /// Changes only the drawing. The previous design's clock stops at once; the view starts the new one.
    public func setVisualizationDesign(_ design: VisualizationDesign) {
        guard design != visualizationDesign else { return }
        driver(for: visualizationDesign).synchronize(activity: .inactive, visible: false)
        visualizationDesign = design
        preferences.set(design.rawValue, forKey: VisualizationDesign.preferenceKey)
    }
    private func stopVisualizations() {
        for design in VisualizationDesign.allCases { driver(for: design).synchronize(activity: .inactive, visible: false) }
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
