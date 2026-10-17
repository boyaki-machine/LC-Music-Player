import Foundation

/// Random playback order of one playlist. One cycle plays every entry once, starting from the
/// entry that was current when the order was made. The order lives only in memory.
struct ShuffleOrder {
    let playlistID: UUID
    private(set) var entries: [UUID]

    /// `shuffle(using:)` is a Fisher–Yates shuffle with unbiased bounded random numbers,
    /// so every order of the remaining entries is equally likely.
    init(_ playlist: MusicPlaylist, first: UUID?, using random: inout some RandomNumberGenerator) {
        playlistID = playlist.id
        var rest = playlist.entries.map(\.id).filter { $0 != first }
        rest.shuffle(using: &random)
        entries = (first.map { [$0] } ?? []) + rest
    }

    func contains(_ entry: UUID) -> Bool { entries.contains(entry) }

    func neighbor(of entry: UUID, offset: Int) -> UUID? {
        guard let i = entries.firstIndex(of: entry), entries.indices.contains(i + offset) else { return nil }
        return entries[i + offset]
    }

    /// Follows playlist edits: removed entries leave the order, and added entries join the
    /// part after `current` that has not been played yet. Reordering the playlist has no effect.
    mutating func reconcile(with playlist: MusicPlaylist, current: UUID, using random: inout some RandomNumberGenerator) {
        let ids = playlist.entries.map(\.id), valid = Set(ids)
        entries.removeAll { !valid.contains($0) }
        guard entries.count < ids.count else { return }
        let known = Set(entries)
        for id in ids where !known.contains(id) {
            let start = (entries.firstIndex(of: current) ?? -1) + 1
            entries.insert(id, at: Int.random(in: start...entries.count, using: &random))
        }
    }
}

/// Stores an injected generator; `inout any RandomNumberGenerator` does not satisfy a generic parameter.
struct AnyRandomNumberGenerator: RandomNumberGenerator {
    private var base: any RandomNumberGenerator
    init(_ base: any RandomNumberGenerator) { self.base = base }
    mutating func next() -> UInt64 { base.next() }
}
