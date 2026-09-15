
import XCTest
@testable import AirScanStudio

/// 需要真機掃描器（manualScannerHost 指定）。驗證 ScanViewModel 的真實掃描路徑。
final class ScanViewModelIntegrationTests: XCTestCase {
    func testRealScanAgainstPinnedScannerADF() async throws {
        let vm = await ScanViewModel()
        await MainActor.run {
            vm.mode = .real
        }
        // pinned scanner comes from UserDefaults manualScannerHost (set by test runner)
        try await vm.startScanForTesting(source: .adf)
        let docs = await vm.documents
        let newest = try XCTUnwrap(docs.first, "掃描後應有文件")
        let actual = await newest.actualSettingsReported
        // page file must exist
        let url = await newest.fileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let pageCount = await newest.pageCount
        XCTAssertGreaterThanOrEqual(pageCount, 1, "ADF 掃描至少 1 頁")
    }


    func testBrotherResolutionColorMatrix() async throws {
        // 需 Brother 10.1.121.175 上線 + 玻璃板有文件
        let matrix: [(ScanResolution, ScanColorMode)] = [
            (.dpi200, .rgb24), (.dpi200, .grayscale8),
            (.dpi300, .rgb24), (.dpi300, .grayscale8),
            (.dpi600, .rgb24), (.dpi600, .grayscale8),
        ]
        let vm = await ScanViewModel()
        await MainActor.run {
            vm.mode = .real
            vm.settings.source = .platen
        }
        for (dpi, color) in matrix {
            await MainActor.run {
                vm.settings.resolution = dpi
                vm.settings.colorMode = color
            }
            // Brother needs ~15s cool-down between jobs (503 when back-to-back)
            var lastErr: Error?
            for attempt in 0..<3 {
                do {
                    try await vm.startScanForTesting()
                    lastErr = nil
                    break
                } catch {
                    lastErr = error
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                }
            }
            if let e = lastErr { throw e }
            let docs = await vm.documents
            let newest = try XCTUnwrap(docs.first, "\(dpi)dpi \(color) 應有文件")
            let pages = await newest.pageCount
            XCTAssertGreaterThanOrEqual(pages, 1)
            print("MATRIX \(dpi)dpi \(color.rawValue): ok, pages=\(pages)")
        }
    }

}
