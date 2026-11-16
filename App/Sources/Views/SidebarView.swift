import SwiftUI
import EOFCore

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
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
                        OpenDocumentRow(document: document, isActive: document.id == model.activeID)
                    }
                }
            }

            if let folder = model.folder {
                Section {
                    FolderContents(node: folder)
                } header: {
                    HStack {
                        Text(verbatim: folder.name)
                        Spacer()
                        Menu {
                            Button {
                                showFolderSearch = true
                            } label: {
                                Label("Find in Folder…", systemImage: "magnifyingglass")
                            }
                            Button {
                                folder.reload()
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            Toggle(isOn: $settings.showHiddenFiles) {
                                Label("Show Hidden Files", systemImage: "eye")
                            }
                            Divider()
                            Button(role: .destructive) {
                                model.closeFolder()
                            } label: {
                                Label("Close Folder", systemImage: "xmark")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .imageScale(.large)
                        }
                        .accessibilityLabel(Text("Folder Actions"))
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
                            Image(systemName: "folder.badge.plus")
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
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(verbatim: item.location)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                            } icon: {
                                Image(systemName: item.isFolder ? "folder" : FileNode.symbol(for: item.name))
                                    .foregroundStyle(item.isFolder ? Color.accentColor : FileNode.tint(for: item.name))
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
        .onChange(of: settings.showHiddenFiles) { _, _ in
            model.folder?.reloadExpanded()
        }
        .onReceive(model.commands) { command in
            if case .findInFolder = command, model.folder != nil { showFolderSearch = true }
        }
    }
}

private struct OpenDocumentRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var document: EditorDocument
    let isActive: Bool

    private var detail: String {
        let place = document.url.map(FileAccess.displayLocation) ?? String(localized: "Not Saved")
        return document.isBinary ? place : "\(document.language.name) · \(place)"
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                model.activate(document)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(verbatim: document.name)
                                .lineLimit(1)
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
                    Image(systemName: FileNode.symbol(for: document.name))
                        .foregroundStyle(document.isBinary ? Color.secondary : FileNode.tint(for: document.name))
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
        }
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

/// The children of a folder node, loaded on demand.
private struct FolderContents: View {
    @ObservedObject var node: FileNode

    var body: some View {
        if let children = node.children {
            if children.isEmpty {
                Text("Empty Folder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(children) { child in
                    FileNodeRow(node: child, parent: node)
                }
            }
        } else {
            ProgressView()
                .onAppear { node.reload() }
        }
    }
}

private struct FileNodeRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var node: FileNode
    let parent: FileNode
    @State private var prompt: NamePrompt?
    @State private var name = ""
    @State private var confirmDelete = false

    private enum NamePrompt: Identifiable {
        case newFile, newFolder, rename
        var id: Int { hashValue }
    }

    var body: some View {
        Group {
            if node.isDirectory {
                DisclosureGroup(isExpanded: $node.isExpanded) {
                    FolderContents(node: node)
                } label: {
                    Label {
                        Text(verbatim: node.name).lineLimit(1)
                    } icon: {
                        Image(systemName: "folder")
                    }
                }
            } else {
                Button {
                    model.open(node.url)
                } label: {
                    Label {
                        Text(verbatim: node.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: FileNode.symbol(for: node.name))
                            .foregroundStyle(FileNode.tint(for: node.name))
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .contextMenu {
            if node.isDirectory {
                Button {
                    name = ""
                    prompt = .newFile
                } label: {
                    Label("New File…", systemImage: "doc.badge.plus")
                }
                Button {
                    name = ""
                    prompt = .newFolder
                } label: {
                    Label("New Folder…", systemImage: "folder.badge.plus")
                }
            }
            Button {
                name = node.name
                prompt = .rename
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            ShareLink(item: node.url)
            Divider()
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .alert(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { kind in
            TextField("Name", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button(kind == .rename ? "Rename" : "Create") { perform(kind) }
        }
        .confirmationDialog("Delete “\(node.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private var promptTitle: LocalizedStringKey {
        switch prompt {
        case .newFile: return "New File"
        case .newFolder: return "New Folder"
        case .rename: return "Rename"
        case nil: return ""
        }
    }

    private func perform(_ kind: NamePrompt) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return }
        let manager = FileManager.default
        do {
            switch kind {
            case .newFile:
                let target = node.url.appendingPathComponent(trimmed)
                guard !manager.fileExists(atPath: target.path) else { throw FileAccess.Failure(message: String(localized: "An item with that name already exists.")) }
                try Data().write(to: target)
                node.isExpanded = true
                node.reload()
                model.open(target)
            case .newFolder:
                try manager.createDirectory(at: node.url.appendingPathComponent(trimmed), withIntermediateDirectories: false)
                node.isExpanded = true
                node.reload()
            case .rename:
                let target = node.url.deletingLastPathComponent().appendingPathComponent(trimmed)
                guard target != node.url else { return }
                if let open = model.documents.first(where: { $0.url?.standardizedFileURL == node.url.standardizedFileURL }) {
                    open.autosave()
                    try manager.moveItem(at: node.url, to: target)
                    open.adopt(url: target)
                    model.saveSession()
                } else {
                    try manager.moveItem(at: node.url, to: target)
                }
                parent.reload()
            }
        } catch {
            model.alert = AppAlert(title: String(localized: "Could Not Complete"), message: error.localizedDescription)
        }
    }

    private func delete() {
        do {
            if let open = model.documents.first(where: { $0.url?.standardizedFileURL == node.url.standardizedFileURL }) {
                open.isDirty = false
                model.close(open)
            }
            try FileManager.default.removeItem(at: node.url)
            parent.reload()
        } catch {
            model.alert = AppAlert(title: String(localized: "Could Not Delete"), message: error.localizedDescription)
        }
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
        default: return .secondary
        }
    }

    /// Re-reads this folder and every expanded folder below it.
    func reloadExpanded() {
        guard isDirectory, children != nil else { return }
        reload()
        for child in children ?? [] where child.isExpanded { child.reloadExpanded() }
    }
}
