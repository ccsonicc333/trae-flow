import XCTest
@testable import TRAE_FLOW

final class MascotFrameLayoutTests: XCTestCase {
    // 1. 默认布局：192×208，codex 9 状态映射第 0~8 行
    func testDefaultLayoutUsesCodexFrameSizeAndRowMapping() {
        let layout = MascotFrameLayout.defaultLayout

        XCTAssertEqual(layout.frameWidth, 192)
        XCTAssertEqual(layout.frameHeight, 208)
        XCTAssertEqual(layout.fps, 8)
        XCTAssertEqual(layout.row(for: .idle), 0)
        XCTAssertEqual(layout.row(for: .runRight), 1)
        XCTAssertEqual(layout.row(for: .runLeft), 2)
        XCTAssertEqual(layout.row(for: .waving), 5)
        XCTAssertEqual(layout.row(for: .jumping), 4)
        XCTAssertEqual(layout.row(for: .failed), 3)
        XCTAssertEqual(layout.row(for: .waiting), 6)
        XCTAssertEqual(layout.row(for: .running), 7)
        XCTAssertEqual(layout.row(for: .review), 8)
        XCTAssertEqual(layout.row(for: .dragging), 8)
        XCTAssertEqual(layout.framesPerRow[.idle], 8)
        XCTAssertEqual(layout.framesPerRow[.running], 8)
        XCTAssertEqual(layout.framesPerRow[.review], 8)
    }

    // 2. 在 1536×1872 图片上 frameCountPerRow 返回 8
    func testFrameCountPerRowOnStandard1536WidthImage() {
        let layout = MascotFrameLayout.defaultLayout
        XCTAssertEqual(layout.frameCountPerRow(imageWidth: 1536), 8)
    }

    // 3. 自定义 frameWidth=64 时按 64 切帧
    func testCustomFrameWidthSlicesAccordingly() throws {
        let json = """
        {
            "id": "custom",
            "displayName": "Custom",
            "frameWidth": 64,
            "frameHeight": 64
        }
        """
        let manifest = try JSONDecoder().decode(
            MascotThemeManifest.self,
            from: json.data(using: .utf8) ?? Data()
        )
        let layout = MascotFrameLayout.from(manifest: manifest)

        XCTAssertEqual(layout.frameWidth, 64)
        XCTAssertEqual(layout.frameHeight, 64)
        // 1536 宽度按 64 切帧 = 24 帧/行
        XCTAssertEqual(layout.frameCountPerRow(imageWidth: 1536), 24)
        // 行映射未声明时回退到 codex 默认 0~8
        XCTAssertEqual(layout.row(for: .idle), 0)
        XCTAssertEqual(layout.row(for: .runRight), 1)
        XCTAssertEqual(layout.row(for: .running), 7)
        XCTAssertEqual(layout.row(for: .review), 8)
    }

    // 4. frameRect 像素坐标正确性（idle 第 0 帧在 (0,0)，running 第 1 帧在 (192,1456)）
    func testFrameRectPixelCoordinates() {
        let layout = MascotFrameLayout.defaultLayout

        // idle 第 0 帧：x=0, y=0
        XCTAssertEqual(
            layout.frameRect(for: .idle, frameIndex: 0, imageWidth: 1536, imageHeight: 1872),
            CGRect(x: 0, y: 0, width: 192, height: 208)
        )
        // runRight 第 1 帧：x=192, y=208
        XCTAssertEqual(
            layout.frameRect(for: .runRight, frameIndex: 1, imageWidth: 1536, imageHeight: 1872),
            CGRect(x: 192, y: 208, width: 192, height: 208)
        )
        // running 第 2 帧：x=384, y=1456
        XCTAssertEqual(
            layout.frameRect(for: .running, frameIndex: 2, imageWidth: 1536, imageHeight: 1872),
            CGRect(x: 384, y: 1456, width: 192, height: 208)
        )
        // review 第 3 帧：x=576, y=1664
        XCTAssertEqual(
            layout.frameRect(for: .review, frameIndex: 3, imageWidth: 1536, imageHeight: 1872),
            CGRect(x: 576, y: 1664, width: 192, height: 208)
        )
    }

    // 5. frameIndex 越界取模
    func testFrameIndexOutOfBoundsWrapsWithModulo() {
        let layout = MascotFrameLayout.defaultLayout
        // 1536 宽度 / 192 = 8 帧/行；frameIndex=8 应取模回 0
        XCTAssertEqual(
            layout.frameRect(for: .idle, frameIndex: 8, imageWidth: 1536, imageHeight: 1872),
            CGRect(x: 0, y: 0, width: 192, height: 208)
        )
        // frameIndex=9 取模为 1，x=192
        XCTAssertEqual(
            layout.frameRect(for: .idle, frameIndex: 9, imageWidth: 1536, imageHeight: 1872),
            CGRect(x: 192, y: 0, width: 192, height: 208)
        )
        // frameIndex=11 取模为 3，x=576
        XCTAssertEqual(
            layout.frameRect(for: .idle, frameIndex: 11, imageWidth: 1536, imageHeight: 1872),
            CGRect(x: 576, y: 0, width: 192, height: 208)
        )
    }

    // 6. 非整数倍图片降级（如 1537 宽度，frameCountPerRow 仍为 8）
    func testNonMultipleImageWidthDegradesSafely() {
        let layout = MascotFrameLayout.defaultLayout
        // 1537 / 192 = 8（整数除法），安全降级
        XCTAssertEqual(layout.frameCountPerRow(imageWidth: 1537), 8)
        // frameIndex=8 仍能取模回 0
        XCTAssertEqual(
            layout.frameRect(for: .idle, frameIndex: 8, imageWidth: 1537, imageHeight: 1872),
            CGRect(x: 0, y: 0, width: 192, height: 208)
        )
    }

    // 额外：frameRect 转换为 CGImage 坐标系后正确翻转
    func testFrameRectMapsToCGImageCoordinates() {
        let layout = MascotFrameLayout.defaultLayout
        let rect = layout.frameRect(for: .idle, frameIndex: 0, imageWidth: 1536, imageHeight: 1872)
        XCTAssertEqual(rect.origin.x, 0)
        XCTAssertEqual(rect.origin.y, 0)
        XCTAssertEqual(rect.width, 192)
        XCTAssertEqual(rect.height, 208)

        // CGImage 坐标系原点在左下，第 0 行翻转后应位于 imageHeight - frameHeight
        let cgY = CGFloat(1872) - rect.origin.y - rect.height
        XCTAssertEqual(cgY, 1664)
    }

    // 额外：fittingSize 按单帧宽高比适配正方形包围盒
    func testFittingSizePreservesAspectRatioWithinSquare() {
        let layout = MascotFrameLayout.defaultLayout
        let size = layout.fittingSize(for: 40)

        XCTAssertEqual(size.height, 40, accuracy: 0.001)
        XCTAssertEqual(size.width, 40 * 192 / 208, accuracy: 0.001)
    }

    func testFittingSizeReturnsSquareForSquareFrame() {
        let layout = MascotFrameLayout(
            frameWidth: 64,
            frameHeight: 64,
            fps: 8,
            rowForIdle: 0,
            rowForRunRight: 1,
            rowForRunLeft: 2,
            rowForWaving: 3,
            rowForJumping: 4,
            rowForFailed: 5,
            rowForWaiting: 6,
            rowForRunning: 7,
            rowForReview: 8,
            rowForDragging: 8,
            framesPerRow: [:]
        )
        let size = layout.fittingSize(for: 40)

        XCTAssertEqual(size.width, 40, accuracy: 0.001)
        XCTAssertEqual(size.height, 40, accuracy: 0.001)
    }

    func testFittingSizeReturnsSquareForZeroFrameDimensions() {
        let layout = MascotFrameLayout(
            frameWidth: 0,
            frameHeight: 0,
            fps: 8,
            rowForIdle: 0,
            rowForRunRight: 1,
            rowForRunLeft: 2,
            rowForWaving: 3,
            rowForJumping: 4,
            rowForFailed: 5,
            rowForWaiting: 6,
            rowForRunning: 7,
            rowForReview: 8,
            rowForDragging: 8,
            framesPerRow: [:]
        )
        let size = layout.fittingSize(for: 40)

        XCTAssertEqual(size.width, 40, accuracy: 0.001)
        XCTAssertEqual(size.height, 40, accuracy: 0.001)
    }

    // 额外：from(manifest:) 完整扩展字段（含自定义行映射与帧数）
    func testFromManifestUsesDeclaredAnimations() throws {
        let json = """
        {
            "id": "full",
            "displayName": "Full",
            "frameWidth": 192,
            "frameHeight": 208,
            "fps": 8,
            "animations": {
                "idle": {"row": 0, "frames": 8},
                "runRight": {"row": 1, "frames": 8},
                "runLeft": {"row": 2, "frames": 8},
                "waving": {"row": 3, "frames": 8},
                "jumping": {"row": 4, "frames": 8},
                "failed": {"row": 5, "frames": 8},
                "waiting": {"row": 6, "frames": 8},
                "running": {"row": 7, "frames": 8},
                "review": {"row": 8, "frames": 8}
            }
        }
        """
        let manifest = try JSONDecoder().decode(
            MascotThemeManifest.self,
            from: json.data(using: .utf8) ?? Data()
        )
        let layout = MascotFrameLayout.from(manifest: manifest)

        XCTAssertEqual(layout.fps, 8)
        XCTAssertEqual(layout.row(for: .idle), 0)
        XCTAssertEqual(layout.row(for: .runRight), 1)
        XCTAssertEqual(layout.row(for: .running), 7)
        XCTAssertEqual(layout.row(for: .review), 8)
        // frameRect 使用 imageWidth 计算的每行帧数，而非声明的 frames
        XCTAssertEqual(
            layout.frameRect(for: .running, frameIndex: 0, imageWidth: 1536, imageHeight: 1872),
            CGRect(x: 0, y: 1456, width: 192, height: 208)
        )
    }
}
