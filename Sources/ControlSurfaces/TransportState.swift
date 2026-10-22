import Foundation

/// What the home screen widgets show. They never carry the song, only the transport state.
/// The lock screen and the Dynamic Island are left to the system "Now Playing".
public enum TransportState: String, Codable, Hashable, Sendable {
    case playing, paused, stopped
}

/// What the `lcmp://` scheme accepts. Any web page or app can open the scheme, so a link only shows
/// a screen of the app; everything else, including extra parts on a known link, does nothing.
public enum AppLink: CaseIterable, Equatable, Sendable {
    /// `lcmp://extension`: the ☰ of the widgets.
    case showExtension

    public static let scheme = "lcmp"

    public var url: URL {
        switch self {
        case .showExtension: URL(string: "\(Self.scheme)://extension")!
        }
    }

    /// Only the exact URL of a link matches, compared component by component.
    public init?(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let link = Self.allCases.first(where: { URLComponents(url: $0.url, resolvingAgainstBaseURL: false) == components })
        else { return nil }
        self = link
    }
}

/// The buttons of the widgets. `menu` opens the app with the extension shown.
public enum TransportCommand: String, CaseIterable, Sendable {
    case previous, playPause, next, stop, menu

    /// Opens the app and shows the extension (`lcmp://extension`).
    public static let menuURL = AppLink.showExtension.url

    public var label: String {
        switch self {
        case .previous: "前の曲"
        case .playPause: "再生／一時停止"
        case .next: "次の曲"
        case .stop: "停止"
        case .menu: "メニュー"
        }
    }
}

/// The transport state the app shares with the widgets through an App Group.
/// Without the App Group (a free personal team may not have it) `defaults` is nil:
/// the widgets then cannot know the state and show one toggle glyph that never lights.
public struct SharedTransportStore {
    public static let stateKey = "transportState"
    /// The kind of the home screen widgets, which the app reloads when the state changes.
    public static let widgetKind = "LCMPPlayer"
    /// The Info.plist key holding the App Group identifier of the app and the widgets.
    public static let appGroupInfoKey = "LCMPAppGroup"
    public let defaults: UserDefaults?

    public init(defaults: UserDefaults?) { self.defaults = defaults }

    /// The App Group of this signing, if the entitlement is present.
    public static func appGroup(bundle: Bundle = .main) -> SharedTransportStore {
        guard let group = bundle.object(forInfoDictionaryKey: appGroupInfoKey) as? String, !group.isEmpty,
              FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil
        else { return SharedTransportStore(defaults: nil) }
        return SharedTransportStore(defaults: UserDefaults(suiteName: group))
    }

    public var isShared: Bool { defaults != nil }

    /// nil when there is no App Group; `.stopped` before the app has written anything.
    public var state: TransportState? {
        guard let defaults else { return nil }
        return defaults.string(forKey: Self.stateKey).flatMap(TransportState.init(rawValue:)) ?? .stopped
    }

    public func write(_ state: TransportState) {
        defaults?.set(state.rawValue, forKey: Self.stateKey)
    }
}
