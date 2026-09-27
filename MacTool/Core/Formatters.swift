import Foundation

enum ByteFormatter {
    private static let units = ["B", "KB", "MB", "GB", "TB"]

    static func string(_ bytes: UInt64) -> String {
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.1f %@", value, units[unit])
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        string(UInt64(max(0, bytesPerSecond))) + "/s"
    }

    /// 菜单栏用的紧凑速率:"0K" "512K" "1.2M" "25M" "1.1G"
    static func compactRate(_ bytesPerSecond: Double) -> String {
        let kb = max(0, bytesPerSecond) / 1024
        if kb < 1000 { return "\(Int(kb.rounded()))K" }
        let mb = kb / 1024
        if mb < 10 { return String(format: "%.1fM", mb) }
        if mb < 1000 { return "\(Int(mb.rounded()))M" }
        return String(format: "%.1fG", mb / 1024)
    }
}

enum DurationFormatter {
    /// 运行时长:"3 天 4 小时" / "5 小时 12 分" / "8 分钟"
    static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分钟"
    }
}
