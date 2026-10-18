import Foundation
import CryptoKit
import AudioProcessingCore
#if canImport(Darwin)
import Darwin
#endif

/// Opaque platform/provider identity. No POSIX types enter the persistent schema.
public struct MeasurementSourceIdentity: Codable, Hashable, Sendable {
    public let locator: String
    public let resource: String
    public let revision: String
    public let size: Int64
    public init(locator: String, resource: String, revision: String, size: Int64) {
        self.locator = locator; self.resource = resource; self.revision = revision; self.size = size
    }
}
public protocol MeasurementSourceIdentifying: Sendable {
    /// Return nil when a provider cannot supply a trustworthy persistent revision.
    func identity(for url: URL) throws -> MeasurementSourceIdentity?
}
public struct LocalMeasurementSourceIdentity: MeasurementSourceIdentifying {
    public init() {}
    public func identity(for url: URL) throws -> MeasurementSourceIdentity? {
        #if os(macOS)
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try canonical.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeIsLocalKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.volumeIsLocal == true,
              let volume = values.volumeUUIDString else { return nil }
        var info = stat()
        let result = canonical.withUnsafeFileSystemRepresentation { path in path.map { lstat($0, &info) } ?? -1 }
        guard result == 0, info.st_size > 0, info.st_ino > 0 else { return nil }
        return MeasurementSourceIdentity(locator: canonical.absoluteString,
            resource: "\(volume)/\(info.st_dev)/\(info.st_ino)",
            revision: "\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)/\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)/\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)",
            size: info.st_size)
        #else
        // iOS file providers require a provider-specific revision adapter. Until
        // verified, a miss is preferable to assuming desktop inode semantics.
        return nil
        #endif
    }
}

public struct MeasurementProgramIdentity: Codable, Equatable, Sendable {
    public let applicationVersion: String
    public let build: String
    public let executableDigest: String
    public let environment: String
    public init(applicationVersion: String, build: String, executableDigest: String, environment: String) {
        self.applicationVersion = applicationVersion; self.build = build
        self.executableDigest = executableDigest; self.environment = environment
    }
    /// Invoked once on the preprocessing queue, never on the render or UI thread.
    static func current() throws -> Self {
        guard let url = Bundle.main.executableURL else { throw PreprocessingFailure.invalidAudio }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let block = try file.read(upToCount: 1024 * 1024), !block.isEmpty { hash.update(data: block) }
        return Self(applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
            executableDigest: hash.finalize().map { String(format: "%02x", $0) }.joined(),
            environment: ProcessInfo.processInfo.operatingSystemVersionString + "/CoreAudio")
    }
}

public struct MeasurementCacheConfiguration: Sendable {
    public let url: URL
    public var program: MeasurementProgramIdentity?
    public var sourceIdentity: any MeasurementSourceIdentifying
    public var maximumBytes: Int = 64 * 1024 * 1024
    public var maximumRecords: Int = 10_000
    public var maximumAge: TimeInterval = 90 * 86400
    public var algorithmVersion: Int = 1
    public var conversionVersion: Int = 1
    public init(url: URL, program: MeasurementProgramIdentity? = nil,
                sourceIdentity: any MeasurementSourceIdentifying = LocalMeasurementSourceIdentity()) {
        self.url = url; self.program = program; self.sourceIdentity = sourceIdentity
    }
    public static var application: Self {
        Self(url: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LCMP/Measurements/v1/measurements.sqlite"))
    }
}

struct MeasurementRequest: Sendable {
    let source: MeasurementSourceIdentity
    let context: Data
    let key: Data
    let epoch: Data
    init(source: MeasurementSourceIdentity, program: MeasurementProgramIdentity,
         configuration: MeasurementCacheConfiguration, profile: MeasurementProfile?) throws {
        self.source = source
        // An ordered array of length-delimited strings prevents concatenation ambiguity.
        let components = ["LCMP-measurements-1", source.locator, source.resource, source.revision, String(source.size),
            program.applicationVersion, program.build, program.executableDigest, program.environment,
            String(configuration.algorithmVersion), String(configuration.conversionVersion),
            profile.map { String($0.version) } ?? "native-peak-1",
            profile.map { String($0.sampleRate.bitPattern) } ?? "", profile.map { String($0.channels) } ?? ""]
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        context = try encoder.encode(components)
        key = Data(SHA256.hash(data: context))
        epoch = Data(SHA256.hash(data: try encoder.encode(Array(components[5...10]))))
    }
}
