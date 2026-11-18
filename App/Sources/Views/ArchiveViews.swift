import EOFCore
import SwiftUI

/// One compress or extract run: what it is doing, how far it got, and how it ended.
final class ArchiveJob: ObservableObject {
    @Published private(set) var title: String?
    @Published private(set) var progress: Progress?
    @Published private(set) var outcome: Outcome?

    enum Outcome {
        case created(URL)
        case failed(Error)
    }

    var isRunning: Bool { title != nil }

    /// Runs `work` off the main thread. `determinate` work gets a progress bar and a Cancel button.
    func run(_ title: String, determinate: Bool, work: @escaping (Progress?) throws -> URL) {
        guard !isRunning else { return }
        let progress = determinate ? Progress(totalUnitCount: 1) : nil
        self.title = title
        self.progress = progress
        outcome = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work(progress) }
            DispatchQueue.main.async {
                self.title = nil
                self.progress = nil
                switch result {
                case .success(let url):
                    self.outcome = .created(url)
                case .failure(let error):
                    // A cancelled run ends quietly.
                    if (error as? CocoaError)?.code != .userCancelled { self.outcome = .failed(error) }
                }
            }
        }
    }

    func cancel() {
        progress?.cancel()
    }

    func clearOutcome() {
        outcome = nil
    }
}

/// The card shown over a page while an archive is being written or unpacked.
struct ArchiveJobCard: View {
    @ObservedObject var job: ArchiveJob

    var body: some View {
        if let title = job.title {
            VStack(spacing: 14) {
                if let progress = job.progress {
                    ProgressView(progress)
                        .progressViewStyle(.linear)
                        .labelsHidden()
                        .frame(width: 200)
                } else {
                    ProgressView()
                }
                Text(verbatim: title)
                    .font(.footnote)
                if job.progress != nil {
                    Button("Cancel", role: .cancel) { job.cancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }
}

/// A short message at the bottom of a page that goes away by itself.
struct Toast: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label {
            Text(verbatim: text)
                .lineLimit(2)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.green)
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .padding(.bottom, 14)
        .padding(.horizontal, 20)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// The files inside an archive, listed without unpacking it, with a button to extract it.
struct ArchiveContents: View {
    let url: URL
    /// Off inside the long-press card, where buttons cannot be tapped.
    var showsActions = true

    @StateObject private var job = ArchiveJob()
    @State private var items: [ArchiveItem]?
    @State private var total = 0
    @State private var error: String?
    @State private var extracted: URL?

    private var format: ArchiveFormat? { Archives.format(url) }

    private var summary: String {
        var parts: [String] = []
        if let format { parts.append(format.displayName) }
        if items != nil { parts.append(String(localized: "\(total) items")) }
        let unpacked = (items ?? []).compactMap(\.size).reduce(0, +)
        if unpacked > 0 {
            parts.append(String(localized: "\(ByteCountFormatter.string(fromByteCount: Int64(unpacked), countStyle: .file)) unpacked"))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .overlay { ArchiveJobCard(job: job) }
        .task(id: url) { await load() }
        .onReceive(job.$outcome) { outcome in
            switch outcome {
            case .created(let folder):
                extracted = folder
                NotificationCenter.default.post(name: .eofFolderChanged, object: url.deletingLastPathComponent(), userInfo: ["created": folder])
            case .failed(let failure):
                error = failure.localizedDescription
            case nil:
                break
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "archivebox.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: summary)
                    .font(.subheadline.weight(.medium))
                if let extracted {
                    Label {
                        Text("Extracted to “\(extracted.lastPathComponent)”")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if showsActions, items != nil {
                Button {
                    extract()
                } label: {
                    Label("Extract", systemImage: "arrow.up.bin")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(job.isRunning)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let items {
            List {
                ForEach(items) { item in
                    ArchiveItemRow(item: item)
                }
                if total > items.count {
                    Text("and \(total - items.count) more items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 28)
        } else if let error {
            ContentUnavailableView {
                Label("Cannot Open Archive", systemImage: "archivebox")
            } description: {
                Text(verbatim: error)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() async {
        let url = url
        let result = await Task.detached { Result { try Archives.contents(of: url) } }.value
        switch result {
        case .success(let listing):
            items = ArchiveContents.withFolders(listing.items)
            total = listing.total
        case .failure(let failure):
            error = failure.localizedDescription
        }
    }

    /// Many archives list only files. Adds a row for each folder they imply, so the indented
    /// entries sit under a visible parent, and sorts the result by path.
    static func withFolders(_ items: [ArchiveItem]) -> [ArchiveItem] {
        var known = Set(items.filter(\.isDirectory).map { $0.path.hasSuffix("/") ? String($0.path.dropLast()) : $0.path })
        var result = items
        var nextID = (items.map(\.id).max() ?? 0) + 1
        for item in items {
            let parts = item.path.split(separator: "/")
            for depth in stride(from: 1, to: parts.count, by: 1) {
                let folder = parts[..<depth].joined(separator: "/")
                if known.insert(folder).inserted {
                    result.append(ArchiveItem(id: nextID, path: folder + "/", size: nil, isDirectory: true))
                    nextID += 1
                }
            }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func extract() {
        let url = url
        error = nil
        job.run(String(localized: "Extracting…"), determinate: format.map(Archives.reportsProgress) ?? false) { progress in
            try Archives.extract(url, progress: progress)
        }
    }
}

/// One entry, indented by its depth and shown by its own name rather than its full path.
private struct ArchiveItemRow: View {
    let item: ArchiveItem

    private var parts: [Substring] { item.path.split(separator: "/") }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isDirectory ? "folder.fill" : FileNode.symbol(for: item.path))
                .font(.system(size: 13))
                .foregroundStyle(item.isDirectory ? Color.accentColor : FileNode.tint(for: item.path))
                .frame(width: 20)
            Text(verbatim: parts.last.map(String.init) ?? item.path)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if !item.isDirectory, let size = item.size {
                Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(min(max(parts.count - 1, 0), 8)) * 16)
        .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
    }
}
