import CoreGraphics
import SwiftUI

/// The register each ermine sings, by the centre frequency of the analysis bands.
enum ErmineRange: Int, CaseIterable, Sendable {
    case bass, lowMid, mid, highMid, high

    static func of(centerHz: Double) -> ErmineRange {
        switch centerHz {
        case ..<150: .bass
        case ..<500: .lowMid
        case ..<2000: .mid
        case ..<5000: .highMid
        default: .high
        }
    }
}

struct ErminePalette: Sendable {
    var fill: Color, shade: Color
    /// White summer-coat fur on the chin, throat and belly (brown ermines only).
    var belly: Color?, bellyShade: Color?
    var earInside = Color(red: 0.95, green: 0.69, blue: 0.73)
    var ink = ErminePalette.ink
    var nose = Color(red: 0.85, green: 0.53, blue: 0.56)
    var tip = Color(red: 0.17, green: 0.15, blue: 0.13), tipHighlight = Color(red: 0.35, green: 0.32, blue: 0.29)
    var eye = Color(red: 0.11, green: 0.09, blue: 0.08)
    var blush = Color(red: 0.94, green: 0.55, blue: 0.61)
    var line: CGFloat = 2

    static let ink = Color(red: 0.165, green: 0.137, blue: 0.125)
    private static let white = Color(red: 1, green: 0.992, blue: 0.973), whiteShade = Color(red: 0.902, green: 0.863, blue: 0.804)
    static let snow = ErminePalette(fill: white, shade: Color(red: 0.839, green: 0.847, blue: 0.902))
    static let cream = ErminePalette(fill: Color(red: 1, green: 0.973, blue: 0.933), shade: Color(red: 0.914, green: 0.859, blue: 0.878),
                                     earInside: Color(red: 0.96, green: 0.66, blue: 0.71))
    static let light = ErminePalette(fill: Color(red: 0.851, green: 0.663, blue: 0.435), shade: Color(red: 0.722, green: 0.518, blue: 0.298),
                                     belly: white, bellyShade: whiteShade)
    static let brown = ErminePalette(fill: Color(red: 0.698, green: 0.482, blue: 0.271), shade: Color(red: 0.549, green: 0.357, blue: 0.188),
                                     belly: white, bellyShade: whiteShade)
    static let dark = ErminePalette(fill: Color(red: 0.576, green: 0.376, blue: 0.184), shade: Color(red: 0.431, green: 0.267, blue: 0.125),
                                    belly: white, bellyShade: whiteShade)
}

struct ErmineFeatures: Sendable {
    var sparkle = false, glasses = false, lashes = false, flower = false, thickBrows = false
    /// −1 draws the tail on the left (the rightmost ermine keeps it inside the stage).
    var tailSide: CGFloat = 1
}

/// One ermine: look, register and personality. Edit these numbers to tune the design.
struct ErmineCastMember: Sendable {
    let id: Int
    let slot: Int
    let palette: ErminePalette
    let scale: CGSize
    let features: ErmineFeatures
    let range: ErmineRange
    /// Chance of open, smiling (closed) and dreamy (half-closed) eyes while singing.
    let expressions: (open: Double, happy: Double, dreamy: Double)
}

enum ErmineCast {
    /// Left to right from low to high like a keyboard: 5, 3, 1, 4, 2.
    /// Ermine 4 stands next to 1 to look after him; 3 peeks at 4 over 1.
    static let members: [ErmineCastMember] = [
        ErmineCastMember(id: 2, slot: 4, palette: .light, scale: CGSize(width: 0.97, height: 0.98), features: ErmineFeatures(sparkle: true, tailSide: -1),
                         range: .high, expressions: (0.4, 0.5, 0.1)),
        ErmineCastMember(id: 3, slot: 1, palette: .brown, scale: CGSize(width: 1, height: 1), features: ErmineFeatures(glasses: true),
                         range: .lowMid, expressions: (0.7, 0.1, 0.2)),
        ErmineCastMember(id: 1, slot: 2, palette: .snow, scale: CGSize(width: 1, height: 1), features: ErmineFeatures(),
                         range: .mid, expressions: (0.5, 0.3, 0.2)),
        ErmineCastMember(id: 4, slot: 3, palette: .cream, scale: CGSize(width: 0.94, height: 0.94), features: ErmineFeatures(lashes: true, flower: true),
                         range: .highMid, expressions: (0.3, 0.35, 0.35)),
        ErmineCastMember(id: 5, slot: 0, palette: .dark, scale: CGSize(width: 1.1, height: 1.03), features: ErmineFeatures(thickBrows: true),
                         range: .bass, expressions: (0.4, 0.6, 0)),
    ]
    /// Stage layout in points of the 360×144 animation area.
    static let slotX: [CGFloat] = [60, 120, 180, 240, 300]
    static let feetY: CGFloat = 120
    static let stageScale: CGFloat = 0.8
}

// MARK: - Face and effect cels

enum ErmineEye: Sendable, Equatable {
    case open, surprise, half, closed, happy, squeeze
    /// One eye closed in a smile, on the side of the pointing hand.
    case wink(side: CGFloat)
}
enum ErmineMouth: Sendable, Equatable { case closed, small, medium, large, round }

struct ErmineFace: Sendable, Equatable {
    var eye = ErmineEye.open
    var mouth = ErmineMouth.closed
    var troubledBrows = false
    var glint = false
    var blush = 1
    /// Which of the three sweat drawings to show, or nil.
    var sweat: Int?
}

struct ErmineNote: Sendable, Equatable {
    var position: CGPoint
    var glyph: String
    var size: CGFloat
}

struct ErmineEffects: Sendable, Equatable {
    /// Alternating vibration marks, or nil.
    var shake: Int?
    var notes: [ErmineNote] = []
}

/// The stage around the ermines: floor lamps follow the bass and turn to a soloist,
/// lamps hung from the beam follow the voice, and letters of the neon sign flicker on high notes.
struct ErmineStage: Sendable, Equatable {
    /// 0…1 brightness of the floor lamps' beams.
    var light: Double = 0
    /// 0…1 brightness of the lamps hung from the beam.
    var topLight: Double = 0
    /// The slot the lamps point at during a solo, or nil for the usual crossed beams.
    var spotSlot: Int?
    /// Brightness of each letter of the neon sign (1 = steady).
    var neon: [Double] = Array(repeating: 1, count: ErmineStage.neonText.count)
    static let neonText = Array("MICRIGAIKE KOJOES")
}

/// What the director decided for one ermine: the key to show and the cels laid over it.
struct ErmineFrame: Sendable {
    var key = ErmineKeyName.idleA
    var face = ErmineFace()
    var effects = ErmineEffects()
    /// Tail wag (−1, 0, 1) drawn as a separate tail cel.
    var wag: CGFloat = 0
    /// The arm pose held for the current phrase.
    var arms = ErmineArms()
}

/// One ermine ready to draw: the (possibly in-between) body pose plus the cels.
struct ErmineDrawing: Sendable {
    var pose: ErmineKey
    var frame: ErmineFrame
}

// MARK: - Band levels with per-song sensitivity

/// Turns 16 analysis bands into one singing level per register. Each register follows its own
/// recent peak (instant attack, slow release), so quiet registers in a song still make their ermine sing.
struct ErmineBandLevels: Sendable {
    static let floorDB = -60.0, spanDB = 30.0, releaseDBPerSecond = 1.5, silentDB = -80.0
    private(set) var peaks = Array(repeating: ErmineBandLevels.floorDB, count: ErmineRange.allCases.count)

    mutating func reset() { peaks = Array(repeating: Self.floorDB, count: ErmineRange.allCases.count) }

    /// Power-averages the bands of each register. Returns nil for malformed input.
    static func registerDB(bandDBFS: [Float], edgesHz: [Double]) -> [Double]? {
        guard edgesHz.count == bandDBFS.count + 1, !bandDBFS.isEmpty, bandDBFS.allSatisfy(\.isFinite) else { return nil }
        var power = Array(repeating: 0.0, count: ErmineRange.allCases.count), count = power
        for (i, db) in bandDBFS.enumerated() {
            let center = (edgesHz[i] * edgesHz[i + 1]).squareRoot()
            let r = ErmineRange.of(centerHz: center).rawValue
            power[r] += pow(10, Double(db) / 10); count[r] += 1
        }
        return zip(power, count).map { $1 > 0 ? 10 * log10(max($0 / $1, 1e-12)) : -100 }
    }

    mutating func levels(bandDBFS: [Float], edgesHz: [Double], dt: Double) -> [Double]? {
        guard let db = Self.registerDB(bandDBFS: bandDBFS, edgesHz: edgesHz) else { return nil }
        return db.enumerated().map { r, value in
            peaks[r] = max(Self.floorDB, max(value, peaks[r] - Self.releaseDBPerSecond * max(0, dt)))
            guard value > Self.silentDB else { return 0 }
            return min(1, max(0, (value - (peaks[r] - Self.spanDB)) / Self.spanDB))
        }
    }
}
