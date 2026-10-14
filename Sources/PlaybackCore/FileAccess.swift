import Foundation

/// Keeps a user-selected URL's access alive until playback releases the file.
public final class FileLease: Sendable {
    private let release: @Sendable () -> Void

    public init(release: @escaping @Sendable () -> Void = {}) {
        self.release = release
    }

    deinit { release() }
}

@MainActor
public protocol FileAccess {
    func acquire(_ url: URL) throws -> FileLease
}

public struct LocalFileAccess: FileAccess {
    public init() {}

    public func acquire(_ url: URL) throws -> FileLease {
        guard url.isFileURL else { throw PlaybackError.inaccessibleFile }
        let scoped = url.startAccessingSecurityScopedResource()
        let lease = FileLease {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        // An unscoped URL can still be readable in a development app.
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw PlaybackError.inaccessibleFile
        }
        return lease
    }
}
