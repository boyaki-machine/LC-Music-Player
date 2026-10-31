import Foundation
#if os(macOS)
import CoreAudio
#else
import AVFAudio
#endif

/// What identifies the output's format without building an engine: the default output device with
/// its sample rate and output channels on macOS, the audio session's route, rate and channels on iOS.
struct OutputSignature: Equatable {
    let values: [String]
    /// The rate the output renders at, which an engine built for this output reports as well.
    /// The values hold it already, so it takes no part in comparing signatures.
    let sampleRate: Double
    static func == (a: OutputSignature, b: OutputSignature) -> Bool { a.values == b.values }

    static func current() -> OutputSignature? {
        #if os(macOS)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var rate: Float64 = 0
        size = UInt32(MemoryLayout<Float64>.size)
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return nil }
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                             mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, list) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        return OutputSignature(values: [String(device), String(rate.bitPattern), String(channels)], sampleRate: rate)
        #else
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute.outputs.map { $0.portType.rawValue + "/" + $0.uid }
        return OutputSignature(values: route + [String(session.sampleRate.bitPattern), String(session.outputNumberOfChannels)],
                               sampleRate: session.sampleRate)
        #endif
    }
}
