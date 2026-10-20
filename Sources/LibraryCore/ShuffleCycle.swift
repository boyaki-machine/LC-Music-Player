import Foundation

/// One shuffle cycle of a playlist: the entries played so far, in the order they were played.
/// The next entry is picked at random from the entries not played yet, so a cycle plays every
/// entry once. The cycle is saved with the library and survives the app being closed.
public struct ShuffleCycle: Codable, Equatable, Sendable {
    public var playlistID: UUID
    public private(set) var played: [UUID]
    public init(playlistID: UUID, first: UUID) { self.playlistID = playlistID; played = [first] }

    func contains(_ entry: UUID) -> Bool { played.contains(entry) }
    /// The entry played before `entry`, and the one played after it when `entry` was reached by going back.
    func neighbor(of entry: UUID, offset: Int) -> UUID? {
        guard let i = played.firstIndex(of: entry), played.indices.contains(i + offset) else { return nil }
        return played[i + offset]
    }
    func unplayed(in list: MusicPlaylist) -> [UUID] {
        let done = Set(played)
        return list.entries.map(\.id).filter { !done.contains($0) }
    }
    /// Every unplayed entry is equally likely (`randomElement` uses unbiased bounded random numbers),
    /// so every order of a cycle is equally likely, as with a Fisher–Yates shuffle.
    func randomUnplayed(in list: MusicPlaylist, using random: inout some RandomNumberGenerator) -> UUID? {
        unplayed(in: list).randomElement(using: &random)
    }
    /// Adds a played entry. Going back and forth (`keepsPosition`) leaves a played entry where it is;
    /// choosing a played entry again moves it to the end, so the entries after it are not replayed.
    mutating func record(_ entry: UUID, keepsPosition: Bool) {
        if keepsPosition, played.contains(entry) { return }
        played.removeAll { $0 == entry }
        played.append(entry)
    }
    /// Entries removed from the playlist leave the cycle; added entries are simply not played yet.
    mutating func reconcile(with list: MusicPlaylist) {
        let valid = Set(list.entries.map(\.id))
        played.removeAll { !valid.contains($0) }
    }
}

/// Stores an injected generator; `inout any RandomNumberGenerator` does not satisfy a generic parameter.
struct AnyRandomNumberGenerator: RandomNumberGenerator {
    private var base: any RandomNumberGenerator
    init(_ base: any RandomNumberGenerator) { self.base = base }
    mutating func next() -> UInt64 { base.next() }
}
