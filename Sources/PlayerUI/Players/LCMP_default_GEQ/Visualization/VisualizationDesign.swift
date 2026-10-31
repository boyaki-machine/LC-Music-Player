import AnalysisCore
import AudioProcessingCore
import VisualizationKit

/// Visualizations this player UI can show in its animation area. Switching keeps the controls,
/// playback and volume unchanged; only the drawing and its driver change.
public enum VisualizationDesign: String, CaseIterable, Sendable {
    case fluorescentLED
    case ermineChorus
    case puppetShow
    case radioCassette

    static let preferenceKey = "visualizationDesign"

    public var title: String {
        switch self {
        case .fluorescentLED: "Last Century イコライザー"
        case .ermineChorus: "MICRIGAIKE コジョーズ"
        case .puppetShow: "教育番組"
        case .radioCassette: "Last Century ラジカセ"
        }
    }

    /// The line under the title on the selection card (up to two lines).
    public var tagline: String {
        switch self {
        case .fluorescentLED: "1990年代の懐かしさをお届け"
        // Break after the comma rather than in the middle of a word.
        case .ermineChorus: "山上の素敵な秘湯では、\n毎晩オコジョ達がステージを開くらしい..."
        case .puppetShow: "思ってたのと違うけど、これはこれで味がある。絵心が欲しい..."
        case .radioCassette: "カセットテープで聞いた、あの頃のワクワクを再び。"
        }
    }

    /// All designs read the same 16 bands, so switching never re-subscribes the audio analysis.
    public static var configuration: AnalysisConfiguration { LCMPDefaultGEQ.configuration }
}

/// The lifecycle contract every visualization driver of this player UI follows (see the developer guide).
@MainActor protocol PlayerVisualizationDriver: AnyObject {
    func synchronize(activity: VisualizationActivity, visible: Bool)
    func receive(_ frame: AnalysisFrame)
    /// The beats and lead vocal of the track being played, when known before playback; nil otherwise.
    func receive(trackMap: TrackMap?)
    func reset()
}

extension PlayerVisualizationDriver {
    /// Designs that do not follow the beat or the vocal ignore the map.
    func receive(trackMap: TrackMap?) {}
}

extension VisualizationDriver: PlayerVisualizationDriver {}
