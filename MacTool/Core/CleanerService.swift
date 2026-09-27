import AppKit
import Foundation

struct CleanCategory: Identifiable, Equatable {
    let id: UUID
    var name: String
    var path: String
    var sizeBytes: UInt64?
    var scanning = false
    var selected = false
}

struct LargeFile: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let size: UInt64
}

/// 磁盘遍历,非 actor 隔离,供后台任务调用
enum DiskScan {
    static func directorySize(atPath path: String) -> UInt64 {
        let url = URL(fileURLWithPath: path)
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(max(0, size))
            }
        }
        return total
    }

    /// 把每个目录下的子项移入废纸篓,返回 (成功数, 失败数)
    static func trashContents(ofPaths paths: [String]) -> (Int, Int) {
        let fm = FileManager.default
        var removed = 0
        var failed = 0
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { continue }
            for child in children {
                do {
                    try fm.trashItem(at: child, resultingItemURL: nil)
                    removed += 1
                } catch {
                    failed += 1
                }
            }
        }
        return (removed, failed)
    }

    static func largestFiles(in folder: URL, limit: Int) -> [LargeFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }
        var files: [LargeFile] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize, size > 0 else { continue }
            files.append(LargeFile(path: fileURL.path, size: UInt64(size)))
        }
        return Array(files.sorted { $0.size > $1.size }.prefix(limit))
    }
}

@Observable
@MainActor
final class CleanerService {
    var categories: [CleanCategory]
    var scanning = false
    var cleaning = false
    var cleanedMessage: String?
    var largeFiles: [LargeFile] = []
    var scanningLarge = false
    var largeFolderPath: String?

    init() {
        let home = NSHomeDirectory()
        let candidates: [(String, String)] = [
            ("用户缓存", "\(home)/Library/Caches"),
            ("用户日志", "\(home)/Library/Logs"),
            ("Xcode 编译缓存", "\(home)/Library/Developer/Xcode/DerivedData"),
            ("Xcode 设备支持文件", "\(home)/Library/Developer/Xcode/iOS DeviceSupport"),
            ("模拟器缓存", "\(home)/Library/Developer/CoreSimulator/Caches"),
            ("npm 缓存", "\(home)/.npm/_cacache"),
        ]
        categories = candidates
            .filter { FileManager.default.fileExists(atPath: $0.1) }
            .map { CleanCategory(id: UUID(), name: $0.0, path: $0.1) }
    }

    var totalScannedBytes: UInt64 {
        categories.compactMap(\.sizeBytes).reduce(0, +)
    }

    var totalSelectedBytes: UInt64 {
        categories.filter(\.selected).compactMap(\.sizeBytes).reduce(0, +)
    }

    func scanAll() {
        for index in categories.indices {
            rescan(index)
        }
    }

    private func rescan(_ index: Int) {
        categories[index].scanning = true
        categories[index].sizeBytes = nil
        let path = categories[index].path
        Task.detached { [weak self] in
            let size = DiskScan.directorySize(atPath: path)
            await MainActor.run { [weak self] in
                guard let self, index < self.categories.count else { return }
                self.categories[index].sizeBytes = size
                self.categories[index].scanning = false
            }
        }
    }

    /// 把所选目录的"内容"移入废纸篓(目录本身保留),可从废纸篓恢复;后台执行避免卡住界面
    func cleanSelected() {
        let indices = categories.indices.filter { categories[$0].selected }
        guard !indices.isEmpty, !cleaning else { return }
        let paths = indices.map { categories[$0].path }
        let freed = indices.compactMap { categories[$0].sizeBytes }.reduce(0, +)
        cleaning = true
        cleanedMessage = nil
        Task.detached { [weak self] in
            let (removed, failed) = DiskScan.trashContents(ofPaths: paths)
            await MainActor.run { [weak self] in
                guard let self else { return }
                for index in indices {
                    self.categories[index].selected = false
                    self.rescan(index)
                }
                self.cleaning = false
                if failed == 0 {
                    self.cleanedMessage = "已将 \(removed) 项(\(ByteFormatter.string(freed)))移入废纸篓"
                } else {
                    self.cleanedMessage = "已清理 \(removed) 项;\(failed) 项失败(文件可能正在使用)"
                }
            }
        }
    }

    // MARK: - 大文件查找

    func chooseLargeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "扫描此文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        largeFolderPath = url.path
        findLargeFiles(in: url)
    }

    func findLargeFiles(in folder: URL) {
        scanningLarge = true
        largeFiles = []
        Task.detached { [weak self] in
            let files = DiskScan.largestFiles(in: folder, limit: 30)
            await MainActor.run { [weak self] in
                self?.largeFiles = files
                self?.scanningLarge = false
            }
        }
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
