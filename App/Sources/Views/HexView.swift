import SwiftUI
import TesseraCore

/// Read-only hex dump for files that are not text.
struct HexView: View {
    let data: Data

    var body: some View {
        let rows = HexDump.rowCount(for: data.count)
        if rows == 0 {
            ContentUnavailableView("Empty File", systemImage: "doc")
        } else {
            ScrollView(.horizontal) {
                List(0..<rows, id: \.self) { index in
                    let row = HexDump.row(index, of: data)
                    HStack(spacing: 14) {
                        Text(verbatim: row.offset)
                            .foregroundStyle(.secondary)
                        Text(verbatim: row.hex)
                            .frame(width: hexWidth, alignment: .leading)
                        Text(verbatim: row.ascii)
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize()
                    .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14))
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 18)
                .frame(width: listWidth)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }

    // 12 pt monospaced digits are about 7.3 pt wide.
    private var hexWidth: CGFloat { 49 * 7.3 }
    private var listWidth: CGFloat { (8 + 49 + 16) * 7.3 + 14 * 4 }
}
