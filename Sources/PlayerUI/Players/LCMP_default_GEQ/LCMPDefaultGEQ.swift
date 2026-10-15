import AnalysisCore
import VisualizationKit

/// Descriptor and analysis adapter owned by this player implementation.
public enum LCMPDefaultGEQ {
    public static let id = "LCMP_default_GEQ"

    public static var name: String { id }
    public static var configuration: AnalysisConfiguration {
        // Constants validated by AnalysisConfiguration; no user-supplied values.
        try! AnalysisConfiguration(bandCount: 16, framesPerSecond: 30, fftSize: 2048)
    }

    static func displayLevels(for frame: AnalysisFrame) -> [Float] {
        frame.bandDBFS.map { LCMPDefaultGEQScale.level(dbFS: $0) }
    }
}

extension SpectrumSample {
    init(defaultGEQFrame frame: AnalysisFrame) {
        self.init(generation: frame.generation, sequence: frame.sequence,
                  levels: LCMPDefaultGEQ.displayLevels(for: frame),
                  producedAt: frame.timing.producedHostTime,
                  presentationAt: frame.timing.estimatedPresentationHostTime)
    }
}
