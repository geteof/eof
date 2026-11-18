import Foundation
import SWCompression

/// The archive and compression formats EOF reads, and the ones it can create.
public enum ArchiveFormat: String, CaseIterable, Identifiable, Sendable {
    case zip, tar, tarGzip, tarBzip2, tarXz, sevenZip, gzip, bzip2, xz

    public var id: String { rawValue }

    /// Recognises a format from a file name. Compound names (`.tar.gz`) win over their last part.
    public static func of(_ name: String) -> ArchiveFormat? {
        let lower = name.lowercased()
        for format in ArchiveFormat.allCases.sorted(by: { $0.longestSuffix > $1.longestSuffix }) {
            if format.suffixes.contains(where: { lower.hasSuffix($0) && lower.count > $0.count }) { return format }
        }
        return nil
    }

    /// Every file-name ending of the format, the usual one first.
    public var suffixes: [String] {
        switch self {
        case .zip: return [".zip"]
        case .tar: return [".tar"]
        case .tarGzip: return [".tar.gz", ".tgz"]
        case .tarBzip2: return [".tar.bz2", ".tbz2", ".tbz"]
        case .tarXz: return [".tar.xz", ".txz"]
        case .sevenZip: return [".7z"]
        case .gzip: return [".gz"]
        case .bzip2: return [".bz2"]
        case .xz: return [".xz"]
        }
    }

    private var longestSuffix: Int { suffixes.map(\.count).max() ?? 0 }

    public var displayName: String {
        switch self {
        case .zip: return "ZIP"
        case .tar: return "TAR"
        case .tarGzip: return "TAR.GZ"
        case .tarBzip2: return "TAR.BZ2"
        case .tarXz: return "TAR.XZ"
        case .sevenZip: return "7Z"
        case .gzip: return "GZ"
        case .bzip2: return "BZ2"
        case .xz: return "XZ"
        }
    }

    /// Formats offered when compressing. 7z, xz and RAR can only be read.
    public static let creatable: [ArchiveFormat] = [.zip, .tarGzip, .tarBzip2, .tar]

    /// True for formats that compress one file rather than holding several.
    public var isSingleFile: Bool { self == .gzip || self == .bzip2 || self == .xz }

    /// "logs.tar.gz" → "logs"; "notes.md.gz" → "notes.md".
    public func baseName(of name: String) -> String {
        let lower = name.lowercased()
        for suffix in suffixes where lower.hasSuffix(suffix) && name.count > suffix.count {
            return String(name.dropLast(suffix.count))
        }
        return name
    }
}

public enum ArchiveError: Error, LocalizedError, Equatable {
    case tooLarge(limit: Int)
    case unsafePath(String)
    case unreadable(String)

    public var errorDescription: String? {
        // Messages are looked up in the app's string catalog; Linux has no `String(localized:)`.
        #if canImport(Darwin)
        switch self {
        case .tooLarge(let limit):
            return String(localized: "This archive is larger than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)), the most EOF can handle in this format. ZIP archives have no such limit.")
        case .unsafePath(let path):
            return String(localized: "The archive contains a path that points outside its folder: \(path)")
        case .unreadable(let detail):
            return String(localized: "The archive could not be read. It may be damaged, encrypted, or in a variant EOF does not support.") + "\n" + detail
        }
        #else
        switch self {
        case .tooLarge(let limit): return "This archive is larger than \(limit) bytes."
        case .unsafePath(let path): return "The archive contains a path that points outside its folder: \(path)"
        case .unreadable(let detail): return "The archive could not be read.\n" + detail
        }
        #endif
    }
}

/// An entry inside an archive, for listing without unpacking.
public struct ArchiveItem: Identifiable, Equatable, Sendable {
    public var id: Int
    public var path: String
    public var size: Int?
    public var isDirectory: Bool

    public init(id: Int, path: String, size: Int?, isDirectory: Bool) {
        self.id = id
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
    }
}

/// Files that archives made on a Mac carry along and nobody wants unpacked.
public enum ArchiveJunk {
    public static func isJunk(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        if parts.first == "__MACOSX" { return true }
        guard let last = parts.last else { return false }
        return last == ".DS_Store" || last.hasPrefix("._")
    }
}

public enum ArchivePaths {
    /// Where an entry may be written inside `root`, or nil for a path that would escape it
    /// (absolute paths and `..` components are refused; `./` is ignored).
    public static func destination(for entryPath: String, in root: URL) -> URL? {
        guard !entryPath.hasPrefix("/") else { return nil }
        var url = root
        var components = 0
        for part in entryPath.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { return nil }
            url.appendPathComponent(String(part))
            components += 1
        }
        return components > 0 ? url : nil
    }

    /// A name in `folder` that is not taken yet: "base.ext", then "base 2.ext", "base 3.ext"…
    public static func freeURL(in folder: URL, base: String, ext: String) -> URL {
        var index = 1
        while true {
            let name = (index == 1 ? base : "\(base) \(index)") + (ext.isEmpty ? "" : "." + ext)
            let candidate = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) || index > 9999 { return candidate }
            index += 1
        }
    }
}

/// Reading and writing every format except ZIP, which the app handles with a streaming library.
public enum ArchiveCodec {
    /// Compressed formats other than ZIP and TAR are decoded in memory, so they have a size limit.
    public static let memoryLimit = 512 * 1024 * 1024

    // MARK: Listing

    public static func list(_ url: URL, format: ArchiveFormat, limit: Int = 500) throws -> (items: [ArchiveItem], total: Int) {
        switch format {
        case .zip:
            preconditionFailure("ZIP is listed by the app")
        case .sevenZip:
            let infos = try decode { try SevenZipContainer.info(container: try read(url)) }
            let shown = infos.filter { !ArchiveJunk.isJunk($0.name) }
            let items = shown.prefix(limit).enumerated().map { index, info in
                ArchiveItem(id: index, path: info.name, size: info.size, isDirectory: info.type == .directory)
            }
            return (items, shown.count)
        case .gzip, .bzip2, .xz:
            let data = try decompress(try read(url), format: format)
            return ([ArchiveItem(id: 0, path: format.baseName(of: url.lastPathComponent), size: data.count, isDirectory: false)], 1)
        case .tar, .tarGzip, .tarBzip2, .tarXz:
            var items: [ArchiveItem] = []
            var total = 0
            try withTarReader(url, format: format) { reader in
                while let entry = try decode({ try reader.read() }) {
                    let info = entry.info
                    guard !ArchiveJunk.isJunk(info.name) else { continue }
                    if items.count < limit {
                        items.append(ArchiveItem(id: total, path: info.name, size: info.size, isDirectory: info.type == .directory))
                    }
                    total += 1
                }
            }
            return (items, total)
        }
    }

    // MARK: Extracting

    /// Unpacks into `destination`, which must exist. Symbolic and hard links are skipped, so nothing
    /// can be written outside the folder through them.
    public static func extract(_ url: URL, format: ArchiveFormat, to destination: URL) throws {
        switch format {
        case .zip:
            preconditionFailure("ZIP is extracted by the app")
        case .sevenZip:
            let entries = try decode { try SevenZipContainer.open(container: try read(url)) }
            for entry in entries {
                try write(name: entry.info.name, type: entry.info.type, data: entry.data, into: destination)
            }
        case .gzip, .bzip2, .xz:
            let data = try decompress(try read(url), format: format)
            try data.write(to: destination.appendingPathComponent(format.baseName(of: url.lastPathComponent)))
        case .tar, .tarGzip, .tarBzip2, .tarXz:
            try withTarReader(url, format: format) { reader in
                while let entry = try decode({ try reader.read() }) {
                    try write(name: entry.info.name, type: entry.info.type, data: entry.data, into: destination)
                }
            }
        }
    }

    private static func write(name: String, type: ContainerEntryType, data: Data?, into root: URL) throws {
        guard !ArchiveJunk.isJunk(name) else { return }
        guard let target = ArchivePaths.destination(for: name, in: root) else {
            // An entry that is only "./" names the root itself.
            if name.split(separator: "/").allSatisfy({ $0 == "." }) { return }
            throw ArchiveError.unsafePath(name)
        }
        let manager = FileManager.default
        switch type {
        case .directory:
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
        case .regular, .contiguous:
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (data ?? Data()).write(to: target)
        default:
            break
        }
    }

    // MARK: Creating

    /// Writes `items` (files or folders, all inside `base`) into a new TAR archive at `destination`,
    /// compressed when the format asks for it.
    public static func create(_ items: [URL], relativeTo base: URL, format: ArchiveFormat, at destination: URL) throws {
        precondition([.tar, .tarGzip, .tarBzip2].contains(format), "unsupported format for writing")
        let manager = FileManager.default
        let tarURL = format == .tar ? destination : destination.deletingLastPathComponent()
            .appendingPathComponent(".eof-\(UUID().uuidString).tar")
        defer { if format != .tar { try? manager.removeItem(at: tarURL) } }
        guard manager.createFile(atPath: tarURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tarURL.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: tarURL)
            defer { try? handle.close() }
            var writer = TarWriter(fileHandle: handle)
            let basePath = base.standardizedFileURL.path
            func relative(_ url: URL) -> String {
                let path = url.standardizedFileURL.path
                return path.hasPrefix(basePath + "/") ? String(path.dropFirst(basePath.count + 1)) : url.lastPathComponent
            }
            func add(_ url: URL) throws {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
                if values.isSymbolicLink == true { return }
                let name = relative(url)
                guard !ArchiveJunk.isJunk(name) else { return }
                if values.isDirectory == true {
                    var info = TarEntryInfo(name: name + "/", type: .directory)
                    info.permissions = Permissions(rawValue: 0o755)
                    info.modificationTime = values.contentModificationDate
                    try writer.append(TarEntry(info: info, data: nil))
                    let children = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    for child in children { try add(child) }
                } else {
                    var info = TarEntryInfo(name: name, type: .regular)
                    info.permissions = Permissions(rawValue: 0o644)
                    info.modificationTime = values.contentModificationDate
                    try writer.append(TarEntry(info: info, data: try Data(contentsOf: url)))
                }
            }
            for item in items { try add(item) }
            try writer.finalize()
        } catch {
            try? manager.removeItem(at: tarURL)
            throw error
        }
        guard format != .tar else { return }
        let tarData = try read(tarURL)
        let compressed: Data
        switch format {
        case .tarGzip: compressed = try GzipArchive.archive(data: tarData)
        case .tarBzip2: compressed = BZip2.compress(data: tarData)
        default: compressed = tarData
        }
        try compressed.write(to: destination)
    }

    // MARK: Helpers

    private static func read(_ url: URL) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= memoryLimit else { throw ArchiveError.tooLarge(limit: memoryLimit) }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func decompress(_ data: Data, format: ArchiveFormat) throws -> Data {
        try decode {
            switch format {
            case .gzip, .tarGzip: return try GzipArchive.unarchive(archive: data)
            case .bzip2, .tarBzip2: return try BZip2.decompress(data: data)
            case .xz, .tarXz: return try XZArchive.unarchive(archive: data)
            default: return data
            }
        }
    }

    /// Opens a TAR stream: the file itself, or its decompressed copy in a temporary file.
    private static func withTarReader(_ url: URL, format: ArchiveFormat, _ body: (inout TarReader) throws -> Void) throws {
        var tarURL = url
        var temporary: URL?
        if format != .tar {
            let data = try decompress(try read(url), format: format)
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("eof-\(UUID().uuidString).tar")
            try data.write(to: scratch)
            tarURL = scratch
            temporary = scratch
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        let handle = try FileHandle(forReadingFrom: tarURL)
        defer { try? handle.close() }
        var reader = TarReader(fileHandle: handle)
        try body(&reader)
    }

    /// Turns the library's format errors into one readable message; file errors pass through.
    private static func decode<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as ArchiveError {
            throw error
        } catch let error as CocoaError {
            throw error
        } catch {
            throw ArchiveError.unreadable(String(describing: error))
        }
    }
}

/// Puts unpacked files in place the way the Finder does.
public enum ArchiveExtraction {
    /// Deletes `__MACOSX`, `.DS_Store` and `._*` files anywhere below `folder`.
    static func removeJunk(in folder: URL) {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        var doomed: [URL] = []
        let base = folder.standardizedFileURL.path
        while let item = walker.nextObject() as? URL {
            let path = String(item.standardizedFileURL.path.dropFirst(base.count + 1))
            if ArchiveJunk.isJunk(path) {
                doomed.append(item)
                walker.skipDescendants()
            }
        }
        doomed.forEach { try? manager.removeItem(at: $0) }
    }

    /// Runs `unpack` into a hidden folder beside the archive, then moves the result out: a single
    /// top-level item keeps its own name, several go into a folder named after the archive. Either
    /// way the name is made unique, and nothing is left behind if unpacking fails.
    public static func extract(_ archive: URL, format: ArchiveFormat, unpack: (URL) throws -> Void) throws -> URL {
        let manager = FileManager.default
        let folder = archive.deletingLastPathComponent()
        let staging = folder.appendingPathComponent(".eof-extract-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        try unpack(staging)
        removeJunk(in: staging)
        let top = try manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        if top.count == 1, let only = top.first {
            let name = only.lastPathComponent
            let isDirectory = (try? only.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let ext = isDirectory ? "" : (name as NSString).pathExtension
            let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
            let target = ArchivePaths.freeURL(in: folder, base: base, ext: ext)
            try manager.moveItem(at: only, to: target)
            return target
        }
        let target = ArchivePaths.freeURL(in: folder, base: format.baseName(of: archive.lastPathComponent), ext: "")
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
        for item in top {
            try manager.moveItem(at: item, to: target.appendingPathComponent(item.lastPathComponent))
        }
        return target
    }
}
