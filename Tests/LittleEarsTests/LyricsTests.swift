import XCTest
import CoreFoundation
@testable import LittleEars

final class LyricsTests: XCTestCase {
    private func track(_ id: String, _ path: String, _ title: String) -> Track {
        Track(id: id, sourceID: "local", relativePath: path, identity: id, title: title, duration: 240, format: "FLAC", fileSize: 100, available: true)
    }
    func testLRCTimestampsOffsetsTranslationsAndSeeking() {
        let text = "\u{feff}[ti:Song]\n[offset:-500]\n[00:03.25][00:05.250]Second\n[00:01.00]First\n[00:01.00]第一句\n[01:02:03.5]Long\n[00:06.00]\n"
        let doc = LyricDocument.parse(text, filename: "test.LRC")
        XCTAssertTrue(doc.timed)
        XCTAssertEqual(doc.lines.map(\.time), [0.5, 2.75, 4.75, 5.5, 3723])
        XCTAssertEqual(doc.lines[0].text, "First\n第一句")
        XCTAssertNil(doc.activeLine(at: 0.49))
        XCTAssertEqual(doc.activeLine(at: 0.5), 0)
        XCTAssertEqual(doc.activeLine(at: 4.8), 2)
        XCTAssertEqual(doc.activeLine(at: 2.8), 1) // Backward seek.
        XCTAssertEqual(doc.activeLine(at: 9999), 4)
        XCTAssertNil(doc.activeLine(at: .nan))
        let positive = LyricDocument.parse("[offset:1000]\n[00:00.2]Start", filename: "a.lrc")
        XCTAssertEqual(positive.lines.first?.time, 1.2)
    }
    func testPlainTextAndInvalidOrEmptyContent() {
        let doc = LyricDocument.parse("\n[00:01]Keep this text\n[Note:literal]\nSecond line\n", filename: "a.txt")
        XCTAssertFalse(doc.timed)
        XCTAssertEqual(doc.lines.count, 3)
        XCTAssertEqual(doc.lines[1].text, "[Note:literal]")
        XCTAssertNil(doc.activeLine(at: 20))
        XCTAssertEqual(LyricDocument.parse("First\r\nSecond", filename: "windows.txt").lines.map(\.text), ["First", "Second"])
        XCTAssertTrue(LyricDocument.parse("[ti:Song]\n[offset:100]", filename: "a.lrc").lines.isEmpty)
        XCTAssertFalse(LyricDocument.parse("[00:99]Bad time", filename: "a.lrc").timed)
    }
    func testMatchingPrioritiesAmbiguityAndVersionProtection() {
        let tracks = [track("one", "a/01 - Singer - Song.flac", "Song"), track("two", "b/01 - Singer - Song.flac", "Song"), track("live", "b/Singer - Song (Live).flac", "Song (Live)")]
        let exact = LyricRecord(filename: "01 - Singer - Song.lrc", sourcePath: "/music/a/01 - Singer - Song.lrc", text: "[00:00]Hello")
        XCTAssertEqual(LyricMatching.candidates(exact, tracks: tracks, roots: ["local": "/music"]).map(\.id), ["one"])
        let ambiguous = LyricRecord(filename: "Song.txt", sourcePath: "/lyrics/Song.txt", text: "Hello")
        XCTAssertEqual(Set(LyricMatching.candidates(ambiguous, tracks: tracks, roots: [:]).map(\.id)), ["one", "two"])
        let live = LyricRecord(filename: "Song (Live).lrc", sourcePath: "/lyrics/live.lrc", text: "[ti:Song]\n[00:00]Hello")
        XCTAssertEqual(LyricMatching.candidates(live, tracks: tracks, roots: [:]).map(\.id), ["live"])
        XCTAssertTrue(LyricMatching.candidates(live, tracks: [tracks[0]], roots: [:]).isEmpty)
        let other = LyricRecord(filename: "Other Singer - Song.lrc", sourcePath: "/lyrics/x.lrc", text: "[00:00]Hello")
        XCTAssertTrue(LyricMatching.candidates(other, tracks: [tracks[0]], roots: [:]).isEmpty)
        XCTAssertEqual(LyricMatching.normalized("01 Song"), LyricMatching.normalized("Song"))
        XCTAssertEqual(LyricMatching.normalized("1943"), "1943")
    }
    @MainActor
    func testBatchImportDuplicatesConflictsManualReplacementAndPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite").path
        let db = try LibraryDatabase(path: path)
        let source = LibrarySource(id: "local", path: directory.path, bookmark: Data(), name: "Music")
        try await db.saveSource(source)
        let tracks = [track("unique", "Unique.flac", "Unique"), track("a", "a/Same.flac", "Same"), track("b", "b/Same.flac", "Same"), track("duplicate", "Duplicate.flac", "Duplicate")]
        try await db.scanResult(sourceID: "local", scanned: tracks)
        let lyrics = directory.appendingPathComponent("lyrics")
        try FileManager.default.createDirectory(at: lyrics, withIntermediateDirectories: true)
        for name in ["Unique.lrc", "Same.lrc", "Unknown.txt", "Duplicate.lrc", "Duplicate.txt"] {
            try "[00:01]Hello\n[00:03]World".write(to: lyrics.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let library = LyricsLibrary()
        try await library.configure(db)
        await library.importFiles([lyrics], tracks: tracks, roots: ["local": directory.path])
        XCTAssertEqual(library.records.count, 5)
        let original = try XCTUnwrap(library.record(for: "unique"))
        XCTAssertNil(library.record(for: "a")); XCTAssertNil(library.record(for: "b"))
        XCTAssertNil(library.record(for: "duplicate")) // Two incoming candidates.
        await library.importFiles([lyrics], tracks: tracks, roots: [:])
        XCTAssertEqual(library.records.count, 5) // No duplicate records on reimport.
        let alternate = lyrics.appendingPathComponent("Alternate.lrc")
        try "[ti:Unique]\n[00:02]Replacement".write(to: alternate, atomically: true, encoding: .utf8)
        await library.importFiles([alternate], tracks: tracks, roots: [:])
        XCTAssertEqual(library.record(for: "unique")?.id, original.id) // Never auto-overwrite.
        let replacement = try XCTUnwrap(library.records.first { $0.filename == "Alternate.lrc" })
        try await library.associate(replacement, with: "unique")
        XCTAssertEqual(library.record(for: "unique")?.id, replacement.id)
        XCTAssertNil(library.records.first { $0.id == original.id }?.trackID)
        let restored = LyricsLibrary()
        try await restored.configure(LibraryDatabase(path: path))
        XCTAssertEqual(restored.record(for: "unique")?.id, replacement.id)
        XCTAssertEqual(restored.document(for: replacement).lines.first?.time, 2)
        try await restored.associate(replacement, with: nil)
        XCTAssertNil(restored.record(for: "unique"))
        XCTAssertEqual(restored.records.count, 6) // Unlink retains imported text.
    }
    @MainActor
    func testUTF16ImportAndEmptyFilesDoNotReplaceLyrics() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try LibraryDatabase(path: ":memory:")
        try await db.saveSource(LibrarySource(id: "local", path: directory.path, bookmark: Data(), name: "Music"))
        let song = track("song", "Song.flac", "Song")
        try await db.scanResult(sourceID: "local", scanned: [song])
        let file = directory.appendingPathComponent("Song.lrc")
        try "[00:01.50]你好".write(to: file, atomically: true, encoding: .utf16)
        let library = LyricsLibrary(); try await library.configure(db)
        await library.importFiles([file], tracks: [song], roots: [:])
        let original = try XCTUnwrap(library.record(for: song.id))
        XCTAssertEqual(library.document(for: original).lines[0].text, "你好")
        try "[ti:Song]\n".write(to: file, atomically: true, encoding: .utf8)
        await library.importFiles([file], tracks: [song], roots: [:], target: song)
        XCTAssertEqual(library.record(for: song.id)?.id, original.id)
        XCTAssertTrue(library.message?.contains("无法读取有效歌词") == true)
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let gbFile = directory.appendingPathComponent("Chinese.lrc")
        try XCTUnwrap("[00:02]中文歌词".data(using: gb)).write(to: gbFile)
        await library.importFiles([gbFile], tracks: [song], roots: [:])
        let gbRecord = try XCTUnwrap(library.records.first { $0.filename == "Chinese.lrc" })
        XCTAssertEqual(library.document(for: gbRecord).lines.first?.text, "中文歌词")
    }
}
