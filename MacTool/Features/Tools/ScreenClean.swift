import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 擦屏模式:在所有显示器上铺一层全屏纯色窗口,方便擦拭屏幕与键盘。
/// 期间吞掉全部按键(含 ⌘Q 等菜单快捷键),仅 Esc 退出、空格/点击切换黑白。
@MainActor
final class ScreenCleanController {
    static let shared = ScreenCleanController()

    let model = ScreenCleanModel()
    private var windows: [ScreenCleanWindow] = []
    private var screenObserver: NSObjectProtocol?

    var isActive: Bool { !windows.isEmpty }

    func show() {
        guard !isActive else { return }
        rebuildWindows()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildWindows() }
        }
        // accessory App 要先激活才能收到按键
        NSApp.activate()
        mouseScreenWindow()?.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        tearDownWindows()
        // 焦点还给之前的 App
        NSApp.deactivate()
    }

    private func rebuildWindows() {
        let rekey = isActive
        tearDownWindows()
        windows = NSScreen.screens.map { screen in
            let window = ScreenCleanWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            // 盖住菜单栏 / Dock,并出现在所有桌面空间
            window.level = .screenSaver
            window.isOpaque = true
            window.hasShadow = false
            window.isMovable = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.keyHandler = { [weak self] event in self?.handleKey(event) ?? true }
            window.contentView = NSHostingView(rootView: ScreenCleanView(
                model: model,
                onCycle: { [weak self] in self?.model.cycle() },
                onExit: { [weak self] in self?.dismiss() }
            ))
            window.orderFrontRegardless()
            return window
        }
        if rekey { mouseScreenWindow()?.makeKeyAndOrderFront(nil) }
    }

    private func tearDownWindows() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
    }

    /// 鼠标所在屏幕的窗口做 key window,按键由它接收
    private func mouseScreenWindow() -> ScreenCleanWindow? {
        let mouse = NSEvent.mouseLocation
        return windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first
    }

    /// 恒返回 true:其余按键(包括 ⌘ 组合,不会走到菜单快捷键)全部吞掉,擦键盘不会误触
    private func handleKey(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape: dismiss()
        case kVK_Space: model.cycle()
        default: break
        }
        return true
    }
}

/// 无边框窗口默认不能成为 key window,放开并在 sendEvent 里先拦 keyDown
final class ScreenCleanWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

@Observable
@MainActor
final class ScreenCleanModel {
    enum Shade: String, CaseIterable {
        case black, white

        var color: Color { self == .black ? .black : .white }
        var contrast: Color { self == .black ? .white : .black }
    }

    static let shadeKey = "screenCleanShade"

    var shade = Shade(rawValue: UserDefaults.standard.string(forKey: ScreenCleanModel.shadeKey) ?? "") ?? .black {
        didSet { UserDefaults.standard.set(shade.rawValue, forKey: Self.shadeKey) }
    }

    var hintVisible = true
    private var lastActivity = Date.distantPast
    private var hideTask: Task<Void, Never>?

    /// 多屏共享一个 model,点击任意屏幕都同步换色
    func cycle() {
        let all = Shade.allCases
        let next = (all.firstIndex(of: shade) ?? 0) + 1
        shade = all[next % all.count]
    }

    /// 提示显示 2.5 秒后淡出;期间有鼠标活动会重新计时
    func pokeHint() {
        lastActivity = Date()
        hintVisible = true
        guard hideTask == nil else { return }
        hideTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                let remaining = self.lastActivity.addingTimeInterval(2.5).timeIntervalSinceNow
                if remaining <= 0 { break }
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard let self, !Task.isCancelled else { return }
            self.hideTask = nil
            withAnimation(.easeOut(duration: 0.4)) { self.hintVisible = false }
        }
    }
}

struct ScreenCleanView: View {
    let model: ScreenCleanModel
    let onCycle: () -> Void
    let onExit: () -> Void

    private var contrast: Color { model.shade.contrast }

    var body: some View {
        ZStack {
            model.shade.color
                .contentShape(Rectangle())
                .onTapGesture { onCycle() }
            VStack {
                HStack {
                    Spacer()
                    Button(action: onExit) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(contrast.opacity(0.6))
                            .padding(9)
                            .background(contrast.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(20)
                }
                Spacer()
                Text("点击或空格切换黑白 · Esc 退出")
                    .font(.callout)
                    .foregroundStyle(contrast.opacity(0.55))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(contrast.opacity(0.09), in: Capsule())
                    .allowsHitTesting(false)
                    .padding(.bottom, 48)
            }
            .opacity(model.hintVisible ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onContinuousHover { phase in
            if case .active = phase { model.pokeHint() }
        }
        .onAppear { model.pokeHint() }
    }
}
