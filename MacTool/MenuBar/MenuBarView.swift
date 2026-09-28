import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openSettings) private var openSettings
    @State private var tab = Tab.monitor

    enum Tab: String, CaseIterable {
        case monitor = "监控"
        case battery = "电池"
        case cleaner = "清理"
        case tools = "工具"
    }

    init(initialTab: Tab = .monitor) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            Group {
                switch tab {
                case .monitor: MonitorView()
                case .battery: BatteryView()
                case .cleaner: CleanerView()
                case .tools: ToolsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Button {
                    openSettings()
                    closeMenuBarWindow()
                } label: {
                    Label("设置", systemImage: "gear")
                }
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    Label("退出", systemImage: "power")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 380, height: 560)
    }

    private func closeMenuBarWindow() {
        DispatchQueue.main.async {
            MenuBarWindow.dismiss()
            NSApp.activate()
        }
    }
}

enum MenuBarWindow {
    /// MenuBarExtra(.window) 的面板是个特殊窗口,打开设置 / 截图前把它关掉
    @MainActor
    static func dismiss() {
        for window in NSApp.windows {
            let className = NSStringFromClass(type(of: window))
            if className.contains("MenuBarExtra") || className.contains("StatusBar") {
                window.orderOut(nil)
            }
        }
    }
}
