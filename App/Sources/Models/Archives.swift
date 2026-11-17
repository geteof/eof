import Foundation
import ZIPFoundation

/// Zip archives: create, extract and list, through ZIPFoundation.
enum Archives {
    struct Item: Identifiable {
        let id: Int
        let path: String
        let size: UInt64
        let isDirectory: Bool
    }

    static func isArchive(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "zip"
    }

    /// A name in `folder` that is not taken yet: "base.ext", then "base 2.ext", "base 3.ext"…
    static func freeURL(in folder: URL, base: String, ext: String) -> URL {
        var index = 1
        while true {
            let name = (index == 1 ? base : "\(base) \(index)") + (ext.isEmpty ? "" : "." + ext)
            let candidate = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) || index > 999 { return candidate }
            index += 1
        }
    }

    /// Zips the items into one archive next to them and returns its location. One item gives
    /// "name.zip"; several give "Archive.zip" with each item at the top level.
    static func compress(_ items: [URL], archiveName: String, progress: Progress? = nil) throws -> URL {
        guard let first = items.first else { throw CocoaError(.fileNoSuchFile) }
        let folder = first.deletingLastPathComponent()
        if items.count == 1 {
            let isDirectory = (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let base = isDirectory ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent
            let destination = freeURL(in: folder, base: base.isEmpty ? first.lastPathComponent : base, ext: "zip")
            try FileManager.default.zipItem(at: first, to: destination, shouldKeepParent: true, compressionMethod: .deflate, progress: progress)
            return destination
        }
        let destination = freeURL(in: folder, base: archiveName, ext: "zip")
        do {
            let archive = try Archive(url: destination, accessMode: .create)
            for item in items {
                let name = item.lastPathComponent
                let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                try archive.addEntry(with: name, relativeTo: folder, compressionMethod: .deflate)
                guard isDirectory else { continue }
                for sub in try FileManager.default.subpathsOfDirectory(atPath: item.path) where !sub.hasSuffix(".DS_Store") {
                    try archive.addEntry(with: name + "/" + sub, relativeTo: folder, compressionMethod: .deflate)
                }
            }
        } catch {
            // Do not leave half an archive behind.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    /// Unpacks the archive into a new folder beside it, named after the archive. The library refuses
    /// entries whose path would land outside that folder.
    static func extract(_ archive: URL, progress: Progress? = nil) throws -> URL {
        let folder = archive.deletingLastPathComponent()
        let destination = freeURL(in: folder, base: archive.deletingPathExtension().lastPathComponent, ext: "")
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: archive, to: destination, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    /// What is inside, without unpacking. `total` counts every entry even when the list is cut short.
    static func contents(of url: URL, limit: Int = 400) -> (items: [Item], total: Int)? {
        guard let archive = try? Archive(url: url, accessMode: .read) else { return nil }
        var items: [Item] = []
        var total = 0
        for entry in archive {
            if total < limit, !entry.path.hasPrefix("__MACOSX/") {
                items.append(Item(id: total, path: entry.path, size: entry.uncompressedSize, isDirectory: entry.type == .directory))
            }
            total += 1
        }
        return (items, total)
    }
}
