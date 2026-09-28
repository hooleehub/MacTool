import SwiftUI

/// 工具页的截图卡片
struct CaptureSection: View {
    @Environment(ScreenCaptureService.self) private var capture
    @AppStorage(ScreenshotHotKey.storageKey) private var hotKey = ScreenshotHotKey.defaultValue
    @State private var permitted = ScreenCaptureService.hasPermission
    private let pins = PinController.shared

    var body: some View {
        GroupBox {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(CaptureMode.allCases) { mode in
                        Button { capture.capture(mode) } label: {
                            VStack(spacing: 4) {
                                Image(systemName: mode.symbolName)
                                    .font(.title3)
                                    .frame(height: 22)
                                Text(mode.title)
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(help(for: mode))
                    }
                }
                .disabled(capture.capturing)

                HStack(spacing: 12) {
                    Menu("延时全屏") {
                        ForEach([3, 5, 10], id: \.self) { seconds in
                            Button("\(seconds) 秒后") { capture.capture(.screen, delay: seconds) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(capture.capturing)
                    .help("先打开要截的菜单或悬停提示,倒计时结束后截取鼠标所在屏幕")
                    Button("贴图剪贴板") { capture.pinClipboardImage() }
                        .help("把剪贴板里的图片钉在屏幕最上层")
                    Spacer()
                    if pins.count > 0 {
                        Button("关闭贴图(\(pins.count))") { pins.closeAll() }
                    }
                    Button {
                        let folder = CaptureActions.saveFolder
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(folder)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("打开截图保存位置")
                }
                .font(.caption)
                .buttonStyle(.borderless)

                if !permitted {
                    HStack {
                        Text("截图需要「录屏与系统录音」权限")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("去授权") { capture.requestPermission() }
                            .buttonStyle(.borderless)
                    }
                    .font(.caption)
                }

                if let message = capture.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } label: {
            HStack {
                Label("截图", systemImage: "camera.viewfinder")
                if hotKey != .off {
                    Text(hotKey.title)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("按 \(hotKey.title) 随时开始区域截图")
                }
            }
        }
        .onAppear { permitted = ScreenCaptureService.hasPermission }
    }

    private func help(for mode: CaptureMode) -> String {
        switch mode {
        case .region: return "拖动选择区域;按空格切换为窗口选择,Esc 取消"
        case .window: return "点击要截取的窗口;按空格切换为区域选择"
        case .screen: return "截取鼠标所在的屏幕"
        }
    }
}
