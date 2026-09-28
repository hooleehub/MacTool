import AppKit
import SwiftUI

/// 截图后右下角的预览浮窗:贴图 / 复制 / 识字 / 标注 / 保存 / 删除,缩略图可直接拖进其他 App。
/// 不激活 App、不抢焦点;无操作 8 秒后自动收起,鼠标悬停时不收
@MainActor
final class CapturePreviewController {
    static let shared = CapturePreviewController()

    let model = CapturePreviewModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private let width: CGFloat = 300

    func show(_ result: CaptureResult) {
        model.result = result
        model.status = Self.summary(for: result)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let hosting = NSHostingView(rootView: CapturePreviewView(model: model, controller: self))
        panel.contentView = hosting
        let size = NSSize(width: width, height: hosting.fittingSize.height)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        panel.setFrame(NSRect(x: visible.maxX - size.width - 16, y: visible.minY + 16, width: size.width, height: size.height), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        scheduleHide()
    }

    func dismiss() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        model.result = nil
    }

    func hoverChanged(_ hovering: Bool) {
        model.hovering = hovering
        if hovering {
            hideTask?.cancel()
        } else {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, !self.model.hovering else { return }
            self.dismiss()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    private static func summary(for result: CaptureResult) -> String {
        let copied = CaptureAfterAction.current.copies
        switch (copied, result.saved) {
        case (true, true): return "已复制并保存到「\(result.fileURL.deletingLastPathComponent().lastPathComponent)」"
        case (false, true): return "已保存到「\(result.fileURL.deletingLastPathComponent().lastPathComponent)」"
        case (true, false): return "已复制到剪贴板"
        case (false, false): return "未保存"
        }
    }

    // MARK: - 操作

    func pin() {
        guard let result = model.result else { return }
        PinController.shared.pin(result.image, png: result.png)
        dismiss()
    }

    func copy() {
        guard let result = model.result else { return }
        CaptureActions.copy(png: result.png)
        model.status = "已复制到剪贴板"
        scheduleHideIfIdle()
    }

    func recognizeText() {
        guard let result = model.result, !model.recognizing else { return }
        model.recognizing = true
        model.status = "正在识别文字…"
        Task {
            let status = await CaptureActions.copyRecognizedText(from: result.image)
            model.recognizing = false
            model.status = status
            scheduleHideIfIdle()
        }
    }

    /// 用系统「预览」打开,工具栏里的标记工具可以画框、箭头、文字、马赛克
    func annotate() {
        guard let result = model.result else { return }
        CaptureActions.openInPreview(result.fileURL)
        dismiss()
    }

    func saveOrReveal() {
        guard var result = model.result else { return }
        if result.saved {
            CaptureActions.reveal(result.fileURL)
            dismiss()
            return
        }
        do {
            result.fileURL = try CaptureActions.save(png: result.png, date: result.date)
            result.saved = true
            model.result = result
            model.status = "已保存到「\(result.fileURL.deletingLastPathComponent().lastPathComponent)」"
        } catch {
            model.status = "保存失败:\(error.localizedDescription)"
        }
        scheduleHideIfIdle()
    }

    /// 已保存的文件移入废纸篓(可恢复);未保存的直接丢弃
    func discard() {
        if let result = model.result, result.saved {
            try? FileManager.default.trashItem(at: result.fileURL, resultingItemURL: nil)
        }
        dismiss()
    }

    private func scheduleHideIfIdle() {
        if !model.hovering { scheduleHide() }
    }
}

@Observable
@MainActor
final class CapturePreviewModel {
    var result: CaptureResult?
    var status: String?
    var hovering = false
    var recognizing = false
}

struct CapturePreviewView: View {
    let model: CapturePreviewModel
    let controller: CapturePreviewController

    var body: some View {
        VStack(spacing: 6) {
            if let result = model.result {
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: result.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 160)
                        .frame(height: 160)
                        .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onDrag { NSItemProvider(contentsOf: result.fileURL) ?? NSItemProvider() }
                        .onTapGesture(count: 2) { controller.annotate() }
                        .help("拖到其他 App 直接发送,双击用「预览」标注")
                    Button(action: controller.dismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .padding(5)
                }

                HStack {
                    Text(model.status ?? "")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    let pixels = result.image.pixelSize
                    Text("\(Int(pixels.width)) × \(Int(pixels.height))")
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)

                HStack(spacing: 0) {
                    tool("贴图", "pin", action: controller.pin)
                    tool("复制", "doc.on.doc", action: controller.copy)
                    tool(model.recognizing ? "识别中" : "识字", "text.viewfinder", action: controller.recognizeText)
                        .disabled(model.recognizing)
                    tool("标注", "pencil.tip.crop.circle", action: controller.annotate)
                    tool(result.saved ? "访达" : "保存", result.saved ? "folder" : "square.and.arrow.down", action: controller.saveOrReveal)
                    tool("删除", "trash", action: controller.discard)
                }
            }
        }
        .padding(8)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .onHover { controller.hoverChanged($0) }
    }

    private func tool(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .frame(height: 16)
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(PreviewToolButtonStyle())
    }
}

private struct PreviewToolButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.08 : 0),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .onHover { hovering = $0 }
    }
}
