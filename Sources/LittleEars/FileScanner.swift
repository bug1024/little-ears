import Foundation
import AVFoundation

actor FileScanner {
    func scan(source: LibrarySource, root: URL) async throws -> [Track] {
        let scanRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let files = try enumerate(root: scanRoot)
        var result: [Track] = []
        for url in files {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .fileResourceIdentifierKey, .creationDateKey])
            guard values.isRegularFile == true else { continue }
            let relative = url.standardizedFileURL.pathComponents.dropFirst(scanRoot.pathComponents.count).joined(separator: "/")
            let size = Int64(values.fileSize ?? 0)
            let identity = "\(String(describing: values.fileResourceIdentifier))|\(values.creationDate?.timeIntervalSince1970 ?? 0)|\(size)"
            let asset = AVURLAsset(url: url)
            var title = url.deletingPathExtension().lastPathComponent
            var duration = (try? await asset.load(.duration).seconds) ?? 0
            if url.pathExtension.lowercased() == "flac" {
                if let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 {
                    duration = Double(file.length) / file.processingFormat.sampleRate
                }
                if let name = try? FLACMetadata.title(at: url) { title = name }
            }
            if let metadata = try? await asset.load(.commonMetadata),
               let item = metadata.first(where: { $0.commonKey == .commonKeyTitle }),
               let name = try? await item.load(.stringValue), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = name }
            result.append(Track(id: UUID().uuidString, sourceID: source.id, relativePath: relative, identity: identity,
                                title: title, duration: duration.isFinite ? max(0, duration) : 0,
                                format: url.pathExtension.uppercased(), fileSize: size, available: true))
        }
        return result
    }
    private func enumerate(root: URL) throws -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .fileResourceIdentifierKey, .creationDateKey]
        var scanError: Error?
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in scanError = error; return false }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var files: [URL] = []
        let formats: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff", "caf", "flac"]
        for case let url as URL in iterator {
            if formats.contains(url.pathExtension.lowercased()) { files.append(url) }
        }
        if let scanError { throw scanError }
        return files
    }

}
