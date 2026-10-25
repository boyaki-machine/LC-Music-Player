import AudioProcessingCore
import Foundation

/// What the lead vocal does at one moment, read from the track's vocal map.
struct PuppetVocal: Sendable, Equatable {
    /// How wide a mouth singing along opens, 0…1, read slightly ahead as lips move before the sound.
    var mouth = 0.0
    /// Within a sung phrase.
    var singing = false
    /// The note against the vocal's median, in octaves: positive when singing high.
    var pitch = 0.0
    var longTone = false, highTone = false, shout = false, harmony = false
}

/// The part a puppet takes in a section of a song with a vocal.
enum PuppetVocalPart: Sendable, Equatable, CaseIterable {
    /// Sings the vocal's syllables and acts out its long tones, high tones and shouts.
    case lead
    /// Sings along quietly, and fully while a second voice harmonizes.
    case sub
    /// Sings on the beat with its register's strength.
    case beat
    /// Hums on the beat, quietly.
    case hum
}

/// Who takes which part. Each song has one lead, picked at random (seeded by the song, so a song plays
/// the same way again). The song is cut into sections where the vocal pauses for a while or every few
/// phrases, and each section deals the other three parts out among the other three puppets. The register
/// each puppet follows moves with its part, so the lead always follows the band of the voice.
struct PuppetCasting: Sendable, Equatable {
    /// A pause in the vocal at least this long starts a new section.
    static let sectionGap = 1.5
    static let phrasesPerSection = 4

    struct Section: Sendable, Equatable {
        var start: Double
        /// The part of each puppet, in the order of `PuppetMember.all`.
        var parts: [PuppetVocalPart]
    }
    let sections: [Section]
    let phrases: [(start: Double, end: Double)]
    /// The register of the voice: the low or the high middle band.
    let voiceRegister: PuppetRegister

    static func == (a: Self, b: Self) -> Bool {
        a.sections == b.sections && a.voiceRegister == b.voiceRegister
            && a.phrases.count == b.phrases.count && zip(a.phrases, b.phrases).allSatisfy { $0 == $1 }
    }

    init(vocals: VocalMap) {
        voiceRegister = vocals.register == .high ? .highMid : .lowMid
        phrases = vocals.events.filter { $0.kind == .phrase }.map { (Double($0.startMilliseconds) / 1000, Double($0.endMilliseconds) / 1000) }
        var random = PuppetRandom(seed: vocals.durationMilliseconds &+ UInt32(vocals.medianNote) &* 7919 &+ UInt32(phrases.count))
        var sections: [Section] = []
        let count = PuppetMember.all.count
        let lead = min(count - 1, Int(random.next() * Double(count)))
        var inSection = 0, previousEnd = -Double.infinity
        for phrase in phrases {
            if sections.isEmpty || phrase.start - previousEnd >= Self.sectionGap || inSection >= Self.phrasesPerSection {
                var rest = Array(PuppetMember.all.indices).filter { $0 != lead }
                var parts = Array(repeating: PuppetVocalPart.hum, count: PuppetMember.all.count)
                parts[lead] = .lead
                for part in [PuppetVocalPart.sub, .beat] {
                    let pick = rest.remove(at: min(rest.count - 1, Int(random.next() * Double(rest.count))))
                    parts[pick] = part
                }
                sections.append(Section(start: sections.isEmpty ? 0 : phrase.start, parts: parts))
                inSection = 0
            }
            inSection += 1; previousEnd = phrase.end
        }
        self.sections = sections
    }

    func section(at seconds: Double) -> Section? { sections.last { $0.start <= seconds } ?? sections.first }

    func part(of member: Int, at seconds: Double) -> PuppetVocalPart { section(at: seconds)?.parts[member] ?? .beat }

    /// The register a part follows: the lead the voice's band, the sub the other middle band,
    /// the beat the bass and the hum the highs.
    func register(for part: PuppetVocalPart) -> PuppetRegister {
        switch part {
        case .lead: voiceRegister
        case .sub: voiceRegister == .lowMid ? .highMid : .lowMid
        case .beat: .bass
        case .hum: .high
        }
    }
}

extension VocalMap {
    /// The lead vocal at `seconds` into the track; the mouth is read `lead` seconds ahead.
    func puppetVocal(at seconds: Double, lead: Double = 0.06) -> PuppetVocal {
        let now = events(at: seconds)
        var v = PuppetVocal()
        v.singing = now.contains { $0.kind == .phrase }
        guard v.singing else { return v }
        v.mouth = mouth(at: seconds + lead)
        if let note = note(at: seconds), medianNote > 0 { v.pitch = (Double(note) - Double(medianNote)) / 12 }
        v.longTone = now.contains { $0.kind == .longTone }
        v.highTone = now.contains { $0.kind == .highTone }
        v.shout = now.contains { $0.kind == .shout }
        v.harmony = now.contains { $0.kind == .harmony }
        return v
    }
}
