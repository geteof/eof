import SwiftUI
import EOFCore

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Light Theme", selection: $settings.lightThemeID) {
                        ForEach(EditorTheme.light) { Text(verbatim: $0.name).tag($0.id) }
                    }
                    Picker("Dark Theme", selection: $settings.darkThemeID) {
                        ForEach(EditorTheme.dark) { Text(verbatim: $0.name).tag($0.id) }
                    }
                    ThemePreview()
                        .listRowInsets(EdgeInsets())
                }
                Section("Text") {
                    Picker("Font", selection: $settings.fontID) {
                        ForEach(AppSettings.fonts, id: \.id) { Text(verbatim: $0.name).tag($0.id) }
                    }
                    Stepper(value: $settings.fontSize, in: AppSettings.fontSizeRange, step: 1) {
                        LabeledContent("Font Size", value: "\(Int(settings.fontSize)) pt")
                    }
                    Stepper(value: $settings.lineHeight, in: 1.0...2.0, step: 0.1) {
                        LabeledContent("Line Height", value: settings.lineHeight.formatted(.number.precision(.fractionLength(1))))
                    }
                }
                Section("Editor") {
                    Toggle("Line Numbers", isOn: $settings.showLineNumbers)
                    Toggle("Wrap Lines", isOn: $settings.wrapLines)
                    Toggle("Highlight Current Line", isOn: $settings.highlightCurrentLine)
                    Toggle("Show Invisibles", isOn: $settings.showInvisibles)
                    Toggle("Keyboard Symbol Bar", isOn: $settings.showAccessoryBar)
                    Toggle("Hide Bars While Scrolling", isOn: $settings.hideBarsOnScroll)
                    Toggle("Open Markdown and HTML as Preview", isOn: $settings.openInPreview)
                }
                Section {
                    Toggle("Indent with Spaces", isOn: $settings.insertSpaces)
                    Picker("Indent Width", selection: $settings.tabWidth) {
                        ForEach([2, 3, 4, 8], id: \.self) { Text(verbatim: "\($0)").tag($0) }
                    }
                    Toggle("Detect from File", isOn: $settings.detectIndentation)
                    Toggle("Auto Indent", isOn: $settings.autoIndent)
                    Toggle("Close Brackets and Quotes", isOn: $settings.autoClosePairs)
                } header: {
                    Text("Indentation")
                } footer: {
                    Text("When detection is on, a file that already uses tabs or a different width keeps its own style.")
                }
                Section {
                    Toggle("Save Automatically", isOn: $settings.autosave)
                    Toggle("Trim Trailing Whitespace", isOn: $settings.trimTrailingWhitespaceOnSave)
                    Toggle("End Files with a Newline", isOn: $settings.ensureFinalNewline)
                } header: {
                    Text("Saving")
                } footer: {
                    Text("Files without a location are kept as drafts until you save them.")
                }
                Section("New Files") {
                    Picker("Encoding", selection: $settings.defaultEncodingID) {
                        ForEach(TextEncoding.all) { Text(verbatim: $0.name).tag($0.id) }
                    }
                    Picker("Line Endings", selection: $settings.defaultLineEnding) {
                        ForEach(LineEnding.allCases) { Text(verbatim: $0.detail).tag($0) }
                    }
                }
                Section {
                    Toggle("Allow JavaScript in HTML Preview", isOn: $settings.previewAllowsJavaScript)
                    Toggle("Show Hidden Files", isOn: $settings.showHiddenFiles)
                } header: {
                    Text("Files and Preview")
                } footer: {
                    Text("Scripts never run in Markdown previews.")
                }
                Section {
                    Button("Clear Recent Files", role: .destructive) { model.clearRecents() }
                        .disabled(model.recents.isEmpty)
                }
                Section {
                    LabeledContent("Version", value: version)
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                } footer: {
                    Text("EOF keeps your files on your device. It has no account and collects no data.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

/// A few highlighted lines in the chosen theme and font.
private struct ThemePreview: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    /// A few lines of Swift with the colour role of each piece.
    private static let sample: [(String, HighlightKind?)] = [
        ("// EOF\n", .comment), ("func", .keyword), (" ", nil), ("greet", .function), ("(_ name: ", nil), ("String", .type), (") -> ", nil), ("String", .type), (" {\n    ", nil),
        ("let", .keyword), (" count = ", nil), ("42", .number), ("\n    ", nil), ("return", .keyword), (" ", nil), ("\"Hello, \\(name)!\"", .string), ("\n}", nil),
    ]

    var body: some View {
        let theme = settings.theme(dark: colorScheme == .dark)
        Text(attributed(theme))
            .lineSpacing(CGFloat((settings.lineHeight - 1) * settings.fontSize))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(uiColor: theme.background))
    }

    private func attributed(_ theme: EditorTheme) -> AttributedString {
        let font = settings.font(size: min(settings.fontSize, 16))
        let result = NSMutableAttributedString()
        for (text, kind) in ThemePreview.sample {
            result.append(NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: kind.map(theme.color(for:)) ?? theme.foreground,
            ]))
        }
        return (try? AttributedString(result, including: \.uiKit)) ?? AttributedString(result.string)
    }
}
