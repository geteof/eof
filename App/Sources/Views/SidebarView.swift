import SwiftUI
import EOFCore

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var window: WindowState
    @EnvironmentObject private var settings: AppSettings
    let startImport: (ImportKind) -> Void
    @Binding var showSettings: Bool
    @State private var showFolderSearch = false
    @State private var showAllRecents = false
    /// Recent files shown before "Show All": enough to find today's work without a scroll.
    private static let recentLimit = 8
    /// The window is one column wide, so the sidebar is a page of its own.
    let isNarrow: Bool

    /// Recent items not already open or being browsed, one per file.
    private var recents: [RecentItem] {
        var seen = Set(model.documents.compactMap { $0.url.map(RecentItem.key) })
        if let folder = model.folder { seen.insert(RecentItem.key(for: folder.url)) }
        return model.recents.filter { seen.insert($0.key).inserted }
    }

    /// The system draws the selection: the document in the pane that has focus. In a narrow
    /// window the sidebar is a page of its own, so nothing stays selected and every tap opens.
    private var selection: Binding<EditorDocument.ID?> {
        Binding(
            get: { isNarrow ? nil : window.documentID(in: window.focusedPane) ?? window.primaryID },
            set: { id in
                if let document = model.document(id) { model.activate(document, in: window) }
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            if !model.documents.isEmpty {
                Section("Open Documents") {
                    ForEach(model.documents) { document in
                        OpenDocumentRow(document: document)
                            .tag(document.id)
                    }
                    .onMove { model.documents.move(fromOffsets: $0, toOffset: $1) }
                }
            }

            if let folder = model.folder {
                Section("Folder") {
                    Button {
                        window.showBrowser = true
                    } label: {
                        Label {
                            Text(verbatim: folder.name)
                        } icon: {
                            FileIcon(name: folder.name, isFolder: true)
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            model.closeFolder()
                        } label: {
                            Label("Close Folder", systemImage: "xmark")
                        }
                    }
                    .swipeActions {
                        Button {
                            model.closeFolder()
                        } label: {
                            Label("Close Folder", systemImage: "xmark")
                        }
                        .tint(.gray)
                    }
                    Button {
                        showFolderSearch = true
                    } label: {
                        Label("Find in Folder…", systemImage: "magnifyingglass")
                    }
                }
            }

            let recents = recents
            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(showAllRecents ? recents : Array(recents.prefix(SidebarView.recentLimit))) { item in
                        Button {
                            model.openRecent(item, in: window)
                        } label: {
                            Label {
                                // Always name over place: a row that switches between one and two
                                // lines by name length makes the list look uneven.
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: item.title)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                    if !item.place.isEmpty {
                                        Text(verbatim: item.place)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            } icon: {
                                FileIcon(name: item.name, isFolder: item.isFolder)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                model.removeRecent(item)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                    if recents.count > SidebarView.recentLimit {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { showAllRecents.toggle() }
                        } label: {
                            Label(showAllRecents ? String(localized: "Show Fewer") : String(localized: "Show All \(recents.count)"),
                                  systemImage: showAllRecents ? "chevron.up" : "chevron.down")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
        .overlay {
            if model.documents.isEmpty, model.folder == nil, recents.isEmpty {
                ContentUnavailableView {
                    Label("No Files", systemImage: "doc.text")
                } description: {
                    Text("Create or open a file with the + button.")
                } actions: {
                    // In a narrow window the sidebar is all there is, so offer the actions here too.
                    if isNarrow {
                        Button("New File") { model.newDocument(in: window) }
                            .buttonStyle(.borderedProminent)
                        Button("Open File…") { startImport(.files) }
                        Button("Open Folder…") { startImport(.folder) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("EOF")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        model.newDocument(in: window)
                    } label: {
                        Label("New File", systemImage: "square.and.pencil")
                    }
                    Button {
                        if let text = UIPasteboard.general.string { model.newDocument(text: text, in: window) }
                    } label: {
                        Label("New from Clipboard", systemImage: "doc.on.clipboard")
                    }
                    Divider()
                    Button {
                        startImport(.files)
                    } label: {
                        Label("Open File…", systemImage: "doc")
                    }
                    Button {
                        startImport(.folder)
                    } label: {
                        Label("Open Folder…", systemImage: "folder")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showFolderSearch) {
            FolderSearchView()
        }
        .onReceive(window.commands) { command in
            if case .findInFolder = command, model.folder != nil { showFolderSearch = true }
        }
    }
}

private struct OpenDocumentRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var window: WindowState
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var document: EditorDocument

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(verbatim: document.name)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if document.isDirty {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.tint)
                        .accessibilityLabel(Text("Edited"))
                }
            }
        } icon: {
            FileIcon(name: document.name)
        }
        .swipeActions {
            Button {
                model.requestClose(document)
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .tint(.gray)
        }
        .contextMenu {
            Button {
                model.requestClose(document)
            } label: {
                Label("Close", systemImage: "xmark")
            }
            Button {
                model.closeOthers(keeping: document)
            } label: {
                Label("Close Others", systemImage: "xmark.square")
            }
            if let url = document.url {
                ShareLink(item: url)
            }
            Divider()
            if window.pane(showing: document.id) == nil, window.primaryID != nil {
                Button {
                    model.activate(document, in: window, pane: .secondary)
                } label: {
                    Label("Open in Split", systemImage: "rectangle.split.2x1")
                }
            }
            if UIApplication.shared.supportsMultipleScenes {
                Button {
                    openWindow(id: EOFApp.windowID, value: document.id)
                } label: {
                    Label("Open in New Window", systemImage: "macwindow.badge.plus")
                }
            }
        } preview: {
            DocumentPeek(document: document)
        }
    }
}

/// A file's icon in lists, drawn in a fixed square so every row lines up. Files and folders use
/// the Material Icon Theme; `symbol` draws an SF Symbol the same size, for actions.
struct FileIcon: View {
    private enum Source {
        case asset(String)
        case symbol(String, Color)
    }

    private let source: Source
    var size: CGFloat = 22

    init(symbol: String, tint: Color) {
        source = .symbol(symbol, tint)
    }

    init(name: String, isFolder: Bool = false, size: CGFloat = 22) {
        source = .asset(isFolder ? MaterialIcons.folder(name) : MaterialIcons.file(name))
        self.size = size
    }

    var body: some View {
        Group {
            switch source {
            case .asset(let asset):
                Image(asset)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
            case .symbol(let symbol, let tint):
                Image(systemName: symbol)
                    .font(.system(size: size * 0.72, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size + 8, height: size + 8)
        .accessibilityHidden(true)
    }
}

/// What a long press on an open document lifts: an opaque card with the whole name and where
/// the file lives. The row itself has no background, so lifting it let the editor show through.
private struct DocumentPeek: View {
    @ObservedObject var document: EditorDocument

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FileIcon(name: document.name, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: document.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: details)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
    }

    private var details: String {
        var parts = [document.language.name]
        if let url = document.url { parts.append(FileAccess.displayLocation(url)) }
        return parts.joined(separator: " · ")
    }
}
