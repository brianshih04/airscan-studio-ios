
import XCTest

/// 需要真機掃描器在網路上（由 manualScannerHost UserDefaults 指定）。
/// 以 `-skip-testing` 預設排除，手動執行。
final class HardwareScanTests: XCTestCase {
    func testScanWithPinnedScanner() {
        let app = XCUIApplication()
        app.terminate()
        // Fresh launch: clears any lingering alert/state from prior runs
        app.launch()
        sleep(3)

        // Dismiss any lingering alert from previous runs
        let okBtn = app.buttons["好"].firstMatch
        if okBtn.waitForExistence(timeout: 2) { okBtn.tap() }

        // Home -> hero (scan settings)
        app.tabBars.buttons["首頁"].firstMatch.tap()
        sleep(1)
        let hero = app.buttons["heroScanCard"].firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 8), "hero card 應存在")
        hero.tap()
        let scanButton = app.buttons["開始掃描"].firstMatch
        XCTAssertTrue(scanButton.waitForExistence(timeout: 6))
        scanButton.tap()

        // If an error alert appears, fail with its message
        let alertTitle = app.staticTexts["掃描失敗"].firstMatch
        if alertTitle.waitForExistence(timeout: 10) {
            let msg = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '掃描' OR label CONTAINS 'HTTP'")).allElementsBoundByIndex.last
            XCTFail("掃描失敗 alert: \(msg?.label ?? "?")")
            app.buttons["好"].firstMatch.tap()
            return
        }

        // Wait for the real document to land in the library
        app.tabBars.buttons["文件"].firstMatch.tap()
        let doc = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '掃描 '")).firstMatch
        XCTAssertTrue(doc.waitForExistence(timeout: 90), "真實掃描文件應出現在文件庫")
    }
}
