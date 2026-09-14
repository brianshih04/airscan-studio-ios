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
                    Text("\(scanVM.settings.source == .adf ? "ADF" : "Flatbed") · \(scanVM.settings.resolution.displayName) · \(scanVM.settings.colorMode.displayName)")
                        .foregroundColor(.white.opacity(0.85))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .frame(height: 200)
        }
        .buttonStyle(.plain)
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
        Button {
            Task { await scanVM.startScan() }
        } label: {
            HStack {
                if case .scanning(let p) = scanVM.phase {
                    ProgressView().tint(.white)
                    Text("掃描中... 第 \(p + 1) 頁")
                } else {
                    Image(systemName: "doc.viewfinder")
                    Text("開始掃描")
                }
            }
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Capsule().fill(Color.primaryAccent))
        }
        .disabled(isBusy)
    }

    private var isBusy: Bool {
        if case .scanning = scanVM.phase { return true }
        if case .saving = scanVM.phase { return true }
        return false
    }
}

// MARK: - Documents (mirrors 04-documents.jpg)

struct DocumentsView: View {
    @ObservedObject var scanVM: ScanViewModel

    var body: some View {
        Group {
            if scanVM.documents.isEmpty {
                ContentUnavailableView("尚無文件", systemImage: "doc.text.magnifyingglass",
                                       description: Text("從首頁開始第一次掃描"))
            } else {
                List {
                    ForEach(scanVM.documents) { doc in
                        DocumentRow(doc: doc)
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
    }
}

struct DocumentRow: View {
    let doc: ScannedDocument

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
            NavigationLink(destination: DocumentPreviewView(doc: doc)) {
                Image(systemName: "chevron.right").font(.caption)
            }.opacity(0.5)
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

// MARK: - Document Preview

struct DocumentPreviewView: View {
    let doc: ScannedDocument

    var body: some View {
        Group {
            if doc.fileURL.pathExtension == "pdf" {
                PDFKitView(url: doc.fileURL)
            } else if FileManager.default.fileExists(atPath: doc.fileURL.path),
                      let img = UIImage(data: (try? Data(contentsOf: doc.fileURL)) ?? Data()) {
                ScrollView { Image(uiImage: img).resizable().scaledToFit() }
            } else {
                ContentUnavailableView("無法預覽", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle(doc.name)
        .navigationBarTitleDisplayMode(.inline)
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

    var body: some View {
        List {
            Section {
                if scanVM.mode == .mock {
                    ContentUnavailableView("模擬模式", systemImage: "wand.and.stars",
                                           description: Text("切換至真實模式以探索網路掃描器"))
                } else {
                    ForEach(scanVM.browser.scanners) { s in
                        VStack(alignment: .leading) {
                            Text(s.name)
                            Text("\(s.isSecure ? "uscanS(TLS)" : "uscan") · \(s.rootPath)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("eSCL 掃描器 (_uscan/_uscans)")
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
