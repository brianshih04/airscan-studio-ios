# iOS OCR / Searchable PDF 規劃（Backlog）

> 對應 Android 版：ML Kit Text Recognition v2 + Searchable PDF（docs/ocr-escl-image-pipeline.md）
> 狀態：**階段一、二已實作並驗證**（2026-09-16：macOS 端 15/15、模擬器 OCR 8/8 + ESCL 9/9、
> 實機 HP/Brother ADF 整合測試通過，真實紙張 OCR 7.4k–7.9k 字、searchable PDF 可搜尋）

## 方案：Vision framework（原生、免模型下載）

Android 用 ML Kit（需 Google Play services 下載模型、語言目錄管理、JP/KR 字型下載）。
iOS 用內建 Vision framework：離線、OS 內建多語模型、無下載流程。

## 階段一：OCR 開關 + 文字辨識 ✅

- 掃描設定頁「文字辨識 (OCR)」toggle（預設關，比照 Android）→ `ScanViewModel.ocrEnabled`（獨立 UserDefaults key `ocrEnabled`）
- 掃描完成後背景執行 VNRecognizeTextRequest（Mock 與 Real 兩條路徑都掛）：
  - recognitionLevel = .accurate
  - recognitionLanguages = `OCRService.defaultLanguages`（["zh-Hant", "zh-Hans", "en-US"]）
  - 輸入：JPEG/PDF 頁面（長邊取樣 4096px，比照 Android 限制）
- 文件詳情頁「原稿/文字」分頁：辨識結果預覽 + 複製按鈕 + 手動「辨識此文件」
- OCR 失敗/無文字：明確顯示「未偵測到文字」，掃描頁保留（比照 Android Skipped 行為）
- 實作位置：`AirScanStudio/OCR/OCRService.swift`、`ScanViewModel` OCR 區塊、`AppUI.swift` DocumentPreviewView

## 階段二：Searchable PDF ✅

- PDFKit 頁面底下加隱形文字層（CoreGraphics，rendering mode .invisible）：
  - VNRecognizedTextObservation.boundingBox（正規化、左下原點）× 頁面 mediaBox → 文字層座標
  - `drawPDFPage` 保留原稿影像，逐 run 疊不可見文字
- 字型：PingFang TC（系統內建），免 Android 版 Noto 下載管理
- **已驗證的坑（macOS 端實測抓到）**：
  - `CGContext(url:mediaBox:)` 的 mediaBox 必須在 context 建立時給定；傳 nil 會落到 Letter 612×792，
    per-page 的 kCGPDFContextMediaBox 不會覆蓋它 → 原稿被裁切、文字層座標全錯
  - PDF 頁面渲染給 OCR 用 `PDFPage.thumbnail(of:for:)`；手動 lockFocus+翻轉矩陣會把頁面畫反 → OCR 全亂碼
- 驗收：PDF 內可搜尋/複製中文與英文（macOS 端獨立驗證程式 15/15 PASS）

## 階段三（選配）：語言選擇 UI ⏳ 未實作

- 設定頁 OCR 區塊加語言多選（繁中/簡中/英/日/韓）
- 對應 VNRecognizeTextRequest.recognitionLanguages

## 已知差異 vs Android

| 項目 | Android (ML Kit) | iOS (Vision) |
|---|---|---|
| 模型 | Play services 下載 | OS 內建 |
| 語言 | 10 語 catalog | VNRecognizeTextRequest 支援語系 |
| JP/KR 字型下載 | 需要（Noto 20MB + SHA256） | 不需要（系統字型） |
| 未就緒行為 | 回 Skipped | 直接可用 |

## 測試

- `AirScanStudioTests/OCRServiceTests.swift`：8 個 iOS 單元測試（中英辨識、bbox 正規化、.txt 產出、
  searchable PDF 頁數/尺寸保留、可搜尋文字層、空白頁、toggle 持久化、OCRTextStore）
- macOS 端獨立驗證程式（/tmp/ocr_verify，同演算法複本）：15/15 PASS，含上述兩個 PDF 層 bug 的迴歸
