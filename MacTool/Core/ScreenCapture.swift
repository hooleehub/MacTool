import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Vision

enum CaptureMode: String, CaseIterable, Identifiable {
    case region, window, screen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .region: return "区域"
        case .window: return "窗口"
        case .screen: return "全屏"
        }
    }

    var symbolName: String {
        switch self {
        case .region: return "rectangle.dashed"
        case .window: return "macwindow"
        case .screen: return "display"
        }
    }
}

enum CaptureAfterAction: String, CaseIterable, Identifiable {
    case copy, save, copyAndSave

    static let storageKey = "captureAfterAction"
    static let defaultValue = CaptureAfterAction.copyAndSave

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copy: return "复制到剪贴板"
        case .save: return "保存到文件夹"
        case .copyAndSave: return "复制并保存"
        }
    }

    var copies: Bool { self != .save }
    var saves: Bool { self != .copy }

    static var current: CaptureAfterAction {
        UserDefaults.standard.string(forKey: storageKey).flatMap(CaptureAfterAction.init) ?? defaultValue
    }
}

enum ScreenshotHotKey: String, HotKeyPreset {
    case off
    case controlShiftA
    case optionShiftA
    case controlCommandA
    case shiftCommand2

    static let slot = HotKeySlot.screenshot
    static let storageKey = "screenshotHotKey"
    static let defaultValue = ScreenshotHotKey.controlShiftA

    var title: String {
        switch self {
        case .off: return "关闭"
        case .controlShiftA: return "⌃⇧A"
        case .optionShiftA: return "⌥⇧A"
        case .controlCommandA: return "⌃⌘A"
        case .shiftCommand2: return "⇧⌘2"
        }
    }

    var carbonKey: (keyCode: Int, modifiers: Int)? {
        switch self {
        case .off: return nil
        case .controlShiftA: return (kVK_ANSI_A, controlKey | shiftKey)
        case .optionShiftA: return (kVK_ANSI_A, optionKey | shiftKey)
        case .controlCommandA: return (kVK_ANSI_A, controlKey | cmdKey)
        case .shiftCommand2: return (kVK_ANSI_2, shiftKey | cmdKey)
        }
    }
}

/// /usr/sbin/screencapture 的参数:交互选区/窗口由系统原生 UI 完成(空格切换区域/窗口,Esc 取消)
enum ScreenCaptureCommand {
    static let path = "/usr/sbin/screencapture"

    static func arguments(mode: CaptureMode, output: URL, delay: Int = 0, sound: Bool = true,
                          shadow: Bool = true, display: Int? = nil) -> [String] {
        var args: [String] = []
        switch mode {
        case .region:
            args.append("-i")
        case .window:
            args += ["-i", "-W"]
        case .screen:
            if let display { args += ["-D", String(display)] }
            if delay > 0 { args += ["-T", String(delay)] }
        }
        if !sound { args.append("-x") }
        if !shadow { args.append("-o") }
        args.append(output.path)
        return args
    }
}

enum CaptureFiles {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    static func fileName(for date: Date) -> String {
        "截图 \(formatter.string(from: date)).png"
    }

    /// 同名时追加 " (2)"、" (3)"…
    static func uniqueURL(in folder: URL, fileName: String, fileManager: FileManager = .default) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(index)).\(ext)")
            index += 1
        }
        return candidate
    }

    static var tempDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MacToolCaptures", isDirectory: true)
    }

    /// 只清理本 App 自己写的临时截图(未保存的截图、拖拽/标注用的副本)
    static func purgeTemp(olderThan age: TimeInterval = 86_400) {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for entry in entries {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created.timeIntervalSinceNow < -age { try? fileManager.removeItem(at: entry) }
        }
    }
}

extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    var pixelSize: NSSize {
        guard let rep = representations.first, rep.pixelsWide > 0 else { return size }
        return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}

/// 截图、预览浮窗与贴图共用的操作
@MainActor
enum CaptureActions {
    static let saveFolderKey = "captureSaveFolder"

    static var defaultSaveFolder: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    static var saveFolder: URL {
        guard let path = UserDefaults.standard.string(forKey: saveFolderKey), !path.isEmpty else { return defaultSaveFolder }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func copy(png: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }

    static func save(png: Data, date: Date = Date()) throws -> URL {
        let folder = saveFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = CaptureFiles.uniqueURL(in: folder, fileName: CaptureFiles.fileName(for: date))
        try png.write(to: url)
        return url
    }

    /// 写到临时目录(用于拖拽 / 用「预览」标注),文件名与正式保存一致
    static func writeTemp(png: Data, date: Date = Date()) throws -> URL {
        let folder = CaptureFiles.tempDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(CaptureFiles.fileName(for: date))
        try png.write(to: url)
        return url
    }

    static func openInPreview(_ url: URL) {
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Vision 本地 OCR(中英文),识别结果复制到剪贴板;返回给用户看的提示
    static func copyRecognizedText(from image: NSImage) async -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "无法读取图片" }
        let text: String
        do {
            text = try await recognizeText(cgImage)
        } catch {
            return "文字识别失败:\(error.localizedDescription)"
        }
        guard !text.isEmpty else { return "没有识别到文字" }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let lines = text.split(separator: "\n").count
        return "已复制识别出的 \(lines) 行文字"
    }

    nonisolated static func recognizeText(_ cgImage: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }
}

struct CaptureResult {
    let image: NSImage
    let png: Data
    let date: Date
    /// 已保存时是正式文件,否则是临时文件
    var fileURL: URL
    var saved: Bool
}

@Observable
@MainActor
final class ScreenCaptureService {
    static let showPreviewKey = "captureShowPreview"
    static let playSoundKey = "capturePlaySound"
    static let windowShadowKey = "captureWindowShadow"
    static let permissionSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    private(set) var capturing = false
    var message: String?

    @ObservationIgnored private var process: Process?

    init() {
        CaptureFiles.purgeTemp()
        // 交互截图进行中退出 App 时一并结束 screencapture
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.process?.terminate() }
        }
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    private static func bool(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// 首次调用会弹系统授权框;已拒绝过则打开系统设置对应页面
    func requestPermission() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(Self.permissionSettingsURL)
        }
    }

    func capture(_ mode: CaptureMode, delay: Int = 0) {
        guard !capturing else { return }
        // screencapture 由本 App 启动,录屏权限算在本 App 头上;没权限只能截到桌面壁纸
        guard Self.hasPermission || CGRequestScreenCaptureAccess() else {
            message = "截图需要「录屏与系统录音」权限:在系统设置中允许 MacTool 后重新打开 App"
            Notifier.post(id: "capture-permission", title: "截图需要录屏权限", body: "请在「系统设置 > 隐私与安全性 > 录屏与系统录音」中允许 MacTool,然后重新打开 App。")
            return
        }
        capturing = true
        message = delay > 0 ? "\(delay) 秒后截取全屏…" : nil
        MenuBarWindow.dismiss()
        CapturePreviewController.shared.dismiss()

        let date = Date()
        let folder = CaptureFiles.tempDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let output = folder.appendingPathComponent(CaptureFiles.fileName(for: date))
        let args = ScreenCaptureCommand.arguments(
            mode: mode,
            output: output,
            delay: delay,
            sound: Self.bool(Self.playSoundKey),
            shadow: Self.bool(Self.windowShadowKey),
            display: mode == .screen ? Self.mouseDisplayIndex() : nil
        )
        Task {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // 等菜单栏面板收起,避免被截进去
            try? await Task.sleep(for: .milliseconds(250))
            let status = await run(args)
            capturing = false
            if delay > 0 { message = nil }
            // 按 Esc 取消时不会生成文件
            guard let png = try? Data(contentsOf: output), let image = NSImage(data: png) else {
                if status < 0 { message = "无法启动 screencapture" }
                return
            }
            finish(CaptureResult(image: image, png: png, date: date, fileURL: output, saved: false))
        }
    }

    func pinClipboardImage() {
        guard let image = NSImage(pasteboard: .general), image.isValid else {
            message = "剪贴板中没有图片"
            return
        }
        MenuBarWindow.dismiss()
        PinController.shared.pin(image)
    }

    private func finish(_ captured: CaptureResult) {
        var result = captured
        let action = CaptureAfterAction.current
        if action.copies { CaptureActions.copy(png: result.png) }
        if action.saves {
            do {
                result.fileURL = try CaptureActions.save(png: result.png, date: result.date)
                result.saved = true
            } catch {
                message = "保存失败:\(error.localizedDescription)"
            }
        }
        if Self.bool(Self.showPreviewKey) {
            CapturePreviewController.shared.show(result)
        }
    }

    private func run(_ args: [String]) async -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ScreenCaptureCommand.path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        self.process = process
        defer { self.process = nil }
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }
    }

    /// screencapture -D 的编号:1 为主显示器,顺序同 CGGetActiveDisplayList
    private static func mouseDisplayIndex() -> Int? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        return displays.firstIndex(of: number.uint32Value).map { $0 + 1 }
    }
}
