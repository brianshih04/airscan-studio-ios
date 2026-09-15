import XCTest
@testable import AirScanStudio

final class ESCLTests: XCTestCase {
    func testScanSettingsXML() {
        var s = ScanSettings()
        s.source = .adf
        s.resolution = .dpi300
        s.colorMode = .rgb24
        let xml = ESCLClient.scanSettingsXML(s, namespace: "http://schemas.microsoft.com/windows/scanning")
        XCTAssertTrue(xml.contains("<scan:InputSource>Feeder</scan:InputSource>"))
        XCTAssertTrue(xml.contains("<scan:XResolution>300</scan:XResolution>"))
        XCTAssertTrue(xml.contains("<scan:ColorMode>RGB24</scan:ColorMode>"))
        XCTAssertTrue(xml.contains("<pwg:Width>2480</pwg:Width>"))
        XCTAssertTrue(xml.contains("<pwg:Height>3508</pwg:Height>"))
    }

    func testA4PixelDimensions() {
        var s = ScanSettings()
        s.resolution = .dpi150
        XCTAssertEqual(s.widthPx, 1240)   // 210mm at 150dpi
        XCTAssertEqual(s.heightPx, 1754)  // 297mm at 150dpi
        s.resolution = .dpi300
        XCTAssertEqual(s.widthPx, 2480)
        XCTAssertEqual(s.heightPx, 3508)
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

    func testMockGeneratorProducesJPEG() {
        let data = MockScanGenerator.generatePage(settings: ScanSettings(), pageIndex: 0, totalPages: 1)
        XCTAssertGreaterThan(data.count, 10_000)
        XCTAssertNotNil(UIImage(data: data))
    }
}
