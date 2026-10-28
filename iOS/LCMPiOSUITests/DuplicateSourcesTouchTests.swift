import XCTest

/// Choosing the extra copies of songs registered twice, from selection mode, and removing them.
@MainActor final class DuplicateSourcesTouchTests: XCTestCase {
    private var folder: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-uitest-\(UUID().uuidString)")
        // The same album twice: "01 Song" in both folders is one song, "02 Other" only in the first.
        let copies = ["flac", "aac"].map { folder.appendingPathComponent("music/\($0)/Blue") }
        for directory in copies { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Self.silence.write(to: copies[0].appendingPathComponent("01 Song.wav"))
        try Self.silence.write(to: copies[0].appendingPathComponent("02 Other.wav"))
        try Self.silence.write(to: copies[1].appendingPathComponent("01 Song.wav"))
        app = XCUIApplication()
        app.launchArguments = ["-LCMPLibraryFile", folder.appendingPathComponent("library.json").path,
                               "-LCMPImportPaths", copies.map(\.path).joined(separator: ",")]
        app.launch()
        let tab = app.buttons["音源"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        XCTAssertTrue(app.staticTexts["3曲"].waitForExistence(timeout: 30), "The imported songs did not reach the library.")
    }

    override func tearDown() async throws {
        app?.terminate()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testChoosingDuplicatesSelectsTheExtraCopyAndRemovesIt() throws {
        app.buttons["曲を選択して除外"].tap()
        XCTAssertTrue(app.staticTexts["重複1曲"].waitForExistence(timeout: 5))
        let keep = app.buttons["可逆形式を残す"]
        XCTAssertTrue(keep.isHittable && app.buttons["非可逆形式を残す"].isHittable)
        keep.tap()
        let remove = app.buttons["1曲を除外"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5) && remove.isEnabled)
        snapshot("source-duplicates")
        remove.tap()
        let confirm = app.buttons.matching(identifier: "1曲を除外").element(boundBy: 1)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        snapshot("source-duplicates-confirm")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["2曲"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["重複1曲"].exists)
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
