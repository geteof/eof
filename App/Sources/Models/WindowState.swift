import Combine
import SwiftUI

enum EditorPane: Hashable {
    case primary, secondary
}

/// What one window shows: its editor panes, which one has focus, and its own command channel.
/// Documents are shared by every window; a document is visible in at most one pane at a time,
/// because its editor view can only be in one place.
final class WindowState: ObservableObject, Identifiable {
    let id = UUID()
    @Published var primaryID: EditorDocument.ID?
    @Published var secondaryID: EditorDocument.ID?
    @Published var focusedPane: EditorPane = .primary
    @Published var compactColumn: NavigationSplitViewColumn = .sidebar
    @Published var showBrowser = false
    /// The first pane hid its bars while scrolling; the status bar goes with them.
    @Published var barsHidden = false
    /// Share of the editor area given to the first pane when split.
    @Published var splitFraction: CGFloat = 0.5
    /// Menu and keyboard commands for this window only.
    let commands = PassthroughSubject<EditorCommand, Never>()

    var isSplit: Bool { secondaryID != nil }

    func documentID(in pane: EditorPane) -> EditorDocument.ID? {
        pane == .primary ? primaryID : secondaryID
    }

    func pane(showing id: EditorDocument.ID) -> EditorPane? {
        if primaryID == id { return .primary }
        if secondaryID == id { return .secondary }
        return nil
    }

    func set(_ id: EditorDocument.ID?, in pane: EditorPane) {
        if pane == .primary { primaryID = id } else { secondaryID = id }
    }

    /// Stops showing `id`. A second pane that is left alone takes over the first.
    func release(_ id: EditorDocument.ID) {
        if secondaryID == id { secondaryID = nil }
        if primaryID == id {
            primaryID = secondaryID
            secondaryID = nil
        }
        if !isSplit { focusedPane = .primary }
    }
}
