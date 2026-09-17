import SwiftUI
import PDFKit
import UIKit

/// UI mirroring the Android app's Material 3 design language:
/// icon-first home (gradient hero card + two feature cards + recent jobs),
/// chips for scan settings, full-width primary button, 4-tab navigation.

// MARK: - Design tokens (from Android version's palette)

extension Color {
    static let heroBlue = Color(red: 0.16, green: 0.32, blue: 0.75)
    static let heroTeal = Color(red: 0.02, green: 0.55, blue: 0.48)
    static let mintCard = Color(red: 0.78, green: 0.95, blue: 0.87)
    static let lavenderCard = Color(red: 0.90, green: 0.90, blue: 0.96)
    static let primaryAccent = Color(red: 0.25, green: 0.35, blue: 0.85)
    static let chipGreen = Color(red: 0.70, green: 0.93, blue: 0.82)
}

// MARK: - Root

@main
struct AirScanStudioApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}

struct RootTabView: View {
    @State private var tab = 0
    @StateObject private var scanVM = ScanViewModel()
    @Environment(\.horizontalSizeClass) private var hSizeClass

    fileprivate static let sidebarItems: [(label: String, icon: String)] = [
        ("首頁", "house.fill"),
        ("文件", "doc.fill"),
        ("紀錄", "clock.arrow.circlepath"),
        ("設定", "gearshape.fill")
    ]

    var body: some View {
        if hSizeClass == .regular {
            // iPad: sidebar navigation (mirrors Android NavigationRail at >=600dp)
            NavigationSplitView {
                List {
                    ForEach(0..<4, id: \.self) { i in
                        Button {
                            tab = i
                        } label: {
                            HStack {
                                Label(Self.sidebarItems[i].label, systemImage: Self.sidebarItems[i].icon)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .listRowBackground(tab == i ? Color.primaryAccent.opacity(0.15) : Color.clear)
                        .foregroundColor(tab == i ? Color.primaryAccent : Color.primary)
                    }
                }
                .listStyle(.sidebar)
                .navigationTitle("AirScan Studio")
            } detail: {
                switch tab {
                case 0: NavigationStack { HomeView(scanVM: scanVM) }
                case 1: NavigationStack { DocumentsView(scanVM: scanVM) }
                case 2: NavigationStack { HistoryView() }
                default: NavigationStack { SettingsView(scanVM: scanVM) }
                }
            }
            .tint(Color.primaryAccent)
        } else {
            TabView(selection: $tab) {
                HomeView(scanVM: scanVM)
                    .tabItem { Label("首頁", systemImage: "house.fill") }
                    .tag(0)
                DocumentsView(scanVM: scanVM)
                    .tabItem { Label("文件", systemImage: "doc.fill") }
                    .tag(1)
                HistoryView()
                    .tabItem { Label("紀錄", systemImage: "clock.arrow.circlepath") }
                    .tag(2)
                SettingsView(scanVM: scanVM)
                    .tabItem { Label("設定", systemImage: "gearshape.fill") }
                    .tag(3)
            }
            .tint(Color.primaryAccent)
        }
    }
}

/// Constrains content width on regular-width layouts and centers it.
struct MaxWidthContainer<Content: View>: View {
    var maxWidth: CGFloat = 720
    @ViewBuilder var content: Content
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        if hSizeClass == .regular {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                content.frame(maxWidth: maxWidth, alignment: .center)
                Spacer(minLength: 0)
            }
        } else {
            content
        }
    }
}

// MARK: - Home (mirrors 01-home.jpg)

struct HomeView: View {
    @ObservedObject var scanVM: ScanViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                MaxWidthContainer {
                    VStack(spacing: 16) {
                        header
                        heroCard
                        HStack(spacing: 12) {
                            printCard
                            deviceCard
                        }
                        recentCard
                    }
                    .padding(16)
                }
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("首頁")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "menucard")
                .font(.title2)
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.heroBlue))
            VStack(alignment: .leading) {
                Text("AirScan Studio").font(.title3.bold())
                Text(scanVM.mode.displayName).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            NavigationLink(destination: SettingsView(scanVM: scanVM)) {
                Image(systemName: "slider.horizontal.3").font(.title3)
            }
        }
    }

    private var heroCard: some View {
        NavigationLink(destination: ScanSettingsView(scanVM: scanVM)) {
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(LinearGradient(colors: [.heroBlue, .heroTeal],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: 34))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 60, height: 60)
                        .background(Circle().fill(.white.opacity(0.15)))
                    Spacer()
                    Text("掃描文件").font(.title.bold()).foregroundColor(.white)
                    Text("\(scanVM.settings.source == .adf ? "ADF" : "Flatbed") · \(scanVM.settings.paperSize.displayName) · \(scanVM.settings.resolution.displayName) · \(scanVM.settings.colorMode.displayName)")
                        .foregroundColor(.white.opacity(0.85))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .frame(height: 200)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("heroScanCard")
    }

    private var printCard: some View {
        NavigationLink(destination: PrintView(scanVM: scanVM)) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "printer.fill")
                    .font(.title3)
                    .foregroundColor(.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color.heroTeal))
                Spacer()
                Text("列印").font(.headline)
                Text("PDF · JPG · PNG").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color.mintCard))
        }
        .buttonStyle(.plain)
    }

    private var deviceCard: some View {
        NavigationLink(destination: DevicesView(scanVM: scanVM)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "scanner").frame(height: 28)
                    Image(systemName: "printer").frame(height: 28)
                }
                .foregroundColor(Color.heroTeal)
                Spacer()
                Text("裝置").font(.headline)
                Label("已就緒", systemImage: "magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color.lavenderCard))
        }
        .buttonStyle(.plain)
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("最近", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                NavigationLink(destination: DocumentsView(scanVM: scanVM)) {
                    Image(systemName: "arrow.right")
                }
            }
            ForEach(scanVM.documents.prefix(2)) { doc in
                HStack {
                    Image(systemName: doc.fileURL.pathExtension == "pdf" ? "doc.richtext" : "photo")
                        .foregroundColor(Color.heroBlue)
                    VStack(alignment: .leading) {
                        Text(doc.name).font(.subheadline)
                        Text("\(doc.pageCount) 頁 · \(doc.settings.resolution.displayName)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Self.friendlyDate(doc.createdAt))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if scanVM.documents.isEmpty {
                Text("尚無掃描文件").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(UIColor.secondarySystemGroupedBackground)))
    }

    private static func friendlyDate(_ d: Date) -> String {
        ScanViewModel.dateFormatter.string(from: d)
    }
}

// MARK: - Scan Settings (mirrors 02-scan-flatbed.jpg)

struct ScanSettingsView: View {
    @ObservedObject var scanVM: ScanViewModel
    @State private var showError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("掃描文件").font(.title.bold())

                summaryCard

                Group {
                    Text("文件來源").font(.subheadline.bold())
                    VStack(spacing: 10) {
                        sourceRadio(ScanSource.platen)
                        sourceRadio(ScanSource.adf)
                    }
                }

                Group {
                    Text("紙張尺寸").font(.subheadline.bold())
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(PaperSize.allCases) { p in
                                chip(selected: scanVM.settings.paperSize == p) {
                                    scanVM.settings.paperSize = p
                                } label: { Text(p.displayName) }
                            }
                        }
                    }
                }

                Group {
                    Text("解析度").font(.subheadline.bold())
                    HStack(spacing: 10) {
                        ForEach(ScanResolution.allCases) { r in
                            chip(selected: scanVM.settings.resolution == r) {
                                scanVM.settings.resolution = r
                            } label: { Text(r.displayName) }
                        }
                    }
                }

                Group {
                    Text("色彩").font(.subheadline.bold())
                    HStack(spacing: 10) {
                        ForEach(ScanColorMode.allCases) { c in
                            chip(selected: scanVM.settings.colorMode == c) {
                                scanVM.settings.colorMode = c
                            } label: { Text(c.displayName) }
                        }
                    }
                }

                if scanVM.settings.source == .adf {
                    Stepper("頁數上限: \(scanVM.adfPageLimit)", value: $scanVM.adfPageLimit, in: 1...50)
                        .font(.subheadline)
                    Toggle("雙面掃描（需掃描器支援）", isOn: $scanVM.duplexEnabled)
                        .font(.subheadline)
                }

                Group {
                    Text("文字辨識").font(.subheadline.bold())
                    VStack(spacing: 8) {
                        Toggle(isOn: $scanVM.ocrEnabled) {
                            HStack {
                                Image(systemName: "text.viewfinder")
                                    .foregroundColor(Color.primaryAccent)
                                Text("OCR 辨識文字")
                            }
                        }
                        .font(.subheadline)
                        Text("掃描後自動辨識文字，產出可搜尋/複製文字的 PDF 與 .txt。")
                            .font(.caption).foregroundStyle(.secondary)
                        if scanVM.ocrEnabled {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("辨識語言").font(.caption.bold()).foregroundStyle(.secondary)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(ScanViewModel.ocrLanguageOptions, id: \.code) { opt in
                                            Button {
                                                if scanVM.ocrLanguages.contains(opt.code) {
                                                    scanVM.ocrLanguages.remove(opt.code)
                                                } else {
                                                    scanVM.ocrLanguages.insert(opt.code)
                                                }
                                            } label: {
                                                Text(opt.name)
                                                    .font(.caption)
                                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                                    .background(Capsule().fill(
                                                        scanVM.ocrLanguages.contains(opt.code) ? Color.chipGreen : Color(UIColor.secondarySystemGroupedBackground)))
                                                    .overlay(Capsule().strokeBorder(
                                                        scanVM.ocrLanguages.contains(opt.code) ? .clear : Color.separator, lineWidth: 1))
                                            }
                                            .accessibilityIdentifier("ocrLang-\(opt.code)")
                                        }
                                    }
                                }
                                Text("未選擇時使用預設（繁中＋簡中＋英文）")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                scanButton
            }
            .padding(16)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle("掃描")
        .navigationBarTitleDisplayMode(.inline)
        .alert("掃描失敗", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            if case .failed(let msg) = scanVM.phase { Text(msg) }
        }
        .onChange(of: scanVM.phase) { _, ph in
            if case .failed = ph { showError = true }
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.viewfinder")
                .font(.title2)
                .foregroundColor(Color.primaryAccent)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.lavenderCard))
            VStack(alignment: .leading) {
                Text("掃描設定").font(.headline)
                Text("\(scanVM.settings.source == .platen ? "Flatbed" : "ADF") · \(scanVM.settings.resolution.displayName) · \(scanVM.settings.colorMode.displayName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(UIColor.secondarySystemGroupedBackground)))
    }

    private func sourceRadio(_ s: ScanSource) -> some View {
        Button {
            scanVM.settings.source = s
        } label: {
            HStack {
                Image(systemName: scanVM.settings.source == s ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(Color.primaryAccent)
                VStack(alignment: .leading) {
                    Text(s == .platen ? "Flatbed 單頁" : "ADF 多頁").font(.headline)
                    Text(s == .platen ? "單頁" : "多頁 · 最多 \(scanVM.adfPageLimit) 頁")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14)
                .fill(scanVM.settings.source == s ? Color.primaryAccent.opacity(0.10) : Color(UIColor.secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(scanVM.settings.source == s ? Color.primaryAccent : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private func chip(selected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            label()
                .font(.subheadline)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Capsule().fill(selected ? Color.chipGreen : Color(UIColor.secondarySystemGroupedBackground)))
                .overlay(Capsule().strokeBorder(selected ? .clear : Color.separator, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var scanButton: some View {
        Group {
            if scanVM.awaitingNextPage {
                // Flatbed 逐頁模式：掃描一頁完成後讓使用者選擇
                VStack(spacing: 10) {
                    Text("已掃描 \(scanVM.flatbedPageCount) 頁（上限 \(ScanViewModel.maxFlatbedPages) 頁）")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button {
                            scanVM.resolveFlatbedChoice(true)
                        } label: {
                            HStack {
                                Image(systemName: "plus.viewfinder")
                                Text("下一頁")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Capsule().fill(Color.heroTeal))
                        }
                        .accessibilityIdentifier("nextPageButton")
                        Button {
                            scanVM.resolveFlatbedChoice(false)
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.doc.fill")
                                Text("完成 PDF")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Capsule().fill(Color.primaryAccent))
                        }
                        .accessibilityIdentifier("finishPDFButton")
                    }
                }
            } else if isBusy {
                // 掃描中：按鈕變「取消」
                Button {
                    scanVM.cancelScan()
                } label: {
                    HStack {
                        if case .scanning(let p) = scanVM.phase {
                            ProgressView().tint(.white)
                            Text("取消掃描（第 \(p + 1) 頁）")
                        } else if case .saving = scanVM.phase {
                            ProgressView().tint(.white)
                            Text("取消（儲存中…）")
                        } else {
                            Image(systemName: "xmark.circle.fill")
                            Text("取消掃描")
                        }
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.red.opacity(0.85)))
                }
                .accessibilityIdentifier("cancelScanButton")
            } else {
                Button {
                    scanVM.startScan()
                } label: {
                    HStack {
                        Image(systemName: "doc.viewfinder")
                        Text("開始掃描")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.primaryAccent))
                }
                .accessibilityIdentifier("startScanButton")
            }
        }
    }

    private var isBusy: Bool {
        if scanVM.isScanning { return true }
        if case .saving = scanVM.phase { return true }
        return false
    }
}

// MARK: - Documents (mirrors 04-documents.jpg)

struct DocumentsView: View {
    @ObservedObject var scanVM: ScanViewModel
    @State private var selectedDoc: ScannedDocument?
    @State private var showPreview = false

    var body: some View {
        NavigationStack {
            Group {
                if scanVM.documents.isEmpty {
                    ContentUnavailableView("尚無文件", systemImage: "doc.text.magnifyingglass",
                                           description: Text("從首頁開始第一次掃描"))
                } else {
                    List {
                        ForEach(scanVM.documents) { doc in
                            Button {
                                selectedDoc = doc
                                showPreview = true
                            } label: {
                                DocumentRow(doc: doc, scanVM: scanVM)
                            }
                            .accessibilityIdentifier("documentRow-\(doc.name)")
                            .swipeActions {
                                Button(role: .destructive) {
                                    scanVM.deleteDocument(doc)
                                } label: { Label("刪除", systemImage: "trash") }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("文件")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showPreview) {
                if let doc = selectedDoc {
                    DocumentPreviewView(doc: doc, scanVM: scanVM)
                }
            }
        }
    }
}

struct DocumentRow: View {
    let doc: ScannedDocument
    @ObservedObject var scanVM: ScanViewModel

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.name).font(.subheadline.weight(.medium))
                Text("\(doc.pageCount) 頁 · \(doc.settings.resolution.displayName) · \(doc.settings.colorMode.displayName)")
                    .font(.caption).foregroundStyle(.secondary)
                if !doc.actualSettingsReported {
                    Text("(requested settings)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if doc.fileURL.pathExtension == "pdf",
           let page = PDFDocument(url: doc.fileURL)?.page(at: 0) {
            Image(uiImage: page.thumbnail(of: CGSize(width: 120, height: 160), for: .mediaBox))
                .resizable().scaledToFill()
                .frame(width: 48, height: 64).clipShape(RoundedRectangle(cornerRadius: 6))
        } else if let img = UIImage(data: (try? Data(contentsOf: doc.fileURL)) ?? Data()) {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(width: 48, height: 64).clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6).fill(Color.lavenderCard)
                .frame(width: 48, height: 64)
                .overlay(Image(systemName: "doc").foregroundColor(.secondary))
        }
    }
}

// MARK: - Document Preview（含 OCR「文字」分頁，backlog 階段一）

struct DocumentPreviewView: View {
    let doc: ScannedDocument
    @ObservedObject var scanVM: ScanViewModel
    @State private var tab: Int = 0 // 0=原稿 1=文字
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            // 自製分段按鈕（iOS 26 的 segmented Picker 對 Accessibility/XCUITest 不可見）
            HStack(spacing: 8) {
                tabButton("原稿", id: "previewTabOriginal", selected: tab == 0) { tab = 0 }
                tabButton("文字", id: "previewTabText", selected: tab == 1) { tab = 1 }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if tab == 0 {
                previewContent
            } else {
                textTab
            }
        }
        .navigationTitle(doc.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tabButton(_ label: String, id: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(Capsule().fill(selected ? Color.primaryAccent.opacity(0.15) : Color(UIColor.secondarySystemGroupedBackground)))
                .overlay(Capsule().strokeBorder(selected ? Color.primaryAccent : Color.separator, lineWidth: 1))
        }
        .foregroundColor(selected ? Color.primaryAccent : .secondary)
        .accessibilityIdentifier(id)
    }

    @ViewBuilder private var previewContent: some View {
        if doc.fileURL.pathExtension == "pdf" {
            PDFKitView(url: doc.fileURL)
        } else if FileManager.default.fileExists(atPath: doc.fileURL.path),
                  let img = UIImage(data: (try? Data(contentsOf: doc.fileURL)) ?? Data()) {
            ScrollView { Image(uiImage: img).resizable().scaledToFit() }
        } else {
            ContentUnavailableView("無法預覽", systemImage: "exclamationmark.triangle")
        }
    }

    /// OCR 結果分頁：辨識中 / 未偵測到文字 / 結果預覽 + 複製（比照 Android 文字分頁）
    @ViewBuilder private var textTab: some View {
        let path = doc.fileURL.path
        if scanVM.ocrRunningPaths.contains(path) {
            VStack(spacing: 12) {
                ProgressView()
                Text("文字辨識中…").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let txt = OCRTextStore.load(for: doc) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("辨識結果").font(.headline)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = txt
                            copied = true
                        } label: {
                            Label(copied ? "已複製" : "複製", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.subheadline)
                        }
                        .accessibilityIdentifier("ocrCopyButton")
                    }
                    Text(txt)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
        } else if case .noText = scanVM.ocrOutcome[path] {
            ContentUnavailableView("未偵測到文字", systemImage: "doc.text.magnifyingglass",
                                   description: Text("掃描頁保留，可調整內容後重新辨識。"))
        } else if case .failed(let msg) = scanVM.ocrOutcome[path] {
            ContentUnavailableView {
                Label("辨識失敗", systemImage: "exclamationmark.triangle")
            } description: {
                Text(msg)
            } actions: {
                Button("重新辨識") { scanVM.runOCRNow(for: doc) }
            }
        } else {
            // 沒有 .txt：OCR 未跑過（開關沒開）。提供手動執行。
            VStack(spacing: 14) {
                ContentUnavailableView("尚未辨識文字", systemImage: "text.viewfinder",
                                       description: Text("開啟「OCR 辨識文字」後新掃描會自動辨識；也可對此文件直接執行。"))
                Button {
                    scanVM.runOCRNow(for: doc)
                } label: {
                    Label("辨識此文件", systemImage: "play.fill")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(Capsule().fill(Color.primaryAccent))
                }
                .accessibilityIdentifier("ocrRunButton")
            }
        }
    }
}

/// OCR 文字讀取：<文件>.txt 與文件同目錄同名
enum OCRTextStore {
    static func textFileURL(for doc: ScannedDocument) -> URL {
        doc.fileURL.deletingPathExtension().appendingPathExtension("txt")
    }
    static func load(for doc: ScannedDocument) -> String? {
        let url = textFileURL(for: doc)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

struct PDFKitView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.document = PDFDocument(url: url)
        return v
    }
    func updateUIView(_ uiView: PDFView, context: Context) {}
}

// MARK: - Print (AirPrint)

struct PrintView: View {
    @ObservedObject var scanVM: ScanViewModel

    var body: some View {
        List {
            Section("掃描文件") {
                ForEach(scanVM.documents) { doc in
                    Button {
                        printDocument(url: doc.fileURL, name: doc.name)
                    } label: {
                        HStack {
                            Image(systemName: "printer").foregroundColor(Color.heroBlue)
                            Text(doc.name).font(.subheadline)
                            Spacer()
                            Text("列印").font(.caption).foregroundColor(Color.primaryAccent)
                        }
                    }
                }
            }
            Section {
                Button {
                    pickAndPrintFromFiles()
                } label: {
                    Label("從檔案選擇…", systemImage: "folder")
                }
            } footer: {
                Text("使用系統 AirPrint 選擇印表機、份數與紙張。")
            }
        }
        .navigationTitle("列印")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func printDocument(url: URL, name: String) {
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = name
        controller.printInfo = info
        controller.printingItem = url as NSURL
        controller.present(animated: true)
    }

    private func pickAndPrintFromFiles() {
        // Simplified: the picker integration lands in the next milestone.
        // For now, direct print of latest doc.
        if let latest = scanVM.documents.first {
            printDocument(url: latest.fileURL, name: latest.name)
        }
    }
}

// MARK: - Devices (mirror 裝置 card)

struct DevicesView: View {
    @ObservedObject var scanVM: ScanViewModel
    @State private var manualHost = ""
    @State private var manualInputError: String?

    var body: some View {
        List {
            if scanVM.mode == .mock {
                Section {
                    ContentUnavailableView("模擬模式", systemImage: "wand.and.stars",
                                           description: Text("切換至真實模式以探索網路掃描器"))
                }
            } else {
                Section {
                    if scanVM.discovered.isEmpty {
                        HStack {
                            ProgressView()
                            Text(scanVM.isBrowsing ? "探索中… (_uscan/_uscans)" : "尚未探索")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    // manual 裝置改列在下方的「手動加入」區（可滑動刪除），這裡只列 Bonjour 探索結果
                    ForEach(scanVM.discovered.filter { !$0.id.hasPrefix("manual-") }) { s in
                        Button {
                            scanVM.selectedScannerID = s.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name).font(.subheadline.weight(.medium))
                                    Text("\(s.host):\(s.port) · \(s.isSecure ? "TLS" : "HTTP")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if scanVM.selectedScanner?.id == s.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(Color.primaryAccent)
                                }
                            }
                        }
                    }
                } header: {
                    Text("eSCL 掃描器")
                } footer: {
                    Text("首次使用需允許「區域網路」權限（設定 → 隱私權與安全性 → 區域網路）。")
                }

                Section("手動加入（Bonjour 被擋時）") {
                    HStack {
                        TextField("IP 位址，例如 192.168.1.50:8080", text: $manualHost)
                            .keyboardType(.decimalPad)
                        Button("加入") {
                            // port 範圍驗證（review #22）：無效輸入不加入、顯示錯誤
                            if !scanVM.addManual(host: manualHost.trimmingCharacters(in: .whitespaces)) {
                                manualInputError = "位址或連接埠無效（port 需 1-65535）"
                            } else {
                                manualInputError = nil
                                manualHost = ""
                            }
                        }
                        .disabled(manualHost.isEmpty)
                    }
                    if let err = manualInputError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                    ForEach(scanVM.discovered.filter { $0.id.hasPrefix("manual-") }) { s in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.subheadline.weight(.medium))
                                Text("\(s.host):\(s.port) · HTTP")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if scanVM.selectedScanner?.id == s.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Color.primaryAccent)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                scanVM.removeManual(scanner: s)
                            } label: { Label("刪除", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .navigationTitle("裝置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { scanVM.startDiscovery() }
    }
}

// MARK: - History

struct HistoryView: View {
    var body: some View {
        ContentUnavailableView("尚無紀錄", systemImage: "clock.arrow.circlepath",
                               description: Text("掃描與列印工作紀錄將顯示在這裡"))
        .navigationTitle("紀錄")
    }
}

// MARK: - Settings (mirrors 07-settings.jpg)

struct SettingsView: View {
    @ObservedObject var scanVM: ScanViewModel

    var body: some View {
        Form {
            Section("掃描模式") {
                Picker("模式", selection: $scanVM.mode) {
                    ForEach(ScanViewModel.Mode.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                Text(scanVM.mode == .mock
                     ? "模擬模式不需實體掃描器，適合開發與 UI 驗證。"
                     : "真實模式透過 eSCL (AirScan) 連線網路掃描器。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("關於") {
                LabeledContent("版本", value: "0.1.0 (MVP)")
                LabeledContent("掃描協定", value: "eSCL v2.63")
                LabeledContent("列印", value: "AirPrint (系統)")
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Helpers

extension Color {
    static let separator = Color(UIColor.separator)
}

#Preview {
    RootTabView()
}
