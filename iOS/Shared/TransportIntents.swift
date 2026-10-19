import AppIntents
import ControlSurfaces

/// Where the transport intents land. The app registers its handler at launch; the widget
/// extension never sets it, because the system runs audio playback intents in the app's process.
@MainActor enum TransportIntentHandler {
    static var handle: ((TransportCommand) -> Void)?
}

/// The buttons of the widgets. They are compiled into both the app and the widget extension
/// so that the system finds them in the app and runs them there.
struct PlayPauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "LCMPの再生／一時停止"
    static let isDiscoverable = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        TransportIntentHandler.handle?(.playPause); return .result()
    }
}

struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "LCMPの前の曲"
    static let isDiscoverable = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        TransportIntentHandler.handle?(.previous); return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "LCMPの次の曲"
    static let isDiscoverable = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        TransportIntentHandler.handle?(.next); return .result()
    }
}

struct StopIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "LCMPの停止"
    static let isDiscoverable = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        TransportIntentHandler.handle?(.stop); return .result()
    }
}
