import XCTest

/// The source tab with a finger: narrowing the library with the search field, removing one song
/// with its own trash button, and removing a whole group in selection mode.
@MainActor final class SourceSearchTouchTests: XCTestCase {
    private var folder: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-uitest-\(UUID().uuidString)")
        let music = ["aac", "mp3"].map { folder.appendingPathComponent("music/\($0)") }
        for (kind, directory) in zip(["aac", "mp3"], music) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for i in 1...3 { try Self.silence.write(to: directory.appendingPathComponent("\(kind)-song-\(i).wav")) }
        }
        app = XCUIApplication()
        // A library of its own, so the test neither sees nor changes the one in use.
        app.launchArguments = ["-LCMPLibraryFile", folder.appendingPathComponent("library.json").path,
                               "-LCMPImportPaths", music.map(\.path).joined(separator: ",")]
        app.launch()
        let tab = app.buttons["音源"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        XCTAssertTrue(app.staticTexts["6曲"].waitForExistence(timeout: 30), "The imported songs did not reach the library.")
    }

    override func tearDown() async throws {
        app?.terminate()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testSearchOpensMatchingGroupsAndATrackCanBeRemovedAlone() throws {
        XCTAssertFalse(song("aac-song-1").exists, "Groups start closed.")
        app.buttons["音源を検索"].tap()
        let field = app.textFields["sourceSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // One word: the test folder's random name may contain any digit.
        field.typeText("AAC-SONG-2")
        XCTAssertTrue(song("aac-song-2").waitForExistence(timeout: 5), "The matching song's group did not open.")
        XCTAssertFalse(song("aac-song-1").exists || song("mp3-song-2").exists)
        XCTAssertTrue(app.staticTexts["1 / 6曲"].exists)
        snapshot("source-search")
        // The trash stays clear of the right edge, where the scroll indicator runs.
        let trash = app.buttons["「aac-song-2」を除外"]
        XCTAssertTrue(trash.isHittable)
        XCTAssertLessThan(trash.frame.maxX, app.windows.firstMatch.frame.maxX - 20, "The trash is too close to the edge: \(trash.frame)")
        trash.tap()
        let confirm = app.buttons["ライブラリから除外"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["一致する曲はありません。"].waitForExistence(timeout: 5))
        // Closing the search returns the full, closed list.
        app.buttons["検索を閉じる"].tap()
        XCTAssertTrue(app.staticTexts["5曲"].waitForExistence(timeout: 5))
        XCTAssertFalse(field.exists || song("aac-song-1").exists)
    }

    /// The keyboard leaves room for only a few rows: scrolling or touching the list puts it away.
    func testScrollingOrTouchingTheListPutsTheKeyboardAwayAndKeepsTheSearch() throws {
        app.buttons["音源を検索"].tap()
        let field = app.textFields["sourceSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("song")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(song("aac-song-1").waitForExistence(timeout: 5))
        song("aac-song-1").swipeUp()
        XCTAssertTrue(waitForKeyboardToHide(), "Scrolling the list left the keyboard up.")
        XCTAssertEqual(field.value as? String, "song")
        XCTAssertTrue(app.staticTexts["6 / 6曲"].exists)
        // Back in the field, then a touch on a group heading.
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "value == %@", "開いています")).firstMatch.tap()
        XCTAssertTrue(waitForKeyboardToHide(), "Touching the list left the keyboard up.")
        XCTAssertEqual(field.value as? String, "song")
        snapshot("source-search-keyboard-hidden")
    }

    func testSelectionModeRemovesTheChosenGroupInOneConfirmation() throws {
        app.buttons["曲を選択して除外"].tap()
        let group = app.buttons["フォルダ「mp3」の3曲を選択"]
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.tap()
        let remove = app.buttons["3曲を除外"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5) && remove.isEnabled)
        snapshot("source-selection")
        remove.tap()
        // The dialog repeats the count; its button is the second match.
        let confirm = app.buttons.matching(identifier: "3曲を除外").element(boundBy: 1)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["3曲"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["曲を選択して除外"].exists, "Selection mode did not end after removing.")
    }

    private func waitForKeyboardToHide() -> Bool {
        let hidden = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        return XCTWaiter().wait(for: [hidden], timeout: 5) == .completed
    }

    private func song(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    /// Writes the screen for review when the runner has `LCMP_UI_SNAPSHOTS`
    /// (passed as `TEST_RUNNER_LCMP_UI_SNAPSHOTS` to xcodebuild).
    private func snapshot(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }

    /// One second of 16-bit mono silence at 8 kHz as a WAV file.
    private static let silence: Data = {
        let rate: UInt32 = 8000, bytes = rate * 2
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
