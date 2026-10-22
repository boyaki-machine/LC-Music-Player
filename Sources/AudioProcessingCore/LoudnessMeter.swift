import Foundation
import Darwin
import LevelDSP

/// Worker-owned bounded meter. The only duration-dependent data is the capped list of block
/// energies, kept in memory: 8 bytes per 100ms, about 48KB for ten minutes and 7MB for a day.
public final class LoudnessMeter {
    private let meter: OpaquePointer
    private let limit: Int
    private var energies: [Double] = []
    private var bytes: Int { energies.count * 8 }
    private var absoluteSum = 0.0
    private var absoluteCount = 0
    private var finished = false
    /// Reused per call; 8 slots exceed lcmp_level_push's bound for an 8192-frame chunk at 32 kHz or above.
    private var blocks = [Double](repeating: 0, count: 8)
    /// Earlier versions spooled the energies to files here.
    public static var temporaryDirectory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("LCMP-level-energy", isDirectory: true) }
    public init(profile: MeasurementProfile, energyByteLimit: Int = 64 * 1024 * 1024) throws {
        guard energyByteLimit >= 8, let meter = lcmp_level_create(profile.sampleRate, profile.channels) else { throw AudioProcessingFailure.unsupportedProfile }
        self.meter = meter; limit = energyByteLimit
    }
    deinit { lcmp_level_destroy(meter) }
    /// Removes spool files an earlier version left behind; a file another process still holds stays.
    public static func cleanAbandonedFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "energy" {
            let handle = Darwin.open(file.path, O_RDWR | O_NOFOLLOW)
            guard handle >= 0 else { continue }
            if flock(handle, LOCK_EX | LOCK_NB) == 0 { unlink(file.path) }
            Darwin.close(handle)
        }
    }
    public func consume(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames: UInt32) throws {
        guard !finished, frames <= 8192 else { throw AudioProcessingFailure.invalidMeasurement }
        let count = lcmp_level_push(meter, left, right, frames, &blocks, UInt32(blocks.count))
        guard count >= 0 else { throw AudioProcessingFailure.invalidMeasurement }
        let length = Int(count) * 8
        guard bytes + length <= limit else { throw AudioProcessingFailure.storageLimit }
        for energy in blocks.prefix(Int(count)) {
            guard energy.isFinite else { throw AudioProcessingFailure.invalidMeasurement }
            if energy > Self.absoluteGate { absoluteSum += energy; absoluteCount += 1 }
        }
        energies.append(contentsOf: blocks.prefix(Int(count)))
    }
    public func finish(checkCancellation: () throws -> Void = {}) throws -> AudioLevelMetrics {
        guard !finished else { throw AudioProcessingFailure.invalidMeasurement }
        finished = true; lcmp_level_flush_peak(meter)
        let peak = lcmp_level_sample_peak(meter), truePeak = lcmp_level_true_peak(meter)
        let frames = lcmp_level_frames(meter)
        guard frames > 0 else { throw AudioProcessingFailure.invalidMeasurement }
        let loudness: IntegratedLoudness
        if peak == 0 { loudness = .silent }
        else if bytes == 0 { loudness = .tooShort }
        else if absoluteCount == 0 { loudness = .belowGate }
        else {
            let threshold = max(Self.absoluteGate, absoluteSum / Double(absoluteCount) / 10)
            var sum = 0.0, count = 0
            for start in stride(from: 0, to: energies.count, by: 1024) {
                try checkCancellation()
                for e in energies[start..<min(start + 1024, energies.count)] where e > threshold { sum += e; count += 1 }
            }
            loudness = count > 0 ? .measured(-0.691 + 10 * log10(sum / Double(count))) : .belowGate
        }
        return AudioLevelMetrics(loudness: loudness, samplePeak: peak, truePeak: truePeak, frameCount: frames, blockCount: bytes / 8)
    }
    private static let absoluteGate = pow(10, (-70 + 0.691) / 10)
}
