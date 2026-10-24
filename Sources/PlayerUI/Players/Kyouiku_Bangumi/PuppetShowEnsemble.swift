import Foundation

/// The conductor: decides where the four look and how they play off each other.
/// - The spiky-haired boy often looks at the boy with glasses, who sometimes looks back.
/// - The ponytail girl glances at the boy with glasses; when their eyes meet she looks away, blushing, her eyes glowing pink.
/// - The twin-tailed girl watches the two boys; when one notices, she closes her eyes, blushes and trembles.
/// - The two girls sometimes share the same choreography at the start of a phrase.
struct PuppetEnsemble: Sendable {
    private var random = PuppetRandom(seed: 4)
    private var next = (spiky: 4.0, pony: 3.0, twin: 6.0)
    private var lastPhrase = -1
    private var ponyPending: (at: Double, meet: Bool)?
    private var twinShyAt: Double?
    /// The latest exchanges, newest first, for tests and inspection.
    private(set) var log: [String] = []

    private static let twin = PuppetMember.index("twin"), spiky = PuppetMember.index("spiky")
    private static let glasses = PuppetMember.index("glasses"), pony = PuppetMember.index("pony")

    /// The facing from `a` toward `b`: positive to the right, a little more for someone farther away.
    static func toward(_ a: Int, _ b: Int, _ k: Double = 1.3) -> Double {
        let d = b - a
        return Double(d.signum()) * k * (abs(d) > 1 ? 1.25 : 1)
    }

    private static func free(_ d: PuppetDirector, _ now: Double) -> Bool {
        !(now < d.lookingUntil) && d.actions.shout <= 0 && d.actions.headbang <= 0 && d.actions.shy <= 0 && d.actions.slump <= 0
    }

    private mutating func say(_ now: Double, _ message: String) {
        log.insert(String(format: "%.1fs ", now) + message, at: 0)
        if log.count > 4 { log.removeLast(log.count - 4) }
    }

    mutating func update(_ d: inout [PuppetDirector], now: Double) {
        let (twin, spiky, glasses, pony) = (Self.twin, Self.spiky, Self.glasses, Self.pony)
        if now > next.spiky {
            next.spiky = now + 6 + random.next() * 5
            if Self.free(d[spiky], now) {
                d[spiky].look = (Self.toward(spiky, glasses), now + 1.6 + random.next())
                if Self.free(d[glasses], now) && random.next() < 0.4 {
                    d[glasses].look = (Self.toward(glasses, spiky), now + 1.4)
                    say(now, "ツンツン髪とメガネくんが目を合わせる")
                } else { say(now, "ツンツン髪がメガネくんを見る") }
            }
        }
        if now > next.pony {
            next.pony = now + 5 + random.next() * 4
            if Self.free(d[pony], now) {
                let meet = Self.free(d[glasses], now) && random.next() < 0.35
                d[pony].look = (Self.toward(pony, glasses), now + (meet ? 0.9 : 0.7))
                if meet {
                    d[glasses].look = (Self.toward(glasses, pony), now + 1.8)
                    ponyPending = (now + 0.9, true)
                    say(now, "ポニーテールとメガネくんの目が合う")
                } else {
                    ponyPending = (now + 1.3, false)   // one more glance
                    say(now, "ポニーテールがメガネくんをチラッと見る")
                }
            }
        }
        if let pending = ponyPending, now >= pending.at {
            if pending.meet {
                d[pony].look = (-Self.toward(pony, glasses, 1.8), now + 2.6)
                d[pony].actions.blush = 3; d[pony].actions.sparkle = 3
                d[pony].cooldown.sparkle = max(d[pony].cooldown.sparkle, 6)
            } else if Self.free(d[pony], now) {
                d[pony].look = (Self.toward(pony, glasses), now + 0.5)
            }
            ponyPending = nil
        }
        if now > next.twin {
            next.twin = now + 7 + random.next() * 5
            if Self.free(d[twin], now) {
                let who = random.next() < 0.6 ? spiky : glasses
                d[twin].look = (Self.toward(twin, who), now + 2.2)
                let name = d[who].member.label
                if Self.free(d[who], now) && random.next() < 0.3 {
                    d[who].look = (Self.toward(who, twin), now + 1.2)
                    twinShyAt = now + 1.0
                    say(now, "ツインテールが\(name)を見ていて気づかれる")
                } else { say(now, "ツインテールが\(name)の様子を見る") }
            }
        }
        if let at = twinShyAt, now >= at {
            d[twin].actions.shy = 2.6; d[twin].look = (0, now + 2.6); twinShyAt = nil
        }
        if d[twin].phrase != lastPhrase {
            lastPhrase = d[twin].phrase
            if random.next() < 0.35 {
                d[pony].sync = (d[twin].armPose, d[twin].turn, d[twin].phrase)
                say(now, "ツインテールとポニーテールが同じ振り付け")
            }
        }
    }
}
