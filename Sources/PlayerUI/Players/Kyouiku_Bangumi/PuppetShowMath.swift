import simd

/// Small helpers shared by the puppet show's motion and drawing. The motion was tuned in a three.js mock,
/// so transforms follow its conventions: y up, Euler angles applied in X·Y·Z order, matrix = T·R·S.
enum PuppetMath {
    static func clamp(_ v: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(b, max(a, v)) }
    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = clamp((x - a) / (b - a)); return t * t * (3 - 2 * t)
    }

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4; m.columns.3 = SIMD4(t.x, t.y, t.z, 1); return m
    }
    static func scale(_ s: SIMD3<Float>) -> simd_float4x4 { simd_float4x4(diagonal: SIMD4(s.x, s.y, s.z, 1)) }
    /// three.js's Euler order "XYZ": the matrix is Rx·Ry·Rz.
    static func rotation(_ r: SIMD3<Float>) -> simd_float4x4 {
        let (a, b) = (cos(r.x), sin(r.x)), (c, d) = (cos(r.y), sin(r.y)), (e, f) = (cos(r.z), sin(r.z))
        let ae = a * e, af = a * f, be = b * e, bf = b * f
        return simd_float4x4(rows: [
            SIMD4(c * e, -c * f, d, 0),
            SIMD4(af + be * d, ae - bf * d, -b * c, 0),
            SIMD4(bf - ae * d, be + af * d, a * c, 0),
            SIMD4(0, 0, 0, 1),
        ])
    }
    static func compose(position: SIMD3<Float>, rotation r: SIMD3<Float>, scale s: SIMD3<Float>) -> simd_float4x4 {
        translation(position) * rotation(r) * scale(s)
    }
    /// A perspective projection with Metal's 0…1 depth range.
    static func perspective(fovYDegrees: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let f = 1 / tan(fovYDegrees * .pi / 360)
        return simd_float4x4(columns: (SIMD4(f / aspect, 0, 0, 0), SIMD4(0, f, 0, 0),
                                       SIMD4(0, 0, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0)))
    }
    /// Stage points (x right, y down) to clip space.
    static func orthographic(width: Float, height: Float) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(2 / width, 0, 0, 0), SIMD4(0, -2 / height, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(-1, 1, 0, 1)))
    }
}

/// The mock's seeded generator (a 32-bit LCG), kept bit-for-bit so stars, cloth and choices match it.
struct PuppetRandom: Sendable {
    private var state: UInt32
    init(seed: UInt32) { state = seed }
    mutating func next() -> Double {
        state = state &* 1_664_525 &+ 1_013_904_223
        return Double(state) / 4_294_967_296
    }
    /// A repeatable value in 0..<1 for an integer, such as the slot of a shooting star.
    static func hash(_ n: Int) -> Double {
        var r = PuppetRandom(seed: UInt32(truncatingIfNeeded: Int64(n) &* 2_654_435_761))
        _ = r.next(); return r.next()
    }
}

/// A critically damped spring: it moves toward its target without overshooting.
struct PuppetSpring: Sendable {
    var value: Double, velocity = 0.0, target: Double
    let omega: Double
    init(_ value: Double = 0, omega: Double) { self.value = value; target = value; self.omega = omega }
    mutating func step(_ dt: Double) {
        let x = value - target, e = exp(-omega * dt), tmp = (velocity + omega * x) * dt
        velocity = (velocity - omega * tmp) * e
        value = target + (x + tmp) * e
    }
}
