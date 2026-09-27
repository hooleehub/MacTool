import AppKit
import Foundation
import UniformTypeIdentifiers

struct Leftover: Identifiable, Equatable {
    let path: String
    var size: UInt64?
    var selected = true
    /// macOS 的"App 数据"保护会阻止读取其他应用的目录
    var isProtected = false
    var id: String { path }
}

struct UninstallTarget: Equatable {
    let appURL: URL
    let name: String
    let bundleID: String?
    var appSize: UInt64?
    var leftovers: [Leftover] = []

    static func == (lhs: UninstallTarget, rhs: UninstallTarget) -> Bool {
        lhs.appURL == rhs.appURL && lhs.appSize == rhs.appSize && lhs.leftovers == rhs.leftovers
    }
}

/// 残留文件匹配规则,纯函数便于测试
enum LeftoverMatcher {
    /// ~/Library 下常见的应用数据目录
    static let searchDirectories = [
        "Application Support", "Caches", "Preferences", "Containers", "Group Containers",
        "Saved Application State", "Logs", "HTTPStorages", "WebKit", "Application Scripts",
        "Cookies", "LaunchAgents",
    ]

    static func matches(entry: String, bundleID: String?, appName: String) -> Bool {
        let lower = entry.lowercased()
        if let id = bundleID?.lowercased(), !id.isEmpty {
            // com.foo.app / com.foo.app.plist / com.foo.app.savedState / TEAMID.com.foo.app / group.com.foo.app
            if lower == id || lower.hasPrefix(id + ".") || lower.hasSuffix("." + id) {
                return true
            }
        }
        let name = appName.lowercased()
        return name.count >= 3 && lower == name
    }

    /// "厂商/应用" 两层目录的匹配依据,如 com.google.Chrome -> Google/Chrome
    static func nestedCandidates(bundleID: String?, appName: String) -> (vendor: String, names: Set<String>)? {
        guard let parts = bundleID?.lowercased().split(separator: "."), parts.count >= 3 else { return nil }
        let vendor = String(parts[1])
        let name = appName.lowercased()
        var names: Set<String> = [name, String(parts[parts.count - 1])]
        if name.hasPrefix(vendor + " ") {
            names.insert(String(name.dropFirst(vendor.count + 1)))
        }
        return (vendor, names.filter { $0.count >= 3 })
    }

    static func findLeftovers(bundleID: String?, appName: String, library: URL) -> [String] {
        let fm = FileManager.default
        let nested = nestedCandidates(bundleID: bundleID, appName: appName)
        var result: [String] = []
        for dir in searchDirectories {
            let url = library.appendingPathComponent(dir)
            guard let entries = try? fm.contentsOfDirectory(atPath: url.path) else { continue }
            for entry in entries {
                let entryURL = url.appendingPathComponent(entry)
                if matches(entry: entry, bundleID: bundleID, appName: appName) {
                    result.append(entryURL.path)
                } else if let nested, entry.lowercased() == nested.vendor,
                          let children = try? fm.contentsOfDirectory(atPath: entryURL.path) {
                    for child in children where nested.names.contains(child.lowercased()) {
                        result.append(entryURL.appendingPathComponent(child).path)
                    }
                }
            }
        }
        return result
    }
}

@Observable
@MainActor
final class AppUninstaller {
    var target: UninstallTarget? {
        didSet { refreshRunning() }
    }
    var scanning = false
    var working = false
    var message: String?
    /// 存储属性以便界面随应用启动/退出实时刷新
    private(set) var isTargetRunning = false

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunning() }
            }
        }
    }

    private func refreshRunning() {
        guard let id = target?.bundleID else {
            isTargetRunning = false
            return
        }
        isTargetRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    var selectedBytes: UInt64 {
        guard let target else { return 0 }
        return (target.appSize ?? 0) + target.leftovers.filter(\.selected).compactMap(\.size).reduce(0, +)
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.prompt = "选择要卸载的应用"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func load(_ url: URL) {
        message = nil
        guard url.pathExtension == "app" else {
            message = "请选择 .app 应用"
            return
        }
        let bundle = Bundle(url: url)
        let bundleID = bundle?.bundleIdentifier
        if url.path.hasPrefix("/System") || bundleID?.hasPrefix("com.apple.") == true {
            message = "系统自带应用不能卸载"
            return
        }
        if bundleID == Bundle.main.bundleIdentifier {
            message = "不能卸载 MacTool 自己"
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        target = UninstallTarget(appURL: url, name: name, bundleID: bundleID)
        scanning = true

        let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        Task.detached { [weak self] in
            let appSize = DiskScan.directorySize(atPath: url.path)
            let leftovers = LeftoverMatcher.findLeftovers(bundleID: bundleID, appName: name, library: library)
                .map { path -> Leftover in
                    let fm = FileManager.default
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: path, isDirectory: &isDir)
                    guard isDir.boolValue else {
                        return Leftover(path: path, size: UInt64((try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? 0))
                    }
                    guard (try? fm.contentsOfDirectory(atPath: path)) != nil else {
                        return Leftover(path: path, size: nil, isProtected: true)
                    }
                    return Leftover(path: path, size: DiskScan.directorySize(atPath: path))
                }
                .sorted { ($0.size ?? 0) > ($1.size ?? 0) }
            await MainActor.run { [weak self] in
                guard let self, self.target?.appURL == url else { return }
                self.target?.appSize = appSize
                self.target?.leftovers = leftovers
                self.scanning = false
            }
        }
    }

    func quitTarget() {
        guard let id = target?.bundleID else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
    }

    /// 应用本体 + 勾选的残留一起移入废纸篓(可恢复)
    func uninstall() {
        guard let target, !working else { return }
        if isTargetRunning {
            message = "请先退出 \(target.name)"
            return
        }
        working = true
        let urls = [target.appURL] + target.leftovers.filter(\.selected).map { URL(fileURLWithPath: $0.path) }
        let freed = selectedBytes
        Task.detached { [weak self] in
            let failed: [String] = urls.compactMap { url in
                (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) == nil ? url.lastPathComponent : nil
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.working = false
                if failed.isEmpty {
                    self.message = "已卸载 \(target.name),\(ByteFormatter.string(freed)) 已移入废纸篓"
                    self.target = nil
                } else if failed.contains(target.appURL.lastPathComponent) {
                    self.message = "应用本体无法移除(可能需要管理员权限,可在访达中手动删除)"
                } else {
                    self.message = "已卸载,\(failed.count) 个残留文件移除失败"
                    self.target = nil
                }
            }
        }
    }

    func reset() {
        target = nil
        message = nil
    }
}
