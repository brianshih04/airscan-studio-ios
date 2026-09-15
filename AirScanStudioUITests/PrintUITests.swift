
import XCTest

final class PrintUITests: XCTestCase {
    func testPrintFlow() {
        let app = XCUIApplication()
        app.launch()
        sleep(2)

        // 1) seed a doc in mock mode
        app.tabBars.buttons["設定"].firstMatch.tap()
        let mockSeg = app.buttons["模擬模式"].firstMatch
        if mockSeg.waitForExistence(timeout: 4) { mockSeg.tap() }
        app.tabBars.buttons["首頁"].firstMatch.tap()
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '掃描文件'")).firstMatch.tap()
        let btn = app.buttons["開始掃描"].firstMatch
        XCTAssertTrue(btn.waitForExistence(timeout: 5))
        btn.tap()
        sleep(8) // mock generates PDF

        // 2) print it: Home -> 列印 card
        app.tabBars.buttons["首頁"].firstMatch.tap()
        let printCard = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '列印'")).firstMatch
        XCTAssertTrue(printCard.waitForExistence(timeout: 5))
        printCard.tap()

        // 3) tap the seeded document row
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS '模擬掃描'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "文件列應存在於列印頁")
        row.tap()

        // 4) system AirPrint sheet appears
        let printerRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '印表機'")).firstMatch
        XCTAssertTrue(printerRow.waitForExistence(timeout: 20), "系統 AirPrint sheet 應出現")
        defer { UserDefaults.standard.removeObject(forKey: "printTestResult") }

        // 5) select printer: tap the printer row (usually shows 飛航/印表機 name); open picker
        let optionsButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '印表機' OR label CONTAINS 'Printer'")).firstMatch
        if optionsButton.waitForExistence(timeout: 5) {
            optionsButton.tap()
            sleep(3) // let it search for AirPrint printers
            // pick HP if listed
            let hp = app.buttons.staticTexts.matching(NSPredicate(format: "label CONTAINS 'HP'")).firstMatch
            if hp.waitForExistence(timeout: 15) {
                hp.tap()
                sleep(1)
                // tap 列印/Print
                let printBtn = app.buttons["列印"].firstMatch
                if printBtn.waitForExistence(timeout: 5) {
                    printBtn.tap()
                    sleep(5) // allow job to be sent
                    UserDefaults.standard.set("sent", forKey: "printTestResult")
                }
            } else {
                UserDefaults.standard.set("noprinter", forKey: "printTestResult")
            }
        }
    }
}
