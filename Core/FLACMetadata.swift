// SPDX-License-Identifier: Apache-2.0
import Foundation

struct FLACMetadata {
    var tags: [String: String] = [:]
    var artwork: Data?

    // Native FLAC metadata blocks. Stop before the first audio frame.
    static func read(from url: URL) -> Self? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.read(upToCount: 4)) == Data("fLaC".utf8) else { return nil }
        var metadata = Self()
        var frontCover = false
        for _ in 0..<4096 {
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { break }
            let type = header[0] & 0x7f
            let size = (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
            do {
                if (type == 4 || type == 6), size > 0, size <= 8_000_000 {
                    guard let bytes = try handle.read(upToCount: size), bytes.count == size else { break }
                    if type == 4 {
                        metadata.tags.merge(comments(bytes)) { first, _ in first }
                    } else if !frontCover, let picture = picture(bytes) {
                        if metadata.artwork == nil || picture.isFront { metadata.artwork = picture.bytes }
                        frontCover = picture.isFront
                    }
                } else {
                    try handle.seek(toOffset: handle.offset() + UInt64(size))
                }
            } catch { break }
            if header[0] & 0x80 != 0 { break }
        }
        return metadata
    }

    private static func comments(_ data: Data) -> [String: String] {
        var cursor = Block(data: data)
        guard let vendorLength = cursor.readInteger(littleEndian: true), cursor.skip(vendorLength),
              let count = cursor.readInteger(littleEndian: true) else { return [:] }
        var tags: [String: String] = [:]
        for _ in 0..<min(count, 20_000) {
            guard let length = cursor.readInteger(littleEndian: true), let field = cursor.read(length) else { break }
            guard let text = String(data: field, encoding: .utf8), let split = text.firstIndex(of: "=") else { continue }
            let name = text[..<split].uppercased()
            let value = String(text[text.index(after: split)...])
            if tags[name] == nil && !value.isEmpty { tags[name] = value }
        }
        return tags
    }

    private static func picture(_ data: Data) -> (isFront: Bool, bytes: Data)? {
        var cursor = Block(data: data)
        guard let type = cursor.readInteger(), let mimeLength = cursor.readInteger(), let mime = cursor.read(mimeLength),
              mime != Data("-->".utf8), let descriptionLength = cursor.readInteger(), cursor.skip(descriptionLength),
              cursor.skip(16), let size = cursor.readInteger(), size > 0, let bytes = cursor.read(size) else { return nil }
        return (type == 3, bytes)
    }

    private struct Block {
        let data: Data
        var offset = 0

        mutating func skip(_ count: Int) -> Bool {
            guard count >= 0, count <= data.count - offset else { return false }
            offset += count
            return true
        }

        mutating func read(_ count: Int) -> Data? {
            let start = offset
            guard skip(count) else { return nil }
            return data.subdata(in: start..<offset)
        }

        mutating func readInteger(littleEndian: Bool = false) -> Int? {
            let start = offset
            guard skip(4) else { return nil }
            let bytes = data[start..<offset]
            if littleEndian { return bytes.reversed().reduce(0) { ($0 << 8) | Int($1) } }
            return bytes.reduce(0) { ($0 << 8) | Int($1) }
        }
    }
}
