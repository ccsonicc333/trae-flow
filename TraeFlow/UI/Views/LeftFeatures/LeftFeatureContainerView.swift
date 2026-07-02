import SwiftUI

/// 展开态左半区功能容器 —— 顶部左上角切换栏 + 主内容区
///
/// 布局：切换栏（功能图标按钮行）固定在顶部左上角，主内容区填充剩余空间。
/// `VStack(alignment: .leading)` 确保切换栏左对齐；主内容区用 `.frame(maxWidth: .infinity)`
/// 占满宽度。
struct LeftFeatureContainerView: View {
    @ObservedObject private var featureStore = LeftFeatureStore.shared
    @ObservedObject private var customAreaStore = CustomAreaStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 切换栏已移至展开态 header 行左侧，与右侧按钮同一水平线
            mainContentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var mainContentArea: some View {
        if let active = featureStore.expandedActiveFeature {
            mainContent(for: active)
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private func mainContent(for feature: LeftFeature) -> some View {
        switch feature.kind {
        case .music:
            MusicExpandedView()
        case .shelf:
            ShelfExpandedView()
        case .customArea(let areaID):
            if let area = customAreaStore.areas.first(where: { $0.id == areaID }) {
                CustomAreaWebView(source: .localArea(area))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                // 目录已被删除但功能残留 —— 显示空状态
                customAreaMissingState
            }
        case .webURL(let urlString):
            // Spec: 远程 URL 功能 —— 构造 .remoteURL 源传入 CustomAreaWebView
            if let url = URL(string: urlString) {
                CustomAreaWebView(source: .remoteURL(url))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                // URL 无效 —— 显示空状态
                webURLInvalidState
            }
        case .newsnow(let baseURL):
            // Spec: 内置 NewsNow 功能 —— 构造 .remoteURL 源传入 CustomAreaWebView，与 .webURL 一致
            if let url = URL(string: baseURL) {
                CustomAreaWebView(source: .remoteURL(url))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                webURLInvalidState
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("未启用任何功能")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            Text("在「设置 > 左侧内容」中启用功能")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var customAreaMissingState: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundColor(.orange)
            Text("自定义 HTML 目录不可用")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Spec: `.webURL` 功能 URL 无效时的空状态
    private var webURLInvalidState: some View {
        VStack(spacing: 8) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 24))
                .foregroundColor(.orange)
            Text("网站 URL 无效")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
