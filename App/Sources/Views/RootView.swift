import SwiftUI
import EOFCore
import UniformTypeIdentifiers

enum ImportKind {
    case files, folder
}

struct RootView: View {
    /// The document a window was opened for ("Open in New Window"); nil for an empty window.
    let initialDocument: UUID?

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var window = WindowState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var isImporting = false
    @State private var importKind = ImportKind.files
    @State private var showSettings = false
    @State private var didStart = false

    /// Shared alerts show in the window the user is working in, not in every window.
    private var isFocusedWindow: Bool { model.focusedWindow === window }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $window.compactColumn) {
            SidebarView(startImport: startImport, showSettings: $showSettings)
                .navigationSplitViewColumnWidth(min: 260, ideal: 330, max: 440)
        } detail: {
            EditorArea(startImport: startImport)
        }
        .navigationSplitViewStyle(.balanced)
        .environmentObject(window)
        .focusedSceneObject(window)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: importKind == .folder ? [.folder] : [.item], allowsMultipleSelection: importKind == .files) { result in
            switch result {
            case .success(let urls):
                if importKind == .folder {
                    if let url = urls.first { model.openFolder(url, in: window) }
                } else {
                    for (index, url) in urls.enumerated() { model.open(url, activate: index == urls.count - 1, in: window) }
                }
            case .failure(let error):
                model.alert = AppAlert(title: String(localized: "Could Not Open"), message: error.localizedDescription)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .fullScreenCover(isPresented: $window.showBrowser) {
            if let folder = model.folder {
                BrowserView(root: folder.url)
                    .environmentObject(model)
                    .environmentObject(settings)
                    .environmentObject(window)
            }
        }
        .alert(item: Binding(get: { isFocusedWindow ? model.alert : nil }, set: { model.alert = $0 })) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog(
            "Discard Changes?",
            isPresented: Binding(get: { isFocusedWindow && model.pendingClose != nil }, set: { if !$0 { model.pendingClose = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingClose
        ) { document in
            Button("Discard Changes", role: .destructive) { model.close(document) }
            Button("Cancel", role: .cancel) {}
        } message: { document in
            Text("“\(document.name)” has changes that are not saved to a file.")
        }
        .overlay(alignment: .top) {
            if let name = model.loadingName, isFocusedWindow {
                Label {
                    Text("Opening \(name)…")
                } icon: {
                    ProgressView()
                }
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .onReceive(window.commands) { command in
            switch command {
            case .openFile: startImport(.files)
            case .openFolder: startImport(.folder)
            case .browseFiles: if model.folder != nil { window.showBrowser = true }
            case .toggleSplit: toggleSplit()
            default: break
            }
        }
        .onOpenURL { url in
            model.focusedWindow = window
            model.openAny(url)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.focusedWindow = window }
        }
        .onAppear(perform: start)
    }

    private func start() {
        guard !didStart else { return }
        didStart = true
        model.register(window)
        if let initialDocument, let document = model.document(initialDocument) {
            model.activate(document, in: window)
            return
        }
        // Only the first window brings back the last session.
        guard model.windows.count == 1 else { return }
        model.focusedWindow = window
        #if DEBUG
        if DebugLaunch.isActive {
            DebugLaunch.open(in: model)
            return
        }
        #endif
        model.restoreSession()
    }

    private func toggleSplit() {
        if window.isSplit {
            model.closeSplit(in: window)
        } else if let next = model.splitCandidate(for: window) {
            model.activate(next, in: window, pane: .secondary)
        }
    }

    private func startImport(_ kind: ImportKind) {
        importKind = kind
        isImporting = true
    }
}

/// The detail column: one editor, or two side by side (or stacked on a narrow screen).
private struct EditorArea: View {
    let startImport: (ImportKind) -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var window: WindowState

    var body: some View {
        if let primary = model.document(window.primaryID) {
            if let secondary = model.document(window.secondaryID) {
                GeometryReader { proxy in
                    // Side by side needs room for two readable columns; below that the panes stack.
                    SplitLayout(horizontal: proxy.size.width >= 640, fraction: $window.splitFraction) {
                        EditorScreen(document: primary, pane: .primary, startImport: startImport)
                            .id(primary.id)
                    } second: {
                        EditorScreen(document: secondary, pane: .secondary, startImport: startImport)
                            .id(secondary.id)
                    }
                }
            } else {
                EditorScreen(document: primary, pane: .primary, startImport: startImport)
                    .id(primary.id)
            }
        } else {
            WelcomeView(startImport: startImport)
        }
    }
}

/// Two views with a divider that can be dragged; double-tapping the divider evens them out.
struct SplitLayout<First: View, Second: View>: View {
    let horizontal: Bool
    @Binding var fraction: CGFloat
    @ViewBuilder var first: First
    @ViewBuilder var second: Second

    private static var handle: CGFloat { 12 }

    var body: some View {
        GeometryReader { proxy in
            let total = (horizontal ? proxy.size.width : proxy.size.height) - SplitLayout.handle
            let firstSize = max(0, total * min(max(fraction, 0.2), 0.8))
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                first
                    .frame(width: horizontal ? firstSize : nil, height: horizontal ? nil : firstSize)
                divider(total: total)
                second
            }
            .coordinateSpace(name: "split")
        }
    }

    private func divider(total: CGFloat) -> some View {
        ZStack {
            Color(uiColor: .systemBackground)
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
            Capsule()
                .fill(Color(uiColor: .tertiaryLabel))
                .frame(width: horizontal ? 4 : 36, height: horizontal ? 36 : 4)
        }
        .frame(width: horizontal ? SplitLayout.handle : nil, height: horizontal ? nil : SplitLayout.handle)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .named("split"))
                .onChanged { value in
                    guard total > 0 else { return }
                    let position = horizontal ? value.location.x : value.location.y
                    fraction = min(max(position / total, 0.2), 0.8)
                }
        )
        .onTapGesture(count: 2) { withAnimation(.snappy) { fraction = 0.5 } }
        .accessibilityLabel(Text("Split Divider"))
        .accessibilityAdjustableAction { direction in
            fraction = min(max(fraction + (direction == .increment ? 0.1 : -0.1), 0.2), 0.8)
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var window: WindowState
    let startImport: (ImportKind) -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Document Open", systemImage: "doc.text")
        } description: {
            Text("Create a file, or open one from Files, iCloud Drive or another app.")
        } actions: {
            Button {
                model.newDocument(in: window)
            } label: {
                Label("New File", systemImage: "square.and.pencil")
            }
            .buttonStyle(.borderedProminent)
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
        }
    }
}
