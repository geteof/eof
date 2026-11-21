import SwiftUI

/// The open-source projects EOF is built on, with their licences, as those licences require.
/// The texts come from App/Resources/Acknowledgements.json, made by Tools/acknowledgements.py.
struct AcknowledgementsView: View {
    struct Entry: Decodable, Identifiable {
        let name: String
        let use: String
        let url: String
        let license: String
        var id: String { name }
    }

    private let entries: [Entry] = {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }()

    var body: some View {
        List(entries) { entry in
            NavigationLink {
                LicenseText(entry: entry)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.name)
                    Text(verbatim: entry.use)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseText: View {
    let entry: AcknowledgementsView.Entry

    /// Long texts (all the grammar licences) are split so only what is on screen is laid out.
    private var paragraphs: [String] {
        entry.license.components(separatedBy: "\n\n")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let url = URL(string: entry.url) {
                    Link(destination: url) {
                        Text(verbatim: entry.url)
                    }
                    .font(.footnote)
                }
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(verbatim: paragraph)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
            .padding()
        }
        .navigationTitle(Text(verbatim: entry.name))
        .navigationBarTitleDisplayMode(.inline)
    }
}
