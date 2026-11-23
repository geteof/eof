import SwiftUI
import EOFCore
import UniformTypeIdentifiers

/// Raw bytes handed to the system exporter.
struct DataFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .plainText] }
    static var writableContentTypes: [UTType] { [.data, .plainText] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum EditorSheet: String, Identifiable {
    case outline, statistics, compare, language
    var id: String { rawValue }
}

struct EditorScreen: View {
    @ObservedObject var document: EditorDocument
    /// The first pane uses the window's navigation bar; the second draws its own header.
    var pane: EditorPane = .primary
    let startImport: () -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var window: WindowState
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showFind = false
    @State private var findWithReplace = false
    @State private var viewMode = ViewMode.source
    @State private var showHex = false
    @StateObject private var bars = BarVisibility()
    @State private var sheet: EditorSheet?
    @State private var showGoToLine = false
    @State private var goToLineText = ""
    @State private var exportFile: DataFile?
    @State private var isExporting = false
    @State private var transformError: String?

    private var canPreview: Bool {
        !document.isBinary && (document.language.id == "markdown" || document.language.id == "html" || document.language.id == "xml" && document.name.lowercased().hasSuffix(".svg"))
    }

    /// What the screen shows: side by side falls back to the preview alone when the window is
    /// too narrow for two readable columns, and documents without a preview show their source.
    private func shownMode(sideBySide: Bool) -> ViewMode {
        guard canPreview else { return .source }
        return viewMode == .sideBySide && !sideBySide ? .preview : viewMode
    }

    var body: some View {
        GeometryReader { proxy in
            let sideBySide = proxy.size.width >= 700
            VStack(spacing: 0) {
                if pane == .secondary {
                    if !bars.hidden {
                        secondaryHeader
                        Divider()
                    }
                } else if model.documents.count > 1, !bars.hidden {
                    TabStrip()
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Divider()
                }
                if let notice = document.notice {
                    NoticeBar(text: notice) { document.notice = nil }
                    Divider()
                }
                if showFind, !document.isBinary {
                    FindBar(document: document, withReplace: $findWithReplace) { showFind = false }
                    Divider()
                }
                content(sideBySide: sideBySide)
                if !bars.hidden {
                    Divider()
                    StatusBar(document: document, status: document.status, sheet: $sheet, viewMode: canPreview ? modeBinding(sideBySide: sideBySide) : nil, allowsSideBySide: sideBySide,
                              onFind: findInStatusBar ? { toggleFind(replace: false) } : nil) {
                        goToLineText = ""
                        showGoToLine = true
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // A thin line marks the pane that menu commands and the keyboard go to.
            .overlay(alignment: .top) {
                if window.isSplit, window.focusedPane == pane {
                    Rectangle()
                        .fill(.tint)
                        .frame(height: 2)
                }
            }
        }
        // With the bars away, the text runs under the clock and down to the screen's bottom edge,
        // as a page does in Safari. Only for a window showing one pane.
        .ignoresSafeArea(.container, edges: bars.hidden && !window.isSplit ? [.top, .bottom] : [])
        .modifier(PaneChrome(isPrimary: pane == .primary, title: document.name, titleMenu: titleMenu, toolbar: toolbarButtons))
        .toolbar(pane == .primary && bars.hidden ? .hidden : .automatic, for: .navigationBar)
        // The clock and signal go with the bars. The window's root applies it: set inside the
        // split view, the status bar preference never reaches the system.
        .onChange(of: bars.hidden) { _, hidden in if pane == .primary { window.setBarsHidden(hidden, by: document.id) } }
        .onAppear { if pane == .primary { window.setBarsHidden(bars.hidden, by: document.id) } }
        .onDisappear { window.releaseBars(by: document.id) }
        .onChange(of: showFind) { _, shown in if shown { bars.reveal() } }
        .onChange(of: settings.hideBarsOnScroll) { _, on in if !on { bars.reveal() } }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .outline: OutlineSheet(document: document)
            case .statistics: StatisticsSheet(document: document)
            case .compare: CompareSheet(document: document)
            case .language: LanguagePicker(document: document)
            }
        }
        .alert("Go to Line", isPresented: $showGoToLine) {
            TextField("Line or line:column", text: $goToLineText)
                .keyboardType(.numbersAndPunctuation)
            Button("Cancel", role: .cancel) {}
            Button("Go") { goToLine() }
        } message: {
            Text("1 – \(document.status.lines)")
        }
        .alert("Transform Failed", isPresented: Binding(get: { transformError != nil }, set: { if !$0 { transformError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: transformError ?? "")
        }
        .alert("“\(document.name)” Changed on Disk", isPresented: $document.hasConflict) {
            Button("Keep My Version") { document.resolveConflictKeepingMine() }
            Button("Reload from Disk", role: .destructive) { document.resolveConflictReloading() }
        } message: {
            Text("Another app changed this file while you were editing it.")
        }
        .alert("Could Not Save", isPresented: Binding(get: { document.saveError != nil && !isExporting }, set: { if !$0 { document.saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: document.saveError ?? "")
        }
        .fileExporter(isPresented: $isExporting, document: exportFile, contentType: (document.name as NSString).pathExtension.isEmpty ? .plainText : .data, defaultFilename: document.name) { result in
            exportFile = nil
            switch result {
            case .success(let url):
                if document.isUntitled {
                    document.adopt(url: url)
                    model.saveSession()
                } else {
                    model.open(url, in: window)
                }
            case .failure(let error):
                model.alert = AppAlert(title: String(localized: "Could Not Save"), message: error.localizedDescription)
            }
        }
        .onReceive(window.commands) { command in
            if !window.isSplit || window.focusedPane == pane { handle(command) }
        }
        .onAppear {
            if settings.openInPreview, canPreview { viewMode = .preview }
            document.controller.onScroll = { [bars, settings] report in
                guard settings.hideBarsOnScroll else { return }
                bars.scrolled(report)
            }
            // Weak, so a closed window is not kept alive by a document it once showed.
            let ownWindow = window
            let ownModel = model
            let ownPane = pane
            document.controller.onFocus = { [weak ownWindow, weak ownModel] in
                guard let ownWindow else { return }
                ownModel?.focusedWindow = ownWindow
                ownWindow.focusedPane = ownPane
            }
            #if DEBUG
            DebugLaunch.apply(to: document, showFind: &showFind, findWithReplace: &findWithReplace, viewMode: &viewMode, sheet: &sheet)
            if ProcessInfo.processInfo.arguments.contains("-hidebars") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { bars.debugHide() }
            }
            #endif
        }
        .onChange(of: document.language) { _, _ in
            if !canPreview { viewMode = .source }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(sideBySide: Bool) -> some View {
        if document.isBinary {
            if let url = document.url, !showHex, url.pathExtension.lowercased() == "pdf" {
                PDFPreview(url: url) { [bars, settings] report in
                    guard settings.hideBarsOnScroll else { return }
                    bars.scrolled(report)
                }
                .id(url)
            } else if let url = document.url, !showHex, FileKind.canPreview(url) {
                QuickLookView(url: url)
                    .id(url)
            } else if let data = document.binary {
                HexView(data: data)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { document.loadBinaryData() }
            }
        } else {
            switch shownMode(sideBySide: sideBySide) {
            case .source:
                editor
            case .preview:
                preview
            case .sideBySide:
                HStack(spacing: 0) {
                    editor
                    Divider()
                    preview
                }
            }
        }
    }

    /// The mode the status bar shows and sets: what is on screen, so a side-by-side choice
    /// that does not fit reads as Preview.
    private func modeBinding(sideBySide: Bool) -> Binding<ViewMode> {
        Binding(
            get: { shownMode(sideBySide: sideBySide) },
            set: { mode in withAnimation(.snappy(duration: 0.2)) { viewMode = mode } }
        )
    }

    private var preview: some View {
        PreviewView(document: document) { [bars, settings] report in
            guard settings.hideBarsOnScroll else { return }
            bars.scrolled(report)
        }
    }

    private var editor: some View {
        EditorHost(
            document: document,
            isDark: colorScheme == .dark,
            settingsStamp: settings.editorStamp ^ document.indent.width ^ (document.indent.usesTabs ? 1 << 19 : 0) ^ (document.isReadOnly ? 1 << 20 : 0)
        )
        .background(Color(uiColor: settings.theme(dark: colorScheme == .dark).background).ignoresSafeArea(.container, edges: .horizontal))
    }

    // MARK: - Toolbar

    /// The find and more buttons: in the navigation bar for the first pane, in the header for
    /// the second. Source, preview and side by side are switched in the status bar.
    @ViewBuilder
    private var toolbarButtons: some View {
            if !document.isBinary, !findInStatusBar {
                Button {
                    toggleFind(replace: false)
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
            }
            if document.isBinary, let url = document.url, FileKind.canPreview(url) {
                Button {
                    showHex.toggle()
                } label: {
                    Label(showHex ? "Preview" : "Hex", systemImage: showHex ? "eye" : "number")
                }
            }
            Menu {
                moreMenu
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
    }

    /// The second pane's own bar: its document (a menu to switch), its buttons, and close.
    private var secondaryHeader: some View {
        HStack(spacing: 14) {
            Menu {
                let others = model.documents.filter { $0.id != document.id && $0.id != window.primaryID }
                if !others.isEmpty {
                    Section("Show in This Pane") {
                        ForEach(others) { other in
                            Button(other.name) { model.activate(other, in: window, pane: .secondary) }
                        }
                    }
                }
                titleMenu
            } label: {
                HStack(spacing: 4) {
                    Text(verbatim: document.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.primary)
            }
            Spacer(minLength: 4)
            toolbarButtons
                .labelStyle(.iconOnly)
            Button {
                model.closeSplit(in: window)
            } label: {
                Label("Close Split", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.footnote.weight(.semibold))
            }
        }
        .imageScale(.medium)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(.bar)

    }

    @ViewBuilder
    private var titleMenu: some View {
        if document.isUntitled {
            Button {
                beginExport()
            } label: {
                Label("Save As…", systemImage: "square.and.arrow.down")
            }
        } else if !document.isBinary {
            Button {
                saveNow()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(!document.isDirty)
            Button {
                beginExport()
            } label: {
                Label("Save a Copy…", systemImage: "doc.on.doc")
            }
        }
        if let url = document.url {
            ShareLink(item: url)
        }
        Button(role: .destructive) {
            model.requestClose(document)
        } label: {
            Label("Close", systemImage: "xmark")
        }
    }

    @ViewBuilder
    private var moreMenu: some View {
        if !document.isBinary {
            Section {
                ControlGroup {
                    Button {
                        document.controller.undo()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    Button {
                        document.controller.redo()
                    } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    Button {
                        document.controller.selectAll()
                    } label: {
                        Label("Select All", systemImage: "selection.pin.in.out")
                    }
                }
            }
            Section {
                Button {
                    toggleFind(replace: true)
                } label: {
                    Label("Find and Replace…", systemImage: "arrow.left.arrow.right")
                }
                Button {
                    goToLineText = ""
                    showGoToLine = true
                } label: {
                    Label("Go to Line…", systemImage: "arrow.down.to.line")
                }
                if Outline.supports(document.language) {
                    Button {
                        sheet = .outline
                    } label: {
                        Label("Outline", systemImage: "list.bullet.indent")
                    }
                }
            }
            if !document.isReadOnly {
                Section {
                    Menu {
                        ForEach(TextTransform.Group.allCases, id: \.self) { group in
                            Section {
                                ForEach(TextTransform.allCases.filter { $0.group == group }) { transform in
                                    Button(transform.title) { run(transform) }
                                }
                            }
                        }
                    } label: {
                        Label("Transform Text", systemImage: "textformat.alt")
                    }
                    Menu {
                        Button {
                            document.controller.indentSelection()
                        } label: {
                            Label("Indent", systemImage: "increase.indent")
                        }
                        Button {
                            document.controller.outdentSelection()
                        } label: {
                            Label("Outdent", systemImage: "decrease.indent")
                        }
                        Button {
                            document.controller.toggleComment()
                        } label: {
                            Label("Toggle Comment", systemImage: "text.bubble")
                        }
                        Button {
                            document.controller.moveLinesUp()
                        } label: {
                            Label("Move Line Up", systemImage: "arrow.up")
                        }
                        Button {
                            document.controller.moveLinesDown()
                        } label: {
                            Label("Move Line Down", systemImage: "arrow.down")
                        }
                        Button {
                            document.controller.duplicateLine()
                        } label: {
                            Label("Duplicate Line", systemImage: "plus.square.on.square")
                        }
                        Button(role: .destructive) {
                            document.controller.deleteLine()
                        } label: {
                            Label("Delete Line", systemImage: "delete.left")
                        }
                    } label: {
                        Label("Line Operations", systemImage: "text.alignleft")
                    }
                }
            }
            Section {
                Toggle(isOn: $settings.wrapLines) {
                    Label("Wrap Lines", systemImage: "arrow.turn.down.left")
                }
                Toggle(isOn: $settings.showLineNumbers) {
                    Label("Line Numbers", systemImage: "list.number")
                }
                Toggle(isOn: $settings.showInvisibles) {
                    Label("Show Invisibles", systemImage: "paragraphsign")
                }
                if !document.isTooLargeToEdit {
                    Toggle(isOn: $document.userReadOnly) {
                        Label("Read Only", systemImage: "lock")
                    }
                }
            }
            Section {
                Button {
                    sheet = .statistics
                } label: {
                    Label("Statistics", systemImage: "chart.bar")
                }
                Button {
                    sheet = .compare
                } label: {
                    Label("Compare With…", systemImage: "plusminus")
                }
                Button {
                    printDocument()
                } label: {
                    Label("Print…", systemImage: "printer")
                }
            }
        }
        Section {
            Button {
                model.newDocument(in: window)
            } label: {
                Label("New File", systemImage: "square.and.pencil")
            }
            Button {
                startImport()
            } label: {
                Label("Open File…", systemImage: "doc")
            }
        }
        Section {
            if window.isSplit {
                Button {
                    model.closeSplit(in: window)
                } label: {
                    Label("Close Split", systemImage: "rectangle")
                }
            } else {
                let others = model.documents.filter { $0.id != document.id && !model.isVisible($0.id) }
                Menu {
                    ForEach(others) { other in
                        Button(other.name) { model.activate(other, in: window, pane: .secondary) }
                    }
                } label: {
                    Label("Open in Split", systemImage: "rectangle.split.2x1")
                }
                .disabled(others.isEmpty)
            }
            if UIApplication.shared.supportsMultipleScenes {
                Button {
                    openWindow(id: EOFApp.windowID, value: document.id)
                } label: {
                    Label("Open in New Window", systemImage: "macwindow.badge.plus")
                }
            }
            Button(role: .destructive) {
                model.requestClose(document)
            } label: {
                Label("Close", systemImage: "xmark")
            }
        }
    }

    // MARK: - Actions

    /// On a narrow screen the bar folds Find into its overflow menu, two taps away at the top.
    /// There it sits at the start of the status bar instead, where a thumb reaches it.
    private var findInStatusBar: Bool {
        !document.isBinary && horizontalSizeClass == .compact
    }

    private func toggleFind(replace: Bool) {
        if showFind, findWithReplace == replace {
            showFind = false
        } else {
            findWithReplace = replace
            showFind = true
        }
    }

    private func handle(_ command: EditorCommand) {
        switch command {
        case .find:
            findWithReplace = false
            showFind = true
        case .replace:
            findWithReplace = true
            showFind = true
        case .goToLine:
            goToLineText = ""
            showGoToLine = true
        case .togglePreview:
            if canPreview { togglePreview() }
        case .save:
            if document.isUntitled { beginExport() } else { saveNow() }
        case .saveAs:
            beginExport()
        case .outline:
            if Outline.supports(document.language) { sheet = .outline }
        case .closeDocument:
            model.requestClose(document)
        case .openFile, .toggleSplit:
            break
        }
    }

    private func saveNow() {
        if document.hasConflict { return }
        try? document.save()
    }

    private func beginExport() {
        do {
            exportFile = DataFile(data: try document.encodedContents())
            isExporting = true
        } catch {
            model.alert = AppAlert(title: String(localized: "Could Not Save"), message: error.localizedDescription)
        }
    }

    private func goToLine() {
        let parts = goToLineText.split(whereSeparator: { $0 == ":" || $0 == "," || $0 == " " }).compactMap { Int($0) }
        guard let line = parts.first else { return }
        document.controller.goToLine(line, column: parts.count > 1 ? parts[1] : 1)
    }

    /// The keyboard command: from the source to the preview, and from either preview back.
    private func togglePreview() {
        withAnimation(.snappy(duration: 0.2)) { viewMode = viewMode == .source ? .preview : .source }
    }

    private func run(_ transform: TextTransform) {
        do {
            try document.controller.apply(transform)
        } catch TextTransform.Failure.notBase64 {
            transformError = String(localized: "The text is not valid Base64.")
        } catch TextTransform.Failure.notJSON(let message) {
            transformError = String(localized: "The text is not valid JSON.") + "\n" + message
        } catch {
            transformError = String(localized: "The text could not be decoded.")
        }
    }

    private func printDocument() {
        let formatter = UISimpleTextPrintFormatter(attributedText: NSAttributedString(
            string: document.text,
            attributes: [.font: UIFont.monospacedSystemFont(ofSize: 9, weight: .regular), .foregroundColor: UIColor.black]
        ))
        formatter.perPageContentInsets = UIEdgeInsets(top: 36, left: 36, bottom: 36, right: 36)
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = document.name
        info.outputType = .grayscale
        let printer = UIPrintInteractionController.shared
        printer.printInfo = info
        printer.printFormatter = formatter
        printer.present(animated: true)
    }
}

extension TextTransform {
    var title: LocalizedStringKey {
        switch self {
        case .uppercase: return "UPPERCASE"
        case .lowercase: return "lowercase"
        case .titleCase: return "Title Case"
        case .sortAscending: return "Sort Lines A → Z"
        case .sortDescending: return "Sort Lines Z → A"
        case .sortNumeric: return "Sort Lines by Number"
        case .reverseLines: return "Reverse Lines"
        case .removeDuplicateLines: return "Remove Duplicate Lines"
        case .removeBlankLines: return "Remove Blank Lines"
        case .trimTrailingWhitespace: return "Trim Trailing Whitespace"
        case .joinLines: return "Join Lines"
        case .tabsToSpaces: return "Tabs to Spaces"
        case .spacesToTabs: return "Leading Spaces to Tabs"
        case .base64Encode: return "Base64 Encode"
        case .base64Decode: return "Base64 Decode"
        case .urlEncode: return "URL Encode"
        case .urlDecode: return "URL Decode"
        case .jsonPretty: return "Format JSON"
        case .jsonMinify: return "Minify JSON"
        }
    }
}

struct NoticeBar: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(verbatim: text)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
            }
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

/// Open documents as a row of tabs.
struct TabStrip: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var window: WindowState
    /// The tab being dragged along the strip.
    @State private var dragging: EditorDocument.ID?

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.documents) { document in
                        TabItem(document: document, isActive: document.id == window.primaryID, isInSplit: document.id == window.secondaryID)
                            .id(document.id)
                            // Drag along the strip to reorder, to another app to hand over the
                            // file, or to the side of the screen for a window of its own.
                            .onDrag {
                                dragging = document.id
                                return FileDrag.provider(url: document.url, document: document.id, name: document.name)
                            }
                            .onDrop(of: [FileDrag.tabType], delegate: TabReorder(target: document.id, dragging: $dragging, model: model))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(.bar)
            .onChange(of: window.primaryID) { _, id in
                if let id { withAnimation { reader.scrollTo(id, anchor: .center) } }
            }
            .onAppear {
                if let id = window.primaryID { reader.scrollTo(id, anchor: .center) }
            }
        }
    }
}

/// Moves the dragged tab into a tab's place as soon as it passes over it, as Safari's tabs do.
private struct TabReorder: DropDelegate {
    let target: EditorDocument.ID
    @Binding var dragging: EditorDocument.ID?
    let model: AppModel

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.snappy(duration: 0.2)) { model.moveDocument(dragging, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private struct TabItem: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var window: WindowState
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var document: EditorDocument
    let isActive: Bool
    /// Shown in the window's second pane.
    var isInSplit = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.activate(document, in: window, pane: .primary)
            } label: {
                HStack(spacing: 5) {
                    if isInSplit {
                        Image(systemName: "rectangle.righthalf.inset.filled")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if document.isDirty {
                        Circle()
                            .fill(.tint)
                            .frame(width: 6, height: 6)
                    }
                    Text(verbatim: document.name)
                        .font(.subheadline.weight(isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180)
                }
            }
            .foregroundStyle(isActive ? .primary : .secondary)
            if isActive {
                Button {
                    model.requestClose(document)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .accessibilityLabel(Text("Close"))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground).opacity(isActive ? 1 : 0), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(uiColor: .separator).opacity(isActive ? 0.6 : 0)))
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
            Divider()
            if !isActive, !isInSplit {
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

/// The navigation bar title, title menu and buttons, only for the pane that owns the bar.
private struct PaneChrome<TitleMenu: View, Buttons: View>: ViewModifier {
    let isPrimary: Bool
    let title: String
    let titleMenu: TitleMenu
    let toolbar: Buttons

    func body(content: Content) -> some View {
        if isPrimary {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarTitleMenu { titleMenu }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) { toolbar }
                }
        } else {
            content
        }
    }
}
