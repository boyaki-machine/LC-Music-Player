import CoreGraphics

/// One authored body drawing (a key, or "genga"). Units: feet at (0, 0), up is negative y.
/// Keys are written by hand as numbers; the display only fills eased in-betweens between them.
struct ErmineKey: Equatable, Sendable {
    var hipW: CGFloat = 15, waistW: CGFloat = 10.5
    var neck = CGPoint(x: 0, y: -60), neckW: CGFloat = 7.5
    var head = CGPoint(x: 0, y: -75), rot: CGFloat = 0, headScale = CGSize(width: 1, height: 1)
    /// End points of the front legs.
    var pawL = CGPoint(x: -7, y: -36), pawR = CGPoint(x: 7, y: -36)
    /// Cubic Bézier control points of the tail.
    var tail = [CGPoint(x: 12, y: -6), CGPoint(x: 27, y: -4), CGPoint(x: 34, y: -20), CGPoint(x: 29, y: -37)]
    /// Eye direction, −1 (left) to 1 (right).
    var look: CGFloat = 0
    /// Torso rotation. Positive faces the viewer's right, so that side recedes and narrows.
    var turn: CGFloat = 0
    var shoulderL: CGFloat = 0, shoulderR: CGFloat = 0
    /// Outward bend of each front leg (an elbow).
    var elbowL: CGFloat = 1.6, elbowR: CGFloat = 1.6
    var hipX: CGFloat = 0, lift: CGFloat = 0
    /// Seen from behind: no face, tail in front, paws hidden.
    var back = false
    /// Raised legs pass behind the head.
    var armsBehind = false
    /// Smear frame: the right leg is stretched and trailed by speed lines.
    var smearRight = false
    /// A pointing paw on the viewer's left (−1) or right (1), or 0.
    var pointing: CGFloat = 0
}

enum ErmineKeyName: String, CaseIterable, Sendable {
    case idleA, idleB, look, tilt, squash, dip, up, singL, singR
    case tallDip, tallA, tallB, reachAnt, reachSm, reach, reachBk // ermine 1
    case wigL, wigR, spin1, back, spin2                           // ermine 2
    case jumpAir, jumpAir2, armsUp, glanceR, glanceL              // ermine 3 (glances are shared)
    case kira                                                     // ermine 4
    case flex, flexL, flexR                                       // ermine 5
    case hop, bow                                                 // everyone together

    var key: ErmineKey { ErmineKeys.table[self]! }

    /// Keys whose front legs may be replaced by a held arm pose (`ErmineArms`): the plain singing and idle drawings.
    var takesArmPose: Bool {
        switch self {
        case .idleA, .idleB, .look, .tilt, .squash, .dip, .up, .singL, .singR, .wigL, .wigR, .glanceL, .glanceR, .hop: true
        default: false
        }
    }
}

private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
private func k(_ edit: (inout ErmineKey) -> Void) -> ErmineKey { var key = ErmineKey(); edit(&key); return key }

enum ErmineKeys {
    static let table: [ErmineKeyName: ErmineKey] = [
        .idleA: ErmineKey(),
        .idleB: k { $0.neck = p(0, -61.5); $0.head = p(0, -76.8); $0.tail = [p(12, -6), p(27, -4), p(35, -21), p(30, -38)] },
        .look: k { $0.head = p(-1, -75); $0.rot = -6; $0.look = -1; $0.turn = -0.2 },
        .tilt: k { $0.head = p(1.5, -74.5); $0.rot = 15; $0.look = 0.4 },
        .squash: k {
            $0.hipW = 18; $0.waistW = 13.5; $0.neck = p(0, -51); $0.neckW = 8.5; $0.head = p(0, -65); $0.headScale = CGSize(width: 1.1, height: 0.9)
            $0.pawL = p(-8, -29); $0.pawR = p(8, -29); $0.tail = [p(12, -6), p(28, -3), p(36, -16), p(33, -30)]
        },
        // A small bob on each beat; `squash` is kept for accents.
        .dip: k {
            $0.hipW = 16; $0.waistW = 11.5; $0.neck = p(0, -57); $0.neckW = 7.8; $0.head = p(0, -72); $0.headScale = CGSize(width: 1.03, height: 0.97)
            $0.pawL = p(-7.5, -34); $0.pawR = p(7.5, -34); $0.tail = [p(12, -6), p(27, -4), p(35, -18), p(31, -34)]
        },
        .up: k {
            $0.hipW = 13; $0.waistW = 8.5; $0.neck = p(0, -69); $0.neckW = 6.8; $0.head = p(0, -85); $0.headScale = CGSize(width: 0.94, height: 1.06)
            $0.pawL = p(-7, -45); $0.pawR = p(7, -45); $0.tail = [p(12, -6), p(25, -6), p(30, -24), p(26, -43)]
        },
        .singL: k {
            $0.neck = p(-1.5, -61); $0.head = p(-2, -76.5); $0.rot = -3.5; $0.pawL = p(-8.5, -37); $0.pawR = p(5.5, -36.5)
            $0.turn = -0.1; $0.shoulderL = -0.5; $0.shoulderR = 0.3; $0.tail = [p(12, -6), p(28, -5), p(36, -21), p(32, -37)]
        },
        .singR: k {
            $0.neck = p(1.5, -61); $0.head = p(2, -76.5); $0.rot = 3.5; $0.pawL = p(-5.5, -36.5); $0.pawR = p(8.5, -37)
            $0.turn = 0.1; $0.shoulderL = 0.3; $0.shoulderR = -0.5; $0.tail = [p(12, -6), p(26, -3), p(32, -19), p(26, -36)]
        },
        // Ermine 1: on tiptoe, trembling; offering a paw.
        .tallDip: k { $0.hipW = 16; $0.waistW = 11.5; $0.neck = p(0, -63); $0.head = p(0, -78); $0.headScale = CGSize(width: 1.05, height: 0.95); $0.pawL = p(-6, -43); $0.pawR = p(6, -43) },
        .tallA: k {
            $0.hipW = 12; $0.waistW = 7.8; $0.neck = p(-0.8, -76); $0.neckW = 6.4; $0.head = p(-1, -92); $0.rot = -2; $0.headScale = CGSize(width: 0.92, height: 1.08)
            $0.pawL = p(-2.5, -60); $0.pawR = p(2.5, -60); $0.tail = [p(12, -6), p(23, -8), p(26, -31), p(19, -49)]
        },
        .tallB: k {
            $0.hipW = 12; $0.waistW = 7.8; $0.neck = p(0.8, -76.5); $0.neckW = 6.4; $0.head = p(1, -92.5); $0.rot = 2; $0.headScale = CGSize(width: 0.92, height: 1.08)
            $0.pawL = p(-2.5, -60.5); $0.pawR = p(2.5, -60.5); $0.tail = [p(12, -6), p(24, -8), p(28, -31), p(22, -50)]
        },
        .reachAnt: k { $0.neck = p(-2, -59); $0.head = p(-3, -73); $0.rot = -5; $0.pawL = p(-7, -36); $0.pawR = p(9, -43); $0.headScale = CGSize(width: 1.03, height: 0.97); $0.turn = -0.3; $0.shoulderL = -0.5; $0.shoulderR = 1 },
        .reachSm: k { $0.neck = p(3, -62); $0.head = p(4, -78); $0.rot = 6; $0.pawL = p(-7, -38); $0.pawR = p(28, -58); $0.smearRight = true; $0.turn = 0.45; $0.shoulderL = 1; $0.shoulderR = -2 },
        .reach: k { $0.neck = p(3, -62); $0.head = p(4, -78); $0.rot = 7; $0.pawL = p(-7, -38); $0.pawR = p(22, -61); $0.turn = 0.5; $0.shoulderL = 1; $0.shoulderR = -2.5 },
        .reachBk: k { $0.neck = p(3, -61); $0.head = p(5, -76); $0.rot = 8; $0.pawL = p(-4, -37); $0.pawR = p(15, -44); $0.turn = 0.25; $0.shoulderL = 0.5; $0.shoulderR = -1 },
        // Ermine 2: hip wiggle and a turn around.
        .wigL: k {
            $0.hipX = -2.5; $0.neck = p(1.5, -61); $0.head = p(2, -76); $0.rot = 4; $0.turn = 0.08; $0.pawL = p(-10, -40); $0.pawR = p(10, -39)
            $0.shoulderL = 0.5; $0.shoulderR = -0.5; $0.tail = [p(8, -6), p(18, 0), p(22, -16), p(15, -32)]
        },
        .wigR: k {
            $0.hipX = 2.5; $0.neck = p(-1.5, -61); $0.head = p(-2, -76); $0.rot = -4; $0.turn = -0.08; $0.pawL = p(-10, -39); $0.pawR = p(10, -40)
            $0.shoulderL = -0.5; $0.shoulderR = 0.5; $0.tail = [p(16, -6), p(34, -8), p(42, -24), p(39, -40)]
        },
        .spin1: k { $0.turn = 0.85; $0.head = p(2, -75); $0.rot = 4; $0.pawL = p(-2, -38); $0.pawR = p(10, -39); $0.tail = [p(10, -6), p(22, -2), p(27, -18), p(21, -34)] },
        .back: k { $0.back = true; $0.neck = p(0, -61); $0.head = p(0, -76); $0.tail = [p(0, -8), p(8, -2), p(13, -16), p(9, -31)] },
        .spin2: k { $0.turn = -0.85; $0.head = p(-2, -75); $0.rot = -4; $0.pawL = p(-10, -39); $0.pawR = p(2, -38); $0.tail = [p(14, -6), p(31, -6), p(38, -22), p(34, -38)] },
        // Ermine 3: arms thrust up and a jump; glancing sideways.
        .jumpAir: k {
            $0.lift = 13; $0.hipW = 13; $0.waistW = 8.5; $0.neck = p(0, -69); $0.neckW = 6.8; $0.head = p(0, -85); $0.headScale = CGSize(width: 0.95, height: 1.05)
            $0.pawL = p(-26, -101); $0.pawR = p(26, -101); $0.elbowL = 4; $0.elbowR = 4; $0.shoulderL = -1; $0.shoulderR = -1; $0.armsBehind = true
            $0.tail = [p(12, -6), p(22, -14), p(20, -30), p(12, -40)]
        },
        .jumpAir2: k {
            $0.lift = 7; $0.hipW = 13.5; $0.waistW = 9; $0.neck = p(0, -67); $0.neckW = 7; $0.head = p(0, -83); $0.pawL = p(-25, -96); $0.pawR = p(25, -96)
            $0.elbowL = 4; $0.elbowR = 4; $0.shoulderL = -1; $0.shoulderR = -1; $0.armsBehind = true; $0.tail = [p(12, -6), p(24, -10), p(25, -26), p(18, -38)]
        },
        .armsUp: k { $0.neck = p(0, -63); $0.head = p(0, -79); $0.pawL = p(-25, -97); $0.pawR = p(25, -97); $0.elbowL = 4; $0.elbowR = 4; $0.shoulderL = -1; $0.shoulderR = -1; $0.armsBehind = true },
        .glanceR: k { $0.head = p(2, -75); $0.rot = 6; $0.look = 1; $0.turn = 0.2 },
        .glanceL: k { $0.head = p(-2, -75); $0.rot = -6; $0.look = -1; $0.turn = -0.2 },
        // Ermine 4: "kira" pose with a paw by the cheek.
        .kira: k {
            $0.neck = p(-2, -61); $0.head = p(-3, -76); $0.rot = -9; $0.turn = -0.2; $0.pawL = p(-15, -72); $0.pawR = p(10, -40)
            $0.elbowL = 5; $0.shoulderL = -1.5; $0.shoulderR = 0.5; $0.tail = [p(12, -6), p(30, -6), p(40, -20), p(38, -36)]
        },
        // Ermine 5: showing off the (invisible) muscles.
        .flex: k {
            $0.hipW = 16.5; $0.waistW = 12; $0.neck = p(0, -59); $0.neckW = 8.2; $0.head = p(0, -74); $0.headScale = CGSize(width: 1.04, height: 0.97)
            $0.pawL = p(-27, -80); $0.pawR = p(27, -80); $0.elbowL = 11; $0.elbowR = 11; $0.shoulderL = -1; $0.shoulderR = -1; $0.armsBehind = true
        },
        .flexL: k { $0.neck = p(-1, -60); $0.head = p(-1.5, -75); $0.rot = -3; $0.turn = -0.08; $0.pawL = p(-27, -81); $0.pawR = p(8, -38); $0.elbowL = 11; $0.shoulderL = -1.5; $0.shoulderR = 0.5; $0.armsBehind = true },
        .flexR: k { $0.neck = p(1, -60); $0.head = p(1.5, -75); $0.rot = 3; $0.turn = 0.08; $0.pawL = p(-8, -38); $0.pawR = p(27, -81); $0.elbowR = 11; $0.shoulderL = 0.5; $0.shoulderR = -1.5; $0.armsBehind = true },
        // Everyone: a small hop together, and a bow at the end of a song.
        .hop: k {
            $0.lift = 9; $0.hipW = 13.5; $0.waistW = 9; $0.neck = p(0, -67); $0.neckW = 7; $0.head = p(0, -82); $0.headScale = CGSize(width: 0.95, height: 1.05)
            $0.pawL = p(-9, -47); $0.pawR = p(9, -47); $0.tail = [p(12, -6), p(24, -12), p(26, -28), p(20, -40)]
        },
        .bow: k {
            $0.hipW = 15.5; $0.waistW = 11; $0.neck = p(0, -55); $0.neckW = 7.8; $0.head = p(0, -65); $0.headScale = CGSize(width: 1.04, height: 0.9)
            $0.pawL = p(-5, -31); $0.pawR = p(5, -31); $0.tail = [p(12, -6), p(28, -3), p(35, -17), p(31, -31)]
        },
    ]
}

/// In-betweens ("nakawari") between two keys, eased in and out like spacing on a timing chart.
/// Trembles, smears and turning to the back stay hard cuts on purpose.
struct ErmineInbetweener: Sendable {
    private(set) var from = ErmineKeyName.idleA.key
    private(set) var to = ErmineKeyName.idleA.key
    private(set) var toName = ErmineKeyName.idleA
    private(set) var start = 0.0
    private(set) var duration = 0.0

    static func duration(from: ErmineKeyName, to: ErmineKeyName) -> Double {
        let trembles: Set<ErmineKeyName> = [.tallA, .tallB]
        if trembles.contains(from) && trembles.contains(to) { return 0 }
        if to == .reachSm || to == .back || from == .back { return 0 }
        if to == .bow || from == .bow { return 0.25 } // a slow, polite bow
        if [.idleA, .idleB].contains(from) && [.idleA, .idleB].contains(to) { return 0.5 }
        return 0.1
    }

    static func ease(_ x: Double) -> Double { x < 0.5 ? 2 * x * x : 1 - 2 * (1 - x) * (1 - x) }

    func pose(at now: Double) -> ErmineKey {
        guard duration > 0 else { return to }
        return Self.lerp(from, to, Self.ease(min(1, max(0, (now - start) / duration))))
    }

    mutating func pose(for name: ErmineKeyName, at now: Double) -> ErmineKey {
        if name != toName {
            from = pose(at: now)
            duration = Self.duration(from: toName, to: name)
            to = name.key; toName = name; start = now
        }
        return pose(at: now)
    }

    mutating func reset(to name: ErmineKeyName = .idleA) {
        from = name.key; to = name.key; toName = name; duration = 0
    }

    static func lerp(_ a: ErmineKey, _ b: ErmineKey, _ e: Double) -> ErmineKey {
        let t = CGFloat(e)
        func v(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        func q(_ x: CGPoint, _ y: CGPoint) -> CGPoint { CGPoint(x: v(x.x, y.x), y: v(x.y, y.y)) }
        var o = b
        o.hipW = v(a.hipW, b.hipW); o.waistW = v(a.waistW, b.waistW)
        o.neck = q(a.neck, b.neck); o.neckW = v(a.neckW, b.neckW)
        o.head = q(a.head, b.head); o.rot = v(a.rot, b.rot)
        o.headScale = CGSize(width: v(a.headScale.width, b.headScale.width), height: v(a.headScale.height, b.headScale.height))
        o.pawL = q(a.pawL, b.pawL); o.pawR = q(a.pawR, b.pawR)
        o.tail = zip(a.tail, b.tail).map(q)
        o.look = v(a.look, b.look); o.turn = v(a.turn, b.turn)
        o.shoulderL = v(a.shoulderL, b.shoulderL); o.shoulderR = v(a.shoulderR, b.shoulderR)
        o.elbowL = v(a.elbowL, b.elbowL); o.elbowR = v(a.elbowR, b.elbowR)
        o.hipX = v(a.hipX, b.hipX); o.lift = v(a.lift, b.lift)
        o.armsBehind = b.armsBehind || (a.armsBehind && e < 0.5)
        return o
    }
}

/// A held arm pose for a phrase, like a singer's: hands together at the chest, a hand offered forward,
/// both hands open, one arm raised to lead, or pointing at the audience. Paws are placed relative to the neck,
/// so they ride along with the bob and sway of the body keys.
enum ErmineArmPose: Sendable, Equatable, CaseIterable {
    case rest, pray, offer, embrace, raise, point

    /// Paw offsets from the neck for the right leg (mirrored for the left), elbows, and whether the legs pass behind the head.
    struct Shape: Equatable { var left: CGVector; var right: CGVector; var elbowL: CGFloat; var elbowR: CGFloat; var behind = false; var pointing = false }

    /// The shape with the active hand on `side` (1 = viewer's right).
    func shape(side: CGFloat) -> Shape? {
        let rest = CGVector(dx: -7, dy: 24)
        func mirror(_ v: CGVector) -> CGVector { CGVector(dx: -v.dx, dy: v.dy) }
        var s: Shape
        switch self {
        case .rest: return nil
        case .pray: return Shape(left: CGVector(dx: -2.2, dy: 9), right: CGVector(dx: 2.2, dy: 9), elbowL: 3.5, elbowR: 3.5)
        case .embrace: return Shape(left: CGVector(dx: -16, dy: 11), right: CGVector(dx: 16, dy: 11), elbowL: 2.5, elbowR: 2.5)
        case .offer: s = Shape(left: rest, right: CGVector(dx: 15, dy: 13), elbowL: 1.6, elbowR: 2)
        // Raised only to beside the cheek, a little above pointing: a natural call to sing along.
        case .raise: s = Shape(left: rest, right: CGVector(dx: 24, dy: -11), elbowL: 1.6, elbowR: 4)
        case .point: s = Shape(left: rest, right: CGVector(dx: 19, dy: 6), elbowL: 1.6, elbowR: 0.6, pointing: true)
        }
        if side < 0 { s = Shape(left: mirror(s.right), right: mirror(s.left), elbowL: s.elbowR, elbowR: s.elbowL, behind: s.behind, pointing: s.pointing) }
        return s
    }
}

struct ErmineArms: Sendable, Equatable {
    var pose = ErmineArmPose.rest
    /// Which hand leads (1 = the viewer's right).
    var side: CGFloat = 1
}

/// Eases the arms from one held pose to the next, separately from the body keys.
struct ErmineArmTween: Sendable {
    static let duration = 0.25
    private var fromWeight = 0.0, from: ErmineArmPose.Shape?, to: ErmineArmPose.Shape?, target = ErmineArms(), start = 0.0

    /// Lays the arm pose over a body pose that takes one; other keys keep their own legs.
    mutating func apply(_ arms: ErmineArms, to key: ErmineKeyName, pose: ErmineKey, at now: Double) -> ErmineKey {
        if arms != target {
            from = current(at: now, base: pose); target = arms; to = arms.pose.shape(side: arms.side); start = now
        }
        guard key.takesArmPose else { return pose }
        let e = CGFloat(ErmineInbetweener.ease(min(1, max(0, (now - start) / Self.duration))))
        let restShape = ErmineArmPose.Shape(left: CGVector(dx: pose.pawL.x - pose.neck.x, dy: pose.pawL.y - pose.neck.y),
                                            right: CGVector(dx: pose.pawR.x - pose.neck.x, dy: pose.pawR.y - pose.neck.y),
                                            elbowL: pose.elbowL, elbowR: pose.elbowR)
        let a = from ?? restShape, b = to ?? restShape
        func mix(_ x: CGVector, _ y: CGVector) -> CGPoint {
            CGPoint(x: pose.neck.x + x.dx + (y.dx - x.dx) * e, y: pose.neck.y + x.dy + (y.dy - x.dy) * e)
        }
        var out = pose
        out.pawL = mix(a.left, b.left); out.pawR = mix(a.right, b.right)
        out.elbowL = a.elbowL + (b.elbowL - a.elbowL) * e; out.elbowR = a.elbowR + (b.elbowR - a.elbowR) * e
        out.armsBehind = (e < 0.5 ? a.behind : b.behind)
        out.pointing = e >= 0.5 && b.pointing ? (target.side < 0 ? -1 : 1) : 0
        return out
    }

    private func current(at now: Double, base: ErmineKey) -> ErmineArmPose.Shape? {
        // Starting a new tween from wherever the last one reached keeps the motion continuous.
        let e = min(1, max(0, (now - start) / Self.duration))
        if e >= 1 { return to }
        guard let a = from ?? to, let b = to ?? from else { return nil }
        let t = CGFloat(ErmineInbetweener.ease(e))
        func m(_ x: CGVector, _ y: CGVector) -> CGVector { CGVector(dx: x.dx + (y.dx - x.dx) * t, dy: x.dy + (y.dy - x.dy) * t) }
        return ErmineArmPose.Shape(left: m(a.left, b.left), right: m(a.right, b.right),
                                   elbowL: a.elbowL + (b.elbowL - a.elbowL) * t, elbowR: a.elbowR + (b.elbowR - a.elbowR) * t,
                                   behind: t < 0.5 ? a.behind : b.behind, pointing: false)
    }
}
