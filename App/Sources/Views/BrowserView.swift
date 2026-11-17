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
                    FolderPage(url: root, root: root, wide: wide, selection: $selection, open: open, popTo: popTo, push: { path.append($0) })
                        .navigationDestination(for: URL.self) { folder in
                            FolderPage(url: folder, root: root, wide: wide, selection: $selection, open: open, popTo: popTo, push: { path.append($0) })
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
    let push: (URL) -> Void

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var listing: FolderListing
    @AppStorage("browserSort") private var sort = BrowserSort.name
    @AppStorage("browserGrid") private var showsGrid = false
    @State private var query = ""
    @State private var prompt: NamePrompt?
    @State private var promptTarget: FileEntry?
    @State private var name = ""
    @State private var info: FileEntry?
    @State private var showFolderSearch = false
    /// Shown here, not through the app-wide alert, which sits underneath the full-screen browser.
    @State private var failure: AppAlert?

    // Selecting several items
    @State private var isSelecting = false
    @State private var picked: Set<URL> = []
    // Items waiting for a confirmation or for the system's move sheet
    @State private var deleting: [FileEntry] = []
    @State private var moving: [URL] = []
    @State private var isMoving = false
    /// Shown over the list while an archive is being written or unpacked.
    @State private var busy: String?

    private enum NamePrompt: Identifiable {
        case newFile, newFolder, rename
        var id: Int { hashValue }
    }

    init(url: URL, root: URL, wide: Bool, selection: Binding<FileEntry?>, open: @escaping (URL) -> Void, popTo: @escaping (URL) -> Void, push: @escaping (URL) -> Void) {
        self.url = url
        self.root = root
        self.wide = wide
        _selection = selection
        self.open = open
        self.popTo = popTo
        self.push = push
        _listing = StateObject(wrappedValue: FolderListing(url: url))
    }

    private var shown: [FileEntry] {
        let sorted = sort.sorted(listing.entries)
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var pickedEntries: [FileEntry] {
        listing.entries.filter { picked.contains($0.url) }
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
        Group {
            if showsGrid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 10)], spacing: 14) {
                        ForEach(shown) { entry in
                            cell(entry)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            } else {
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
            }
        }
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
        .overlay {
            if let busy {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(verbatim: busy)
                        .font(.footnote)
                }
                .padding(22)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .disabled(busy != nil)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("Filter by Name"))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .toolbar(isSelecting ? .visible : .hidden, for: .bottomBar)
        .refreshable { reload() }
        .onAppear { reload() }
        .onChange(of: settings.showHiddenFiles) { _, _ in reload() }
        .alert(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { kind in
            TextField("Name", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button(kind == .rename ? "Rename" : "Create") { perform(kind) }
        }
        .confirmationDialog(
            deleting.count == 1 ? "Delete?" : "Delete \(deleting.count) Items?",
            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete(deleting) }
            Button("Cancel", role: .cancel) {}
        } message: {
            if deleting.count == 1, let entry = deleting.first {
                Text("“\(entry.name)” will be deleted. This cannot be undone.")
            } else {
                Text("This cannot be undone.")
            }
        }
        .fileMover(isPresented: $isMoving, files: moving) { result in
            finishMove(result)
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

    // MARK: Rows and cells

    private func tap(_ entry: FileEntry) {
        if isSelecting {
            if picked.contains(entry.url) { picked.remove(entry.url) } else { picked.insert(entry.url) }
        } else if entry.isDirectory {
            push(entry.url)
        } else if wide {
            selection = entry
        } else {
            open(entry.url)
        }
    }

    private func mark(_ entry: FileEntry) -> some View {
        Image(systemName: picked.contains(entry.url) ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(picked.contains(entry.url) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
    }

    private func row(_ entry: FileEntry) -> some View {
        Button {
            tap(entry)
        } label: {
            HStack(spacing: 10) {
                if isSelecting { mark(entry) }
                EntryLabel(entry: entry, isOpen: isOpen(entry))
                if entry.isDirectory, !isSelecting {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if !isSelecting, !entry.isDirectory { open(entry.url) }
        })
        .listRowBackground(!isSelecting && wide && selection?.url.standardizedFileURL.path == entry.url.standardizedFileURL.path ? Color.accentColor.opacity(0.16) : nil)
        .contextMenu {
            actions(for: entry)
        } preview: {
            FilePeekCard(entry: entry)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleting = [entry]
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

    private func cell(_ entry: FileEntry) -> some View {
        Button {
            tap(entry)
        } label: {
            GridCell(entry: entry, isOpen: isOpen(entry), isHighlighted: !isSelecting && wide && selection?.url.standardizedFileURL.path == entry.url.standardizedFileURL.path)
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        mark(entry)
                            .background(Color(uiColor: .systemBackground), in: Circle())
                            .padding(6)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if !isSelecting, !entry.isDirectory { open(entry.url) }
        })
        .contextMenu {
            actions(for: entry)
        } preview: {
            FilePeekCard(entry: entry)
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
        Button {
            beginMove([entry.url])
        } label: {
            Label("Move…", systemImage: "folder")
        }
        if !entry.isDirectory {
            Button {
                duplicate([entry])
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
        }
        if Archives.isArchive(entry.url) {
            Button {
                extract(entry)
            } label: {
                Label("Extract", systemImage: "arrow.up.bin")
            }
        }
        Button {
            compress([entry.url])
        } label: {
            Label("Compress", systemImage: "archivebox")
        }
        Button {
            isSelecting = true
            picked = [entry.url]
        } label: {
            Label("Select", systemImage: "checkmark.circle")
        }
        Button(role: .destructive) {
            deleting = [entry]
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isSelecting {
                Button(picked.count == shown.count && !shown.isEmpty ? "Deselect All" : "Select All") {
                    picked = picked.count == shown.count ? [] : Set(shown.map(\.url))
                }
            } else if url == root {
                Button("Done") { model.showBrowser = false }
            }
        }
        ToolbarItem(placement: .principal) {
            if isSelecting {
                Text("\(picked.count) Selected")
                    .font(.headline)
            } else {
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
        }
        ToolbarItem(placement: .primaryAction) {
            if isSelecting {
                Button("Done") {
                    isSelecting = false
                    picked = []
                }
                .fontWeight(.semibold)
            } else {
                Menu {
                    Section {
                        Button {
                            isSelecting = true
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
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
                        Picker("View", selection: $showsGrid) {
                            Label("List", systemImage: "list.bullet").tag(false)
                            Label("Grid", systemImage: "square.grid.2x2").tag(true)
                        }
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
        ToolbarItemGroup(placement: .bottomBar) {
            if isSelecting {
                Button {
                    beginMove(Array(picked))
                } label: {
                    Label("Move", systemImage: "folder")
                }
                .disabled(picked.isEmpty)
                Spacer()
                ShareLink(items: Array(picked)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(picked.isEmpty)
                Spacer()
                Button {
                    duplicate(pickedEntries.filter { !$0.isDirectory })
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .disabled(pickedEntries.allSatisfy(\.isDirectory))
                Spacer()
                Button {
                    compress(Array(picked))
                } label: {
                    Label("Compress", systemImage: "archivebox")
                }
                .disabled(picked.isEmpty)
                Spacer()
                Button(role: .destructive) {
                    deleting = pickedEntries
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(picked.isEmpty)
            }
        }
    }

    // MARK: Actions

    private func reload() {
        listing.reload(showHidden: settings.showHiddenFiles)
    }

    private func endSelection() {
        isSelecting = false
        picked = []
    }

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

    /// Open documents at or below `url`.
    private func documents(under url: URL) -> [EditorDocument] {
        let prefix = url.standardizedFileURL.path
        return model.documents.filter { document in
            guard let path = document.url?.standardizedFileURL.path else { return false }
            return path == prefix || path.hasPrefix(prefix + "/")
        }
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
                reload()
                open(target)
            case .newFolder:
                try manager.createDirectory(at: url.appendingPathComponent(trimmed), withIntermediateDirectories: false)
                reload()
            case .rename:
                guard let entry = promptTarget else { return }
                let target = entry.url.deletingLastPathComponent().appendingPathComponent(trimmed)
                guard target != entry.url else { return }
                guard !manager.fileExists(atPath: target.path) else { throw FileAccess.Failure(message: String(localized: "An item with that name already exists.")) }
                try relocate(entry.url, to: target) { try manager.moveItem(at: entry.url, to: target) }
                if selection?.url == entry.url { selection = FileEntry.load(target) }
                reload()
            }
        } catch {
            fail(error)
        }
    }

    /// Runs `move` and keeps open documents pointing at their files: one that was `old` itself, or
    /// inside it when `old` is a folder.
    private func relocate(_ old: URL, to new: URL, move: () throws -> Void) throws {
        let affected = documents(under: old)
        affected.forEach { $0.autosave() }
        let oldPath = old.standardizedFileURL.path
        let targets = affected.map { document -> URL in
            let path = document.url!.standardizedFileURL.path
            let rest = String(path.dropFirst(oldPath.count))
            return rest.isEmpty ? new : new.appendingPathComponent(String(rest.dropFirst()))
        }
        try move()
        for (document, target) in zip(affected, targets) { document.adopt(url: target) }
        if !affected.isEmpty { model.saveSession() }
    }

    private func duplicate(_ entries: [FileEntry]) {
        do {
            for entry in entries {
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
                try FileManager.default.copyItem(at: entry.url, to: target)
            }
        } catch {
            fail(error)
        }
        endSelection()
        reload()
    }

    private func delete(_ entries: [FileEntry]) {
        do {
            for entry in entries {
                // Close what is about to disappear, including files inside a deleted folder.
                for document in documents(under: entry.url) {
                    document.isDirty = false
                    model.close(document)
                }
                try FileManager.default.removeItem(at: entry.url)
                if selection?.url == entry.url { selection = nil }
            }
        } catch {
            fail(error)
        }
        deleting = []
        endSelection()
        reload()
    }

    private func compress(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        documents(underAny: urls).forEach { $0.autosave() }
        busy = String(localized: "Compressing…")
        let archiveName = String(localized: "Archive")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Archives.compress(urls, archiveName: archiveName) }
            DispatchQueue.main.async { finishArchive(result) }
        }
    }

    private func extract(_ entry: FileEntry) {
        busy = String(localized: "Extracting…")
        let url = entry.url
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Archives.extract(url) }
            DispatchQueue.main.async { finishArchive(result) }
        }
    }

    private func finishArchive(_ result: Result<URL, Error>) {
        busy = nil
        if case .failure(let error) = result { fail(error) }
        endSelection()
        reload()
    }

    /// Hands the items to the system's move sheet, which can put them in any folder the user can reach.
    private func beginMove(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        documents(underAny: urls).forEach { $0.autosave() }
        moving = urls
        isMoving = true
    }

    private func documents(underAny urls: [URL]) -> [EditorDocument] {
        urls.flatMap { documents(under: $0) }
    }

    private func finishMove(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let destinations):
            // The sheet returns the new locations in the order the items were given.
            for (old, new) in zip(moving, destinations) {
                let oldPath = old.standardizedFileURL.path
                for document in documents(under: old) {
                    let rest = String(document.url!.standardizedFileURL.path.dropFirst(oldPath.count))
                    document.adopt(url: rest.isEmpty ? new : new.appendingPathComponent(String(rest.dropFirst())))
                }
                if selection?.url == old { selection = nil }
            }
            model.saveSession()
        case .failure(let error):
            // Cancelling the sheet is not an error worth showing.
            if (error as NSError).code != NSUserCancelledError { fail(error) }
        }
        moving = []
        endSelection()
        reload()
    }
}

/// One item in the grid: a thumbnail or a large icon above the name.
private struct GridCell: View {
    let entry: FileEntry
    let isOpen: Bool
    let isHighlighted: Bool

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if !entry.isDirectory, FileKind.canPreview(entry.url) {
                    Thumbnail(url: entry.url)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: entry.isDirectory ? "folder.fill" : FileNode.symbol(for: entry.name))
                        .font(.system(size: 38, weight: .regular))
                        .foregroundStyle(entry.isDirectory ? Color.accentColor : FileNode.tint(for: entry.name))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            (entry.isDirectory ? Color.accentColor : FileNode.tint(for: entry.name)).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                }
            }
            .frame(height: 78)
            Text(verbatim: entry.name)
                .font(.caption)
                .fontWeight(isOpen ? .semibold : .regular)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
            Text(verbatim: entry.isDirectory ? entry.summary : entry.sizeText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(isHighlighted ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            } else if Archives.isArchive(entry.url) {
                ArchiveContents(url: entry.url)
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
            guard !entry.isDirectory, !FileKind.canPreview(entry.url), !Archives.isArchive(entry.url) else { return }
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

/// The files inside a zip archive, listed without unpacking it.
struct ArchiveContents: View {
    let url: URL
    @State private var items: [Archives.Item]?
    @State private var total = 0
    @State private var failed = false

    var body: some View {
        Group {
            if let items {
                List {
                    ForEach(items) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.isDirectory ? "folder" : "doc")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text(verbatim: item.path)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Spacer(minLength: 6)
                            if !item.isDirectory {
                                Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    }
                    if total > items.count {
                        Text("and \(total - items.count) more items")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 26)
            } else if failed {
                ContentUnavailableView("No Preview", systemImage: "archivebox", description: Text("This archive could not be read."))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            let url = url
            let result = await Task.detached { Archives.contents(of: url) }.value
            if let result {
                items = result.items
                total = result.total
            } else {
                failed = true
            }
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
