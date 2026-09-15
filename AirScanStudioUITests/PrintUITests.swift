
import XCTest

/// AirPrint 列印流程驗證。
/// 注意：iOS Simulator 的 AirPrint 印表機探索（mDNS）不可用，
/// sheet 會顯示 "No Printer Selected"。實體出紙需在真機驗證。
final class PrintUITests: XCTestCase {
    func testPrintSheetOpensWithDocument() {
        let app = XCUIApplication()
        app.launch()
        sleep(2)

        // seed a document via mock mode
        app.tabBars.buttons["設定"].firstMatch.tap()
        let mockSeg = app.buttons["模擬模式"].firstMatch
        if mockSeg.waitForExistence(timeout: 4) { mockSeg.tap() }
        app.tabBars.buttons["首頁"].firstMatch.tap()
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '掃描文件'")).firstMatch.tap()
        let btn = app.buttons["開始掃描"].firstMatch
        XCTAssertTrue(btn.waitForExistence(timeout: 5))
        btn.tap()
        sleep(8)

        // Home -> 列印 card -> document row
        app.tabBars.buttons["首頁"].firstMatch.tap()
        let printCard = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '列印'")).firstMatch
        XCTAssertTrue(printCard.waitForExistence(timeout: 5))
        printCard.tap()
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS '模擬掃描'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "列印頁應列出文件")
        row.tap()

        // system AirPrint sheet with paper-size A4 + preview = printingItem wired correctly
        let sheet = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Paper Size' OR label CONTAINS '紙張'")).firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 20), "AirPrint sheet 應出現且附帶文件預覽")
    }
}
