import AppKit
import ScreenCaptureKit

/// 画面の取り込み。画像はメモリ上で解析に使うだけで、保存も送信もしない。
final class ScreenCapturer {
    private var filter: SCContentFilter?
    private var pointSize: CGSize = .zero
    private var scale: CGFloat = 2

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { CGRequestScreenCaptureAccess() }

    /// 指定した画面を、このアプリ自身のウインドウ（注釈）を除いて取り込む準備をする。
    func prepare(screen: NSScreen) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
            throw NSError(domain: "Hodoku", code: 1, userInfo: [NSLocalizedDescriptionKey: "画面が見つかりません"])
        }
        let me = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        self.filter = filter
        pointSize = CGSize(width: display.width, height: display.height)
        scale = CGFloat(filter.pointPixelScale)
    }

    func captureFull() async throws -> CGImage {
        try await capture(width: Int(pointSize.width * scale), height: Int(pointSize.height * scale))
    }

    /// 画面が変わったかどうかを見るための、粗い明るさの並び。
    func captureSignature() async throws -> [UInt8] {
        let w = 96, h = 60
        let image = try await capture(width: w, height: h)
        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBytes { buf in
            let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return pixels
    }

    private func capture(width: Int, height: Int) async throws -> CGImage {
        guard let filter else { throw NSError(domain: "Hodoku", code: 2) }
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var sum = 0
        for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count)
    }
}
