import SwiftUI

/// 紧凑态中转站视图 —— tray.full 图标 + 数量徽章
struct ShelfCompactView: View {
    @ObservedObject private var store = ShelfStore.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "tray.full")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            if store.items.count > 0 {
                Text("\(store.items.count)")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.accentColor, in: Capsule())
                    .offset(x: 8, y: -6)
            }
        }
        .frame(width: 24, height: 24)
    }
}
