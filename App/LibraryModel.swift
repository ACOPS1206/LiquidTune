// SPDX-License-Identifier: Apache-2.0
import Observation
import UIKit

@MainActor @Observable
final class LibraryModel {
    enum Appearance: String, CaseIterable, Identifiable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"
        var id: Self { self }
    }

    let playback: PlaybackEngine
    private let storage: MediaStorage
    private let local: LocalMusicProvider
    private let artworkStore: ArtworkStore

    private(set) var localTracks: [Track] = []
    private(set) var servers: [ServerProfile]
    private(set) var serverTracks: [UUID: [Track]] = [:]
    private(set) var serverPlaylists: [UUID: [ServerPlaylist]] = [:]
    private(set) var loading: Set<UUID> = []
    private(set) var sourceMessages: [UUID: String] = [:]
    private(set) var playlists: [Playlist]
    private(set) var favorites: Set<String>
    private(set) var importing = false
    private(set) var isPreparingMix = false
    private(set) var activeServer: UUID?
    var message: String?

    var appearance: Appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
    }
    var dynamicColor: Bool {
        didSet { UserDefaults.standard.set(dynamicColor, forKey: "dynamicColor") }
    }
    var visualizer: Bool {
        didSet {
            UserDefaults.standard.set(visualizer, forKey: "visualizer")
            playback.setVisualizerEnabled(visualizer)
        }
    }

    @ObservationIgnored private var remoteProviders: [UUID: any MusicProvider] = [:]
    @ObservationIgnored private var refreshes: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let images = NSCache<NSString, UIImage>()
    @ObservationIgnored private var started = false

    init(storage: MediaStorage = .standard) {
        self.storage = storage
        local = LocalMusicProvider(storage: storage)
        artworkStore = ArtworkStore(directory: storage.cache)
        playback = PlaybackEngine(storage: storage)
        let profiles: [ServerProfile] = storage.read("servers.json", default: [])
        servers = profiles
        playlists = storage.read("playlists.json", default: [])
        favorites = storage.read("favorites.json", default: [])
        let defaults = UserDefaults.standard
        let selected = defaults.string(forKey: "activeServer").flatMap(UUID.init(uuidString:))
        activeServer = profiles.contains(where: { $0.id == selected }) ? selected : nil
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        dynamicColor = defaults.object(forKey: "dynamicColor") as? Bool ?? true
        visualizer = defaults.object(forKey: "visualizer") as? Bool ?? false
        images.totalCostLimit = 36_000_000
        for profile in servers {
            if let secret = try? Keychain.read(profile.id) {
                remoteProviders[profile.id] = Self.makeProvider(profile, secret: secret)
            }
        }
        playback.resolve = { [weak self] track in
            guard let self else { throw MusicError.unavailable }
            return try self.provider(for: track).stream(for: track)
        }
        playback.loadArtwork = { [weak self] track in await self?.artwork(for: track) }
        playback.isFavorite = { [weak self] id in self?.favorites.contains(id) == true }
        playback.setFavorite = { [weak self] id, favorite in self?.setFavorite(id, favorite: favorite) }
    }

    var tracks: [Track] {
        let source = activeServer.map { serverTracks[$0] ?? [] } ?? localTracks
        return source.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var sourceName: String {
        servers.first { $0.id == activeServer }?.name ?? "On this device"
    }

    func start() async {
        guard !started else { return }
        started = true
        playback.setVisualizerEnabled(visualizer)
        playback.configure()
        localTracks = await local.library()
        if let activeServer { requestRefresh(activeServer) }
    }

    func selectSource(_ id: UUID?) {
        guard activeServer != id else { return }
        activeServer = id
        UserDefaults.standard.set(id?.uuidString, forKey: "activeServer")
        if let id, serverTracks[id] == nil { requestRefresh(id) }
    }

    func requestRefresh(_ id: UUID) {
        guard refreshes[id] == nil else { return }
        guard let provider = remoteProviders[id] else {
            sourceMessages[id] = MusicError.unauthorized.localizedDescription
            return
        }
        loading.insert(id)
        sourceMessages[id] = nil
        refreshes[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.loading.remove(id)
                self.refreshes[id] = nil
            }
            do {
                let results = try await provider.library()
                try Task.checkCancellation()
                self.serverTracks[id] = results
                let playlists = try await provider.playlists()
                try Task.checkCancellation()
                self.serverPlaylists[id] = playlists
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.sourceMessages[id] = error.localizedDescription }
            }
        }
    }

    func importFiles(_ urls: [URL]) async {
        guard !importing, !urls.isEmpty else { return }
        importing = true
        defer { importing = false }
        var failures: [String] = []
        for url in urls {
            do { _ = try await local.importFile(url) }
            catch is CancellationError { break }
            catch { failures.append(url.lastPathComponent) }
        }
        localTracks = await local.library()
        if !failures.isEmpty {
            let preview = failures.prefix(3).joined(separator: ", ")
            message = "Could not import \(failures.count) file(s). \(preview)"
        }
    }

    func connect(kind: ServerKind, address: String, username: String, password: String, name: String, replacing existingID: UUID?) async throws {
        let url = try ServerAddress.parse(address)
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = existingID ?? UUID()
        var profile = ServerProfile(id: id, kind: kind, name: label.isEmpty ? kind.rawValue : label, baseURL: url, username: account)
        let secret: String
        switch kind {
        case .jellyfin:
            (profile, secret) = try await JellyfinProvider.connect(profile, password: password)
        case .subsonic:
            try await SubsonicProvider(profile: profile, password: password).ping()
            secret = password
        }
        let previousSecret = try? Keychain.read(id)
        try Keychain.store(secret, for: id)
        let updated = servers.filter { $0.id != id } + [profile]
        do { try storage.write(updated, to: "servers.json") }
        catch {
            if let previousSecret { try? Keychain.store(previousSecret, for: id) }
            else { try? Keychain.remove(id) }
            throw error
        }
        refreshes[id]?.cancel()
        let oldRefresh = refreshes[id]
        await oldRefresh?.value
        servers = updated
        remoteProviders[id] = Self.makeProvider(profile, secret: secret)
        serverTracks[id] = nil
        serverPlaylists[id] = nil
        if activeServer == id { requestRefresh(id) }
        else { selectSource(id) }
    }

    func disconnect(_ id: UUID) async {
        let updated = servers.filter { $0.id != id }
        do {
            try storage.write(updated, to: "servers.json")
            do { try Keychain.remove(id) }
            catch {
                try? storage.write(servers, to: "servers.json")
                throw error
            }
            refreshes[id]?.cancel()
            await refreshes[id]?.value
            servers = updated
            remoteProviders[id] = nil
            serverTracks[id] = nil
            serverPlaylists[id] = nil
            sourceMessages[id] = nil
            if activeServer == id { selectSource(nil) }
        } catch {
            message = error.localizedDescription
        }
    }

    private static func makeProvider(_ profile: ServerProfile, secret: String) -> any MusicProvider {
        switch profile.kind {
        case .jellyfin: JellyfinProvider(profile: profile, token: secret)
        case .subsonic: SubsonicProvider(profile: profile, password: secret)
        }
    }

    private func provider(for track: Track) throws -> any MusicProvider {
        switch track.location {
        case .local: return local
        case let .server(profile, _, _):
            guard let provider = remoteProviders[profile] else { throw MusicError.unavailable }
            return provider
        }
    }

    func lyrics(for track: Track) async throws -> TrackLyrics? {
        guard let jellyfin = try provider(for: track) as? JellyfinProvider else { return nil }
        return try await jellyfin.lyrics(for: track)
    }

    func startInstantMix(from seed: Track) async throws {
        guard !isPreparingMix else { return }
        isPreparingMix = true
        defer { isPreparingMix = false }
        let previousEntry = playback.queue.current?.id
        let limit = 40
        do {
            let provider = try provider(for: seed)
            var recommendations: [Track] = []
            if let jellyfin = provider as? JellyfinProvider {
                do {
                    recommendations = try await jellyfin.instantMix(from: seed, limit: limit)
                } catch MusicError.server(let status) where [404, 405, 501].contains(status) {
                    // Fall back to the tracks already available from this source.
                }
            }
            try Task.checkCancellation()
            guard playback.queue.current?.id == previousEntry else { return }
            if recommendations.isEmpty {
                let sourceTracks: [Track]
                switch seed.location {
                case .local: sourceTracks = localTracks
                case let .server(profile, _, _): sourceTracks = serverTracks[profile] ?? []
                }
                recommendations = seed.relatedTracks(in: sourceTracks, limit: limit)
            }
            guard !recommendations.isEmpty else { throw MusicError.noRelatedTracks }
            playback.play([seed] + recommendations)
        } catch {
            if !Task.isCancelled, playback.queue.current?.id == previousEntry {
                throw error
            }
        }
    }

    func search(_ query: String, source: UUID?) async throws -> [Track] {
        if let source {
            guard let provider = remoteProviders[source] else { throw MusicError.unavailable }
            let cached = (serverTracks[source] ?? []).filter { $0.matches(query) }
            do {
                let remote = try await provider.search(query)
                var seen: Set<String> = []
                return (cached + remote).filter { seen.insert($0.id).inserted }
            } catch {
                if !cached.isEmpty && !Task.isCancelled { return cached }
                throw error
            }
        }
        return await local.search(query)
    }

    func serverPlaylistTracks(_ playlist: ServerPlaylist) async throws -> [Track] {
        guard let provider = remoteProviders[playlist.profileID] else { throw MusicError.unavailable }
        return try await provider.tracks(in: playlist)
    }

    func artwork(for track: Track) async -> UIImage? {
        let key: String
        switch track.location {
        case let .local(_, artwork?): key = "local:\(artwork)"
        case let .server(profile, _, artwork?): key = "\(profile):\(artwork)"
        default: return nil
        }
        if let image = images.object(forKey: key as NSString) { return image }
        guard let request = try? provider(for: track).artwork(for: track),
              let bytes = try? await artworkStore.data(key: key, request: request),
              let image = UIImage(data: bytes) else { return nil }
        images.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * 4))
        return image
    }

    func createPlaylist(_ name: String, with initialTrack: Track? = nil) {
        createPlaylist(name, withTracks: initialTrack.map { [$0] } ?? [])
    }

    func createPlaylist(_ name: String, withTracks tracks: [Track]) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var playlist = Playlist(name: title)
        playlist.tracks = tracks
        savePlaylists(playlists + [playlist])
    }

    func addToPlaylist(_ track: Track, id: UUID) {
        addToPlaylist([track], id: id)
    }

    func addToPlaylist(_ tracks: [Track], id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        var existingIDs = Set(playlists[index].tracks.map(\.id))
        let additions = tracks.filter { existingIDs.insert($0.id).inserted }
        guard !additions.isEmpty else { return }
        var updated = playlists
        updated[index].tracks.append(contentsOf: additions)
        savePlaylists(updated)
    }

    func removeFromPlaylist(_ track: Track, id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        var updated = playlists
        updated[index].tracks.removeAll { $0.id == track.id }
        savePlaylists(updated)
    }

    func deletePlaylist(_ id: UUID) { savePlaylists(playlists.filter { $0.id != id }) }

    func renamePlaylist(_ id: UUID, name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        var updated = playlists
        updated[index].name = title
        savePlaylists(updated)
    }

    private func savePlaylists(_ updated: [Playlist]) {
        do { try storage.write(updated, to: "playlists.json"); playlists = updated }
        catch { message = "The playlist could not be saved." }
    }

    func toggleFavorite(_ track: Track) {
        setFavorite(track.id, favorite: !favorites.contains(track.id))
    }

    private func setFavorite(_ id: String, favorite: Bool) {
        guard favorites.contains(id) != favorite else { return }
        var updated = favorites
        if favorite { updated.insert(id) } else { updated.remove(id) }
        do {
            try storage.write(updated, to: "favorites.json")
            favorites = updated
            playback.refreshFavoriteCommand()
        } catch { message = "Favorites could not be saved." }
    }
}
