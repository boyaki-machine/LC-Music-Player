#if os(macOS)
import AVFAudio
import Foundation
import SoundAnalysis
import Testing
@testable import AnalysisCore
import AudioProcessingCore
@testable import PlayerUI

/// Compares beat trackers, and the vocal analyzer with the OS sound classifier, with what was tapped by
/// hand (scripts/beat-annotator.html), for the songs in
/// `LCMP_BEAT_EVAL=<directory>`: each `*.beats.json` there names its audio file in the same directory.
/// The audio and the annotations stay outside the repository. Results are printed and, with
/// `LCMP_BEAT_EVAL_OUT=<file>`, written as JSON.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LCMP_BEAT_EVAL"] != nil))
struct BeatEvaluationTests {
    @Test func compareTrackersWithTappedBeats() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LCMP_BEAT_EVAL"]))
        let annotations = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".beats.json") }.sorted { $0.path < $1.path }
        try #require(!annotations.isEmpty)
        var results: [BeatEvaluation.SongResult] = []
        for (number, file) in annotations.enumerated() {
            let annotation = try JSONDecoder().decode(BeatAnnotation.self, from: Data(contentsOf: file))
            let audio = directory.appendingPathComponent(annotation.file)
            let pcm = try BeatEvaluation.read(audio)
            var scores: [String: BeatEvaluation.Scores] = [:]
            for tracker in BeatEvaluation.trackers {
                let started = ContinuousClock.now
                let beats = try tracker.run(pcm)
                var score = BeatEvaluation.score(beats, against: annotation)
                score.seconds = BeatEvaluation.seconds(started.duration(to: .now))
                scores[tracker.name] = score
            }
            var vocals: [String: [String: VocalEvaluation.Overlap]] = [:]
            var vocalInfo = ""
            for analyzer in VocalEvaluation.analyzers {
                let started = ContinuousClock.now
                let spans = try analyzer.run(pcm, audio)
                var overlaps = VocalEvaluation.score(spans, against: annotation)
                overlaps["seconds"] = .init(precision: BeatEvaluation.seconds(started.duration(to: .now)), recall: 0, tapped: 0)
                vocals[analyzer.name] = overlaps
            }
            if let map = try? VocalEvaluation.map(pcm) { vocalInfo = "音域 \(map.register) 中央値 \(map.medianNote)" }
            // Songs are numbered, not named, so that the results can be kept in notes.
            results.append(.init(song: number + 1, genre: annotation.genre, meter: annotation.meter, scores: scores,
                                 vocals: vocals, vocalInfo: vocalInfo))
        }
        BeatEvaluation.report(results)
        VocalEvaluation.report(results)
        if let out = ProcessInfo.processInfo.environment["LCMP_BEAT_EVAL_OUT"] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(results).write(to: URL(fileURLWithPath: out))
        }
    }

}

/// The scoring itself, on beats whose answers are known. Runs without any songs.
@Suite struct BeatEvaluationScoringTests {
    @Test func scoringNamesTheKindOfMistake() throws {
        let truth = BeatAnnotation(file: "", genre: "", meter: 4, excerptMilliseconds: [0, 20_000],
            beats: (0..<20).map { .init(ms: 1000 + $0 * 500, downbeat: $0 % 4 == 0) }, longTones: [], shouts: [])
        let times = (0..<20).map { 1.0 + Double($0) * 0.5 }
        let exact = BeatEvaluation.score(times.map { ($0 + 0.02, false) }, against: truth)
        #expect(exact.fMeasure == 1 && exact.tempo == .same)
        #expect(abs(try #require(exact.startDelay) - 0.02) < 1e-9)
        let double = BeatEvaluation.score((0..<40).map { (1.0 + Double($0) * 0.25, false) }, against: truth)
        #expect(double.tempo == .double && double.recall == 1 && abs(double.precision - 0.5) < 0.03)
        let half = BeatEvaluation.score(stride(from: 0, to: 20, by: 2).map { (times[$0], false) }, against: truth)
        #expect(half.tempo == .half && half.precision == 1)
        let offBeat = BeatEvaluation.score(times.map { ($0 + 0.25, false) }, against: truth)
        #expect(offBeat.tempo == .offBeat && offBeat.fMeasure == 0)
        let late = BeatEvaluation.score(times.dropFirst(6).map { ($0, false) }, against: truth)
        #expect(abs(try #require(late.startDelay) - 3) < 1e-9)
        #expect(BeatEvaluation.score([], against: truth).startDelay == nil)
    }
}

struct BeatAnnotation: Codable {
    struct Beat: Codable { var ms: Int; var downbeat: Bool }
    var file: String
    var genre: String
    var meter: Int
    var excerptMilliseconds: [Int]
    var beats: [Beat]
    var longTones: [[Int]]
    var shouts: [[Int]]
    /// Added after the first annotations; missing in those.
    var highTones: [[Int]]? = nil
    var harmonies: [[Int]]? = nil
}

enum BeatEvaluation {
    static let tolerance = 0.07

    struct PCM: Sendable { var left: [Float]; var right: [Float]; var rate: Double }

    struct Tracker: Sendable {
        var name: String
        /// Beat times in seconds and whether each begins a bar.
        var run: @Sendable (PCM) throws -> [(Double, Bool)]
    }

    enum Tempo: String, Codable { case same = "一致", double = "倍", half = "半分", threeTwo = "3:2", offBeat = "裏拍", other = "その他", none = "なし" }

    struct Scores: Codable {
        var precision = 0.0, recall = 0.0, fMeasure = 0.0
        var tempo = Tempo.none
        /// Seconds from the first tapped beat to the first of four beats in a row that are right.
        var startDelay: Double?
        /// The share of detected bar starts on a tapped bar start.
        var downbeats: Double?
        var seconds = 0.0
    }

    struct SongResult: Codable {
        var song: Int
        var genre: String
        var meter: Int
        var scores: [String: Scores]
        var vocals: [String: [String: VocalEvaluation.Overlap]] = [:]
        var vocalInfo = ""
    }

    static let trackers: [Tracker] = [
        Tracker(name: "現行（再生中の推定）", run: live),
        Tracker(name: "前処理 v\(OnsetBeatDetector.algorithm)", run: { pcm in try offline(pcm, detector: .standard) }),
    ]

    static func read(_ url: URL) throws -> PCM {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536) else { throw AudioProcessingFailure.invalidMeasurement }
        var pcm = PCM(left: [], right: [], rate: format.sampleRate)
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            let n = Int(buffer.frameLength)
            pcm.left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: n))
            pcm.right.append(contentsOf: UnsafeBufferPointer(start: channels[format.channelCount > 1 ? 1 : 0], count: n))
        }
        return pcm
    }

    /// The detector run over the whole track as the preprocessing does, in chunks of 8192 frames.
    static func offline(_ pcm: PCM, detector make: BeatDetector) throws -> [(Double, Bool)] {
        let detector = try make(sampleRate: pcm.rate)
        try pcm.left.withUnsafeBufferPointer { l in
            try pcm.right.withUnsafeBufferPointer { r in
                var start = 0
                while start < l.count {
                    let n = min(8192, l.count - start)
                    try detector.consume(left: l.baseAddress! + start, right: r.baseAddress! + start, frames: n)
                    start += n
                }
            }
        }
        return try detector.finish().beats.map { (Double($0.milliseconds) / 1000, $0.isDownbeat) }
    }

    /// The estimate the puppets use while playing: the analysis the player makes at 30 frames a second,
    /// fed to `ErmineBeatTracker` at the middle of each window. A beat is where the estimate's beat index moves on.
    static func live(_ pcm: PCM) throws -> [(Double, Bool)] {
        let configuration = VisualizationDesign.configuration
        let analyzer = try SpectrumAnalyzer(configuration: configuration)
        let n = configuration.fftSize
        let hop = min(n / 2, max(1, Int(pcm.rate / Double(configuration.framesPerSecond))))
        var tracker = ErmineBeatTracker()
        var beats: [(Double, Bool)] = []
        var lastIndex: Int?
        var start = 0
        while start + n <= pcm.left.count {
            let time = (Double(start) + Double(n) / 2) / pcm.rate
            if let result = analyzer.analyze(left: Array(pcm.left[start..<start + n]), right: Array(pcm.right[start..<start + n]), sampleRate: pcm.rate),
               let db = PuppetRegisterLevels.registerDB(bandDBFS: result.db, edgesHz: result.edges) {
                tracker.feed(registerDB: db, at: time)
            }
            if let beat = tracker.beat(at: time) {
                if beat.index != lastIndex { beats.append((time - beat.phase * beat.period, false)) }
                lastIndex = beat.index
            } else { lastIndex = nil }
            start += hop
        }
        return beats
    }

    static func score(_ detected: [(Double, Bool)], against annotation: BeatAnnotation) -> Scores {
        let truth = annotation.beats.map { Double($0.ms) / 1000 }
        guard let first = truth.first, let last = truth.last, truth.count >= 4 else { return Scores() }
        let found = detected.filter { $0.0 >= first - tolerance && $0.0 <= last + tolerance }
        var scores = Scores()
        // One detected beat answers at most one tapped beat.
        var used = Set<Int>()
        var hits = 0
        for (t, _) in found {
            if let j = truth.indices.filter({ !used.contains($0) && abs(truth[$0] - t) <= tolerance }).min(by: { abs(truth[$0] - t) < abs(truth[$1] - t) }) {
                used.insert(j); hits += 1
            }
        }
        scores.precision = found.isEmpty ? 0 : Double(hits) / Double(found.count)
        scores.recall = Double(hits) / Double(truth.count)
        scores.fMeasure = scores.precision + scores.recall > 0 ? 2 * scores.precision * scores.recall / (scores.precision + scores.recall) : 0
        scores.tempo = tempo(found.map(\.0), truth: truth)
        // The start: the first of four detected beats in a row that each fall on a tapped beat.
        let onTruth = found.map { f in truth.contains { abs($0 - f.0) <= tolerance } }
        if onTruth.count >= 4, let i = (0...(onTruth.count - 4)).first(where: { onTruth[$0..<$0 + 4].allSatisfy { $0 } }) {
            scores.startDelay = max(0, found[i].0 - first)
        }
        let bars = annotation.beats.filter(\.downbeat).map { Double($0.ms) / 1000 }
        let detectedBars = found.filter(\.1).map(\.0)
        if !bars.isEmpty, !detectedBars.isEmpty {
            scores.downbeats = Double(detectedBars.filter { d in bars.contains { abs($0 - d) <= tolerance } }.count) / Double(detectedBars.count)
        }
        return scores
    }

    /// How the detected beats relate to the tapped ones: the ratio of the median intervals, and for the
    /// same tempo whether most beats fall halfway between the tapped ones.
    static func tempo(_ found: [Double], truth: [Double]) -> Tempo {
        func median(_ x: [Double]) -> Double? {
            let intervals = zip(x.dropFirst(), x).map { $0 - $1 }.sorted()
            return intervals.isEmpty ? nil : intervals[intervals.count / 2]
        }
        guard let d = median(found), let t = median(truth) else { return .none }
        let ratio = d / t
        if abs(ratio - 1) < 0.08 {
            let middles = zip(truth.dropFirst(), truth).map { ($0 + $1) / 2 }
            let off = found.filter { f in middles.contains { abs($0 - f) <= tolerance } }.count
            return Double(off) > 0.5 * Double(found.count) ? .offBeat : .same
        }
        if abs(ratio - 0.5) < 0.04 { return .double }
        if abs(ratio - 2) < 0.16 { return .half }
        if abs(ratio - 1.5) < 0.12 || abs(ratio - 2.0 / 3) < 0.06 { return .threeTwo }
        return .other
    }

    static func report(_ results: [SongResult]) {
        let names = trackers.map(\.name)
        func f(_ x: Double?) -> String { x.map { String(format: "%.2f", $0) } ?? "-" }
        print("BEATEVAL 曲\tジャンル\t拍子\t" + names.map { "\($0) F\t\($0) テンポ\t\($0) 出だし\t\($0) 小節" }.joined(separator: "\t"))
        for r in results {
            let cells = names.map { name -> String in
                let s = r.scores[name] ?? Scores()
                return "\(f(s.fMeasure))\t\(s.tempo.rawValue)\t\(f(s.startDelay))\t\(f(s.downbeats))"
            }
            print("BEATEVAL \(r.song)\t\(r.genre)\t\(r.meter)\t" + cells.joined(separator: "\t"))
        }
        for name in names {
            let all = results.compactMap { $0.scores[name] }
            let mean = all.map(\.fMeasure).reduce(0, +) / Double(max(1, all.count))
            let delays = all.compactMap(\.startDelay)
            let counts = Dictionary(grouping: all, by: \.tempo).mapValues(\.count).map { "\($0.key.rawValue) \($0.value)" }.sorted().joined(separator: "・")
            print("BEATEVAL 平均 \(name)：F \(f(mean))、テンポ \(counts)、出だしの遅れの中央値 \(f(delays.sorted().dropFirst(delays.count / 2).first))秒（\(delays.count)曲で拍に乗れた）、時間 \(f(all.map(\.seconds).reduce(0, +)))秒")
        }
    }

    static func seconds(_ value: Duration) -> Double {
        Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
    }
}
/// The vocal stretches the annotator records, scored by how much of their time overlaps.
enum VocalEvaluation {
    /// Seconds by which a detected stretch may miss the tapped one at either end.
    static let slack = 0.3
    static let kinds = ["ロングトーン", "シャウト", "ハイトーン", "ハモり"]
    /// The stretches tapped for a kind; the first annotations have no high tones or harmonies.
    static func tapped(_ kind: String, in a: BeatAnnotation) -> [[Int]] {
        switch kind {
        case "ロングトーン": a.longTones
        case "シャウト": a.shouts
        case "ハイトーン": a.highTones ?? []
        default: a.harmonies ?? []
        }
    }

    struct Overlap: Codable {
        /// The share of detected time near a tapped stretch, and of tapped time that was detected.
        var precision: Double, recall: Double
        var tapped: Double
    }

    struct Analyzer: Sendable {
        var name: String
        /// Detected stretches in seconds, by kind name.
        var run: @Sendable (BeatEvaluation.PCM, URL) throws -> [String: [(Double, Double)]]
    }

    static let analyzers: [Analyzer] = [
        Analyzer(name: "前処理 v\(CentreVocalAnalyzer.algorithm)", run: { pcm, _ in
            let map = try map(pcm)
            func spans(_ kind: VocalMap.Event.Kind) -> [(Double, Double)] {
                map.events.filter { $0.kind == kind }.map { (Double($0.startMilliseconds) / 1000, Double($0.endMilliseconds) / 1000) }
            }
            return ["ロングトーン": spans(.longTone), "シャウト": spans(.shout), "ハイトーン": spans(.highTone), "ハモり": spans(.harmony)]
        }),
        Analyzer(name: "OSの分類器", run: { _, url in try classify(url) }),
    ]

    static func map(_ pcm: BeatEvaluation.PCM) throws -> VocalMap {
        let analyzer = try CentreVocalAnalyzer(sampleRate: pcm.rate)
        try pcm.left.withUnsafeBufferPointer { l in
            try pcm.right.withUnsafeBufferPointer { r in
                var start = 0
                while start < l.count {
                    let n = min(8192, l.count - start)
                    try analyzer.consume(left: l.baseAddress! + start, right: r.baseAddress! + start, frames: n)
                    start += n
                }
            }
        }
        return try analyzer.finish()
    }

    /// The OS classifier's 3-second windows every 1.5 seconds: a shout where shouting, yelling or screaming
    /// is likely, a harmony where a choir sings. It has no long or high tones.
    static func classify(_ url: URL) throws -> [String: [(Double, Double)]] {
        final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
            var windows: [(start: Double, end: Double, scores: [String: Double])] = []
            func request(_ request: SNRequest, didProduce result: SNResult) {
                guard let result = result as? SNClassificationResult else { return }
                windows.append((result.timeRange.start.seconds, result.timeRange.end.seconds,
                                Dictionary(uniqueKeysWithValues: result.classifications.map { ($0.identifier, $0.confidence) })))
            }
        }
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.overlapFactor = 0.5
        let analyzer = try SNAudioFileAnalyzer(url: url), collector = Collector()
        try analyzer.add(request, withObserver: collector)
        analyzer.analyze()
        func spans(_ labels: [String]) -> [(Double, Double)] {
            collector.windows.filter { w in labels.contains { (w.scores[$0] ?? 0) > 0.3 } }.map { ($0.start, $0.end) }
        }
        return ["シャウト": spans(["shout", "yell", "screaming", "battle_cry"]), "ハモり": spans(["choir_singing"])]
    }

    static func score(_ detected: [String: [(Double, Double)]], against annotation: BeatAnnotation) -> [String: Overlap] {
        let excerpt = (Double(annotation.excerptMilliseconds[0]) / 1000, Double(annotation.excerptMilliseconds[1]) / 1000)
        var result: [String: Overlap] = [:]
        for name in kinds {
            guard let found = detected[name] else { continue }
            let tapped = Self.tapped(name, in: annotation).map { (Double($0[0]) / 1000, Double($0[1]) / 1000) }
            let inside = found.compactMap { s -> (Double, Double)? in
                let a = max(s.0, excerpt.0), b = min(s.1, excerpt.1); return b > a ? (a, b) : nil
            }
            func length(_ spans: [(Double, Double)]) -> Double { spans.reduce(0) { $0 + $1.1 - $1.0 } }
            func covered(_ spans: [(Double, Double)], by others: [(Double, Double)], slack: Double) -> Double {
                spans.reduce(0) { sum, s in
                    sum + others.reduce(0) { $0 + max(0, min(s.1, $1.1 + slack) - max(s.0, $1.0 - slack)) }
                }
            }
            let detectedTime = length(inside), tappedTime = length(tapped)
            result[name] = Overlap(precision: detectedTime > 0 ? min(1, covered(inside, by: tapped, slack: slack) / detectedTime) : (tappedTime == 0 ? 1 : 0),
                                   recall: tappedTime > 0 ? min(1, covered(tapped, by: inside, slack: slack) / tappedTime) : 1,
                                   tapped: tappedTime)
        }
        return result
    }

    static func report(_ results: [BeatEvaluation.SongResult]) {
        func f(_ x: Double) -> String { String(format: "%.2f", x) }
        for r in results { print("VOCALEVAL \(r.song)\t\(r.genre)\t\(r.vocalInfo)") }
        for analyzer in analyzers {
            for name in kinds {
                let all = results.compactMap { $0.vocals[analyzer.name]?[name] }
                guard !all.isEmpty else { continue }
                let tapped = all.reduce(0) { $0 + $1.tapped }
                // Recall weighted by tapped time; precision over songs where something was detected or tapped.
                let recall = tapped > 0 ? all.reduce(0) { $0 + $1.recall * $1.tapped } / tapped : 1
                let precision = all.map(\.precision).reduce(0, +) / Double(all.count)
                print("VOCALEVAL \(analyzer.name) \(name)：適合 \(f(precision))、再現 \(f(recall))、正解 \(f(tapped))秒")
            }
            let time = results.compactMap { $0.vocals[analyzer.name]?["seconds"]?.precision }.reduce(0, +)
            print("VOCALEVAL \(analyzer.name) 時間 \(f(time))秒")
        }
    }
}

#endif
