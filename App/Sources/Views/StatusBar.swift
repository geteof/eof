import SwiftUI
import EOFCore

/// Caret position, language, indentation, encoding and line endings. Each item opens its own menu.
struct StatusBar: View {
    @ObservedObject var document: EditorDocument
    @ObservedObject var status: CursorStatus
    @Binding var sheet: EditorSheet?
    /// Source, preview or side by side, for documents that have a preview. The only control
    /// for it, at the bottom so a thumb reaches it.
    var viewMode: Binding<ViewMode>?
    /// The window is wide enough for source and preview side by side.
    var allowsSideBySide = false
    let goToLine: () -> Void
    @EnvironmentObject private var model: AppModel
    @State private var encodingError: String?

    var body: some View {
        GeometryReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                if document.isBinary {
                    if let url = document.url {
                        Text(verbatim: FileKind.describe(url))
                    } else {
                        Text("Binary")
                    }
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(document.byteCount), countStyle: .file))
                } else {
                    if let viewMode {
                        Picker("View", selection: viewMode) {
                            Text("Source").tag(ViewMode.source)
                            Text("Preview").tag(ViewMode.preview)
                            if allowsSideBySide {
                                Text("Side by Side").tag(ViewMode.sideBySide)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .controlSize(.mini)
                    }
                    Button(action: goToLine) {
                        if status.selection > 0 {
                            Text("Ln \(status.line), Col \(status.column) (\(status.selection) selected)")
                        } else {
                            Text("Ln \(status.line), Col \(status.column)")
                        }
                    }
                    .monospacedDigit()
                    if document.isReadOnly {
                        Label("Read Only", systemImage: "lock.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    Spacer(minLength: 12)
                    Button {
                        sheet = .language
                    } label: {
                        Text(verbatim: document.language.name)
                    }
                    indentMenu
                    encodingMenu
                    lineEndingMenu
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(minWidth: proxy.size.width, minHeight: 30)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .frame(height: 30)
        .background(.bar)
        .buttonStyle(.plain)
        .alert("Encoding", isPresented: Binding(get: { encodingError != nil }, set: { if !$0 { encodingError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: encodingError ?? "")
        }
    }

    private var indentMenu: some View {
        Menu {
            Section("Spaces") {
                ForEach([2, 3, 4, 8], id: \.self) { width in
                    Button {
                        document.setIndent(IndentStyle(usesTabs: false, width: width))
                    } label: {
                        if !document.indent.usesTabs, document.indent.width == width {
                            Label("\(width) Spaces", systemImage: "checkmark")
                        } else {
                            Text("\(width) Spaces")
                        }
                    }
                }
            }
            Section("Tabs") {
                ForEach([2, 4, 8], id: \.self) { width in
                    Button {
                        document.setIndent(IndentStyle(usesTabs: true, width: width))
                    } label: {
                        if document.indent.usesTabs, document.indent.width == width {
                            Label("Tab Width \(width)", systemImage: "checkmark")
                        } else {
                            Text("Tab Width \(width)")
                        }
                    }
                }
            }
        } label: {
            if document.indent.usesTabs {
                Text("Tabs: \(document.indent.width)")
            } else {
                Text("Spaces: \(document.indent.width)")
            }
        }
    }

    private var encodingMenu: some View {
        Menu {
            if !document.isUntitled {
                Menu("Reopen with Encoding") {
                    ForEach(TextEncoding.all) { encoding in
                        Button(encoding.name) { reopen(with: encoding) }
                    }
                }
            }
            Menu("Save with Encoding") {
                ForEach(TextEncoding.all) { encoding in
                    Button {
                        convert(to: encoding)
                    } label: {
                        if encoding == document.encoding {
                            Label(encoding.name, systemImage: "checkmark")
                        } else {
                            Text(verbatim: encoding.name)
                        }
                    }
                }
            }
        } label: {
            Text(verbatim: document.encoding.name)
        }
    }

    private var lineEndingMenu: some View {
        Menu {
            ForEach(LineEnding.allCases) { ending in
                Button {
                    guard ending != document.lineEnding else { return }
                    document.lineEnding = ending
                    document.markEdited()
                } label: {
                    if ending == document.lineEnding {
                        Label(ending.detail, systemImage: "checkmark")
                    } else {
                        Text(verbatim: ending.detail)
                    }
                }
            }
        } label: {
            Text(verbatim: document.lineEnding.name)
        }
        .disabled(document.isReadOnly)
    }

    private func reopen(with encoding: TextEncoding) {
        if document.isDirty {
            encodingError = String(localized: "Save or discard your changes before reopening with another encoding.")
            return
        }
        do {
            try document.reload(encoding: encoding)
        } catch {
            encodingError = error.localizedDescription
        }
    }

    private func convert(to encoding: TextEncoding) {
        guard encoding != document.encoding else { return }
        guard encoding.encode(document.text) != nil else {
            encodingError = String(localized: "Some characters cannot be saved as \(encoding.name). Choose another encoding, such as UTF-8.")
            return
        }
        document.encoding = encoding
        document.markEdited()
    }
}

struct LanguagePicker: View {
    @ObservedObject var document: EditorDocument
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var languages: [Language] {
        let sorted = Languages.all.sorted { a, b in
            if a.id == "plain" { return true }
            if b.id == "plain" { return false }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.extensions.contains { $0.localizedCaseInsensitiveContains(query) } }
    }

    var body: some View {
        NavigationStack {
            List(languages) { language in
                Button {
                    document.setLanguage(language)
                    dismiss()
                } label: {
                    HStack {
                        Text(verbatim: language.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        if language.id == document.language.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Language")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
