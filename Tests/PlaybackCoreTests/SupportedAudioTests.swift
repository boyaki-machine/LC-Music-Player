import Foundation
import Testing
@testable import PlaybackCore

@Test func acceptsOnlySupportedLocalFiles() {
    #expect(SupportedAudio.accepts(URL(fileURLWithPath: "/tmp/music.FLAC")))
    #expect(!SupportedAudio.accepts(URL(fileURLWithPath: "/tmp/music.dsf")))
    #expect(!SupportedAudio.accepts(URL(string: "https://example.com/music.mp3")!))
}
