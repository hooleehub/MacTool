import Foundation
import UserNotifications

enum Notifier {
    static func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

/// 阈值触发器:数值持续超过阈值 sustain 秒才触发;触发后需回落到 rearm 以下才会再次触发,避免反复提醒
struct ThresholdTrigger {
    let threshold: Double
    let rearm: Double
    let sustain: TimeInterval

    private(set) var armed = true
    private var exceededSince: Date?

    init(threshold: Double, rearm: Double, sustain: TimeInterval = 0) {
        self.threshold = threshold
        self.rearm = rearm
        self.sustain = sustain
    }

    /// 返回 true 表示此刻应该发提醒
    mutating func update(_ value: Double, now: Date = .now) -> Bool {
        if value < rearm {
            armed = true
        }
        guard value >= threshold else {
            exceededSince = nil
            return false
        }
        let since = exceededSince ?? now
        exceededSince = since
        guard armed, now.timeIntervalSince(since) >= sustain else { return false }
        armed = false
        return true
    }
}

enum AlertKind: String, CaseIterable, Identifiable {
    case cpu, memory, disk, lowBattery

    var id: String { rawValue }
    var storageKey: String { "alert_" + rawValue }
    var defaultEnabled: Bool { self == .disk || self == .lowBattery }

    var title: String {
        switch self {
        case .cpu: return "CPU 持续 2 分钟高于 90%"
        case .memory: return "内存占用高于 90%"
        case .disk: return "磁盘可用空间低于 10%"
        case .lowBattery: return "电量低于 20%(未接电源时)"
        }
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: storageKey) as? Bool ?? defaultEnabled
    }
}

/// 监控数据超过阈值时发系统通知。由 SystemMetrics / BatteryService 每次采样后调用
@MainActor
final class AlertMonitor {
    static let shared = AlertMonitor()

    private var cpu = ThresholdTrigger(threshold: 0.9, rearm: 0.7, sustain: 120)
    private var memory = ThresholdTrigger(threshold: 0.9, rearm: 0.8, sustain: 30)
    /// 以已用比例计算:已用 >= 90% 即可用 <= 10%
    private var disk = ThresholdTrigger(threshold: 0.9, rearm: 0.85)
    /// 以缺电比例计算,方便复用"越大越糟"的触发器
    private var battery = ThresholdTrigger(threshold: 0.8, rearm: 0.75)

    func check(cpuUsage: Double, memFraction: Double, diskUsed: UInt64, diskTotal: UInt64) {
        if cpu.update(cpuUsage), AlertKind.cpu.isEnabled {
            Notifier.post(id: "alert.cpu", title: "CPU 占用持续偏高",
                          body: "已连续 2 分钟超过 90%,可在 MacTool「监控」中查看占用最高的进程。")
        }
        if memory.update(memFraction), AlertKind.memory.isEnabled {
            Notifier.post(id: "alert.memory", title: "内存占用偏高",
                          body: "当前已用 \(SystemMetrics.percent(memFraction)),可以关闭不用的应用释放内存。")
        }
        guard diskTotal > 0 else { return }
        let used = Double(diskUsed) / Double(diskTotal)
        if disk.update(used), AlertKind.disk.isEnabled {
            Notifier.post(id: "alert.disk", title: "磁盘空间不足",
                          body: "仅剩 \(ByteFormatter.string(diskTotal - min(diskTotal, diskUsed))) 可用,可在 MacTool「清理」中释放空间。")
        }
    }

    func check(batteryPercent: Int, onAC: Bool) {
        // 接上电源即视为已处理,重新布防
        let deficit = onAC ? 0 : 1 - Double(batteryPercent) / 100
        if battery.update(deficit), AlertKind.lowBattery.isEnabled {
            Notifier.post(id: "alert.battery", title: "电量低", body: "剩余 \(batteryPercent)%,请尽快连接电源。")
        }
    }
}
