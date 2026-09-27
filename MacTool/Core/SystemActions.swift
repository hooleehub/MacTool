import AppKit
import Foundation

/// 常用系统操作(锁屏 / 隐藏文件 / 深色模式 / 防休眠 / 清空废纸篓)
enum SystemActions {
    /// 优先用 login.framework 的 SACLockScreenImmediate(与"控制中心 > 锁定屏幕"相同);
    /// 旧的 CGSession 工具在新系统已移除。找不到时退回熄屏(默认设置下熄屏即需密码)
    static func lockScreen() {
        typealias LockFunction = @convention(c) () -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            _ = unsafeBitCast(symbol, to: LockFunction.self)()
        } else {
            run("/usr/bin/pmset", ["displaysleepnow"])
        }
    }

    static var hiddenFilesShown: Bool {
        let output = runCapturing("/usr/bin/defaults", ["read", "com.apple.finder", "AppleShowAllFiles"])
        return ["1", "true", "TRUE"].contains(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func setHiddenFiles(_ shown: Bool) {
        run("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", shown ? "true" : "false"])
        run("/usr/bin/killall", ["Finder"])
    }

    /// 需要"自动化"权限,首次会弹系统授权框
    static func toggleDarkMode() {
        run("/usr/bin/osascript", ["-e", #"tell application "System Events" to tell appearance preferences to set dark mode to not dark mode"#])
    }

    enum TrashResult: Equatable {
        case emptied(Int)
        case alreadyEmpty
        case notAuthorized
        case failed(String)
    }

    /// 不可恢复地删除废纸篓内容,调用方需先取得用户确认。
    /// ~/.Trash 受系统保护,普通应用读不到,所以交给访达清倒(与访达菜单"清倒废纸篓"相同,
    /// 也会一并清理外置磁盘上的废纸篓);首次需要"自动化 > 访达"授权
    static func emptyTrash() -> TrashResult {
        let script = """
        tell application "Finder"
            set itemCount to count items of trash
            if itemCount > 0 then empty trash
            return itemCount
        end tell
        """
        let result = runScript(script)
        if result.status == 0 {
            let count = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return count > 0 ? .emptied(count) : .alreadyEmpty
        }
        // -1743:用户拒绝了自动化权限
        if result.error.contains("-1743") || result.error.contains("Not authorized") {
            return .notAuthorized
        }
        return .failed(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func runScript(_ source: String) -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        guard (try? process.run()) != nil else { return (-1, "", "无法启动 osascript") }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        return process
    }

    static func runCapturing(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        // 先读完再等待退出:输出超过管道缓冲(64KB)时,先 wait 会与子进程互相阻塞
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

@Observable
@MainActor
final class ToolService {
    private(set) var caffeinating = false
    private(set) var hiddenFiles = SystemActions.hiddenFilesShown
    var message: String?

    private var caffeinateProcess: Process?

    func toggleCaffeinate() {
        if caffeinating {
            caffeinateProcess?.terminate()
            caffeinateProcess = nil
        } else {
            // -w 绑定本进程:App 退出/崩溃时 caffeinate 自动结束,不会让 Mac 永久不休眠
            let pid = String(ProcessInfo.processInfo.processIdentifier)
            caffeinateProcess = SystemActions.run("/usr/bin/caffeinate", ["-d", "-w", pid])
        }
        caffeinating.toggle()
    }

    func toggleHiddenFiles() {
        SystemActions.setHiddenFiles(!hiddenFiles)
        hiddenFiles.toggle()
    }

    func toggleDarkMode() {
        SystemActions.toggleDarkMode()
    }

    func lockScreen() {
        SystemActions.lockScreen()
    }

    private(set) var emptyingTrash = false

    func emptyTrash() {
        guard !emptyingTrash else { return }
        emptyingTrash = true
        message = "正在清倒废纸篓…"
        Task.detached { [weak self] in
            let result = SystemActions.emptyTrash()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.emptyingTrash = false
                switch result {
                case .emptied(let count):
                    self.message = "已清倒废纸篓(\(count) 项)"
                case .alreadyEmpty:
                    self.message = "废纸篓已经是空的"
                case .notAuthorized:
                    self.message = "需要授权:请在「系统设置 > 隐私与安全性 > 自动化」中允许 MacTool 控制「访达」"
                case .failed(let error):
                    self.message = "清倒失败:\(error)"
                }
            }
        }
    }
}
