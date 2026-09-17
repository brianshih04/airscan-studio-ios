import Foundation
import SwiftUI
import PDFKit
import UIKit

/// Generates synthetic scan documents for Mock mode.
/// Mirrors the Android app's MockScannerRepository: lets the whole flow
/// (scan → document library → print) work without a physical device.
enum MockScanGenerator {
    /// Renders an A4 page with a subtle paper texture + content blocks, returns JPEG data.
    /// format.scale = 1（review B3）：預設 renderer 帶螢幕 scale（3x），2480×3508 的
    /// 「模擬 A4 頁」會實際 render 成 7440×10524 bitmap（~313MB/頁），多頁直接炸記憶體。
    static func generatePage(settings: ScanSettings, pageIndex: Int, totalPages: Int) -> Data {
        let width = CGFloat(min(settings.widthPx, 2480))
        let height = CGFloat(min(settings.heightPx, 3508))
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            // Paper background
            UIColor(white: 0.985, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            let gray = settings.colorMode == .bw1
            let ink: UIColor = gray ? UIColor.black : UIColor(darkGray: 0.15)

            let w08 = width * 0.08
            // Header bar
            ink.setFill()
            ctx.fill(CGRect(x: w08, y: height * 0.07, width: width * 0.35, height: height * 0.02))

            // Fake text lines
            for i in 0..<22 {
                let frac: CGFloat = 0.55 + CGFloat((i * 37) % 40) / 100.0
                let alpha: CGFloat = settings.colorMode == .grayscale8 ? 0.45 : 0.72
                let lineWidth = width * frac
                let lineY = height * 0.13 + CGFloat(i) * height * 0.028
                ink.withAlphaComponent(alpha).setFill()
                ctx.fill(CGRect(x: w08, y: lineY, width: lineWidth, height: height * 0.008))
            }

            // Fake diagram box
            let box = CGRect(x: width * 0.18, y: height * 0.78, width: width * 0.64, height: height * 0.12)
            ink.withAlphaComponent(0.8).setFill()
            ctx.fill(box)

            // Page footer
            let footer = "MOCK SCAN · page \(pageIndex + 1)/\(totalPages) · \(settings.resolution.rawValue)dpi · \(settings.colorMode.displayName)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: CGFloat(height) * 0.016, weight: .medium),
                .foregroundColor: ink.withAlphaComponent(0.6)
            ]
            footer.draw(at: CGPoint(x: width * 0.08, y: height * 0.955), withAttributes: attrs)
        }
        return image.jpegData(compressionQuality: 0.85) ?? Data()
    }

    /// Builds a multi-page PDF from generated pages.
    /// 逐頁串流寫出（review B3）：不再 PDFPage(image:) 全頁解碼圖駐留
    /// （50 頁 × 3x-scale bitmap = 15.6GB 峰值需求 → jetsam），改走與 real 掃描
    /// 相同的 ScanViewModel.writePDF 串流路徑，每頁寫入即釋放，峰值 = 單頁。
    /// 回傳實際寫入頁數。
    @discardableResult
    static func generatePDF(settings: ScanSettings, pageCount: Int, to url: URL) throws -> Int {
        var pages: [Data] = []
        pages.reserveCapacity(pageCount)
        for i in 0..<pageCount {
            pages.append(generatePage(settings: settings, pageIndex: i, totalPages: pageCount))
        }
        return try ScanViewModel.writePDF(from: pages, to: url)
    }
}

private extension UIColor {
    convenience init(darkGray v: CGFloat) {
        self.init(red: v, green: v, blue: v, alpha: 1)
    }
}
