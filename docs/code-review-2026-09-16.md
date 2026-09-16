# AirScan Studio 靜態程式碼審查報告

- 日期:2026-09-16
- 範圍:app target 全部 Swift 原始碼(AirScanStudio/ 下 6 檔,共 2,143 行);tests 831 行快掃;project.yml 核對
- 排除(已知不重報):Xcode 27/iOS 26 環境問題、segmented Picker AX 問題、DocumentsView NavigationStack 補丁、模擬器 24/24 綠、實機 HP/Brother ADF OCR 已驗證

統計:P0 = 2,P1 = 7,P2 = 20,總計 29 項

---

## P0(會 crash 或資料錯誤)

1. [P0] ScanViewModel.swift:414 — 文件庫以絕對路徑持久化,app 更新後清單全滅 — iOS container 路徑每次更新都變,`loadDocuments` 的 `fileExists` 全數失敗,所有歷史文件從列表消失(檔案還在磁碟但 App 看不見);應只存檔名並在載入時拼接目前 Documents 目錄。
2. [P0] ScanViewModel.swift:301-307 — 多頁 PDF 組裝把全部頁面解碼圖同時駐留記憶體 — ADF 上限 50 頁 × 600dpi A4(~139MB/頁解碼)可達數 GB,PDFPage(image:) 持住 UIImage 直到 `pdf.write` 完成,必然被 jetsam 殺進程;應逐頁以 CGPDFContext 串流寫出或每頁 autorelease。

## P1(功能缺陷)

3. [P1] ScanViewModel.swift:135-161 — 取消後立即重掃的競態 — `cancelScan` 把 scanTask 清 nil,但舊 Task 要等下一個 await 才收到取消;期間新掃描已啟動,舊 Task 收尾時寫 `phase = .idle` 會蓋掉新掃描的狀態,最壞情況兩個掃描並行、文件重複入庫;需要 generation token 或等舊 Task 結束才允許重啟。
4. [P1] ESCLClient.swift:130-141 — pullPage 不把 `.completed` 當終態 — HP ADF 進紙掃完最後一頁後 job=Completed 但 NextDocument 回非 200,迴圈只認 aborted/canceled,會空轉滿 120 次(~2 分鐘)才回 nil,每次 ADF 掃描結尾卡住;應在 `phase == .completed && code != 200` 時返回 nil。
5. [P1] ScanViewModel.swift:79-86 — 手動加入的掃描器永久霸佔 selectedScanner — 只要 discovered 裡有 `manual-` 開頭項,Bonjour 探索到的裝置永遠選不到(裝置頁點了也無反應、勾選不移動);應以使用者明確選擇優先。
6. [P1] OCRService.swift:164 — UIGraphicsImageRenderer 用預設 3x scale,downsample 形同失效 — `UIGraphicsImageRenderer(size:)` 預設帶螢幕 scale,「長邊 4096」實際渲染成 ~12288px(~400MB bitmap),600dpi OCR 記憶體爆炸且背景任務更容易被殺;要設 `format.scale = 1`。
7. [P1] OCRService.swift:87-90 — searchable PDF 原地替換非原子 — 先 `removeItem` 原檔再 `moveItem`,若中途失敗(磁碟滿等)原始掃描檔已刪、新檔留在 tmp,使用者永久遺失原稿;應改 `replaceItemAt` 或先備份再回滾。
8. [P1] ScanViewModel.swift:247-264 — 錯誤路徑不清 eSCL job — `cleanupJob` 只在 happy path 執行;pullPage/createJob 拋例外時掃描器端 job 殘留(HP 已知會因 Aborted job 堆積 wedge),只有使用者主動取消才有補救;應用 defer 確保清理。
9. [P1] ScanViewModel.swift:292-307 — PDF 組裝與寫檔在 MainActor 執行 — 整個 ViewModel 是 @MainActor,多頁 JPEG 解碼 + PDF 編碼 + 寫檔凍結 UI 數秒到數十秒(頁數/解析度越大越久);應移到背景 actor。

## P2(品質建議)

10. [P2] AppUI.swift:571-607 — DocumentRow 掛 @ObservedObject scanVM 但 body 沒用到 — 每次任何 VM 變更(掃描 phase、OCR set 異動)都重繪整個列表,且縮圖在主執行緒同步 `PDFDocument(url:)`/`Data(contentsOf:)` 全檔載入;拿掉 scanVM 參數 + 快取縮圖。
11. [P2] ScanViewModel.swift:295-297 — pullPage 接受 application/pdf MIME 但單頁一律存 .jpg — 若裝置回 PDF,內容會被存成副檔名 .jpg 的壞檔(ESCLClient.swift:126 一併看)。
12. [P2] ScanViewModel.swift:302-306 — 頁面解碼失敗靜默跳頁 — `UIImage(data:)` 失敗的頁被丟棄但 `pageCount` 仍記 pages.count,文件 metadata 與實際 PDF 頁數不一致。
13. [P2] ScanViewModel.swift:427 — loadDocuments 用「當下」settings 回填歷史文件 — 重啟後所有舊文件顯示的是最後一次使用的設定而非掃描當時設定;應一併持久化 settings。
14. [P2] ScanViewModel.swift:431-435 — deleteDocument 不刪 .txt sidecar — OCR 文字檔孤兒留在磁碟;OCR 執行中刪除文件還會把檔案寫回來(孤兒復活)。
15. [P2] ScanViewModel.swift:381-389 — startScanForTesting / SCANUSED print / ProcessInfo 參數解析留在 app target — 測試後門與診斷輸出不應在 production 路徑(ScanViewModel.swift:216-228 同)。
16. [P2] ESCLClient.swift:46,72,83,105,127,136,152 + ScanViewModel.swift:223,230 — NSLog 輸出內網 IP、port、完整 URL — 區域網路拓撲資訊進系統日誌(隱私面);除錯日誌應降級或抽換。
17. [P2] ESCLClient.swift:241 — tag 拼錯:pwg:MakerAndModel 應為 pwg:MakeAndModel — eSCL/PWG 規範元素名無 "r",以致 maker/model 永遠空字串(僅顯示用途)。
18. [P2] ESCLClient.swift:93-110, 149-157 — waitForJob / downloadPage 是死碼 — app 流程只用 pullPage;留著的 waitForJob 對暫時性網路錯誤也零容忍,日後誤用會放大成掃描中斷。
19. [P2] ESCLClient.swift:69-78 — 503 重試累計睡眠可達 120 秒且 `data` 變數從未讀取 — 8+16+24+32+40s 的遞增 backoff 疊上 300s resource timeout,極端時以 URLError 而非 jobRejected 收場;backoff 應設上限。
20. [P2] ScannerBrowser.swift:44-75 — NWConnection handler 強參照 conn 形成環 — stateUpdateHandler capture conn 再 conn.cancel(),連線物件與 handler 互相持住直到 cancel 完成才釋放;週期內少量洩漏。
21. [P2] ScannerBrowser.swift:58-61 — IPv6 host 剝掉 %zone 後未加方括號 — 產生 `http://fe80::1:80/eSCL` 這種 URL 會建構失敗,等於 IPv6 掃描器無法連線。
22. [P2] AppUI.swift:846-856 — 手動輸入驗證不足 — port 無 0-65535 範圍檢查、無法移除已加入的手動裝置、decimalPad 也輸不了 IPv6。
23. [P2] AppUI.swift:66-69 + 118 + 535 — iPad 下 NavigationStack 雙層巢狀 — RootTabView 的 sidebar detail 已包 NavigationStack,HomeView/DocumentsView 內部又各自再包一層,產生雙導覽列與標題異常。
24. [P2] AppUI.swift:781-789 — iPad 上 UIPrintInteractionController.present(animated:) 無錨點 — iPad 規範要用 presentFromRect/presentFromBarButtonItem,直接 present 可能無法呈現或行為未定義。
25. [P2] AppUI.swift:791-797 — 「從檔案選擇…」實際直接列印最新文件 — 按鈕文案與行為不符(stub),誤導使用者。
26. [P2] AppUI.swift:735-744 — PDFKitView 不反應檔案內容變化 — OCR 原地替換 PDF 後,已開啟的預覽不會重載(updateUIView 空實作、URL 不變),顯示舊內容。
27. [P2] AppUI.swift:381-383 — onChange(of:) 使用已棄用的單參數版 — iOS 17 起應用雙參數 API,目前會產生編譯警告。
28. [P2] OCRService.swift:60 — assumedDPI 參數從未使用 — 簽名誤導呼叫者, either 實作 or 刪除。
29. [P2] ScanViewModel.swift:71, 360-376 — flatbedContinuation 僅靠 cancelScan 收尾 — 若 Task 被系統/其他路徑取消而非經過 cancelScan,continuation 永不 resume,scan flow 懸掛洩漏;可加 `withTaskCancellationHandler` 保險。

---

## Top 5 修復優先序

1. **文件庫改存相對檔名**(#1)— 一次 app 更新就全清單消失,資料層最痛; migration:載入時把既有絕對路徑取 lastPathComponent 重拼。
2. **PDF 組裝改串流寫出 + 移出 MainActor**(#2 + #9)— 600dpi×多頁必炸記憶體,且目前 UI 整段凍結;兩者一起改(逐頁 CGPDFContext 寫、背景 actor)。
3. **取消/重啟競態加 generation token**(#3)— 修掉 phase 互蓋與雙掃描並行,是狀態機正確性的根。
4. **pullPage 補 .completed 終態**(#4)— HP ADF 每次結尾多等 ~2 分鐘,使用者體感最直接的缺陷。
5. **OCRService 三合一**(#6 + #7 + #28)— renderer scale=1 修記憶體、replaceItemAt 修原子性、刪 assumedDPI;一次 PR 收拾 OCR 資源安全。
