
import XCTest

final class AirScanFlowUITests: XCTestCase {
    func testFullMockScanFlow() {
        let app = XCUIApplication()
        app.launch()

        // Home -> tap hero card
        app.staticTexts["掃描文件"].firstMatch.tap()

        // Scan settings -> tap 開始掃描
        let scanButton = app.buttons["開始掃描"].firstMatch
        XCTAssertTrue(scanButton.waitForExistence(timeout: 5))
        scanButton.tap()

        // Wait for mock scan (5s max) -> document should appear in library
        // Navigate to Documents tab
        let docsTab = app.tabBars.buttons["文件"]
        XCTAssertTrue(docsTab.waitForExistence(timeout: 5))
        docsTab.tap()

        // The doc name contains 模擬掃描
        let docCell = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '模擬掃描'")).firstMatch
        XCTAssertTrue(docCell.waitForExistence(timeout: 8), "掃描文件應出現在文件庫")
    }
}
