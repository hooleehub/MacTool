import SwiftUI

struct ToolsView: View {
    @Environment(ToolService.self) private var tools
    @State private var confirmEmptyTrash = false

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
                        actionRow("切换深色模式", systemImage: "moon.circle") {
                            tools.toggleDarkMode()
                        }
                        Divider()
                        actionRow(tools.hiddenFiles ? "隐藏 Finder 隐藏文件" : "显示 Finder 隐藏文件",
                                  systemImage: tools.hiddenFiles ? "eye.slash" : "eye") {
                            tools.toggleHiddenFiles()
                        }
                        Divider()
                        actionRow(tools.desktopIcons ? "隐藏桌面图标" : "显示桌面图标",
                                  systemImage: tools.desktopIcons ? "menubar.dock.rectangle" : "macwindow.on.rectangle") {
                            tools.toggleDesktopIcons()
                        }
                        Divider()
                        actionRow(tools.ejecting ? "正在推出…" : "推出所有外置磁盘", systemImage: "eject") {
                            tools.ejectAll()
                        }
                        .disabled(tools.ejecting)
                        Divider()
                        HStack(spacing: 12) {
                            Label("重启", systemImage: "arrow.clockwise")
                            Spacer()
                            Button("程序坞") { tools.restartDock() }
                            Button("访达") { tools.restartFinder() }
                        }
                        .font(.callout)
                        .buttonStyle(.borderless)
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

                caffeinateCard

                ClipboardSection()
            }
            .padding(10)
        }
    }

    private var caffeinateCard: some View {
        @Bindable var tools = tools
        return GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if tools.caffeinating {
                        if let until = tools.caffeinateUntil {
                            Text("将在 \(until, style: .time) 结束(剩余 \(until, style: .timer))")
                        } else {
                            Text("已开启,直到手动关闭")
                        }
                    } else {
                        Text("阻止 Mac 自动进入睡眠")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if tools.caffeinating {
                        Button("关闭") { tools.stopCaffeinate() }
                    } else {
                        Menu("开启") {
                            ForEach(CaffeinateDuration.allCases) { duration in
                                Button(duration.title) { tools.startCaffeinate(duration) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                .font(.callout)
                Toggle("保持屏幕常亮", isOn: $tools.keepDisplayOn)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                    .help("关闭后只阻止系统睡眠(下载、编译不中断),屏幕仍按设置熄灭")
            }
        } label: {
            HStack {
                Label("防休眠", systemImage: tools.caffeinating ? "cup.and.saucer.fill" : "cup.and.saucer")
                if tools.caffeinating {
                    Circle().fill(.green).frame(width: 6, height: 6)
                }
            }
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
