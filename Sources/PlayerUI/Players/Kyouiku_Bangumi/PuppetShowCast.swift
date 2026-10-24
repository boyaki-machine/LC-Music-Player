import Foundation

enum PuppetEyeKind: Sendable { case led, flame, wave, sakura }

/// How a puppet's eyes light up. `core` covers the pupil, `glow` is the light around it.
struct PuppetEyeStyle: Sendable {
    let core: (Double, Double, Double), glow: (Double, Double, Double)
    let kind: PuppetEyeKind
    /// Calm colors: the core's center is not made white, and the light is kept dim.
    var dim = false
}

/// The four puppets, from left to right, with the register each one sings and its character.
struct PuppetMember: Sendable {
    let name: String
    let label: String
    let register: PuppetRegister
    let seed: UInt32
    /// The center on the 360pt stage.
    let x: Double
    let eyes: PuppetEyeStyle

    static let all: [PuppetMember] = [
        // Highs. Caring and shy.
        PuppetMember(name: "twin", label: "ツインテール", register: .high, seed: 11, x: 50,
                     eyes: PuppetEyeStyle(core: (46, 84, 140), glow: (40, 78, 135), kind: .wave, dim: true)),
        // Bass. A cheerful favorite who headbangs.
        PuppetMember(name: "spiky", label: "ツンツン髪", register: .bass, seed: 23, x: 136,
                     eyes: PuppetEyeStyle(core: (255, 120, 40), glow: (255, 70, 20), kind: .flame)),
        // Low mids (the song). The green of the Last Century equalizer.
        PuppetMember(name: "glasses", label: "メガネくん", register: .lowMid, seed: 65, x: 224,
                     eyes: PuppetEyeStyle(core: (102, 255, 121), glow: (102, 255, 121), kind: .led)),
        // High mids (the song). Has a crush on the boy with glasses.
        PuppetMember(name: "pony", label: "ポニーテール", register: .highMid, seed: 37, x: 310,
                     eyes: PuppetEyeStyle(core: (168, 104, 124), glow: (150, 80, 108), kind: .sakura, dim: true)),
    ]

    static func index(_ name: String) -> Int { all.firstIndex { $0.name == name }! }

    /// The skin, adjusted from the color measured on the art: the twin-tailed girl is fairer, the spiky-haired boy tanned.
    static func skin(_ name: String, measured c: [Double]) -> [Double] {
        switch name {
        case "twin": c.map { $0 + (1 - $0) * 0.22 }
        case "spiky": [c[0] * 0.9, c[1] * 0.8, c[2] * 0.72]
        default: c
        }
    }
}

enum PuppetRegister: Int, CaseIterable, Sendable {
    case bass, lowMid, highMid, high
    static func of(centerHz: Double) -> PuppetRegister {
        switch centerHz {
        case ..<250: .bass
        case ..<1000: .lowMid
        case ..<4000: .highMid
        default: .high
        }
    }
}

/// The level of each register, following the loudest recent value so quiet music still moves everyone:
/// the peak rises at once and falls 1.5dB a second; 30dB below it is 0 and the peak is 1.
struct PuppetRegisterLevels: Sendable {
    static let floorDB = -60.0, spanDB = 30.0, releaseDBPerSecond = 1.5, silentDB = -80.0
    private(set) var peaks = Array(repeating: PuppetRegisterLevels.floorDB, count: PuppetRegister.allCases.count)

    mutating func reset() { peaks = Array(repeating: Self.floorDB, count: PuppetRegister.allCases.count) }

    /// Power-averages the analysis bands of each register. Returns nil for malformed input.
    static func registerDB(bandDBFS: [Float], edgesHz: [Double]) -> [Double]? {
        guard edgesHz.count == bandDBFS.count + 1, !bandDBFS.isEmpty, bandDBFS.allSatisfy(\.isFinite) else { return nil }
        var power = Array(repeating: 0.0, count: PuppetRegister.allCases.count), count = power
        for (i, db) in bandDBFS.enumerated() {
            let r = PuppetRegister.of(centerHz: (edgesHz[i] * edgesHz[i + 1]).squareRoot()).rawValue
            power[r] += pow(10, Double(db) / 10); count[r] += 1
        }
        return zip(power, count).map { $1 > 0 ? 10 * log10(max($0 / $1, 1e-12)) : -100 }
    }

    mutating func levels(registerDB db: [Double], dt: Double) -> [Double] {
        db.enumerated().map { r, value in
            peaks[r] = max(Self.floorDB, max(value, peaks[r] - Self.releaseDBPerSecond * max(0, dt)))
            guard value > Self.silentDB else { return 0 }
            return min(1, max(0, (value - (peaks[r] - Self.spanDB)) / Self.spanDB))
        }
    }
}
