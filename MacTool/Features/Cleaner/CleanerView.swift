import SwiftUI

struct CleanerView: View {
    @State private var page = Page.junk

    enum Page: String, CaseIterable {
        case junk = "垃圾清理"
        case uninstall = "应用卸载"
        case large = "大文件"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $page) {
                ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.top, 8)

            switch page {
            case .junk: JunkCleanView()
            case .uninstall: UninstallerView()
            case .large: LargeFilesView()
            }
        }
    }
}

func shortenPath(_ path: String) -> String {
    path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
}

// MARK: - 垃圾清理

private struct JunkCleanView: View {
    @Environment(CleanerService.self) private var cleaner
    @State private var confirmClean = false

    var body: some View {
        @Bindable var cleaner = cleaner

        ScrollView {
            VStack(spacing: 10) {
                GroupBox {
                    VStack(spacing: 0) {
                        ForEach($cleaner.categories) { $category in
                            HStack(spacing: 8) {
                                Toggle(isOn: $category.selected) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(category.name).font(.callout)
                                        Text(shortenPath(category.path))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                .toggleStyle(.checkbox)
                                Spacer()
                                if category.scanning {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text(category.sizeBytes.map(ByteFormatter.string) ?? "--")
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            if category.id != cleaner.categories.last?.id {
                                Divider()
                            }
                        }
                    }
                } label: {
                    HStack {
                        Label("可清理项", systemImage: "trash")
                        Spacer()
                        Text("共 \(ByteFormatter.string(cleaner.totalScannedBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("重新扫描") { cleaner.scanAll() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }

                HStack {
                    Text("已选 \(ByteFormatter.string(cleaner.totalSelectedBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if cleaner.cleaning {
                        ProgressView()
                            .controlSize(.small)
                        Text("清理中…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("清理所选") { withAnimation { confirmClean = true } }
                        .disabled(cleaner.totalSelectedBytes == 0 || cleaner.cleaning || confirmClean)
                }
                .padding(.horizontal, 4)

                if confirmClean {
                    ConfirmBar(
                        message: "将约 \(ByteFormatter.string(cleaner.totalSelectedBytes)) 的内容移入废纸篓,之后可从废纸篓恢复。",
                        confirmTitle: "移入废纸篓",
                        destructive: false,
                        onConfirm: {
                            withAnimation { confirmClean = false }
                            cleaner.cleanSelected()
                        },
                        onCancel: { withAnimation { confirmClean = false } }
                    )
                }

                if let message = cleaner.cleanedMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
            .padding(10)
        }
        .onAppear {
            if cleaner.categories.allSatisfy({ $0.sizeBytes == nil }) {
                cleaner.scanAll()
            }
        }
    }
}

// MARK: - 大文件

private struct LargeFilesView: View {
    @Environment(CleanerService.self) private var cleaner

    var body: some View {
        ScrollView {
            GroupBox {
                VStack(spacing: 6) {
                    HStack {
                        Text(cleaner.largeFolderPath.map(shortenPath) ?? "选择一个文件夹,列出其中最大的 30 个文件")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("选择文件夹") { cleaner.chooseLargeFolder() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                    if cleaner.scanningLarge {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        ForEach(cleaner.largeFiles) { file in
                            Button { cleaner.revealInFinder(file.path) } label: {
                                HStack {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                                        .resizable()
                                        .frame(width: 16, height: 16)
                                    Text(URL(fileURLWithPath: file.path).lastPathComponent)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Text(ByteFormatter.string(file.size))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(shortenPath(file.path))
                        }
                        if cleaner.largeFolderPath != nil && cleaner.largeFiles.isEmpty {
                            Text("未找到文件")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } label: {
                Label("大文件查找(点击在访达中显示)", systemImage: "doc.magnifyingglass")
            }
            .padding(10)
        }
    }
}
