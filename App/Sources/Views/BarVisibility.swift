import SwiftUI

/// Hides a screen's bars while the user scrolls down through content and shows them again on
/// scrolling up or reaching the top, as Safari does. Only scrolling the user drives counts:
/// typing and jumping to a line also move the content, and must not hide anything.
final class BarVisibility: ObservableObject {
    @Published private(set) var hidden = false
    private var anchor: CGFloat = 0
    /// How far the content must move in one direction before the bars change.
    private let threshold: CGFloat = 28

    func scrolled(offset: CGFloat, top: CGFloat, userDriven: Bool) {
        if offset <= top + 4 {
            reveal()
            anchor = offset
            return
        }
        guard userDriven else {
            anchor = offset
            return
        }
        if hidden {
            // Keep the anchor at the furthest point down, so any real scroll up brings them back.
            if offset > anchor { anchor = offset }
            if anchor - offset > threshold { reveal(); anchor = offset }
        } else {
            if offset < anchor { anchor = offset }
            if offset - anchor > threshold { set(true); anchor = offset }
        }
    }

    func reveal() { set(false) }

    private func set(_ value: Bool) {
        guard hidden != value else { return }
        withAnimation(.easeInOut(duration: 0.22)) { hidden = value }
    }
}

/// How a Markdown or HTML preview shares the screen with its source.
enum PreviewLayout: String {
    case split, previewOnly
}
