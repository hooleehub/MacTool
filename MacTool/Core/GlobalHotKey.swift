import Carbon.HIToolbox
import Foundation

/// 每种用途占一个快捷键槽位,互不覆盖
enum HotKeySlot: UInt32 {
    case clipboard = 1
    case screenshot = 2
}

/// 快捷键预设:菜单里选一个,存 UserDefaults(`@AppStorage(storageKey)`)
protocol HotKeyPreset: RawRepresentable, CaseIterable, Identifiable, Hashable where RawValue == String, AllCases == [Self] {
    static var slot: HotKeySlot { get }
    static var storageKey: String { get }
    static var defaultValue: Self { get }
    var title: String { get }
    /// nil 表示关闭
    var carbonKey: (keyCode: Int, modifiers: Int)? { get }
}

extension HotKeyPreset {
    var id: String { rawValue }

    static var current: Self {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? defaultValue
    }
}

enum ClipboardHotKey: String, HotKeyPreset {
    case off
    case shiftCommandV
    case optionCommandV
    case controlCommandV
    case controlOptionV

    static let slot = HotKeySlot.clipboard
    static let storageKey = "clipboardHotKey"
    static let defaultValue = ClipboardHotKey.shiftCommandV

    var title: String {
        switch self {
        case .off: return "关闭"
        case .shiftCommandV: return "⇧⌘V"
        case .optionCommandV: return "⌥⌘V"
        case .controlCommandV: return "⌃⌘V"
        case .controlOptionV: return "⌃⌥V"
        }
    }

    var carbonKey: (keyCode: Int, modifiers: Int)? {
        switch self {
        case .off: return nil
        case .shiftCommandV: return (kVK_ANSI_V, shiftKey | cmdKey)
        case .optionCommandV: return (kVK_ANSI_V, optionKey | cmdKey)
        case .controlCommandV: return (kVK_ANSI_V, controlKey | cmdKey)
        case .controlOptionV: return (kVK_ANSI_V, controlKey | optionKey)
        }
    }
}

/// Carbon RegisterEventHotKey:系统级快捷键,不需要辅助功能权限,且会吞掉按键不传给前台 App
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    var actions: [HotKeySlot: () -> Void] = [:]
    private var hotKeyRefs: [HotKeySlot: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    func apply<Preset: HotKeyPreset>(_ preset: Preset, retries: Int = 3) {
        let slot = Preset.slot
        unregister(slot)
        guard let key = preset.carbonKey else { return }
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D54_4C43), id: slot.rawValue) // 'MTLC'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(key.keyCode), UInt32(key.modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeyRefs[slot] = ref
            return
        }
        NSLog("MacTool: 注册快捷键 \(preset.title) 失败 \(status)")
        // 单实例切换时旧实例可能还没退出、仍占着快捷键,稍后重试
        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard Preset.current == preset else { return }
            self?.apply(preset, retries: retries - 1)
        }
    }

    private func unregister(_ slot: HotKeySlot) {
        if let ref = hotKeyRefs.removeValue(forKey: slot) {
            UnregisterEventHotKey(ref)
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard let slot = HotKeySlot(rawValue: hotKeyID.id) else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotKey.shared.actions[slot]?() }
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
    }
}
