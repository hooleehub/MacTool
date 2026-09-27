import Carbon.HIToolbox
import Foundation

enum ClipboardHotKey: String, CaseIterable, Identifiable {
    case off
    case shiftCommandV
    case optionCommandV
    case controlCommandV
    case controlOptionV

    static let storageKey = "clipboardHotKey"
    static let defaultValue = ClipboardHotKey.shiftCommandV

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "关闭"
        case .shiftCommandV: return "⇧⌘V"
        case .optionCommandV: return "⌥⌘V"
        case .controlCommandV: return "⌃⌘V"
        case .controlOptionV: return "⌃⌥V"
        }
    }

    var carbonModifiers: UInt32? {
        switch self {
        case .off: return nil
        case .shiftCommandV: return UInt32(shiftKey | cmdKey)
        case .optionCommandV: return UInt32(optionKey | cmdKey)
        case .controlCommandV: return UInt32(controlKey | cmdKey)
        case .controlOptionV: return UInt32(controlKey | optionKey)
        }
    }

    static var current: ClipboardHotKey {
        UserDefaults.standard.string(forKey: storageKey).flatMap(ClipboardHotKey.init) ?? defaultValue
    }
}

/// Carbon RegisterEventHotKey:系统级快捷键,不需要辅助功能权限,且会吞掉按键不传给前台 App
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    var action: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func apply(_ preset: ClipboardHotKey, retries: Int = 3) {
        unregister()
        guard let modifiers = preset.carbonModifiers else { return }
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D54_4C43), id: 1) // 'MTLC'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_V), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status != noErr else { return }
        NSLog("MacTool: 注册快捷键失败 \(status)")
        // 单实例切换时旧实例可能还没退出、仍占着快捷键,稍后重试
        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard ClipboardHotKey.current == preset else { return }
            self?.apply(preset, retries: retries - 1)
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotKey.shared.action?() }
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
    }
}
