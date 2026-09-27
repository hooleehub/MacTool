import Foundation
import IOKit
import IOKit.ps
import UserNotifications

/// 电池容量解析,兼容新旧两种 AppleSmartBattery 格式
enum BatteryMath {
    /// 旧系统:顶层 DesignCapacity / MaxCapacity(mAh);
    /// 新系统:数据在 BatteryData 子字典,顶层 MaxCapacity 变成了百分比(<=100)
    static func capacities(_ props: [String: Any]) -> (design: Int?, max: Int?) {
        let data = props["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? {
            (props[key] as? NSNumber)?.intValue ?? (data[key] as? NSNumber)?.intValue
        }
        let design = int("DesignCapacity")
        let maxCap = int("NominalChargeCapacity")
            ?? int("AppleRawMaxCapacity")
            ?? int("FullChargeCapacity")
            ?? int("MaxCapacity").flatMap { $0 > 100 ? $0 : nil }
        return (design, maxCap)
    }

    /// 与"系统设置 > 电池"一致,最高显示 100%
    static func health(design: Int?, max: Int?) -> Double? {
        guard let design, let max, design > 0 else { return nil }
        return min(100, Double(max) / Double(design) * 100)
    }
}

@Observable
@MainActor
final class BatteryService {
    private(set) var supported = false
    private(set) var percent = 0
    private(set) var isCharging = false
    private(set) var isCharged = false
    private(set) var onAC = false
    private(set) var timeToEmptyMin: Int?
    private(set) var timeToFullMin: Int?
    private(set) var cycleCount: Int?
    private(set) var designCycleCount: Int?
    private(set) var designCapacity: Int?
    private(set) var maxCapacity: Int?
    private(set) var adapterWattage: Int?
    private(set) var healthPercent: Double?
    private(set) var temperatureC: Double?
    private(set) var voltageV: Double?
    private(set) var wattageW: Double?

    private var notified80 = false
    private var task: Task<Void, Never>?

    var percentText: String { supported ? "\(percent)%" : "--" }

    var symbolName: String {
        if isCharging { return "battery.100percent.bolt" }
        // 取最接近的档位
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var statusText: String {
        if isCharging { return "充电中" }
        if isCharged { return "已充满" }
        return onAC ? "使用电源适配器" : "使用电池"
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func refresh() {
        readPowerSources()
        readSmartBattery()
        maybeNotify80()
    }

    // MARK: - IOPSCopyPowerSourcesInfo(电量/充电状态/剩余时间)

    private func readPowerSources() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            supported = false
            return
        }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  let type = desc[kIOPSTypeKey] as? String,
                  type == kIOPSInternalBatteryType else { continue }
            supported = true
            percent = intValue(desc["Current Capacity"]) ?? percent
            isCharging = desc["Is Charging"] as? Bool ?? isCharging
            isCharged = desc["Is Charged"] as? Bool ?? isCharged
            onAC = (desc["Power Source State"] as? String) == kIOPSACPowerValue
            timeToEmptyMin = intValue(desc["Time to Empty"]).flatMap { $0 > 0 ? $0 : nil }
            timeToFullMin = intValue(desc["Time to Full Charge"]).flatMap { $0 > 0 ? $0 : nil }
            return
        }
        supported = false
    }

    // MARK: - IORegistryEntry AppleSmartBattery(循环次数/健康度/功率)

    private func readSmartBattery() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any] else { return }

        cycleCount = intValue(props["CycleCount"])
        designCycleCount = intValue(props["DesignCycleCount9C"])
        let capacities = BatteryMath.capacities(props)
        designCapacity = capacities.design
        maxCapacity = capacities.max
        healthPercent = BatteryMath.health(design: capacities.design, max: capacities.max)
        if let t = intValue(props["Temperature"]) ?? intValue(props["VirtualTemperature"]) {
            temperatureC = Double(t) / 100
        }
        if let v = intValue(props["Voltage"]) {
            voltageV = Double(v) / 1000
        }
        let mA = int64Value(props["InstantAmperage"]) ?? int64Value(props["Amperage"])
        if let mA, let voltageV {
            wattageW = abs(voltageV * Double(mA) / 1000)
        }
        if let charger = props["ChargerData"] as? [String: Any] {
            adapterWattage = intValue(charger["Wattage"])
        }
    }

    // MARK: - 80% 充电提醒

    private func maybeNotify80() {
        if percent < 78 { notified80 = false }
        guard percent >= 80, isCharging,
              UserDefaults.standard.bool(forKey: AppSettings.notify80Key),
              !notified80 else { return }
        notified80 = true
        let content = UNMutableNotificationContent()
        content.title = "电量已达 \(percent)%"
        content.body = "可以拔掉充电器,有助于延长电池寿命。"
        let request = UNNotificationRequest(identifier: "battery80", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func intValue(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private func int64Value(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }
}
