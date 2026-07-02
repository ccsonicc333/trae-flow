import SwiftUI
import UniformTypeIdentifiers

/// 展开态中转站视图 —— 拖入文件提示区 + 文件网格 + AirDrop 按钮
struct ShelfExpandedView: View {
    @ObservedObject private var store = ShelfStore.shared
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 10) {
            dropHint
            gridContent
            airDropButton
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    // MARK: - Drop Hint

    private var dropHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 11))
            Text(store.items.isEmpty ? "拖入文件到此处中转" : "继续拖入文件添加")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(isDropTargeted ? .accentColor : .secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                              style: StrokeStyle(lineWidth: 1, dash: [4]))
        )
    }

    // MARK: - Grid

    @ViewBuilder
    private var gridContent: some View {
        if store.items.isEmpty {
            Spacer()
        } else {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(store.items) { item in
                        shelfItemCell(item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func shelfItemCell(_ item: ShelfItem) -> some View {
        VStack(spacing: 4) {
            if let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
            }
            Text(item.name)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .onDrag {
            NSItemProvider(object: item.fileURL as NSURL)
        }
        .contextMenu {
            Button("移除") { store.remove(id: item.id) }
        }
    }

    // MARK: - AirDrop Button

    private var airDropButton: some View {
        Button(action: store.airDropAll) {
            Label("通过 AirDrop 分享全部", systemImage: "share.play")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.bordered)
        .disabled(store.items.isEmpty)
    }

    // MARK: - Drop Handling

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    store.add(url: url)
                }
            }
        }
    }
}
