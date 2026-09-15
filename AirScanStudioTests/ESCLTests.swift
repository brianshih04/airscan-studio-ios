import XCTest
@testable import AirScanStudio

final class ESCLTests: XCTestCase {
    func testScanSettingsXML() {
        var s = ScanSettings()
        s.source = .adf
        s.resolution = .dpi300
        s.colorMode = .rgb24
        let xml = ESCLClient.scanSettingsXML(s, namespace: "http://schemas.microsoft.com/windows/scanning")
        XCTAssertTrue(xml.contains("<pwg:InputSource>Feeder</pwg:InputSource>"))
        XCTAssertTrue(xml.contains("<scan:XResolution>300</scan:XResolution>"))
        XCTAssertTrue(xml.contains("<scan:ColorMode>RGB24</scan:ColorMode>"))
        // 尺寸以 ScanRegions 表達（Android 版對齊），不在 top-level
        XCTAssertTrue(xml.contains("<pwg:Width>2480</pwg:Width>"))
        XCTAssertTrue(xml.contains("<pwg:Height>3508</pwg:Height>"))
        XCTAssertTrue(xml.contains("<pwg:XOffset>0</pwg:XOffset>"))
        XCTAssertFalse(xml.contains("<pwg:Width>2480</pwg:Width>\n          <pwg:Height>"))
    }

    func testA4PixelDimensions() {
        // eSCL Width/Height are in 1/300-inch units, independent of dpi
        let s = ScanSettings()
        XCTAssertEqual(s.widthPx, 2480)
        XCTAssertEqual(s.heightPx, 3508)
        var s150 = ScanSettings()
        s150.resolution = .dpi150
        XCTAssertEqual(s150.widthPx, 2480)   // Width/Height unchanged
        XCTAssertEqual(s150.heightPx, 3508)
    }

    func testJobPhaseParsing() {
        let completed = "<pwg:JobState>Completed</pwg:JobState>".data(using: .utf8)!
        XCTAssertEqual(ESCLClient.parseJobPhase(completed), .completed)
        let processing = "<pwg:JobState>Processing</pwg:JobState>".data(using: .utf8)!
        XCTAssertEqual(ESCLClient.parseJobPhase(processing), .processing)
        let aborted = "<JobState>Aborted</JobState>".data(using: .utf8)!
        XCTAssertEqual(ESCLClient.parseJobPhase(aborted), .aborted)
    }

    func testCapabilitiesParsing() throws {
        let xml = """
        <scan:ScannerCapabilities xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm" xmlns:scan="http://schemas.microsoft.com/windows/scanning">
          <pwg:Version>2.63</pwg:Version>
          <pwg:MakerAndModel>HP LaserJet Pro MFP 3104fdw</pwg:MakerAndModel>
          <scan:Platen>
            <scan:PlatenInputCaps><scan:MinWidth>8</scan:MinWidth></scan:PlatenInputCaps>
          </scan:Platen>
          <scan:Adf>
            <scan:FeederInputCaps><scan:FeederMaxWidth>100</scan:FeederMaxWidth></scan:FeederInputCaps>
          </scan:Adf>
        </scan:ScannerCapabilities>
        """.data(using: .utf8)!
        let client = ESCLClient(scanner: DiscoveredScanner(id: "t", name: "t", host: "1.2.3.4", port: 80, isSecure: false))
        let caps = try client.fetchCapabilitiesParser(xml)
        XCTAssertTrue(caps.supportsPlaten)
        XCTAssertTrue(caps.supportsAdf)
        XCTAssertEqual(caps.version, "2.63")
        XCTAssertEqual(caps.maker, "HP LaserJet Pro MFP 3104fdw")
    }

    // MARK: - ADF 進階（scan:NumberOfPages / scan:Duplex）

    func testScanSettingsXMLSendsNumberOfPagesForADF() {
        var s = ScanSettings()
        s.source = .adf
        let xml = ESCLClient.scanSettingsXML(s, namespace: "http://schemas.microsoft.com/windows/scanning",
                                             numberOfPages: 7, duplex: false)
        XCTAssertTrue(xml.contains("<scan:NumberOfPages>7</scan:NumberOfPages>"),
                      "ADF 支援時應送 scan:NumberOfPages")
        XCTAssertFalse(xml.contains("<scan:Duplex>"), "未啟用雙面時不應送 scan:Duplex")
    }

    func testScanSettingsXMLSendsDuplexWhenEnabled() {
        var s = ScanSettings()
        s.source = .adf
        let xml = ESCLClient.scanSettingsXML(s, namespace: "http://schemas.microsoft.com/windows/scanning",
                                             numberOfPages: 5, duplex: true)
        XCTAssertTrue(xml.contains("<scan:Duplex>true</scan:Duplex>"),
                      "caps.adfDuplex 時應送 scan:Duplex")
        XCTAssertTrue(xml.contains("<scan:NumberOfPages>5</scan:NumberOfPages>"))
    }

    func testScanSettingsXMLNoADFOptionsForPlaten() {
        var s = ScanSettings()
        s.source = .platen
        let xml = ESCLClient.scanSettingsXML(s, namespace: "http://schemas.microsoft.com/windows/scanning",
                                             numberOfPages: 3, duplex: true)
        XCTAssertFalse(xml.contains("NumberOfPages"), "Platen 不應送 NumberOfPages")
        XCTAssertFalse(xml.contains("Duplex"), "Platen 不應送 Duplex")
    }

    func testCapsAdfDuplexParsing() throws {
        let xml = """
        <scan:ScannerCapabilities xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm" xmlns:scan="http://schemas.microsoft.com/windows/scanning">
          <pwg:Version>2.63</pwg:Version>
          <scan:Adf>
            <scan:FeederInputCaps><scan:FeederMaxWidth>100</scan:FeederMaxWidth></scan:FeederInputCaps>
            <scan:AdfDuplexInputCaps><scan:MinWidth>8</scan:MinWidth></scan:AdfDuplexInputCaps>
          </scan:Adf>
        </scan:ScannerCapabilities>
        """.data(using: .utf8)!
        let client = ESCLClient(scanner: DiscoveredScanner(id: "t", name: "t", host: "1.2.3.4", port: 80, isSecure: false))
        let caps = try client.fetchCapabilitiesParser(xml)
        XCTAssertTrue(caps.supportsAdf)
        XCTAssertTrue(caps.adfDuplex, "含 AdfDuplexInputCaps 時 adfDuplex 應為 true")
    }

    // MARK: - Flatbed 逐頁合併 PDF

    func testMaxFlatbedPagesIs50() {
        XCTAssertEqual(ScanViewModel.maxFlatbedPages, 50)
    }

    /// 驗證 Flatbed 逐頁狀態機：prompt 掛起 → resolve(.finish) → continuation 恢復
    @MainActor
    func testFlatbedChoiceFlowNextThenFinish() async throws {
        let vm = ScanViewModel()
        // 直接驗證 continuation 機制（不觸發真掃，真掃由整合測試覆蓋）
        let promptTask = Task { try await vm.promptFlatbedNextPage(pageNumber: 1) }
        for _ in 0..<100 where !vm.awaitingNextPage {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(vm.awaitingNextPage, "prompt 後應進入等待狀態")
        XCTAssertTrue(vm.phase == .awaitingNextPage(page: 1) || vm.awaitingNextPage)
        vm.resolveFlatbedChoice(true) // 下一頁
        let choice = try await promptTask.value
        XCTAssertEqual(choice, .nextPage)
        XCTAssertFalse(vm.awaitingNextPage, "resolve 後應離開等待狀態")
    }

    /// 驗證取消路徑：prompt 掛起 → cancelScan → continuation 拋 CancellationError、phase 回 idle
    @MainActor
    func testCancelScanResolvesPromptAndResetsPhase() async throws {
        let vm = ScanViewModel()
        let promptTask = Task { try await vm.promptFlatbedNextPage(pageNumber: 1) }
        for _ in 0..<100 where !vm.awaitingNextPage {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(vm.awaitingNextPage)
        vm.cancelScan()
        XCTAssertEqual(vm.phase, .idle, "取消後 phase 應回 idle")
        XCTAssertFalse(vm.awaitingNextPage)
        do {
            _ = try await promptTask.value
            XCTFail("取消應拋 CancellationError")
        } catch is CancellationError {
            // 預期路徑
        }
    }

    func testMockGeneratorProducesJPEG() {
        let data = MockScanGenerator.generatePage(settings: ScanSettings(), pageIndex: 0, totalPages: 1)
        XCTAssertGreaterThan(data.count, 10_000)
        XCTAssertNotNil(UIImage(data: data))
    }
}
