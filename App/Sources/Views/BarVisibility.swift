import SwiftUI

/// Where a scroll view stands, for deciding whether to hide the bars.
struct ScrollReport {
    var offset: CGFloat
    /// The offset at the top and at the end of the content.
    var top: CGFloat
    var bottom: CGFloat
    /// The user is dragging or the content is still moving from a drag.
    var userDriven: Bool

    init(_ scrollView: UIScrollView) {
        offset = scrollView.contentOffset.y
        top = -scrollView.adjustedContentInset.top
        bottom = max(top, scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height)
        userDriven = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
    }
}

/// Hides a screen's bars while the user scrolls down through content and shows them again on
/// scrolling up or reaching the top, as Safari does. Only scrolling the user drives counts:
/// typing and jumping to a line also move the content, and must not hide anything.
final class BarVisibility: ObservableObject {
    @Published private(set) var hidden = false
    private var anchor: CGFloat = 0
    /// How far the content must move in one direction before the bars change.
    private let threshold: CGFloat = 28
    /// How far content must scroll before the bars may hide. Hiding them makes the view taller,
    /// so content that only just scrolls would stop scrolling, return to the top and bring the
    /// bars back, over and over. Once hidden, they stay hidden while a little room is left.
    private let roomToHide: CGFloat = 240
    private let roomToStayHidden: CGFloat = 40

    func scrolled(_ report: ScrollReport) {
        let top = report.top
        // Past the end the content bounces back up; that is not the user scrolling up.
        let offset = min(report.offset, report.bottom)
        let userDriven = report.userDriven
        #if DEBUG
        lastScroll = "offset=\(Int(offset)) top=\(Int(top)) bottom=\(Int(report.bottom)) user=\(userDriven)"
        #endif
        if report.bottom - top < (hidden ? roomToStayHidden : roomToHide) {
            reveal()
            anchor = offset
            return
        }
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

    func reveal() {
        #if DEBUG
        if pinned { return }
        #endif
        set(false)
    }

    #if DEBUG
    /// For screenshots of the hidden state: launch with `-hidebars`. Stays hidden, because a
    /// preview that finishes loading reports a scroll to the top, which would bring them back.
    private var pinned = false
    func debugHide() {
        set(true)
        pinned = true
    }
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

/// What a Markdown, HTML or SVG document shows: its source, its preview, or both side by side.
enum ViewMode: Hashable {
    case source, preview, sideBySide
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
