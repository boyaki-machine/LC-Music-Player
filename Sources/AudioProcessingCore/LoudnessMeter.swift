import Foundation
import Darwin
import LevelDSP

/// Worker-owned bounded meter. The only duration-dependent data is a capped energy spool.
public final class LoudnessMeter {
    private let meter: OpaquePointer
    private let fd: Int32
    private let url: URL
    private let limit: Int
    private var bytes = 0
    private var absoluteSum = 0.0
    private var absoluteCount = 0
    private var finished = false
    /// Reused per call; 8 slots exceed lcmp_level_push's bound for an 8192-frame chunk at 32 kHz or above.
    private var blocks = [Double](repeating: 0, count: 8)
    public static var temporaryDirectory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("LCMP-level-energy", isDirectory: true) }
    public init(profile: MeasurementProfile, energyByteLimit: Int = 64 * 1024 * 1024) throws {
        guard energyByteLimit >= 8, let meter = lcmp_level_create(profile.sampleRate, profile.channels) else { throw AudioProcessingFailure.unsupportedProfile }
        self.meter = meter; limit = energyByteLimit
        let directory = Self.temporaryDirectory
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { lcmp_level_destroy(meter); throw error }
        url = directory.appendingPathComponent(UUID().uuidString + ".energy")
        fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { lcmp_level_destroy(meter); throw CocoaError(.fileWriteUnknown) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); unlink(url.path); lcmp_level_destroy(meter); throw CocoaError(.fileWriteUnknown)
        }
    }
    deinit { Darwin.close(fd); unlink(url.path); lcmp_level_destroy(meter) }
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
        try blocks.withUnsafeBytes { raw in
            var offset = 0
            while offset < length {
                let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), length - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += written
            }
        }
        bytes += length
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
            guard lseek(fd, 0, SEEK_SET) == 0 else { throw CocoaError(.fileReadUnknown) }
            var buffer = [Double](repeating: 0, count: 1024), sum = 0.0, count = 0
            while true {
                try checkCancellation()
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
                if n < 0, errno == EINTR { continue }
                guard n >= 0, n % 8 == 0 else { throw CocoaError(.fileReadUnknown) }
                if n == 0 { break }
                for e in buffer.prefix(n / 8) where e > threshold { sum += e; count += 1 }
            }
            loudness = count > 0 ? .measured(-0.691 + 10 * log10(sum / Double(count))) : .belowGate
        }
        return AudioLevelMetrics(loudness: loudness, samplePeak: peak, truePeak: truePeak, frameCount: frames, blockCount: bytes / 8)
    }
    private static let absoluteGate = pow(10, (-70 + 0.691) / 10)
}
