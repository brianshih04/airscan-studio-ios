# OCR / Searchable PDF 測試報告（2026-09-16）

> 對應實作：`AirScanStudio/OCR/OCRService.swift`（Vision OCR + CoreGraphics 隱形文字層）
> 測試環境：Xcode 27.0 (27A266a) / iPhone 17 Pro 模擬器（iOS 26.5 runtime）+ 實機 HP / Brother MFP

## 驗證矩陣總覽

| 層級 | 測試 | 結果 |
|---|---|---|
| 演算法（macOS 端獨立程式，同演算法複本） | 中英辨識、bbox 正規化、`.txt` 產出、searchable PDF 中英文可搜尋、頁數/尺寸保留、空白頁 | **15/15 PASS** |
| 模擬器單元測試 | `OCRServiceTests`（8 測試） | **8/8 PASS** |
| 模擬器迴歸 | `ESCLTests`（既有 eSCL/ADF/flatbed） | **9/9 PASS** |
| 實機端到端（HP + Brother ADF） | `OCRHardwareTests`：掃描 → 背景 OCR → searchable PDF + `.txt` | **2/2 PASS** |

## 實機 OCR 數據（ADF 2 頁 / 300dpi / A4 / 真實紙張：Economics brief 頁面）

| 裝置 | host | OCR 字數 | PDF 文字層（p0） | 頁數保留 | 耗時 |
|---|---|---|---|---|---|
| Brother MFC-L2715DW | 10.1.121.175:80 | 7,414 | 6,816 字可搜尋 | ✅ 2 頁 | ~34 秒 |
| HP LaserJet Pro MFP 3104fdw | 10.1.121.182:8080 | 7,870 | 6,814 字可搜尋 | ✅ 2 頁 | ~33 秒 |

## 10 頁壓力測試（2026-09-17，修復後 pipeline，Brother ADF 單一 job `NumberOfPages=10`）

| 項目 | 結果 |
|---|---|
| 掃描+OCR 全流程 | ✅ 105.6 秒（10 頁連續進紙、同一 job、無中途退紙） |
| OCR 字數 | 13,382 字繁中（財務報表類文件，表格數字正確） |
| searchable PDF | ✅ 10 頁完整保留、3.0 MB、p0 866 字文字層 |
| 記憶體修復驗證 | ✅ `writePDF` 串流路徑峰值 = 單頁 ~35MB（舊實作同量級駐留 ~1.4GB 必被 jetsam 殺） |

此輪同時實機驗證 ADF 行為約束：**job 結束（含逾時/中止）時 ADF 整疊退紙**，故
`adfPageLimit` 必須等於實際放紙張數；測試斷言已改為單頁 .jpg / 多頁 .pdf 彈性處理
（`OCRHardwareTests`）。

- `SCANUSED` 斷言確認實際使用的掃描器端點（非 discovery 靜默接管）
- HP 辨識品質略低於 Brother（該機掃描器對焦特性），文字層與搜尋功能不受影響
- OCR 於掃描完成後背景執行（`Task.detached` priority .utility），UI 不阻塞

## 實測抓到並修復的 bug

1. **PDF mediaBox 落 Letter**：`CGContext(url:mediaBox:)` 的 `mediaBox` 必須在 context 建立時給定。
   傳 `nil` 時落到 Letter 612×792，per-page `kCGPDFContextMediaBox` **不會覆蓋** context-level 值
   → 原稿被裁切、隱形文字層座標全錯（搜尋命中內容為亂序碎片）。
   修法：建立 context 時傳入首頁 `page.bounds(for: .mediaBox)`。
2. **頁面渲染方向反轉**：以 lockFocus + translate/flip 矩陣手動渲染 `PDFPage` 會把部分頁面畫反
   → OCR 回傳亂碼（`269lcpgple FgAel`），症狀像模型/語言問題，實為影像上下顛倒。
   修法：改用 `PDFPage.thumbnail(of:for:)`（官方渲染路徑，方向保證正確）。

## 測試檔案

- `AirScanStudioTests/OCRServiceTests.swift` — 8 個單元測試（合成影像，不需掃描器）
- `AirScanStudioTests/OCRHardwareTests.swift` — 實機整合測試（需指定主機可達 + ADF 有紙）：
  - `testBrotherADFWithOCR` / `testHPADFWithOCR`
  - 驗收：PDF 存在、頁數 ≥1、OCR 於 240 秒內完成、`.txt` 產出、PDF 可開啟、頁數不變、有文字時文字層非空

## 已知限制 / 後續

- 實機驗證以英文紙張為主；中文 OCR 已由合成影像測試覆蓋（模擬器 + macOS 端），真實中文紙張實機未測
- Flatbed 單頁（.jpg）路徑的 OCR 僅產 `.txt`（無文字層），實機未單獨驗證
- 階段三（OCR 語言選擇 UI）未實作，目前固定 `zh-Hant` / `zh-Hans` / `en-US`
- Xcode 27 環境注意：更新後需 `sudo xcodebuild -license accept` 與 `sudo xcodebuild -runFirstLaunch`
  （CoreSimulator 元件更新），否則模擬器功能全部卡住；工具鏈直呼 swiftc 可繞過授權閘做 typecheck
