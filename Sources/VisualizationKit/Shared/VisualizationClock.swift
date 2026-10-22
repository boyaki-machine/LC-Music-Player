import AVFAudio
import Darwin

public enum VisualizationClock {
    public static func now() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
    /// How long before its estimated presentation time a result is adopted. Results are adopted
    /// on a 33ms clock, on average half a period after they are due, and a drawing reaches the
    /// screen about one display refresh later. Adopting this much earlier centers the error on
    /// the sound instead of always showing late; a picture slightly ahead of the sound is also
    /// much harder to notice than one behind it.
    public static let presentationLead = 0.025
}

public enum VisualizationActivity: Sendable { case inactive, playing, paused }
