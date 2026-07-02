import XCTest
import CoreGraphics
import ImageIO
@testable import TRAE_FLOW

/// `MascotSpriteCache` 解码缓存测试
///
/// 验证 CGImageSource 解码路径能按原始像素尺寸读取 sprite sheet，
/// 避免因 NSImage representation 缩放导致 frameRect 切帧偏移。
@MainActor
final class MascotSpriteCacheTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mascot-sprite-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tempRoot = tmp
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        MascotSpriteCache.shared.clear()
    }

    func testSpriteCacheDecodesPNGAtPixelSize() throws {
        let imageURL = tempRoot.appendingPathComponent("fake.png")
        try writeSolidPNG(at: imageURL, size: CGSize(width: 96, height: 96))

        let manifest = MascotThemeManifest(
            id: "fake-theme",
            displayName: "Fake Theme",
            spritesheetPath: "fake.png"
        )
        let theme = MascotTheme(manifest: manifest, rootURL: tempRoot, source: .user)

        let cgImage = MascotSpriteCache.shared.cgImage(for: theme)
        XCTAssertNotNil(cgImage)
        XCTAssertEqual(cgImage?.width, 96)
        XCTAssertEqual(cgImage?.height, 96)
    }

    private func writeSolidPNG(at url: URL, size: CGSize) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("无法创建图形上下文")
        }
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        guard let cgImage = context.makeImage() else {
            throw XCTSkip("无法生成 CGImage")
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw XCTSkip("无法创建图片目标")
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
    }
}
