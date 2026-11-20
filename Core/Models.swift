// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum ServerKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case jellyfin = "Jellyfin"
    case subsonic = "Subsonic / OpenSubsonic"
    public var id: String { rawValue }
}

public struct ServerProfile: Codable, Identifiable, Sendable {
    public let id: UUID
    public var kind: ServerKind
    public var name: String
    public var baseURL: URL
    public var username: String
    public var userID: String?
    
    public init(id: UUID = UUID(), kind: ServerKind, name: String, baseURL: URL, username: String, userID: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.username = username
        self.userID = userID
    }
}

public struct Track: Codable, Hashable, Identifiable, Sendable {
    public enum Location: Codable, Hashable, Sendable {
        case local(file: String, artwork: String?)
        case server(profile: UUID, item: String, artwork: String?)
    }
    
    public let id: String
    public var title: String
    public var artist: String
    public var album: String
    public var albumKey: String?
    public var genre: String?
    public var number: Int?
    public var disc: Int?
    public var duration: Double
    public var format: String?
    public var location: Location
    
    public init(id: String, title: String, artist: String, album: String, albumKey: String? = nil, genre: String? = nil, number: Int? = nil,
                disc: Int? = nil, duration: Double = 0, format: String? = nil, location: Location) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumKey = albumKey
        self.genre = genre
        self.number = number
        self.disc = disc
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.format = format
        self.location = location
    }

    public func matches(_ query: String) -> Bool {
        [title, artist, album, genre ?? ""].contains { $0.localizedStandardContains(query) }
    }

    public func relatedTracks(in tracks: [Track], limit: Int) -> [Track] {
        guard limit > 0 else { return [] }
        func normalized(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        func artists(_ value: String) -> Set<String> {
            Set(value.split(separator: ",").map { normalized(String($0)) }.filter { !$0.isEmpty })
        }
        let seedArtists = artists(artist)
        let seedGenre = normalized(genre ?? "")
        var seen: Set<String> = [id]
        let candidates = tracks.compactMap { candidate -> (track: Track, score: Int)? in
            guard seen.insert(candidate.id).inserted else { return nil }
            let sameArtist = !seedArtists.isDisjoint(with: artists(candidate.artist))
            let sameGenre = !seedGenre.isEmpty && seedGenre == normalized(candidate.genre ?? "")
            let score = (sameArtist ? 2 : 0) + (sameGenre ? 1 : 0)
            return score > 0 ? (candidate, score) : nil
        }
        return candidates.shuffled().sorted { $0.score > $1.score }.prefix(limit).map(\.track)
    }
}

public struct Playlist: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var tracks: [Track] = []
    
    public init(name: String) { self.name = name }
}

public struct ServerPlaylist: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let profileID: UUID
    public let count: Int?
}

public struct PlayStatistics: Codable, Sendable {
    public var plays: [String: Int] = [:]
    public var lastPlayed: [String: Date] = [:]
    public var listeningSeconds: Double = 0
    
    public init() {}
    
    public mutating func record(_ trackID: String, at date: Date = .now) {
        plays[trackID, default: 0] += 1
        lastPlayed[trackID] = date
    }
}

public protocol MusicProvider: Sendable {
    func library() async throws -> [Track]
    func search(_ query: String) async throws -> [Track]
    func playlists() async throws -> [ServerPlaylist]
    func tracks(in playlist: ServerPlaylist) async throws -> [Track]
    func stream(for track: Track) throws -> URL
    func artwork(for track: Track) throws -> URLRequest?
}

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
