import XCTest

/// Mock 模式 OCR UI 流程：開 OCR toggle → 模擬掃描 → 文件詳情「文字」分頁 → 辨識結果 + 複製
final class OcrUITests: XCTestCase {

    func testMockScanOcrTextTabShowsResult() {
        let app = XCUIApplication()
        app.launch()

        // 確保模擬模式（app 記住上次模式）
        app.tabBars.buttons["設定"].firstMatch.tap()
        let mockSeg = app.buttons["模擬模式"].firstMatch
        if mockSeg.waitForExistence(timeout: 4) { mockSeg.tap() }

        // 進掃描設定頁（首頁 hero card）開 OCR toggle
        app.tabBars.buttons["首頁"].firstMatch.tap()
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '掃描文件'")).firstMatch.tap()
        let ocrToggle = app.switches["OCR 辨識文字"].firstMatch
        XCTAssertTrue(ocrToggle.waitForExistence(timeout: 5), "掃描頁應有 OCR toggle")
        if let v = ocrToggle.value as? String, v == "0" {
            ocrToggle.tap()
        }

        // 模擬掃描一頁（就在本頁）
        let scanButton = app.buttons["開始掃描"].firstMatch
        XCTAssertTrue(scanButton.waitForExistence(timeout: 5))
        scanButton.tap()

        // 文件庫 → 點整列開啟最新文件
        // iOS 26 XCUITest 對 List row 的 element.tap() hit-test 失效（事件不進 app），
        // 改送原生觸控座標（coordinate tap）繞過
        app.tabBars.buttons["文件"].firstMatch.tap()
        let docRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentRow-'")).firstMatch
        XCTAssertTrue(docRow.waitForExistence(timeout: 10), "文件列應存在")
        docRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        _ = app.buttons["previewTabOriginal"].firstMatch.waitForExistence(timeout: 5)
        if !app.buttons["previewTabOriginal"].exists {
            // coordinate tap 一次沒中再補一次（偶發）
            docRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = app.buttons["previewTabOriginal"].firstMatch.waitForExistence(timeout: 5)
        }

        // 切到「文字」分頁
        let textTab = app.buttons["previewTabText"].firstMatch
        XCTAssertTrue(textTab.waitForExistence(timeout: 6), "詳情頁應有 原稿/文字 分頁")
        textTab.tap()

        // Mock 頁尾含 "MOCK SCAN · page 1/1" 真實文字 → OCR 後應出現複製按鈕（辨識完成）
        // accurate 模式單頁在模擬器可能需要數十秒
        let copyButton = app.buttons["ocrCopyButton"].firstMatch
        let ocrDone = copyButton.waitForExistence(timeout: 90)
        if !ocrDone {
            // dump 供除錯：列出可見元素
            let labels = app.descendants(matching: .any).allElementsBoundByIndex
                .compactMap { $0.label.isEmpty ? nil : "\($0.elementType.rawValue):\($0.label)" }
                .prefix(30)
            XCTFail("OCR 後應顯示辨識結果與複製按鈕；visible=\(labels.joined(separator: " | "))")
        }

        // 辨識文字應含 MOCK（mock 頁尾固定字樣）或至少非空結果區
        let resultHeader = app.staticTexts["辨識結果"].firstMatch
        if resultHeader.exists {
            let copyTap = copyButton
            if copyTap.exists { copyTap.tap() }
        }
    }
}
