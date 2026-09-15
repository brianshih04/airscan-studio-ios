# iOS OCR / Searchable PDF 規劃（Backlog）

> 對應 Android 版：ML Kit Text Recognition v2 + Searchable PDF（docs/ocr-escl-image-pipeline.md）
> 狀態：等待掃描核心（Flatbed 逐頁合併 / ADF 進階 / 取消按鈕）完成後實作

## 方案：Vision framework（原生、免模型下載）

Android 用 ML Kit（需 Google Play services 下載模型、語言目錄管理、JP/KR 字型下載）。
iOS 用內建 Vision framework：離線、OS 內建多語模型、無下載流程。

## 階段一：OCR 開關 + 文字辨識

- 掃描設定頁加「文字辨識 (OCR)」toggle（預設關，比照 Android）
- 掃描完成後背景執行 VNRecognizeTextRequest：
  - recognitionLevel = .accurate
  - recognitionLanguages = 使用者選擇（預設 ["zh-Hant", "zh-Hans", "en-US"]）
  - 輸入：JPEG 頁面（12MP/4096px 長邊取樣，比照 Android 限制）
- 文件詳情頁加「文字」分頁：辨識結果預覽 + 複製按鈕
- OCR 失敗/無文字：明確顯示「未偵測到文字」，掃描頁保留（比照 Android Skipped 行為）

## 階段二：Searchable PDF

- PDFKit 頁面底下加隱形文字層：
  - VNRecognizeTextRequest 回傳 boundingBox（正規化座標）→ 換算 PDF 頁面座標
  - 每個辨識片段放透明文字 element（PDFKit 無原生支援，需用 CoreGraphics
    於 PDF context 繪製：先畫影像，再用 rendering mode .invisible 疊文字）
- 字型：系統內建（PingFang TC / Helvetica），免 Android 版的 Noto 下載管理
- 驗收：PDF 內可搜尋/複製中文與英文

## 階段三（選配）：語言選擇 UI

- 設定頁 OCR 區塊加語言多選（繁中/簡中/英/日/韓）
- 對應 VNRecognizeTextRequest.recognitionLanguages

## 已知差異 vs Android

| 項目 | Android (ML Kit) | iOS (Vision) |
|---|---|---|
| 模型 | Play services 下載 | OS 內建 |
| 語言 | 10 語 catalog | VNRecognizeTextRequest 支援語系 |
| JP/KR 字型下載 | 需要（Noto 20MB + SHA256） | 不需要（系統字型） |
| 未就緒行為 | 回 Skipped | 直接可用 |
