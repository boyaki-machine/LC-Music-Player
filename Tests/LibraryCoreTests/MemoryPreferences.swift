import Foundation
import LibraryCore

/// In-memory settings for tests, so no UserDefaults suite plist is left in ~/Library/Preferences.
final class MemoryPreferences: PreferenceStoring {
    private var values: [String: Any] = [:]
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
