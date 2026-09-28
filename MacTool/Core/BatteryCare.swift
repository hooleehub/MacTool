import Foundation

/// 当前生效的充电管理策略。powerd 会把策略归档写入
/// /Library/Preferences/com.apple.powerd.charging.plist(所有用户可读)
enum ChargePolicy: Equatable {
    /// 用户在「系统设置 > 电池 > 充电」里设定的充电上限
    case chargeLimit(Int)
    /// 优化电池充电等系统策略正在暂缓充电;Int 为暂缓的电量上限(可能读不到)
    case managed(Int?)
    /// 没有任何充电限制
    case none
    /// 读不到(台式机/文件不存在/格式变化)
    case unknown

    var text: String {
        switch self {
        case .chargeLimit(let limit): return "充电上限 \(limit)%"
        case .managed(let limit):
            if let limit { return "暂缓至 \(limit)%(优化电池充电)" }
            return "优化电池充电生效中"
        case .none: return "未开启"
        case .unknown: return "--"
        }
    }
}

/// powerd 的 ChargeCtrlPolicy 对象。NSKeyedUnarchiver 按归档里的类名匹配,
/// 用 @objc(ChargeCtrlPolicy) 顶替同名类解码,只取需要的字段
@objc(ChargeCtrlPolicy)
final class ChargeCtrlPolicy: NSObject, NSSecureCoding {
    let reason: String
    let soclimit: Int
    let drain: Bool
    let terminated: Bool
    let noChargeToFull: Bool
    let isEndOfCharge: Bool

    static var supportsSecureCoding: Bool { true }

    init(reason: String = "", soclimit: Int = 100, drain: Bool = false,
         terminated: Bool = false, noChargeToFull: Bool = false, isEndOfCharge: Bool = false) {
        self.reason = reason
        self.soclimit = soclimit
        self.drain = drain
        self.terminated = terminated
        self.noChargeToFull = noChargeToFull
        self.isEndOfCharge = isEndOfCharge
    }

    required init?(coder: NSCoder) {
        reason = (coder.decodeObject(of: NSString.self, forKey: "reason") as? String) ?? ""
        soclimit = coder.decodeInteger(forKey: "soclimit")
        drain = coder.decodeBool(forKey: "drain")
        terminated = coder.decodeBool(forKey: "terminated")
        noChargeToFull = coder.decodeBool(forKey: "noChargeToFull")
        isEndOfCharge = coder.decodeBool(forKey: "isEndOfCharge")
    }

    func encode(with coder: NSCoder) {
        coder.encode(reason, forKey: "reason")
        coder.encode(soclimit, forKey: "soclimit")
        coder.encode(drain, forKey: "drain")
        coder.encode(terminated, forKey: "terminated")
        coder.encode(noChargeToFull, forKey: "noChargeToFull")
        coder.encode(isEndOfCharge, forKey: "isEndOfCharge")
    }
}

enum ChargePolicyReader {
    private static let url = URL(fileURLWithPath: "/Library/Preferences/com.apple.powerd.charging.plist")
    private static let classes: [AnyClass] = [
        NSArray.self, NSMutableArray.self, ChargeCtrlPolicy.self, NSString.self, NSUUID.self,
    ]

    static func read() -> ChargePolicy {
        guard let dict = NSDictionary(contentsOf: url),
              let data = dict["policies"] as? Data,
              let policies = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? [ChargeCtrlPolicy] else { return .unknown }
        return classify(policies)
    }

    /// terminated 的策略已失效;手动充电上限优先,其余活动策略归为「优化电池充电」类管理
    static func classify(_ policies: [ChargeCtrlPolicy]) -> ChargePolicy {
        let active = policies.filter { !$0.terminated }
        if let manual = active.first(where: { $0.reason == "manualChargeLimit" }) {
            return .chargeLimit(manual.soclimit)
        }
        guard let hold = active.first else { return .none }
        let limit = (0..<100).contains(hold.soclimit) ? hold.soclimit : nil
        return .managed(limit)
    }
}

struct CareTip: Identifiable {
    let text: String
    let icon: String
    var warning = false
    var id: String { text }
}

/// 按 Apple 官方电池保养建议生成当前状态下的提示
enum BatteryCare {
    static func tips(policy: ChargePolicy, onAC: Bool, acDuration: TimeInterval?,
                     temperatureC: Double?, healthPercent: Double?) -> [CareTip] {
        var tips: [CareTip] = []
        if let t = temperatureC, t >= 35 {
            tips.append(CareTip(
                text: String(format: "电池温度 %.0f℃ 偏高,建议降低负载并注意散热", t),
                icon: "thermometer.high", warning: true))
        }
        if let h = healthPercent, h < 80 {
            tips.append(CareTip(
                text: "电池健康度低于 80%,建议到 Apple 支持检测",
                icon: "exclamationmark.triangle", warning: true))
        }
        if onAC {
            switch policy {
            case .chargeLimit:
                tips.append(CareTip(text: "已开启充电上限,长期插电无需额外操作", icon: "checkmark.circle"))
            case .managed:
                tips.append(CareTip(text: "优化电池充电生效中,系统会自动暂缓充满", icon: "checkmark.circle"))
            case .none:
                tips.append(CareTip(
                    text: "长期插电建议在系统设置开启「优化电池充电」或「充电上限」", icon: "info.circle"))
                if let d = acDuration, d >= 3 * 86_400 {
                    tips.append(CareTip(
                        text: "已持续插电 \(Int(d / 86_400)) 天,建议偶尔用电池放电到 50% 左右", icon: "battery.50percent"))
                }
            case .unknown:
                break
            }
        }
        if tips.isEmpty {
            tips.append(CareTip(text: "避免高温环境;长期存放请保持约 50% 电量", icon: "info.circle"))
        }
        return tips
    }
}
