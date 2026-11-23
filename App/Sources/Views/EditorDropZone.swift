import SwiftUI
import UniformTypeIdentifiers

/// Files dropped on the editor area. The targets appear only while a file is dragged over it:
/// the first half opens the file in the pane there, the second half opens it beside, in split
/// view. The editor itself takes no drops, so a file is never pasted into the text.
struct EditorDropZone: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var window: WindowState
    @State private var isTargeted = false
    @State private var pane = EditorPane.primary

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            // The same rule SplitLayout uses: side by side on a wide area, stacked on a narrow one.
            let horizontal = proxy.size.width >= 640
            let hasDocument = window.primaryID != nil
            content
                .overlay {
                    if isTargeted {
                        targets(horizontal: horizontal, split: hasDocument)
                            .transition(.opacity)
                    }
                }
                .onDrop(of: FileDrag.droppableTypes, delegate: Delegate(
                    size: proxy.size, horizontal: horizontal, split: hasDocument,
                    isTargeted: $isTargeted, pane: $pane
                ) { providers, pane in
                    FileDrag.open(providers, model: model, window: window, pane: pane)
                })
        }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .animation(.easeOut(duration: 0.12), value: pane)
    }

    @ViewBuilder
    private func targets(horizontal: Bool, split: Bool) -> some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
        layout {
            target(String(localized: "Open Here"), systemImage: "doc.text", active: pane == .primary)
            if split {
                target(String(localized: "Open in Split"), systemImage: horizontal ? "rectangle.righthalf.inset.filled" : "rectangle.bottomhalf.inset.filled", active: pane == .secondary)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .allowsHitTesting(false)
    }

    private func target(_ title: String, systemImage: String, active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.accentColor.opacity(active ? 0.22 : 0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(active ? 0.9 : 0.35), style: StrokeStyle(lineWidth: 2, dash: active ? [] : [8, 6]))
            }
            .overlay {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
    }

    private struct Delegate: DropDelegate {
        let size: CGSize
        let horizontal: Bool
        let split: Bool
        @Binding var isTargeted: Bool
        @Binding var pane: EditorPane
        let perform: ([NSItemProvider], EditorPane) -> Void

        func validateDrop(info: DropInfo) -> Bool {
            FileDrag.canOpen(info.itemProviders(for: FileDrag.droppableTypes))
        }

        func dropEntered(info: DropInfo) {
            isTargeted = true
            update(info)
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            update(info)
            return DropProposal(operation: .copy)
        }

        func dropExited(info: DropInfo) {
            isTargeted = false
        }

        func performDrop(info: DropInfo) -> Bool {
            isTargeted = false
            perform(info.itemProviders(for: FileDrag.droppableTypes), pane)
            return true
        }

        private func update(_ info: DropInfo) {
            let share = horizontal ? info.location.x / max(size.width, 1) : info.location.y / max(size.height, 1)
            let target: EditorPane = split && share >= 0.5 ? .secondary : .primary
            if target != pane { pane = target }
        }
    }
}
