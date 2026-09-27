import Foundation

struct BluetoothDevice: Identifiable, Equatable {
    struct Level: Equatable {
        let label: String?
        let percent: Int
    }

    let name: String
    let minorType: String?
    let levels: [Level]
    var id: String { name }

    var symbolName: String {
        let type = (minorType ?? "").lowercased()
        let lowerName = name.lowercased()
        if lowerName.contains("airpods max") { return "airpodsmax" }
        if lowerName.contains("airpods pro") { return "airpodspro" }
        if lowerName.contains("airpods") { return "airpods" }
        if type.contains("mouse") || lowerName.contains("mouse") { return "magicmouse" }
        if type.contains("keyboard") || lowerName.contains("keyboard") { return "keyboard" }
        if type.contains("trackpad") || lowerName.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if type.contains("headphone") || type.contains("headset") { return "headphones" }
        if type.contains("speaker") { return "hifispeaker" }
        if type.contains("gamepad") || type.contains("controller") { return "gamecontroller" }
        return "dot.radiowaves.left.and.right"
    }
}

/// 解析 `system_profiler SPBluetoothDataType -json`,只保留已连接且上报电量的设备
enum BluetoothBatteryParser {
    private static let levelKeys: [(key: String, label: String?)] = [
        ("device_batteryLevelMain", nil),
        ("device_batteryLevel", nil),
        ("device_batteryLevelLeft", "左"),
        ("device_batteryLevelRight", "右"),
        ("device_batteryLevelCase", "充电盒"),
    ]

    static func parse(_ data: Data) -> [BluetoothDevice] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = json["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var devices: [BluetoothDevice] = []
        for controller in controllers {
            // 每个元素是 { 设备名: 属性字典 } 的单键字典
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let props = value as? [String: Any] else { continue }
                    let levels = levelKeys.compactMap { item -> BluetoothDevice.Level? in
                        guard let percent = percentValue(props[item.key]) else { return nil }
                        return BluetoothDevice.Level(label: item.label, percent: percent)
                    }
                    guard !levels.isEmpty else { continue }
                    devices.append(BluetoothDevice(name: name, minorType: props["device_minorType"] as? String, levels: levels))
                }
            }
        }
        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 值形如 "85%",个别系统版本是数字
    static func percentValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        guard let string = value as? String else { return nil }
        return Int(string.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
    }
}

/// AirPods、妙控鼠标/键盘/触控板等蓝牙设备的电量。system_profiler 较慢(约 1~3 秒),只在电池页可见时轮询
@Observable
@MainActor
final class BluetoothBatteryService {
    private(set) var devices: [BluetoothDevice] = []
    private(set) var loaded = false
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let data = await Task.detached {
                    Data(SystemActions.runCapturing("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]).utf8)
                }.value
                guard !Task.isCancelled else { return }
                self?.devices = BluetoothBatteryParser.parse(data)
                self?.loaded = true
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
