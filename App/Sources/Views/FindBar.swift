import Combine
import SwiftUI
import TesseraCore

final class FindModel: ObservableObject {
    @Published var query = ""
    @Published var replacement = ""
    @Published var options = FindOptions()
    @Published private(set) var matches: [NSRange] = []
    @Published private(set) var current: Int?
    @Published private(set) var error: String?
    @Published private(set) var reachedLimit = false

    private static let limit = 20_000
    private weak var document: EditorDocument?
    private var compiled: FindQuery?
    private var subscriptions = Set<AnyCancellable>()

    func attach(_ document: EditorDocument) {
        guard self.document == nil else { return }
        self.document = document
        // Seed from the selection, like every desktop editor does.
        let selected = document.controller.selectedText
        if !selected.isEmpty, selected.count < 200, !selected.contains("\n") { query = selected }
        Publishers.CombineLatest($query, $options)
            .debounce(for: .milliseconds(180), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.search(keepPosition: false) }
            .store(in: &subscriptions)
        document.edits
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.search(keepPosition: true) }
            .store(in: &subscriptions)
    }

    func detach() {
        document?.controller.setFindMatches([], current: nil)
        subscriptions.removeAll()
    }

    private func search(keepPosition: Bool) {
        guard let document else { return }
        let controller = document.controller
        do {
            let compiled = try FindQuery(query, options: options)
            self.compiled = compiled
            error = nil
            let found = compiled.matches(in: controller.text, limit: FindModel.limit)
            matches = found
            reachedLimit = found.count >= FindModel.limit
            if found.isEmpty {
                current = nil
            } else {
                // Start from the first match at or after the caret.
                let caret = controller.selectedRange.location
                let index = found.firstIndex { $0.location >= caret } ?? 0
                current = keepPosition ? min(current ?? index, found.count - 1) : index
            }
        } catch {
            compiled = nil
            matches = []
            current = nil
            reachedLimit = false
            self.error = (error as? FindQuery.Failure)?.errorDescription
        }
        controller.setFindMatches(matches, current: current.map { matches[$0] })
        if !keepPosition, let current { controller.scroll(to: matches[current]) }
    }

    func step(_ delta: Int) {
        guard let document, !matches.isEmpty else { return }
        let next = ((current ?? -1) + delta + matches.count) % matches.count
        current = next
        document.controller.setFindMatches(matches, current: matches[next])
        document.controller.select(matches[next])
    }

    func replaceCurrent() {
        guard let document, let compiled, let current, current < matches.count else { return }
        let controller = document.controller
        let range = matches[current]
        guard let text = compiled.replacement(in: controller.text, at: range, with: replacement) else { return }
        controller.replace(range, with: text)
        search(keepPosition: true)
        if let index = self.current, index < matches.count { controller.select(matches[index]) }
    }

    func replaceAll() {
        guard let document, let compiled, !matches.isEmpty else { return }
        let controller = document.controller
        let selection = controller.selectedRange
        // With several lines selected, replace only inside the selection.
        let scope = selection.length > 0 && controller.selectedText.contains("\n") ? selection : nil
        if let scope {
            let part = (controller.text as NSString).substring(with: scope)
            let result = compiled.replaceAll(in: part, with: replacement)
            guard result.count > 0 else { return }
            controller.replace(scope, with: result.text, selecting: NSRange(location: scope.location, length: (result.text as NSString).length))
        } else {
            let result = compiled.replaceAll(in: controller.text, with: replacement)
            guard result.count > 0 else { return }
            controller.replaceAll(with: result.text)
        }
        search(keepPosition: false)
    }
}

struct FindBar: View {
    let document: EditorDocument
    @Binding var withReplace: Bool
    let close: () -> Void
    @StateObject private var find = FindModel()
    @FocusState private var focus: Field?

    private enum Field { case find, replace }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Find", text: $find.query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .focused($focus, equals: .find)
                        .submitLabel(.search)
                        .onSubmit {
                            find.step(1)
                            focus = .find
                        }
                    if !find.query.isEmpty {
                        Text(countText)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(find.matches.isEmpty ? Color.red : Color.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    optionsMenu
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Button {
                    find.step(-1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(find.matches.isEmpty)
                .accessibilityLabel(Text("Previous Match"))
                Button {
                    find.step(1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(find.matches.isEmpty)
                .accessibilityLabel(Text("Next Match"))
                Button("Done", action: close)
                    .fontWeight(.semibold)
            }
            if withReplace, !document.isReadOnly {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                        TextField("Replace", text: $find.replacement)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                            .focused($focus, equals: .replace)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    Button("Replace") { find.replaceCurrent() }
                        .disabled(find.current == nil)
                    Button("All") { find.replaceAll() }
                        .disabled(find.matches.isEmpty)
                }
            }
            if let error = find.error {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear {
            find.attach(document)
            focus = .find
        }
        .onDisappear { find.detach() }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugFindQuery)) { note in
            if let query = note.object as? String { find.query = query }
        }
        #endif
    }

    private var countText: String {
        guard !find.matches.isEmpty else { return String(localized: "No Results") }
        let total = find.reachedLimit ? "\(find.matches.count)+" : "\(find.matches.count)"
        if let current = find.current { return "\(current + 1)/\(total)" }
        return total
    }

    private var optionsMenu: some View {
        Menu {
            Toggle(isOn: $find.options.caseSensitive) {
                Label("Match Case", systemImage: "textformat")
            }
            Toggle(isOn: $find.options.wholeWord) {
                Label("Whole Words", systemImage: "text.word.spacing")
            }
            Toggle(isOn: $find.options.regex) {
                Label("Regular Expression", systemImage: "asterisk")
            }
            Divider()
            Toggle(isOn: $withReplace) {
                Label("Replace", systemImage: "arrow.left.arrow.right")
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(find.options == FindOptions() ? Color.secondary : Color.accentColor)
        }
        .accessibilityLabel(Text("Find Options"))
    }
}
