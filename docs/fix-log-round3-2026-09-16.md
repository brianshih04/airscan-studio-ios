# AirScan Studio 修復記錄（Round 3）

- 日期：2026-09-17
- 依據：`docs/rereview-2026-09-16.md` P2 三項（#26、#25、#10）
- 範圍：僅 `UI/AppUI.swift` 與 `AirScanStudioTests/ReviewFixTests.swift`；eSCL（ESCLClient）與 OCRService 邏輯零改動
- 未 git commit（依指示）

---

## Fix #26 — PDFKitView 不反應檔案變化（P2）

- 檔案：`UI/AppUI.swift`（PDFKitView）
- 問題：OCR 背景任務以 `replaceItemAt` 原地替換 PDF 後 URL 不變，`updateUIView` 空實作 → 已開啟的預覽永遠顯示不可搜尋的舊版（掃完立刻開預覽＋OCR 尚在背景的情境必踩）。
- 改法：
  - 新增 `PDFFileStamp`（`Equatable`，`modificationDate + size`，`static func of(url:)` 檔案不存在回 nil）。
  - `PDFKitView` 加 `Coordinator` 記住已載入內容的 stamp（`makeUIView` 時記錄初始 stamp）。
  - `updateUIView`：讀當下 stamp，與 coordinator 的 `loadedStamp` 相同 → 直接 return（避免每次重繪重新 parse 造成無限重繪/主執行緒卡幀）；不同 → `PDFDocument(url:)` 重載並更新 stamp。
  - 邊界：檔案已不存在（stamp==nil）→ `uiView.document = nil` 清空預覽；檔案存在但 parse 失敗（暫態）→ 保留舊內容，下次 updateUIView 再試。
  - OCR 完成回呼寫 `@Published ocrOutcome` → `objectWillChange` → 詳情頁重繪 → `updateUIView` 觸發 → 重載。掃描期間 phase 變化同樣觸發。
- 測試（ReviewFixTests）：`testPDFFileStampReflectsFileReplacement` — 不存在 → nil；未變時兩次讀取相等；原地替換（URL 不變、大小變）→ stamp 必須改變。PDFKitView 本身（UIViewRepresentable）不直接測，以 helper 單測覆蓋判斷核心。

## Fix #25 — 「從檔案選擇…」假按鈕（P2）

- 檔案：`UI/AppUI.swift`（PrintView）
- 問題：按鈕文案「從檔案選擇…」，行為是 stub 直接列印最新文件（`pickAndPrintFromFiles`），誤導使用者。
- 改法：移除整個按鈕 Section 與 `pickAndPrintFromFiles()` 函式（最簡、誠實）；AirPrint footer 文案（「使用系統 AirPrint 選擇印表機、份數與紙張。」）移入「掃描文件」Section 的 footer 保留。未實作 file picker（那是新功能）。
- 測試：既有 PrintUITests 不觸碰該按鈕（本輪指令未含 PrintUITests，不受影響）；無新測試（UI 移除項）。

## Fix #10 — DocumentRow 縮圖主執行緒全檔 parse（P2）

- 檔案：`UI/AppUI.swift`（DocumentRow）
- 問題：`thumbnail` 在 `body` 內同步 `PDFDocument(url:)` / `Data(contentsOf:)` 全檔載入 — 每次 List 重繪都重 parse；OCR 原地替換後檔案更大（多文字層），50 頁 PDF 在主執行緒滑列表時卡幀。
- 改法：
  - `@State private var thumbnail: UIImage?` + `.task(id: doc.fileURL)`：離開 row 會自動取消；同一 row 重繪不會重跑 task（id 未變）。
  - 新增 `DocumentThumbnailCache`：`static let shared` 包 `NSCache<NSString, UIImage>`（countLimit 200），跨 row / 跨重繪共用，同一 URL 不重複 parse。
  - 新增 `DocumentThumbnailLoader`：
    - `thumbnail(for:)`：`withCheckedContinuation` + `DispatchQueue.global(qos: .userInitiated)` 背景產生 — PDF 用 `PDFPage.thumbnail(of: CGSize(240×320), for: .mediaBox)`（2x @120×160 pt 顯示尺寸），圖檔解碼 `UIImage(data:)`。
    - `cachedThumbnail(for:)`（`@MainActor`）：快取優先（命中回同一 instance，不 parse）→ miss 才背景產生並入快取。DocumentRow.task 與測試共用此路徑。
  - placeholder：載入中顯示既有 lavenderCard+doc 圖示框（未載入完成前）。
  - `DocumentRow` 保留 `scanVM` 依賴不動（依指示）；`DocumentPreviewView` 依賴未動。
- 測試（ReviewFixTests）：
  - `testThumbnailCacheReturnsSameInstanceForSameURL`：同一 URL 兩次 `cachedThumbnail` 回傳同一 instance（`===`）、快取內容 `===` 首次結果、不同 URL 不誤撞。以可觀察行為（instance 身分）驗證「不重複 parse」。
  - `testThumbnailLoaderHandlesPDF`：mock PDF（writePDF 串流路徑產物）首頁可出縮圖，覆蓋 PDF 分支。
- 已知取捨：OCR 原地替換後縮圖仍為舊版（快取 key 是 URL path）——縮圖是 48×64 點陣，搜尋文字層差異視覺不可辨，不為此加失效邏輯（可用 `DocumentThumbnailCache.shared.removeAllObjects()` 於需要時清）。

---

## 驗證

指令（依指示）：

```
xcodebuild -project AirScanStudio.xcodeproj -scheme AirScanStudio \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/dd test \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:AirScanStudioTests/ReviewFixTests \
  -only-testing:AirScanStudioTests/OCRServiceTests \
  -only-testing:AirScanStudioTests/ESCLTests \
  -only-testing:AirScanStudioUITests/OcrUITests \
  -only-testing:AirScanStudioUITests/AirScanFlowUITests
```

- 結果：**全綠**。`** TEST SUCCEEDED **`（exit 0）
  - ReviewFixTests：17 tests（含本輪新增 3 項：testPDFFileStampReflectsFileReplacement /
    testThumbnailCacheReturnsSameInstanceForSameURL / testThumbnailLoaderHandlesPDF）
  - OCRServiceTests、ESCLTests、OcrUITests、AirScanFlowUITests 全數 passed
  - 合計 40 passed / 0 failed（跑兩次：第一次驗證修復，第二次於 #26 updateUIView 邊界強化後重跑，兩次皆 40/40，AppUI.swift 重編譯無警告）

## 未動（依指示保留）

- eSCL 協定（ESCLClient.swift 零改動）與 OCRService 邏輯
- 其餘複審清單項目（B4 mixed-size writePDF、B5 取消後文件入庫、B6 URLSession 洩漏、B8 OCR 頁數對齊、#13 settings 持久化、#23 iPad 雙 NavigationStack 等）留待下輪
- git commit
