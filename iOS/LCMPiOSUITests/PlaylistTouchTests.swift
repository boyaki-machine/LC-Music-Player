import XCTest

/// Real touches on the extension's playlist: scrolling a list longer than the screen,
/// and the row gestures (tap, double tap, long press and drag) on top of it.
@MainActor final class PlaylistTouchTests: XCTestCase {
    private var folder: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-uitest-\(UUID().uuidString)")
        let music = folder.appendingPathComponent("music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        for i in 1...40 { try Self.silence.write(to: music.appendingPathComponent(String(format: "track-%02d.wav", i))) }
        app = XCUIApplication()
        // A library of its own, so the test neither sees nor changes the one in use.
        app.launchArguments = ["-LCMPLibraryFile", folder.appendingPathComponent("library.json").path,
                               "-LCMPImportPaths", music.path]
        app.launch()
        XCTAssertTrue(row(1).waitForExistence(timeout: 30), "The imported songs did not appear in the playlist.")
    }

    override func tearDown() async throws {
        app?.terminate()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testLongPlaylistScrollsWithAFingerOnTheRows() {
        XCTAssertTrue(row(1).isHittable)
        XCTAssertFalse(row(40).exists && row(40).isHittable)
        // Quick flicks that start on a row, as a finger does; a long press would lift the row instead.
        for _ in 0..<8 where !(row(40).exists && row(40).isHittable) {
            let start = row(visibleIndex()).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -300)),
                        withVelocity: .fast, thenHoldForDuration: 0)
        }
        XCTAssertTrue(row(40).exists && row(40).isHittable, "The playlist did not scroll to its last song.")
        XCTAssertFalse(row(1).isHittable)
    }

    func testTapSelectsDoubleTapPlaysAndLongPressReorders() {
        row(3).tap()
        XCTAssertTrue(waitForLabel(of: 3, containing: "選択中"), "A tap did not select the song: \(row(3).label)")
        row(5).doubleTap()
        XCTAssertTrue(waitForLabel(of: 5, containing: "再生中"), "A double tap did not play the song: \(row(5).label)")
        // Lift the first song and drop it below the third one.
        row(1).press(forDuration: 0.8, thenDragTo: row(4))
        let moved = expectation(for: NSPredicate { _, _ in self.row(1).frame.minY > self.row(3).frame.minY }, evaluatedWith: nil)
        wait(for: [moved], timeout: 5)
    }

    private func row(_ number: Int) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", String(format: "track-%02d", number))).firstMatch
    }

    /// The lowest numbered song that is on screen now.
    private func visibleIndex() -> Int { (1...40).first { row($0).exists && row($0).isHittable } ?? 1 }

    private func waitForLabel(of number: Int, containing text: String) -> Bool {
        let found = expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: row(number))
        return XCTWaiter().wait(for: [found], timeout: 10) == .completed
    }

    /// Twenty seconds of 16-bit mono silence at 8 kHz as a WAV file, long enough to still be playing when checked.
    private static let silence: Data = {
        let rate: UInt32 = 8000, bytes = rate * 2 * 20
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(rate); put(rate * 2); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        data.append(Data(count: Int(bytes)))
        return data
    }()
}
