import XCTest
@testable import EOFCore

final class ArchiveTests: XCTestCase {
    // Made with Python's tarfile, gzip, bz2 and lzma modules.
    private static let fixtures: [String: String] = [
        "txz": "/Td6WFoAAATm1rRGAgAhARYAAAB0L+Wj4Cf/AI9dADgayRWYrNGyNLfGdGcdDih9Ep0T9bXEgo8sqfq6AWIHES+IZM8gNuwfoi0Hqqo136yOAKD4XAEq2UVsgRaZ+lS96YbZZEs6HQDakPvGQLkMGkRpbE+beK5VdjYfAXoDu81K3brWegksoin70sRMRud12FHyF17XGAmmOcD99pGfUsox/mTWEFsyfF9bbu0rAAAI1Dkgl52P/wABqwGAUAAAy4QLDLHEZ/sCAAAAAARZWg==",
        "evil": "H4sIAFps/WoC/+3NMQqDQBQE0H8UT7AxsOh5UlgEUukqHj8bK0mvIL7XzDDNpPQYlvcnlbXEUdqqy3nL6j+r567/9r7LfTRtnGCeymusl3FPawAAAAAAAAAAAHBFX8saWGcAKAAA",
        "link": "H4sIAFps/WoC/+3TMQ5AQBCF4TnKnoBdEXseQSEEsSsc31LJKlQ0/q95k2mmmTd2id+8vEoHRZ6fGcQZZJf52FujrSgtH1icL+dwUv5p7AQ/1rfD6x/w3P9oNrqwRlSWNr5Kp9K5tab/AAAAAAAAAAAAAAAAwN0OgssFnQAoAAA=",
        "junk": "H4sIAFNs/WoC/+3XMQ4CIRBA0TmKJ0Bgka2NtbHYxo5gaWOiGD2+aGW2W5OhkP8aCA3VZ0I25VlEl61iCJ+1mq+V+9q/z+PoNrKy0sD9VvK1Xil9yoKepbTf7g7TcW1S1noKFvfvbPCe/ls4k0DXTDqp3/HD/B+Y//QPfeVxUf8BLO9/HGyk/xY8CQAAAAAAAAAAAPyVF64wUzgAKAAA",
        "gz": "H4sIAAAAAAAC/yvOzEvPSVVIr8os4AIAGr2uCgwAAAA=",
        "bz2": "QlpoOTFBWSZTWQeoUZ4AAAXZgAAQQAAQABKlSBAgACIADIQNA0Hnp3gQUB8XckU4UJAHqFGe",
        "xz": "/Td6WFoAAATm1rRGAgAhARYAAAB0L+WjAQAJc2luZ2xlIHh6CgAAAL8qz2s+RlvLAAEiChUa4WcftvN9AQAAAAAEWVo=",
    ]

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("eof-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func fixture(_ key: String, named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(Self.fixtures[key]))).write(to: url)
        return url
    }

    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    func testFormatRecognition() {
        let cases: [(String, ArchiveFormat?)] = [
            ("a.zip", .zip), ("a.ZIP", .zip), ("a.tar", .tar), ("a.tar.gz", .tarGzip), ("a.tgz", .tarGzip),
            ("a.tar.bz2", .tarBzip2), ("a.tbz2", .tarBzip2), ("a.tar.xz", .tarXz), ("a.txz", .tarXz),
            ("a.7z", .sevenZip), ("notes.md.gz", .gzip), ("x.bz2", .bzip2), ("x.xz", .xz),
            ("a.md", nil), (".gz", nil), ("tar", nil), ("a.svgz", nil),
        ]
        for (name, format) in cases { XCTAssertEqual(ArchiveFormat.of(name), format, name) }
        XCTAssertEqual(ArchiveFormat.tarGzip.baseName(of: "logs.tar.gz"), "logs")
        XCTAssertEqual(ArchiveFormat.tarGzip.baseName(of: "logs.TGZ"), "logs")
        XCTAssertEqual(ArchiveFormat.gzip.baseName(of: "notes.md.gz"), "notes.md")
    }

    func testSafePaths() {
        let base = URL(fileURLWithPath: "/tmp/x")
        XCTAssertEqual(ArchivePaths.destination(for: "a/b.txt", in: base)?.path, "/tmp/x/a/b.txt")
        XCTAssertEqual(ArchivePaths.destination(for: "./a//b.txt", in: base)?.path, "/tmp/x/a/b.txt")
        XCTAssertNil(ArchivePaths.destination(for: "../a", in: base))
        XCTAssertNil(ArchivePaths.destination(for: "a/../../b", in: base))
        XCTAssertNil(ArchivePaths.destination(for: "/etc/passwd", in: base))
        XCTAssertNil(ArchivePaths.destination(for: "./", in: base))
        XCTAssertTrue(ArchiveJunk.isJunk("__MACOSX/._a"))
        XCTAssertTrue(ArchiveJunk.isJunk("dir/.DS_Store"))
        XCTAssertTrue(ArchiveJunk.isJunk("dir/._b"))
        XCTAssertFalse(ArchiveJunk.isJunk("dir/.env"))
    }

    func testTarRoundTripInEveryWritableFormat() throws {
        let source = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let body = String(repeating: "line of text \u{4E2D}\u{6587}\n", count: 300)
        try body.write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "nested".write(to: source.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)
        try "junk".write(to: source.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        for format in [ArchiveFormat.tar, .tarGzip, .tarBzip2] {
            let archive = root.appendingPathComponent("project" + format.suffixes[0])
            try ArchiveCodec.create([source], relativeTo: root, format: format, at: archive)
            let listed = try ArchiveCodec.list(archive, format: format)
            XCTAssertEqual(Set(listed.items.map(\.path)), ["project/", "project/a.txt", "project/sub/", "project/sub/b.txt"], "\(format)")
            if format != .tar {
                let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                XCTAssertLessThan(size, body.utf8.count / 2, "\(format) should compress")
            }
            let out = try ArchiveExtraction.extract(archive, format: format) { try ArchiveCodec.extract(archive, format: format, to: $0) }
            // One top-level folder: it comes out under its own name, not nested in another folder.
            XCTAssertEqual(out.lastPathComponent, "project 2", "\(format)") // "project" itself is the source folder
            XCTAssertEqual(text(out.appendingPathComponent("a.txt")), body, "\(format)")
            XCTAssertEqual(text(out.appendingPathComponent("sub/b.txt")), "nested", "\(format)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent(".DS_Store").path))
            try FileManager.default.removeItem(at: out)
        }
        // No staging folders are left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".eof") }
        XCTAssertEqual(leftovers, [])
    }

    func testReadsTarXzAndSingleFileFormats() throws {
        let txz = try fixture("txz", named: "pkg.tar.xz")
        XCTAssertEqual(Set(try ArchiveCodec.list(txz, format: .tarXz).items.map(\.path)), ["pkg/", "pkg/a.txt", "pkg/sub/b.txt"])
        let pkg = try ArchiveExtraction.extract(txz, format: .tarXz) { try ArchiveCodec.extract(txz, format: .tarXz, to: $0) }
        XCTAssertEqual(pkg.lastPathComponent, "pkg")
        XCTAssertEqual(text(pkg.appendingPathComponent("a.txt")), "hello xz\n")
        XCTAssertEqual(text(pkg.appendingPathComponent("sub/b.txt")), "nested\n")

        for (key, format, expected) in [("gz", ArchiveFormat.gzip, "single gzip\n"), ("bz2", .bzip2, "single bzip2\n"), ("xz", .xz, "single xz\n")] {
            let url = try fixture(key, named: "notes.md." + key)
            let listed = try ArchiveCodec.list(url, format: format)
            XCTAssertEqual(listed.items.map(\.path), ["notes.md"], key)
            XCTAssertEqual(listed.items.first?.size, expected.utf8.count, key)
            let out = try ArchiveExtraction.extract(url, format: format) { try ArchiveCodec.extract(url, format: format, to: $0) }
            XCTAssertEqual(out.lastPathComponent, "notes.md", key)
            XCTAssertEqual(text(out), expected, key)
            try FileManager.default.removeItem(at: out)
        }
    }

    func testSeveralTopLevelItemsGoIntoAFolderAndJunkIsDropped() throws {
        let url = try fixture("junk", named: "mixed.tar.gz")
        XCTAssertEqual(try ArchiveCodec.list(url, format: .tarGzip).items.map(\.path), ["a.txt", "two.txt"])
        let out = try ArchiveExtraction.extract(url, format: .tarGzip) { try ArchiveCodec.extract(url, format: .tarGzip, to: $0) }
        XCTAssertEqual(out.lastPathComponent, "mixed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted(), ["a.txt", "two.txt"])
    }

    func testEscapingPathsAndLinksAreRefused() throws {
        let evil = try fixture("evil", named: "evil.tar.gz")
        XCTAssertThrowsError(try ArchiveExtraction.extract(evil, format: .tarGzip) { try ArchiveCodec.extract(evil, format: .tarGzip, to: $0) }) { error in
            XCTAssertEqual(error as? ArchiveError, .unsafePath("../evil.txt"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("evil.txt").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".eof") }, [])

        let link = try fixture("link", named: "link.tar.gz")
        let out = try ArchiveExtraction.extract(link, format: .tarGzip) { try ArchiveCodec.extract(link, format: .tarGzip, to: $0) }
        // The symbolic link is skipped; only the regular file comes out.
        XCTAssertEqual(out.lastPathComponent, "ok.txt")
        XCTAssertEqual(text(out), "ok")
    }

    func testDamagedInputGivesAReadableError() throws {
        let url = root.appendingPathComponent("broken.tar.gz")
        try Data("not an archive".utf8).write(to: url)
        XCTAssertThrowsError(try ArchiveCodec.list(url, format: .tarGzip)) { error in
            guard case .unreadable? = error as? ArchiveError else { return XCTFail("\(error)") }
        }
        let seven = root.appendingPathComponent("broken.7z")
        try Data("not 7z".utf8).write(to: seven)
        XCTAssertThrowsError(try ArchiveCodec.list(seven, format: .sevenZip))
    }
}
