import AppKit
import Foundation

struct ProcessEntry: Identifiable, Equatable {
    let pid: Int32
    let name: String
    let cpu: Double         // 百分比,可能超过 100(多核)
    let memBytes: UInt64
    var id: Int32 { pid }
}

enum ProcessParser {
    /// 解析 `ps -Aeo pid=,pcpu=,rss=,comm=` 输出;comm 是完整路径,可能含空格
    static func parse(_ output: String) -> [ProcessEntry] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4,
                  let pid = Int32(fields[0]),
                  let cpu = Double(fields[1]),
                  let rssKB = UInt64(fields[2]) else { return nil }
            let command = String(fields[3]).trimmingCharacters(in: .whitespaces)
            let name = (command as NSString).lastPathComponent
            return ProcessEntry(pid: pid, name: name.isEmpty ? command : name, cpu: cpu, memBytes: rssKB * 1024)
        }
    }
}

/// 占用最高的进程;仅在监控页可见时轮询,节省资源
@Observable
@MainActor
final class ProcessMonitor {
    private(set) var topCPU: [ProcessEntry] = []
    private(set) var topMemory: [ProcessEntry] = []
    var message: String?

    private var task: Task<Void, Never>?
    private let limit = 5

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let output = await Task.detached {
                    SystemActions.runCapturing("/bin/ps", ["-Aeo", "pid=,pcpu=,rss=,comm="])
                }.value
                guard let self, !Task.isCancelled else { return }
                let entries = ProcessParser.parse(output)
                self.topCPU = Array(entries.sorted { $0.cpu > $1.cpu }.prefix(self.limit))
                self.topMemory = Array(entries.sorted { $0.memBytes > $1.memBytes }.prefix(self.limit))
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func terminate(_ entry: ProcessEntry) {
        if kill(entry.pid, SIGTERM) == 0 {
            message = "已发送结束信号给 \(entry.name)"
        } else {
            message = "无法结束 \(entry.name)(系统进程或权限不足)"
        }
    }

    /// GUI 应用返回应用名与图标,命令行进程返回 nil
    static func appInfo(for pid: Int32) -> (name: String, icon: NSImage)? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let name = app.localizedName, let icon = app.icon else { return nil }
        return (name, icon)
    }
}
