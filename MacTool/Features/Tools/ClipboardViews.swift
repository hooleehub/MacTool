import SwiftUI

/// 剪贴板一行:图标/缩略图 + 内容 + 时间;工具页与快捷键弹窗共用
struct ClipboardRow: View {
    @Environment(ClipboardStore.self) private var clipboard
    let item: ClipboardStore.Item
    var highlighted = false
    var shortcutIndex: Int?
    var justCopied = false

    var body: some View {
        HStack(spacing: 8) {
            leading
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .lineLimit(2)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    if item.pinned {
                        Image(systemName: "pin.fill")
                            .foregroundStyle(.orange)
                    }
                    Text(item.time, style: .time)
                }
                .font(.caption2)
                .foregroundStyle(highlighted ? .white.opacity(0.8) : Color.secondary.opacity(0.8))
            }
            Spacer(minLength: 0)
            if let shortcutIndex {
                Text("⌘\(shortcutIndex + 1)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(highlighted ? .white.opacity(0.8) : Color.secondary.opacity(0.6))
            }
        }
        .font(.caption)
        .foregroundStyle(highlighted ? .white : .primary)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leading: some View {
        if justCopied {
            Image(systemName: "checkmark").foregroundStyle(.green)
        } else if let image = clipboard.thumbnail(for: item) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if case .files(let paths) = item.content, let first = paths.first {
            Image(nsImage: NSWorkspace.shared.icon(forFile: first))
                .resizable()
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: item.symbolName)
                .foregroundStyle(highlighted ? .white : .secondary)
        }
    }
}

/// 工具页里的剪贴板历史
struct ClipboardSection: View {
    @Environment(ClipboardStore.self) private var clipboard
    @AppStorage(ClipboardHotKey.storageKey) private var hotKey = ClipboardHotKey.defaultValue
    @State private var query = ""
    @State private var copiedItemID: UUID?

    var body: some View {
        GroupBox {
            VStack(spacing: 6) {
                if !clipboard.items.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.tertiary)
                        TextField("搜索", text: $query)
                            .textFieldStyle(.plain)
                    }
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
                let items = Array(clipboard.filtered(query).prefix(50))
                if items.isEmpty {
                    Text(emptyText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            Button {
                                clipboard.copyBack(item)
                                copiedItemID = item.id
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                    if copiedItemID == item.id { copiedItemID = nil }
                                }
                            } label: {
                                ClipboardRow(item: item, justCopied: copiedItemID == item.id)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(item.pinned ? "取消置顶" : "置顶") { clipboard.togglePin(item) }
                                if case .image(let png) = item.content, let image = clipboard.thumbnail(for: item) {
                                    Button("贴到屏幕") {
                                        MenuBarWindow.dismiss()
                                        PinController.shared.pin(image, png: png)
                                    }
                                }
                                Button("删除") { clipboard.remove(item) }
                            }
                            .help("点击复制,右键置顶或删除")
                            if item.id != items.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        } label: {
            HStack {
                Label("剪贴板历史", systemImage: "clipboard")
                if hotKey != .off {
                    Text(hotKey.title)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("按 \(hotKey.title) 随时呼出剪贴板历史")
                }
                Spacer()
                if clipboard.items.contains(where: { !$0.pinned }) {
                    Button("清空") { clipboard.clear() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("清空未置顶的记录")
                }
            }
        }
    }

    private var emptyText: String {
        if !query.isEmpty { return "没有匹配的记录" }
        return clipboard.persist
            ? "暂无记录。复制的文本、文件和图片会显示在这里。"
            : "暂无记录。复制的文本、文件和图片会显示在这里(仅保存在内存)。"
    }
}
