import SwiftUI
import UIKit

/// The row of keys above the software keyboard: characters that are slow to reach on iOS,
/// plus caret movement, Tab and undo.
final class KeyboardAccessory {
    let view: UIInputView
    private let host: UIHostingController<AccessoryBar>

    init(controller: EditorController) {
        view = UIInputView(frame: CGRect(x: 0, y: 0, width: 320, height: 46), inputViewStyle: .keyboard)
        host = UIHostingController(rootView: AccessoryBar(controller: controller))
        host.view.backgroundColor = .clear
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.safeAreaRegions = []
        view.addSubview(host.view)
    }

    func update(dark: Bool) {
        view.overrideUserInterfaceStyle = dark ? .dark : .light
    }
}

struct AccessoryBar: View {
    weak var controller: EditorController?

    private static let symbols = ["{", "}", "[", "]", "(", ")", "<", ">", "\"", "'", "=", ":", ";", "/", "\\", "|", "&", "!", "?", "#", "$", "%", "^", "*", "+", "-", "_", "~", "`", "@"]

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    key(systemImage: "arrow.right.to.line", label: "Tab") { controller?.insert("\t") }
                    key(systemImage: "arrow.uturn.backward", label: "Undo") { controller?.undo() }
                    key(systemImage: "arrow.uturn.forward", label: "Redo") { controller?.redo() }
                    key(systemImage: "arrow.left", label: "Move Left", repeats: true) { controller?.moveCaret(by: -1) }
                    key(systemImage: "arrow.right", label: "Move Right", repeats: true) { controller?.moveCaret(by: 1) }
                    ForEach(AccessoryBar.symbols, id: \.self) { symbol in
                        Button {
                            controller?.insert(symbol)
                        } label: {
                            Text(verbatim: symbol)
                                .font(.system(size: 17, weight: .medium, design: .monospaced))
                                .frame(minWidth: 34, minHeight: 34)
                        }
                        .buttonStyle(AccessoryKeyStyle())
                    }
                }
                .padding(.horizontal, 8)
            }
            Divider().frame(height: 26)
            Button {
                controller?.resignFocus()
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 17))
                    .frame(width: 46, height: 46)
            }
            .accessibilityLabel(Text("Hide Keyboard"))
        }
        .frame(height: 46)
        .ignoresSafeArea()
    }

    private func key(systemImage: String, label: LocalizedStringKey, repeats: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(minWidth: 34, minHeight: 34)
        }
        .buttonStyle(AccessoryKeyStyle())
        .buttonRepeatBehavior(repeats ? .enabled : .disabled)
        .accessibilityLabel(Text(label))
    }
}

private struct AccessoryKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(uiColor: configuration.isPressed ? .systemFill : .tertiarySystemFill))
            )
    }
}
