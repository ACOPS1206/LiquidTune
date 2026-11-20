// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum MusicError: LocalizedError, Sendable {
    case invalidURL, unauthorized, invalidResponse, unavailable, noRelatedTracks
    case network(Int), server(Int), subsonic(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter an HTTPS server address or a local HTTP address."
        case .unauthorized: "Authentication failed. Check the account or reconnect in Settings."
        case .invalidResponse: "The server returned an unexpected response."
        case .unavailable: "The source for this item is unavailable."
        case .noRelatedTracks: "No related songs were found for Instant Mix."
        case .network(let code): "The server could not be reached (network error \(code))."
        case .server(let status): "The server returned HTTP \(status)."
        case .subsonic(let code): "The Subsonic server returned error \(code)."
        }
    }
}

public enum ServerAddress {
    public static func parse(_ address: String) throws -> URL {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              scheme == "https" || scheme == "http" && isLocal(host) else { throw MusicError.invalidURL }
        components.scheme = scheme
        while components.percentEncodedPath.last == "/" { components.percentEncodedPath.removeLast() }
        guard let url = components.url else { throw MusicError.invalidURL }
        return url
    }

    private static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || host == "[::1]" || host == "::1" { return true }
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { return false }
        let ip = pieces.compactMap { UInt8($0) }
        guard ip.count == 4 else { return false }
        return ip[0] == 127 || ip[0] == 10 || (ip[0] == 192 && ip[1] == 168)
            || (ip[0] == 172 && (16...31).contains(ip[1])) || (ip[0] == 169 && ip[1] == 254)
    }
}

public protocol HTTPTransport: Sendable {
    func get(_ request: URLRequest) async throws -> Data
}

private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let old = task.originalRequest?.url
        let new = request.url
        guard let old, let new, old.scheme == new.scheme, old.host == new.host, old.port == new.port else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

public struct ServerTransport: HTTPTransport {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 90
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: SameOriginRedirects(), delegateQueue: nil)
    }()

    public init() {}

    public func get(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw MusicError.invalidResponse }
            switch response.statusCode {
            case 200..<300: return data
            case 401, 403: throw MusicError.unauthorized
            default: throw MusicError.server(response.statusCode)
            }
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw MusicError.network(error.errorCode)
        }
    }
}

private func endpoint(_ base: URL, _ path: [String], _ params: [(String, String)] = []) throws -> URL {
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw MusicError.invalidURL }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
    for part in path {
        guard part != ".", part != "..", let encoded = part.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw MusicError.invalidURL
        }
        components.percentEncodedPath += "/" + encoded
    }
    if !params.isEmpty {
        components.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }
    guard let url = components.url else { throw MusicError.invalidURL }
    return url
}

private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do { return try JSONDecoder().decode(type, from: data) }
    catch { throw MusicError.invalidResponse }
}

public struct TrackLyrics: Sendable {
    public struct Line: Sendable {
        public let text: String
        public let start: Double?
    }

    public let lines: [Line]
    private let timedIndices: [Int]

    fileprivate init(lines: [Line]) {
        self.lines = lines
        timedIndices = lines.indices.filter { lines[$0].start != nil }.sorted {
            let left = lines[$0].start ?? 0
            let right = lines[$1].start ?? 0
            return left == right ? $0 < $1 : left < right
        }
    }

    public var isTimed: Bool { !timedIndices.isEmpty }

    public func activeLine(at seconds: Double) -> Int? {
        guard seconds.isFinite else { return nil }
        var lower = 0
        var upper = timedIndices.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if let start = lines[timedIndices[middle]].start, start <= seconds { lower = middle + 1 }
            else { upper = middle }
        }
        return lower > 0 ? timedIndices[lower - 1] : nil
    }
}

private struct LyricKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

public struct JellyfinProvider: MusicProvider {
    private struct AuthResponse: Decodable {
        struct User: Decodable { let Id: String }
        let AccessToken: String
        let User: User
    }

    private struct Page: Decodable {
        let Items: [Item]
        let TotalRecordCount: Int?
    }
    
    private struct Item: Decodable {
        let Id: String
        let Name: String
        let Artists: [String]?
        let AlbumArtist: String?
        let Album: String?
        let AlbumId: String?
        let AlbumPrimaryImageTag: String?
        let ImageTags: [String: String]?
        let RunTimeTicks: Int64?
        let IndexNumber: Int?
        let ParentIndexNumber: Int?
        let Genres: [String]?
        let Container: String?
        let ChildCount: Int?
    }

    private let profile: ServerProfile
    private let token: String
    private let transport: any HTTPTransport

    public init(profile: ServerProfile, token: String, transport: any HTTPTransport = ServerTransport()) {
        self.profile = profile
        self.token = token
        self.transport = transport
    }

    private static func authorization(_ id: UUID, token: String? = nil) -> String {
        var value = "MediaBrowser Client=\"LiquidTune\", Device=\"iOS\", DeviceId=\"\(id.uuidString)\", Version=\"1\""
        if let token { value += ", Token=\"\(token)\"" }
        return value
    }

    public static func connect(_ profile: ServerProfile, password: String, transport: any HTTPTransport = ServerTransport()) async throws -> (ServerProfile, String) {
        var request = URLRequest(url: try endpoint(profile.baseURL, ["Users", "AuthenticateByName"]))
        request.httpMethod = "POST"
        request.setValue(authorization(profile.id), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["Username": profile.username, "Pw": password])
        let response = try decode(AuthResponse.self, from: await transport.get(request))
        guard !response.AccessToken.isEmpty, !response.User.Id.isEmpty else { throw MusicError.invalidResponse }
        var updated = profile
        updated.userID = response.User.Id
        return (updated, response.AccessToken)
    }

    private func list(_ path: [String], _ parameters: [(String, String)], maxPages: Int = .max) async throws -> [Item] {
        guard let user = profile.userID else { throw MusicError.unauthorized }
        var result: [Item] = []
        var seen: Set<String> = []
        var start = 0
        for _ in 0..<maxPages {
            try Task.checkCancellation()
            var request = URLRequest(url: try endpoint(profile.baseURL, path, parameters + [
                ("userId", user), ("startIndex", String(start)), ("limit", "200")
            ]))
            request.setValue(Self.authorization(profile.id, token: token), forHTTPHeaderField: "Authorization")
            let page = try decode(Page.self, from: await transport.get(request))
            let unique = page.Items.filter { seen.insert($0.Id).inserted }
            guard !unique.isEmpty else { break }
            result += unique
            start += page.Items.count
            if let total = page.TotalRecordCount, total > 0 {
                if start >= total { break }
            } else if page.Items.count < 200 {
                break
            }
        }
        return result
    }

    private func track(_ item: Item) -> Track {
        let art = item.ImageTags?["Primary"] != nil ? item.Id : (item.AlbumPrimaryImageTag == nil ? nil : item.AlbumId)
        return Track(id: "\(profile.id):\(item.Id)", title: item.Name,
                     artist: item.Artists?.joined(separator: ", ").nonEmpty ?? item.AlbumArtist ?? "",
                     album: item.Album ?? "", albumKey: item.AlbumId, genre: item.Genres?.first,
                     number: item.IndexNumber, disc: item.ParentIndexNumber,
                     duration: Double(item.RunTimeTicks ?? 0) / 10_000_000, format: item.Container,
                     location: .server(profile: profile.id, item: item.Id, artwork: art))
    }

    private var audioParameters: [(String, String)] {
        [("recursive", "true"), ("includeItemTypes", "Audio"), ("sortBy", "SortName"), ("fields", "Genres,MediaSources")]
    }

    public func library() async throws -> [Track] {
        try await list(["Items"], audioParameters).map(track)
    }

    public func search(_ query: String) async throws -> [Track] {
        try await list(["Items"], audioParameters + [("searchTerm", query)], maxPages: 5).map(track)
    }

    public func playlists() async throws -> [ServerPlaylist] {
        try await list(["Items"], [("recursive", "true"), ("includeItemTypes", "Playlist"), ("fields", "ChildCount")]).map {
            ServerPlaylist(id: $0.Id, name: $0.Name, profileID: profile.id, count: $0.ChildCount)
        }
    }

    public func tracks(in playlist: ServerPlaylist) async throws -> [Track] {
        guard playlist.profileID == profile.id else { throw MusicError.unavailable }
        return try await list(["Playlists", playlist.id, "Items"], [("fields", "Genres,MediaSources")]).map(track)
    }

    public func instantMix(from seed: Track, limit: Int = 40) async throws -> [Track] {
        guard case let .server(id, item, _) = seed.location, id == profile.id else { throw MusicError.unavailable }
        guard let user = profile.userID else { throw MusicError.unauthorized }
        guard limit > 0 else { return [] }
        let url = try endpoint(profile.baseURL, ["Songs", item, "InstantMix"], [
            ("userId", user), ("limit", String(limit)), ("fields", "Genres,MediaSources")
        ])
        var request = URLRequest(url: url)
        request.setValue(Self.authorization(profile.id, token: token), forHTTPHeaderField: "Authorization")
        let page = try decode(Page.self, from: await transport.get(request))
        var seen: Set<String> = [item]
        return page.Items.filter { seen.insert($0.Id).inserted }.prefix(limit).map(track)
    }

    public func lyrics(for track: Track) async throws -> TrackLyrics? {
        guard case let .server(id, item, _) = track.location, id == profile.id else { throw MusicError.unavailable }
        struct Payload: Decodable {
            struct Entry: Decodable {
                let Text: String?
                let Start: Int64?
            }
            let Lyrics: [Entry]?
        }
        var request = URLRequest(url: try endpoint(profile.baseURL, ["Audio", item, "Lyrics"]))
        request.setValue(Self.authorization(profile.id, token: token), forHTTPHeaderField: "Authorization")
        let data: Data
        do { data = try await transport.get(request) }
        catch MusicError.server(404) { return nil }

        // Jellyfin timestamps are in 100 ns ticks. Accept both server JSON naming policies.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            let key = path.last?.stringValue ?? ""
            return LyricKey(stringValue: key.prefix(1).uppercased() + key.dropFirst())
        }
        let payload: Payload
        do { payload = try decoder.decode(Payload.self, from: data) }
        catch { throw MusicError.invalidResponse }
        let lines = (payload.Lyrics ?? []).map {
            TrackLyrics.Line(text: $0.Text ?? "", start: $0.Start.map { max(0, Double($0) / 10_000_000) })
        }
        guard lines.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        return TrackLyrics(lines: lines)
    }

    public func stream(for track: Track) throws -> URL {
        guard case let .server(id, item, _) = track.location, id == profile.id else { throw MusicError.unavailable }
        return try endpoint(profile.baseURL, ["Audio", item, "stream"], [("static", "true"), ("api_key", token)])
    }

    public func artwork(for track: Track) throws -> URLRequest? {
        guard case let .server(id, _, artwork) = track.location, id == profile.id, let artwork else { return nil }
        var request = URLRequest(url: try endpoint(profile.baseURL, ["Items", artwork, "Images", "Primary"], [("maxWidth", "768")]))
        request.setValue(Self.authorization(profile.id, token: token), forHTTPHeaderField: "Authorization")
        return request
    }
}

public struct SubsonicProvider: MusicProvider {
    private struct Envelope: Decodable {
        let response: Response
        enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
    }

    private struct Response: Decodable {
        struct Failure: Decodable { let code: Int }
        let status: String
        let error: Failure?
        let searchResult3: SearchResult?
        let albumList2: AlbumList?
        let album: Album?
        let playlists: Playlists?
        let playlist: RemotePlaylist?
    }

    private struct SearchResult: Decodable { let song: [Song]? }
    private struct AlbumList: Decodable { let album: [Album]? }
    private struct Album: Decodable { let id: String; let song: [Song]? }
    private struct Playlists: Decodable { let playlist: [RemotePlaylist]? }
    private struct RemotePlaylist: Decodable {
        let id: String
        let name: String
        let songCount: Int?
        let entry: [Song]?
    }

    private struct Song: Decodable {
        let id: String
        let title: String
        let artist: String?
        let album: String?
        let albumId: String?
        let coverArt: String?
        let duration: Int?
        let track: Int?
        let discNumber: Int?
        let genre: String?
        let suffix: String?
    }

    private let profile: ServerProfile
    private let password: String
    private let transport: any HTTPTransport

    public init(profile: ServerProfile, password: String, transport: any HTTPTransport = ServerTransport()) {
        self.profile = profile
        self.password = password
        self.transport = transport
    }

    private func url(_ action: String, _ parameters: [(String, String)] = [], json: Bool = true) throws -> URL {
        let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let token = SubsonicMD5.hex(Data((password + salt).utf8))
        var auth = [("u", profile.username), ("t", token), ("s", salt), ("v", "1.16.1"), ("c", "LiquidTune")]
        if json { auth.append(("f", "json")) }
        return try endpoint(profile.baseURL, ["rest", action + ".view"], parameters + auth)
    }

    private func response(_ action: String, _ parameters: [(String, String)] = []) async throws -> Response {
        let request = URLRequest(url: try url(action, parameters))
        let result = try decode(Envelope.self, from: await transport.get(request)).response
        guard result.status == "ok" else {
            let code = result.error?.code ?? 0
            if code == 40 || code == 41 || code == 50 { throw MusicError.unauthorized }
            throw MusicError.subsonic(code)
        }
        return result
    }

    public func ping() async throws { _ = try await response("ping") }

    public func library() async throws -> [Track] {
        do {
            let tracks = try await query("", maxPages: .max)
            if !tracks.isEmpty { return tracks }
        } catch MusicError.subsonic(_) {
            // Some servers reject empty searches. Browse via ID3 album endpoints.
        }
        var tracks: [Track] = []
        var seen: Set<String> = []
        var offset = 0
        while true {
            let result = try await response("getAlbumList2", [("type", "alphabeticalByName"), ("size", "100"), ("offset", String(offset))])
            let albums = result.albumList2?.album ?? []
            let unique = albums.filter { seen.insert($0.id).inserted }
            guard !unique.isEmpty else { break }
            for album in unique {
                let details = try await response("getAlbum", [("id", album.id)])
                tracks += (details.album?.song ?? []).map(track)
            }
            if albums.count < 100 { break }
            offset += albums.count
        }
        return tracks
    }

    private func query(_ query: String, maxPages: Int) async throws -> [Track] {
        var result: [Track] = []
        var seen: Set<String> = []
        var offset = 0
        for _ in 0..<maxPages {
            let reply = try await response("search3", [("query", query), ("songCount", "100"),
                ("songOffset", String(offset)), ("artistCount", "0"), ("albumCount", "0")])
            let songs = reply.searchResult3?.song ?? []
            let unique = songs.filter { seen.insert($0.id).inserted }
            guard !unique.isEmpty else { break }
            result += unique.map(track)
            if songs.count < 100 { break }
            offset += songs.count
        }
        return result
    }

    public func search(_ query: String) async throws -> [Track] { try await self.query(query, maxPages: 5) }

    public func playlists() async throws -> [ServerPlaylist] {
        let result = try await response("getPlaylists")
        return (result.playlists?.playlist ?? []).map {
            ServerPlaylist(id: $0.id, name: $0.name, profileID: profile.id, count: $0.songCount)
        }
    }

    public func tracks(in playlist: ServerPlaylist) async throws -> [Track] {
        guard playlist.profileID == profile.id else { throw MusicError.unavailable }
        let result = try await response("getPlaylist", [("id", playlist.id)])
        return (result.playlist?.entry ?? []).map(track)
    }

    public func stream(for track: Track) throws -> URL {
        guard case let .server(id, item, _) = track.location, id == profile.id else { throw MusicError.unavailable }
        return try url("stream", [("id", item)], json: false)
    }

    public func artwork(for track: Track) throws -> URLRequest? {
        guard case let .server(id, _, artwork) = track.location, id == profile.id, let artwork else { return nil }
        return URLRequest(url: try url("getCoverArt", [("id", artwork), ("size", "768")], json: false))
    }

    private func track(_ song: Song) -> Track {
        Track(id: "\(profile.id):\(song.id)", title: song.title, artist: song.artist ?? "", album: song.album ?? "",
              albumKey: song.albumId, genre: song.genre, number: song.track, disc: song.discNumber,
              duration: Double(song.duration ?? 0), format: song.suffix,
              location: .server(profile: profile.id, item: song.id, artwork: song.coverArt))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
