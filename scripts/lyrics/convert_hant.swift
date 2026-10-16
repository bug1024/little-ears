import Foundation

// Offline Traditional -> Simplified conversion for .lrc lyric files, using the
// ICU "Hant-Hans" transform that ships with macOS. Timestamps, metadata tags and
// any ASCII are untouched; only Han characters are transliterated.
//
// usage: swift convert_hant.swift <root> [--skip <dir-name>]

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: convert_hant.swift <root> [skip-dir-name]\n".utf8))
    exit(2)
}
let root = args[1]
let skip = args.count >= 3 ? args[2] : ""

let fm = FileManager.default
var rootIsDir: ObjCBool = false
guard fm.fileExists(atPath: root, isDirectory: &rootIsDir), rootIsDir.boolValue,
      let iterator = fm.enumerator(atPath: root) else {
    FileHandle.standardError.write(Data("cannot enumerate \(root)\n".utf8))
    exit(1)
}

let transform = StringTransform("Hant-Hans")
var converted = 0
var unchanged = 0
var failed: [String] = []

for case let rel as String in iterator {
    guard rel.lowercased().hasSuffix(".lrc") else { continue }
    if !skip.isEmpty, rel.split(separator: "/").contains(Substring(skip)) { continue }
    let path = (root as NSString).appendingPathComponent(rel)
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        failed.append(rel); continue
    }
    guard let out = text.applyingTransform(transform, reverse: false) else {
        failed.append(rel); continue
    }
    if out == text { unchanged += 1; continue }
    do {
        try out.write(toFile: path, atomically: true, encoding: .utf8)
        converted += 1
    } catch {
        failed.append(rel)
    }
}

print("converted: \(converted)  already-simplified: \(unchanged)  failed: \(failed.count)")
for name in failed.prefix(10) { print("  failed: \(name)") }