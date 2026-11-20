// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import Security
import UniformTypeIdentifiers

struct MediaStorage: Sendable {
    let root: URL
    let cache: URL

    static let standard = MediaStorage(
        root: URL.applicationSupportDirectory.appending(path: "Twelve", directoryHint: .isDirectory),
        cache: URL.cachesDirectory.appending(path: "TwelveArtwork", directoryHint: .isDirectory)
    )

    func read<Value: Decodable>(_ name: String, default fallback: Value) -> Value {
        let url = root.appending(path: name)
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Value.self, from: data) else { return fallback }
        return value
    }

    func write<Value: Encodable>(_ value: Value, to name: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: root.appending(path: name), options: .atomic)
    }

    func localURL(_ leaf: String) throws -> URL {
        guard !leaf.isEmpty, leaf == URL(fileURLWithPath: leaf).lastPathComponent, leaf != ".", leaf != ".." else {
            throw MusicError.unavailable
        }
        return root.appending(path: "Media", directoryHint: .isDirectory).appending(component: leaf)
    }
}

enum Keychain {
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Twelve.Server",
         kSecAttrAccount as String: id.uuidString]
    }

    static func store(_ secret: String, for id: UUID) throws {
        let key = query(id)
        let value = Data(secret.utf8)
        let state = SecItemUpdate(key as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if state == errSecSuccess { return }
        if state == errSecItemNotFound {
            var entry = key
            entry[kSecValueData as String] = value
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw KeychainError.storage }
            return
        }
        throw KeychainError.storage
    }

    static func read(_ id: UUID) throws -> String {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw KeychainError.storage }
        return value
    }

    static func remove(_ id: UUID) throws {
        let result = SecItemDelete(query(id) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw KeychainError.storage }
    }

    private enum KeychainError: LocalizedError {
        case storage
        var errorDescription: String? { "The server credentials could not be accessed in Keychain." }
    }
}

actor LocalMusicProvider: MusicProvider {
    let storage: MediaStorage

    init(storage: MediaStorage) { self.storage = storage }

    func library() -> [Track] { storage.read("local.json", default: []) }
    func search(_ query: String) -> [Track] { library().filter { $0.matches(query) } }
    func playlists() -> [ServerPlaylist] { [] }
    func tracks(in playlist: ServerPlaylist) -> [Track] { [] }
    
    nonisolated func stream(for track: Track) throws -> URL {
        guard case let .local(file, _) = track.location else { throw MusicError.unavailable }
        let url = try storage.localURL(file)
        guard FileManager.default.fileExists(atPath: url.path) else { throw MusicError.unavailable }
        return url
    }
    
    nonisolated func artwork(for track: Track) throws -> URLRequest? {
        guard case let .local(_, file?) = track.location else { return nil }
        return URLRequest(url: try storage.localURL(file))
    }

    enum ImportError: LocalizedError {
        case unsupported
        var errorDescription: String? { "This file has no supported audio track." }
    }

    // A single import modifies the index at a time. Files are copied before async metadata reads.
    func importFile(_ source: URL) async throws -> Track {
        let id = UUID().uuidString
        let file = id + "." + source.pathExtension.lowercased()
        let destination = try storage.localURL(file)
        let cover = try storage.localURL(id + ".jpg")
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?
            var copyError: (any Error)?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
                do { try manager.copyItem(at: readable, to: destination) }
                catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            
            var title = source.deletingPathExtension().lastPathComponent
            var artist = ""
            var album = ""
            var albumArtist: String?
            var genre: String?
            var artwork: String?
            var number: Int?
            var disc: Int?
            let asset = AVURLAsset(url: destination)
            let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            let fileReader = audio.isEmpty ? try? AVAudioFile(forReading: destination) : nil
            guard !audio.isEmpty || fileReader != nil else { throw ImportError.unsupported }
            let duration: Double
            if let fileReader { duration = Double(fileReader.length) / fileReader.processingFormat.sampleRate }
            else { duration = (try? await asset.load(.duration).seconds) ?? 0 }
            
            let common = (try? await asset.load(.commonMetadata)) ?? []
            let all = (try? await asset.load(.metadata)) ?? []
            for item in common {
                switch item.commonKey {
                case .commonKeyTitle: title = (try? await item.load(.stringValue)) ?? title
                case .commonKeyArtist: artist = (try? await item.load(.stringValue)) ?? artist
                case .commonKeyAlbumName: album = (try? await item.load(.stringValue)) ?? album
                case .commonKeyType: genre = try? await item.load(.stringValue)
                case .commonKeyArtwork:
                    if let bytes = try? await item.load(.dataValue),
                       let image = Self.thumbnail(bytes), (try? image.write(to: cover, options: .atomic)) != nil {
                        artwork = cover.lastPathComponent
                    }
                default: break
                }
            }
            for item in all {
                let key = item.identifier?.rawValue.lowercased() ?? ""
                if key.contains("albumartist") || key.hasSuffix("/tpe2") || key.hasSuffix("/aart") {
                    albumArtist = try? await item.load(.stringValue)
                } else if key.contains("tracknumber") || key.hasSuffix("/trck") || key.hasSuffix("/trkn") {
                    number = await indexValue(item)
                } else if key.contains("discnumber") || key.hasSuffix("/tpos") || key.hasSuffix("/disk") {
                    disc = await indexValue(item)
                } else if genre == nil && (key.contains("genre") || key.hasSuffix("/tcon") || key.hasSuffix("/%a9gen")) {
                    genre = try? await item.load(.stringValue)
                }
            }
            if source.pathExtension.lowercased() == "flac", let flac = FLACMetadata.read(from: destination) {
                title = flac.tags["TITLE"] ?? title
                artist = flac.tags["ARTIST"] ?? artist
                album = flac.tags["ALBUM"] ?? album
                albumArtist = flac.tags["ALBUMARTIST"]
                genre = flac.tags["GENRE"] ?? genre
                if let value = flac.tags["TRACKNUMBER"]?.split(separator: "/").first { number = Int(value) ?? number }
                if let value = flac.tags["DISCNUMBER"]?.split(separator: "/").first { disc = Int(value) ?? disc }
                if artwork == nil, let bytes = flac.artwork, let image = Self.thumbnail(bytes),
                   (try? image.write(to: cover, options: .atomic)) != nil {
                    artwork = cover.lastPathComponent
                }
            }
            let albumKey = album.isEmpty ? nil : (album + "|" + (albumArtist ?? artist))
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let track = Track(id: id, title: title.isEmpty ? source.deletingPathExtension().lastPathComponent : title,
                              artist: artist, album: album, albumKey: albumKey, genre: genre, number: number, disc: disc,
                              duration: duration, format: source.pathExtension.uppercased(), location: .local(file: file, artwork: artwork))
            try Task.checkCancellation()
            try storage.write(library() + [track], to: "local.json")
            return track
        } catch {
            try? manager.removeItem(at: destination)
            try? manager.removeItem(at: cover)
            throw error
        }
    }

    private func indexValue(_ item: AVMetadataItem) async -> Int? {
        if let value = try? await item.load(.numberValue), value.intValue > 0 { return value.intValue }
        if let text = try? await item.load(.stringValue), let first = text.split(separator: "/").first {
            return Int(first.trimmingCharacters(in: .whitespaces))
        }
        if let data = try? await item.load(.dataValue), data.count >= 4 {
            return data.dropFirst(2).prefix(2).reduce(0) { $0 * 256 + Int($1) }
        }
        return nil
    }

    private static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024
              ] as CFDictionary) else { return nil }
        let bytes = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(bytes as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        return CGImageDestinationFinalize(output) ? bytes as Data : nil
    }
}

actor ArtworkStore {
    private let directory: URL
    private let transport = ServerTransport()
    private var pending: [String: Task<Data, Error>] = [:]
    private var writes = 0

    init(directory: URL) { self.directory = directory }

    func data(key: String, request: URLRequest) async throws -> Data {
        if let url = request.url, url.isFileURL { return try Data(contentsOf: url) }
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appending(component: name)
        if let bytes = try? Data(contentsOf: file) {
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
            return bytes
        }
        if let task = pending[key] { return try await task.value }
        let transport = self.transport
        let task = Task {
            let bytes = try await transport.get(request)
            guard bytes.count <= 6_000_000,
                  let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) > 0 else {
                throw MusicError.invalidResponse
            }
            return bytes
        }
        pending[key] = task
        defer { pending[key] = nil }
        let bytes = try await task.value
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? bytes.write(to: file, options: .atomic)
        writes += 1
        if writes % 12 == 1 { trim() }
        return bytes
    }

    private func trim() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        let byRecent = files.compactMap { file -> (URL, Int, Date)? in
            guard let metadata = try? file.resourceValues(forKeys: keys) else { return nil }
            return (file, metadata.fileSize ?? 0, metadata.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 > $1.2 }
        var bytes = 0
        for entry in byRecent {
            bytes += entry.1
            if bytes > 80_000_000 { try? FileManager.default.removeItem(at: entry.0) }
        }
    }
}
