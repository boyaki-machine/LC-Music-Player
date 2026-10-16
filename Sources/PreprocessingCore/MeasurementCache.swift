import Foundation
import CryptoKit
import CSQLite
import Darwin
import AudioProcessingCore

/// Binary DTO; no decoder, PCM, access lease, or intermediate block energies.
struct CachedMeasurement: Codable {
    let sourcePeak: Double
    let sourceFrames: Int64
    let sourceRate: Double
    let sourceChannels: UInt32
    let rate: Double?
    let channels: UInt32?
    let loudnessState: String?
    let loudness: Double?
    let samplePeak: Double?
    let truePeak: Double?
    let frames: UInt64?
    let blocks: Int?
    let completedAt: Date
    init(peak: TrackPeak, levels: TrackAudioMetrics? = nil) {
        sourcePeak = peak.samplePeak; sourceFrames = peak.frameCount; sourceRate = peak.sampleRate; sourceChannels = peak.channelCount
        rate = levels?.profile.sampleRate; channels = levels?.profile.channels
        if let l = levels?.levels.loudness {
            switch l {
            case .measured: loudnessState = "measured"
            case .silent: loudnessState = "silent"
            case .tooShort: loudnessState = "tooShort"
            case .belowGate: loudnessState = "belowGate"
            }
        } else { loudnessState = nil }
        loudness = levels?.levels.loudness.value; samplePeak = levels?.levels.samplePeak
        truePeak = levels?.levels.truePeak; frames = levels?.levels.frameCount; blocks = levels?.levels.blockCount
        completedAt = Date()
    }
    func peak(source: SourceFingerprint) throws -> TrackPeak {
        guard sourcePeak.isFinite, sourcePeak >= 0, sourceFrames > 0,
              sourceRate.isFinite, sourceRate > 0, sourceChannels > 0, sourceChannels <= 64,
              completedAt.timeIntervalSince1970.isFinite, completedAt <= Date(timeIntervalSinceNow: 300) else {
            throw PreprocessingFailure.invalidAudio
        }
        return TrackPeak(source: source, samplePeak: sourcePeak, frameCount: sourceFrames,
                         sampleRate: sourceRate, channelCount: sourceChannels)
    }
    func metrics(source: SourceFingerprint, profile: MeasurementProfile) throws -> TrackAudioMetrics {
        let peak = try peak(source: source)
        guard rate == profile.sampleRate, channels == profile.channels,
              let samplePeak, samplePeak.isFinite, samplePeak >= 0,
              let truePeak, truePeak.isFinite, truePeak >= samplePeak,
              let frames, frames > 0, frames <= UInt64(Int64.max), let blocks, blocks >= 0 else {
            throw PreprocessingFailure.invalidAudio
        }
        let blockFrames = UInt64(profile.sampleRate * 0.4), hop = UInt64(profile.sampleRate * 0.1)
        let expectedBlocks = frames < blockFrames ? 0 : Int((frames - blockFrames) / hop + 1)
        guard blocks == expectedBlocks,
              abs(Double(frames)/profile.sampleRate - Double(sourceFrames)/sourceRate) <= 0.05 else {
            throw PreprocessingFailure.invalidAudio
        }
        let integrated: IntegratedLoudness
        switch loudnessState {
        case "measured":
            guard let loudness, loudness.isFinite, blocks > 0, samplePeak > 0 else { throw PreprocessingFailure.invalidAudio }
            integrated = .measured(loudness)
        case "silent":
            guard loudness == nil, samplePeak == 0, truePeak == 0, sourcePeak == 0 else { throw PreprocessingFailure.invalidAudio }
            integrated = .silent
        case "tooShort":
            guard loudness == nil, blocks == 0, samplePeak > 0 else { throw PreprocessingFailure.invalidAudio }
            integrated = .tooShort
        case "belowGate":
            guard loudness == nil, blocks > 0, samplePeak > 0 else { throw PreprocessingFailure.invalidAudio }
            integrated = .belowGate
        default: throw PreprocessingFailure.invalidAudio
        }
        return TrackAudioMetrics(source: source, profile: profile,
            levels: AudioLevelMetrics(loudness: integrated, samplePeak: samplePeak, truePeak: truePeak, frameCount: frames, blockCount: blocks),
            sourceFrameCount: sourceFrames, sourcePeak: peak)
    }
}

/// Queue-confined SQLite store. Errors are handled as cache misses by the caller.
final class MeasurementCache {
    let configuration: MeasurementCacheConfiguration
    private var db: SQLiteConnection?
    private var program: MeasurementProgramIdentity?
    private var activeOwners: Set<UUID>?
    private var lastMaintenance: Date = .distantPast
    init(_ configuration: MeasurementCacheConfiguration) { self.configuration = configuration }
    func request(_ url: URL, profile: MeasurementProfile?) throws -> MeasurementRequest? {
        guard configuration.maximumRecords > 0, configuration.maximumAge.isFinite, configuration.maximumAge > 0,
              let identity = try configuration.sourceIdentity.identity(for: url),
              !identity.locator.isEmpty, !identity.resource.isEmpty, !identity.revision.isEmpty, identity.size > 0 else { return nil }
        if program == nil { program = try configuration.program ?? MeasurementProgramIdentity.current() }
        return try MeasurementRequest(source: identity, program: program!, configuration: configuration, profile: profile)
    }
    func validate(_ request: MeasurementRequest, for url: URL) throws {
        guard try configuration.sourceIdentity.identity(for: url) == request.source else { throw PreprocessingFailure.sourceChanged }
    }
    private func connection() throws -> SQLiteConnection {
        if let db { try db.validateSchema(); return db }
        let db = try SQLiteConnection(url: configuration.url, maximumBytes: configuration.maximumBytes)
        self.db = db
        return db
    }
    func associateNativePeak(for url: URL, owner: UUID?) throws {
        guard let owner, accepts(owner), let request = try request(url, profile: nil) else { return }
        let db = try connection()
        try db.transaction {
            guard !(try db.query("SELECT key FROM measurements WHERE key=? AND context=?", [.blob(request.key), .blob(request.context)])).isEmpty else { return }
            try bind(request.key, owner: owner, db: db)
        }
    }
    func accepts(_ owner: UUID?) -> Bool { owner.map { activeOwners?.contains($0) ?? true } ?? true }
    func load(_ request: MeasurementRequest, owner: UUID?) throws -> CachedMeasurement? {
        let db = try connection(), now = Date()
        try maintain(db, now: now)
        let rows = try db.query("SELECT payload, checksum, completed FROM measurements WHERE key=? AND context=? AND used>=?",
            [.blob(request.key), .blob(request.context), .real(now.timeIntervalSince1970-configuration.maximumAge)])
        guard let row = rows.first, let payload = row[0].data, let checksum = row[1].data,
              row[2].number.map({ $0 <= now.timeIntervalSince1970+300 }) == true,
              payload.count <= 32768, Data(SHA256.hash(data: payload)) == checksum else { return nil }
        let value = try PropertyListDecoder().decode(CachedMeasurement.self, from: payload)
        try db.transaction {
            try bind(request.key, owner: owner, db: db)
            try db.execute("UPDATE measurements SET used=? WHERE key=?", [.real(now.timeIntervalSince1970), .blob(request.key)])
        }
        return value
    }
    func save(_ value: CachedMeasurement, request: MeasurementRequest, owners: [UUID?], validating url: URL, isCurrent: () -> Bool) throws {
        guard owners.contains(where: accepts), isCurrent() else { return }
        // Recheck the original provider revision after the successful EOF.
        try validate(request, for: url)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let payload = try encoder.encode(value)
        guard payload.count <= 32768 else { return }
        let db = try connection(), now = Date()
        try db.transaction {
            // Epoch removes incompatible program/DSP generations without decoding their records.
            try db.execute("DELETE FROM measurements WHERE epoch<>?", [.blob(request.epoch)])
            let pageSize = try db.query("PRAGMA page_size").first?.first?.integer ?? 4096
            let pages = try db.query("PRAGMA page_count").first?.first?.integer ?? 0
            let free = try db.query("PRAGMA freelist_count").first?.first?.integer ?? 0
            if (pages-free)*pageSize > configuration.maximumBytes - min(65536, configuration.maximumBytes/4) {
                let count = try db.query("SELECT COUNT(*) FROM measurements").first?.first?.integer ?? 0
                try prune(db, targetCount: max(0, count - max(1, count/4)), now: now)
            }
            // Make space BEFORE inserting; SQLite's page cap still provides a hard bound.
            try prune(db, targetCount: max(0, configuration.maximumRecords-1), now: now)
            try db.execute("""
                INSERT INTO measurements(key,context,epoch,payload,checksum,completed,used,managed) VALUES(?,?,?,?,?,?,?,0)
                ON CONFLICT(key) DO UPDATE SET context=excluded.context,epoch=excluded.epoch,payload=excluded.payload,
                    checksum=excluded.checksum,completed=excluded.completed,used=excluded.used
                """, [.blob(request.key), .blob(request.context), .blob(request.epoch), .blob(payload), .blob(Data(SHA256.hash(data: payload))),
                      .real(value.completedAt.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
            for owner in owners where accepts(owner) { try bind(request.key, owner: owner, db: db) }
            guard isCurrent() else { throw CancellationError() }
        }
    }
    private func bind(_ key: Data, owner: UUID?, db: SQLiteConnection) throws {
        guard let owner, accepts(owner) else { return }
        try db.execute("INSERT OR IGNORE INTO owners(track,key) VALUES(?,?)", [.text(owner.uuidString), .blob(key)])
        try db.execute("UPDATE measurements SET managed=1 WHERE key=?", [.blob(key)])
    }
    /// Called only with a successfully loaded/saved library snapshot.
    func reconcile(_ owners: Set<UUID>) throws {
        activeOwners = owners // also prevents a canceled/late scan resurrecting excluded entries
        let db = try connection()
        try db.transaction {
            try db.execute("CREATE TEMP TABLE IF NOT EXISTS active_tracks(id TEXT PRIMARY KEY)")
            try db.execute("DELETE FROM active_tracks")
            for owner in owners { try db.execute("INSERT INTO active_tracks VALUES(?)", [.text(owner.uuidString)]) }
            try db.execute("DELETE FROM owners WHERE NOT EXISTS(SELECT 1 FROM active_tracks WHERE id=owners.track)")
            try db.execute("DELETE FROM measurements WHERE managed=1 AND NOT EXISTS(SELECT 1 FROM owners WHERE owners.key=measurements.key)")
        }
        try maintain(db, now: Date())
    }
    private func maintain(_ db: SQLiteConnection, now: Date) throws {
        guard now.timeIntervalSince(lastMaintenance) >= 60 else { return }
        try db.transaction { try prune(db, targetCount: configuration.maximumRecords, now: now) }
        try db.execute("PRAGMA incremental_vacuum(128)")
        lastMaintenance = now
    }
    private func prune(_ db: SQLiteConnection, targetCount: Int, now: Date) throws {
        try db.execute("DELETE FROM measurements WHERE used<?", [.real(now.timeIntervalSince1970-configuration.maximumAge)])
        let count = try db.query("SELECT COUNT(*) FROM measurements").first?.first?.integer ?? 0
        if count > targetCount {
            try db.execute("DELETE FROM measurements WHERE key IN(SELECT key FROM measurements ORDER BY used LIMIT ?)", [.integer(Int64(count-targetCount))])
        }
    }
}

enum SQLValue {
    case blob(Data), text(String), real(Double), integer(Int64), null
    var data: Data? { if case .blob(let d) = self { d } else { nil } }
    var number: Double? { if case .real(let n) = self { n } else { nil } }
    var integer: Int? { if case .integer(let n) = self { Int(exactly: n) } else { nil } }
}
struct MeasurementDatabaseFailure: Error {
    let operation: String
    let code: Int32
    let detail: String
    init(_ operation: String = "database", code: Int32 = 0, detail: String = "") { self.operation = operation; self.code = code; self.detail = detail }
}
final class SQLiteConnection {
    private var handle: OpaquePointer?
    private var initialized = false
    init(url: URL, maximumBytes: Int) throws {
        let fm = FileManager.default, directory = url.deletingLastPathComponent()
        guard maximumBytes >= 65536 else { throw MeasurementDatabaseFailure() }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw MeasurementDatabaseFailure() }
        if fm.fileExists(atPath: url.path) {
            let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard v.isRegularFile == true, v.isSymbolicLink != true, v.fileSize.map({ $0 <= maximumBytes }) == true else { throw MeasurementDatabaseFailure() }
        }
        // Foundation intentionally abbreviates /private/var back to /var on macOS.
        // Use the POSIX canonical parent string to preserve NOFOLLOW semantics.
        guard let canonicalParent = realpath(directory.path, nil) else { throw MeasurementDatabaseFailure() }
        defer { free(canonicalParent) }
        let path = String(cString: canonicalParent) + "/" + url.lastPathComponent
        let status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOFOLLOW, nil)
        guard status == SQLITE_OK else {
            let detail = String(cString: sqlite3_errmsg(handle))
            let code = sqlite3_extended_errcode(handle)
            if let handle { sqlite3_close(handle) }; handle = nil
            throw MeasurementDatabaseFailure("open", code: code, detail: detail)
        }
        do {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            sqlite3_busy_timeout(handle, 50)
            sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 65536)
            try execute("PRAGMA trusted_schema=OFF")
            try execute("PRAGMA foreign_keys=ON")
            let version = try query("PRAGMA user_version").first?.first?.integer ?? -1
            let application = try query("PRAGMA application_id").first?.first?.integer ?? -1
            if version == 0, application == 0 {
                guard try query("SELECT name FROM sqlite_master WHERE type='table'").isEmpty else { throw MeasurementDatabaseFailure() }
                try execute("PRAGMA page_size=4096")
                try execute("PRAGMA auto_vacuum=INCREMENTAL")
                try transaction {
                    try execute("CREATE TABLE measurements(key BLOB PRIMARY KEY,context BLOB NOT NULL,epoch BLOB NOT NULL,payload BLOB NOT NULL CHECK(length(payload)<=32768),checksum BLOB NOT NULL,completed REAL NOT NULL,used REAL NOT NULL,managed INTEGER NOT NULL) WITHOUT ROWID")
                    try execute("CREATE INDEX measurements_used ON measurements(used)")
                    try execute("CREATE TABLE owners(track TEXT NOT NULL,key BLOB NOT NULL REFERENCES measurements(key) ON DELETE CASCADE,PRIMARY KEY(track,key)) WITHOUT ROWID")
                    try execute("CREATE INDEX owners_key ON owners(key)")
                    try execute("PRAGMA application_id=1279479120") // LCMP
                    try execute("PRAGMA user_version=1")
                }
            } else { guard version == 1, application == 1279479120 else { throw MeasurementDatabaseFailure() } }
            let pageSize = try query("PRAGMA page_size").first?.first?.integer ?? 4096
            try execute("PRAGMA max_page_count=\(maximumBytes/pageSize)")
            try execute("PRAGMA journal_size_limit=0")
            initialized = true
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }
    deinit { sqlite3_close(handle) }
    func validateSchema() throws {
        guard try query("PRAGMA user_version").first?.first?.integer == 1,
              try query("PRAGMA application_id").first?.first?.integer == 1279479120 else { throw MeasurementDatabaseFailure() }
    }
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { if initialized { try validateSchema() }; try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func execute(_ sql: String, _ values: [SQLValue] = []) throws { _ = try query(sql, values) }
    func query(_ sql: String, _ values: [SQLValue] = []) throws -> [[SQLValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw MeasurementDatabaseFailure("prepare: " + sql, code: sqlite3_errcode(handle)) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let slot = Int32(index+1), status: Int32
            switch value {
            case .blob(let d): status = d.withUnsafeBytes { sqlite3_bind_blob(statement, slot, $0.baseAddress, Int32($0.count), transient) }
            case .text(let s): status = sqlite3_bind_text(statement, slot, s, -1, transient)
            case .real(let n): status = sqlite3_bind_double(statement, slot, n)
            case .integer(let n): status = sqlite3_bind_int64(statement, slot, n)
            case .null: status = sqlite3_bind_null(statement, slot)
            }
            guard status == SQLITE_OK else { throw MeasurementDatabaseFailure() }
        }
        var rows: [[SQLValue]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw MeasurementDatabaseFailure("step: " + sql, code: status) }
            var row: [SQLValue] = []
            for i in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, i) {
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, i))
                    row.append(.blob(sqlite3_column_blob(statement, i).map { Data(bytes: $0, count: count) } ?? Data()))
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, i)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, i)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(statement, i))))
                default: row.append(.null)
                }
            }
            rows.append(row)
        }
    }
}
