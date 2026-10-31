import Foundation

/// The cassette's tape: where it is wound to, which way it runs, and how far the reels and the
/// tape on the path have moved. Coordinates are the 360×144pt design.
///
/// The tape runs at a constant speed, so each reel turns at the speed its own pack allows: 45.5 rpm
/// when nearly empty, 18.9 rpm when full. One side takes ten minutes from end to end; at either end
/// the deck reverses by itself, and every new track reverses it too, keeping the position.
struct RadioCassetteTape: Equatable {
    static let endToEndSeconds = 600.0
    static let fastestRPM = 45.5, slowestRPM = 18.9
    static let hubRadius = 10.5, fullRadius = 29.0
    static let emptyRadius = fullRadius * slowestRPM / fastestRPM
    /// pt/s at the reels' edge.
    static let tapeSpeed = fastestRPM / 60 * 2 * Double.pi * emptyRadius
    /// The dashes on the path run slower than the reels' edge; at full speed they looked hurried.
    static let flowRatio = 0.5
    static let startPosition = 0.35

    /// How far the tape has wound from the left reel onto the right, 0...1.
    private(set) var position = startPosition
    /// Forward runs left to right across the heads.
    private(set) var reverse = false
    /// Reel angles in radians, left and right; forward turns both anticlockwise (negative, y down).
    private(set) var angles = [0.0, 0.0]
    /// How far the dashes on the path have moved, in pt along the path.
    private(set) var flow = 0.0

    /// The packs' radii: the tape's area, not its radius, moves from one reel to the other.
    var radii: [Double] { [Self.radius(filled: 1 - position), Self.radius(filled: position)] }
    var rpm: [Double] { radii.map { Self.tapeSpeed / $0 / (2 * .pi) * 60 } }

    static func radius(filled: Double) -> Double {
        let q = min(1, max(0, filled))
        return (emptyRadius * emptyRadius + (fullRadius * fullRadius - emptyRadius * emptyRadius) * q).squareRoot()
    }

    mutating func advance(seconds dt: Double) {
        guard dt > 0 else { return }
        let direction = reverse ? -1.0 : 1.0
        let radii = radii
        for i in angles.indices {
            angles[i] = (angles[i] - direction * Self.tapeSpeed / radii[i] * dt).truncatingRemainder(dividingBy: 2 * .pi)
        }
        flow = (flow + direction * Self.tapeSpeed * Self.flowRatio * dt).truncatingRemainder(dividingBy: 1000)
        position += direction * dt / Self.endToEndSeconds
        if position >= 1 || position <= 0 {
            position = min(1, max(0, position))
            reverse.toggle()
        }
    }

    /// A new track: the tape stays where it is and runs the other way.
    mutating func nextTrack() { reverse.toggle() }
}
