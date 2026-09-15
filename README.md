# AirScan Studio

iOS App：透過 **eSCL（AirScan）** 掃描網路文件，並以 **AirPrint** 列印。iOS 17+ Universal（iPhone / iPad）。

是 [mopria-android-scan-print](https://github.com/brianshih04/mopria-android-scan-print) 的 iOS 移植版，UI/UX 與協定實作行為與 Android 版對齊。

## 功能（MVP 0.1.0）

- **模擬模式**：不需實體掃描器，生成 A4 mock 掃描 PDF（開發 / UI 驗證 / Demo 用）
- **真實模式**：eSCL pull scan — Bonjour 探索（`_uscan._tcp` / `_uscans._tcp`）→ ScannerCapabilities → ScanJobs → 下載文件
- **AirPrint 列印**：掃描結果或檔案直出系統列印
- **文件庫**：PDF 縮圖、預覽（PDFKit）、刪除、持久化
- 掃描設定：Flatbed / ADF、150 / 300 / 600 dpi、彩色 / 灰階 / 黑白
- requested vs actual settings 明確標記（與 Android 版行為一致）

## 技術

- SwiftUI + Swift 5.9，XcodeGen 管理專案
- eSCL client：URLSession 自實作（無第三方依賴）
- 探索：Network.framework `NWBrowser`

## 開發

```bash
# 生成 Xcode 專案（需 XcodeGen）
xcodegen generate

# 編譯（不啟動模擬器）
xcodebuild -project AirScanStudio.xcodeproj -target AirScanStudio \
  -sdk iphonesimulator26.5 build CODE_SIGNING_ALLOWED=NO SYMROOT=build/sym

# 測試（單元 + UI，需已啟動的模擬器）
xcodebuild -scheme AirScanStudio \
  -destination 'platform=iOS Simulator,name=iPhone 17e' \
  -derivedDataPath build/dd test CODE_SIGNING_ALLOWED=NO
```

## 已知裝置測試狀態（iOS 版真機驗證 2026-09-15）

| 裝置 | eSCL 掃描 | 備註 |
|---|---|---|
| HP LaserJet Pro MFP 3104fdw | ✅ ADF + Flatbed（App 端到端） | eSCL 在 `:8080`；ScanSettings 需 HP escl namespace；標準 A4 輸出 |
| Brother MFC-L2715DW | ✅ Flatbed（App 端到端） | eSCL 在 `:80`；**無 Bonjour 廣告，需手動輸入 IP**；無 `scan:Intent` 會卡 Pending；回傳原生 2512×3290 |

詳見[測試報告](docs/hp-brother-ios-test-report-2026-09-15.md)。

## 授權

TBD

## GitHub 倉庫

https://github.com/brianshih04/airscan-studio-ios

## 文件

- [HP / Brother 真機測試報告（2026-09-15）](docs/hp-brother-ios-test-report-2026-09-15.md) —
  兩台 MFP 的 eSCL 協定差異、App 端到端驗證結果、已知限制
- 上游專案：[mopria-android-scan-print](https://github.com/brianshih04/mopria-android-scan-print)（Android 版，含 ADF 解析度調查與 OCR pipeline 文件）
