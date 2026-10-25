import Foundation

/// What the lead vocal of a whole track does over time, found before playback so that a character can
/// sing along with it: how wide the mouth opens, the sung note, and stretches such as long tones,
/// high notes, shouts and harmonies. Times are milliseconds from the start of the track.
public struct VocalMap: Equatable, Sendable {
    /// Which register the lead vocal mostly sings in, judged from its median note.
    public enum Register: UInt8, Sendable { case unknown = 0, low = 1, high = 2 }

    public struct Event: Equatable, Sendable {
        public enum Kind: UInt8, Sendable {
            /// The lead vocal sings: a phrase between breaths.
            case phrase = 1
            case longTone = 2
            /// Notes well above the lead vocal's usual range.
            case highTone = 3
            case shout = 4
            /// A second voice at a consonant interval, such as a backing chorus.
            case harmony = 5
        }
        public var kind: Kind
        public var startMilliseconds: UInt32
        public var durationMilliseconds: UInt32
        /// 0...127.
        public var strength: UInt8
        public var endMilliseconds: UInt32 { startMilliseconds + durationMilliseconds }
        public init(kind: Kind, startMilliseconds: UInt32, durationMilliseconds: UInt32, strength: UInt8) {
            self.kind = kind; self.startMilliseconds = startMilliseconds
            self.durationMilliseconds = durationMilliseconds; self.strength = min(strength, 127)
        }
    }

    /// The analyzer and its version (`VocalAnalyzing.algorithm`) that made this map.
    public var algorithm: UInt16
    public var durationMilliseconds: UInt32
    public var register: Register
    /// The lead vocal's median note (MIDI number), 0 when it never sings.
    public var medianNote: UInt8
    /// Milliseconds between entries of `mouth`; `notes` has one entry for every two.
    public var frameMilliseconds: UInt16
    /// How wide a mouth singing along opens, 0 (closed) to 15.
    public var mouth: [UInt8]
    /// The sung note (MIDI number), 0 where nothing is sung.
    public var notes: [UInt8]
    /// In order of their start.
    public var events: [Event]

    public init(algorithm: UInt16, durationMilliseconds: UInt32, register: Register, medianNote: UInt8,
                frameMilliseconds: UInt16, mouth: [UInt8], notes: [UInt8], events: [Event]) {
        self.algorithm = algorithm; self.durationMilliseconds = durationMilliseconds
        self.register = register; self.medianNote = medianNote
        self.frameMilliseconds = max(1, frameMilliseconds)
        self.mouth = mouth.map { min($0, 15) }; self.notes = notes; self.events = events
    }

    /// The mouth at `seconds`, 0...1, between the two nearest entries.
    public func mouth(at seconds: Double) -> Double {
        let position = seconds * 1000 / Double(frameMilliseconds)
        guard position.isFinite, position >= 0, !mouth.isEmpty else { return 0 }
        let i = Int(position), f = position - Double(i)
        guard i < mouth.count else { return 0 }
        let next = i + 1 < mouth.count ? Double(mouth[i + 1]) : 0
        return (Double(mouth[i]) * (1 - f) + next * f) / 15
    }

    /// The sung note at `seconds`, or nil where nothing is sung.
    public func note(at seconds: Double) -> UInt8? {
        let position = seconds * 1000 / Double(2 * Int(frameMilliseconds))
        guard position.isFinite, position >= 0, Int(position) < notes.count else { return nil }
        let note = notes[Int(position)]
        return note == 0 ? nil : note
    }

    /// The events under way at `seconds`.
    public func events(at seconds: Double) -> [Event] {
        let ms = seconds * 1000
        return events.filter { Double($0.startMilliseconds) <= ms && ms < Double($0.endMilliseconds) }
    }

    /// The same map with half as many entries, for tracks too long to store at full detail.
    func coarser() -> VocalMap {
        let halfMouth = stride(from: 0, to: mouth.count, by: 2).map { max(mouth[$0], $0 + 1 < mouth.count ? mouth[$0 + 1] : 0) }
        let halfNotes = stride(from: 0, to: notes.count, by: 2).map { notes[$0] != 0 ? notes[$0] : ($0 + 1 < notes.count ? notes[$0 + 1] : 0) }
        return VocalMap(algorithm: algorithm, durationMilliseconds: durationMilliseconds, register: register, medianNote: medianNote,
                        frameMilliseconds: frameMilliseconds * 2, mouth: halfMouth, notes: halfNotes, events: events)
    }
}

// MARK: - Binary form

/// A header, the mouth packed two entries to a byte, the notes one to a byte, and the events with
/// their times as differences, in unsigned LEB128 varints. Ten minutes take about 15KB.
extension VocalMap {
    static let magic: [UInt8] = Array("LCVM".utf8)
    static let formatVersion: UInt8 = 1

    public func encoded() -> Data {
        var out = Data(Self.magic)
        out.append(Self.formatVersion)
        out.appendVarint(UInt64(algorithm))
        out.appendVarint(UInt64(durationMilliseconds))
        out.append(register.rawValue)
        out.append(medianNote)
        out.appendVarint(UInt64(frameMilliseconds))
        out.appendVarint(UInt64(mouth.count))
        for i in stride(from: 0, to: mouth.count, by: 2) {
            out.append(mouth[i] | (i + 1 < mouth.count ? mouth[i + 1] << 4 : 0))
        }
        out.appendVarint(UInt64(notes.count))
        out.append(contentsOf: notes)
        out.appendVarint(UInt64(events.count))
        var previous: UInt32 = 0
        for event in events {
            out.append(event.kind.rawValue)
            out.appendVarint(UInt64(event.startMilliseconds &- previous)); previous = event.startMilliseconds
            out.appendVarint(UInt64(event.durationMilliseconds))
            out.append(event.strength)
        }
        return out
    }

    /// Rejects anything but a complete, ordered map of this format.
    public init(encoded data: Data) throws {
        var reader = ByteReader(bytes: [UInt8](data))
        guard try reader.bytes(4) == Self.magic, try reader.byte() == Self.formatVersion else { throw AudioProcessingFailure.invalidMeasurement }
        let algorithm = try reader.varint(max: UInt64(UInt16.max))
        let duration = try reader.varint(max: UInt64(UInt32.max))
        guard let register = Register(rawValue: try reader.byte()) else { throw AudioProcessingFailure.invalidMeasurement }
        let median = try reader.byte()
        let frame = try reader.varint(max: UInt64(UInt16.max))
        guard frame > 0 else { throw AudioProcessingFailure.invalidMeasurement }
        // A map covers the track and a little more, never much more.
        let maxFrames = duration / frame + 2
        let mouthCount = Int(try reader.varint(max: maxFrames))
        let packed = try reader.bytes((mouthCount + 1) / 2)
        var mouth: [UInt8] = []
        mouth.reserveCapacity(mouthCount)
        for i in 0..<mouthCount { mouth.append(i % 2 == 0 ? packed[i / 2] & 0x0f : packed[i / 2] >> 4) }
        if mouthCount % 2 == 1, packed.last! >> 4 != 0 { throw AudioProcessingFailure.invalidMeasurement }
        let notes = try reader.bytes(Int(try reader.varint(max: maxFrames / 2 + 1)))
        guard notes.allSatisfy({ $0 <= 127 }) else { throw AudioProcessingFailure.invalidMeasurement }
        var events: [Event] = []
        var time: UInt64 = 0
        for _ in 0..<(try reader.count()) {
            guard let kind = Event.Kind(rawValue: try reader.byte()) else { throw AudioProcessingFailure.invalidMeasurement }
            time += try reader.varint(max: duration)
            let length = try reader.varint(max: duration)
            let strength = try reader.byte()
            guard time + length <= duration, strength <= 127 else { throw AudioProcessingFailure.invalidMeasurement }
            events.append(Event(kind: kind, startMilliseconds: UInt32(time), durationMilliseconds: UInt32(length), strength: strength))
        }
        guard reader.isAtEnd, median <= 127 else { throw AudioProcessingFailure.invalidMeasurement }
        self.init(algorithm: UInt16(algorithm), durationMilliseconds: UInt32(duration), register: register, medianNote: median,
                  frameMilliseconds: UInt16(frame), mouth: mouth, notes: notes, events: events)
    }
}
