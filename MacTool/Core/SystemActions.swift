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

    /// 未设置时 CreateDesktop 缺省为显示
    static var desktopIconsShown: Bool {
        let output = runCapturing("/usr/bin/defaults", ["read", "com.apple.finder", "CreateDesktop"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !["0", "false", "FALSE"].contains(output)
    }

    static func setDesktopIcons(_ shown: Bool) {
        run("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", shown ? "true" : "false"])
        run("/usr/bin/killall", ["Finder"])
    }

    static func restart(_ processName: String) {
        run("/usr/bin/killall", [processName])
    }

    /// 可推出的卷:外置/可移除磁盘、磁盘映像、网络卷(不含系统盘)
    static func ejectableVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsRootFileSystem != true else { return false }
            return values.volumeIsEjectable == true || values.volumeIsRemovable == true || values.volumeIsInternal == false
        }
    }

    /// 返回 (成功数, 失败的卷名)
    static func ejectAll() -> (ejected: Int, failed: [String]) {
        var ejected = 0
        var failed: [String] = []
        for url in ejectableVolumes() {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                ejected += 1
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        return (ejected, failed)
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

enum CaffeinateDuration: Int, CaseIterable, Identifiable {
    case forever = 0
    case minutes30 = 1800
    case hour1 = 3600
    case hours2 = 7200
    case hours5 = 18000

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .forever: return "一直"
        case .minutes30: return "30 分钟"
        case .hour1: return "1 小时"
        case .hours2: return "2 小时"
        case .hours5: return "5 小时"
        }
    }
}

@Observable
@MainActor
final class ToolService {
    static let keepDisplayOnKey = "caffeinateKeepDisplayOn"

    private(set) var caffeinating = false
    /// nil 表示不限时
    private(set) var caffeinateUntil: Date?
    private(set) var hiddenFiles = SystemActions.hiddenFilesShown
    private(set) var desktopIcons = SystemActions.desktopIconsShown
    private(set) var ejecting = false
    var message: String?

    /// 关闭后只阻止系统休眠,屏幕照常按设置熄灭
    var keepDisplayOn: Bool = UserDefaults.standard.object(forKey: ToolService.keepDisplayOnKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(keepDisplayOn, forKey: Self.keepDisplayOnKey)
            if caffeinating { startCaffeinate(remainingDuration) }
        }
    }

    private var caffeinateProcess: Process?
    private var caffeinateTimer: Task<Void, Never>?

    private var remainingDuration: TimeInterval {
        caffeinateUntil.map { max(1, $0.timeIntervalSinceNow) } ?? 0
    }

    func startCaffeinate(_ duration: CaffeinateDuration) {
        startCaffeinate(TimeInterval(duration.rawValue))
    }

    /// seconds 为 0 表示不限时;到时由本 App 结束 caffeinate,不依赖 -t(与 -w 组合时行为不直观)
    private func startCaffeinate(_ seconds: TimeInterval) {
        stopCaffeinate()
        // -w 绑定本进程:App 退出/崩溃时 caffeinate 自动结束,不会让 Mac 永久不休眠
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let process = SystemActions.run("/usr/bin/caffeinate", [keepDisplayOn ? "-di" : "-i", "-w", pid])
        caffeinateProcess = process
        caffeinating = true
        guard seconds > 0 else { return }
        caffeinateUntil = Date().addingTimeInterval(seconds)
        caffeinateTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.stopCaffeinate()
        }
    }

    func stopCaffeinate() {
        caffeinateTimer?.cancel()
        caffeinateTimer = nil
        caffeinateProcess?.terminate()
        caffeinateProcess = nil
        caffeinating = false
        caffeinateUntil = nil
    }

    func toggleHiddenFiles() {
        SystemActions.setHiddenFiles(!hiddenFiles)
        hiddenFiles.toggle()
    }

    func toggleDesktopIcons() {
        SystemActions.setDesktopIcons(!desktopIcons)
        desktopIcons.toggle()
    }

    func restartDock() {
        SystemActions.restart("Dock")
        message = "已重启程序坞"
    }

    func restartFinder() {
        SystemActions.restart("Finder")
        message = "已重启访达"
    }

    func ejectAll() {
        guard !ejecting else { return }
        ejecting = true
        message = "正在推出磁盘…"
        Task.detached { [weak self] in
            let result = SystemActions.ejectAll()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.ejecting = false
                if result.ejected == 0 && result.failed.isEmpty {
                    self.message = "没有可推出的磁盘"
                } else if result.failed.isEmpty {
                    self.message = "已推出 \(result.ejected) 个磁盘"
                } else {
                    self.message = "已推出 \(result.ejected) 个,\(result.failed.joined(separator: "、")) 正在使用中无法推出"
                }
            }
        }
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
