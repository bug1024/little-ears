import Foundation
import CoreFoundation
import SwiftUI
import GRDB
import AppKit

struct LyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    let time: Double?
    let text: String
}
struct LyricDocument: Sendable {
    let lines: [LyricLine]
    var timed: Bool { lines.first?.time != nil }
    func activeLine(at position: Double) -> Int? {
        guard timed, position.isFinite else { return nil }
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if (lines[mid].time ?? .infinity) <= position { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }
    static func parse(_ text: String, filename: String) -> LyricDocument {
        let rows = text.replacingOccurrences(of: "\u{feff}", with: "").replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        let tag = try! NSRegularExpression(pattern: #"\[(\d{1,3}:\d{2}(?::\d{2})?(?:\.\d{1,3})?)\]"#)
        let metadata = try! NSRegularExpression(pattern: #"^\s*\[[a-zA-Z]+:.*\]\s*$"#)
        var offset = 0.0
        for row in rows {
            if row.lowercased().hasPrefix("[offset:"), let end = row.firstIndex(of: "]"), let value = Double(row[row.index(row.startIndex, offsetBy: 8)..<end]), value.isFinite { offset = max(-3600000, min(3600000, value)) / 1000 }
        }
        let isLRC = (filename as NSString).pathExtension.lowercased() == "lrc"
        var timed: [(Double, String, Int)] = []
        var plain: [String] = []
        for row in rows {
            let range = NSRange(row.startIndex..., in: row)
            if isLRC && metadata.firstMatch(in: row, range: range) != nil { continue }
            plain.append(row)
            guard isLRC else { continue }
            let matches = tag.matches(in: row, range: range)
            guard let last = matches.last, let end = Range(last.range, in: row)?.upperBound else { continue }
            let content = String(row[end...]).trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let r = Range(match.range(at: 1), in: row) else { continue }
                let pieces = row[r].split(separator: ":").compactMap { Double($0) }
                guard (pieces.count == 2 || pieces.count == 3), let seconds = pieces.last, seconds < 60 else { continue }
                if pieces.count == 3 && pieces[1] >= 60 { continue }
                let time = pieces.count == 2 ? pieces[0] * 60 + seconds : pieces[0] * 3600 + pieces[1] * 60 + seconds
                timed.append((max(0, time + offset), content, timed.count))
            }
        }
        if !timed.isEmpty {
            timed.sort { $0.0 == $1.0 ? $0.2 < $1.2 : $0.0 < $1.0 }
            var grouped: [(Double, String)] = []
            for (time, content, _) in timed {
                if grouped.last?.0 == time {
                    if !content.isEmpty { grouped[grouped.count - 1].1 += (grouped.last!.1.isEmpty ? "" : "\n") + content }
                } else { grouped.append((time, content)) }
            }
            return LyricDocument(lines: grouped.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) })
        }
        while plain.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { plain.removeFirst() }
        while plain.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { plain.removeLast() }
        return LyricDocument(lines: plain.enumerated().map { LyricLine(id: $0.offset, time: nil, text: $0.element) })
    }
}
struct LyricRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "lyrics"
    var id = UUID().uuidString
    var filename: String
    var sourcePath: String
    var text: String
    var trackID: String?
}
enum LyricMatching {
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let numbered = folded.replacingOccurrences(of: #"^\s*\d{1,3}(?:\s*[.、_\-]\s*|\s+)"#, with: "", options: .regularExpression)
        return numbered.replacingOccurrences(of: #"[\s._\-—·]+"#, with: "", options: .regularExpression)
    }
    static func versions(_ text: String) -> Set<String> {
        let patterns = ["live": #"(?i)\blive\b|现场"#, "instrumental": #"(?i)\binstrumental\b|伴奏"#, "remix": #"(?i)\bremix\b|混音"#, "remaster": #"(?i)\bremaster(?:ed)?\b|重制"#]
        return Set(patterns.compactMap { text.range(of: $0.value, options: .regularExpression) != nil ? $0.key : nil })
    }
    static func aliases(_ text: String) -> Set<String> {
        var names: Set<String> = [normalized(text)]
        if let range = text.range(of: " - ", options: .backwards) { names.insert(normalized(String(text[range.upperBound...]))) }
        names.remove("")
        return names
    }
    static func candidates(_ record: LyricRecord, tracks: [Track], roots: [String: String]) -> [Track] {
        let stem = (record.filename as NSString).deletingPathExtension
        let exact = normalized(stem)
        let sameDirectory = tracks.filter { track in
            guard let root = roots[track.sourceID] else { return false }
            let path = URL(fileURLWithPath: root).appendingPathComponent(track.relativePath)
            return path.deletingLastPathComponent().standardizedFileURL.path == URL(fileURLWithPath: record.sourcePath).deletingLastPathComponent().standardizedFileURL.path && normalized(track.displayName(.filename)) == exact
        }
        if !sameDirectory.isEmpty { return sameDirectory }
        let filenames = tracks.filter { normalized($0.displayName(.filename)) == exact }
        if !filenames.isEmpty { return filenames }
        var names = aliases(stem)
        for line in record.text.components(separatedBy: .newlines) where versions(stem).isEmpty {
            if line.lowercased().hasPrefix("[ti:"), let end = line.firstIndex(of: "]") {
                names.formUnion(aliases(String(line[line.index(line.startIndex, offsetBy: 4)..<end])))
            }
        }
        return tracks.filter { track in
            guard versions(stem) == versions(track.filename + " " + track.title) else { return false }
            if let lyricArtist = stem.components(separatedBy: " - ").dropLast().first,
               let trackArtist = track.displayName(.filename).components(separatedBy: " - ").dropLast().first,
               normalized(lyricArtist) != normalized(trackArtist) { return false }
            return !names.isDisjoint(with: aliases(track.title).union(aliases(track.displayName(.filename))))
        }
    }
}

@MainActor
final class LyricsLibrary: ObservableObject {
    @Published private(set) var records: [LyricRecord] = []
    @Published private(set) var importing = false
    @Published var message: String?
    private var database: LibraryDatabase?
    private var documents: [String: LyricDocument] = [:]
    func configure(_ database: LibraryDatabase) async throws {
        self.database = database
        try await reload()
    }
    private func reload() async throws {
        guard let database else { return }
        let loaded = try await database.loadLyrics()
        documents = await Task.detached { Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, LyricDocument.parse($0.text, filename: $0.filename)) }) }.value
        records = loaded
    }
    func record(for trackID: String) -> LyricRecord? { records.first { $0.trackID == trackID } }
    func document(for record: LyricRecord) -> LyricDocument { documents[record.id] ?? LyricDocument.parse(record.text, filename: record.filename) }
    func associate(_ record: LyricRecord, with trackID: String?) async throws {
        guard let database else { return }
        try await database.associateLyric(recordID: record.id, trackID: trackID)
        try await reload()
    }
    func chooseImport(target: Track?, tracks: [Track], roots: [String: String], completion: @escaping () -> Void) {
        guard !importing, database != nil else { return }
        let panel = NSOpenPanel()
        panel.title = target == nil ? "导入歌词文件或文件夹" : "为当前音频关联歌词"
        panel.canChooseDirectories = target == nil; panel.canChooseFiles = true
        panel.allowsMultipleSelection = target == nil
        panel.message = "支持 LRC 时间轴歌词和 TXT 纯文本。批量导入会自动匹配；匹配不明确或读取失败时保留原歌词。"
        let overwrite = NSButton(checkboxWithTitle: "覆盖已关联歌词", target: nil, action: nil)
        overwrite.state = .off
        overwrite.toolTip = "仅用本次唯一匹配且解析有效的歌词替换已有歌词，原导入记录仍保留。"
        if target == nil {
            panel.accessoryView = overwrite
            panel.isAccessoryViewDisclosed = true
        }
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importFiles(urls, tracks: tracks, roots: roots, target: target, overwriteExisting: overwrite.state == .on); completion() }
    }
    func importFiles(_ urls: [URL], tracks: [Track], roots: [String: String], target: Track? = nil, overwriteExisting: Bool = false) async {
        guard !importing, let database else { return }
        importing = true
        defer { importing = false }
        do {
            let result = await Task.detached(priority: .userInitiated) { Self.readFiles(urls) }.value
            var batch: [LyricRecord] = []
            for incoming in result.records {
                if let existing = records.first(where: { $0.sourcePath == incoming.sourcePath && $0.text == incoming.text }) { batch.append(existing) }
                else { batch.append(incoming) }
            }
            // In replacement mode, only this import participates in duplicate detection.
            // Older, unlinked revisions must not block an explicitly requested replacement.
            let matchingRecords = overwriteExisting ? batch : records + batch
            let pending = Dictionary(matchingRecords.filter { overwriteExisting || $0.trackID == nil }.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            let proposed = await Task.detached(priority: .userInitiated) {
                var matchesByTrack: [String: [String]] = [:]
                for record in pending.values {
                    let matches = LyricMatching.candidates(record, tracks: tracks, roots: roots)
                    if matches.count == 1 { matchesByTrack[matches[0].id, default: []].append(record.id) }
                }
                return matchesByTrack
            }.value
            var matched = 0, replaced = 0, kept = 0
            for index in batch.indices {
                if let target, batch.count == 1 {
                    batch[index].trackID = target.id; matched += 1
                } else if batch[index].trackID == nil {
                    let candidates = proposed.filter { $0.value == [batch[index].id] }
                    if let id = candidates.keys.first {
                        if records.contains(where: { $0.trackID == id }) {
                            if overwriteExisting { batch[index].trackID = id; replaced += 1 }
                            else { kept += 1 }
                        } else { batch[index].trackID = id; matched += 1 }
                    }
                } else { kept += 1 }
            }
            try await database.saveLyrics(batch, replacing: target != nil || overwriteExisting)
            try await reload()
            let linked = batch.filter { $0.trackID != nil }.count
            message = "导入 \(batch.count) 个 · 新增关联 \(matched) 个 · 替换 \(replaced) 个 · 保留原关联 \(kept) 个 · 待关联 \(batch.count - linked) 个" + (result.errors.isEmpty ? "" : "\n未导入：" + result.errors.joined(separator: "；"))
        } catch { message = "导入失败：\(error.localizedDescription)" }
    }
    nonisolated private static func readFiles(_ urls: [URL]) -> (records: [LyricRecord], errors: [String]) {
        var files = Set<URL>(), errors: [String] = []
        let scopes = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
        for url in urls {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { errors.append(url.lastPathComponent + "：文件不存在"); continue }
            if directory.boolValue {
                if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    for case let file as URL in enumerator where ["lrc", "txt"].contains(file.pathExtension.lowercased()) {
                        if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.insert(file.standardizedFileURL) }
                    }
                }
            } else { files.insert(url.standardizedFileURL) }
        }
        var records: [LyricRecord] = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            do {
                guard ["lrc", "txt"].contains(file.pathExtension.lowercased()) else { throw CocoaError(.fileReadUnknown) }
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 2_000_000 else { throw CocoaError(.fileReadTooLarge) }
                let data = try Data(contentsOf: file)
                guard data.count <= 2_000_000 else { throw CocoaError(.fileReadTooLarge) }
                let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
                let text: String?
                if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { text = String(data: data, encoding: .utf16) }
                else { text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb) }
                guard let text, !text.contains("\0"), LyricDocument.parse(text, filename: file.lastPathComponent).lines.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                records.append(LyricRecord(filename: file.lastPathComponent, sourcePath: file.path, text: text))
            } catch { errors.append(file.lastPathComponent + "：无法读取有效歌词") }
        }
        return (records, errors)
    }
}
