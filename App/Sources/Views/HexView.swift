import SwiftUI
import EOFCore

/// Read-only hex dump for files that are not text. Rows hold sixteen bytes where they fit and
/// eight on a narrow screen, so nothing runs off the side.
struct HexView: View {
    let data: Data

    // 12 pt monospaced characters are about 7.3 pt wide.
    private static let characterWidth: CGFloat = 7.3
    private static let spacing: CGFloat = 12
    private static let margin: CGFloat = 14

    private static func width(bytesPerRow: Int) -> CGFloat {
        CGFloat(8 + HexDump.hexColumnWidth(bytesPerRow: bytesPerRow) + bytesPerRow) * characterWidth + spacing * 2 + margin * 2
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
                    HStack(spacing: HexView.spacing) {
                        Text(verbatim: row.offset)
                            .foregroundStyle(.secondary)
                        Text(verbatim: row.hex)
                            .frame(width: CGFloat(HexDump.hexColumnWidth(bytesPerRow: bytesPerRow)) * HexView.characterWidth + 2, alignment: .leading)
                        Text(verbatim: row.ascii)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12, design: .monospaced))
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
