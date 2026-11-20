import Foundation

/// Coordinated, security-scoped file I/O. Every call opens and closes its own access to the URL,
/// so files picked from other apps and cloud providers work the same as local ones.
enum FileAccess {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func withAccess<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    static func read(_ url: URL) throws -> Data {
        try withAccess(url) {
            var result: Result<Data, Error> = .failure(Failure(message: "The file could not be read."))
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { actual in
                result = Result {
                    let size = (try? actual.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return try Data(contentsOf: actual, options: size > 16_000_000 ? .mappedIfSafe : [])
                }
            }
            if let coordinationError { throw coordinationError }
            return try result.get()
        }
    }

    static func write(_ data: Data, to url: URL) throws {
        try withAccess(url) {
            var result: Result<Void, Error> = .success(())
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { actual in
                result = Result { try data.write(to: actual, options: .atomic) }
            }
            if let coordinationError { throw coordinationError }
            try result.get()
        }
    }

    static func modificationDate(_ url: URL) -> Date? {
        withAccess(url) {
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
    }

    static func exists(_ url: URL) -> Bool {
        withAccess(url) { FileManager.default.fileExists(atPath: url.path) }
    }

    static func bookmark(for url: URL) -> Data? {
        withAccess(url) { try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
    }

    static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    static var draftsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// A short, readable location for lists: the folder that holds the file.
    /// The name to show for a file or folder. The top folder another app shares through the
    /// Files app is called "File Provider Storage" on disk, which means nothing to the user.
    static func displayName(_ url: URL) -> String {
        url.lastPathComponent == "File Provider Storage" ? String(localized: "Folder from Another App") : url.lastPathComponent
    }

    static func displayLocation(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent()
        let path = parent.path
        if let range = path.range(of: "/Documents") , path.contains("/Containers/") || path.contains("/Application/") {
            let rest = path[range.upperBound...]
            return rest.isEmpty ? String(localized: "On My Device") : String(rest.dropFirst())
        }
        if path.contains("com~apple~CloudDocs") {
            let rest = path.components(separatedBy: "com~apple~CloudDocs").last ?? ""
            return rest.isEmpty ? String(localized: "iCloud Drive") : (rest as NSString).lastPathComponent
        }
        // Another app's storage (a file provider) or a copy another app handed over: the folder
        // names on the way are internal, so say where it came from instead.
        if path.hasSuffix("/File Provider Storage") || path.hasSuffix("/Inbox") || parent.lastPathComponent.count == 36 {
            return String(localized: "Other App")
        }
        if path.contains("/File Provider Storage/") { return parent.lastPathComponent }
        return parent.lastPathComponent
    }
}
