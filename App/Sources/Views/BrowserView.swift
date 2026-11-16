import EOFCore
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// One item in a folder, with what the browser shows about it.
struct FileEntry: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let size: Int
    let modified: Date?
    let created: Date?
    /// Number of items inside, for folders.
    let childCount: Int?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var fileExtension: String { url.pathExtension }

    var kind: String {
        if isDirectory { return String(localized: "Folder") }
        let language = Languages.detect(filename: name)
        if !language.isPlainText || language.id == "csv" { return language.name }
        return UTType(filenameExtension: fileExtension.lowercased())?.localizedDescription ?? String(localized: "Document")
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// "Markdown · 14 KB · Yesterday" or "12 items".
    var summary: String {
        if isDirectory {
            guard let childCount else { return kind }
            return String(localized: "\(childCount) items")
        }
        var parts = [kind, sizeText]
        if let modified { parts.append(modified.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    static func load(_ url: URL, isDirectory: Bool? = nil) -> FileEntry {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey])
        let directory = isDirectory ?? ((values?.isDirectory ?? false) && !(values?.isPackage ?? false))
        var count: Int?
        if directory {
            count = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.filter { $0 != ".DS_Store" }.count
        }
        return FileEntry(url: url, isDirectory: directory, size: values?.fileSize ?? 0, modified: values?.contentModificationDate, created: values?.creationDate, childCount: count)
    }
}

enum BrowserSort: String, CaseIterable, Identifiable {
    case name, date, size, kind

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .name: return "Name"
        case .date: return "Date Modified"
        case .size: return "Size"
        case .kind: return "Kind"
        }
    }

    func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { a, b in
            // Folders always come first.
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch self {
            case .name: break
            case .date:
                if a.modified != b.modified { return (a.modified ?? .distantPast) > (b.modified ?? .distantPast) }
            case .size:
                if a.size != b.size { return a.size > b.size }
            case .kind:
                let x = a.fileExtension.lowercased(), y = b.fileExtension.lowercased()
                if x != y { return x < y }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// The contents of one folder, read off the main thread.
final class FolderListing: ObservableObject {
    let url: URL
    @Published private(set) var entries: [FileEntry] = []
    @Published private(set) var isLoading = true
    @Published private(set) var error: String?

    init(url: URL) {
        self.url = url
    }

    func reload(showHidden: Bool) {
        let url = url
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> [FileEntry] in
                let items = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey],
                    options: showHidden ? [] : [.skipsHiddenFiles]
                )
                return items.filter { $0.lastPathComponent != ".DS_Store" }.map { FileEntry.load($0) }
            }
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let entries):
                    self.entries = entries
                    self.error = nil
                case .failure(let failure):
                    self.entries = []
                    self.error = failure.localizedDescription
                }
            }
        }
    }
}

/// Reads the start of a file for previews.
enum FilePeek {
    /// The first part of a text file, cut at a line break, or nil when the file is not text.
    static func textPrefix(_ url: URL, limit: Int = 60_000) -> String? {
        FileAccess.withAccess(url) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            var data = (try? handle.read(upToCount: limit)) ?? Data()
            if data.count == limit, let lineBreak = data.lastIndex(of: 0x0A) { data = Data(data[data.startIndex..<lineBreak]) }
            guard let detected = TextEncoding.detect(data) else { return nil }
            return LineEnding.normalize(detected.text)
        }
    }

    static func bytesPrefix(_ url: URL, limit: Int = 4096) -> Data {
        FileAccess.withAccess(url) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
            defer { try? handle.close() }
            return (try? handle.read(upToCount: limit)) ?? Data()
        }
    }
}

// MARK: - Browser

/// A full-screen file browser for the open folder: one folder per page, full-width rows, and on a
/// wide screen a preview of the selected file beside the list.
struct BrowserView: View {
    @EnvironmentObject private var model: AppModel
    let root: URL
    @State private var path: [URL] = []
    @State private var selection: FileEntry?

    var body: some View {
        GeometryReader { proxy in
            // Wide enough for a list and a preview side by side: an unfolded phone or an iPad.
            let wide = proxy.size.width >= 600
            HStack(spacing: 0) {
                NavigationStack(path: $path) {
                    FolderPage(url: root, root: root, wide: wide, selection: $selection, open: open, popTo: popTo)
                        .navigationDestination(for: URL.self) { folder in
                            FolderPage(url: folder, root: root, wide: wide, selection: $selection, open: open, popTo: popTo)
                        }
                }
                .frame(width: wide ? min(max(300, proxy.size.width * 0.44), 460) : nil)
                if wide {
                    Divider()
                    NavigationStack {
                        PreviewPane(entry: selection, open: open)
                    }
                }
            }
        }
        .onAppear {
            #if DEBUG
            DebugLaunch.applyBrowser(root: root, path: &path, selection: &selection)
            #endif
        }
    }

    private func open(_ url: URL) {
        model.open(url)
        model.showBrowser = false
    }

    /// Goes back up to one of the folders above the current page.
    private func popTo(_ folder: URL) {
        let target = folder.standardizedFileURL
        if target == root.standardizedFileURL {
            path = []
        } else if let index = path.firstIndex(where: { $0.standardizedFileURL == target }) {
            path = Array(path[...index])
        }
    }
}

private struct FolderPage: View {
    let url: URL
    let root: URL
    let wide: Bool
    @Binding var selection: FileEntry?
    let open: (URL) -> Void
    let popTo: (URL) -> Void

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var listing: FolderListing
    @AppStorage("browserSort") private var sort = BrowserSort.name
    @State private var query = ""
    @State private var prompt: NamePrompt?
    @State private var promptTarget: FileEntry?
    @State private var name = ""
    @State private var info: FileEntry?
    @State private var deleting: FileEntry?
    @State private var showFolderSearch = false
    /// Shown here, not through the app-wide alert, which sits underneath the full-screen browser.
    @State private var failure: AppAlert?

    private enum NamePrompt: Identifiable {
        case newFile, newFolder, rename
        var id: Int { hashValue }
    }

    init(url: URL, root: URL, wide: Bool, selection: Binding<FileEntry?>, open: @escaping (URL) -> Void, popTo: @escaping (URL) -> Void) {
        self.url = url
        self.root = root
        self.wide = wide
        _selection = selection
        self.open = open
        self.popTo = popTo
        _listing = StateObject(wrappedValue: FolderListing(url: url))
    }

    private var shown: [FileEntry] {
        let sorted = sort.sorted(listing.entries)
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// The folders from the root down to this one, for jumping back up.
    private var ancestors: [URL] {
        var result: [URL] = []
        var current = url.standardizedFileURL
        let top = root.standardizedFileURL
        while current.path.count > top.path.count, current.path.hasPrefix(top.path) {
            current = current.deletingLastPathComponent()
            result.append(current)
        }
        return result
    }

    var body: some View {
        List {
            if let error = listing.error {
                Text(verbatim: error)
                    .foregroundStyle(.secondary)
            }
            ForEach(shown) { entry in
                row(entry)
            }
        }
        .listStyle(.plain)
        .overlay {
            if listing.isLoading {
                ProgressView()
            } else if shown.isEmpty, listing.error == nil {
                if query.isEmpty {
                    ContentUnavailableView("Empty Folder", systemImage: "folder", description: Text("Create a file here, or go back and pick another folder."))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("Filter by Name"))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .refreshable { listing.reload(showHidden: settings.showHiddenFiles) }
        .onAppear { listing.reload(showHidden: settings.showHiddenFiles) }
        .onChange(of: settings.showHiddenFiles) { _, hidden in listing.reload(showHidden: hidden) }
        .alert(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { kind in
            TextField("Name", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button(kind == .rename ? "Rename" : "Create") { perform(kind) }
        }
        .confirmationDialog(
            "Delete?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { entry in
            Button("Delete", role: .destructive) { delete(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("“\(entry.name)” will be deleted. This cannot be undone.")
        }
        .sheet(item: $info) { entry in
            FileInfoSheet(entry: entry, root: root)
        }
        .sheet(isPresented: $showFolderSearch) {
            FolderSearchView()
        }
        .alert(item: $failure) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ entry: FileEntry) -> some View {
        Group {
            if entry.isDirectory {
                NavigationLink(value: entry.url) {
                    EntryLabel(entry: entry, isOpen: false)
                }
            } else {
                Button {
                    if wide {
                        selection = entry
                    } else {
                        open(entry.url)
                    }
                } label: {
                    EntryLabel(entry: entry, isOpen: isOpen(entry))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded { open(entry.url) })
                .listRowBackground(wide && selection?.url == entry.url ? Color.accentColor.opacity(0.16) : nil)
            }
        }
        .contextMenu {
            actions(for: entry)
        } preview: {
            FilePeekCard(entry: entry)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleting = entry
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                beginRename(entry)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .leading) {
            Button {
                info = entry
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }
            .tint(.blue)
        }
    }

    @ViewBuilder
    private func actions(for entry: FileEntry) -> some View {
        if !entry.isDirectory {
            Button {
                open(entry.url)
            } label: {
                Label("Open in Editor", systemImage: "square.and.pencil")
            }
        }
        Button {
            info = entry
        } label: {
            Label("Get Info", systemImage: "info.circle")
        }
        Button {
            UIPasteboard.general.string = entry.name
        } label: {
            Label("Copy Name", systemImage: "doc.on.doc")
        }
        ShareLink(item: entry.url)
        Divider()
        Button {
            beginRename(entry)
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        if !entry.isDirectory {
            Button {
                duplicate(entry)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
        }
        Button(role: .destructive) {
            deleting = entry
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if url == root {
                Button("Done") { model.showBrowser = false }
            }
        }
        ToolbarItem(placement: .principal) {
            // The title doubles as a menu of the folders above this one.
            Menu {
                ForEach(ancestors, id: \.self) { folder in
                    Button {
                        popTo(folder)
                    } label: {
                        Label(folder.lastPathComponent, systemImage: "folder")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(verbatim: url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !ancestors.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                }
                .foregroundStyle(.primary)
            }
            .disabled(ancestors.isEmpty)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Section {
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
                Section {
                    Picker("Sort By", selection: $sort) {
                        ForEach(BrowserSort.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle(isOn: $settings.showHiddenFiles) {
                        Label("Show Hidden Files", systemImage: "eye")
                    }
                }
                Section {
                    Button {
                        showFolderSearch = true
                    } label: {
                        Label("Find in Folder…", systemImage: "doc.text.magnifyingglass")
                    }
                    Button {
                        info = FileEntry.load(url, isDirectory: true)
                    } label: {
                        Label("Folder Info", systemImage: "info.circle")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: Actions

    private func isOpen(_ entry: FileEntry) -> Bool {
        model.documents.contains { $0.url?.standardizedFileURL == entry.url.standardizedFileURL }
    }

    private var promptTitle: LocalizedStringKey {
        switch prompt {
        case .newFile: return "New File"
        case .newFolder: return "New Folder"
        case .rename: return "Rename"
        case nil: return ""
        }
    }

    private func beginRename(_ entry: FileEntry) {
        promptTarget = entry
        name = entry.name
        prompt = .rename
    }

    private func fail(_ error: Error) {
        failure = AppAlert(title: String(localized: "Could Not Complete"), message: error.localizedDescription)
    }

    private func perform(_ kind: NamePrompt) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return }
        let manager = FileManager.default
        do {
            switch kind {
            case .newFile:
                let target = url.appendingPathComponent(trimmed)
                guard !manager.fileExists(atPath: target.path) else { throw FileAccess.Failure(message: String(localized: "An item with that name already exists.")) }
                try Data().write(to: target)
                listing.reload(showHidden: settings.showHiddenFiles)
                open(target)
            case .newFolder:
                try manager.createDirectory(at: url.appendingPathComponent(trimmed), withIntermediateDirectories: false)
                listing.reload(showHidden: settings.showHiddenFiles)
            case .rename:
                guard let entry = promptTarget else { return }
                let target = entry.url.deletingLastPathComponent().appendingPathComponent(trimmed)
                guard target != entry.url else { return }
                guard !manager.fileExists(atPath: target.path) else { throw FileAccess.Failure(message: String(localized: "An item with that name already exists.")) }
                let openDocument = model.documents.first { $0.url?.standardizedFileURL == entry.url.standardizedFileURL }
                openDocument?.autosave()
                try manager.moveItem(at: entry.url, to: target)
                if let openDocument {
                    openDocument.adopt(url: target)
                    model.saveSession()
                }
                if selection?.url == entry.url { selection = FileEntry.load(target) }
                listing.reload(showHidden: settings.showHiddenFiles)
            }
        } catch {
            fail(error)
        }
    }

    private func duplicate(_ entry: FileEntry) {
        let folder = entry.url.deletingLastPathComponent()
        let base = entry.url.deletingPathExtension().lastPathComponent
        let ext = entry.fileExtension
        var index = 1
        var target: URL
        repeat {
            let suffix = index == 1 ? String(localized: " copy") : String(localized: " copy \(index)")
            target = folder.appendingPathComponent(base + suffix + (ext.isEmpty ? "" : "." + ext))
            index += 1
        } while FileManager.default.fileExists(atPath: target.path) && index < 500
        do {
            try FileManager.default.copyItem(at: entry.url, to: target)
            listing.reload(showHidden: settings.showHiddenFiles)
        } catch {
            fail(error)
        }
    }

    private func delete(_ entry: FileEntry) {
        do {
            let prefix = entry.url.standardizedFileURL.path
            // Close what is about to disappear, including files inside a deleted folder.
            for document in model.documents {
                guard let path = document.url?.standardizedFileURL.path else { continue }
                if path == prefix || path.hasPrefix(prefix + "/") {
                    document.isDirty = false
                    model.close(document)
                }
            }
            try FileManager.default.removeItem(at: entry.url)
            if selection?.url == entry.url { selection = nil }
            listing.reload(showHidden: settings.showHiddenFiles)
        } catch {
            fail(error)
        }
    }
}

/// Icon, full name and a line of facts. The name wraps instead of being cut.
private struct EntryLabel: View {
    let entry: FileEntry
    let isOpen: Bool

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(name: entry.name, isFolder: entry.isDirectory)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: entry.name)
                    .font(.body)
                    .fontWeight(isOpen ? .semibold : .regular)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .truncationMode(.middle)
                Text(verbatim: entry.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isOpen {
                Circle()
                    .fill(.tint)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(Text("Open"))
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Previews

/// A thumbnail from the system, for pictures, PDFs and documents.
private struct Thumbnail: View {
    let url: URL
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                Image(systemName: FileNode.symbol(for: url.lastPathComponent))
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 600, height: 600), scale: displayScale, representationTypes: .thumbnail)
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = representation.uiImage
            } else {
                failed = true
            }
        }
    }
}

/// What a file holds, without opening it as a document: text, a thumbnail, or the first bytes.
private struct FileContentPreview: View {
    let entry: FileEntry
    /// The context-menu card uses a thumbnail; the pane uses the live previewer.
    let live: Bool
    @State private var text: String?
    @State private var bytes: Data?
    @State private var loaded = false

    var body: some View {
        Group {
            if entry.isDirectory {
                VStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                    Text(verbatim: entry.summary)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if FileKind.canPreview(entry.url) {
                if live {
                    QuickLookView(url: entry.url)
                        .id(entry.url)
                } else {
                    Thumbnail(url: entry.url)
                        .padding(12)
                }
            } else if let text {
                ScrollView {
                    Text(verbatim: text.isEmpty ? String(localized: "Empty File") : text)
                        .font(.system(size: live ? 13 : 11, design: .monospaced))
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                }
            } else if let bytes {
                HexView(data: bytes)
            } else if loaded {
                ContentUnavailableView("No Preview", systemImage: "eye.slash")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: entry.url) {
            guard !entry.isDirectory, !FileKind.canPreview(entry.url) else { return }
            let url = entry.url
            let limit = live ? 200_000 : 6000
            let result = await Task.detached { () -> (String?, Data?) in
                if FileKind.isMedia(url) { return (nil, FilePeek.bytesPrefix(url)) }
                if let text = FilePeek.textPrefix(url, limit: limit) { return (text, nil) }
                return (nil, FilePeek.bytesPrefix(url))
            }.value
            text = result.0
            bytes = result.1
            loaded = true
        }
    }
}

/// The long-press card: the whole file name, its facts, and the start of its contents.
private struct FilePeekCard: View {
    let entry: FileEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: entry.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: entry.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            FileContentPreview(entry: entry, live: false)
                .frame(height: entry.isDirectory ? 140 : 320)
        }
        .frame(width: 340)
        .background(Color(uiColor: .systemBackground))
    }
}

/// The right-hand side on a wide screen: look at the selected file before opening it.
private struct PreviewPane: View {
    let entry: FileEntry?
    let open: (URL) -> Void

    var body: some View {
        Group {
            if let entry {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        FileIcon(name: entry.name, isFolder: entry.isDirectory)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: entry.name)
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Text(verbatim: entry.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    Divider()
                    FileContentPreview(entry: entry, live: true)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            open(entry.url)
                        } label: {
                            Label("Open in Editor", systemImage: "square.and.pencil")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                ContentUnavailableView("Select a File", systemImage: "doc.text.magnifyingglass", description: Text("Tap a file to look at it here. Double-tap to open it in the editor."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Name, kind, size, dates and location of one item.
struct FileInfoSheet: View {
    let entry: FileEntry
    let root: URL
    @Environment(\.dismiss) private var dismiss
    @State private var lines: Int?
    @State private var encoding: String?

    private var location: String {
        let top = root.standardizedFileURL.deletingLastPathComponent().path
        let folder = entry.url.standardizedFileURL.deletingLastPathComponent().path
        if folder.hasPrefix(top) { return String(folder.dropFirst(top.count).drop { $0 == "/" }) }
        return FileAccess.displayLocation(entry.url)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        FileIcon(name: entry.name, isFolder: entry.isDirectory)
                        Text(verbatim: entry.name)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                Section {
                    LabeledContent("Kind", value: entry.kind)
                    if !entry.isDirectory {
                        LabeledContent("Extension", value: entry.fileExtension.isEmpty ? String(localized: "None") : "." + entry.fileExtension)
                        LabeledContent("Size", value: entry.sizeText + " · " + String(localized: "\(entry.size.formatted()) bytes"))
                        if let lines { LabeledContent("Lines", value: lines.formatted()) }
                        if let encoding { LabeledContent("Encoding", value: encoding) }
                    } else if let count = entry.childCount {
                        LabeledContent("Contains", value: String(localized: "\(count) items"))
                    }
                }
                Section {
                    if let modified = entry.modified {
                        LabeledContent("Modified", value: modified.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let created = entry.created {
                        LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Where", value: location)
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            // Line count and encoding only for text files of a reasonable size.
            guard !entry.isDirectory, entry.size < 8_000_000, !FileKind.isMedia(entry.url) else { return }
            let url = entry.url
            let result = await Task.detached { () -> (Int, String)? in
                guard let data = try? FileAccess.read(url), let detected = TextEncoding.detect(data) else { return nil }
                return (TextStatistics(detected.text).lines, detected.encoding.name)
            }.value
            lines = result?.0
            encoding = result?.1
        }
    }
}
