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

## 已知裝置測試狀態（承 Android 版實機報告）

| 裝置 | eSCL | 備註 |
|---|---|---|
| HP LaserJet Pro MFP 3104fdw | ✅ ADF/Flatbed | A4 300dpi 尺寸正確（2480×3508） |
| Brother MFC-L2715DW | ⚠️ | Flatbed 回傳非 A4 比例低像素；ADF 不取紙（firmware 互通問題） |

## 授權

TBD

## GitHub 倉庫

https://github.com/brianshih04/airscan-studio-ios

### 推送

本機尚未設定 GitHub 憑證（無 `gh` CLI、無 ssh key、鑰匙圈無 github.com 網路密碼）。
首次推送需要認證，兩種方式擇一：

```bash
# 方式 A：GitHub CLI（推薦，會引導瀏覽器登入）
brew install gh && gh auth login
git remote add origin https://github.com/brianshih04/airscan-studio-ios.git
git push -u origin main

# 方式 B：SSH key
ssh-keygen -t ed25519 -C "brian.shih04@gmail.com"
# 把 ~/.ssh/id_ed25519.pub 加到 GitHub → Settings → SSH keys
git remote add origin git@github.com:brianshih04/airscan-studio-ios.git
git push -u origin main
```

注意：需先在 GitHub 上建立空倉庫 `airscan-studio-ios`（不要勾選初始化 README）。
