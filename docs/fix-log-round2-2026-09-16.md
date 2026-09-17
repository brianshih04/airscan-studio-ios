# AirScan Studio 修復記錄（Round 2）

- 日期：2026-09-17
- 依據：`docs/rereview-2026-09-16.md`「該立即修的」4 項（#8、#5+#22、B1、B3）
- 範圍：僅這 4 項；eSCL 協定行為與送出的 XML 格式完全未動（ESCLClient 僅零改動，本輪未觸及協定相關程式碼）
- 未 git commit（依指示）

---

## Fix #8 — runRealScan 錯誤路徑 defer 清 eSCL job（P1）

- 檔案：`Scan/ScanViewModel.swift`
- 問題：`pullPage`/`createJob` 拋非取消錯誤（如網路斷的 URLError）時直接 throw 出 `runRealScan`，`cleanupJob` 只在 happy path 執行，job 殘留掃描器端。HP 已知會因 Aborted job 堆積 wedge（需 aging 才清）。
- 改法：
  - `createJob` 成功後立即建立 `var cleanedJobURL: URL?` + `defer`：任何離開（錯誤、取消、正常）都會檢查 `cleanedJobURL` 是否仍有未清理的 job。
  - 冪等設計（避免與 cancelScan / happy path 重複 DELETE）：
    - 主路徑與 flatbed 每頁成功清理後把 `cleanedJobURL` 歸 nil → defer 不重跑；
    - `cancelScan` 已先行清理（把 `activeJobURL` 清 nil）→ defer 內 `cleanupTrackedJob` 以 `activeJobURL == jobURL` 判斷已清理，跳過；
    - 取消路徑（`Task.isCancelled == true`）→ 跳過（cancelScan 的 detached cleanupJob 已處理），不雙 DELETE。
  - flatbed 逐頁迴圈的新 job 也透過 `track()` 註冊同一 defer 機制（頁掃到一半拋錯同樣清理）。
  - 抽出 `cleanupTrackedJob(client:jobURL:cancelled:)` 方法（internal）供單元測試驗證呼叫路徑。
- 測試（ReviewFixTests）：
  - `testCleanupTrackedJobSkipLogic`：非取消錯誤 → 清理執行（activeJobURL 清 nil）；取消 → 跳過；cancelScan 已清理（activeJobURL=nil）→ 跳過不雙 DELETE。
  - `testRealScanErrorPathLeavesNoTrackedJob`：對 127.0.0.1:1（本機 connection refused，立即失敗）跑真實掃描 → 正確拋錯、`activeJobURL`/`activeESCLClient` 不殘留。
- 測試結果：見文末。

## Fix #5 + #22 — manual 裝置選擇優先序 / 滑動刪除 / port 驗證（P1）

- 檔案：`Scan/ScanViewModel.swift`、`Scan/ScannerBrowser.swift`、`UI/AppUI.swift`
- 問題：
  - #5：`selectedScanner` 的 `manual-` 開頭裝置一律霸佔，使用者明確選了 Bonjour 探索到的裝置也選不到（雙機工作流 session 內必踩）。
  - #22：手動輸入 port 無 1-65535 範圍檢查（0/負數/65536 都會被接受拼出壞 URL）；manual 裝置無法移除，#5 的霸佔永久化。
- 改法：
  - **優先序改為**：`selectedScannerID` 有值且存在於清單 → 使用者明確選擇贏；無選擇 → manual 裝置次之（保留自動化測試 pin 的意圖）；最後回退第一台探索結果。手動加入時仍會 `selectedScannerID = manual-...`（明確選擇的一種），行為與舊版相同；差別只在使用者後續點選其他裝置時不再被霸佔。
  - **port 驗證**：新增 `validateManualHost(_:) -> ManualHostValidation`（nonisolated static 純函式）：解析 `ip` / `ip:port`，port 需 `1...65535`，`ip:port:extra`、空 port、非數字 port 一律 invalid。`addManual` 回傳 `Bool`（無效輸入不加入），UI 顯示「位址或連接埠無效（port 需 1-65535）」。
  - **滑動刪除**：裝置頁 manual 裝置列出於「手動加入」區（含選中勾選），`swipeActions` 滑動刪除 → `removeManual(scanner:)` → `browser.removeScanner(id:)`；若刪的是目前選中裝置，選擇回退第一台剩餘裝置。Bonjour 區塊改只列非 manual 裝置（manual 移至自己的區，不再重複顯示）。`removeManual` 只接受 `manual-` 開頭 id（探索結果不可誤刪）。
- 測試（ReviewFixTests）：
  - `testSelectedScannerExplicitChoiceBeatsManualHijack`：四段優先序（manual 預設贏 → 明確選 HP 贏 → 選擇失效回退 manual → 無 manual 回退第一台）。
  - `testManualHostPortValidation`：合法（預設 80、1、65535、8080）與非法（0、65536、-1、abc、空字串、非 IP、多冒號、空 port）全矩陣。
  - `testAddManualRejectsInvalidAndRemoveManualFallsBack`：無效不加入；manual 可移除；刪選中的 manual 後選擇回退；非 manual 裝置不可經 removeManual 移除。
- 測試結果：見文末。

## Fix B1 — OCR 刪除復活（P1）

- 檔案：`Scan/ScanViewModel.swift`、`OCR/OCRService.swift`
- 問題：`runOCRAfterScan` 的 `Task.detached` 持有 doc；使用者刪除文件後 OCR 完成，`processDocument` 會 (a) 重寫 `<file>.txt`、(b) 對已刪路徑 `moveItem(tmp → url)` 把含文字層的 PDF 寫回原路徑 → 磁碟出現 UI 看不見、無法再刪的孤兒 PDF+txt。
- 改法（三層防護，用最簡組合）：
  1. **MainActor 側已刪路徑集合**：`deletedDocumentPaths: Set<String>`；`deleteDocument` 時 insert + 清 `ocrOutcome[path]` + `ocrRunningPaths.remove(path)`（原本的 entry 殘留小洩漏一併處理）。
  2. **runOCRAfterScan 完成回呼（MainActor）**：寫 outcome 前檢查 `deletedDocumentPaths.contains(path)` 與 `documents.contains { $0.fileURL.path == path }`，已刪則丟棄（不記 outcome）；錯誤回呼同理。`runOCRNow` 對已刪文件不再受理。
  3. **OCRService 落地層**（不動 replaceItemAt/moveItem 本身，在呼叫前攔）：
     - 辨識開始前來源已不存在 → 直接回空結果（不寫 txt、不進 PDF 流程）；
     - PDF 逐頁辨識間檢查來源存在性，被刪即中止；
     - 落地前（寫 txt / makeSearchablePDF / replaceItemAt 之前）再檢查一次，來源已被刪 → 回空結果，不寫回。
- 測試（ReviewFixTests）：
  - `testDeletedDocumentOcrDiscarded`：deleteDocument 後 `deletedDocumentPaths` 有記錄、`ocrOutcome`/`ocrRunningPaths` entry 已清、runOCRNow 不再啟動。
  - `testOcrProcessDeletedSourceWritesNothing`：對不存在的來源跑 `OCRService.processDocument` → 不拋錯、不寫 txt、不寫回原路徑、目錄無任何孤兒檔。
- 測試結果：見文末。

## Fix B3 — Mock 模式記憶體（P1）

- 檔案：`Scan/MockScanGenerator.swift`
- 問題：(a) `generatePage` 的 `UIGraphicsImageRenderer` 未設 `format.scale=1`，2480×3508 的模擬頁被螢幕 3x scale 渲染成 7440×10524（~313MB/頁 bitmap）；(b) `generatePDF` 用 `PDFPage(image:)` 全頁解碼駐留 + `pdf.write`，50 頁 ADF mock 峰值需求 ~15.6GB → jetsam（Fix 2 只修了 real 路徑）。
- 改法：
  - `generatePage`：`UIGraphicsImageRendererFormat.default()` + `format.scale = 1`（與 OCRService.downsampled 同型修法）。
  - `generatePDF`：改呼叫 `ScanViewModel.writePDF(from:to:)` 串流路徑（real 掃描同一條）：逐頁產 JPEG data → 逐頁解碼寫入 CGPDFContext → 每頁釋放，峰值 = 單頁。回傳實際寫入頁數（`@discardableResult`，既有呼叫端不受影響）。mock 輸出仍為 PDF（副檔名與預覽行為不變）。
- 測試（ReviewFixTests）：
  - `testMockPDFCorrectMediaBoxAndPageCount`：3 頁 A4 mock PDF — 每頁 mediaBox 2480×3508（非 Letter 612×792）、頁數 3、回傳寫入 3。
  - `testMockPageNotScaledByScreen`：generatePage 輸出像素就是 2480×3508（不被 3x 放大）。
- 既有測試影響：`OCRServiceTests`/`ESCLTests` 對 `generatePDF` 的呼叫（簽名相容）與 `generatePage` 的行為斷言（JPEG data 可解碼）全數照舊通過；mock PDF 頁面尺寸從此精確 2480×3508（原 3x 版縮回相同邏輯尺寸）。
- 測試結果：見文末。

---

## 驗證

指令（依指示，硬體整合測試排除）：

```
xcodebuild -project AirScanStudio.xcodeproj -scheme AirScanStudio \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/dd test \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:AirScanStudioTests \
  -only-testing:AirScanStudioUITests/OcrUITests \
  -only-testing:AirScanStudioUITests/AirScanFlowUITests \
  -skip-testing:AirScanStudioTests/ScanViewModelIntegrationTests \
  -skip-testing:AirScanStudioTests/OCRHardwareTests
```

- 結果：**全綠**。`** TEST SUCCEEDED **`（exit 0）
  - AirScanStudioTests（排除 2 個硬體 class 後）：35 tests, 0 failures（含本次新增 9 項：
    testSelectedScannerExplicitChoiceBeatsManualHijack / testManualHostPortValidation /
    testAddManualRejectsInvalidAndRemoveManualFallsBack / testCleanupTrackedJobSkipLogic /
    testRealScanErrorPathLeavesNoTrackedJob / testDeletedDocumentOcrDiscarded /
    testOcrProcessDeletedSourceWritesNothing / testMockPDFCorrectMediaBoxAndPageCount /
    testMockPageNotScaledByScreen）
  - AirScanStudioUITests：OcrUITests + AirScanFlowUITests = 2 tests, 0 failures（mock 掃描→OCR 文字分頁、mock 全流程在 B3 改寫後照常通過）
  - 合計 37 passed / 0 failed

## 未動（依指示保留）

- eSCL 協定行為與 XML（`scanSettingsXML`、polling 順序、timeout、backoff 全未動；本輪 ESCLClient.swift 零改動）
- 其餘複審清單項目（B4 mixed-size writePDF、B5 取消後文件入庫、B6 URLSession 洩漏、B8 OCR 頁數對齊、B9 ocrOutcome key 殘留（部分已順手清：deleteDocument 現在會清 entry）、#10 縮圖、#13 settings 持久化等）留待下輪
- git commit
