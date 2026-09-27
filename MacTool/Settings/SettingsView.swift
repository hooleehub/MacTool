import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("通用") {
                Toggle("开机自动启动", isOn: $settings.launchAtLogin)
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
