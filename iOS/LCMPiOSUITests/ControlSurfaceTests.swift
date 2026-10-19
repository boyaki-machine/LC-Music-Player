import XCTest

/// The app side of the widgets: their menu link opens the extension.
@MainActor final class ControlSurfaceTests: XCTestCase {
    private var folder: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-uitest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        app = XCUIApplication()
        // A library of its own and the extension closed.
        app.launchArguments = ["-LCMPLibraryFile", folder.appendingPathComponent("library.json").path,
                               "-LCMPExtension", "NO"]
        app.launch()
    }

    override func tearDown() async throws {
        app?.terminate()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// The ☰ of the widgets opens `lcmp://extension`.
    func testMenuLinkOpensTheExtension() {
        let tab = app.buttons["設定"]
        XCTAssertFalse(tab.waitForExistence(timeout: 3), "The extension was already open.")
        app.open(URL(string: "lcmp://extension")!)
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "The menu link did not open the extension.")
    }
}
