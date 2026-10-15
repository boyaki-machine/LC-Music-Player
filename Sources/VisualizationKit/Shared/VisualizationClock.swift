import AVFAudio
import Darwin

public enum VisualizationClock {
    public static func now() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
}

public enum VisualizationActivity: Sendable { case inactive, playing, paused }
