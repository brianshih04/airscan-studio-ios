
import XCTest
@testable import AirScanStudio

/// 需要真機掃描器（manualScannerHost 指定）。驗證 ScanViewModel 的真實掃描路徑。
final class ScanViewModelIntegrationTests: XCTestCase {
    func testRealScanAgainstPinnedScanner() async throws {
        let vm = await ScanViewModel()
        await MainActor.run {
            vm.mode = .real
        }
        // pinned scanner comes from UserDefaults manualScannerHost (set by test runner)
        try await vm.startScanForTesting()
        let docs = await vm.documents
        let newest = try XCTUnwrap(docs.first, "掃描後應有文件")
        let actual = await newest.actualSettingsReported
        // page file must exist
        let url = await newest.fileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
