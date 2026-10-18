import AVFAudio
import Foundation
import Testing

/// A quiet 1 kHz stereo tone whose last sample sets the peak. Real-output tests use
/// several seconds so that no natural finish advances playback while a loaded run waits.
func audioFile(_ root: URL, name: String, duration: Double = 3, peak: Float = 0.3) throws -> URL {
    let url = root.appendingPathComponent(name)
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(duration * 48000)))
    buffer.frameLength = buffer.frameCapacity
    for n in 0..<Int(buffer.frameLength) {
        buffer.floatChannelData![0][n] = sin(Float(n) * 2 * .pi * 1000 / 48000) * 0.05
        buffer.floatChannelData![1][n] = -buffer.floatChannelData![0][n]
    }
    buffer.floatChannelData![1][Int(buffer.frameLength) - 1] = peak
    let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer)
    return url
}
