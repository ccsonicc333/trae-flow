import SwiftUI

/// 紧凑态音乐视图 —— 封面（正方形圆角 18pt）+ 截断标题
struct MusicCompactView: View {
    @ObservedObject private var provider = NowPlayingProvider.shared

    var body: some View {
        if let np = provider.nowPlaying, np.isPlaying || np.title != nil {
            HStack(spacing: 6) {
                artworkView(np)
                if let title = np.title {
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.trailing, 4)
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func artworkView(_ np: NowPlayingInfo) -> some View {
        if let artwork = np.artwork {
            Image(nsImage: artwork)
                .resizable()
                .scaledToFill()
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 18, height: 18)
        }
    }
}
