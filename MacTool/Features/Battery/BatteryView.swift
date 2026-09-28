import AppKit
import SwiftUI

struct BatteryView: View {
    @Environment(BatteryService.self) private var battery
    @Environment(BluetoothBatteryService.self) private var bluetooth
    @EnvironmentObject private var settings: AppSettings
    @AppStorage(AlertKind.lowBattery.storageKey) private var lowBatteryAlert = AlertKind.lowBattery.defaultEnabled
    @AppStorage(AlertKind.batteryTemp.storageKey) private var batteryTempAlert = AlertKind.batteryTemp.defaultEnabled

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if battery.supported {
                    overviewCard
                    healthCard
                    detailCard
                    careCard
                } else if bluetooth.loaded && bluetooth.devices.isEmpty {
                    ContentUnavailableView(
                        "未检测到电池",
                        systemImage: "battery.0percent",
                        description: Text("此 Mac 可能没有内置电池,或权限受限。")
                    )
                }
                if !bluetooth.devices.isEmpty {
                    bluetoothCard
                }
                if battery.supported {
                    notifyCard
                }
            }
            .padding(10)
        }
        .onAppear { bluetooth.start() }
        .onDisappear { bluetooth.stop() }
    }

    private var bluetoothCard: some View {
        GroupBox {
            VStack(spacing: 6) {
                ForEach(bluetooth.devices) { device in
                    HStack(spacing: 8) {
                        Image(systemName: device.symbolName)
                            .frame(width: 20)
                            .foregroundStyle(.secondary)
                        Text(device.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        ForEach(device.levels.indices, id: \.self) { index in
                            let level = device.levels[index]
                            HStack(spacing: 2) {
                                if let label = level.label {
                                    Text(label).foregroundStyle(.secondary)
                                }
                                Text("\(level.percent)%")
                                    .monospacedDigit()
                                    .foregroundStyle(level.percent <= 20 ? .red : .primary)
                            }
                        }
                    }
                    .font(.callout)
                }
            }
            .frame(maxWidth: .infinity)
        } label: {
            Label("蓝牙设备", systemImage: "wave.3.right")
        }
    }

    private var overviewCard: some View {
        GroupBox {
            HStack(spacing: 14) {
                Image(systemName: battery.symbolName)
                    .font(.system(size: 34))
                    .foregroundStyle(battery.isCharging ? .green : .primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(battery.percentText)
                        .font(.title.monospacedDigit().bold())
                    Text(battery.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        } label: {
            Label("状态", systemImage: "bolt.batteryblock")
        }
    }

    private var healthCard: some View {
        GroupBox {
            VStack(spacing: 4) {
                row("循环次数", battery.cycleCount.map { count in
                    battery.designCycleCount.map { "\(count) / \($0) 次" } ?? "\(count) 次"
                })
                row("电池健康度", battery.healthPercent.map { String(format: "%.0f%%", $0) })
                row("设计容量", battery.designCapacity.map { "\($0) mAh" })
                row("当前最大容量", battery.maxCapacity.map { "\($0) mAh" })
            }
            .frame(maxWidth: .infinity)
        } label: {
            Label("健康", systemImage: "heart.text.square")
        }
    }

    private var detailCard: some View {
        GroupBox {
            VStack(spacing: 4) {
                optionalRow("电池温度", battery.temperatureC.map { String(format: "%.1f ℃", $0) })
                optionalRow("电压", battery.voltageV.map { String(format: "%.2f V", $0) })
                optionalRow(battery.isCharging ? "充电功率" : "放电功率", battery.wattageW.map { String(format: "%.1f W", $0) })
                optionalRow("电源适配器", battery.adapterWattage.map { "\($0) W" })
                optionalRow("充满还需", battery.timeToFullMin.map(formatMinutes))
                optionalRow("预计可用", battery.timeToEmptyMin.map(formatMinutes))
            }
            .frame(maxWidth: .infinity)
        } label: {
            Label("详情", systemImage: "info.circle")
        }
    }

    private var careCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                row("充电策略", battery.chargePolicy.text)
                optionalRow("已持续插电", battery.acDurationText)
                ForEach(battery.careTips) { tip in
                    Label(tip.text, systemImage: tip.icon)
                        .font(.caption)
                        .foregroundStyle(tip.warning ? .orange : .secondary)
                }
                Toggle("电池温度高于 40℃ 时提醒我", isOn: $batteryTempAlert)
                    .font(.callout)
                HStack {
                    Spacer()
                    Button("打开电池设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("电池保养", systemImage: "leaf")
        }
    }

    private var notifyCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("充电到 80% 时提醒我", isOn: $settings.batteryNotifyAt80)
                Toggle("电量低于 20% 时提醒我", isOn: $lowBatteryAlert)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("电量提醒", systemImage: "bell.badge")
        }
    }

    private func row(_ name: String, _ value: String?) -> some View {
        HStack {
            Text(name)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "--")
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .monospacedDigit()
        }
        .font(.callout)
    }

    /// 读不到的数据(机型不支持/当前状态无意义)直接不显示
    @ViewBuilder
    private func optionalRow(_ name: String, _ value: String?) -> some View {
        if let value {
            row(name, value)
        }
    }

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes >= 60 {
            return "\(minutes / 60) 小时 \(minutes % 60) 分"
        }
        return "\(minutes) 分钟"
    }
}
