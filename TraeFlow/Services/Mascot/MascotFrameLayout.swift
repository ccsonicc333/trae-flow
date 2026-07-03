import Foundation
import CoreGraphics

/// 主题包 sprite sheet 帧布局
/// 默认约定：192×208 像素切帧，按 codex 9 状态顺序映射到第 0~8 行
struct MascotFrameLayout: Equatable, Sendable {
    /// 单帧像素宽度
    let frameWidth: Int
    /// 单帧像素高度
    let frameHeight: Int
    /// 单帧像素宽高比（width / height）
    var aspectRatio: CGFloat {
        guard frameHeight > 0 else { return 1 }
        return CGFloat(frameWidth) / CGFloat(frameHeight)
    }

    /// 按单帧宽高比，将帧适配进边长为 `boundingSize` 的正方形后的显示尺寸。
    /// 主题包不会被硬塞进正方形，调用方传入的 `size` 仍可沿用旧的“边长”语义。
    func fittingSize(for boundingSize: CGFloat) -> CGSize {
        guard frameWidth > 0, frameHeight > 0 else {
            return CGSize(width: boundingSize, height: boundingSize)
        }
        let scale = min(
            boundingSize / CGFloat(frameWidth),
            boundingSize / CGFloat(frameHeight)
        )
        return CGSize(
            width: CGFloat(frameWidth) * scale,
            height: CGFloat(frameHeight) * scale
        )
    }

    /// 动画播放帧率
    let fps: Int

    /// idle 状态对应的行号
    let rowForIdle: Int
    /// runRight 状态对应的行号
    let rowForRunRight: Int
    /// runLeft 状态对应的行号
    let rowForRunLeft: Int
    /// waving 状态对应的行号
    let rowForWaving: Int
    /// jumping 状态对应的行号
    let rowForJumping: Int
    /// failed 状态对应的行号
    let rowForFailed: Int
    /// waiting 状态对应的行号
    let rowForWaiting: Int
    /// running 状态对应的行号
    let rowForRunning: Int
    /// review 状态对应的行号
    let rowForReview: Int
    /// dragging 状态对应的行号
    let rowForDragging: Int

    /// 各状态声明的每行帧数（来自 manifest 扩展字段，仅作元数据；实际切帧以 `frameCountPerRow(imageWidth:)` 为准）
    let framesPerRow: [MascotStatus: Int]

    /// 默认单帧宽度（codex 标准）
    static let defaultFrameWidth = 192
    /// 默认单帧高度（codex 标准）
    static let defaultFrameHeight = 208
    /// 默认帧率
    static let defaultFPS = 8

    /// 解析单帧尺寸：manifest 显式声明优先；均未声明且 imageSize 有效时按 codex 8×9 网格推断。
    private static func resolvedFrameSize(
        manifest: MascotThemeManifest,
        imageSize: CGSize?
    ) -> (frameWidth: Int, frameHeight: Int) {
        let declaredWidth = manifest.frameWidth
        let declaredHeight = manifest.frameHeight

        if let declaredWidth, let declaredHeight {
            return (declaredWidth, declaredHeight)
        }

        if declaredWidth == nil && declaredHeight == nil,
           let imageSize = imageSize,
           imageSize.width > 0, imageSize.height > 0 {
            let inferredWidth = Int(imageSize.width) / 8
            let inferredHeight = Int(imageSize.height) / 9
            if inferredWidth > 0 && inferredHeight > 0 {
                return (inferredWidth, inferredHeight)
            }
        }

        return (
            declaredWidth ?? defaultLayout.frameWidth,
            declaredHeight ?? defaultLayout.frameHeight
        )
    }

    /// 默认布局：192×208，fps=8，codex 9 状态顺序，每行 8 帧
    static let defaultLayout: MascotFrameLayout = {
        let framesPerStatus: [MascotStatus: Int] = [
            .idle: 8,
            .runRight: 8,
            .runLeft: 8,
            .waving: 8,
            .jumping: 8,
            .failed: 8,
            .waiting: 8,
            .running: 8,
            .review: 8,
            .dragging: 8
        ]
        return MascotFrameLayout(
            frameWidth: defaultFrameWidth,
            frameHeight: defaultFrameHeight,
            fps: defaultFPS,
            rowForIdle: 0,
            rowForRunRight: 1,
            rowForRunLeft: 2,
            rowForWaving: 5,
            rowForJumping: 4,
            rowForFailed: 3,
            rowForWaiting: 6,
            rowForRunning: 7,
            rowForReview: 8,
            rowForDragging: 8,
            framesPerRow: framesPerStatus
        )
    }()

    /// 从 manifest 构建：若 manifest 声明了扩展字段则用之，否则回退到默认布局。
    /// 当 `imageSize` 提供且 manifest 未声明单帧尺寸时，按 codex 标准 8 列 × 9 行从实际图像推断。
    static func from(manifest: MascotThemeManifest, imageSize: CGSize? = nil) -> MascotFrameLayout {
        let (frameWidth, frameHeight) = Self.resolvedFrameSize(
            manifest: manifest,
            imageSize: imageSize
        )
        let fps = manifest.fps ?? defaultLayout.fps

        let animations = manifest.animations
        let rowForIdle = animations?.idle?.row ?? defaultLayout.rowForIdle
        let rowForRunRight = animations?.runRight?.row ?? defaultLayout.rowForRunRight
        let rowForRunLeft = animations?.runLeft?.row ?? defaultLayout.rowForRunLeft
        let rowForWaving = animations?.waving?.row ?? defaultLayout.rowForWaving
        let rowForJumping = animations?.jumping?.row ?? defaultLayout.rowForJumping
        let rowForFailed = animations?.failed?.row ?? defaultLayout.rowForFailed
        let rowForWaiting = animations?.waiting?.row ?? defaultLayout.rowForWaiting
        let rowForRunning = animations?.running?.row ?? defaultLayout.rowForRunning
        let rowForReview = animations?.review?.row ?? defaultLayout.rowForReview
        let rowForDragging = animations?.dragging?.row ?? defaultLayout.rowForDragging

        // 只收录 manifest 显式声明的状态帧数；未声明的状态不放入字典，
        // 调用方（frameRect / frames(for:status:)）会回退到 imageWidth/frameWidth 几何计算，
        // 避免硬编码 8 与实际 sprite sheet 列数不符导致越界/重复帧。
        var framesPerStatus: [MascotStatus: Int] = [:]
        if let f = animations?.idle?.frames { framesPerStatus[.idle] = f }
        if let f = animations?.runRight?.frames { framesPerStatus[.runRight] = f }
        if let f = animations?.runLeft?.frames { framesPerStatus[.runLeft] = f }
        if let f = animations?.waving?.frames { framesPerStatus[.waving] = f }
        if let f = animations?.jumping?.frames { framesPerStatus[.jumping] = f }
        if let f = animations?.failed?.frames { framesPerStatus[.failed] = f }
        if let f = animations?.waiting?.frames { framesPerStatus[.waiting] = f }
        if let f = animations?.running?.frames { framesPerStatus[.running] = f }
        if let f = animations?.review?.frames { framesPerStatus[.review] = f }
        if let f = animations?.dragging?.frames { framesPerStatus[.dragging] = f }

        return MascotFrameLayout(
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            fps: fps,
            rowForIdle: rowForIdle,
            rowForRunRight: rowForRunRight,
            rowForRunLeft: rowForRunLeft,
            rowForWaving: rowForWaving,
            rowForJumping: rowForJumping,
            rowForFailed: rowForFailed,
            rowForWaiting: rowForWaiting,
            rowForRunning: rowForRunning,
            rowForReview: rowForReview,
            rowForDragging: rowForDragging,
            framesPerRow: framesPerStatus
        )
    }

    /// 根据图片实际像素宽度计算每行帧数（安全降级 floor）
    func frameCountPerRow(imageWidth: Int) -> Int {
        guard frameWidth > 0 else { return 1 }
        return max(1, imageWidth / frameWidth)
    }

    /// 状态对应的行号
    func row(for status: MascotStatus) -> Int {
        switch status {
        case .idle: return rowForIdle
        case .runRight: return rowForRunRight
        case .runLeft: return rowForRunLeft
        case .waving: return rowForWaving
        case .jumping: return rowForJumping
        case .failed: return rowForFailed
        case .waiting: return rowForWaiting
        case .running: return rowForRunning
        case .review: return rowForReview
        case .dragging: return rowForDragging
        }
    }

    /// 根据状态与帧索引计算 sprite sheet 中的源矩形（像素坐标）
    /// - Parameters:
    ///   - status: 动画状态
    ///   - frameIndex: 帧索引（越界时按每行帧数取模）
    ///   - imageWidth: sprite sheet 实际像素宽度
    ///   - imageHeight: sprite sheet 实际像素高度（保留用于后续高度方向裁剪）
    /// - Returns: 源矩形像素坐标
    func frameRect(for status: MascotStatus, frameIndex: Int, imageWidth: Int, imageHeight: Int) -> CGRect {
        // 优先用 manifest 声明的帧数取模；未声明时用几何计算的每行帧数
        let geometricPerRow = frameCountPerRow(imageWidth: imageWidth)
        let declaredFrames = framesPerRow[status] ?? geometricPerRow
        let perRow = max(1, declaredFrames)
        let safeFrame = ((frameIndex % perRow) + perRow) % perRow
        var row = self.row(for: status)
        // 行越界时回退到 idle 行（row 0），避免裁剪到透明区域导致宠物闪烁/消失
        if frameHeight > 0 && row * frameHeight >= imageHeight {
            row = 0
        }
        return CGRect(
            x: safeFrame * frameWidth,
            y: row * frameHeight,
            width: frameWidth,
            height: frameHeight
        )
    }
}
