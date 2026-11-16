import SwiftUI
import EOFCore
import UniformTypeIdentifiers

enum ImportKind {
    case files, folder
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var isImporting = false
    @State private var importKind = ImportKind.files
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $model.compactColumn) {
            SidebarView(startImport: startImport, showSettings: $showSettings)
                .navigationSplitViewColumnWidth(min: 260, ideal: 330, max: 440)
        } detail: {
            if let document = model.activeDocument {
                EditorScreen(document: document, startImport: startImport)
                    .id(document.id)
            } else {
                WelcomeView(startImport: startImport)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: importKind == .folder ? [.folder] : [.item], allowsMultipleSelection: importKind == .files) { result in
            switch result {
            case .success(let urls):
                if importKind == .folder {
                    if let url = urls.first { model.openFolder(url) }
                } else {
                    for (index, url) in urls.enumerated() { model.open(url, activate: index == urls.count - 1) }
                }
            case .failure(let error):
                model.alert = AppAlert(title: String(localized: "Could Not Open"), message: error.localizedDescription)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .fullScreenCover(isPresented: $model.showBrowser) {
            if let folder = model.folder {
                BrowserView(root: folder.url)
                    .environmentObject(model)
                    .environmentObject(settings)
            }
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog(
            "Discard Changes?",
            isPresented: Binding(get: { model.pendingClose != nil }, set: { if !$0 { model.pendingClose = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingClose
        ) { document in
            Button("Discard Changes", role: .destructive) { model.close(document) }
            Button("Cancel", role: .cancel) {}
        } message: { document in
            Text("“\(document.name)” has changes that are not saved to a file.")
        }
        .overlay(alignment: .top) {
            if let name = model.loadingName {
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
        .onReceive(model.commands) { command in
            switch command {
            case .openFile: startImport(.files)
            case .openFolder: startImport(.folder)
            case .browseFiles: if model.folder != nil { model.showBrowser = true }
            default: break
            }
        }
    }

    private func startImport(_ kind: ImportKind) {
        importKind = kind
        isImporting = true
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    let startImport: (ImportKind) -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Document Open", systemImage: "doc.text")
        } description: {
            Text("Create a file, or open one from Files, iCloud Drive or another app.")
        } actions: {
            Button {
                model.newDocument()
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
