# Android 版建議事項驗證結果（對照實際 codebase）

- 日期:2026-09-16
- 驗證對象:`docs/android-port-recommendations-2026-09-16.md`(依 iOS code review 推導的 8 項建議)
- 驗證方式:逐一對照 Android 版(mopria-android-scan-print)實際原始碼

## 結論

**8 項建議中 7 項在 Android codebase 已正確實作,不成立。** 該文件是從 iOS code review 推導的
「若 Android 照抄就會中雷」假設清單,但 Android 版實作時從一開始就寫對了。文件應作為
「Android 版已通過的檢核清單」歸檔,而非行動清單。

| # | 文件判斷 | 實際狀況 | 成立? |
|---|---------|---------|-------|
| 1 | 絕對路徑持久化 | 確實存 absolutePath | 部分成立 |
| 2 | PDF 一次解碼全部(P0) | 已是逐頁模式 | 不成立 |
| 3 | OCR 全尺寸解碼 | 已是兩段式取樣 | 不成立 |
| 4 | 非原子替換 | 已用原子替換 | 不成立 |
| 5 | 錯誤路徑不清 job | 已有 NonCancellable 清理 | 不成立 |
| 6 | 取消競態 | isBusy guard 防護 | 不成立 |
| 7 | Completed 不當終態 | 已當終態處理 | 不成立 |
| 8 | 主執行緒組裝 | 全在 Dispatchers.IO | 不成立 |

## 逐項證據

### #2 [P0] PDF 組裝 — 文件建議的寫法就是現有代碼

`PdfPageRenderer.writePdf` 是逐頁 callback 模型,`drawPage` 在每頁內解碼一張 → 畫完 →
`finally { bitmap.recycle() }`(ScanExportService.kt L405-409):

```kotlin
val bitmap = loadPageBitmap(page) ?: createMockPageBitmap(page)  // 每頁解一張
try {
    PdfPageRenderer.drawFittedInArea(canvas, bitmap, margin, top, bottom)
} finally {
    bitmap.recycle()   // finishPage 後立即回收
}
```

且 `loadPageBitmap` 限定 `requestedWidth=2048`(bounded decode),600dpi A4 不會解到 139MB。
IPP 列印路徑 `drawPrintPage`(RealIntegrationProvider L650-658)同樣模式。
**「一次解碼全部頁面」在這個 codebase 不存在。**

### #3 OCR 取樣 — 建議的兩段式 decode 已完整實作

`Ocr.kt` L114-138 `OcrBitmapLoader`:先 `inJustDecodeBounds` 拿邊界 →
`OcrImageSizing.sampleSize()` 算 `inSampleSize`(12M pixel / 4096 long-edge 上限)→
才真正解碼。沒有任何「先全解碼再 createScaledBitmap」或 `InputImage.fromFilePath` 的路徑。
連 OOM fallback 都有(L135-137)。

### #5 job 清理 — 連文件警告的協程陷阱都已處理

RealIntegrationProvider L448/458/464/470,三個 catch 路徑全部是文件建議的 exact pattern:

```kotlin
withContext(NonCancellable + Dispatchers.IO) { runCatching { httpClient.cancelScanJob(baseUrl, location) } }
```

`NonCancellable`(避免取消後清理被 CancellationException 打斷)+ `runCatching`
(404/409 冪等吞掉)都在。

### #7 Completed 終態 — 已當終態,且有實機驗證

- L249:timeout 時 `JobTransferState.Completed -> break@pageLoop`
- L265:HTTP 410 Gone + Completed → break
- L283-285:404 時只在 adfStillLoaded 才 retry,上限 3 次;ADF 空則立即 break

2026-08-13 在 Brother MFC-L2715DW 實測:最後一頁後 NextDocument 回 404 + ADF
ScannerAdfEmpty → 立即結束,**沒有 2 分鐘空轉**。

### #8 主執行緒 — 重活全在 IO dispatcher

- scan() → `viewModelScope.launch(Dispatchers.IO)`(L120)
- `ScanExportService.save()` 本身是 `withContext(Dispatchers.IO)`(L56-57),`saveScan` 的
  Main launch 只做狀態更新
- 符合文件建議的「Main 只做狀態、重活 withContext」規範

### #6 取消競態 — 用更簡單的方式防住了

scan() L380-385:`if (_uiState.value.isBusy) return` + launch 前先 claim slot
(`isDiscovering = true`),第二次 tap 進不來。`CancellationException` 在 L589/842 等處
分開 catch 且 rethrow。App 沒有 user-facing 的 cancelScan 按鈕,不存在「取消後立即重掃」的入口。

### #1 絕對路徑 — 唯一部分成立的項目

`DocumentStore.save()` L41-42 把 `imagePath`(absolutePath)寫進 JSON。但:

- `load()` L146-152 會**過濾掉檔案已不存在的文件** — 是優雅降級(靜默移除),不是 iOS 那種
  「清單全滅」
- Android `filesDir` 更新後路徑不變,主案不成立
- 剩餘風險情境:work profile(`/data/user/10/`)、雙開、未來改 MediaStore — 對目前這個
  開發中項目實際影響低

另外文件假設用 Room — 這個 app 用的是 `org.json` 檔案持久化,**沒有 Room**
(AGENTS.md 明載無 Hilt/Room/WorkManager)。

## 後續建議

1. **唯一值得做的 follow-up**:#1 相對路徑化 — 降為 P3/backlog,等確定要支援 work profile
   或改用 SAF 時再遷移(現有 `load()` 過濾已是安全網)
2. 本文件與原建議書一起歸檔:原文件作為「跨平台設計檢核清單」,本文件記錄 Android 版
   已逐項通過
3. 若回覆文件作者:8 項中 7 項 Android 版實作時就已符合建議,#1 部分成立但已有防護
