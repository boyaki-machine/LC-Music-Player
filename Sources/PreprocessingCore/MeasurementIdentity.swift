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
        // macOS and iOS both keep audio files on local APFS volumes (on iOS also the files a
        // file provider has stored on the device). Any change of a timestamp or size is a miss.
        // Music library songs have no file revision; the iOS app identifies them through the library.
        guard url.isFileURL else { return nil }
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
    }
}

/// The versions of the code that measures. A change that can alter a stored measurement raises
/// one of them, and only then are earlier measurements measured again; a new build of the app
/// alone keeps them. `MeasurementVersionTests` pins the results of each version.
public enum MeasurementVersions {
    /// Loudness, sample peak, true peak and native peak (LevelDSP, LoudnessMeter, NativeSamplePeak).
    public static let algorithm = 1
    /// Decoding into the profile's format (AudioDecoderFactory, ProfileConversion).
    public static let conversion = 1
}

/// The platform whose Core Audio decodes and converts the audio: the OS and its major version.
/// Minor updates of the OS keep measurements; a new major version measures again once.
public struct MeasurementPlatformIdentity: Codable, Equatable, Sendable {
    public let system: String
    public let decoder: String
    public init(system: String, decoder: String = "CoreAudio") { self.system = system; self.decoder = decoder }
    public static var current: Self { Self(system: system(major: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)) }
    static func system(major: Int) -> String {
        #if os(iOS)
        "iOS \(major)"
        #else
        "macOS \(major)"
        #endif
    }
}

public struct MeasurementCacheConfiguration: Sendable {
    public let url: URL
    public var platform: MeasurementPlatformIdentity
    public var sourceIdentity: any MeasurementSourceIdentifying
    public var maximumBytes: Int = 64 * 1024 * 1024
    public var maximumRecords: Int = 10_000
    public var maximumAge: TimeInterval = 90 * 86400
    public var algorithmVersion: Int = MeasurementVersions.algorithm
    public var conversionVersion: Int = MeasurementVersions.conversion
    public init(url: URL, platform: MeasurementPlatformIdentity = .current,
                sourceIdentity: any MeasurementSourceIdentifying = LocalMeasurementSourceIdentity()) {
        self.url = url; self.platform = platform; self.sourceIdentity = sourceIdentity
    }
    public static var application: Self {
        Self(url: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LCMP/Measurements/v1/measurements.sqlite"))
    }
}

struct MeasurementRequest: Sendable {
    static let format = "LCMP-measurements-2"
    let source: MeasurementSourceIdentity
    let context: Data
    let key: Data
    let epoch: Data
    init(source: MeasurementSourceIdentity, configuration: MeasurementCacheConfiguration, profile: MeasurementProfile?) throws {
        try self.init(source: source, platform: configuration.platform, algorithm: String(configuration.algorithmVersion),
                      conversion: String(configuration.conversionVersion), profile: profile.map { String($0.version) } ?? "native-peak-1",
                      rate: profile.map { String($0.sampleRate.bitPattern) } ?? "", channels: profile.map { String($0.channels) } ?? "")
    }
    init(source: MeasurementSourceIdentity, platform: MeasurementPlatformIdentity, algorithm: String, conversion: String,
         profile: String, rate: String, channels: String) throws {
        self.source = source
        // An ordered array of length-delimited strings prevents concatenation ambiguity.
        let components = [Self.format, source.locator, source.resource, source.revision, String(source.size),
            platform.system, platform.decoder, algorithm, conversion, profile, rate, channels]
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        context = try encoder.encode(components)
        key = Data(SHA256.hash(data: context))
        epoch = Data(SHA256.hash(data: try encoder.encode(Array(components[5...8]))))
    }

    /// A record of the first format (schema 1) under the current format, or nil when it cannot be
    /// carried over. That format keyed the app's build and executable, which no longer invalidate a
    /// measurement, and the whole OS version string, of which only the major version is kept.
    /// Only records decoded by Core Audio with the current algorithm and conversion carry over.
    static func legacy(_ context: Data, configuration: MeasurementCacheConfiguration) -> MeasurementRequest? {
        guard let c = try? PropertyListDecoder().decode([String].self, from: context), c.count == 14,
              c[0] == "LCMP-measurements-1", let size = Int64(c[4]),
              c[8].hasSuffix("/CoreAudio"), let major = Self.legacyMajor(c[8]),
              c[9] == String(configuration.algorithmVersion), c[10] == String(configuration.conversionVersion) else { return nil }
        let source = MeasurementSourceIdentity(locator: c[1], resource: c[2], revision: c[3], size: size)
        let platform = MeasurementPlatformIdentity(system: MeasurementPlatformIdentity.system(major: major))
        return try? MeasurementRequest(source: source, platform: platform, algorithm: c[9], conversion: c[10], profile: c[11], rate: c[12], channels: c[13])
    }

    /// The major version in `ProcessInfo.operatingSystemVersionString`, e.g. 26 in "Version 26.0 (Build 25A354)/CoreAudio".
    static func legacyMajor(_ environment: String) -> Int? {
        guard environment.hasPrefix("Version ") else { return nil }
        let digits = environment.dropFirst("Version ".count).prefix { $0.isNumber }
        return Int(digits).flatMap { $0 > 0 ? $0 : nil }
    }
}
