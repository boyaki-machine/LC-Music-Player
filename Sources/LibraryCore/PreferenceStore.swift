import Foundation

/// Playback settings storage for LibraryController. Tests inject an in-memory store instead of
/// UserDefaults suites, which leave empty plist files in ~/Library/Preferences.
public protocol PreferenceStoring: AnyObject {
    func bool(forKey key: String) -> Bool
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: PreferenceStoring {}
