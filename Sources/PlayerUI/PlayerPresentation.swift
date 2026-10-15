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
    public var volumeVisible = false
    public private(set) var extensionVisible = false
    public var section: ExtensionSection = .playlist
    public var selectingFile = false
    public init(seekHideDelay: Duration = .seconds(2)) { self.seekHideDelay = seekHideDelay }
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
