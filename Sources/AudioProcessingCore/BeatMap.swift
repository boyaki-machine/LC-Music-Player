import Foundation

/// The beats of a whole track, found before playback so that visualizations can move on the beat from
/// the first bar. Times are milliseconds from the start of the track.
public struct BeatMap: Equatable, Sendable {
    public struct Beat: Equatable, Sendable {
        public var milliseconds: UInt32
        /// How clearly this beat stands out, 0...127.
        public var strength: UInt8
        public var isDownbeat: Bool
        public init(milliseconds: UInt32, strength: UInt8, isDownbeat: Bool) {
            self.milliseconds = milliseconds; self.strength = min(strength, 127); self.isDownbeat = isDownbeat
        }
    }
    /// A stretch of the track at one tempo, from `startMilliseconds` to the next segment.
    public struct TempoSegment: Equatable, Sendable {
        public var startMilliseconds: UInt32
        /// Hundredths of a beat per minute.
        public var centiBPM: UInt16
        public var bpm: Double { Double(centiBPM) / 100 }
        public init(startMilliseconds: UInt32, bpm: Double) {
            self.startMilliseconds = startMilliseconds
            centiBPM = UInt16(clamping: Int((bpm * 100).rounded()))
        }
    }
    /// The detector and its version (`BeatDetecting.algorithm`) that made this map.
    public var algorithm: UInt16
    public var durationMilliseconds: UInt32
    /// How clear the beat of the whole track is, 0 (no beat to follow) to 1.
    public var clarity: Double
    public var tempos: [TempoSegment]
    /// In time order.
    public var beats: [Beat]

    public init(algorithm: UInt16, durationMilliseconds: UInt32, clarity: Double,
                tempos: [TempoSegment], beats: [Beat]) {
        self.algorithm = algorithm; self.durationMilliseconds = durationMilliseconds
        // Stored in 1/255 steps.
        self.clarity = (min(1, max(0, clarity.isFinite ? clarity : 0)) * 255).rounded() / 255
        self.tempos = tempos; self.beats = beats
    }

    /// The beat at `seconds` into the track: the index of the last beat at or before it, how far it is
    /// toward the next beat (0..<1) and the seconds between the two. Nil before the first beat and
    /// after the last.
    public func beat(at seconds: Double) -> (index: Int, phase: Double, period: Double)? {
        guard seconds.isFinite, beats.count >= 2 else { return nil }
        let ms = seconds * 1000
        var low = 0, high = beats.count
        while low < high {
            let mid = (low + high) / 2
            if Double(beats[mid].milliseconds) <= ms { low = mid + 1 } else { high = mid }
        }
        let index = low - 1
        guard index >= 0, index + 1 < beats.count else { return nil }
        let start = Double(beats[index].milliseconds), end = Double(beats[index + 1].milliseconds)
        guard end > start else { return nil }
        return (index, (ms - start) / (end - start), (end - start) / 1000)
    }
}

// MARK: - Binary form

/// The map as stored with the track's other maps (`TrackMap`): a small header and lists whose times are differences
/// from the previous entry, as unsigned LEB128 varints. A beat takes about 3 bytes.
extension BeatMap {
    static let magic: [UInt8] = Array("LCBM".utf8)
    static let formatVersion: UInt8 = 1

    public func encoded() -> Data {
        var out = Data(Self.magic)
        out.append(Self.formatVersion)
        out.appendVarint(UInt64(algorithm))
        out.appendVarint(UInt64(durationMilliseconds))
        out.append(UInt8((clarity * 255).rounded()))
        out.appendVarint(UInt64(tempos.count))
        var previous: UInt32 = 0
        for tempo in tempos {
            out.appendVarint(UInt64(tempo.startMilliseconds &- previous)); previous = tempo.startMilliseconds
            out.appendVarint(UInt64(tempo.centiBPM))
        }
        out.appendVarint(UInt64(beats.count))
        previous = 0
        for beat in beats {
            out.appendVarint(UInt64(beat.milliseconds &- previous)); previous = beat.milliseconds
            out.append(beat.strength | (beat.isDownbeat ? 0x80 : 0))
        }
        return out
    }

    /// Rejects anything but a complete, ordered map of this format.
    public init(encoded data: Data) throws {
        var reader = ByteReader(bytes: [UInt8](data))
        guard try reader.bytes(4) == Self.magic, try reader.byte() == Self.formatVersion else { throw AudioProcessingFailure.invalidMeasurement }
        let algorithm = try reader.varint(max: UInt64(UInt16.max))
        let duration = try reader.varint(max: UInt64(UInt32.max))
        let clarity = Double(try reader.byte()) / 255
        var tempos: [TempoSegment] = [], beats: [Beat] = []
        var time: UInt64 = 0
        for _ in 0..<(try reader.count()) {
            time += try reader.varint(max: duration)
            let centi = try reader.varint(max: UInt64(UInt16.max))
            guard time <= duration, centi > 0 else { throw AudioProcessingFailure.invalidMeasurement }
            var tempo = TempoSegment(startMilliseconds: UInt32(time), bpm: 0); tempo.centiBPM = UInt16(centi)
            tempos.append(tempo)
        }
        time = 0
        for index in 0..<(try reader.count()) {
            let delta = try reader.varint(max: duration)
            guard index == 0 || delta > 0 else { throw AudioProcessingFailure.invalidMeasurement }
            time += delta
            let flags = try reader.byte()
            guard time <= duration else { throw AudioProcessingFailure.invalidMeasurement }
            beats.append(Beat(milliseconds: UInt32(time), strength: flags & 0x7f, isDownbeat: flags & 0x80 != 0))
        }
        guard reader.isAtEnd else { throw AudioProcessingFailure.invalidMeasurement }
        self.init(algorithm: UInt16(algorithm), durationMilliseconds: UInt32(duration), clarity: clarity,
                  tempos: tempos, beats: beats)
    }
}

extension Data {
    mutating func appendVarint(_ value: UInt64) {
        var v = value
        repeat {
            let byte = UInt8(v & 0x7f); v >>= 7
            append(v == 0 ? byte : byte | 0x80)
        } while v != 0
    }
}

struct ByteReader {
    let bytes: [UInt8]
    var offset = 0
    var isAtEnd: Bool { offset == bytes.count }
    mutating func byte() throws -> UInt8 {
        guard offset < bytes.count else { throw AudioProcessingFailure.invalidMeasurement }
        defer { offset += 1 }
        return bytes[offset]
    }
    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard bytes.count - offset >= count else { throw AudioProcessingFailure.invalidMeasurement }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }
    mutating func varint(max: UInt64) throws -> UInt64 {
        var value: UInt64 = 0, shift: UInt64 = 0
        while true {
            let b = try byte()
            guard shift < 35 else { throw AudioProcessingFailure.invalidMeasurement }
            value |= UInt64(b & 0x7f) << shift
            if b & 0x80 == 0 { break }
            shift += 7
        }
        guard value <= max else { throw AudioProcessingFailure.invalidMeasurement }
        return value
    }
    /// A list length, bounded by the bytes left so a corrupt count cannot allocate much.
    mutating func count() throws -> Int {
        let n = try varint(max: UInt64(bytes.count - offset))
        return Int(n)
    }
}
