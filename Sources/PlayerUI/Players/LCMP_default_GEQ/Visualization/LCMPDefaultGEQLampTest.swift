import Foundation

/// The lamp test of the LED: a pattern sweeps across all 16 columns, one column every `step`, so every
/// cell and color is seen lit by itself rather than only as the bottom of a bar. One pass, then the
/// ordinary display returns.
enum LCMPDefaultGEQLampTest {
    static let step = 0.1
    /// Each dot of the pattern is three rows high with one unlit row above it.
    static let baseRow = 2
    static let rowPitch = 4
    static let dotRows = 3

    /// The pattern's columns, five dots each (bit 0 at the bottom), whitened so that the table is not
    /// mistaken for data of the spectrum.
    private static let table: [UInt8] = [
        0x6C, 0x7B, 0xF4, 0xCE, 0x4F, 0xED, 0x4A, 0x48, 0xD8, 0xF3, 0x9E, 0xC6, 0xCF, 0x04, 0x67, 0xBC, 0xD6,
        0x45, 0xE3, 0xCA, 0x40, 0x29, 0x3F, 0x92, 0xEF, 0xDE, 0xFC, 0xBD, 0xFE, 0x34, 0x1C, 0x8A, 0x9A, 0xCF,
        0xE4, 0x85, 0x98, 0x79, 0xE9, 0x41, 0x21, 0xA7, 0x92, 0x8D, 0x1B, 0x99, 0xAC, 0xE8, 0x33, 0xDF, 0x4D,
        0xD7, 0xB0, 0x8D, 0x72, 0x97, 0x7F, 0x25, 0x8B, 0x31, 0xDB, 0xD8, 0x55, 0xDE, 0x30, 0x51,
    ]
    static let columns: [UInt8] = {
        var state: UInt32 = 0x2545_F491
        return table.map { byte in
            state = state &* 1_103_515_245 &+ 12345
            return byte ^ UInt8(truncatingIfNeeded: state >> 16)
        }
    }()
    /// From the first column entering at the right edge until the last one has left at the left.
    static var duration: Double { Double(SpectrumSnapshot.columns + columns.count) * step }

    /// The lit rows of each LED column, `elapsed` seconds after the start; nil once the pass is over.
    static func pattern(at elapsed: Double) -> [UInt32]? {
        guard elapsed.isFinite, elapsed >= 0, elapsed < duration else { return nil }
        let offset = Int(elapsed / step) - SpectrumSnapshot.columns
        return (0..<SpectrumSnapshot.columns).map { column in
            let source = column + offset
            guard columns.indices.contains(source) else { return 0 }
            return rows(columns[source])
        }
    }

    static func rows(_ dots: UInt8) -> UInt32 {
        var mask: UInt32 = 0
        for dot in 0..<5 where dots >> dot & 1 == 1 {
            mask |= ((1 << dotRows) - 1) << UInt32(baseRow + dot * rowPitch)
        }
        return mask
    }
}

/// Which LED button of the player was pressed.
enum LCMPDefaultGEQControl: Int, CaseIterable {
    case previous, playPause, next, stop, volume, menu
}

/// Starts the lamp test from the buttons, a service sequence rather than a setting, as on old equipment.
/// Pauses longer than `timeout` start over.
struct LCMPDefaultGEQServiceSequence {
    static let timeout = 5.0
    /// Three bits per press, ending with 7.
    private static let code: UInt64 = 0x4_32AD_E034 ^ 0x5_DEEC_E66D
    private var position = 0
    private var last: Double?

    static func expected(_ position: Int) -> Int { Int(code >> UInt64(3 * position) & 7) }

    /// True when this press completes the sequence.
    mutating func press(_ control: LCMPDefaultGEQControl, now: Double) -> Bool {
        if let last, !(now - last <= Self.timeout) { position = 0 }
        last = now
        if control.rawValue == Self.expected(position) { position += 1 }
        else { position = control.rawValue == Self.expected(0) ? 1 : 0 }
        guard Self.expected(position) == 7 else { return false }
        reset()
        return true
    }

    mutating func reset() { position = 0; last = nil }
}
