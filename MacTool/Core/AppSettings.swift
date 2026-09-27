import Foundation
import ServiceManagement

enum MenuBarMetric: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, network, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "内存"
        case .network: return "网速(上传/下载)"
        case .battery: return "电量"
        }
    }

    var storageKey: String { "menuBarShow_" + rawValue }

    var defaultEnabled: Bool { self == .cpu }
}

final class AppSettings: ObservableObject {
    static let refreshIntervalKey = "refreshInterval"
    static let notify80Key = "batteryNotifyAt80"

    /// 监控采样间隔(秒)
    @Published var refreshInterval: Double {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: Self.refreshIntervalKey) }
    }

    @Published var batteryNotifyAt80: Bool {
        didSet { UserDefaults.standard.set(batteryNotifyAt80, forKey: Self.notify80Key) }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            objectWillChange.send()
        }
    }

    @Published var errorMessage: String?

    init() {
        let defaults = UserDefaults.standard
        Self.migrateMenuBarKeys(defaults)
        refreshInterval = defaults.object(forKey: Self.refreshIntervalKey) as? Double ?? 2
        batteryNotifyAt80 = defaults.object(forKey: Self.notify80Key) as? Bool ?? true
    }

    /// 旧版本用单个字符串/数组存菜单栏显示项,迁移到每项一个 Bool key
    private static func migrateMenuBarKeys(_ defaults: UserDefaults) {
        let rawList: [String]?
        if let array = defaults.stringArray(forKey: "menuBarMetrics") {
            rawList = array
            defaults.removeObject(forKey: "menuBarMetrics")
        } else if let single = defaults.string(forKey: "menuBarMetric") {
            rawList = [single]
            defaults.removeObject(forKey: "menuBarMetric")
        } else {
            rawList = nil
        }
        guard let rawList else { return }
        for metric in MenuBarMetric.allCases where defaults.object(forKey: metric.storageKey) == nil {
            defaults.set(rawList.contains(metric.rawValue), forKey: metric.storageKey)
        }
    }

    /// 服务循环内读取,避免与视图层耦合
    static var refreshIntervalValue: Double {
        UserDefaults.standard.object(forKey: refreshIntervalKey) as? Double ?? 2
    }
}
