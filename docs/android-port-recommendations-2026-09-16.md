# 給 Android 版開發者的建議事項(AirScan Studio / mopria-android-scan-print)

- 日期:2026-09-16
- 依據:iOS 版全專案 code review(`docs/code-review-2026-09-16.md`,29 項)
- 範圍:僅收錄在兩版共用架構(文件庫持久化、eSCL 掃描流程、多頁 PDF 組裝、ML Kit OCR)下同樣適用的 8 項;iOS 專屬項(SwiftUI/UIKit、NavigationStack、UIGraphicsImageRenderer、@MainActor 語意等)已略過。
- 每條標註對應 iOS review 編號,便於跨版對照;嚴重度依 Android 平台特性重新評估,與 iOS 不完全相同。

| # | 主題 | 嚴重度 | 對應 iOS |
|---|------|--------|----------|
| 1 | 文件庫以絕對路徑持久化 | P1 | #1 |
| 2 | 多頁 PDF 組裝一次解碼全部頁面 | P0 | #2 |
| 3 | OCR 前的大圖取樣 | P1 | #6 |
| 4 | searchable PDF 原地替換非原子 | P1 | #7 |
| 5 | 錯誤路徑不清 eSCL job | P1 | #8 |
| 6 | 取消後立即重掃的競態 | P1 | #3 |
| 7 | pullPage 不把 Completed 當終態 | P1 | #4 |
| 8 | PDF 組裝與寫檔跑在主執行緒 | P1 | #9 |

---

## 1. [P1] 文件庫以絕對路徑持久化(對應 iOS #1)

**問題**:iOS 版把輸出檔的絕對路徑整串寫進持久化清單,container 路徑一換,`fileExists` 全數失敗、清單全滅。Android 版若同樣把 `File.absolutePath` 存進 Room,就是同一顆雷換個引信。

**Android 影響評估**:Android 的 `filesDir` 在一般 app 更新時路徑不變(不像 iOS container 每次更新都換),所以「一更新就全滅」的主案情在 Android 不成立——這是與 iOS 最大的差異,故降為 P1。但以下情境仍會讓絕對路徑失效,症狀相同(檔案還在磁碟、清單看不到):備份移轉到工作資料夾(work profile,路徑在 `/data/user/10/...`)、第三方「應用分身/雙開」、未來改用 SAF/MediaStore(content:// URI)或 app 移轉至採用儲存空間。絕對路徑也讓 FileProvider 授權範圍與 backup 規則難以維護。若產品明確支援企業 work profile 或雙開機型,此項直接升 P0。

**建議修法**:Room entity 只存檔名(必要的話加相對子目錄),載入時以 context 拼接:

```kotlin
@Entity(tableName = "documents")
data class DocumentEntity(
    @PrimaryKey val id: String,
    val fileName: String,          // 只存 "scan-20260916-001.pdf"
    ...                            // 其餘 metadata
)

fun DocumentEntity.file(context: Context): File =
    File(File(context.filesDir, "documents"), fileName)
```

既有資料 migration 不要在 SQL 裡切字串,一次性 Kotlin 遷移讀出所有 row、`fileName.substringAfterLast('/')` 回寫。新欄位建議命名 `relativePath`,語意自明。

---

## 2. [P0] 多頁 PDF 組裝一次解碼全部頁面(對應 iOS #2)

**問題**:iOS 版把每頁解碼圖同時駐留記憶體再逐頁 `PDFPage(image:)`。ADF 上限 50 頁 × 600dpi A4(~4960×7016px,4 bytes/px ≈ 139MB/頁解碼)可達數 GB,必然被系統殺。

**Android 影響評估**:完全相同,而且 Android 更脆弱:bitmap 像素計在 native 記憶體、由 lmkd 依整體 RSS 決定殺誰,`largeHeap` 救不了 native 層;低階機(2–3GB RAM)疊上 launcher 返回,幾頁就出局。崩潰表現為背景被殺或 `OutOfMemoryError`,組到一半的 PDF 直接丟失。

**建議修法**:`android.graphics.pdf.PdfDocument` 本身就是逐頁 flush 的模型——`finishPage()` 之後該頁已序列化進文件緩衝,bitmap 可立即 recycle。正確形狀是「任何時刻只住一張 bitmap」:

```kotlin
val pdf = PdfDocument()
try {
    pageFiles.forEachIndexed { i, f ->
        val bmp = BitmapFactory.decodeFile(f.absolutePath)   // 一次解一頁
        val page = pdf.startPage(PageInfo.Builder(bmp.width, bmp.height, i + 1).create())
        page.canvas.drawBitmap(bmp, 0f, 0f, null)
        pdf.finishPage(page)
        bmp.recycle()
    }
    FileOutputStream(tmpFile).use { out ->
        pdf.writeTo(out)
        out.fd.sync()
    }
} finally {
    pdf.close()
}
```

兩個關鍵:(a) 掃描階段先用 eSCL NextDocument 把每頁收成「一頁一個 JPEG 檔」,組裝階段逐檔解碼——掃描與組裝之間不要以 `List<Bitmap>` 傳遞;(b) 輸出先寫暫存檔再原子替換(見 #4)。驗收:50 頁 600dpi ADF 實測,組裝期峰值記憶體應只與單頁同數量級(~150–300MB)。

---

## 3. [P1] OCR 前的大圖取樣(對應 iOS #6)

**問題**:iOS 版 downsample 的 renderer 帶到螢幕 scale,「長邊 4096」實際渲染 ~12288px(~400MB)。Android 版對應的坑:先 `decodeFile` 全尺寸、再 `createScaledBitmap` 縮圖——全尺寸那一步已把 139MB bitmap 搬進記憶體,取樣形同虛設;`InputImage.fromFilePath()` 內部也是全尺寸解碼,同一個問題。

**Android 影響評估**:ML Kit 推論本身能在背景跑,但輸入 bitmap 得先建出來;600dpi 頁面全解碼即 139MB,若與 PDF 組裝並行(流程上很可能)就是雙倍峰值。OCR 若用 WorkManager 排程,背景被殺後重試還會重複計工。

**建議修法**:在「解碼時」取樣,而不是解碼後縮圖——兩段式 decode:

```kotlin
val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
BitmapFactory.decodeFile(path, bounds)
val longEdge = maxOf(bounds.outWidth, bounds.outHeight)
var sample = 1
while (longEdge / sample > 4096) sample *= 2          // inSampleSize 只吃 2 的冪
val opts = BitmapFactory.Options().apply { inSampleSize = sample }
val bmp = BitmapFactory.decodeFile(path, opts)
val rotation = ExifInterface(path).getAttributeInt(
    ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL).let { ... }
val input = InputImage.fromBitmap(bmp, rotationDegrees)
```

取樣目標:拉丁文件長邊 ~2048 即可,CJK 小字建議留 ~3000(ML Kit 要求文字至少 16px 高;600dpi 的 12pt 字原生 100px,取樣 4–8 倍仍有餘裕)。EXIF 方向務必讀出並轉給 `fromBitmap` 的 rotationDegrees(掃描器輸出通常已正立,但別假設)。整段跑 `Dispatchers.Default`,ML Kit 的 `Task` 用 `kotlinx-coroutines-play-services` 的 `await()` 收。

---

## 4. [P1] searchable PDF 原地替換非原子(對應 iOS #7)

**問題**:iOS 版先 `removeItem` 原檔再 `moveItem` 新檔,中途失敗原稿已刪。Android 版若用「先 delete 再 rename」、或直接以 `FileOutputStream` 覆寫原檔,crash/磁碟滿時同一後果:原始掃描檔永久遺失,新檔殘留。

**Android 影響評估**:掃描原稿是不可再生資料,替換失敗=資料遺失,無法補救。Android 上程序隨時可能被 lmkd 殺(尤其 OCR + PDF 組裝同時跑的記憶體高峰),中斷機率不低於 iOS。

**建議修法**:同目錄寫 `.tmp` → fsync → `ATOMIC_MOVE`:

```kotlin
val tmp = File(target.parentFile, target.name + ".tmp")
// ... 寫完 tmp、stream 關閉前 fd.sync() ...
Files.move(tmp.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE)
```

注意兩點:(a) tmp 一定要放在 target 同目錄——跨掛載點 rename 會失敗,且不要丟 cacheDir(會被系統清理);(b) `ATOMIC_MOVE` 丟 `AtomicMoveNotSupportedException` 時 fallback `renameTo()`(同目錄必同 filesystem,實務上幾乎不會走到)。

---

## 5. [P1] 錯誤路徑不清 eSCL job(對應 iOS #8)

**問題**:iOS 版 `DELETE /eSCL/ScannerJobs` 只在 happy path 執行;pullPage/createJob 拋例外時 job 殘留。Android 版若照抄流程,同樣中雷。

**Android 影響評估**:這是設備端行為,與平台無關——HP 實測會因 Aborted job 堆積而 wedge(殘留 job 要靠時間 aging 才清掉),使用者感受到的就是「掃描器壞了」。WiFi 切換、app 退背景導致掃描流程被取消,是殘留的高發路徑。

**建議修法**:Kotlin 的 try/finally 對應 iOS 的 defer,但多一個協程陷阱——finally 裡的 suspend 網路呼叫在協程已被取消時會立刻丟 `CancellationException`,清理反而做不完。要包 `NonCancellable`:

```kotlin
var jobUrl: String? = null
try {
    jobUrl = escl.createJob(settings)
    pullPages(jobUrl)
} finally {
    jobUrl?.let { url ->
        withContext(NonCancellable) {
            runCatching { escl.deleteJob(url) }   // 已完成 job 會回 404/409,吞掉即可(冪等)
        }
    }
}
```

---

## 6. [P1] 取消後立即重掃的競態(對應 iOS #3)

**問題**:iOS 版 `cancelScan` 清掉 task 引用,但舊 Task 要到下一個 await 才收到取消;期間新掃描已啟動,舊 Task 收尾寫 `phase = .idle` 蓋掉新掃描狀態,最壞兩個掃描並行、文件重複入庫。Android 版的對應坑:`scanJob?.cancel()` 只是送出取消訊號,協程是合作式取消,舊協程要跑到下一個掛起點才會丟 `CancellationException`——語意一模一樣。

**Android 影響評估**:發生率與 iOS 相同;Android 另有加乘風險——慣用的 `catch (e: Exception)` 會連 `CancellationException` 一起吃掉,取消傳播直接壞掉,錯誤路徑還會誤報成掃描失敗。

**建議修法**:二選一,可並用:

(a) 啟動前等舊任務真正結束:

```kotlin
fun startScan() {
    viewModelScope.launch {
        scanJob?.cancelAndJoin()          // 等舊任務收完尾
        scanJob = launch { doScan() }
    }
}
```

(b) generation token:每次掃描遞增編號,每個掛起點之後、寫任何狀態之前檢查 `if (gen != scanGeneration) return@launch`。

搭配一條鐵律:`catch (e: CancellationException) { throw e }` 永遠擺在最前面,之後才允許 catch 一般 Exception。

---

## 7. [P1] pullPage 不把 Completed 當終態(對應 iOS #4)

**問題**:HP ADF 掃完最後一頁後 job 進 `Completed`,但 NextDocument 回非 200;輪詢迴圈只認 Aborted/Canceled,於是空轉滿 120 次(~2 分鐘)才放棄——每次 HP ADF 掃描結尾都卡。

**Android 影響評估**:這是 eSCL 通訊層 bug,兩版共用同一份協定邏輯,照移植就照炸。Android 版若把輪詢掛在 foreground service/WorkManager,逾時與重試政策還會疊上去,放大等待與耗電。

**建議修法**:pullPage 迴圈把 job 狀態與 NextDocument 回碼「與」起來判斷終止:

```kotlin
val phase = getJobPhase(jobUrl)          // eSCL JobStatus 查詢
if (phase == COMPLETED && response.code != 200) return null   // 終態:不可能再有新頁
if (phase == ABORTED || phase == CANCELED) throw ...
```

原則:`Completed` 之後不可能再產生新頁,NextDocument 非 200 即結束,不要再重試。單頁下載的暫時性錯誤也別無限重試,設上限後走清理路徑(#5)。

---

## 8. [P1] PDF 組裝與寫檔跑在主執行緒(對應 iOS #9)

**問題**:iOS 版整個 ViewModel 是 @MainActor,組裝全程凍結 UI。Android 版對應坑:`viewModelScope.launch` 預設 Main dispatcher,組裝直接寫在 launch 裡就是全段跑 main thread。

**Android 影響評估**:比 iOS 更硬——main thread 卡超過 5 秒且使用者碰螢幕就是 ANR:系統對話框直接問使用者要不要關 app,並計入 Play Console vitals 的 crash 類。50 頁 600dpi 的解碼+編碼遠超 5 秒。即使沒觸發 ANR,UI 也是整段凍結、無法顯示進度。

**建議修法**:訂一條 dispatcher 規範並機械化檢查:

- `viewModelScope`(Main)只做狀態更新與導航;任何超過一幀(>16ms)的工作必須 `withContext` 指定 dispatcher。
- bitmap 解碼 / PDF 編碼 → `Dispatchers.Default`;檔案 IO → `Dispatchers.IO`。`StateFlow.value` 更新本身 thread-safe,不必特地跳回 Main。

```kotlin
viewModelScope.launch {
    val result = withContext(Dispatchers.Default) { assemblePdf(pageFiles) }
    _phase.value = ScanPhase.Idle
    _documents.value = reloadDocuments(result)
}
```

- 在 debug build 開 `StrictMode().setThreadPolicy(ThreadPolicy.Builder().detectAll().penaltyDeath().build())`,主執行緒磁碟/網路違規直接崩,UI 測試一跑就抓到;release 用 `penaltyLog`。

---

## 建議修復順序

1. **#2 PDF 逐頁寫 + #8 dispatcher 規範** —— 唯一 P0,且兩者改的是同一段程式,一次 PR 收掉;以 50 頁 600dpi ADF 實測峰值記憶體與 ANR。
2. **#1 Room 改相對路徑** —— 資料層整型,趁文件數量還少時遷移成本最低。
3. **#7 pullPage 補 Completed 終態** —— HP 用戶每次掃描都遇到,體感最直接、改動最小。
4. **#6 取消競態 + #5 job 清理** —— 兩者都在掃描生命週期上,一次改完並補「取消後立即重掃」「掃描中退背景」兩條測試路徑。
5. **#3 OCR 取樣 + #4 原子替換** —— OCR 資源安全一次收拾;驗收用 600dpi CJK 文件 OCR 正確率不退化。
