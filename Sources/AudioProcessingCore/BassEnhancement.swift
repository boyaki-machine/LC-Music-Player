import AVFAudio
import AudioToolbox
import LevelDSP

/// How much the low band's attacks are emphasized. The listener's choice, kept across launches.
public enum BassEnhancement: Int, CaseIterable, Sendable {
    case off, light, strong
}

/// An in-process effect around `LCMPBassPunch`. It reports no latency and renders in the caller's
/// slice, so the audio is not delayed against the analysis that observes the stage before it.
final class BassPunchUnit: AUAudioUnit {
    /// Sandbox-safe: in the App Sandbox (the macOS app, every iOS app) an unflagged component waits
    /// for the user's consent, its instance fails (-3000) and AVAudioUnitEffect raises an exception.
    static let description = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: 0x6C63_6270 /* lcbp */,
        componentManufacturer: 0x4C43_4D50 /* LCMP */,
        componentFlags: AudioComponentFlags.sandboxSafe.rawValue, componentFlagsMask: 0)
    /// Registers the subclass once, before the first node is made from its description.
    static let registered: Void = {
        AUAudioUnit.registerSubclass(BassPunchUnit.self, as: description, name: "LCMP: Bass Punch", version: 1)
    }()

    /// What the render block reads: set only while render resources are (de)allocated, which the
    /// engine never does while it renders.
    private struct RenderState {
        var punch: OpaquePointer?
        var input: UnsafeMutablePointer<Float>?
        var capacity: AUAudioFrameCount = 0
        var channels = 0
    }
    private let state = UnsafeMutablePointer<RenderState>.allocate(capacity: 1)
    private let inputList = AudioBufferList.allocate(maximumBuffers: 2)
    private let sources = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: 2)
    private let targets = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 2)
    private var inputBus: AUAudioUnitBus!
    private var outputBus: AUAudioUnitBus!
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!

    var strength: BassEnhancement = .off {
        didSet { if let punch = state.pointee.punch { lcmp_bass_punch_set_strength(punch, Int32(strength.rawValue)) } }
    }

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        state.initialize(to: RenderState())
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
    }
    deinit {
        release()
        state.deallocate(); inputList.unsafeMutablePointer.deallocate()
        sources.deallocate(); targets.deallocate()
    }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var canProcessInPlace: Bool { true }
    override func shouldChange(to format: AVAudioFormat, for bus: AUAudioUnitBus) -> Bool {
        format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved && (1...2).contains(format.channelCount)
    }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let format = outputBus.format
        guard inputBus.format.channelCount == format.channelCount, inputBus.format.sampleRate == format.sampleRate,
              let punch = lcmp_bass_punch_create(format.sampleRate, format.channelCount) else {
            super.deallocateRenderResources()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        release()
        lcmp_bass_punch_set_strength(punch, Int32(strength.rawValue))
        lcmp_bass_punch_reset(punch)
        let channels = Int(format.channelCount), capacity = maximumFramesToRender
        state.pointee = RenderState(punch: punch,
                                    input: .allocate(capacity: channels*Int(capacity)),
                                    capacity: capacity, channels: channels)
    }
    override func deallocateRenderResources() {
        release()
        super.deallocateRenderResources()
    }
    private func release() {
        if let punch = state.pointee.punch { lcmp_bass_punch_destroy(punch) }
        state.pointee.input?.deallocate()
        state.pointee = RenderState()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let state = state, inputList = inputList, sources = sources, targets = targets
        return { flags, timestamp, frames, _, output, _, pull in
            let render = state.pointee
            guard let pull else { return kAudioUnitErr_NoConnection }
            guard let punch = render.punch, let input = render.input, frames <= render.capacity else {
                return kAudioUnitErr_TooManyFramesToProcess
            }
            let bytes = frames*UInt32(MemoryLayout<Float>.size)
            inputList.count = render.channels
            for channel in 0..<render.channels {
                inputList[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes,
                                                 mData: input + channel*Int(render.capacity))
            }
            let status = pull(flags, timestamp, frames, 0, inputList.unsafeMutablePointer)
            guard status == noErr else { return status }
            let outputList = UnsafeMutableAudioBufferListPointer(output)
            guard outputList.count == render.channels else { return kAudioUnitErr_FormatNotSupported }
            for channel in 0..<render.channels {
                guard let source = inputList[channel].mData?.assumingMemoryBound(to: Float.self) else {
                    return kAudioUnitErr_InvalidParameter
                }
                if outputList[channel].mData == nil { outputList[channel].mData = UnsafeMutableRawPointer(source) }
                outputList[channel].mDataByteSize = bytes
                sources[channel] = UnsafePointer(source)
                targets[channel] = outputList[channel].mData?.assumingMemoryBound(to: Float.self)
            }
            lcmp_bass_punch_process(punch, sources, targets, frames)
            return noErr
        }
    }
}
