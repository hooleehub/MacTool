import AppKit
import Carbon.HIToolbox

/// 贴图:把图片钉在屏幕最上层,方便对照参考。
/// 拖动移动、滚轮/捏合缩放、双击或 Esc 关闭,右键菜单复制/保存/识字/透明度
@Observable
@MainActor
final class PinController {
    static let shared = PinController()

    private(set) var count = 0
    @ObservationIgnored private var panels: [PinPanel] = []

    func pin(_ image: NSImage, png: Data? = nil) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        // 100% 为截图时的原始点尺寸;超出屏幕 80% 时缩小
        let fit = min(1, visible.width * 0.8 / image.size.width, visible.height * 0.8 / image.size.height)
        let size = NSSize(width: image.size.width * fit, height: image.size.height * fit)
        // 连续贴多张时错开,避免完全重叠
        let offset = CGFloat(panels.count % 8) * 24
        let x = min(max(visible.midX - size.width / 2 + offset, visible.minX), visible.maxX - size.width)
        let y = min(max(visible.midY - size.height / 2 - offset, visible.minY), visible.maxY - size.height)

        let panel = PinPanel(image: image, png: png, frame: NSRect(origin: NSPoint(x: x, y: y), size: size), scale: fit)
        panel.onClose = { [weak self, weak panel] in
            guard let self else { return }
            self.panels.removeAll { $0 === panel }
            self.count = self.panels.count
        }
        panels.append(panel)
        count = panels.count
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func closeAll() {
        for panel in panels { panel.closePin() }
    }
}

final class PinPanel: NSPanel {
    var onClose: (() -> Void)?
    private let pinView: PinImageView

    init(image: NSImage, png: Data?, frame: NSRect, scale: CGFloat) {
        pinView = PinImageView(image: image, png: png, scale: scale)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = pinView
        makeFirstResponder(pinView)
    }

    /// 无边框面板默认不能成为 key window,放开后才收得到 Esc / ⌘C
    override var canBecomeKey: Bool { true }

    @objc func closePin() {
        orderOut(nil)
        onClose?()
        onClose = nil
    }
}

final class PinImageView: NSView {
    private let image: NSImage
    private let png: Data?
    private var scale: CGFloat
    private let badge = NSTextField(labelWithString: "")
    private var badgeHideWork: DispatchWorkItem?

    init(image: NSImage, png: Data?, scale: CGFloat) {
        self.image = image
        self.png = png
        self.scale = scale
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor

        badge.font = .systemFont(ofSize: 11, weight: .medium)
        badge.textColor = .white
        badge.drawsBackground = true
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        badge.isBordered = false
        badge.lineBreakMode = .byTruncatingTail
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { showBadge("滚轮缩放 · 双击或 Esc 关闭 · 右键更多", duration: 2.5) }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            closePin()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let step = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
        let delta = event.scrollingDeltaY * step
        guard delta != 0 else { return }
        zoom(to: scale * (1 + delta))
    }

    override func magnify(with event: NSEvent) {
        zoom(to: scale * (1 + event.magnification))
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case kVK_Escape: closePin()
        case kVK_ANSI_W where command: closePin()
        case kVK_ANSI_C where command: copyImage()
        case kVK_ANSI_S where command: saveImage()
        case kVK_ANSI_0: actualSize()
        case kVK_ANSI_Equal: zoom(to: scale * 1.1)
        case kVK_ANSI_Minus: zoom(to: scale / 1.1)
        default: super.keyDown(with: event)
        }
    }

    /// 以鼠标位置为锚点缩放,鼠标下的像素保持不动
    private func zoom(to target: CGFloat) {
        guard let window else { return }
        let newScale = min(max(target, 0.1), 8)
        let size = NSSize(width: image.size.width * newScale, height: image.size.height * newScale)
        guard newScale != scale, size.width >= 24, size.height >= 24 else { return }
        let frame = window.frame
        var anchor = NSEvent.mouseLocation
        if !NSMouseInRect(anchor, frame, false) { anchor = NSPoint(x: frame.midX, y: frame.midY) }
        let fx = (anchor.x - frame.minX) / frame.width
        let fy = (anchor.y - frame.minY) / frame.height
        scale = newScale
        window.setFrame(NSRect(x: anchor.x - fx * size.width, y: anchor.y - fy * size.height, width: size.width, height: size.height), display: true)
        showBadge("\(Int((scale * 100).rounded()))%")
    }

    private func showBadge(_ text: String, duration: TimeInterval = 1.2) {
        badge.stringValue = " \(text) "
        badge.isHidden = false
        badgeHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.badge.isHidden = true }
        badgeHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private var pngData: Data? { png ?? image.pngData }

    // MARK: - 右键菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(item("复制", #selector(copyImage), key: "c"))
        menu.addItem(item("保存到截图文件夹", #selector(saveImage), key: "s"))
        menu.addItem(item("识别文字并复制", #selector(recognizeText)))
        menu.addItem(.separator())
        menu.addItem(item("原始大小", #selector(actualSize), key: "0"))
        let opacity = NSMenuItem(title: "不透明度", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for percent in [100, 80, 60, 40] {
            let option = item("\(percent)%", #selector(setOpacity(_:)))
            option.tag = percent
            option.state = Int(((window?.alphaValue ?? 1) * 100).rounded()) == percent ? .on : .off
            submenu.addItem(option)
        }
        opacity.submenu = submenu
        menu.addItem(opacity)
        menu.addItem(.separator())
        menu.addItem(item("关闭", #selector(closePin)))
        if PinController.shared.count > 1 {
            menu.addItem(item("关闭全部贴图", #selector(closeAllPins)))
        }
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func copyImage() {
        guard let pngData else { return }
        CaptureActions.copy(png: pngData)
        showBadge("已复制")
    }

    @objc private func saveImage() {
        guard let pngData else { return }
        do {
            let url = try CaptureActions.save(png: pngData)
            showBadge("已保存:\(url.lastPathComponent)", duration: 2)
        } catch {
            showBadge("保存失败", duration: 2)
        }
    }

    @objc private func recognizeText() {
        showBadge("正在识别文字…", duration: 30)
        Task { @MainActor in
            let status = await CaptureActions.copyRecognizedText(from: image)
            showBadge(status, duration: 2)
        }
    }

    @objc private func actualSize() {
        zoom(to: 1)
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        window?.alphaValue = CGFloat(sender.tag) / 100
    }

    @objc private func closePin() {
        (window as? PinPanel)?.closePin()
    }

    @objc private func closeAllPins() {
        PinController.shared.closeAll()
    }
}
