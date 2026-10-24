import Foundation
import simd

/// Triangles with position (stage points), texture coordinates (top-left origin) and a linear RGBA color.
struct PuppetMesh: Sendable {
    static let floatsPerVertex = 9
    var vertices: [Float] = []
    var indices: [UInt32] = []
    var vertexCount: Int { vertices.count / Self.floatsPerVertex }

    mutating func add(_ p: SIMD3<Double>, _ uv: SIMD2<Double>, _ c: SIMD4<Double>) {
        vertices += [Float(p.x), Float(p.y), Float(p.z), Float(uv.x), Float(uv.y), Float(c.x), Float(c.y), Float(c.z), Float(c.w)]
    }
    func position(_ i: Int) -> SIMD3<Double> {
        let b = i * Self.floatsPerVertex
        return SIMD3(Double(vertices[b]), Double(vertices[b + 1]), Double(vertices[b + 2]))
    }

    /// three.js's SphereGeometry (radius 1, 40×24 segments) with the same vertex order, poles and texture coordinates.
    static func sphere(phiStart: Double, phiLength: Double, thetaStart: Double, thetaLength: Double,
                       color: (SIMD3<Double>) -> SIMD4<Double>, uv uvOf: ((SIMD3<Double>) -> SIMD2<Double>)? = nil) -> PuppetMesh {
        let ws = 40, hs = 24, thetaEnd = min(thetaStart + thetaLength, .pi)
        var mesh = PuppetMesh(), grid: [[UInt32]] = []
        for iy in 0...hs {
            let v = Double(iy) / Double(hs)
            let uOffset = iy == 0 && thetaStart == 0 ? 0.5 / Double(ws) : iy == hs && thetaEnd == .pi ? -0.5 / Double(ws) : 0
            var row: [UInt32] = []
            for ix in 0...ws {
                let u = Double(ix) / Double(ws)
                let phi = phiStart + u * phiLength, theta = thetaStart + v * thetaLength
                let p = SIMD3(-cos(phi) * sin(theta), cos(theta), sin(phi) * sin(theta))
                row.append(UInt32(mesh.vertexCount))
                mesh.add(p, uvOf?(p) ?? SIMD2(u + uOffset, v), color(p))
            }
            grid.append(row)
        }
        for iy in 0..<hs {
            for ix in 0..<ws {
                let a = grid[iy][ix + 1], b = grid[iy][ix], c = grid[iy + 1][ix], d = grid[iy + 1][ix + 1]
                if iy != 0 || thetaStart > 0 { mesh.indices += [a, b, d] }
                if iy != hs - 1 || thetaEnd < .pi { mesh.indices += [b, c, d] }
            }
        }
        return mesh
    }

    /// three.js's open CylinderGeometry (radius 1, height 1, 32 segments).
    static func cylinder(color: (SIMD3<Double>) -> SIMD4<Double>) -> PuppetMesh {
        var mesh = PuppetMesh()
        for y in 0...1 {
            for x in 0...32 {
                let u = Double(x) / 32, theta = u * 2 * .pi
                let p = SIMD3(sin(theta), -Double(y) + 0.5, cos(theta))
                mesh.add(p, SIMD2(u, Double(y)), color(p))
            }
        }
        for x in 0..<32 {
            let a = UInt32(x), b = UInt32(33 + x), c = UInt32(34 + x), d = UInt32(x + 1)
            mesh.indices += [a, b, d, b, c, d]
        }
        return mesh
    }

    /// A half disc whose round edge is at +y. Its corners are those of the head's ring at the cut (the sphere's
    /// 40 segments around, so 20 over the front half); a finer edge would stick out of the head between the
    /// head's corners and show as a dotted line across the closed mouth.
    static func halfDisc() -> PuppetMesh {
        var mesh = PuppetMesh()
        mesh.add(SIMD3(0, 0, 0), SIMD2(0.5, 0.5), SIMD4(1, 1, 1, 1))
        for s in 0...20 {
            let a = Double(s) / 20 * .pi, p = SIMD3(cos(a), sin(a), 0)
            mesh.add(p, SIMD2((p.x + 1) / 2, 1 - (p.y + 1) / 2), SIMD4(1, 1, 1, 1))
        }
        for i in 1...20 { mesh.indices += [UInt32(i), UInt32(i + 1), 0] }
        return mesh
    }

    /// A centered rectangle like three.js's PlaneGeometry.
    static func plane(_ w: Double, _ h: Double) -> PuppetMesh {
        var mesh = PuppetMesh()
        for (x, y) in [(-0.5, 0.5), (0.5, 0.5), (-0.5, -0.5), (0.5, -0.5)] {
            mesh.add(SIMD3(x * w, y * h, 0), SIMD2(x + 0.5, 0.5 - y), SIMD4(1, 1, 1, 1))
        }
        mesh.indices = [0, 2, 1, 2, 3, 1]
        return mesh
    }
}

enum PuppetBlend: Sendable { case opaque, cutout, normal, additive }

/// Textures of the puppets. `isSRGB` ones are decoded to linear when sampled, as three.js did with sRGB encoding.
enum PuppetTexture: Hashable, Sendable {
    case art(String), fabric, mouthCap(tongue: Bool), eyeGlow(String), eyeCore(String), ripple(String)
    case blush, coveredEye(String, squeeze: Bool?), shoutLine, tearStream
    var isSRGB: Bool {
        switch self {
        case .art, .mouthCap, .eyeGlow, .eyeCore, .coveredEye: true
        case .fabric, .ripple, .blush, .shoutLine, .tearStream: false
        }
    }
    var repeats: Bool { self == .tearStream }
}

/// One mesh drawn with one material at one node.
struct PuppetPiece: Sendable {
    var node: Int
    var mesh: Int
    var texture: PuppetTexture
    var blend: PuppetBlend
    /// Effects over the face ignore depth and are drawn last, so the head never hides them.
    var depthTest = true
    /// Takes the color of the time of day's light.
    var lit = false
    var renderOrder = 0
    var opacity = 1.0
    /// Draws only this many indices (the tears grow downward); nil draws all.
    var indexCount: Int?
    var uvOffset = SIMD2<Double>(0, 0)
}

struct PuppetNode: Sendable {
    var parent: Int?
    var position = SIMD3<Double>(0, 0, 0)
    var rotation = SIMD3<Double>(0, 0, 0)
    var scale = SIMD3<Double>(1, 1, 1)
    var matrix: simd_float4x4 {
        PuppetMath.compose(position: SIMD3<Float>(position), rotation: SIMD3<Float>(rotation), scale: SIMD3<Float>(scale))
    }
}

/// A puppet assembled from its parts, as in the agreed mock: a skin-colored ellipsoid head split by a horizontal
/// cut for the mouth, eye stickers, hair on a slightly larger ellipsoid, a short neck cylinder, the body, and
/// sleeves that turn at the shoulders. Units are stage points; 1 pixel of the source art is 0.185pt.
struct PuppetRig: Sendable {
    static let pixel = 0.185
    static let headScale = 1.14

    let member: PuppetMember
    private(set) var nodes: [PuppetNode] = []
    private(set) var meshes: [PuppetMesh] = []
    var pieces: [PuppetPiece] = []
    /// The depth on the stage; neighbors stand slightly apart.
    let depth: Double

    private(set) var root = 0, body = 0, armL = 0, armR = 0, neck = 0, head = 0, upper = 0, jaw = 0
    private var glowNodes: [Int] = [], glowPieces: [Int] = [], corePieces: [Int] = []
    private var rippleNodes: [Int] = [], ripplePieces: [Int] = []
    private var tearPieces: [Int] = [], squeezePieces: [Int] = [], closedPieces: [Int] = [], blushPieces: [Int] = []
    private var lineNodes: [Int] = [], linePieces: [Int] = []
    private var glowBase = 48 * PuppetRig.pixel
    static let tearSegments = 32

    private mutating func node(_ parent: Int?, _ position: SIMD3<Double> = .zero, rotation: SIMD3<Double> = .zero,
                               scale: SIMD3<Double> = SIMD3(1, 1, 1)) -> Int {
        nodes.append(PuppetNode(parent: parent, position: position, rotation: rotation, scale: scale)); return nodes.count - 1
    }
    @discardableResult
    private mutating func piece(_ node: Int, _ mesh: PuppetMesh, _ texture: PuppetTexture, _ blend: PuppetBlend,
                                depthTest: Bool = true, lit: Bool = false, order: Int = 0) -> Int {
        meshes.append(mesh)
        pieces.append(PuppetPiece(node: node, mesh: meshes.count - 1, texture: texture, blend: blend, depthTest: depthTest, lit: lit, renderOrder: order))
        return pieces.count - 1
    }

    /// Builds the puppet. `images` gives the parts by name ("body", "arm_l", …); `fabricMean` is the cloth's mean brightness.
    init(member: PuppetMember, index: Int, character b: PuppetCharacter, images: [String: PuppetImage], fabricMean: Double) {
        self.member = member
        depth = Double(index % 2) * -4
        let S = Self.pixel, name = member.name
        let (hcx, hcy) = (b.headCenter[0], b.headCenter[1])
        let (hrx, hry, hrz) = (b.headRadius[0], b.headRadius[1], b.headRadius[2])
        let hairScale = b.hairScale
        let toLinear = { (c: [Double]) in SIMD3(pow(c[0], 2.2), pow(c[1], 2.2), pow(c[2], 2.2)) }
        // A little more red in the skin.
        let skin = simd_min(toLinear(PuppetMember.skin(name, measured: b.skin)) * SIMD3(1.06, 0.97, 0.95), SIMD3(1, 1, 1))
        let hair = toLinear(b.hair)
        let painted = { (c: SIMD3<Double>) in simd_min(c / fabricMean, SIMD3(1, 1, 1)) }
        func headDepth(_ x: Double, _ y: Double) -> Double {
            let dx = (x - hcx) / hrx, dy = (y - hcy) / hry
            return hrz * max(0, 1 - dx * dx - dy * dy).squareRoot()
        }
        // The brightness of a surface lit from the front, from the ellipsoid's normal.
        func shade(_ nx: Double, _ ny: Double, _ nz: Double) -> Double {
            let l = (nx * nx + ny * ny + nz * nz).squareRoot(), k = l > 0 ? l : 1
            return max(0.55, 0.74 + 0.22 * (nz / k) - 0.06 * (ny / k))
        }
        func headShade(_ x: Double, _ y: Double) -> Double {
            shade((x - hcx) / (hrx * hrx), (y - hcy) / (hry * hry), headDepth(x, y) / (hrz * hrz))
        }
        func sphereColor(_ c: SIMD3<Double>) -> (SIMD3<Double>) -> SIMD4<Double> {
            { p in let v = shade(p.x / hrx, -p.y / hry, p.z / hrz); return SIMD4(c * v, 1) }
        }
        func shellScale(_ s: Double) -> SIMD3<Double> { SIMD3(hrx * s * S, hry * s * S, hrz * s * S) }
        /// A flat part of the art on a grid, bent by `depth`, around `pivot` (source pixels).
        func part(_ image: PuppetImage, pivot: SIMD2<Double>, depth: (Double, Double) -> Double, shade: (Double, Double) -> Double,
                  _ nx: Int = 28, _ ny: Int = 28) -> PuppetMesh {
            var mesh = PuppetMesh()
            guard let bounds = image.opaqueBounds() else { return mesh }
            // `px`, `py` are pixels of the part's own (trimmed) picture; the sheet is offset by the box and the trim.
            let (ox, oy) = (b.box[0] + Double(image.origin.x), b.box[1] + Double(image.origin.y))
            for j in 0...ny {
                for i in 0...nx {
                    let px = Double(bounds.x0) + Double(bounds.x1 + 1 - bounds.x0) * Double(i) / Double(nx)
                    let py = Double(bounds.y0) + Double(bounds.y1 + 1 - bounds.y0) * Double(j) / Double(ny)
                    let x = px + ox, y = py + oy, v = shade(x, y)
                    mesh.add(SIMD3((x - pivot.x) * S, -(y - pivot.y) * S, depth(x, y) * S),
                             SIMD2(px / Double(image.width), py / Double(image.height)), SIMD4(v, v, v, 1))
                }
            }
            for j in 0..<ny {
                for i in 0..<nx {
                    let a = UInt32(j * (nx + 1) + i), bb = a + 1, c = a + UInt32(nx + 1), d = c + 1
                    mesh.indices += [a, c, bb, bb, c, d]
                }
            }
            return mesh
        }
        func art(_ key: String) -> PuppetImage? { images[key] }

        let hip = SIMD2(b.headCX, b.hipY)
        root = node(nil)
        body = node(root)
        if let image = art("body") {
            let bodyDepth = { (x: Double, _: Double) in
                let dx = (x - b.headCX) / (hrx * 1.06); return 38 * (hrx / 127) * max(0, 1 - dx * dx).squareRoot()
            }
            let bodyShade = { (x: Double, _: Double) in
                let dx = PuppetMath.clamp(abs(x - b.headCX) / (hrx * 1.06)); return 0.98 - 0.2 * dx * dx
            }
            piece(body, part(image, pivot: hip, depth: bodyDepth, shade: bodyShade), .art("\(name)/body"), .cutout, lit: true)
        }
        // Sleeves are parts of their own, in front of the body, turning at the shoulder.
        func arm(_ key: String, _ pivot: [Double]) -> Int {
            let n = node(body, SIMD3((pivot[0] - hip.x) * S, -(pivot[1] - hip.y) * S, 34 * S))
            if let image = art(key) {
                piece(n, part(image, pivot: SIMD2(pivot[0], pivot[1]), depth: { _, _ in 0 }, shade: { _, _ in 0.97 }, 12, 12),
                      .art("\(name)/\(key)"), .cutout, lit: true)
            }
            return n
        }
        armL = arm("arm_l", b.pivotArmL); armR = arm("arm_r", b.pivotArmR)
        let neckPivot = SIMD2(b.pivotNeck[0], b.pivotNeck[1])
        neck = node(body, SIMD3((neckPivot.x - hip.x) * S, -(neckPivot.y - hip.y) * S, 30 * S))
        // The neck: a short cylinder sunk into the head and the body, dark in the chin's shadow, darker toward the top.
        let k = hrx / 127, neckColor = painted(skin)
        let neckNode = node(neck, SIMD3(0, -8 * k * S, -48 * k * S), scale: SIMD3(50 * k * S, 90 * k * S, 50 * k * S))
        piece(neckNode, .cylinder { p in
            let v = (p.y > 0 ? 0.45 : 0.58) + 0.1 * max(0, p.z); return SIMD4(neckColor * v, 1)
        }, .fabric, .opaque, lit: true)
        head = node(neck, scale: SIMD3(repeating: Self.headScale))   // a little larger, hiding the collar under the chin
        // The mouth: a horizontal cut in the ellipsoid head, hinged at its back (the ellipsoid's center plane).
        let hinge = SIMD2(hcx, b.cutY)
        upper = node(head, SIMD3((hinge.x - neckPivot.x) * S, -(hinge.y - neckPivot.y) * S, 0))
        jaw = node(head, SIMD3((hinge.x - neckPivot.x) * S, -(hinge.y - neckPivot.y) * S, 0))
        let thetaCut = acos(PuppetMath.clamp(-(b.cutY - hcy) / hry, -1, 1)), centerY = (b.cutY - hcy) * S
        func shell(_ parent: Int, _ color: SIMD3<Double>, _ s: Double, _ phi: (Double, Double), _ theta: (Double, Double)) {
            let n = node(parent, SIMD3(0, centerY, 0), scale: shellScale(s))
            piece(n, .sphere(phiStart: phi.0, phiLength: phi.1, thetaStart: theta.0, thetaLength: theta.1, color: sphereColor(painted(color))),
                  .fabric, .opaque, lit: true)
        }
        // The face: only skin color on cloth, split by the cut.
        shell(upper, skin, 1, (0, 2 * .pi), (0, thetaCut))
        shell(jaw, skin, 1, (0, 2 * .pi), (thetaCut, .pi - thetaCut))
        // Only the glasses and eyes are stuck on, with soft edges.
        if let image = art("decal") {
            piece(upper, part(image, pivot: hinge, depth: { headDepth($0, $1) + 1.5 }, shade: headShade, 32, 16),
                  .art("\(name)/decal"), .normal, lit: true, order: 5)
        }
        // Hair: an ellipsoid a size larger than the face. The front is the hair picture projected from the front; the back is the hair color.
        let thetaHair = acos(PuppetMath.clamp(-(b.sideburnY - hcy) / (hry * hairScale), -1, 1))
        if let image = art("hair_cap") {
            let n = node(upper, SIMD3(0, centerY, 0), scale: shellScale(hairScale))
            let mesh = PuppetMesh.sphere(phiStart: 0, phiLength: .pi, thetaStart: 0, thetaLength: thetaHair,
                                         color: sphereColor(SIMD3(1, 1, 1))) { p in
                let x = hcx + p.x * hrx * hairScale, y = hcy - p.y * hry * hairScale
                return SIMD2((x - b.box[0] - Double(image.origin.x)) / Double(image.width),
                             (y - b.box[1] - Double(image.origin.y)) / Double(image.height))
            }
            piece(n, mesh, .art("\(name)/hair_cap"), .cutout, lit: true)
        }
        shell(upper, hair, hairScale, (.pi, .pi), (0, thetaHair))
        // Hair beyond the ellipsoid (spikes, twin tails, a ponytail, a ribbon) is a board at the head's center plane;
        // hair hanging below the mouth goes behind the body and arms.
        if let image = art("hair_extra") {
            let extraDepth = { (x: Double, y: Double) in
                PuppetMath.lerp(-hrz * 0.15 + 0.25 * hrz * PuppetMath.clamp(1 - abs(x - hcx) / (hrx * 1.6)), -hrz * 1.1,
                                PuppetMath.smoothstep(b.cutY - 20, b.cutY + 30, y))
            }
            piece(upper, part(image, pivot: hinge, depth: extraDepth, shade: { _, _ in 0.9 }, 24, 24), .art("\(name)/hair_extra"), .cutout, lit: true)
        }
        // The insides of the mouth fill the cut exactly, slightly inside the head's surface.
        let dy = (b.cutY - hcy) / hry, kk = max(0, 1 - dy * dy).squareRoot() * 0.995
        let capScale = SIMD3(hrx * kk * S, hrz * kk * S, 1)
        let upperCap = node(upper, SIMD3(0, 0.05, 0), rotation: SIMD3(.pi / 2, 0, 0), scale: capScale)
        piece(upperCap, .halfDisc(), .mouthCap(tongue: false), .cutout, lit: true)
        let jawCap = node(jaw, SIMD3(0, -0.05, 0), rotation: SIMD3(.pi / 2, 0, 0), scale: capScale)
        piece(jawCap, .halfDisc(), .mouthCap(tongue: true), .cutout, lit: true)

        // Effects on the eyes ride on the upper head.
        func local(_ x: Double, _ y: Double) -> SIMD2<Double> { SIMD2((x - hinge.x) * S, -(y - hinge.y) * S) }
        let style = member.eyes
        for (i, eye) in b.eyes.enumerated() {
            let (ex, ey) = (eye[0], eye[1]), at = local(ex, ey), hd = headDepth(ex, ey)
            let glow = node(upper, SIMD3(at.x, at.y + (style.kind == .flame ? 6 * S : 0), (hd + 4) * S))
            glowNodes.append(glow)
            glowPieces.append(piece(glow, .plane(1, 1.5), .eyeGlow(name), .additive, depthTest: false, order: 11))
            if style.kind == .wave {
                for _ in 0..<2 {
                    let n = node(upper, SIMD3(at.x, at.y, (hd + 5) * S))
                    rippleNodes.append(n)
                    ripplePieces.append(piece(n, .plane(1, 1), .ripple(name), .additive, depthTest: false, order: 12))
                }
            }
            corePieces.append(piece(node(upper, SIMD3(at.x, at.y, (hd + 3) * S)), .plane(15 * S, 21 * S), .eyeCore(name), .normal,
                                    depthTest: false, order: 10))
            // Tears: a stream from under the eye down the cheek, widening, meandering, fading before the mouth.
            let side = i == 0 ? -1.0 : 1.0
            var stream = PuppetMesh()
            let (x0, y0, y1) = (ex + side * 2, ey + 10, b.cutY - 2)
            for j in 0...Self.tearSegments {
                let t = Double(j) / Double(Self.tearSegments), y = PuppetMath.lerp(y0, y1, t)
                let x = x0 + side * (2 + 8 * t) + 7 * t * sin(t * .pi * 2.4 + (side > 0 ? 0.6 : 0)), w = 5 + 22 * pow(t, 0.9)
                let a = 1 - PuppetMath.smoothstep(0.72, 1, t)
                for k in [-1.0, 1.0] {
                    let xk = x + k * w
                    stream.add(SIMD3((xk - hcx) * S, -(y - b.cutY) * S, (headDepth(xk, y) + 1.5) * S),
                               SIMD2(k < 0 ? 0 : 1, -(y - y0) / 30), SIMD4(1, 1, 1, a))
                }
            }
            for j in 0..<Self.tearSegments {
                let a = UInt32(j * 2); stream.indices += [a, a + 2, a + 1, a + 1, a + 2, a + 3]
            }
            tearPieces.append(piece(upper, stream, .tearStream, .normal, depthTest: false, order: 12))
            squeezePieces.append(piece(node(upper, SIMD3(at.x, at.y, (hd + 5) * S)), .plane(30 * S, 22 * S),
                                       .coveredEye(name, squeeze: i == 1), .normal, depthTest: false, lit: true, order: 13))
            let (bx, by) = (ex + (i == 0 ? -8 : 8), ey + 30), bAt = local(bx, by)
            blushPieces.append(piece(node(upper, SIMD3(bAt.x, bAt.y, (headDepth(bx, by) + 3) * S)), .plane(40 * S, 20 * S), .blush, .normal,
                                     depthTest: false, order: 12))
            let big = name == "twin" || name == "pony" ? 1.4 : 1   // the girls' closed eyes are drawn larger
            closedPieces.append(piece(node(upper, SIMD3(at.x, at.y, (hd + 5) * S)), .plane(30 * S * big, 22 * S * big),
                                      .coveredEye(name, squeeze: nil), .normal, depthTest: false, lit: true, order: 13))
        }
        // Shouting lines around the head, on the neck so they do not swing back with the upper head.
        for degrees in [150.0, 168, 186, 30, 12, -6] {
            let a = degrees * .pi / 180, r = 180 * S * Self.headScale
            let n = node(neck, SIMD3(cos(a) * r, (neckPivot.y - hcy) * S * Self.headScale + sin(a) * r, 60 * S), rotation: SIMD3(0, 0, a - .pi / 2))
            lineNodes.append(n)
            linePieces.append(piece(n, .plane(9 * S, 60 * S), .shoutLine, .normal, depthTest: false, order: 13))
        }
        apply(PuppetPose())
    }

    /// Puts the parts where `pose` says.
    mutating func apply(_ p: PuppetPose) {
        nodes[root].position = SIMD3(member.x, p.rootY, depth)
        nodes[body].position = SIMD3(p.bodyPosition.x, p.bodyPosition.y, 0)
        nodes[body].rotation = p.bodyRotation
        nodes[head].rotation = p.headRotation
        nodes[upper].rotation.x = p.upperRotationX
        nodes[jaw].rotation.x = p.jawRotationX
        nodes[armL].rotation.z = p.armL
        nodes[armR].rotation.z = p.armR
        for i in squeezePieces.indices {
            pieces[squeezePieces[i]].opacity = p.squeeze
            pieces[closedPieces[i]].opacity = p.closedEyes
            pieces[blushPieces[i]].opacity = p.blush
            pieces[glowPieces[i]].opacity = p.eyeGlow[i]
            pieces[corePieces[i]].opacity = p.eyeCore[i]
            nodes[glowNodes[i]].scale = SIMD3(glowBase * p.eyeGlowScale[i].x, glowBase * p.eyeGlowScale[i].y, 1)
            let shown = Int((Double(Self.tearSegments) * p.tears).rounded()) * 6
            pieces[tearPieces[i]].indexCount = shown
            pieces[tearPieces[i]].opacity = shown > 0 ? 1 : 0
            pieces[tearPieces[i]].uvOffset = SIMD2(0, p.tearFlow)
        }
        for (k, n) in rippleNodes.enumerated() {
            pieces[ripplePieces[k]].opacity = p.ripples[k].x
            nodes[n].scale = SIMD3(repeating: glowBase * p.ripples[k].y)
        }
        for (i, n) in lineNodes.enumerated() {
            pieces[linePieces[i]].opacity = p.shoutLines[i].x
            nodes[n].scale = SIMD3(1, p.shoutLines[i].y, 1)
        }
    }

    /// Every node's matrix in stage space.
    func worldMatrices() -> [simd_float4x4] {
        var out = [simd_float4x4](repeating: matrix_identity_float4x4, count: nodes.count)
        for (i, n) in nodes.enumerated() { out[i] = n.parent.map { out[$0] * n.matrix } ?? n.matrix }
        return out
    }
}
