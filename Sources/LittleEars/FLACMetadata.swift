import Foundation

/// Reads only bounded FLAC metadata blocks; audio data and embedded artwork are never loaded.
enum FLACMetadata {
    static func title(at url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data("fLaC".utf8) else { return nil }
        // A malformed file must not make metadata scanning unbounded.
        for _ in 0..<128 {
            guard let header = try handle.read(upToCount: 4), header.count == 4 else { return nil }
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            let last = header[0] & 0x80 != 0
            if header[0] & 0x7f == 4, length <= 1_048_576 {
                guard let data = try handle.read(upToCount: length), data.count == length else { return nil }
                if let title = title(in: data) { return title }
            } else {
                let offset = try handle.offset()
                try handle.seek(toOffset: offset + UInt64(length))
            }
            if last { break }
        }
        return nil
    }
    static func title(in data: Data) -> String? {
        let bytes = Array(data)
        var offset = 0
        func integer() -> Int? {
            guard offset + 4 <= bytes.count else { return nil }
            defer { offset += 4 }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        guard let vendorLength = integer(), vendorLength <= bytes.count - offset else { return nil }
        offset += vendorLength
        guard let count = integer(), count <= (bytes.count - offset) / 4 else { return nil }
        for _ in 0..<count {
            guard let length = integer(), length <= bytes.count - offset else { return nil }
            let comment = String(bytes: bytes[offset..<(offset + length)], encoding: .utf8)
            offset += length
            guard let comment, let separator = comment.firstIndex(of: "="), comment[..<separator].uppercased() == "TITLE" else { continue }
            let value = String(comment[comment.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }
}
