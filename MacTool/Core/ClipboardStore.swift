import AppKit
import Foundation

/// 剪贴板历史,仅保存在内存,不写盘
@Observable
@MainActor
final class ClipboardStore {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let time: Date
    }

    private(set) var items: [Item] = []

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount = 0
    private var task: Task<Void, Never>?
    private let limit = 50

    func start() {
        guard task == nil else { return }
        lastChangeCount = pasteboard.changeCount
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard let text = pasteboard.string(forType: .string),
              !text.isEmpty,
              text != items.first?.text else { return }
        items.insert(Item(text: text, time: .now), at: 0)
        if items.count > limit {
            items.removeLast(items.count - limit)
        }
    }

    func copyBack(_ item: Item) {
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
        lastChangeCount = pasteboard.changeCount
    }

    func clear() {
        items.removeAll()
    }
}
