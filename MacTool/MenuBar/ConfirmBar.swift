import SwiftUI

/// 面板内的二次确认条。
/// MenuBarExtra(.window) 面板一旦失去焦点就会收起,confirmationDialog / alert 会弹出新窗口抢走焦点,
/// 导致面板连同确认框一起消失,所以面板内的确认一律用这个内联组件
struct ConfirmBar: View {
    let message: String
    let confirmTitle: String
    var destructive = true
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(destructive ? .red : .orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(destructive ? .red : .accentColor)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((destructive ? Color.red : Color.orange).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder((destructive ? Color.red : Color.orange).opacity(0.3))
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
