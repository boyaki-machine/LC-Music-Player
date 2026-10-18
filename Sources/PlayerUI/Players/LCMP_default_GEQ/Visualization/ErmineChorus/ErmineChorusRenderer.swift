import SwiftUI

/// Draws the stage and the ermines as stacked cels: tail, feet, body, head, legs, face, effects.
/// Ink lines and two-tone cel shading, like hand-drawn animation.
enum ErmineChorusRenderer {
    static let background = Color(red: 5 / 255, green: 8 / 255, blue: 7 / 255)
    static let stageSize = CGSize(width: 360, height: 144)

    static func draw(context original: GraphicsContext, size: CGSize, drawings: [ErmineDrawing],
                     stage: ErmineStage = ErmineStage(), dust: [ErmineMote] = [], reduceMotion: Bool = false) {
        var context = original
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
        // Fit the 360×144 stage into the given size.
        let scale = min(size.width / stageSize.width, size.height / stageSize.height)
        context.translateBy(x: (size.width - stageSize.width * scale) / 2, y: (size.height - stageSize.height * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.fill(Path(CGRect(origin: .zero, size: stageSize)), with: .radialGradient(
            Gradient(colors: [Color(red: 0.25, green: 0.26, blue: 0.22).opacity(0.85), background.opacity(0)]),
            center: CGPoint(x: 180, y: 124), startRadius: 10, endRadius: 215))
        // With reduced motion the lamps hold a steady brightness and the sign does not flicker.
        let lamps = reduceMotion ? ErmineStage(light: 0.4, topLight: 0.4, spotSlot: nil) : stage
        drawHungLamps(context, light: lamps.topLight)
        drawBeam(context)
        drawNeon(context, brightness: lamps.neon)
        drawFloorLamps(context, stage: lamps)
        if !reduceMotion { drawDust(context, motes: dust, beams: hungBeams(light: lamps.topLight) + floorBeams(stage: lamps)) }
        for x in ErmineCast.slotX { drawCrate(context, centerX: x, top: ErmineCast.feetY) }
        drawFloorLight(context, stage: lamps)
        for (member, drawing) in zip(ErmineCast.members, drawings) {
            let x = ErmineCast.slotX[member.slot]
            var c = context
            c.translateBy(x: x, y: ErmineCast.feetY)
            c.scaleBy(x: ErmineCast.stageScale, y: ErmineCast.stageScale)
            drawErmine(c, drawing: drawing, member: member)
        }
    }

    // MARK: Backdrop

    private static let wood = Color(red: 0.55, green: 0.36, blue: 0.19), woodLight = Color(red: 0.68, green: 0.47, blue: 0.27)
    private static let rope = Color(red: 0.78, green: 0.7, blue: 0.55)
    private static let neonPink = Color(red: 1, green: 0.27, blue: 0.68), neonCore = Color(red: 1, green: 0.74, blue: 0.91)
    /// The sign hangs a little crooked, as if the ermines built the stage themselves.
    static let neonTilt = Angle.degrees(-2.5), neonCenter = CGPoint(x: 180, y: 22)

    /// A hand-made wooden beam across the top, with lamps and the sign hung from it by rope.
    static func drawBeam(_ context: GraphicsContext) {
        let beam = Path(roundedRect: CGRect(x: 18, y: -1, width: 324, height: 6), cornerRadius: 1.5)
        context.fill(beam, with: .color(wood))
        context.fill(Path(CGRect(x: 19, y: 0, width: 322, height: 1.8)), with: .color(woodLight))
        var grain = Path()
        for x: CGFloat in [70, 150, 236, 300] { grain.move(to: CGPoint(x: x, y: 1)); grain.addLine(to: CGPoint(x: x + 9, y: 3.5)) }
        context.stroke(grain, with: .color(ErminePalette.ink.opacity(0.35)), lineWidth: 0.6)
        context.stroke(beam, with: .color(ErminePalette.ink), lineWidth: 1)
    }

    /// The band's name in pink neon tubes, hung from the beam. A letter flickers only on a high note.
    static func drawNeon(_ context: GraphicsContext, brightness: [Double]) {
        var c = context
        c.translateBy(x: neonCenter.x, y: neonCenter.y); c.rotate(by: neonTilt)
        let font = Font.system(size: 14, weight: .heavy, design: .rounded)
        let letters = ErmineStage.neonText.map { c.resolve(Text(String($0)).font(font)) }
        let widths = letters.map { $0.measure(in: CGSize(width: 100, height: 100)).width }
        let total = widths.reduce(0, +)
        // Strings to the beam and the tube lines above and below the letters.
        var strings = Path()
        for x in [-total * 0.36, total * 0.36] { strings.move(to: CGPoint(x: x, y: -11)); strings.addLine(to: CGPoint(x: x + 1.5, y: -20)) }
        c.stroke(strings, with: .color(rope.opacity(0.8)), lineWidth: 0.7)
        var tubes = Path()
        tubes.move(to: CGPoint(x: -total / 2 - 2, y: -11)); tubes.addLine(to: CGPoint(x: total / 2 + 2, y: -11.5))
        tubes.move(to: CGPoint(x: -total / 2 - 5, y: 10.5)); tubes.addLine(to: CGPoint(x: total / 2 + 5, y: 10))
        var x = -total / 2
        var centers: [CGFloat] = []
        for w in widths { centers.append(x + w / 2); x += w }
        for (radius, opacity) in [(CGFloat(6), 0.55), (CGFloat(2.5), 0.8)] {
            c.drawLayer { glow in
                glow.addFilter(.blur(radius: radius))
                glow.stroke(tubes, with: .color(neonPink.opacity(opacity)), lineWidth: 2)
                for (i, letter) in ErmineStage.neonText.enumerated() where letter != " " {
                    let level = i < brightness.count ? brightness[i] : 1
                    glow.draw(Text(String(letter)).font(font).foregroundColor(neonPink.opacity(opacity * level)), at: CGPoint(x: centers[i], y: 0))
                }
            }
        }
        c.stroke(tubes, with: .color(neonCore), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        for (i, letter) in ErmineStage.neonText.enumerated() where letter != " " {
            let level = i < brightness.count ? brightness[i] : 1
            // An unlit tube still shows as a dull pink glass letter.
            let color = level > 0.5 ? neonCore : Color(red: 0.45, green: 0.2, blue: 0.33)
            c.draw(Text(String(letter)).font(font).foregroundColor(color), at: CGPoint(x: centers[i], y: 0))
        }
    }

    /// A small can lamp tied to the beam, shining down on the singers with the voice.
    /// A beam of light as a triangle from the lens, fading toward its far end.
    struct Beam {
        var lens: CGPoint, edgeA: CGPoint, edgeB: CGPoint, end: CGPoint
        var strength: Double
        var path: Path { var p = Path(); p.move(to: lens); p.addLine(to: edgeA); p.addLine(to: edgeB); p.closeSubpath(); return p }

        /// How much of this beam lights the point (0…1): full near the lens, fading along the beam, nothing outside it.
        func light(at point: CGPoint) -> Double {
            func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
            let d1 = cross(lens, edgeA, point), d2 = cross(edgeA, edgeB, point), d3 = cross(edgeB, lens, point)
            let inside = !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
            guard inside else { return 0 }
            let along = hypot(point.x - lens.x, point.y - lens.y) / max(1, hypot(end.x - lens.x, end.y - lens.y))
            return strength * max(0, 1 - 0.8 * Double(along))
        }
    }

    static let hungLamps: [(x: CGFloat, target: CGFloat)] = [(40, 150), (320, 210)]
    static func hungBeams(light: Double) -> [Beam] {
        hungLamps.map { x, target in
            Beam(lens: CGPoint(x: x + (target > x ? 3 : -3), y: 16), edgeA: CGPoint(x: target - 38, y: 118), edgeB: CGPoint(x: target + 38, y: 118),
                 end: CGPoint(x: target, y: 118), strength: min(1, max(0, light)))
        }
    }

    static let floorLamps = [CGPoint(x: 14, y: 128), CGPoint(x: 346, y: 128)]
    static func floorBeams(stage: ErmineStage) -> [Beam] {
        let targets: [CGFloat] = stage.spotSlot.map { [ErmineCast.slotX[$0], ErmineCast.slotX[$0]] } ?? [130, 230]
        return zip(floorLamps, targets).map { lamp, targetX in
            let target = CGPoint(x: targetX, y: 52)
            let dx = target.x - lamp.x, dy = target.y - lamp.y, length = max(1, hypot(dx, dy))
            let spread = CGVector(dx: -dy / length * 34, dy: dx / length * 34)
            return Beam(lens: CGPoint(x: lamp.x + dx / length * 6, y: lamp.y + dy / length * 6),
                        edgeA: CGPoint(x: target.x + spread.dx, y: target.y + spread.dy),
                        edgeB: CGPoint(x: target.x - spread.dx, y: target.y - spread.dy), end: target, strength: min(1, max(0, stage.light)))
        }
    }

    /// Dust glitters only where a beam passes through it; it is drawn behind the crates and the ermines,
    /// so it shows against the dark background and inside the beams.
    static func drawDust(_ context: GraphicsContext, motes: [ErmineMote], beams: [Beam]) {
        let speck = Color(red: 1, green: 0.97, blue: 0.9)
        for mote in motes {
            let light = min(1, beams.reduce(0) { $0 + $1.light(at: mote.position) })
            let alpha = light * mote.twinkle
            guard alpha > 0.03 else { continue }
            let r = mote.size / 2
            if alpha > 0.5 { // A glint: a faint halo around the brightest specks.
                context.fill(Path(ellipseIn: CGRect(x: mote.position.x - r * 3, y: mote.position.y - r * 3, width: r * 6, height: r * 6)),
                             with: .color(speck.opacity(0.18 * alpha)))
            }
            context.fill(Path(ellipseIn: CGRect(x: mote.position.x - r, y: mote.position.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(speck.opacity(0.95 * alpha)))
        }
    }

    static func drawHungLamps(_ context: GraphicsContext, light rawLight: Double) {
        let light = min(1, max(0, rawLight))
        for ((x, target), beam) in zip(hungLamps, hungBeams(light: light)) {
            context.fill(beam.path, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.86, blue: 0.6).opacity(0.26 * light), .clear]),
                                                          startPoint: beam.lens, endPoint: beam.end))
            var ropes = Path(); ropes.move(to: CGPoint(x: x, y: 4)); ropes.addLine(to: CGPoint(x: x, y: 8))
            context.stroke(ropes, with: .color(rope), lineWidth: 0.9)
            var lamp = context
            lamp.translateBy(x: x, y: 12); lamp.rotate(by: .degrees(target > x ? -28 : 28))
            let can = Path(roundedRect: CGRect(x: -4.5, y: -4.5, width: 9, height: 10), cornerRadius: 1.5)
            lamp.fill(can, with: .color(Color(red: 0.27, green: 0.26, blue: 0.27)))
            lamp.fill(Path(CGRect(x: -4.5, y: -4.5, width: 3, height: 10)), with: .color(Color(red: 0.4, green: 0.39, blue: 0.4)))
            lamp.stroke(can, with: .color(ErminePalette.ink), lineWidth: 1)
            let face = Path(ellipseIn: CGRect(x: -4, y: 3.5, width: 8, height: 3))
            lamp.fill(face, with: .color(Color(red: 1, green: 0.9, blue: 0.62).opacity(0.45 + 0.55 * light)))
            lamp.stroke(face, with: .color(ErminePalette.ink), lineWidth: 0.8)
        }
    }

    /// Two can lamps (PAR) on short stands at the front corners, lighting the ermines up from below.
    /// The beams brighten on the bass and turn to a soloist.
    static func drawFloorLamps(_ context: GraphicsContext, stage: ErmineStage) {
        let light = min(1, max(0, stage.light))
        let color = Color(red: 0.84, green: 0.92, blue: 1)
        for (lamp, beam) in zip(floorLamps, floorBeams(stage: stage)) {
            context.fill(beam.path, with: .linearGradient(Gradient(colors: [color.opacity(0.34 * light), color.opacity(0)]),
                                                          startPoint: beam.lens, endPoint: beam.end))
            drawParCan(context, at: lamp, angle: atan2(beam.end.y - lamp.y, beam.end.x - lamp.x), light: light)
        }
    }

    /// A stage can lamp: a short stand, a yoke and a can with a glowing lens, inked like the ermines.
    private static func drawParCan(_ context: GraphicsContext, at base: CGPoint, angle: Double, light: Double) {
        let ink = ErminePalette.ink, metal = Color(red: 0.25, green: 0.24, blue: 0.26), metalLight = Color(red: 0.42, green: 0.41, blue: 0.44)
        var stand = Path()
        stand.move(to: CGPoint(x: base.x - 6, y: base.y + 10)); stand.addLine(to: CGPoint(x: base.x + 6, y: base.y + 10))
        stand.move(to: CGPoint(x: base.x, y: base.y + 10)); stand.addLine(to: CGPoint(x: base.x, y: base.y + 2))
        context.stroke(stand, with: .color(ink), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        context.stroke(stand, with: .color(metalLight), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
        var yoke = Path()
        yoke.addArc(center: base, radius: 6.5, startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
        context.stroke(yoke, with: .color(ink), lineWidth: 2.4)
        context.stroke(yoke, with: .color(metalLight), lineWidth: 1)
        var can = context
        can.translateBy(x: base.x, y: base.y); can.rotate(by: .radians(angle))
        let body = Path(roundedRect: CGRect(x: -6, y: -5, width: 13, height: 10), cornerRadius: 2)
        can.fill(body, with: .color(metal))
        can.fill(Path(CGRect(x: -6, y: -5, width: 13, height: 3)), with: .color(metalLight))
        can.stroke(body, with: .color(ink), lineWidth: 1)
        let lens = Path(ellipseIn: CGRect(x: 5.5, y: -5.5, width: 4, height: 11))
        can.drawLayer { glow in
            glow.addFilter(.blur(radius: 3))
            glow.fill(lens, with: .color(Color(red: 0.8, green: 0.9, blue: 1).opacity(0.9 * light)))
        }
        can.fill(lens, with: .color(Color(red: 0.75 + 0.25 * light, green: 0.85 + 0.15 * light, blue: 1)))
        can.stroke(lens, with: .color(ink), lineWidth: 0.9)
    }

    /// Where the floor lamps' beams land on the crates, drawn over the crates and under the ermines.
    static func drawFloorLight(_ context: GraphicsContext, stage: ErmineStage) {
        let light = min(1, max(0, stage.light))
        let targets: [CGFloat] = stage.spotSlot.map { [ErmineCast.slotX[$0]] } ?? [130, 230]
        for x in targets {
            context.fill(Path(ellipseIn: CGRect(x: x - 30, y: 114, width: 60, height: 12)), with: .radialGradient(
                Gradient(colors: [Color(red: 0.86, green: 0.93, blue: 1).opacity((stage.spotSlot == nil ? 0.16 : 0.5) * light), .clear]),
                center: CGPoint(x: x, y: 120), startRadius: 0, endRadius: 30))
        }
    }

    static func drawCrate(_ context: GraphicsContext, centerX: CGFloat, top: CGFloat) {
        let w: CGFloat = 56, h: CGFloat = 18, x = centerX - w / 2
        context.fill(Path(CGRect(x: x, y: top, width: w, height: h)), with: .color(Color(red: 0.54, green: 0.35, blue: 0.18)))
        context.fill(Path(CGRect(x: x + 1, y: top + 1, width: w - 2, height: 5.5)), with: .color(Color(red: 0.66, green: 0.45, blue: 0.25)))
        context.fill(Path(CGRect(x: x + 2, y: top + 1, width: 4, height: h - 2)), with: .color(Color(red: 0.43, green: 0.27, blue: 0.14)))
        context.fill(Path(CGRect(x: x + w - 6, y: top + 1, width: 4, height: h - 2)), with: .color(Color(red: 0.43, green: 0.27, blue: 0.14)))
        var planks = Path()
        for y in [top + 6.5, top + 12] { planks.move(to: CGPoint(x: x + 1, y: y)); planks.addLine(to: CGPoint(x: x + w - 1, y: y)) }
        context.stroke(planks, with: .color(Color(red: 0.29, green: 0.18, blue: 0.09)), lineWidth: 0.8)
        context.stroke(Path(CGRect(x: x + 0.5, y: top + 0.5, width: w - 1, height: h - 1)), with: .color(ErminePalette.ink), lineWidth: 1.2)
    }

    static func drawErmine(_ original: GraphicsContext, drawing: ErmineDrawing, member: ErmineCastMember) {
        var context = original
        let k = drawing.pose
        context.scaleBy(x: member.scale.width, y: member.scale.height)
        if k.lift > 0 { // The shadow stays on the crate while the body is in the air.
            context.fill(Path(ellipseIn: CGRect(x: -(12 - k.lift * 0.3), y: -1.5, width: 2 * (12 - k.lift * 0.3), height: 4)),
                         with: .color(.black.opacity(0.35)))
        }
        context.translateBy(x: 0, y: -k.lift)
        drawBody(context, k, palette: member.palette, features: member.features, wag: drawing.frame.wag)
        drawFace(context, k, face: drawing.frame.face, palette: member.palette, features: member.features)
        drawEffects(context, k, effects: drawing.frame.effects)
    }

    // MARK: Body cel

    private static func sideScale(_ k: ErmineKey) -> (left: CGFloat, right: CGFloat) { (1 + 0.16 * k.turn, 1 - 0.16 * k.turn) }

    static func bodyPath(_ k: ErmineKey) -> Path {
        let nx = k.neck.x, ny = k.neck.y, hipY: CGFloat = -14, (mL, mR) = sideScale(k), hx = k.hipX
        // The receding side narrows a little when the torso turns; the hips turn least.
        let hl = k.hipW * (1 + (mL - 1) * 0.5), hr = k.hipW * (1 + (mR - 1) * 0.5)
        let wl = k.waistW * mL, wr = k.waistW * mR, nl = k.neckW * mL, nr = k.neckW * mR
        let midY = (hipY + ny) / 2 - 4, midX = nx * 0.55 + k.turn * 1.2 + hx * 0.4
        var p = Path()
        p.move(to: CGPoint(x: -hl * 0.82 + hx * 0.5, y: -1))
        p.addCurve(to: CGPoint(x: midX - wl, y: midY), control1: CGPoint(x: -hl - 2.5 + hx, y: hipY + 4), control2: CGPoint(x: -hl - 1 + hx, y: hipY - 8))
        p.addCurve(to: CGPoint(x: nx - nl, y: ny), control1: CGPoint(x: midX - wl + 1, y: midY - 9), control2: CGPoint(x: nx - nl - 1, y: ny + 8))
        p.addLine(to: CGPoint(x: nx - nl, y: ny - 9)); p.addLine(to: CGPoint(x: nx + nr, y: ny - 9)); p.addLine(to: CGPoint(x: nx + nr, y: ny)) // under the head
        p.addCurve(to: CGPoint(x: midX + wr, y: midY), control1: CGPoint(x: nx + nr + 1, y: ny + 8), control2: CGPoint(x: midX + wr - 1, y: midY - 9))
        p.addCurve(to: CGPoint(x: hr * 0.82 + hx * 0.5, y: -1), control1: CGPoint(x: hr + 1 + hx, y: hipY - 8), control2: CGPoint(x: hr + 2.5 + hx, y: hipY + 4))
        p.addQuadCurve(to: CGPoint(x: -hl * 0.82 + hx * 0.5, y: -1), control: CGPoint(x: hx * 0.5, y: 2))
        p.closeSubpath()
        return p
    }

    /// Head: wider than tall, flat on top, cheeks out, chin tucked — an ermine, not a cat or a lion.
    static let headPath: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: -14.5))
        p.addCurve(to: CGPoint(x: 21.5, y: 0.5), control1: CGPoint(x: 13, y: -15.5), control2: CGPoint(x: 21.5, y: -9))
        p.addCurve(to: CGPoint(x: 0, y: 13.5), control1: CGPoint(x: 21.5, y: 9), control2: CGPoint(x: 11, y: 13.5))
        p.addCurve(to: CGPoint(x: -21.5, y: 0.5), control1: CGPoint(x: -11, y: 13.5), control2: CGPoint(x: -21.5, y: 9))
        p.addCurve(to: CGPoint(x: 0, y: -14.5), control1: CGPoint(x: -21.5, y: -9), control2: CGPoint(x: -13, y: -15.5))
        p.closeSubpath()
        return p
    }()

    /// Two-tone cel shading: shade everything, then lay the lit colour offset toward the light.
    private static func celFill(_ context: GraphicsContext, _ path: Path, _ palette: ErminePalette, shift: CGSize, patch: Path? = nil) {
        var c = context
        c.clip(to: path)
        c.fill(path, with: .color(palette.shade))
        c.fill(path.offsetBy(dx: shift.width, dy: shift.height), with: .color(palette.fill))
        if let patch, let belly = palette.belly, let bellyShade = palette.bellyShade {
            c.fill(patch, with: .color(bellyShade))
            c.fill(patch.offsetBy(dx: -1.4, dy: -0.6), with: .color(belly))
        }
        context.stroke(path, with: .color(palette.ink), style: StrokeStyle(lineWidth: palette.line, lineJoin: .round))
    }

    private static func tube(_ context: GraphicsContext, _ points: ArraySlice<CGPoint>, _ color: Color, _ width: CGFloat) {
        guard let first = points.first else { return }
        var p = Path(); p.move(to: first); for q in points.dropFirst() { p.addLine(to: q) }
        context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private static func bezier(_ c: [CGPoint], _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, d = 3 * u * t * t, e = t * t * t
        return CGPoint(x: a * c[0].x + b * c[1].x + d * c[2].x + e * c[3].x, y: a * c[0].y + b * c[1].y + d * c[2].y + e * c[3].y)
    }

    private static func drawTail(_ context: GraphicsContext, _ k: ErmineKey, _ palette: ErminePalette, wag: CGFloat, side: CGFloat) {
        let hipShare: [CGFloat] = [1, 1, 0.6, 0.4], wagShare: [CGFloat] = [0, 2, 6, 8]
        let c = (0..<4).map { CGPoint(x: side * (k.tail[$0].x + wag * wagShare[$0]) + k.hipX * hipShare[$0], y: k.tail[$0].y) }
        let points = (0...24).map { bezier(c, CGFloat($0) / 24) }, cut = 16
        tube(context, points[...], palette.ink, 6.4 + palette.line * 2)
        tube(context, points[0...cut], palette.fill, 6.4)
        tube(context, points[1..<cut], palette.shade, 2.2)
        tube(context, points[cut...], palette.tip, 6.4)
        tube(context, points[(cut + 1)..<(points.count - 2)], palette.tipHighlight, 1.6)
    }

    /// A front leg grows from the shoulder on the body outline, bends slightly like an elbow,
    /// keeps its width for a while and then narrows quickly into a small round paw.
    /// The root has no ink, so the outer edge reads as a continuation of the body outline.
    static func legPaths(edge: CGPoint, paw: CGPoint, side: CGFloat, tipRadius r1: CGFloat, elbow: CGFloat) -> (fill: Path, ink: Path) {
        let r0: CGFloat = 3.6, n = 16
        let s = CGPoint(x: edge.x - side * r0, y: edge.y)
        let cp = CGPoint(x: s.x + side * elbow, y: s.y + (paw.y - s.y) * 0.55)
        func at(_ t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(x: u * u * s.x + 2 * u * t * cp.x + t * t * paw.x, y: u * u * s.y + 2 * u * t * cp.y + t * t * paw.y)
        }
        func tangent(_ t: CGFloat) -> CGVector {
            let x = 2 * (1 - t) * (cp.x - s.x) + 2 * t * (paw.x - cp.x), y = 2 * (1 - t) * (cp.y - s.y) + 2 * t * (paw.y - cp.y)
            let l = max(hypot(x, y), 1e-6); return CGVector(dx: x / l, dy: y / l)
        }
        let f: CGFloat = tangent(0).dy >= 0 ? 1 : -1 // keep "outer" on the outside for raised legs too
        func width(_ t: CGFloat) -> CGFloat { r1 + (r0 - r1) * (1 - pow(t, 2.4)) } // slow at first, then a quick taper
        var outer: [CGPoint] = [], inner: [CGPoint] = []
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n), q = at(t), d = tangent(t), w = width(t)
            let o = CGVector(dx: f * side * d.dy, dy: -f * side * d.dx)
            outer.append(CGPoint(x: q.x + o.dx * w, y: q.y + o.dy * w)); inner.append(CGPoint(x: q.x - o.dx * w, y: q.y - o.dy * w))
        }
        let d = tangent(1)
        let a1 = atan2(-f * side * d.dx, f * side * d.dy), a2 = a1 + .pi
        let tipward = atan2(d.dy, d.dx)
        let turnToTip = ((tipward - a1).truncatingRemainder(dividingBy: 2 * .pi) + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        let clockwise = turnToTip < .pi // the cap goes around the tip side
        var fill = Path(); fill.move(to: outer[0]); for q in outer.dropFirst() { fill.addLine(to: q) }
        // In y-down space SwiftUI's `clockwise: false` sweeps increasing angles, so pass the opposite flag.
        fill.addArc(center: paw, radius: r1, startAngle: .radians(a1), endAngle: .radians(a2), clockwise: !clockwise)
        for q in inner.reversed() { fill.addLine(to: q) }
        fill.closeSubpath()
        var ink = Path(); ink.move(to: outer[0]); for q in outer.dropFirst() { ink.addLine(to: q) }
        ink.addArc(center: paw, radius: r1, startAngle: .radians(a1), endAngle: .radians(a2), clockwise: !clockwise)
        for i in stride(from: n, through: Int((CGFloat(n) * 0.55).rounded()), by: -1) { ink.addLine(to: inner[i]) }
        return (fill, ink)
    }

    static func drawBody(_ context: GraphicsContext, _ k: ErmineKey, palette: ErminePalette, features: ErmineFeatures, wag: CGFloat) {
        if !k.back { drawTail(context, k, palette, wag: wag, side: features.tailSide) }
        for s: CGFloat in [-1, 1] {
            celFill(context, Path(ellipseIn: CGRect(x: s * 7.5 - 6.2, y: -5.2, width: 12.4, height: 6.4)), palette, shift: CGSize(width: -1, height: -1))
        }
        var belly: Path?
        if palette.belly != nil && !k.back {
            let ry = (-k.neck.y - 14) / 2 + 7, rx = k.waistW * 0.62
            let center = CGPoint(x: k.neck.x * 0.6 + k.turn * 2 + k.hipX * 0.3, y: (k.neck.y - 14) / 2 + 3)
            belly = Path(ellipseIn: CGRect(x: center.x - rx, y: center.y - ry, width: 2 * rx, height: 2 * ry))
        }
        celFill(context, bodyPath(k), palette, shift: CGSize(width: -2.6 - 1.6 * k.turn, height: -1.4), patch: belly)
        // Raised legs (jump, flex) pass behind the head; legs held at the chest are in front of it.
        let scales = sideScale(k)
        func legs() {
            for (side, paw, shoulder, elbow, scale) in [(CGFloat(-1), k.pawL, k.shoulderL, k.elbowL, scales.left),
                                                        (CGFloat(1), k.pawR, k.shoulderR, k.elbowR, scales.right)] {
                let edge = CGPoint(x: k.neck.x + side * (k.neckW * scale + 0.4), y: k.neck.y + 5 + shoulder)
                let smeared = side > 0 && k.smearRight
                if smeared { // Smear frame: speed lines trail the leg.
                    var lines = Path()
                    for o: CGFloat in [-3.5, 0, 3.5] {
                        lines.move(to: CGPoint(x: edge.x + 2, y: edge.y + o + 4)); lines.addLine(to: CGPoint(x: paw.x - 6, y: paw.y + o + 2))
                    }
                    context.stroke(lines, with: .color(palette.ink.opacity(0.6)), lineWidth: 0.8)
                }
                let leg = legPaths(edge: edge, paw: paw, side: side, tipRadius: smeared ? 1.5 : 1.9, elbow: elbow)
                if k.pointing == side { // A little pointing digit beyond the paw.
                    let dx = paw.x - edge.x, dy = paw.y - edge.y, l = max(1, hypot(dx, dy))
                    var digit = Path(); digit.move(to: paw); digit.addLine(to: CGPoint(x: paw.x + dx / l * 4.5, y: paw.y + dy / l * 4.5))
                    context.stroke(digit, with: .color(palette.ink), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    context.stroke(digit, with: .color(palette.fill), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                }
                context.fill(leg.fill, with: .color(palette.fill)) // same paint as the body, so the root disappears into it
                context.stroke(leg.ink, with: .color(palette.ink), style: StrokeStyle(lineWidth: palette.line * 0.9, lineCap: .round, lineJoin: .round))
            }
        }
        if k.armsBehind && !k.back { legs() }
        var head = context
        head.translateBy(x: k.head.x, y: k.head.y); head.rotate(by: .degrees(Double(k.rot))); head.scaleBy(x: k.headScale.width, y: k.headScale.height)
        for s: CGFloat in [-1, 1] {
            celFill(head, Path(ellipseIn: CGRect(x: s * 14.5 - 5.2, y: -16.7, width: 10.4, height: 10.4)), palette, shift: CGSize(width: -1, height: -1))
            if !k.back { head.fill(Path(ellipseIn: CGRect(x: s * 14.5 - 2.6, y: -13.6, width: 5.2, height: 5.2)), with: .color(palette.earInside)) }
        }
        var face: Path?
        if palette.belly != nil && !k.back { face = Path(ellipseIn: CGRect(x: k.turn * 3 - 14, y: -0.5, width: 28, height: 16)) }
        celFill(head, headPath, palette, shift: CGSize(width: -2, height: -2.4), patch: face)
        if features.flower { drawFlower(head, at: CGPoint(x: k.back ? -15 : 15, y: -9)) }
        if k.back { drawTail(context, k, palette, wag: wag, side: features.tailSide); return } // seen from behind
        if !k.armsBehind { legs() }
    }

    private static func drawFlower(_ context: GraphicsContext, at center: CGPoint) {
        for i in 0..<5 {
            let a = Double(i) * 2 * .pi / 5
            let petal = Path(ellipseIn: CGRect(x: center.x + 2.4 * cos(a) - 1.9, y: center.y + 2.4 * sin(a) - 1.9, width: 3.8, height: 3.8))
            context.fill(petal, with: .color(Color(red: 1, green: 0.62, blue: 0.72))); context.stroke(petal, with: .color(ErminePalette.ink), lineWidth: 0.7)
        }
        let heart = Path(ellipseIn: CGRect(x: center.x - 1.4, y: center.y - 1.4, width: 2.8, height: 2.8))
        context.fill(heart, with: .color(Color(red: 1, green: 0.89, blue: 0.48))); context.stroke(heart, with: .color(ErminePalette.ink), lineWidth: 0.7)
    }

    // MARK: Face cel

    static func drawFace(_ original: GraphicsContext, _ k: ErmineKey, face: ErmineFace, palette: ErminePalette, features: ErmineFeatures) {
        guard !k.back else { return }
        var c = original
        c.translateBy(x: k.head.x, y: k.head.y); c.rotate(by: .degrees(Double(k.rot))); c.scaleBy(x: k.headScale.width, y: k.headScale.height)
        let turn = k.turn
        let sign: CGFloat = turn < 0 ? -1 : 1
        c.translateBy(x: turn * 3 + sign * max(0, abs(turn) - 0.5) * 12, y: 0) // the face turns with the torso
        let far: CGFloat = abs(turn) > 0.7 ? sign : 0 // in a three-quarter view the far eye is hidden
        let sides: [CGFloat] = [-1, 1].filter { $0 != far }
        if face.blush > 0 { // Manga hatching, more lines when straining.
            var hatch = Path()
            for s in sides {
                for i in 0..<face.blush {
                    let x = s * 14 + (CGFloat(i) - CGFloat(face.blush - 1) / 2) * 2.2
                    hatch.move(to: CGPoint(x: x - 0.9, y: 6.2)); hatch.addLine(to: CGPoint(x: x + 0.9, y: 3.4))
                }
            }
            c.stroke(hatch, with: .color(palette.blush), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
        }
        let look = k.look * 1.6
        let eyeLine = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
        for s in sides {
            let ex = s * 10.5 + look
            var eye = face.eye
            if case let .wink(side) = face.eye { eye = s == side ? .happy : .open } // the eye over the pointing hand closes
            switch eye {
            case .open, .surprise:
                let (rx, ry): (CGFloat, CGFloat) = eye == .surprise ? (2.6, 2.8) : (2.9, 2.3)
                c.fill(Path(ellipseIn: CGRect(x: ex - rx, y: -ry, width: 2 * rx, height: 2 * ry)), with: .color(palette.eye))
                c.fill(Path(ellipseIn: CGRect(x: ex + 0.9 - 0.85, y: -0.8 - 0.85, width: 1.7, height: 1.7)), with: .color(.white))
                if features.sparkle { c.fill(Path(ellipseIn: CGRect(x: ex - 1.5, y: 0.4, width: 1, height: 1)), with: .color(.white)) }
                if features.lashes {
                    var lashes = Path()
                    lashes.move(to: CGPoint(x: ex + s * 2.6, y: -1.2)); lashes.addLine(to: CGPoint(x: ex + s * 4.3, y: -2.4))
                    lashes.move(to: CGPoint(x: ex + s * 2.9, y: -0.2)); lashes.addLine(to: CGPoint(x: ex + s * 4.6, y: -0.8))
                    c.stroke(lashes, with: .color(palette.eye), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
                }
            case .half:
                c.fill(Path(ellipseIn: CGRect(x: ex - 2.9, y: -0.6, width: 5.8, height: 2.4)), with: .color(palette.eye))
                var lid = Path(); lid.move(to: CGPoint(x: ex - 3.4, y: -0.4)); lid.addLine(to: CGPoint(x: ex + 3.4, y: -0.4))
                c.stroke(lid, with: .color(palette.eye), style: eyeLine)
            case .closed:
                var p = Path(); p.move(to: CGPoint(x: ex - 3, y: 0)); p.addQuadCurve(to: CGPoint(x: ex + 3, y: 0), control: CGPoint(x: ex, y: 1.6))
                c.stroke(p, with: .color(palette.eye), style: eyeLine)
            case .happy:
                var p = Path(); p.move(to: CGPoint(x: ex - 3, y: 1)); p.addQuadCurve(to: CGPoint(x: ex + 3, y: 1), control: CGPoint(x: ex, y: -2.4))
                c.stroke(p, with: .color(palette.eye), style: eyeLine)
            case .squeeze:
                let d = -s
                var p = Path(); p.move(to: CGPoint(x: ex - d * 2.8, y: -2.4)); p.addLine(to: CGPoint(x: ex + d * 2.2, y: 0)); p.addLine(to: CGPoint(x: ex - d * 2.8, y: 2.4))
                c.stroke(p, with: .color(palette.eye), style: eyeLine)
            case .wink: break
            }
        }
        if features.thickBrows || face.troubledBrows { // Thick for the strongman, raised inner ends when troubled.
            for s in sides {
                let ex = s * 10.5 + look
                var p = Path()
                if face.troubledBrows {
                    p.move(to: CGPoint(x: ex - s * 3, y: -6.5)); p.addLine(to: CGPoint(x: ex + s * 2.6, y: -4.6))
                    c.stroke(p, with: .color(palette.eye), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                } else {
                    p.move(to: CGPoint(x: ex - s * 3.2, y: -5.2)); p.addLine(to: CGPoint(x: ex + s * 2.8, y: -5.8))
                    c.stroke(p, with: .color(palette.eye), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                }
            }
        }
        if features.glasses { // Round black rims; sometimes the lenses flash white.
            let rims = sides.map { s in Path(ellipseIn: CGRect(x: s * 10.5 + look * 0.6 - 5, y: -4.4, width: 10, height: 8.8)) }
            if face.glint {
                for (s, rim) in zip(sides, rims) {
                    c.fill(rim, with: .color(.white))
                    let cx = s * 10.5 + look * 0.6
                    var shine = Path(); shine.move(to: CGPoint(x: cx - 2.6, y: 2)); shine.addLine(to: CGPoint(x: cx + 1, y: -2.4))
                    c.stroke(shine, with: .color(Color(red: 0.81, green: 0.89, blue: 1)), lineWidth: 1)
                }
            }
            for rim in rims { c.stroke(rim, with: .color(palette.eye), lineWidth: 1.3) }
            if far == 0 {
                var bridge = Path(); bridge.move(to: CGPoint(x: -5.5, y: -0.8)); bridge.addQuadCurve(to: CGPoint(x: 5.5, y: -0.8), control: CGPoint(x: 0, y: -2.4))
                c.stroke(bridge, with: .color(palette.eye), lineWidth: 1.3)
            }
        }
        let nose = Path(ellipseIn: CGRect(x: -2, y: 3.25, width: 4, height: 2.7))
        c.fill(nose, with: .color(palette.nose)); c.stroke(nose, with: .color(palette.ink), lineWidth: 0.7)
        drawMouth(c, face.mouth, palette)
        if let sweat = face.sweat { drawSweat(c, sweat) }
    }

    private static let mouthInside = Color(red: 0.48, green: 0.15, blue: 0.2), tongue = Color(red: 0.94, green: 0.55, blue: 0.61)

    private static func drawMouth(_ c: GraphicsContext, _ mouth: ErmineMouth, _ palette: ErminePalette) {
        let ink = StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round)
        switch mouth {
        case .round:
            let o = Path(ellipseIn: CGRect(x: -1.5, y: 6.2, width: 3, height: 3.6))
            c.fill(o, with: .color(mouthInside)); c.stroke(o, with: .color(palette.ink), style: ink)
        case .closed:
            var p = Path(); p.move(to: CGPoint(x: -2.4, y: 6.8))
            p.addQuadCurve(to: CGPoint(x: 0, y: 6.6), control: CGPoint(x: -1.2, y: 8.4)); p.addQuadCurve(to: CGPoint(x: 2.4, y: 6.8), control: CGPoint(x: 1.2, y: 8.4))
            c.stroke(p, with: .color(palette.ink), style: ink)
        case .small, .medium, .large:
            let (w, h): (CGFloat, CGFloat) = mouth == .small ? (1.5, 1.5) : mouth == .medium ? (2.3, 2.8) : (3.1, 4.4)
            let top: CGFloat = 6.3
            var p = Path(); p.move(to: CGPoint(x: -w, y: top)); p.addLine(to: CGPoint(x: w, y: top))
            p.addCurve(to: CGPoint(x: -w, y: top), control1: CGPoint(x: w, y: top + h * 1.2), control2: CGPoint(x: -w, y: top + h * 1.2)); p.closeSubpath()
            c.fill(p, with: .color(mouthInside)); c.stroke(p, with: .color(palette.ink), style: ink)
            if mouth != .small {
                c.fill(Path(ellipseIn: CGRect(x: -w * 0.55, y: top + h * 0.7 - h * 0.18, width: w * 1.1, height: h * 0.36)), with: .color(tongue))
            }
        }
    }

    /// Manga sweat drops flying off the head; three drawings cycled.
    private static func drawSweat(_ c: GraphicsContext, _ index: Int) {
        let sets: [[(CGFloat, CGFloat, Double)]] = [[(-24, -8, -0.5), (23, -12, 0.4)], [(-27, -12, -0.7), (26, -6, 0.6), (20, -17, 0.3)],
                                                     [(-22, -15, -0.4), (28, -10, 0.7)]]
        for (x, y, r) in sets[index % 3] {
            var d = c; d.translateBy(x: x, y: y); d.rotate(by: .radians(r))
            var p = Path(); p.move(to: CGPoint(x: 0, y: -3.6))
            p.addQuadCurve(to: CGPoint(x: 0, y: 2.2), control: CGPoint(x: 2.6, y: 0)); p.addQuadCurve(to: CGPoint(x: 0, y: -3.6), control: CGPoint(x: -2.6, y: 0))
            d.fill(p, with: .color(Color(red: 0.85, green: 0.94, blue: 1))); d.stroke(p, with: .color(ErminePalette.ink), lineWidth: 0.8)
        }
    }

    // MARK: Effect cel

    private static func outlinedText(_ c: GraphicsContext, _ string: String, at point: CGPoint, size: CGFloat, fill: Color, bold: Bool = false) {
        let font = Font.system(size: size, weight: bold ? .heavy : .regular, design: .rounded)
        for (dx, dy) in [(-1.0, 0.0), (1, 0), (0, -1), (0, 1), (-0.7, -0.7), (0.7, -0.7), (-0.7, 0.7), (0.7, 0.7)] {
            c.draw(Text(string).font(font).foregroundColor(ErminePalette.ink), at: CGPoint(x: point.x + dx, y: point.y + dy))
        }
        c.draw(Text(string).font(font).foregroundColor(fill), at: point)
    }

    static func drawEffects(_ context: GraphicsContext, _ k: ErmineKey, effects: ErmineEffects) {
        if let shake = effects.shake { // Vibration marks beside the body, alternating with the tremble drawings.
            let y = k.neck.y + 10, o: CGFloat = shake % 2 == 1 ? 1.2 : 0
            var marks = Path()
            for s: CGFloat in [-1, 1] {
                for dy: CGFloat in [-4, 2] {
                    let center = CGPoint(x: s * (17 + o), y: y + dy)
                    let start: Angle = s < 0 ? .radians(.pi * 0.7) : .radians(-.pi * 0.3)
                    let end: Angle = s < 0 ? .radians(.pi * 1.3) : .radians(.pi * 0.3)
                    marks.move(to: CGPoint(x: center.x + 3 * cos(start.radians), y: center.y + 3 * sin(start.radians)))
                    marks.addArc(center: center, radius: 3, startAngle: start, endAngle: end, clockwise: false)
                }
            }
            context.stroke(marks, with: .color(Color(red: 0.91, green: 0.89, blue: 0.85)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
        }
        for note in effects.notes {
            outlinedText(context, note.glyph, at: note.position, size: note.size, fill: Color(red: 1, green: 0.88, blue: 0.54))
        }
    }
}
