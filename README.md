# AirScan Studio

iOS App：透過 **eSCL（AirScan）** 掃描網路文件，並以 **AirPrint** 列印。iOS 17+ Universal（iPhone / iPad）。

是 [mopria-android-scan-print](https://github.com/brianshih04/mopria-android-scan-print) 的 iOS 移植版，UI/UX 與協定實作行為與 Android 版對齊。

## 功能（MVP 0.1.0）

- **模擬模式**：不需實體掃描器，生成 A4 mock 掃描 PDF（開發 / UI 驗證 / Demo 用）
- **真實模式**：eSCL pull scan — Bonjour 探索（`_uscan._tcp` / `_uscans._tcp`）→ ScannerCapabilities → ScanJobs → 下載文件
- **OCR 文字辨識 + Searchable PDF**：Vision framework（準確模式，繁中/簡中/英文，免模型下載）；
  掃描完成背景辨識，PDF 疊加不可見文字層（可搜尋/複製）+ 同名 `.txt`；文件詳情頁「文字」分頁（預覽/複製/重跑）
- **AirPrint 列印**：掃描結果或檔案直出系統列印
- **文件庫**：PDF 縮圖、預覽（PDFKit）、刪除、持久化
- 掃描設定：Flatbed / ADF、150 / 300 / 600 dpi、彩色 / 灰階 / 黑白、Flatbed 逐頁合併（上限 50 頁）
- requested vs actual settings 明確標記（與 Android 版行為一致）

## 技術

- SwiftUI + Swift 5.9，XcodeGen 管理專案
- eSCL client：URLSession 自實作（無第三方依賴）
- 探索：Network.framework `NWBrowser`
- OCR：Vision `VNRecognizeTextRequest`（accurate、`zh-Hant`/`zh-Hans`/`en-US`、長邊 4096px 取樣）
- Searchable PDF：CoreGraphics `drawPDFPage` 保留原稿 + rendering mode `.invisible` 文字層（CoreText/PingFang TC，座標由 Vision 正規化 bbox 換算）

## 開發

```bash
# 生成 Xcode 專案（需 XcodeGen）
xcodegen generate

# 編譯（不啟動模擬器）
xcodebuild -project AirScanStudio.xcodeproj -target AirScanStudio \
  -sdk iphonesimulator27.0 build CODE_SIGNING_ALLOWED=NO SYMROOT=build/sym

# 測試（單元 + UI，需已啟動的模擬器）
xcodebuild -scheme AirScanStudio \
  -destination 'platform=iOS Simulator,name=iPhone 17e' \
  -derivedDataPath build/dd test CODE_SIGNING_ALLOWED=NO
```

## 已知裝置測試狀態（iOS 版真機驗證 2026-09-15，OCR 驗證 2026-09-16）

| 裝置 | eSCL 掃描 | OCR + Searchable PDF | 備註 |
|---|---|---|---|
| HP LaserJet Pro MFP 3104fdw | ✅ ADF + Flatbed（App 端到端） | ✅ ADF 2 頁實測 | eSCL 在 `:8080`；ScanSettings 需 HP escl namespace；標準 A4 輸出 |
| Brother MFC-L2715DW | ✅ Flatbed + ADF（App 端到端） | ✅ ADF 2 頁實測 | eSCL 在 `:80`；**無 Bonjour 廣告，需手動輸入 IP**；無 `scan:Intent` 會卡 Pending |

### OCR 實測數據（2026-09-16，ADF 2 頁 / 300dpi / A4，真實紙張 Economics brief）

| 裝置 | OCR 字數 | PDF 文字層（第 1 頁） | 耗時（掃描+OCR） |
|---|---|---|---|
| Brother | 7,414 | 6,816 字可搜尋 | ~34 秒 |
| HP | 7,870 | 6,814 字可搜尋 | ~33 秒 |

驗證矩陣：macOS 端演算法驗證 15/15、模擬器單元測試 OCR 9/9 + eSCL 9/9、UI 測試（Mock OCR 全流程 / Mock 掃描流程 / AirPrint sheet）全綠、
實機 ADF 端到端（掃描 → 背景 OCR → searchable PDF + `.txt`）。
實測抓到並修復：PDF context `mediaBox` 需建立時給定（nil 落 Letter 612×792 會裁切原稿）；PDF 頁渲染需用 `PDFPage.thumbnail`（手動翻轉矩陣會畫反 → OCR 亂碼）；
iOS 26 segmented Picker 對 Accessibility 不可見（詳情頁分頁改自製按鈕）；文件列表 row 導航補 `NavigationStack`（`navigationDestination` 才會推入）。

詳見[測試報告](docs/hp-brother-ios-test-report-2026-09-15.md)、[OCR 測試報告](docs/ocr-test-report-2026-09-16.md)與 [OCR backlog](docs/ocr-backlog.md)。

## 授權

TBD

## GitHub 倉庫

https://github.com/brianshih04/airscan-studio-ios

## 文件

- [HP / Brother 真機測試報告（2026-09-15）](docs/hp-brother-ios-test-report-2026-09-15.md) —
  兩台 MFP 的 eSCL 協定差異、App 端到端驗證結果、已知限制
- [OCR / Searchable PDF 規劃與測試狀態](docs/ocr-backlog.md) —
  Vision OCR + 隱形文字層實作說明、驗證矩陣、已知坑（mediaBox / 頁面渲染方向）
- 上游專案：[mopria-android-scan-print](https://github.com/brianshih04/mopria-android-scan-print)（Android 版，含 ADF 解析度調查與 OCR pipeline 文件）
