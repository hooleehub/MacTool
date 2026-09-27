import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(ClipboardStore.self) private var clipboard
    @AppStorage(ClipboardHotKey.storageKey) private var hotKey = ClipboardHotKey.defaultValue
    @AppStorage(ClipboardPanelController.autoPasteKey) private var autoPaste = true
    @State private var accessibilityTrusted = ClipboardPanelController.accessibilityTrusted()

    var body: some View {
        @Bindable var clipboard = clipboard

        Form {
            Section("通用") {
                Toggle("开机自动启动", isOn: $settings.launchAtLogin)
            }
            Section {
                Picker("呼出快捷键", selection: $hotKey) {
                    ForEach(ClipboardHotKey.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: hotKey) { _, preset in GlobalHotKey.shared.apply(preset) }
                Toggle("选中后自动粘贴到当前应用", isOn: $autoPaste)
                    .onChange(of: autoPaste) { _, enabled in
                        if enabled { accessibilityTrusted = ClipboardPanelController.accessibilityTrusted(prompt: true) }
                    }
                if autoPaste && !accessibilityTrusted {
                    HStack {
                        Text("自动粘贴需要「辅助功能」权限")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("去授权") {
                            accessibilityTrusted = ClipboardPanelController.accessibilityTrusted(prompt: true)
                        }
                    }
                    .font(.caption)
                }
                Toggle("保存历史到磁盘(重启后保留)", isOn: $clipboard.persist)
            } header: {
                Text("剪贴板")
            } footer: {
                Text("图片只保存在内存;密码管理器标记为敏感的内容不会被记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("通知提醒") {
                ForEach(AlertKind.allCases) { kind in
                    AlertToggle(kind: kind)
                }
            }
            Section("菜单栏显示") {
                ForEach(MenuBarMetric.allCases) { metric in
                    MetricToggle(metric: metric)
                }
            }
            Section("监控") {
                Slider(value: $settings.refreshInterval, in: 1...10, step: 1) {
                    Text("采样间隔:\(Int(settings.refreshInterval)) 秒")
                }
            }
            Section("电池") {
                Toggle("充电到 80% 时提醒", isOn: $settings.batteryNotifyAt80)
            }
            Section {
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "--")
            }
            if let error = settings.errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(4)
        // 从系统设置授权回来后刷新提示
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = ClipboardPanelController.accessibilityTrusted()
        }
    }
}

private struct AlertToggle: View {
    let kind: AlertKind
    @AppStorage private var isOn: Bool

    init(kind: AlertKind) {
        self.kind = kind
        _isOn = AppStorage(wrappedValue: kind.defaultEnabled, kind.storageKey)
    }

    var body: some View {
        Toggle(kind.title, isOn: $isOn)
    }
}

/// 与菜单栏 label 的 @AppStorage 共用同一 key,两边互相实时刷新
private struct MetricToggle: View {
    let metric: MenuBarMetric
    @AppStorage private var isOn: Bool

    init(metric: MenuBarMetric) {
        self.metric = metric
        _isOn = AppStorage(wrappedValue: metric.defaultEnabled, metric.storageKey)
    }

    var body: some View {
        Toggle(metric.title, isOn: $isOn)
    }
}
