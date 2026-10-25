import Foundation

/// Everything found about a track's music before playback, on one timeline: its beats and its lead vocal.
public struct TrackMap: Equatable, Sendable {
    public var beats: BeatMap
    public var vocals: VocalMap
    public init(beats: BeatMap, vocals: VocalMap) { self.beats = beats; self.vocals = vocals }
}

/// The two maps, each in its own format, after a header and their lengths.
extension TrackMap {
    static let magic: [UInt8] = Array("LCTM".utf8)
    static let formatVersion: UInt8 = 1

    public func encoded() -> Data {
        let b = beats.encoded(), v = vocals.encoded()
        var out = Data(Self.magic)
        out.append(Self.formatVersion)
        out.appendVarint(UInt64(b.count)); out.append(b)
        out.appendVarint(UInt64(v.count)); out.append(v)
        return out
    }

    /// The map in at most `limit` bytes: the vocal map's detail is halved until it fits.
    /// Nil when even the beats alone do not fit.
    public func encoded(fitting limit: Int) -> Data? {
        var map = self
        var data = map.encoded()
        while data.count > limit, map.vocals.frameMilliseconds < 5000 {
            map.vocals = map.vocals.coarser(); data = map.encoded()
        }
        return data.count <= limit ? data : nil
    }

    public init(encoded data: Data) throws {
        var reader = ByteReader(bytes: [UInt8](data))
        guard try reader.bytes(4) == Self.magic, try reader.byte() == Self.formatVersion else { throw AudioProcessingFailure.invalidMeasurement }
        let beats = try BeatMap(encoded: Data(try reader.bytes(try reader.count())))
        let vocals = try VocalMap(encoded: Data(try reader.bytes(try reader.count())))
        guard reader.isAtEnd, beats.durationMilliseconds == vocals.durationMilliseconds else { throw AudioProcessingFailure.invalidMeasurement }
        self.init(beats: beats, vocals: vocals)
    }
}

/// The analyzers that make a track's map, made afresh for each scan. The cache keys both algorithms,
/// so changing either finds the maps again.
public struct TrackAnalyzers: Sendable {
    public var beats: BeatDetector
    public var vocals: VocalAnalyzer
    public init(beats: BeatDetector = .standard, vocals: VocalAnalyzer = .standard) { self.beats = beats; self.vocals = vocals }
    public static let standard = TrackAnalyzers()
    /// Names both algorithms, e.g. "beats-1/vocals-1".
    public var identity: String { "beats-\(beats.algorithm)/vocals-\(vocals.algorithm)" }

    /// A pair of analyzers fed the same PCM. A failure of one leaves the other going; `finish` needs both.
    public func make(sampleRate: Double) throws -> Session {
        Session(beats: try beats(sampleRate: sampleRate), vocals: try vocals(sampleRate: sampleRate))
    }

    public final class Session {
        private var beats: (any BeatDetecting)?
        private var vocals: (any VocalAnalyzing)?
        init(beats: any BeatDetecting, vocals: any VocalAnalyzing) { self.beats = beats; self.vocals = vocals }
        public func consume(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames: Int) {
            do { try beats?.consume(left: left, right: right, frames: frames) } catch { beats = nil }
            do { try vocals?.consume(left: left, right: right, frames: frames) } catch { vocals = nil }
        }
        public func finish() throws -> TrackMap {
            guard let beats, let vocals else { throw AudioProcessingFailure.invalidMeasurement }
            defer { self.beats = nil; self.vocals = nil }
            return TrackMap(beats: try beats.finish(), vocals: try vocals.finish())
        }
    }
}
