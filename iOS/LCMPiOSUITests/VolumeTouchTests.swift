import XCTest

/// The volume bar runs the height of the animation area, and a finger sets it anywhere along it.
@MainActor final class VolumeTouchTests: XCTestCase {
    private var folder: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-uitest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = ["-LCMPLibraryFile", folder.appendingPathComponent("library.json").path, "-LCMPExtension", "NO"]
        app.launch()
    }

    override func tearDown() async throws {
        app?.terminate()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testTheVolumeBarIsTallAndFollowsTheFinger() throws {
        let button = app.buttons["音量"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 30))
        button.tap()
        let slider = app.descendants(matching: .any)["アプリ内音量"].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        // The bar ends above the buttons and is at least a finger wide.
        XCTAssertGreaterThanOrEqual(slider.frame.width, 43.9)
        XCTAssertGreaterThan(slider.frame.height, 120, "\(slider.frame)")
        XCTAssertLessThan(slider.frame.maxY, button.frame.minY)
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        start.press(forDuration: 0.05, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)))
        XCTAssertTrue(app.staticTexts["100%"].waitForExistence(timeout: 3))
        if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("volume.png"))
        }
        // Half way leaves the shared simulator at an ordinary volume.
        start.press(forDuration: 0.05, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertTrue(app.staticTexts["50%"].waitForExistence(timeout: 3))
    }
}
