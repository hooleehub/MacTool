import SwiftUI

struct UninstallerView: View {
    @Environment(AppUninstaller.self) private var uninstaller
    @State private var dropTargeted = false
    @State private var confirmUninstall = false

    var body: some View {
        @Bindable var uninstaller = uninstaller

        ScrollView {
            VStack(spacing: 10) {
                if let target = uninstaller.target {
                    targetCard(target)
                    if confirmUninstall {
                        ConfirmBar(
                            message: "\(target.name) 及所选残留(约 \(ByteFormatter.string(uninstaller.selectedBytes)))将移入废纸篓,可恢复。",
                            confirmTitle: "卸载",
                            onConfirm: {
                                withAnimation { confirmUninstall = false }
                                uninstaller.uninstall()
                            },
                            onCancel: { withAnimation { confirmUninstall = false } }
                        )
                    }
                } else {
                    dropZone
                }

                if let message = uninstaller.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
            .padding(10)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            uninstaller.load(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .onChange(of: uninstaller.target?.appURL) { confirmUninstall = false }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "app.dashed")
                .font(.system(size: 36))
                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
            Text("把应用拖到这里")
                .font(.callout)
            Text("会同时找出它在 ~/Library 中的缓存、偏好设置等残留文件")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("从应用程序中选择…") { uninstaller.chooseApp() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
        )
    }

    private func targetCard(_ target: UninstallTarget) -> some View {
        @Bindable var uninstaller = uninstaller

        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: target.appURL.path))
                        .resizable()
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.name).font(.headline)
                        Text(target.bundleID ?? "未知 Bundle ID")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(target.appSize.map(ByteFormatter.string) ?? "…")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Divider()

                if uninstaller.scanning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在查找残留文件…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if target.leftovers.isEmpty {
                    Text("未发现残留文件")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("残留文件(\(target.leftovers.count))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(Binding(
                        get: { uninstaller.target?.leftovers ?? [] },
                        set: { uninstaller.target?.leftovers = $0 }
                    )) { $item in
                        HStack {
                            Toggle(isOn: $item.selected) {
                                Text(shortenPath(item.path))
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            .toggleStyle(.checkbox)
                            Spacer()
                            Text(item.isProtected ? "受系统保护" : item.size.map(ByteFormatter.string) ?? "--")
                                .monospacedDigit()
                                .foregroundStyle(item.isProtected ? .tertiary : .secondary)
                        }
                        .font(.caption)
                        .help(item.isProtected
                              ? "\(item.path)\n系统限制读取其他应用的数据,大小无法统计;如移除失败,可在「系统设置 > 隐私与安全性」中授予 MacTool 权限"
                              : item.path)
                    }
                }

                Divider()

                if uninstaller.isTargetRunning {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("\(target.name) 正在运行")
                            .font(.caption)
                        Spacer()
                        Button("退出应用") { uninstaller.quitTarget() }
                            .controlSize(.small)
                    }
                }

                HStack {
                    Button("取消") { uninstaller.reset() }
                    Spacer()
                    if uninstaller.working {
                        ProgressView().controlSize(.small)
                    }
                    Button("卸载 \(ByteFormatter.string(uninstaller.selectedBytes))") {
                        withAnimation { confirmUninstall = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(uninstaller.scanning || uninstaller.working || uninstaller.isTargetRunning)
                }
            }
        } label: {
            Label("应用卸载", systemImage: "xmark.bin")
        }
    }
}
