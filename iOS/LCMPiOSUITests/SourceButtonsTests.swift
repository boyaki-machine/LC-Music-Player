import XCTest

/// The source tab's register buttons sit on one row, each label on a single line.
@MainActor final class SourceButtonsTests: XCTestCase {
    func testRegisterButtonsShareOneRow() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-uitest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = XCUIApplication()
        // A library of its own, so the test neither sees nor changes the one in use.
        app.launchArguments = ["-LCMPLibraryFile", folder.appendingPathComponent("library.json").path]
        app.launch()
        defer { app.terminate() }
        let tab = app.buttons["音源"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
        let buttons = ["ファイル", "フォルダ", "ミュージック"].map { app.buttons[$0].firstMatch }
        for button in buttons { XCTAssertTrue(button.waitForExistence(timeout: 5) && button.isHittable, "\(button) is missing.") }
        let frames = buttons.map(\.frame)
        XCTAssertLessThan(frames.map(\.midY).max()! - frames.map(\.midY).min()!, 2, "The buttons are not on one row: \(frames)")
        XCTAssertLessThan(frames[0].maxX, frames[1].minX)
        XCTAssertLessThan(frames[1].maxX, frames[2].minX)
        // One height for all; a label that wraps would also make its button taller than the others.
        XCTAssertLessThan(frames.map(\.height).max()! - frames.map(\.height).min()!, 1, "The buttons differ in height: \(frames)")
        XCTAssertLessThan(frames[2].height, 44, "The music button's label wraps: \(frames)")
    }
}
