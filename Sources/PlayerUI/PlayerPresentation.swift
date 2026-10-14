import Foundation
import Observation
import PlaybackCore

public enum ExtensionSection: String, CaseIterable {
    case playlist = "リスト", source = "音源", visualization = "表示", settings = "設定"
}

@Observable @MainActor
public final class PlayerPresentation {
    public var seekVisible = false
    public var volumeVisible = false
    public private(set) var extensionVisible = false
    public var section: ExtensionSection = .playlist
    public var selectingFile = false
    public init() {}
    public func toggleExtension() {
        extensionVisible.toggle()
        if extensionVisible { section = .playlist }
    }
    public func closeOverlays() { volumeVisible = false; seekVisible = false }
}
