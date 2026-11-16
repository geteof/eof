import SwiftUI
import EOFCore

/// Read-only hex dump for files that are not text. Rows hold sixteen bytes where they fit and
/// eight on a narrow screen, so nothing runs off the side.
struct HexView: View {
    let data: Data

    private static let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// Measured, not assumed: a guess that is slightly too small cuts the last byte off every row.
    private static let characterWidth: CGFloat = ceil(("0" as NSString).size(withAttributes: [.font: font]).width * 100) / 100
    private static let spacing: CGFloat = 12
    private static let margin: CGFloat = 14

    private static func width(bytesPerRow: Int) -> CGFloat {
        CGFloat(8 + HexDump.hexColumnWidth(bytesPerRow: bytesPerRow) + bytesPerRow) * characterWidth + spacing * 2 + margin * 2 + 8
    }

    var body: some View {
        if data.isEmpty {
            ContentUnavailableView("Empty File", systemImage: "doc")
        } else {
            GeometryReader { proxy in
                let bytesPerRow = proxy.size.width >= HexView.width(bytesPerRow: 16) ? 16 : 8
                let rows = HexDump.rowCount(for: data.count, bytesPerRow: bytesPerRow)
                List(0..<rows, id: \.self) { index in
                    let row = HexDump.row(index, of: data, bytesPerRow: bytesPerRow)
                    // The last row is padded with spaces so the text column stays aligned; each
                    // column takes the width its text needs, so nothing is cut.
                    let columns = HexDump.hexColumnWidth(bytesPerRow: bytesPerRow)
                    HStack(spacing: HexView.spacing) {
                        Text(verbatim: row.offset)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Text(verbatim: row.hex + String(repeating: " ", count: max(0, columns - row.hex.count)))
                            .fixedSize()
                        Text(verbatim: row.ascii)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Spacer(minLength: 0)
                    }
                    .font(Font(HexView.font))
                    .lineLimit(1)
                    .listRowInsets(EdgeInsets(top: 2, leading: HexView.margin, bottom: 2, trailing: HexView.margin))
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 18)
                .id(bytesPerRow)
            }
        }
    }
}
