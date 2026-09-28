import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 作为单元测试宿主运行时不做单实例处理,否则并行测试的宿主会互相结束
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // 单实例保护:后启动的实例顶替旧实例,避免菜单栏出现多个图标
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.lihao.MacTool"
        let currentPID = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where app.processIdentifier != currentPID {
            app.terminate()
        }
        // 启动即申请通知权限,保证 80% 充电提醒可用
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

@main
struct MacToolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var metrics: SystemMetrics
    @State private var battery: BatteryService
    @State private var clipboard: ClipboardStore
    @State private var capture: ScreenCaptureService
    @State private var processes = ProcessMonitor()
    @State private var uninstaller = AppUninstaller()
    @State private var cleaner = CleanerService()
    @State private var tools = ToolService()
    @State private var speedTest = SpeedTestService()
    @State private var bluetooth = BluetoothBatteryService()
    @StateObject private var settings = AppSettings()

    init() {
        let metrics = SystemMetrics()
        let battery = BatteryService()
        let clipboard = ClipboardStore()
        metrics.start()
        battery.start()
        clipboard.start()
        _metrics = State(initialValue: metrics)
        _battery = State(initialValue: battery)
        _clipboard = State(initialValue: clipboard)
        let capture = ScreenCaptureService()
        _capture = State(initialValue: capture)

        ClipboardPanelController.shared.store = clipboard
        GlobalHotKey.shared.actions[.clipboard] = { ClipboardPanelController.shared.toggle() }
        GlobalHotKey.shared.actions[.screenshot] = { capture.capture(.region) }
        // 测试宿主里不抢占全局快捷键
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            GlobalHotKey.shared.apply(ClipboardHotKey.current)
            GlobalHotKey.shared.apply(ScreenshotHotKey.current)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(metrics)
                .environment(battery)
                .environment(cleaner)
                .environment(clipboard)
                .environment(capture)
                .environment(tools)
                .environment(processes)
                .environment(uninstaller)
                .environment(speedTest)
                .environment(bluetooth)
                .environmentObject(settings)
        } label: {
            MenuBarLabel()
                .environment(metrics)
                .environment(battery)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(clipboard)
                .environment(capture)
                .environmentObject(settings)
        }
    }
}

struct MenuBarLabel: View {
    @Environment(SystemMetrics.self) private var metrics
    @Environment(BatteryService.self) private var battery
    @AppStorage("menuBarShow_cpu") private var showCPU = true
    @AppStorage("menuBarShow_gpu") private var showGPU = false
    @AppStorage("menuBarShow_memory") private var showMemory = false
    @AppStorage("menuBarShow_network") private var showNetwork = false
    @AppStorage("menuBarShow_battery") private var showBattery = false

    var body: some View {
        if items.isEmpty {
            Image(systemName: "wrench.and.screwdriver.fill")
        } else {
            Image(nsImage: renderedImage)
        }
    }

    private var items: [MenuBarMetricsStrip.Item] {
        var result: [MenuBarMetricsStrip.Item] = []
        if showCPU { result.append(.init(top: "CPU", bottom: metrics.cpuPercentText)) }
        if showGPU { result.append(.init(top: "GPU", bottom: metrics.gpuPercentText)) }
        if showMemory { result.append(.init(top: "内存", bottom: metrics.memPercentText)) }
        if showNetwork {
            result.append(.init(
                top: "↑ " + ByteFormatter.compactRate(metrics.netUpBps),
                bottom: "↓ " + ByteFormatter.compactRate(metrics.netDownBps),
                style: .stacked
            ))
        }
        if showBattery { result.append(.init(top: "电量", bottom: battery.percentText)) }
        return result
    }

    /// 菜单栏 label 只支持单行文本且忽略字体,所以把两行布局渲染成模板图片;
    /// isTemplate 让系统按浅色/深色菜单栏自动着色
    private var renderedImage: NSImage {
        let renderer = ImageRenderer(content: MenuBarMetricsStrip(items: items))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}

/// 每项占一格:上方小字名 + 下方数值;网速用上下两行等大小字(同 Stats)
struct MenuBarMetricsStrip: View {
    struct Item {
        enum Style { case labeled, stacked }
        let top: String
        let bottom: String
        var style: Style = .labeled
    }

    let items: [Item]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                switch item.style {
                case .labeled:
                    VStack(spacing: -1) {
                        Text(item.top)
                            .font(.system(size: 8, weight: .medium))
                        Text(item.bottom)
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .fixedSize()
                    }
                    // 最小宽度按 "88%" 预留,数字变化时不抖动;"100%" 时自动变宽不截断
                    .frame(minWidth: 26)
                case .stacked:
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.top)
                        Text(item.bottom)
                    }
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .fixedSize()
                    .frame(minWidth: 40, alignment: .leading)
                }
            }
        }
        .foregroundStyle(.black)
        .frame(height: 22)
    }
}
