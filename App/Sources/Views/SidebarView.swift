import SwiftUI
import EOFCore

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var window: WindowState
    @EnvironmentObject private var settings: AppSettings
    let startImport: (ImportKind) -> Void
    @Binding var showSettings: Bool
    @State private var showFolderSearch = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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
            get: { horizontalSizeClass == .compact ? nil : window.documentID(in: window.focusedPane) ?? window.primaryID },
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
                    ForEach(recents.prefix(12)) { item in
                        Button {
                            model.openRecent(item, in: window)
                        } label: {
                            LabeledContent {
                                Text(verbatim: item.place)
                            } label: {
                                Label {
                                    Text(verbatim: item.name)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                } icon: {
                                    FileIcon(name: item.name, isFolder: item.isFolder)
                                }
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
                    if horizontalSizeClass == .compact {
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

