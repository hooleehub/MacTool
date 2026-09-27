import Foundation

struct SpeedTestResult: Equatable {
    /// 字节/秒(networkQuality 输出的是比特/秒,解析时换算)
    let downloadBps: Double
    let uploadBps: Double
    /// 基础往返时延(毫秒)
    let latencyMs: Double?
    /// 负载下的响应性(RPM,每分钟往返次数,越高越好)
    let responsivenessRPM: Double?
    let interface: String?
    let date: Date

    /// 苹果的分级:RPM < 200 低,200...1000 中,> 1000 高
    var responsivenessLevel: String? {
        guard let rpm = responsivenessRPM else { return nil }
        switch rpm {
        case ..<200: return "低"
        case ..<1000: return "中"
        default: return "高"
        }
    }
}

enum SpeedTestParser {
    static func parse(_ data: Data, date: Date = .now) -> SpeedTestResult? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dl = (json["dl_throughput"] as? NSNumber)?.doubleValue,
              let ul = (json["ul_throughput"] as? NSNumber)?.doubleValue else { return nil }
        return SpeedTestResult(
            downloadBps: dl / 8,
            uploadBps: ul / 8,
            latencyMs: (json["base_rtt"] as? NSNumber)?.doubleValue,
            responsivenessRPM: (json["responsiveness"] as? NSNumber)?.doubleValue,
            interface: json["interface_name"] as? String,
            date: date
        )
    }
}

/// 用系统自带的 networkQuality 测速(与"系统设置 > 网络"里的测速同源),耗时约 15~20 秒
@Observable
@MainActor
final class SpeedTestService {
    private(set) var running = false
    private(set) var result: SpeedTestResult?
    private(set) var error: String?
    private(set) var startedAt: Date?

    private var process: Process?

    func start() {
        guard !running else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
        process.arguments = ["-c", "-M", "20"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            self.error = "无法启动 networkQuality"
            return
        }
        self.process = process
        running = true
        error = nil
        startedAt = .now
        Task.detached { [weak self] in
            // 先读完再等待退出,避免输出超过管道缓冲时互相阻塞
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let status = process.terminationStatus
            let reason = process.terminationReason
            await MainActor.run { [weak self] in
                guard let self, self.process === process else { return }
                self.process = nil
                self.running = false
                self.startedAt = nil
                if reason == .uncaughtSignal { return }
                if let parsed = SpeedTestParser.parse(data) {
                    self.result = parsed
                } else {
                    self.error = status == 0 ? "无法解析测速结果" : "测速失败,请检查网络连接"
                }
            }
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
        running = false
        startedAt = nil
    }
}
