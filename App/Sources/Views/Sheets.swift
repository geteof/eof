import SwiftUI
import EOFCore
import UniformTypeIdentifiers

struct OutlineSheet: View {
    let document: EditorDocument
    @Environment(\.dismiss) private var dismiss
    @State private var items: [OutlineItem]?
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if let items {
                    let shown = query.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(query) }
                    if shown.isEmpty {
                        ContentUnavailableView("No Symbols", systemImage: "list.bullet.indent", description: Text("Nothing to list in this file."))
                    } else {
                        List(shown) { item in
                            Button {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { document.controller.goToLine(item.line) }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: symbol(item.kind))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 22)
                                    Text(verbatim: item.title)
                                        .font(.system(.callout, design: item.kind == .heading ? .default : .monospaced))
                                        .fontWeight(item.level == 0 ? .medium : .regular)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 8)
                                    Text(verbatim: "\(item.line)")
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.leading, CGFloat(min(item.level, 5)) * 14)
                            }
                        }
                        .listStyle(.plain)
                    }
                } else {
                    ProgressView()
                }
            }
            .searchable(text: $query)
            .navigationTitle("Outline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            let text = document.text
            let language = document.language
            items = await Task.detached { Outline.items(in: text, language: language) }.value
        }
    }

    private func symbol(_ kind: OutlineItem.Kind) -> String {
        switch kind {
        case .heading: return "number"
        case .type: return "cube"
        case .function: return "function"
        case .section: return "bookmark"
        case .tag: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

struct StatisticsSheet: View {
    @ObservedObject var document: EditorDocument
    @Environment(\.dismiss) private var dismiss
    @State private var whole: TextStatistics?
    @State private var selection: TextStatistics?

    var body: some View {
        NavigationStack {
            Form {
                if let whole {
                    Section("Document") { rows(whole) }
                    if let selection {
                        Section("Selection") { rows(selection) }
                    }
                } else {
                    ProgressView()
                }
                Section("File") {
                    LabeledContent("Language", value: document.language.name)
                    LabeledContent("Encoding", value: document.encoding.name)
                    LabeledContent("Line Endings", value: document.lineEnding.detail)
                    if let url = document.url {
                        LabeledContent("Location", value: FileAccess.displayLocation(url))
                    }
                }
            }
            .navigationTitle("Statistics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            let text = document.text
            let selected = document.controller.selectedText
            whole = await Task.detached { TextStatistics(text) }.value
            if !selected.isEmpty { selection = await Task.detached { TextStatistics(selected) }.value }
        }
    }

    @ViewBuilder
    private func rows(_ stats: TextStatistics) -> some View {
        LabeledContent("Lines", value: stats.lines.formatted())
        LabeledContent("Words", value: stats.words.formatted())
        LabeledContent("Characters", value: stats.characters.formatted())
        LabeledContent("Characters (no spaces)", value: stats.charactersNoSpaces.formatted())
        LabeledContent("File Size", value: ByteCountFormatter.string(fromByteCount: Int64(stats.bytes), countStyle: .file))
    }
}

/// Line-by-line comparison of the current document with another open document or a file.
struct CompareSheet: View {
    let document: EditorDocument
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var otherName: String?
    @State private var lines: [DiffLine]?
    @State private var isWorking = false
    @State private var isImporting = false
    @State private var error: String?
    @State private var changesOnly = false

    var body: some View {
        NavigationStack {
            Group {
                if isWorking {
                    ProgressView()
                } else if let lines, let otherName {
                    result(lines, otherName: otherName)
                } else {
                    chooser
                }
            }
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if lines != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Change…") { lines = nil }
                    }
                }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item]) { result in
                guard case .success(let url) = result else { return }
                isWorking = true
                DispatchQueue.global(qos: .userInitiated).async {
                    let loaded = try? LoadedFile.load(url, defaults: (.utf8, .lf))
                    DispatchQueue.main.async {
                        if case .text(let text)? = loaded?.content {
                            compare(with: text, name: url.lastPathComponent)
                        } else {
                            isWorking = false
                            error = String(localized: "That file is not text.")
                        }
                    }
                }
            }
        }
    }

    private var chooser: some View {
        List {
            Section {
                Button {
                    isImporting = true
                } label: {
                    Label("Choose a File…", systemImage: "doc")
                }
                Button {
                    if let text = UIPasteboard.general.string { compare(with: LineEnding.normalize(text), name: String(localized: "Clipboard")) }
                } label: {
                    Label("Clipboard", systemImage: "doc.on.clipboard")
                }
            } footer: {
                if let error { Text(verbatim: error).foregroundStyle(.red) }
            }
            let others = model.documents.filter { $0.id != document.id && !$0.isBinary }
            if !others.isEmpty {
                Section("Open Documents") {
                    ForEach(others) { other in
                        Button {
                            compare(with: other.text, name: other.name)
                        } label: {
                            Label {
                                Text(verbatim: other.name).foregroundStyle(.primary)
                            } icon: {
                                FileIcon(name: other.name)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func result(_ lines: [DiffLine], otherName: String) -> some View {
        let summary = LineDiff.summary(lines)
        let shown = changesOnly ? lines.filter { $0.kind != .same } : lines
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(document.name) → \(otherName)")
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 10) {
                        Text(verbatim: "+\(summary.added)").foregroundStyle(.green)
                        Text(verbatim: "−\(summary.removed)").foregroundStyle(.red)
                    }
                    .font(.caption.monospacedDigit())
                }
                Spacer()
                Toggle("Changes Only", isOn: $changesOnly)
                    .toggleStyle(.button)
                    .font(.footnote)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()
            if summary.added == 0, summary.removed == 0 {
                ContentUnavailableView("No Differences", systemImage: "equal.circle", description: Text("The two texts are identical."))
            } else {
                List(shown) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: line.leftNumber.map(String.init) ?? "")
                            .frame(width: 38, alignment: .trailing)
                            .foregroundStyle(.tertiary)
                        Text(verbatim: line.rightNumber.map(String.init) ?? "")
                            .frame(width: 38, alignment: .trailing)
                            .foregroundStyle(.tertiary)
                        Text(verbatim: line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                            .foregroundStyle(line.kind == .added ? .green : .red)
                        Text(verbatim: line.text.isEmpty ? " " : line.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 10))
                    .listRowSeparator(.hidden)
                    .listRowBackground(background(line.kind))
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 20)
            }
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .same: return .clear
        case .added: return Color.green.opacity(0.16)
        case .removed: return Color.red.opacity(0.16)
        }
    }

    private func compare(with other: String, name: String) {
        let mine = document.text
        guard mine.utf16.count + other.utf16.count < 6_000_000 else {
            isWorking = false
            error = String(localized: "These files are too large to compare.")
            return
        }
        error = nil
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LineDiff.compare(mine, other)
            DispatchQueue.main.async {
                otherName = name
                lines = result
                isWorking = false
            }
        }
    }
}
