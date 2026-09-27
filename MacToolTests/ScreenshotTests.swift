@testable import MacTool
import AppKit
import SwiftUI
import XCTest

/// 用真实数据渲染各页面并导出 PNG 到 <repo>/Screenshots/,供 README 使用
@MainActor
final class ScreenshotTests: XCTestCase {
    func testRenderScreenshots() async throws {
        let metrics = SystemMetrics()
        let battery = BatteryService()
        let clipboard = ClipboardStore()
        let processes = ProcessMonitor()
        let cleaner = CleanerService()
        let settings = AppSettings()
        let tools = ToolService()
        let uninstaller = AppUninstaller()
        metrics.start()
        battery.start()
        processes.start()
        cleaner.scanAll()

        // 等采样两轮 + 清理扫描完成(上限 60s,目录很大时截当前进度)
        try await Task.sleep(for: .seconds(4))
        let deadline = Date().addingTimeInterval(60)
        while cleaner.categories.contains(where: \.scanning), Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
        }

        // <repo>/MacToolTests/ScreenshotTests.swift -> <repo>/Screenshots
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dir = repo.appendingPathComponent("Screenshots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 分段 Picker 离屏渲染不出内容,直接渲染各功能页本体
        let pages: [(String, AnyView)] = [
            ("monitor", AnyView(MonitorView())),
            ("battery", AnyView(BatteryView())),
            ("cleaner", AnyView(CleanerView())),
            ("tools", AnyView(ToolsView())),
        ]
        for (name, page) in pages {
            let view = page
                .environment(metrics)
                .environment(battery)
                .environment(cleaner)
                .environment(clipboard)
                .environment(tools)
                .environment(processes)
                .environment(uninstaller)
                .environmentObject(settings)
            try save(render(view, size: NSSize(width: 380, height: 560)), to: dir, named: name)
        }

        // 菜单栏指标条(画在模拟菜单栏底色的横条上)
        let strip = MenuBarMetricsStrip(items: [
            .init(top: "CPU", bottom: metrics.cpuPercentText),
            .init(top: "GPU", bottom: metrics.gpuPercentText),
            .init(top: "内存", bottom: metrics.memPercentText),
            .init(top: "↑ " + ByteFormatter.compactRate(metrics.netUpBps),
                  bottom: "↓ " + ByteFormatter.compactRate(metrics.netDownBps), style: .stacked),
            .init(top: "电量", bottom: battery.percentText),
        ])
        .padding(.horizontal, 8)
        .background(Color(white: 0.93), in: RoundedRectangle(cornerRadius: 6))
        .padding(4)
        try save(render(strip), to: dir, named: "menubar")

        processes.stop()
    }

    /// ImageRenderer 离屏渲染 Charts/复杂控件会出空白,改用 NSHostingView 走 AppKit 绘制
    private func render(_ view: some View, size: NSSize? = nil) -> NSImage? {
        let hostingView = NSHostingView(rootView: view)
        let fitting = hostingView.fittingSize
        let bounds = NSRect(origin: .zero, size: size ?? fitting)
        hostingView.frame = bounds
        // 需要挂到窗口上才会完成布局,窗口不进屏幕也不显示
        let window = NSWindow(
            contentRect: bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return nil }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        window.orderOut(nil)
        return image
    }

    private func save(_ image: NSImage?, to dir: URL, named name: String) throws {
        let image = try XCTUnwrap(image, "\(name) 渲染失败")
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return XCTFail("\(name) 转 PNG 失败") }
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
