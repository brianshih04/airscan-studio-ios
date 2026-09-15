# AirScan Studio — HP / Brother 真機測試報告

測試日期：2026-09-15（Asia/Taipei）
測試環境：macOS 26.6 + Xcode 26.6，iOS Simulator（iPhone 17e / iPhone 17 / iPad Air 13"）、
Mac 與印表機同一區網（10.1.121.0/24）。App 版本 0.1.0 MVP（commit 866803a 之後）。
測試方法：macOS Swift probe（直接 URLSession）+ iOS Simulator App（真實模式，手動 IP 輸入）+ XCUITest 自動化。

## 1. 執行摘要

- **HP LaserJet Pro MFP 3104fdw**（`10.1.121.182:8080`）：eSCL ADF 與 Platen 掃描全流程通過。
  App 端到端（真實模式 → 掃描 → 文件庫）掃出真實紙張文件（會議紀錄，2550×4200 @ 300dpi，489KB JPEG）。
- **Brother MFC-L2715DW**（`10.1.121.175:80`）：eSCL Platen 掃描全流程通過。
  App 端到端掃出真實紙張文件（貸款結清申請書，2512×3290，323KB JPEG）。
- **AirPrint 列印**：系統 `UIPrintInteractionController` sheet 正常開啟、文件正確附加。
  模擬器的 AirPrint 印表機探索（mDNS）不可用（Apple 已知限制），**實體出紙需真機驗證**。
  列印路徑本身已由 Mac CUPS → HP 實測出紙成功（證明印表機列印服務正常）。

## 2. 關鍵協定發現（兩台裝置差異）

| 項目 | HP 3104fdw | Brother MFC-L2715DW |
|---|---|---|
| eSCL port | **8080**（來源：mDNS TXT；打 80 會得到誤導性 400） | **80**（標準） |
| Bonjour 廣告 | `_uscan._tcp` 有廣告 | **完全沒有廣告**（必須手動輸入 IP） |
| caps namespace | `schemas.hp.com/imaging/escl/2011/05/03` | 同 HP escl ns |
| ScanSettings namespace | **必須用 HP escl ns**（microsoft ns → HTTP 400 "Payload Error"） | 同左 |
| 必要 XML 元素 | `scan:Intent` + `scan:DocumentFormatExt` | **`scan:Intent` 缺失會使工作卡 Pending 直到逾時取消** |
| 拉頁行為 | job Completed 後 NextDocument 回 200 | **job 仍在 Pending 時 NextDocument 即回 200**（必須 POST 後立即拉取） |
| GET job URI | 回 XML（可輪詢 JobState） | **回 HTML 錯誤頁**（狀態只能由 ScannerStatus 比對 JobUri） |
| ADF | capabilities 有 `FeederInputCaps`，ADF 取紙正常 | capabilities **無 Feeder**（mDNS 卻宣稱 adf）；實測 Feeder POST → 500 |
| Platen 回傳尺寸 | 標準 A4 300dpi（2550×4200 或 2480×3508） | **原生感測範圍 2512×3290（非 A4 比例）**，與 Android 版報告一致 |
| 解析度支援 | 75–600 連續 | 100/200/300/600 離散 |

### HP 專有行為
- 掃描器 eSCL 服務在 Aborted jobs 累積時會 wedge：POST 201 但 job GET 立即 404，
  DELETE 也 404，僅能等 aging 或重開機恢復。測試期間觀察到一次，已由 App 的 cleanupJob
  與縮短 job 生命週期緩解。

### Brother 專有行為
- **PullScan 完全自動，不需要按面板 Start**（需 `scan:Intent` + `scan:DocumentFormatExt`
  + POST 後立即輪詢 NextDocument）。先前 Android 版報告的「互通問題」實為兩項協定差異
  加上掃描內容回傳非 A4 尺寸，並非需要面板確認。
- 掃描內容為感測器原生尺寸（2512×3290，比例 0.763 ≠ A4 0.707），App 依規格標記
  requested settings，不拉伸。

## 3. App 端到端驗證（iOS Simulator，真實模式）

| 流程 | HP | Brother |
|---|---|---|
| Capabilities 取得 | 200 ✅ | 200 ✅ |
| POST ScanJobs | 201 ✅ | 201 ✅ |
| 拉取影像 | 200 @ poll 0（489KB） | 200 @ poll 0（323KB） |
| 文件庫出現真實文件 | ✅ | ✅ |
| Mock 模式回歸 | ✅（5 頁 PDF） | — |

## 4. 測試自動化

- `ESCLTests`（5 unit）：XML 生成、A4 像素對齊、JobState 解析、Capabilities 解析、Mock 生成。
- `AirScanFlowUITests`：Home → 掃描設定 → 開始掃描 → 文件庫（Mock 全流程）。
- `PrintUITests`：Mock 文件 → 列印 sheet 開啟與文件附加（模擬器限制下可行的最深驗證）。
- `RealScanUITests`：**需要 10.1.121.175 真機在線**，預設 skip（`-skip-testing`），手動執行。

## 5. 整合測試（直接呼叫 ScanViewModel，繞過 UI 點擊）

`ScanViewModelIntegrationTests.testRealScanAgainstPinnedScanner`：
以 `manualScannerHost` UserDefaults 指定掃描器，直接呼叫 `startScanForTesting()`。

- Brother（10.1.121.175）：**通過（10 秒完成真實掃描，744KB JPEG，掃描內容為 Brother 測試校準頁）**
- 過程中發現並修復一個真 bug：`NWEndpoint` 的 IPv4 description 帶 interface scope
  （`10.1.121.182%en0`），造成 `URL(string:)` 回 nil → force-unwrap crash。
  修法：host 取值後 strip `%` 之後的 scope，並以 `badScannerURL` 錯誤取代 force-unwrap。

## 6. 已知限制與後續

1. 模擬器無法完成 AirPrint 印表機探索 → 實體出紙待真機驗證。
2. Brother Flatbed 非 A4 比例為 firmware 行為（延續 Android 報告結論），App 不拉伸、
   標示 requested settings；「裁切/補白成 A4」列為產品決策選項。
3. Brother 的 eSCL 未開放 ADF（caps 無 Feeder）；ADF 掃描僅 HP 可用。
4. Code review（glm-5.3）指出的 P1/P2（rootPath 應讀 TXT `rs=`、縮圖背景解碼、
   文件持久化改 Codable、掃描取消等）列於 GitHub issue 跟進。
