
import XCTest

final class RealScanUITests: XCTestCase {
    func testRealScanAgainstHP() {
        let app = XCUIApplication()
        app.launch()

        // Switch to real mode first (Settings tab)
        app.tabBars.buttons["設定"].tap()
        let seg = app.buttons["真實模式"]
        if seg.waitForExistence(timeout: 4) {
            seg.tap()
        } else {
            let txt = app.staticTexts["真實模式"]
            if txt.waitForExistence(timeout: 3) { txt.tap() }
        }

        // Go to Devices, manually add the real HP
        app.tabBars.buttons["首頁"].tap()
        app.staticTexts["裝置"].firstMatch.tap()

        let hostField = app.textFields["IP 位址，例如 10.1.121.182"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 5))
        hostField.tap()
        hostField.typeText("10.1.121.175")
        app.buttons["加入"].tap()

        // Scanner row should appear and get selected
        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '10.1.121.182'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "手動掃描器應出現在清單")

        // Go scan: 首頁 -> 掃描文件 -> 開始掃描
        app.navigationBars.buttons.firstMatch.tap() // back
        app.tabBars.buttons["首頁"].tap()
        app.staticTexts["掃描文件"].firstMatch.tap()
        let scanButton = app.buttons["開始掃描"].firstMatch
        XCTAssertTrue(scanButton.waitForExistence(timeout: 5))
        scanButton.tap()

        // Real scan produces name "掃描 MM/dd HH:mm" (mock ones are "模擬掃描 ...")
        app.tabBars.buttons["文件"].tap()
        let realDoc = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '掃描 1'")).firstMatch
        XCTAssertTrue(realDoc.waitForExistence(timeout: 120), "真實掃描文件（掃描 MM/dd）應出現在文件庫")
    }
}
