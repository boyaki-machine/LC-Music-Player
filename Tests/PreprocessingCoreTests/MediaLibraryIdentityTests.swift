import Foundation
import Testing
@testable import PreprocessingCore

@Suite struct MediaLibraryIdentityTests {
    /// Music library songs have no file revision to compare, so they never hit the persistent cache.
    @Test func librarySongsHaveNoPersistentIdentity() throws {
        #expect(try LocalMeasurementSourceIdentity().identity(for: URL(string: "ipod-library://item/item.m4a?id=1")!) == nil)
    }

    /// Preparing a library song must not read file attributes of its asset URL.
    @Test func librarySongFingerprintIsStable() throws {
        let url = URL(string: "ipod-library://item/item.m4a?id=1")!
        let fingerprint = try SourceFingerprint(url: url)
        try fingerprint.validate()
        #expect(fingerprint.url == url)
        #expect(try SourceFingerprint(url: URL(string: "ipod-library://item/item.m4a?id=2")!) != fingerprint)
    }
}
