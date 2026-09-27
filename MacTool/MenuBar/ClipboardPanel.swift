import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// 快捷键呼出的剪贴板弹窗:不激活 App(前台应用保持焦点),选中后复制并可自动粘贴到前台应用
@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    static let shared = ClipboardPanelController()
    static let autoPasteKey = "clipboardAutoPaste"

    var store: ClipboardStore?
    private var panel: KeyablePanel?
    private let model = ClipboardPopupModel()
    private let size = NSSize(width: 360, height: 420)

    static var autoPasteEnabled: Bool {
        UserDefaults.standard.object(forKey: autoPasteKey) as? Bool ?? true
    }

    /// 自动粘贴需要"辅助功能"权限来模拟 ⌘V;prompt 为 true 时弹出系统授权引导
    @discardableResult
    static func accessibilityTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    private func show() {
        guard let store else { return }
        model.query = ""
        model.selection = 0
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        panel.contentView = NSHostingView(rootView: ClipboardPopupView(
            model: model,
            onSelect: { [weak self] item in self?.select(item) }
        ).environment(store))
        panel.setFrame(NSRect(origin: origin(), size: size), display: false)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        return panel
    }

    /// 出现在鼠标下方,限制在当前屏幕可见区域内
    private func origin() -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let x = min(max(mouse.x - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let y = min(max(mouse.y - size.height - 12, visible.minY + 8), visible.maxY - size.height - 8)
        return NSPoint(x: x, y: y)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let store else { return false }
        let items = store.filtered(model.query)
        let command = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case kVK_DownArrow:
            model.selection = min(items.count - 1, model.selection + 1)
        case kVK_UpArrow:
            model.selection = max(0, model.selection - 1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if items.indices.contains(model.selection) { select(items[model.selection]) }
        case kVK_Escape:
            close()
        case kVK_Delete where command:
            if items.indices.contains(model.selection) { store.remove(items[model.selection]) }
            model.selection = min(model.selection, max(0, items.count - 2))
        case kVK_ANSI_P where command:
            if items.indices.contains(model.selection) { store.togglePin(items[model.selection]) }
        default:
            guard command, let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) else { return false }
            if items.indices.contains(digit - 1) { select(items[digit - 1]) }
        }
        return true
    }

    private func select(_ item: ClipboardStore.Item) {
        close()
        store?.copyBack(item)
        guard Self.autoPasteEnabled, Self.accessibilityTrusted() else { return }
        // 等弹窗消失、焦点回到前台应用后再发 ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Self.postCommandV() }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_V)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// 无边框 + 不激活的面板默认不能成为 key window,输入框就收不到键盘;这里放开并先拦截导航键
final class KeyablePanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

@Observable
@MainActor
final class ClipboardPopupModel {
    var query = ""
    var selection = 0
}

struct ClipboardPopupView: View {
    @Environment(ClipboardStore.self) private var clipboard
    @Bindable var model: ClipboardPopupModel
    let onSelect: (ClipboardStore.Item) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = clipboard.filtered(model.query)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索剪贴板历史", text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .font(.body)
            .padding(10)

            Divider()

            if items.isEmpty {
                Text(clipboard.items.isEmpty ? "暂无记录" : "没有匹配的记录")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ClipboardRow(
                                    item: item,
                                    highlighted: index == model.selection,
                                    shortcutIndex: index < 9 ? index : nil
                                )
                                .id(item.id)
                                .onTapGesture { onSelect(item) }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: model.selection) { _, selection in
                        guard items.indices.contains(selection) else { return }
                        proxy.scrollTo(items[selection].id)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text("↑↓ 选择 · ↩ \(pasteVerb) · ⌘1-9 快速选择 · ⌘P 置顶 · ⌘⌫ 删除 · esc 关闭")
                if ClipboardPanelController.autoPasteEnabled && !ClipboardPanelController.accessibilityTrusted() {
                    Text("未授予辅助功能权限,选中后仅复制到剪贴板")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(width: 360, height: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .onChange(of: model.query) { model.selection = 0 }
        .onAppear { searchFocused = true }
    }

    private var pasteVerb: String {
        ClipboardPanelController.autoPasteEnabled && ClipboardPanelController.accessibilityTrusted() ? "粘贴" : "复制"
    }
}
