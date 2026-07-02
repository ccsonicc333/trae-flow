import SwiftUI

/// 展开态音乐视图 —— 大封面 + 标题/艺术家/专辑 + 进度条 + 控制按钮
/// 背景根据专辑封面提取主色调，渲染为模糊渐变色，对齐设计稿风格。
struct MusicExpandedView: View {
    @ObservedObject private var provider = NowPlayingProvider.shared
    @State private var backgroundColors: [Color] = [
        Color(nsColor: .systemIndigo),
        Color(nsColor: .systemPurple)
    ]

    var body: some View {
        if let np = provider.nowPlaying, np.isPlaying || np.title != nil {
            playingContent(np)
                .onAppear { updateBackgroundColors(from: np.artwork) }
                .onChange(of: np.artwork) { _, newImage in
                    updateBackgroundColors(from: newImage)
                }
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private func playingContent(_ np: NowPlayingInfo) -> some View {
        VStack(spacing: 12) {
            artworkView(np)
                .frame(maxWidth: .infinity, alignment: .center)

            VStack(spacing: 2) {
                Text(np.title ?? "未知曲目")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text([np.artist, np.album].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            progressView(np)

            controlButtons(np)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dynamicBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// 根据专辑封面提取的动态模糊渐变背景。
    private var dynamicBackground: some View {
        ZStack {
            // 底层深色，保证文字可读性
            Color.black.opacity(0.25)

            // 根据主色调生成大面积模糊光斑
            GeometryReader { geo in
                ZStack {
                    ForEach(backgroundColors.indices, id: \.self) { index in
                        Circle()
                            .fill(backgroundColors[index])
                            .frame(
                                width: geo.size.width * 0.9,
                                height: geo.size.width * 0.9
                            )
                            .blur(radius: geo.size.width * 0.35)
                            .offset(
                                x: index == 0 ? -geo.size.width * 0.25 : geo.size.width * 0.25,
                                y: index == 0 ? -geo.size.height * 0.25 : geo.size.height * 0.3
                            )
                            .opacity(0.75)
                    }
                }
            }

            // 上层毛玻璃材质，进一步柔化并统一色调
            Color.clear
                .background(.regularMaterial)
                .opacity(0.45)
        }
    }

    @ViewBuilder
    private func artworkView(_ np: NowPlayingInfo) -> some View {
        if let artwork = np.artwork {
            Image(nsImage: artwork)
                .resizable()
                .scaledToFill()
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 6)
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
                .frame(width: 140, height: 140)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private func progressView(_ np: NowPlayingInfo) -> some View {
        VStack(spacing: 4) {
            clickableProgressBar(np)
            HStack {
                Text(formatTime(np.elapsed))
                Spacer()
                Text(formatTime(np.duration))
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(.white.opacity(0.6))
        }
    }

    /// 可点击的进度条：点击/轻触位置即跳转到对应比例时间。
    @ViewBuilder
    private func clickableProgressBar(_ np: NowPlayingInfo) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                Capsule()
                    .fill(Color.white)
                    .frame(width: np.duration > 0 ? geo.size.width * CGFloat(np.elapsed / np.duration) : 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let ratio = max(0, min(1, location.x / geo.size.width))
                provider.seek(to: ratio * np.duration)
            }
        }
        .frame(height: 4)
    }

    @ViewBuilder
    private func controlButtons(_ np: NowPlayingInfo) -> some View {
        HStack(spacing: 28) {
            Button(action: provider.skipToPrevious) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)

            Button(action: provider.togglePlayPause) {
                Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)

            Button(action: provider.skipToNext) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("未在播放")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func updateBackgroundColors(from image: NSImage?) {
        guard let image else {
            backgroundColors = [
                Color(nsColor: .systemIndigo),
                Color(nsColor: .systemPurple)
            ]
            return
        }
        backgroundColors = ImageColorExtractor.dominantColors(from: image, count: 3)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}
