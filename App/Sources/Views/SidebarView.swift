import SwiftUI
import EOFCore

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var window: WindowState
    @EnvironmentObject private var settings: AppSettings
    let startImport: (ImportKind) -> Void
    @Binding var showSettings: Bool
    @State private var showFolderSearch = false

    var body: some View {
        List {
            Section {
                QuickActions(startImport: startImport)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if !model.documents.isEmpty {
                Section("Open Documents") {
                    ForEach(model.documents) { document in
                        OpenDocumentRow(document: document, isActive: window.pane(showing: document.id) != nil)
                    }
                }
            }

            if let folder = model.folder {
                Section("Folder") {
                    Button {
                        window.showBrowser = true
                    } label: {
                        HStack(spacing: 4) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: folder.name)
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text("Browse Files")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                FileIcon(name: folder.name, isFolder: true)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            showFolderSearch = true
                        } label: {
                            Label("Find in Folder…", systemImage: "magnifyingglass")
                        }
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
                        Label {
                            Text("Find in Folder…")
                                .font(.callout)
                                .foregroundStyle(.primary)
                        } icon: {
                            FileIcon(symbol: "magnifyingglass", tint: .gray)
                        }
                    }
                }
            }

            if model.folder == nil {
                Section("Folder") {
                    Button {
                        startImport(.folder)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Open Folder…")
                                    .foregroundStyle(.primary)
                                Text("Browse and search a whole project.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            FileIcon(symbol: "folder.badge.plus", tint: .accentColor)
                        }
                    }
                }
            }

            let recents = model.recents.filter { item in
                !model.documents.contains { $0.url?.standardizedFileURL.path == item.path } && model.folder?.url.standardizedFileURL.path != item.path
            }
            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(recents.prefix(12)) { item in
                        Button {
                            model.openRecent(item)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: item.name)
                                        .font(.callout)
                                        .lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                        .truncationMode(.middle)
                                    Text(verbatim: item.location)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                            } icon: {
                                FileIcon(name: item.name, isFolder: item.isFolder)
                            }
                        }
                        .foregroundStyle(.primary)
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
                        model.newDocument()
                    } label: {
                        Label("New File", systemImage: "square.and.pencil")
                    }
                    Button {
                        if let text = UIPasteboard.general.string { model.newDocument(text: text) }
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
    let isActive: Bool

    private var detail: String {
        let place = document.url.map(FileAccess.displayLocation) ?? String(localized: "Not Saved")
        return document.isBinary ? place : "\(document.language.name) · \(place)"
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                model.activate(document, in: window)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(verbatim: document.name)
                                .font(.callout)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .truncationMode(.middle)
                                .fontWeight(isActive ? .semibold : .regular)
                                .foregroundStyle(.primary)
                            if document.isDirty {
                                Circle()
                                    .fill(.tint)
                                    .frame(width: 7, height: 7)
                                    .accessibilityLabel(Text("Edited"))
                            }
                        }
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } icon: {
                    FileIcon(name: document.name)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                model.requestClose(document)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Close"))
        }
        // An inset, rounded highlight like the system's own sidebar selection.
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
        )
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

/// A file's icon in lists: one glyph on a rounded tile of fixed size, so every row lines up
/// whatever the glyph's own width is.
struct FileIcon: View {
    let symbol: String
    let tint: Color

    init(symbol: String, tint: Color) {
        self.symbol = symbol
        self.tint = tint
    }

    init(name: String, isFolder: Bool = false) {
        symbol = isFolder ? "folder.fill" : FileNode.symbol(for: name)
        tint = isFolder ? .accentColor : FileNode.tint(for: name)
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// New, open file and open folder as three large targets at the top of the sidebar.
private struct QuickActions: View {
    @EnvironmentObject private var model: AppModel
    let startImport: (ImportKind) -> Void

    var body: some View {
        HStack(spacing: 8) {
            tile("New File", systemImage: "square.and.pencil") { model.newDocument() }
            tile("Open File", systemImage: "doc") { startImport(.files) }
            tile("Open Folder", systemImage: "folder") { startImport(.folder) }
        }
    }

    private func tile(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(height: 24)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

extension FileNode {
    /// A quiet colour per kind of file, so a list of names can be scanned by type.
    static func tint(for name: String) -> Color {
        switch symbol(for: name) {
        case "doc.plaintext": return .blue
        case "list.bullet.rectangle": return .orange
        case "globe": return .teal
        case "terminal": return .green
        case "swift": return .orange
        case "chevron.left.forwardslash.chevron.right": return .indigo
        case "plusminus": return .pink
        case "tablecells": return .green
        case "photo": return .purple
        case "film", "waveform": return .pink
        case "doc.richtext", "rectangle.on.rectangle": return .red
        default: return .gray
        }
    }
}
