import SwiftUI
import UIKit

/// The row of keys above the software keyboard: characters that are slow to reach on iOS,
/// plus caret movement, Tab and undo.
final class KeyboardAccessory {
    let view: AccessoryContainer
    private let host: UIHostingController<AccessoryBar>

    init(controller: EditorController) {
        view = AccessoryContainer(frame: CGRect(x: 0, y: 0, width: 320, height: 46))
        view.anchor = controller.textView
        host = UIHostingController(rootView: AccessoryBar(controller: controller))
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        view.content.addSubview(host.view)
        host.view.frame = view.content.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    func update(dark: Bool) {
        view.overrideUserInterfaceStyle = dark ? .dark : .light
    }
}

/// The system stretches an accessory view across the whole window. This one draws its keys
/// only above the editor it belongs to and lets touches beside them through, so a sidebar or
/// a second pane next to the editor stays visible and usable while typing.
final class AccessoryContainer: UIView {
    weak var anchor: UIView?
    let content = UIInputView(frame: CGRect(x: 0, y: 0, width: 320, height: 46), inputViewStyle: .keyboard)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth]
        addSubview(content)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        content.frame = keysFrame()
    }

    /// The part of the bar above the editor; the whole bar when the editor fills the width or
    /// its position is unknown.
    private func keysFrame() -> CGRect {
        guard let anchor, let space = anchor.window?.windowScene?.coordinateSpace, window != nil else { return bounds }
        let editor = convert(anchor.convert(anchor.bounds, to: space), from: space)
        let minX = max(bounds.minX, editor.minX)
        let maxX = min(bounds.maxX, editor.maxX)
        // Too narrow to be worth it, or nearly full width anyway.
        guard maxX - minX >= 280, maxX - minX < bounds.width - 8 else { return bounds }
        return CGRect(x: minX, y: bounds.minY, width: maxX - minX, height: bounds.height)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        content.frame.contains(point)
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
