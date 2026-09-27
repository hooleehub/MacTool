import SwiftUI

struct ToolsView: View {
    @Environment(ToolService.self) private var tools
    @Environment(ClipboardStore.self) private var clipboard
    @State private var confirmEmptyTrash = false
    @State private var copiedItemID: UUID?

    var body: some View {
        @Bindable var tools = tools

        ScrollView {
            VStack(spacing: 10) {
                GroupBox {
                    VStack(spacing: 4) {
                        actionRow("锁屏", systemImage: "lock.display") {
                            tools.lockScreen()
                        }
                        Divider()
                        actionRow(tools.hiddenFiles ? "隐藏 Finder 隐藏文件" : "显示 Finder 隐藏文件",
                                  systemImage: tools.hiddenFiles ? "eye.slash" : "eye") {
                            tools.toggleHiddenFiles()
                        }
                        Divider()
                        actionRow("切换深色模式", systemImage: "moon.circle") {
                            tools.toggleDarkMode()
                        }
                        Divider()
                        HStack {
                            Label("防休眠 (caffeinate)", systemImage: "cup.and.saucer")
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { tools.caffeinating },
                                set: { _ in tools.toggleCaffeinate() }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                        Divider()
                        actionRow(tools.emptyingTrash ? "正在清倒废纸篓…" : "清空废纸篓", systemImage: "trash.slash", tint: .red) {
                            withAnimation { confirmEmptyTrash = true }
                        }
                        .disabled(tools.emptyingTrash)
                    }
                } label: {
                    Label("快捷操作", systemImage: "bolt")
                }

                if confirmEmptyTrash {
                    ConfirmBar(
                        message: "废纸篓中的所有文件将被永久删除,无法恢复。",
                        confirmTitle: "清空废纸篓",
                        onConfirm: {
                            withAnimation { confirmEmptyTrash = false }
                            tools.emptyTrash()
                        },
                        onCancel: { withAnimation { confirmEmptyTrash = false } }
                    )
                }

                if let message = tools.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                GroupBox {
                    if clipboard.items.isEmpty {
                        Text("暂无记录。复制文本后会显示在这里(仅保存在内存)。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(clipboard.items) { item in
                                Button {
                                    clipboard.copyBack(item)
                                    copiedItemID = item.id
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                        if copiedItemID == item.id { copiedItemID = nil }
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: copiedItemID == item.id ? "checkmark" : "doc.on.clipboard")
                                            .foregroundStyle(copiedItemID == item.id ? .green : .secondary)
                                            .frame(width: 14)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.text)
                                                .lineLimit(2)
                                                .truncationMode(.tail)
                                            Text(item.time, style: .time)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                        Spacer()
                                    }
                                    .font(.caption)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if item.id != clipboard.items.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Label("剪贴板历史", systemImage: "clipboard")
                        Spacer()
                        if !clipboard.items.isEmpty {
                            Button("清空") { clipboard.clear() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    private func actionRow(_ title: String, systemImage: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(tint)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.callout)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}
