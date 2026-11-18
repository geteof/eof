import EOFCore
import Foundation
import ZIPFoundation

/// Archives in every format EOF knows. ZIP goes through ZIPFoundation, which streams and reports
/// progress; the other formats go through EOFCore.
enum Archives {
    typealias Item = ArchiveItem

    static func format(_ url: URL) -> ArchiveFormat? {
        ArchiveFormat.of(url.lastPathComponent)
    }

    static func isArchive(_ url: URL) -> Bool {
        format(url) != nil
    }

    /// Only ZIP reports how far along it is; the rest show an indeterminate spinner.
    static func reportsProgress(_ format: ArchiveFormat) -> Bool {
        format == .zip
    }

    /// Writes the items into one archive next to them and returns its location. One item gives
    /// "name.zip"; several give "Archive.zip" with each item at the top level. A cancelled
    /// `progress` stops ZIP output and removes what was written.
    static func compress(_ items: [URL], format: ArchiveFormat, archiveName: String, progress: Progress? = nil) throws -> URL {
        guard let first = items.first else { throw CocoaError(.fileNoSuchFile) }
        let folder = first.deletingLastPathComponent()
        let ext = String(format.suffixes[0].dropFirst())
        let destination: URL
        if items.count == 1 {
            let isDirectory = (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let base = isDirectory ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent
            destination = ArchivePaths.freeURL(in: folder, base: base.isEmpty ? first.lastPathComponent : base, ext: ext)
        } else {
            destination = ArchivePaths.freeURL(in: folder, base: archiveName, ext: ext)
        }
        do {
            if format == .zip {
                try writeZip(items, relativeTo: folder, to: destination, progress: progress)
            } else {
                try ArchiveCodec.create(items, relativeTo: folder, format: format, at: destination)
            }
        } catch {
            // Do not leave half an archive behind.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    private static func writeZip(_ items: [URL], relativeTo folder: URL, to destination: URL, progress: Progress?) throws {
        let archive = try Archive(url: destination, accessMode: .create)
        var paths: [String] = []
        for item in items {
            let name = item.lastPathComponent
            paths.append(name)
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            for sub in try FileManager.default.subpathsOfDirectory(atPath: item.path) where !ArchiveJunk.isJunk(sub) {
                paths.append(name + "/" + sub)
            }
        }
        progress?.totalUnitCount = Int64(paths.count)
        for path in paths {
            if progress?.isCancelled == true { throw CocoaError(.userCancelled) }
            try archive.addEntry(with: path, relativeTo: folder, compressionMethod: .deflate)
            progress?.completedUnitCount += 1
        }
    }

    /// Unpacks beside the archive. One top-level item comes out under its own name; several go into
    /// a folder named after the archive. Paths that would leave that folder are refused.
    static func extract(_ url: URL, progress: Progress? = nil) throws -> URL {
        guard let format = format(url) else { throw ArchiveError.unreadable(url.lastPathComponent) }
        return try ArchiveExtraction.extract(url, format: format) { staging in
            if format == .zip {
                do {
                    try FileManager.default.unzipItem(at: url, to: staging, progress: progress)
                } catch Archive.ArchiveError.cancelledOperation {
                    throw CocoaError(.userCancelled)
                } catch let error as CocoaError where error.code == .fileReadInvalidFileName {
                    throw ArchiveError.unsafePath(error.userInfo[NSFilePathErrorKey] as? String ?? "")
                } catch let error as CocoaError {
                    throw error
                } catch {
                    throw ArchiveError.unreadable(String(describing: error))
                }
            } else {
                try ArchiveCodec.extract(url, format: format, to: staging)
            }
        }
    }

    /// What is inside, without unpacking. `total` counts every entry even when the list is cut short.
    static func contents(of url: URL, limit: Int = 500) throws -> (items: [Item], total: Int) {
        guard let format = format(url) else { throw ArchiveError.unreadable(url.lastPathComponent) }
        guard format == .zip else { return try ArchiveCodec.list(url, format: format, limit: limit) }
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ArchiveError.unreadable(String(describing: error))
        }
        var items: [Item] = []
        var total = 0
        for entry in archive where !ArchiveJunk.isJunk(entry.path) {
            if items.count < limit {
                items.append(Item(id: total, path: entry.path, size: Int(clamping: entry.uncompressedSize), isDirectory: entry.type == .directory))
            }
            total += 1
        }
        return (items, total)
    }
}

extension Notification.Name {
    /// Posted with the folder's URL after files were added to it outside the browser page showing it.
    static let eofFolderChanged = Notification.Name("EOFFolderChanged")
}
