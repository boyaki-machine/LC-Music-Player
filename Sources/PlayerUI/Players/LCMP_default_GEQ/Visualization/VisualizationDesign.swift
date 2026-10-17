import AnalysisCore
import VisualizationKit

/// Visualizations this player UI can show in its animation area. Switching keeps the controls,
/// playback and volume unchanged; only the drawing and its driver change.
public enum VisualizationDesign: String, CaseIterable, Sendable {
    case fluorescentLED
    case ermineChorus

    static let preferenceKey = "visualizationDesign"

    public var title: String {
        switch self {
        case .fluorescentLED: "蛍光管LED"
        case .ermineChorus: "オコジョ合唱団"
        }
    }

    public var summary: String {
        switch self {
        case .fluorescentLED: "16列の周波数レベルを、緑・黄・赤のLEDで表示します。セルごとに点灯し、消灯後は淡い残光が消えていきます。"
        case .ermineChorus: "5匹のオコジョが、低音から高音までの音域を1つずつ受け持って歌います。曲ごとに感度を合わせるので、どの曲でも全員が歌います。"
        }
    }

    /// Both designs read the same 16 bands, so switching never re-subscribes the audio analysis.
    public static var configuration: AnalysisConfiguration { LCMPDefaultGEQ.configuration }
}

/// The lifecycle contract every visualization driver of this player UI follows (see the developer guide).
@MainActor protocol PlayerVisualizationDriver: AnyObject {
    func synchronize(activity: VisualizationActivity, visible: Bool)
    func receive(_ frame: AnalysisFrame)
    func reset()
}

extension VisualizationDriver: PlayerVisualizationDriver {}
