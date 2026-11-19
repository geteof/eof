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
        #if DEBUG
        lastScroll = "offset=\(Int(offset)) top=\(Int(top)) user=\(userDriven)"
        #endif
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

    #if DEBUG
    /// For screenshots of the hidden state: launch with `-hidebars`.
    func debugHide() { set(true) }
    #endif

    #if DEBUG
    /// Every change with the scroll that caused it, for the layout report.
    static var log: [String] = []
    private var lastScroll = ""
    #endif

    private func set(_ value: Bool) {
        guard hidden != value else { return }
        #if DEBUG
        BarVisibility.log.append("\(value ? "hide" : "show") after \(lastScroll)")
        #endif
        withAnimation(.easeInOut(duration: 0.22)) { hidden = value }
    }
}

/// How a Markdown or HTML preview shares the screen with its source.
enum PreviewLayout: String {
    case split, previewOnly
}

/// On iPhone Duo, iOS 27 moves the status bar and toolbar buttons into a column at the side of
/// the screen. EOF keeps them in a horizontal bar at the top instead, as Safari does, so the text
/// gets the full width. A NavigationSplitView takes this preference from its trailing column.
struct HorizontalBars: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.toolbarVerticalBehavior(.disabled)
        } else {
            content
        }
    }
}

extension View {
    func horizontalBars() -> some View {
        modifier(HorizontalBars())
    }
}
