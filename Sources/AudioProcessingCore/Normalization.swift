import Foundation
import AVFAudio

public enum AudioProcessingFailure: Error, LocalizedError {
    case unsupportedProfile, invalidMeasurement, invalidSettings, storageLimit, outputChanged, missingPlan
    public var errorDescription: String? {
        switch self {
        case .unsupportedProfile: "この音声形式では音量自動調整を利用できません。"
        case .invalidMeasurement: "音量の測定結果を確認できません。"
        case .invalidSettings: "音量自動調整の設定が無効です。"
        case .storageLimit: "音量測定の一時記録の上限に達しました。"
        case .outputChanged: "出力形式が変わりました。再生を準備し直してください。"
        case .missingPlan: "音量測定と補正の準備が必要です。"
        }
    }
}

public struct MeasurementProfile: Equatable, Sendable {
    public let sampleRate: Double
    public let channels: UInt32
    public let version = 1
    public init(sampleRate: Double, channels: UInt32) throws {
        guard [44100.0, 48000, 96000].contains(sampleRate),
              (1...2).contains(channels) else { throw AudioProcessingFailure.unsupportedProfile }
        self.sampleRate = sampleRate; self.channels = channels
    }
    public var format: AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)! }
}

public enum IntegratedLoudness: Equatable, Sendable {
    case measured(Double), silent, tooShort, belowGate
    public var value: Double? { if case .measured(let value) = self { value } else { nil } }
}
public struct AudioLevelMetrics: Equatable, Sendable {
    public let loudness: IntegratedLoudness
    public let samplePeak: Double
    public let truePeak: Double
    public let frameCount: UInt64
    public let blockCount: Int
    public var truePeakDBTP: Double { truePeak == 0 ? -.infinity : 20 * log10(truePeak) }
    public init(loudness: IntegratedLoudness, samplePeak: Double, truePeak: Double, frameCount: UInt64, blockCount: Int) {
        self.loudness = loudness; self.samplePeak = samplePeak; self.truePeak = truePeak
        self.frameCount = frameCount; self.blockCount = blockCount
    }
}
public struct NormalizationSettings: Equatable, Sendable {
    // A reference-loudness starting point, with a product boost cap of 2x.
    // The latter is not a BS.1770 requirement. No physical SPL guarantee.
    public static let standard = try! NormalizationSettings()
    public let targetLUFS: Double
    public let ceilingDBTP: Double
    public let marginDB: Double
    public let maximumBoostDB: Double
    public init(targetLUFS: Double = -23, ceilingDBTP: Double = -1,
                marginDB: Double = 0.5, maximumBoostDB: Double = 6) throws {
        guard targetLUFS.isFinite, (-30 ... -14).contains(targetLUFS),
              ceilingDBTP.isFinite, (-6 ... 0).contains(ceilingDBTP),
              marginDB.isFinite, (0.5 ... 3).contains(marginDB),
              maximumBoostDB.isFinite, (0 ... 12).contains(maximumBoostDB) else {
            throw AudioProcessingFailure.invalidSettings
        }
        self.targetLUFS = targetLUFS; self.ceilingDBTP = ceilingDBTP
        self.marginDB = marginDB; self.maximumBoostDB = maximumBoostDB
    }
}
public enum NormalizationConstraint: String, Sendable {
    case targetReached, peakLimited, boostLimited, noIntegratedLoudness, silent
}
public struct NormalizationPlan: Equatable, Sendable {
    public let profile: MeasurementProfile
    public let settings: NormalizationSettings
    public let gainDB: Double
    public let constraint: NormalizationConstraint
    public var linearGain: Double { pow(10, gainDB / 20) }
    public init(metrics: AudioLevelMetrics, profile: MeasurementProfile,
                settings: NormalizationSettings = .standard) throws {
        guard metrics.frameCount > 0, metrics.samplePeak.isFinite, metrics.samplePeak >= 0,
              metrics.truePeak.isFinite, metrics.truePeak >= metrics.samplePeak else { throw AudioProcessingFailure.invalidMeasurement }
        self.profile = profile; self.settings = settings
        if metrics.truePeak == 0 {
            guard metrics.loudness == .silent else { throw AudioProcessingFailure.invalidMeasurement }
            gainDB = 0; constraint = .silent; return
        }
        let peak = settings.ceilingDBTP - settings.marginDB - metrics.truePeakDBTP
        if let lufs = metrics.loudness.value {
            guard lufs.isFinite else { throw AudioProcessingFailure.invalidMeasurement }
            let wanted = settings.targetLUFS - lufs
            gainDB = min(wanted, peak, settings.maximumBoostDB)
            constraint = gainDB < wanted ? (peak <= settings.maximumBoostDB ? .peakLimited : .boostLimited) : .targetReached
        } else {
            guard metrics.loudness != .silent else { throw AudioProcessingFailure.invalidMeasurement }
            gainDB = min(0, peak); constraint = .noIntegratedLoudness
        }
        guard gainDB.isFinite, (-96 ... 24).contains(gainDB) else { throw AudioProcessingFailure.invalidMeasurement }
    }
}

/// Ordered processing location: observation → [future EQ] → level → [future delay] → manual mixer.
/// Every disabled stage is identity. No fabricated EQ/delay implementation.
@MainActor public final class AudioProcessingChain {
    public let levelNode: AVAudioUnitEQ
    public init(plan: NormalizationPlan?) {
        levelNode = AVAudioUnitEQ(numberOfBands: 0)
        levelNode.globalGain = Float(plan?.gainDB ?? 0)
    }
}
