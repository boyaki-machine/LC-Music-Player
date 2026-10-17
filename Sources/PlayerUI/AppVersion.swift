import Foundation

/// The app version comes only from the bundle's Info.plist, which the app build writes as
/// <major>.<minor>.<build> (see scripts/app_version.py).
public enum AppVersion {
    public static let displayName = "LC Music Player (LCMP)"
    /// "0.18.42", or "開発版" when no bundle version exists (tests and `swift run`).
    public static func text(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        guard let version = info?["CFBundleShortVersionString"] as? String, !version.isEmpty else { return "開発版" }
        return version
    }
}
