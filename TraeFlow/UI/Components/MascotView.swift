import SwiftUI
import Foundation
import AppKit
import ImageIO

private struct MascotAnimationsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

/// 显式忽略 `EnergyGovernor` 的静态帧节能策略。
///
/// 默认为 `false`：运行时 UI（如 Notch 宠物）会在 `quietBackground` 模式下冻结动画以节能。
/// 设置为 `true` 时，`MascotView` 即使在静态帧策略下也走逐帧动画，
/// 供设置页展开状态预览等"用户主动查看动画"的场景使用。
private struct MascotAnimationsIgnoreEnergyPolicyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var mascotAnimationsEnabled: Bool {
        get { self[MascotAnimationsEnabledKey.self] }
        set { self[MascotAnimationsEnabledKey.self] = newValue }
    }

    var mascotAnimationsIgnoreEnergyPolicy: Bool {
        get { self[MascotAnimationsIgnoreEnergyPolicyKey.self] }
        set { self[MascotAnimationsIgnoreEnergyPolicyKey.self] = newValue }
    }
}

enum MascotClient: String, CaseIterable, Identifiable, Sendable {
    case claude
    case trae

    static let allCases: [MascotClient] = [
        .claude,
        .trae,
    ]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude:
            return "TRAE"
        case .trae:
            return "Trae"
        }
    }

    var subtitle: String {
        switch self {
        case .claude:
            return "TRAE Hooks 与默认 TRAE 会话"
        case .trae:
            return "Trae IDE 中的 TRAE 会话"
        }
    }

    nonisolated var defaultMascotKind: MascotKind {
        switch self {
        case .claude:
            return .claude
        case .trae:
            return .claude
        }
    }

    nonisolated init(provider: SessionProvider) {
        switch provider {
        case .trae:
            self = .claude
        }
    }

    nonisolated init(clientInfo: SessionClientInfo, provider: SessionProvider) {
        if let profileID = clientInfo.resolvedProfile(for: provider)?.id {
            let resolvedClient: MascotClient? = switch profileID {
            case "trae":
                .trae
            default:
                nil
            }

            if let resolvedClient {
                self = resolvedClient
                return
            }
        }

        switch clientInfo.brand {
        case .trae:
            self = .claude
        case .neutral:
            switch provider {
            case .trae:
                self = .claude
            }
        default:
            switch provider {
            case .trae:
                self = .claude
            }
        }
    }
}

/// 宠物主题包 ID 载体（替代旧的硬编码枚举）
///
/// 所有主题包统一走 sprite sheet 切帧路径（由 `MascotThemeScanner` 提供清单）。
/// 默认回退主题包 ID 为 `BuiltInMascotThemes.defaultThemeID`（traeflow / TRAE FLOW）。
struct MascotKind: Hashable, Identifiable, Sendable {
    /// 主题包 ID（与 `MascotTheme.manifest.id` 对应）
    let themeID: String

    var id: String { themeID }

    /// 兼容旧代码的 rawValue 访问
    var rawValue: String { themeID }

    /// 内置回退主题包 ID（traeflow / TRAE FLOW）
    nonisolated static let claude = MascotKind(themeID: BuiltInMascotThemes.defaultThemeID)

    /// 用户可选择的全部主题包 ID 列表（静态回退，仅包含内置默认）
    /// 动态列表由 Settings UI 直接从 `MascotThemeScanner` 获取（扫描器是 @MainActor，
    /// 这里同步访问不可靠，故只返回静态回退）
    nonisolated static var allCases: [MascotKind] {
        [.claude]
    }

    var title: String { themeID }
    var subtitle: String { "" }
    var alertColor: Color { Color.orange }

    /// 兼容旧代码的 `MascotKind(rawValue:)` 调用
    init?(rawValue: String) {
        self.themeID = rawValue
    }

    nonisolated init(client: MascotClient) {
        self = .claude
    }

    nonisolated init(provider: SessionProvider) {
        self = MascotKind(client: MascotClient(provider: provider))
    }

    nonisolated init(clientInfo: SessionClientInfo, provider: SessionProvider) {
        self = MascotKind(client: MascotClient(clientInfo: clientInfo, provider: provider))
    }

    init(themeID: String) {
        self.themeID = themeID
    }
}

extension SessionState {
    nonisolated var mascotClient: MascotClient {
        MascotClient(clientInfo: clientInfo, provider: provider)
    }

    nonisolated var defaultMascotKind: MascotKind {
        MascotKind(client: mascotClient)
    }
}

struct MascotView: View {
    @Environment(\.mascotAnimationsEnabled) private var mascotAnimationsEnabled
    @Environment(\.mascotAnimationsIgnoreEnergyPolicy) private var mascotAnimationsIgnoreEnergyPolicy
    @ObservedObject private var energyGovernor = EnergyGovernor.shared
    @ObservedObject private var settings = AppSettingsStore.shared
    @ObservedObject private var themeScanner = MascotThemeScanner.shared

    let kind: MascotKind
    let status: MascotStatus
    var size: CGFloat = 40
    var animationTime: TimeInterval?
    var isDragging: Bool = false

    init(
        kind: MascotKind,
        status: MascotStatus,
        size: CGFloat = 40,
        animationTime: TimeInterval? = nil,
        isDragging: Bool = false
    ) {
        self.kind = kind
        self.status = status
        self.size = size
        self.animationTime = animationTime
        self.isDragging = isDragging
    }

    init(
        provider: SessionProvider,
        status: MascotStatus,
        size: CGFloat = 40,
        animationTime: TimeInterval? = nil,
        isDragging: Bool = false
    ) {
        self.init(
            kind: MascotKind(provider: provider),
            status: status,
            size: size,
            animationTime: animationTime,
            isDragging: isDragging
        )
    }

    var body: some View {
        let renderTime = effectiveAnimationTime
        let isIdleProtectionActive = settings.idleAutoRoutePromptsToTerminalActive
        let displaySize = themePackDisplaySize ?? CGSize(width: size, height: size)

        ZStack {
            canvasScene(interval: adaptiveInterval(for: status), status: status, staticTime: renderTime)

            if isIdleProtectionActive {
                IdleProtectionMascotOverlay(size: size, time: renderTime)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .clipped()
        .accessibilityLabel(accessibilityLabel(isIdleProtectionActive: isIdleProtectionActive))
    }

    private func accessibilityLabel(isIdleProtectionActive: Bool) -> String {
        guard isIdleProtectionActive else {
            return AppLocalization.format("%@ %@", kind.title, status.displayName)
        }
        return AppLocalization.format("%@ %@ 空闲保护中", kind.title, status.displayName)
    }

    /// 静态渲染时间：非 nil 时表示当前应渲染单帧（不驱动 TimelineView）。
    /// - 显式传入 `animationTime`（如设置页缩略图传 0）
    /// - `mascotAnimationsEnabled == false`（如设置页缩略图、非悬停预览）
    /// - 能耗策略要求静态帧（除非 `mascotAnimationsIgnoreEnergyPolicy` 显式覆盖）
    /// 以上任一成立时返回具体值，否则返回 nil（走逐帧动画）。
    private var effectiveAnimationTime: TimeInterval? {
        if let animationTime {
            return animationTime
        }
        guard mascotAnimationsEnabled else { return 0 }
        // 设置页展开状态预览等场景显式要求动画，忽略 EnergyGovernor 的静态帧降级
        if mascotAnimationsIgnoreEnergyPolicy { return nil }
        return energyGovernor.policy.animationLevel == .staticFrames ? 0 : nil
    }

    /// 主题包按单帧真实宽高比计算后的显示尺寸
    private var themePackDisplaySize: CGSize? {
        guard let theme = themeScanner.theme(forID: kind.themeID) else { return nil }
        let cgImage = MascotSpriteCache.shared.cgImage(for: theme)
        let imageSize: CGSize? = cgImage.map { CGSize(width: $0.width, height: $0.height) }
        let layout = MascotFrameLayout.from(manifest: theme.manifest, imageSize: imageSize)
        return layout.fittingSize(for: size)
    }

    @ViewBuilder
    private func canvasScene(interval: TimeInterval, status: MascotStatus, staticTime: TimeInterval?) -> some View {
        themePackCanvasScene(interval: interval, status: status, staticTime: staticTime)
    }

    // MARK: - Theme Pack Sprite Sheet Rendering

    /// 主题包 sprite sheet 渲染入口：`staticTime` 非 nil 时渲染单帧（不创建 TimelineView），
    /// 否则走逐帧动画。设置页缩略图等静态场景借此避免大量 TimelineView 持续 tick 导致卡顿。
    @ViewBuilder
    private func themePackCanvasScene(interval: TimeInterval, status: MascotStatus, staticTime: TimeInterval?) -> some View {
        if let theme = themeScanner.theme(forID: kind.themeID) {
            if let staticTime {
                themePackStaticFrame(theme: theme, status: status, time: staticTime)
            } else {
                themePackAnimatedFrame(theme: theme, interval: interval, status: status)
            }
        } else {
            EmptyView()
        }
    }

    /// 静态单帧渲染：不创建 TimelineView，直接按 `time` 选取一帧。
    /// 供设置页缩略图、非悬停预览等不需要动画的场景使用。
    @ViewBuilder
    private func themePackStaticFrame(theme: MascotTheme, status: MascotStatus, time: TimeInterval) -> some View {
        let frames = MascotSpriteCache.shared.frames(for: theme, status: status)
        let layout = MascotFrameLayout.from(
            manifest: theme.manifest,
            imageSize: frames.first.map { CGSize(width: $0.width, height: $0.height) }
        )
        let safeFrames = frames.isEmpty ? (MascotSpriteCache.shared.cgImage(for: theme).map { [$0] } ?? []) : frames
        themePackFrameImage(frames: safeFrames, fps: layout.fps, time: time)
    }

    /// 主题包逐帧动画：用预裁剪的帧数组驱动 TimelineView，只做 Image 切换不再每帧裁剪。
    /// 帧数按主题包该状态实际声明/推断的帧数，不同状态可不同。
    private func themePackAnimatedFrame(theme: MascotTheme, interval: TimeInterval, status: MascotStatus) -> some View {
        let frames = MascotSpriteCache.shared.frames(for: theme, status: status)
        let layout = MascotFrameLayout.from(
            manifest: theme.manifest,
            imageSize: frames.first.map { CGSize(width: $0.width, height: $0.height) }
        )
        let fps = layout.fps
        let safeFrames = frames.isEmpty ? (MascotSpriteCache.shared.cgImage(for: theme).map { [$0] } ?? []) : frames

        return TimelineView(.periodic(from: .now, by: interval)) { context in
            themePackFrameImage(frames: safeFrames, fps: fps, time: context.date.timeIntervalSinceReferenceDate)
        }
    }

    /// 渲染预裁剪帧数组中的某一帧
    @ViewBuilder
    private func themePackFrameImage(frames: [CGImage], fps: Int, time: TimeInterval) -> some View {
        if frames.isEmpty {
            EmptyView()
        } else {
            let idx = fps > 0 ? Int(time * TimeInterval(fps)) : 0
            let frameIndex = ((idx % frames.count) + frames.count) % frames.count
            Image(decorative: frames[frameIndex], scale: 1.0, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }

    /// Adaptive refresh rate based on animation complexity.
    /// Visible pets need enough cadence for the time-based motion to read as animation.
    private func adaptiveInterval(for status: MascotStatus) -> TimeInterval {
        let baseInterval: TimeInterval
        switch status {
        case .idle, .jumping, .waving:
            baseInterval = 1.0 / 12.0
        case .running, .runRight, .runLeft, .waiting, .review, .failed:
            baseInterval = 1.0 / 24.0
        case .dragging:
            baseInterval = 1.0 / 30.0
        }

        switch energyGovernor.policy.animationLevel {
        case .full:
            return baseInterval
        case .reduced:
            return baseInterval * 1.6
        case .staticFrames:
            return baseInterval
        }
    }

}

private struct IdleProtectionMascotOverlay: View {
    let size: CGFloat
    var time: TimeInterval?

    var body: some View {
        overlayBody(time: time ?? 0)
    }

    private func overlayBody(time: TimeInterval) -> some View {
        let tint = Color(red: 0.24, green: 0.88, blue: 0.48)

        return ZStack(alignment: .bottomTrailing) {
            if size >= 16 {
                IdleProtectionBadge(size: min(14, max(7, size * 0.24)), tint: tint)
                    .offset(x: -size * 0.02, y: -size * 0.02)
                    .shadow(color: tint.opacity(0.34), radius: size * 0.08)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size, alignment: .bottomTrailing)
        .allowsHitTesting(false)
    }
}

private struct IdleProtectionBadge: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        Image(systemName: "shield.fill")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(tint)
        .frame(width: size, height: size)
    }
}

/// Sprite sheet 解码缓存（按 themeID + 文件路径）
/// 避免每帧重绘都重复解码 webp/png
@MainActor
final class MascotSpriteCache {
    static let shared = MascotSpriteCache()

    /// 缓存键：`themeID:spritesheetPath`，路径变化时自动失效
    private var cache: [String: CGImage] = [:]
    /// 预裁剪帧缓存：`themeID:status` → 该状态所有帧的 CGImage 数组
    private var framesCache: [String: [CGImage]] = [:]

    func cgImage(for theme: MascotTheme) -> CGImage? {
        let key = theme.id + ":" + theme.spritesheetURL.path
        if let cached = cache[key] { return cached }

        let cgImage = decodeSpriteSheet(at: theme.spritesheetURL)
        if let cgImage {
            cache[key] = cgImage
        }
        return cgImage
    }

    /// 获取指定主题包指定状态的所有预裁剪帧。
    /// 首次调用时按 layout 裁剪并缓存，后续直接返回缓存数组。
    /// 裁剪失败的帧会被跳过；若全部失败则回退到完整 sprite sheet 单帧。
    /// 仅尾部透明帧（sprite sheet 末行不足 8 帧时的空白格）会被剔除，避免动画循环到空白帧导致宠物消失；
    /// 不再对每一帧做像素采样，把首次裁剪从 O(N) 次 CGContext 渲染降到 ~O(1) 次，显著降低展开预览的主线程卡顿。
    func frames(for theme: MascotTheme, status: MascotStatus) -> [CGImage] {
        let key = theme.id + ":" + status.rawValue
        if let cached = framesCache[key] { return cached }

        guard let sheet = cgImage(for: theme) else { return [] }
        let imageSize = CGSize(width: sheet.width, height: sheet.height)
        let layout = MascotFrameLayout.from(manifest: theme.manifest, imageSize: imageSize)
        let imageWidth = sheet.width
        let imageHeight = sheet.height
        let perRow = layout.frameCountPerRow(imageWidth: imageWidth)
        let declaredFrames = layout.framesPerRow[status] ?? perRow
        let frameCount = max(1, declaredFrames)

        var frames: [CGImage] = []
        frames.reserveCapacity(frameCount)
        for frameIndex in 0..<frameCount {
            let srcRect = layout.frameRect(
                for: status,
                frameIndex: frameIndex,
                imageWidth: imageWidth,
                imageHeight: imageHeight
            )
            let clampedX = max(0, min(srcRect.origin.x, CGFloat(imageWidth) - srcRect.width))
            let clampedY = max(0, min(srcRect.origin.y, CGFloat(imageHeight) - srcRect.height))
            let clampedRect = CGRect(
                x: clampedX,
                y: CGFloat(imageHeight) - clampedY - srcRect.height,
                width: min(srcRect.width, CGFloat(imageWidth) - clampedX),
                height: min(srcRect.height, CGFloat(imageHeight) - clampedY)
            )
            if let sub = sheet.cropping(to: clampedRect) {
                frames.append(sub)
            }
        }
        // 仅从尾部剔除连续透明帧（sprite sheet 末行空白格的常见场景）。
        // 中间帧假定有效，避免对每帧做 CGContext 像素采样。
        while frames.count > 1, !Self.hasVisibleContent(frames[frames.count - 1]) {
            frames.removeLast()
        }
        // 全部裁剪失败或均为透明时回退到完整 sprite sheet，保证至少有一帧可见
        if frames.isEmpty {
            frames = [sheet]
        }
        framesCache[key] = frames
        return frames
    }

    /// 检查 CGImage 是否有非透明像素（用于过滤 sprite sheet 末尾的空白帧）
    private static func hasVisibleContent(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return false }

        let bytesPerRow = width * 4
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true } // 无法检测时保守认为有内容
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 采样：步长按帧大小调整，大帧用步长 4，小帧用步长 2
        let step = max(1, min(width, height) / 32)
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let alpha = pixelData[(y * bytesPerRow) + (x * 4) + 3]
                if alpha > 10 { return true }
            }
        }
        return false
    }

    /// 多层试错解码 sprite sheet（兼容 png / webp 等格式）
    private func decodeSpriteSheet(at url: URL) -> CGImage? {
        // 1. 标准路径：CGImageSourceCreateWithURL
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return cgImage
        }

        // 2. 备选路径：预先读入 Data 再解码（兼容需要完整文件数据的格式）
        guard let data = try? Data(contentsOf: url) else { return nil }

        // 2a. CGImageSourceCreateWithData
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return cgImage
        }

        // 2b. NSBitmapImageRep 回退（支持更多旧格式）
        if let rep = NSBitmapImageRep(data: data),
           let cgImage = rep.cgImage {
            return cgImage
        }

        return nil
    }

    func clear() {
        cache.removeAll()
        framesCache.removeAll()
    }

    /// 主题包被删除/更新时调用，按 themeID 前缀失效相关缓存
    func invalidate(themeID: String) {
        cache = cache.filter { !$0.key.hasPrefix(themeID + ":") }
        framesCache = framesCache.filter { !$0.key.hasPrefix(themeID + ":") }
    }
}

#Preview("Mascot Grid") {
    VStack(spacing: 20) {
        ForEach(MascotStatus.allCases, id: \.self) { status in
            HStack(spacing: 14) {
                ForEach(MascotKind.allCases) { kind in
                    VStack(spacing: 8) {
                        MascotView(kind: kind, status: status, size: 32)
                        Text(kind.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    .padding()
    .background(Color.black)
}
