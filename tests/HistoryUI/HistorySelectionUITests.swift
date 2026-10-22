import XCTest

final class HistorySelectionUITests: XCTestCase {
    @MainActor
    func testMultipleSelectionAndDeleteAllWithoutConfirmation() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.example.indexrelay")
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        let edit = app.buttons["history.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        edit.tap()
        let first = app.buttons["history.select." + String(format: "%064x", 3)]
        let second = app.buttons["history.select." + String(format: "%064x", 2)]
        let third = app.buttons["history.select." + String(format: "%064x", 1)]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        second.tap()
        let delete = app.buttons["history.bulkDelete"]
        XCTAssertEqual(delete.label, "選択した2件を削除")
        XCTAssertEqual(first.value as? String, "選択済み")
        XCTAssertEqual(second.value as? String, "選択済み")
        first.tap()
        XCTAssertEqual(delete.label, "選択した1件を削除")
        first.tap()
        XCTAssertEqual(delete.label, "選択した2件を削除")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "two-recordings-selected"; screenshot.lifetime = .keepAlways; add(screenshot)
        delete.tap()
        XCTAssertFalse(first.exists)
        XCTAssertFalse(second.exists)
        XCTAssertTrue(third.exists)
        XCTAssertEqual(app.alerts.count, 0)
        app.buttons["history.selectAll"].tap()
        XCTAssertEqual(delete.label, "選択した1件を削除")
        delete.tap()
        XCTAssertTrue(app.staticTexts["文字起こしはまだありません"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 0)
        edit.tap()
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.staticTexts["表示・保存件数"].waitForExistence(timeout: 5))
    }
}
