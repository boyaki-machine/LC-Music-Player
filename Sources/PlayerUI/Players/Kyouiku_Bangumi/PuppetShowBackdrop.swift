import Foundation

/// The paper-craft scenery behind the puppets. Layers from the back: sky → moving things (stars, sun, moon,
/// clouds, birds, an airplane) → the land. A day lasts six minutes of playback and the land slides once
/// around it; nothing advances while stopped. Coordinates are stage points (360×144, y down).
enum PuppetBackdrop {
    static let width = 360.0, height = 144.0
    static let daySeconds = 360.0
    static let landHeight = 108.0
    /// Morning, noon, evening and night are centered here in the day (0…1).
    static let timeKeys = [0.0, 0.25, 0.5, 0.75]
    /// The sky's colors at the top and the horizon, left · center · right, picked from the four reference pictures.
    static let sky: [[[SIMD3<Double>]]] = [
        [[SIMD3(124, 192, 250), SIMD3(123, 193, 249), SIMD3(118, 191, 249)], [SIMD3(139, 198, 248), SIMD3(171, 212, 238), SIMD3(129, 199, 248)]],
        [[SIMD3(68, 152, 227), SIMD3(62, 141, 217), SIMD3(49, 114, 188)], [SIMD3(67, 150, 225), SIMD3(112, 164, 211), SIMD3(49, 113, 185)]],
        [[SIMD3(228, 173, 114), SIMD3(199, 100, 63), SIMD3(120, 48, 67)], [SIMD3(231, 184, 127), SIMD3(187, 104, 72), SIMD3(120, 48, 65)]],
        [[SIMD3(18, 15, 47), SIMD3(24, 22, 57), SIMD3(18, 15, 47)], [SIMD3(20, 18, 50), SIMD3(74, 74, 115), SIMD3(18, 15, 47)]],
    ]
    /// The light cast on the puppets at each time of day (linear).
    static let light = [SIMD3(1, 0.97, 0.97), SIMD3(1, 1, 1), SIMD3(1, 0.82, 0.7), SIMD3(0.55, 0.6, 0.82)]
    static let cloudTint = [SIMD3(255.0, 236, 238), SIMD3(255, 255, 255), SIMD3(255, 204, 170), SIMD3(74, 84, 118)]
    /// Clouds from the back (small and slow) to the front. `shape` indexes `cloudPictures`.
    static let clouds: [(x: Double, y: Double, width: Double, speed: Double, shape: Int)] = [
        (330, 34, 26, 1.0, 3), (150, 28, 34, 1.5, 1), (30, 14, 46, 2.1, 0), (250, 8, 56, 2.7, 2),
    ]
    static let cloudPictures = ["cloud-pink-long", "cloud-pink", "cloud-white", "cloud-dark"]
    static let landPictures = ["land-morning", "land-noon", "land-evening", "land-night"]
    /// The x of the landmarks (Mt. Fuji's peak and the campfire) in each land picture. Each picture is stretched
    /// piecewise so its landmarks meet the noon picture's, and the four can cross-fade.
    static let landMarks: [(Double, Double)] = [(1591, 3419), (1719, 3396), (1821, 3370), (1708, 3394)]
    static let landPictureSize = (width: 3676.0, height: 656.0)
    /// The share of the picture's width overlapped at the seam so the land repeats sideways.
    static let seamRatio = 0.13
    static var landSeam: Double { (landPictureSize.width * seamRatio).rounded() }
    static var landPeriod: Double { landPictureSize.width - landSeam }
    static var landTileWidth: Double { landPeriod * landHeight / landPictureSize.height }

    static let stars: [(x: Double, y: Double, size: Double, phase: Double, rate: Double)] = {
        var r = PuppetRandom(seed: 5)
        return (0..<55).map { _ in
            (r.next() * width, r.next() * height * 0.62, 0.4 + r.next() * 0.9, r.next() * 6.28, 0.6 + r.next() * 2.2)
        }
    }()

    /// How much of morning, noon, evening and night is in the time `t` (0…1); they add up to 1.
    static func weights(_ t: Double) -> [Double] {
        let w = timeKeys.map { c -> Double in
            var d = abs(t - c); d = min(d, 1 - d)
            return PuppetMath.smoothstep(0.17, 0.08, d)
        }
        let s = w.reduce(0, +)
        return w.map { $0 / (s > 0 ? s : 1) }
    }

    static func mix(_ colors: [SIMD3<Double>], _ w: [Double]) -> SIMD3<Double> {
        zip(colors, w).reduce(SIMD3(0, 0, 0)) { $0 + $1.0 * $1.1 }
    }

    static let synodicMonth = 29.530588853
    /// The moon's age in days (0 new, about 14.8 full) at a date.
    static func moonAge(at date: Date) -> Double {
        let days = date.timeIntervalSince1970 / 86400 - 10962.76
        let m = days.truncatingRemainder(dividingBy: synodicMonth)
        return m < 0 ? m + synodicMonth : m
    }

    /// The arc of the sun and the moon, continued below the horizon so they set behind the land.
    static func arc(_ u: Double) -> (x: Double, y: Double) {
        (PuppetMath.lerp(-6, width + 6, u), 118 - sin(.pi * u) * 106)
    }

    /// How far along its arc the sun is at `tod` (0 rising, 1 set), or nil while it is down.
    static func sunArc(_ tod: Double) -> Double? {
        let u = (tod + 0.16).truncatingRemainder(dividingBy: 1) / 0.82
        return u >= 0 && u <= 1 ? u : nil
    }
    /// The same for the moon.
    static func moonArc(_ tod: Double) -> Double? {
        let u = (tod - 0.5 + 1).truncatingRemainder(dividingBy: 1) / 0.62
        return u >= 0 && u <= 1 ? u : nil
    }
    /// The moon is not seen around the new moon.
    static func moonShows(age: Double) -> Bool { cos(2 * .pi * age / synodicMonth) <= 0.97 }

    enum Layer: Equatable {
        /// Colors at the top and horizon (left, center, right), 0…255.
        case sky(top: [SIMD3<Double>], horizon: [SIMD3<Double>])
        /// A star's glow (additive), with a cross of thin lines when it is large.
        case glint(x: Double, y: Double, radius: Double, alpha: Double)
        /// A shooting star's tail from `from` to `to` (additive).
        case streak(from: SIMD2<Double>, to: SIMD2<Double>, alpha: Double)
        /// A picture. `multiply` tints it like the mock's multiply-then-mask; `flip` mirrors it horizontally.
        case picture(name: String, frame: CGRectValue, alpha: Double, multiply: SIMD3<Double>?, flip: Bool)
        /// A soft round glow of a color (normal blending).
        case halo(x: Double, y: Double, radius: Double, color: SIMD3<Double>, alpha: Double)
        case moon(x: Double, y: Double, radius: Double, age: Double, alpha: Double)
        /// A rainbow's arc around (x, y) with its outer edge at `radius`, drawn from the left up to the angle `reveal`
        /// (radians, 0 at the left, π at the right).
        case rainbow(x: Double, y: Double, radius: Double, width: Double, reveal: Double, alpha: Double)
        /// A cloud tinted for the time of day, with its paper shadow.
        case cloud(shape: Int, frame: CGRectValue, tint: SIMD3<Double>, shadowAlpha: Double)
        /// One of the four land pictures at an opacity; tiles start at `offset` and repeat every `landTileWidth`.
        case land(index: Int, offset: Double, alpha: Double)
    }

    /// A rectangle in stage points (kept free of CoreGraphics so the layout is plain data).
    struct CGRectValue: Equatable { var x, y, width, height: Double }

    /// Everything drawn behind the puppets at time of day `tod` (0…1) after `time` seconds of playback.
    static func layers(tod: Double, time: Double, moonAge: Double, reduceMotion: Bool = false, event: PuppetSkyEvent? = nil) -> [Layer] {
        let w = weights(tod)
        var out: [Layer] = [.sky(top: (0..<3).map { c in mix(sky.map { $0[0][c] }, w) },
                                 horizon: (0..<3).map { c in mix(sky.map { $0[1][c] }, w) })]
        let night = w[3]
        if night > 0.01 {
            // Stars glow small and quietly; now and then one twinkles.
            for s in stars {
                let twinkle = reduceMotion ? 0 : pow((1 + sin(time * s.rate * 0.35 + s.phase)) / 2, 40)
                let alpha = night * (0.35 + 0.65 * twinkle)
                if alpha >= 0.02 { out.append(.glint(x: s.x, y: s.y, radius: s.size * (0.45 + 0.9 * twinkle), alpha: alpha)) }
            }
            if !reduceMotion {
                // A shooting star with a short tail, sometimes.
                let slot = Int((time / 7).rounded(.down)), u = time.truncatingRemainder(dividingBy: 7) / 0.9
                if PuppetRandom.hash(slot) < 0.5 && u < 1 {
                    let x0 = 40 + PuppetRandom.hash(slot + 1) * 260, y0 = 6 + PuppetRandom.hash(slot + 2) * 20
                    let dir = PuppetRandom.hash(slot + 3) < 0.5 ? 1.0 : -1.0
                    let hx = x0 + dir * 46 * u, hy = y0 + 22 * u, a = night * sin(.pi * min(1, u * 1.2))
                    out.append(.streak(from: SIMD2(hx - dir * 16, hy - 7.6), to: SIMD2(hx, hy), alpha: a))
                    out.append(.glint(x: hx, y: hy, radius: 1.1, alpha: a))
                }
                // A comet, rarely and slowly, from left to right.
                let cs = Int((time / 40).rounded(.down)), cu = time.truncatingRemainder(dividingBy: 40) / 14
                if PuppetRandom.hash(cs + 99) < 0.4 && cu < 1 {
                    out.append(.picture(name: "comet", frame: CGRectValue(x: PuppetMath.lerp(60, 160, cu), y: PuppetMath.lerp(16, 30, cu),
                                                                         width: 24, height: 24 * 142 / 208),
                                        alpha: night * sin(cu * .pi) * 0.95, multiply: nil, flip: true))
                }
            }
        }
        // The sun is redder and darker the lower it is, and tints the sky around it near the horizon.
        if let sunU = sunArc(tod) {
            let (x, y) = arc(sunU), low = PuppetMath.smoothstep(40, 100, y), size = 24 + 6 * low
            if low > 0.01 { out.append(.halo(x: x, y: y, radius: 70, color: SIMD3(255, 120, 60), alpha: 0.35 * low)) }
            let tint = SIMD3(255, PuppetMath.lerp(255, 120, low), PuppetMath.lerp(255, 80, low)) * (1 - 0.3 * low)
            out.append(.picture(name: "sun", frame: CGRectValue(x: x - size / 2, y: y - size / 2, width: size, height: size * 218 / 234),
                                alpha: 1, multiply: tint, flip: false))
        }
        if let moonU = moonArc(tod) {
            let (x, y) = arc(moonU)
            let alpha = PuppetMath.clamp(w[3] + w[2] * 0.6 + w[0] * 0.3)
            if moonShows(age: moonAge) {
                out.append(.moon(x: x, y: y, radius: 8, age: moonAge, alpha: alpha))
            }
        }
        if let event { out += event.layers(reduceMotion: reduceMotion) }
        // Clouds keep one shape each and take the time of day's color, casting a paper shadow.
        let tint = mix(cloudTint, w)
        for c in clouds {
            let x = (c.x + time * c.speed).truncatingRemainder(dividingBy: width + 80) - 60
            let size = cloudSizes[c.shape]
            out.append(.cloud(shape: c.shape, frame: CGRectValue(x: x, y: c.y, width: c.width, height: c.width * size.1 / size.0),
                              tint: tint, shadowAlpha: 0.22 + 0.2 * w[3]))
        }
        // Birds and an airplane cross now and then in the daytime.
        let day = w[0] + w[1]
        let bs = Int((time / 30).rounded(.down)), bu = time.truncatingRemainder(dividingBy: 30) / 16
        if day > 0.05 && PuppetRandom.hash(bs + 3) < 0.7 && bu < 1 {
            let by = 26 + PuppetRandom.hash(bs + 4) * 16 + sin(time * 5) * 1.2
            out.append(.picture(name: "birds", frame: CGRectValue(x: PuppetMath.lerp(-20, width + 10, bu), y: by, width: 13, height: 13 * 338 / 330),
                                alpha: day, multiply: nil, flip: false))
        }
        let ps = Int((time / 55).rounded(.down)), pu = time.truncatingRemainder(dividingBy: 55) / 30
        if day > 0.05 && PuppetRandom.hash(ps + 8) < 0.6 && pu < 1 {
            out.append(.picture(name: "airplane", frame: CGRectValue(x: PuppetMath.lerp(-20, width + 10, pu), y: 14, width: 15, height: 15 * 340 / 452),
                                alpha: day, multiply: nil, flip: false))
        }
        // The land: the four times of day laid over each other, sliding once around in a day.
        let tile = landTileWidth, offset = (tod * tile).truncatingRemainder(dividingBy: tile)
        for (i, weight) in w.enumerated() where weight >= 0.005 { out.append(.land(index: i, offset: offset, alpha: weight)) }
        return out
    }

    /// The pixel sizes of the cloud pictures, in `cloudPictures` order.
    static let cloudSizes: [(Double, Double)] = [(482, 148), (390, 180), (330, 170), (428, 134)]
}
