// SPDX-License-Identifier: Apache-2.0
import SwiftUI

private struct MusicGroup: Identifiable {
    let id: String
    let title: String
    let tracks: [Track]
    var artwork: Track? { tracks.first(where: {
        switch $0.location {
        case .local(_, .some), .server(_, _, .some): true
        default: false
        }
    }) ?? tracks.first }

    static func group(_ tracks: [Track], by kind: String) -> [MusicGroup] {
        let groups = Dictionary(grouping: tracks) { track in
            switch kind {
            case "Albums":
                if let key = track.albumKey { return key }
                return track.album.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            case "Artists": return track.artist
            default: return track.genre ?? ""
            }
        }
        return groups.map { key, items in
            let ordered = items.sorted {
                let first = ($0.disc ?? 1, $0.number ?? Int.max)
                let second = ($1.disc ?? 1, $1.number ?? Int.max)
                if kind == "Albums", first != second { return first < second }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            let title: String
            switch kind {
            case "Albums": title = (ordered.first?.album).nonBlank ?? "Unknown album"
            case "Artists": title = key.isEmpty ? "Unknown artist" : key
            default: title = key.isEmpty ? "Unknown genre" : key
            }
            return MusicGroup(id: key, title: title, tracks: ordered)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func detail(_ symbol: String) -> BrowseDetail {
        let isAlbum = symbol == "opticaldisc"
        let subtitle = isAlbum ? ((tracks.first?.artist).nonBlank ?? "Unknown artist") : "\(tracks.count) songs"
        return BrowseDetail(title: title, subtitle: subtitle, glyph: symbol, artwork: artwork,
                            destination: isAlbum ? .album(tracks) : .tracks(tracks))
    }
}

private extension Optional where Wrapped == String {
    var nonBlank: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}

struct HomeScreen: View {
    let open: (BrowseDetail) -> Void
    let importFiles: () -> Void
    @Environment(LibraryModel.self) private var model

    private let gutter: CGFloat = 20

    var body: some View {
        let tracks = model.tracks
        if tracks.isEmpty {
            LibraryEmpty(importFiles: importFiles)
        } else {
            let stats = model.playback.statistics
            let recent = tracks.filter { stats.lastPlayed[$0.id] != nil }.sorted {
                stats.lastPlayed[$0.id, default: .distantPast] > stats.lastPlayed[$1.id, default: .distantPast]
            }
            let albums = MusicGroup.group(tracks, by: "Albums")
            let discovery = albums.sorted { $0.id.hashValue < $1.id.hashValue }
            let favorites = rankedGroups(albums, stats: stats)
            let favoriteIDs = Set(favorites.map(\.id))
            let featured = favorites + discovery.filter { !favoriteIDs.contains($0.id) }
            let mostPlayed = tracks.filter { stats.plays[$0.id, default: 0] > 0 }
                .sorted { stats.plays[$0.id, default: 0] > stats.plays[$1.id, default: 0] }

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    featuredShelf(featured, tracks: tracks)
                    if !recent.isEmpty { trackShelf("Recently played", recent, showAll: true) }
                    albumShelf("Discover albums", discovery, icon: "opticaldisc")
                    if !mostPlayed.isEmpty {
                        trackShelf("Most played songs", mostPlayed)
                        albumShelf("Most played albums", favorites, icon: "opticaldisc")
                        albumShelf("Most played artists", rankedGroups(MusicGroup.group(tracks, by: "Artists"), stats: stats), icon: "person")
                        albumShelf("Most played genres", rankedGroups(MusicGroup.group(tracks, by: "Genres"), stats: stats), icon: "music.quarternote.3")
                    }
                }
                .padding(.vertical, 16)
            }
        }
    }

    private func title(_ value: String) -> some View {
        Text(value).font(.title2.bold()).accessibilityAddTraits(.isHeader)
    }

    private func featuredShelf(_ groups: [MusicGroup], tracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                title("Featured albums")
                Spacer(minLength: 4)
                Button("Shuffle songs", systemImage: "shuffle") {
                    model.playback.play(tracks, index: Int.random(in: tracks.indices), shuffle: true)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
            }
            .padding(.horizontal, gutter)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(groups.prefix(8)) { group in
                        featuredCard(group)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, gutter, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }

    private func featuredCard(_ group: MusicGroup) -> some View {
        Button {
            open(group.detail("opticaldisc"))
        } label: {
            Cover(track: group.artwork, radius: 0, placeholder: "opticaldisc")
                .frame(height: 280)
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.title).font(.title3.bold()).lineLimit(2)
                        if let artist = group.tracks.first?.artist, !artist.isEmpty {
                            Text(artist).font(.subheadline).foregroundStyle(.white.opacity(0.86)).lineLimit(1)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(alignment: .bottom) {
                        LinearGradient(colors: [.clear, .black.opacity(0.96)], startPoint: .top, endPoint: .bottom)
                            .padding(.top, -30)
                    }
                }
                .clipShape(.rect(cornerRadius: 22))
                .containerRelativeFrame(.horizontal) { width, _ in min(275, width * 0.74) }
        }
        .buttonStyle(.plain)
    }

    private func trackShelf(_ heading: String, _ tracks: [Track], showAll: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if showAll {
                Button {
                    open(BrowseDetail(title: heading, subtitle: "\(tracks.count) songs", glyph: "clock",
                                      artwork: tracks.first, destination: .tracks(tracks)))
                } label: {
                    HStack(spacing: 6) {
                        title(heading)
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, gutter)
            } else {
                title(heading).padding(.horizontal, gutter)
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(tracks.prefix(12).enumerated()), id: \.element.id) { index, track in
                        ShelfTile(title: track.title, subtitle: track.artist, track: track, glyph: "music.note") {
                            model.playback.play(tracks, index: index)
                        }
                    }
                }
            }
            .contentMargins(.horizontal, gutter, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
    }

    private func rankedGroups(_ groups: [MusicGroup], stats: PlayStatistics) -> [MusicGroup] {
        groups.map { group in
            (group, group.tracks.reduce(0) { $0 + stats.plays[$1.id, default: 0] })
        }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    private func albumShelf(_ heading: String, _ groups: [MusicGroup], icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            title(heading).padding(.horizontal, gutter)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(groups.prefix(12)) { group in
                        ShelfTile(title: group.title, subtitle: icon == "opticaldisc" ? group.tracks.first?.artist ?? "" : "\(group.tracks.count) songs", track: group.artwork, glyph: icon) {
                            open(group.detail(icon))
                        }
                    }
                }
            }
            .contentMargins(.horizontal, gutter, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
    }
}

private struct ShelfTile: View {
    let title: String
    let subtitle: String
    let track: Track?
    let glyph: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Cover(track: track, radius: 13, placeholder: glyph)
                    .frame(height: 154)
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(width: 154, alignment: .leading)
            .lineLimit(1)
        }
        .buttonStyle(.plain)
    }
}

struct LibraryScreen: View {
    let open: (BrowseDetail) -> Void
    let importFiles: () -> Void
    @Environment(LibraryModel.self) private var model
    @State private var section = "Albums"
    @State private var ascending = true
    @State private var newPlaylist = false
    @State private var playlistName = ""
    private let sections = ["Albums", "Artists", "Songs", "Genres", "Playlists"]

    var body: some View {
        VStack(spacing: 0) {
            libraryHeader

            libraryContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Library options", systemImage: "ellipsis") {
                    if section == "Playlists" {
                        Button("New playlist", systemImage: "plus") {
                            playlistName = ""
                            newPlaylist = true
                        }
                    } else {
                        Picker("Sort", selection: $ascending) {
                            Text("Title A to Z").tag(true)
                            Text("Title Z to A").tag(false)
                        }
                    }
                    if model.activeServer == nil {
                        Button("Import files", systemImage: "square.and.arrow.down", action: importFiles)
                    }
                }
            }
        }
        .alert("New playlist", isPresented: $newPlaylist) {
            TextField("Playlist name", text: $playlistName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { model.createPlaylist(playlistName) }
        }
    }

    private var libraryHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Library")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(model.sourceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: false, vertical: true)

            Picker("Library category", selection: $section) {
                ForEach(sections, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .layoutPriority(1)
    }

    @ViewBuilder private var libraryContent: some View {
        if section == "Playlists" {
            playlists
        } else if model.tracks.isEmpty {
            LibraryEmpty(importFiles: importFiles)
        } else if section == "Songs" {
            List {
                TrackRows(tracks: ascending ? model.tracks : Array(model.tracks.reversed()))
            }
            .listStyle(.plain)
        } else {
            collection(section)
        }
    }

    private func collection(_ kind: String) -> some View {
        let groups = MusicGroup.group(model.tracks, by: kind)
        let ordered = ascending ? groups : Array(groups.reversed())
        let icon = kind == "Albums" ? "opticaldisc" : (kind == "Artists" ? "person" : "music.quarternote.3")
        return Group {
            if kind == "Albums" {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 240), spacing: 14)], alignment: .leading, spacing: 20) {
                        ForEach(ordered) { group in
                            Button {
                                open(group.detail(icon))
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Color.clear
                                        .aspectRatio(1, contentMode: .fit)
                                        .overlay { Cover(track: group.artwork, radius: 13, placeholder: icon) }
                                    Text(group.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    Text((group.tracks.first?.artist).nonBlank ?? "Unknown artist")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            } else {
                List(ordered) { group in
                    GroupRow(title: group.title, subtitle: "\(group.tracks.count) songs", artwork: group.artwork,
                             icon: icon, round: kind == "Artists") { open(group.detail(icon)) }
                }
                .listStyle(.plain)
            }
        }
    }

    private var playlists: some View {
        List {
            Section("On this device") {
                let favorites = model.tracks.filter { model.favorites.contains($0.id) }
                GroupRow(title: "Favorites", subtitle: "\(favorites.count) songs", artwork: nil, icon: "heart.fill") {
                    open(BrowseDetail(title: "Favorites", subtitle: "", glyph: "heart.fill",
                                      artwork: favorites.first, destination: .tracks(favorites)))
                }
                ForEach(model.playlists) { playlist in
                    GroupRow(title: playlist.name, subtitle: "\(playlist.tracks.count) songs", artwork: playlist.tracks.first, icon: "music.note.list") {
                        open(BrowseDetail(title: playlist.name, subtitle: "", glyph: "music.note.list",
                                          artwork: playlist.tracks.first, destination: .localPlaylist(playlist.id)))
                    }
                }
                Button("New playlist", systemImage: "plus") {
                    playlistName = ""
                    newPlaylist = true
                }
            }
            if let id = model.activeServer, let playlists = model.serverPlaylists[id], !playlists.isEmpty {
                Section(model.sourceName) {
                    ForEach(playlists) { playlist in
                        GroupRow(title: playlist.name, subtitle: playlist.count.map { "\($0) songs" } ?? "Server playlist",
                                 artwork: nil, icon: "music.note.list") {
                            open(BrowseDetail(title: playlist.name, subtitle: "Server playlist", glyph: "music.note.list",
                                              artwork: nil, destination: .serverPlaylist(playlist)))
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct SearchScreen: View {
    let query: String
    let open: (BrowseDetail) -> Void
    @Environment(LibraryModel.self) private var model
    @State private var tracks: [Track] = []
    @State private var searching = false
    @State private var error: String?

    private var input: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Group {
            if input.isEmpty {
                ContentUnavailableView("Search your music", systemImage: "magnifyingglass")
            } else if searching && tracks.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView("Search unavailable", systemImage: "exclamationmark.circle", description: Text(error))
            } else if tracks.isEmpty {
                ContentUnavailableView.search(text: input)
            } else {
                results
            }
        }
        .task(id: (model.activeServer?.uuidString ?? "local") + ":" + input) {
            tracks = []
            error = nil
            guard !input.isEmpty else { searching = false; return }
            searching = true
            defer { if !Task.isCancelled { searching = false } }
            do {
                try await Task.sleep(for: .milliseconds(280))
                let result = try await model.search(input, source: model.activeServer)
                if !Task.isCancelled { tracks = result }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private var results: some View {
        let albums = MusicGroup.group(tracks.filter { $0.album.localizedStandardContains(input) }, by: "Albums")
        let artists = MusicGroup.group(tracks.filter { $0.artist.localizedStandardContains(input) }, by: "Artists")
        return List {
            if !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums.prefix(6)) { album in
                        GroupRow(title: album.title, subtitle: album.tracks.first?.artist ?? "", artwork: album.artwork, icon: "opticaldisc") {
                            open(album.detail("opticaldisc"))
                        }
                    }
                }
            }
            if !artists.isEmpty {
                Section("Artists") {
                    ForEach(artists.prefix(6)) { artist in
                        GroupRow(title: artist.title, subtitle: "\(artist.tracks.count) songs", artwork: artist.artwork, icon: "person", round: true) {
                            open(artist.detail("person"))
                        }
                    }
                }
            }
            Section("Songs") { TrackRows(tracks: tracks) }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
    }
}

struct CollectionDetailScreen: View {
    let detail: BrowseDetail
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var creatingPlaylist = false
    @State private var playlistName = ""
    @State private var artworkImage: UIImage?
    @State private var artworkColors: [Color] = []

    @State private var remoteTracks: [Track]?
    @State private var remoteError: String?
    @State private var request = UUID()
    @State private var delete = false
    @State private var rename = false
    @State private var name = ""

    private let actionHeight: CGFloat = 48
    private var playlistID: UUID? {
        if case let .localPlaylist(id) = detail.destination { return id }
        return nil
    }
    private var playlist: Playlist? { model.playlists.first { $0.id == playlistID } }
    private var serverPlaylist: ServerPlaylist? {
        if case let .serverPlaylist(playlist) = detail.destination { return playlist }
        return nil
    }
    private var isAlbum: Bool {
        if case .album = detail.destination { return true }
        return false
    }
    private var tracks: [Track] {
        switch detail.destination {
        case let .tracks(tracks), let .album(tracks): tracks
        case .localPlaylist: playlist?.tracks ?? []
        case .serverPlaylist: remoteTracks ?? []
        }
    }
    private var title: String { playlist?.name ?? detail.title }
    private var artworkTrack: Track? {
        if isAlbum, let artwork = detail.artwork { return artwork }
        return tracks.first { track in
            switch track.location {
            case .local(_, .some), .server(_, _, .some): true
            default: false
            }
        }
    }
    private var collectionScheme: ColorScheme {
        guard !artworkColors.isEmpty, artworkColors.allSatisfy({
            var white: CGFloat = 0
            var alpha: CGFloat = 0
            let color = UIColor($0)
            if color.getWhite(&white, alpha: &alpha) { return white >= 0.70 }
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            return color.getRed(&red, green: &green, blue: &blue, alpha: nil) && min(red, green, blue) >= 0.70
        }) else { return colorScheme }
        return .light
    }
    private var collectionInk: Color { collectionScheme == .dark ? .white : .black }

    private var metadata: String {
        let genres = Set(tracks.compactMap { ($0.genre?.trimmingCharacters(in: .whitespacesAndNewlines)).nonBlank })
        let genre = isAlbum && genres.count == 1 ? genres.first : nil
        let duration = tracks.reduce(0) { $0 + $1.duration }
        let count = remoteTracks == nil ? serverPlaylist?.count ?? tracks.count : tracks.count
        return [genre, count == 1 ? "1 song" : "\(count) songs", duration > 0 ? clock(duration) : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        List {
            header
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            if let remoteError {
                ContentUnavailableView {
                    Label("Playlist unavailable", systemImage: "exclamationmark.circle")
                } description: {
                    Text(remoteError)
                } actions: {
                    Button("Retry") { request = UUID() }.buttonStyle(.glass)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else if serverPlaylist != nil, remoteTracks == nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else if tracks.isEmpty {
                ContentUnavailableView("No songs", systemImage: "music.note")
                    .listRowSeparator(.hidden)
            } else {
                TrackRows(tracks: tracks, localPlaylist: playlistID, layout: isAlbum ? .album : .playlist)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background { collectionBackground.ignoresSafeArea() }
        .tint(collectionInk)
        .environment(\.colorScheme, collectionScheme)
        .task(id: artworkTrack?.id) {
            artworkImage = nil
            artworkColors = []
            guard let track = artworkTrack, let image = await model.artwork(for: track),
                  !Task.isCancelled else { return }
            artworkImage = image
            withAnimation(.easeOut(duration: 0.3)) {
                artworkColors = ArtworkPalette.albumColors(from: image)
            }
        }
        .task(id: request) {
            guard let serverPlaylist else { return }
            remoteError = nil
            do {
                let tracks = try await model.serverPlaylistTracks(serverPlaylist)
                try Task.checkCancellation()
                remoteTracks = tracks
            } catch {
                if !Task.isCancelled { remoteError = error.localizedDescription }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: [title, detail.subtitle].filter { !$0.isEmpty }.joined(separator: " — "))
                Menu(isAlbum ? "Album options" : "Playlist options", systemImage: "ellipsis") {
                    if !tracks.isEmpty { addActions }
                    if let playlist {
                        Button("Rename", systemImage: "pencil") { name = playlist.name; rename = true }
                        Button("Delete playlist", systemImage: "trash", role: .destructive) { delete = true }
                    }
                }
                .disabled(tracks.isEmpty && playlist == nil)
            }
        }
        .alert("New playlist", isPresented: $creatingPlaylist) {
            TextField("Playlist name", text: $playlistName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { model.createPlaylist(playlistName, withTracks: tracks) }
        }
        .alert("Rename playlist", isPresented: $rename) {
            TextField("Playlist name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let playlistID { model.renamePlaylist(playlistID, name: name) } }
        }
        .confirmationDialog("Delete playlist?", isPresented: $delete, titleVisibility: .visible) {
            Button("Delete playlist", role: .destructive) {
                if let playlistID { model.deletePlaylist(playlistID); dismiss() }
            }
        }
    }

    private var collectionBackground: some View {
        let first = artworkColors.first ?? .clear
        let second = artworkColors.dropFirst().first ?? first
        let strength = collectionScheme == .dark ? 0.56 : 0.28

        return ZStack {
            (collectionScheme == .dark ? Color.black : Color.white)
            LinearGradient(colors: [first.opacity(strength), second.opacity(strength * 0.78)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var header: some View {
        VStack(spacing: 18) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Cover(knownImage: artworkImage, radius: 18, placeholder: detail.glyph)
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(.primary.opacity(0.09))
                        .accessibilityHidden(true)
                }
                .containerRelativeFrame(.horizontal) { width, _ in min(360, width * 0.76) }

            VStack(spacing: 5) {
                Text(title).font(.title.bold()).accessibilityAddTraits(.isHeader)
                if !detail.subtitle.isEmpty {
                    Text(detail.subtitle).font(.title3).foregroundStyle(.secondary)
                }
                Text(metadata).font(.footnote).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            if !tracks.isEmpty {
                HStack(spacing: 12) {
                    Button {
                        model.playback.play(tracks, index: Int.random(in: tracks.indices), shuffle: true)
                    } label: {
                        collectionActionIcon("shuffle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Shuffle")

                    Button {
                        model.playback.play(tracks)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "play.fill").accessibilityHidden(true)
                            Text("Play").lineLimit(1).minimumScaleFactor(0.65)
                        }
                        .font(.headline)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 26)
                        .frame(minWidth: 122)
                        .frame(height: actionHeight)
                        .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Menu {
                        addActions
                    } label: {
                        collectionActionIcon("plus")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isAlbum ? "Add album" : "Add playlist tracks")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 18)
    }

    private func collectionActionIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .frame(width: actionHeight, height: actionHeight)
            .glassEffect(.regular.interactive(), in: .circle)
    }

    @ViewBuilder private var addActions: some View {
        Button(isAlbum ? "Add album to queue" : "Add playlist to queue", systemImage: "text.append") { model.playback.appendToQueue(tracks) }
        Menu("Add to playlist", systemImage: "music.note.list") {
            Button("New playlist", systemImage: "plus") {
                playlistName = ""
                creatingPlaylist = true
            }
            ForEach(model.playlists) { playlist in
                Button(playlist.name) { model.addToPlaylist(tracks, id: playlist.id) }
            }
        }
    }
}

struct DetailScreen: View {
    let detail: BrowseDetail
    let tracks: [Track]
    @Environment(LibraryModel.self) private var model

    var body: some View {
        List {
            hero
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            if tracks.isEmpty {
                ContentUnavailableView("No songs", systemImage: "music.note")
                    .listRowSeparator(.hidden)
            } else {
                TrackRows(tracks: tracks)
            }
        }
        .listStyle(.plain)
        .navigationTitle(detail.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hero: some View {
        VStack(spacing: 9) {
            Cover(track: detail.artwork ?? tracks.first, radius: 18, placeholder: detail.glyph)
                .frame(width: 172, height: 172)
                .padding(.bottom, 3)
            Text(detail.title).font(.title2.bold())
            if !detail.subtitle.isEmpty { Text(detail.subtitle).foregroundStyle(.secondary) }
            Text("\(tracks.count) songs · \(clock(tracks.reduce(0) { $0 + $1.duration }))")
                .font(.caption).foregroundStyle(.secondary)
            if !tracks.isEmpty {
                HStack {
                    Button("Play", systemImage: "play.fill") { model.playback.play(tracks) }
                        .buttonStyle(.glassProminent)
                    Button("Shuffle", systemImage: "shuffle") {
                        model.playback.play(tracks, index: Int.random(in: tracks.indices), shuffle: true)
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.large)
                .padding(.top, 5)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

private struct GroupRow: View {
    let title: String
    let subtitle: String
    let artwork: Track?
    let icon: String
    var round = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Cover(track: artwork, radius: round ? 23 : 9, placeholder: icon).frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TrackRows: View {
    let tracks: [Track]
    var localPlaylist: UUID? = nil
    enum Layout { case standard, album, playlist }
    var layout: Layout = .standard
    @Environment(LibraryModel.self) private var model
    @State private var createWithTrack: Track?
    @State private var name = ""

    var body: some View {
        ForEach(Array(tracks.enumerated()), id: \.offset) { position, track in
            HStack(spacing: 8) {
                Button {
                    model.playback.play(tracks, index: position)
                } label: {
                    HStack(spacing: 12) {
                        if layout != .standard {
                            let number = (layout == .album ? track.number.flatMap { $0 > 0 ? $0 : nil } : nil) ?? (position + 1)
                            Text("\(number)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 24, alignment: .leading)
                                .accessibilityLabel("Track \(number)")
                        } else {
                            Cover(track: track, radius: 8).frame(width: 44, height: 44)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title)
                            if layout != .album {
                                let subtitle = [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · ")
                                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .lineLimit(1)
                        Spacer(minLength: 4)
                        if track.duration > 0 {
                            Text(clock(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: layout == .standard ? nil : 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Menu("Options for \(track.title)", systemImage: "ellipsis") {
                    Button("Instant Mix", systemImage: "music.note.list") {
                        Task {
                            do { try await model.startInstantMix(from: track) }
                            catch { model.message = error.localizedDescription }
                        }
                    }
                    .disabled(model.isPreparingMix)
                    Button("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.playback.add(track, next: true) }
                    Button("Add to queue", systemImage: "text.append") { model.playback.add(track, next: false) }
                    let favorite = model.favorites.contains(track.id)
                    Button(favorite ? "Remove favorite" : "Favorite", systemImage: favorite ? "heart.slash" : "heart") {
                        model.toggleFavorite(track)
                    }
                    Menu("Add to playlist", systemImage: "music.note.list") {
                        Button("New playlist", systemImage: "plus") { name = ""; createWithTrack = track }
                        ForEach(model.playlists) { playlist in
                            Button(playlist.name) { model.addToPlaylist(track, id: playlist.id) }
                        }
                    }
                    if let localPlaylist {
                        Button("Remove from playlist", systemImage: "minus.circle", role: .destructive) {
                            model.removeFromPlaylist(track, id: localPlaylist)
                        }
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .tint(.primary)
            }
            .listRowBackground(model.playback.current?.id == track.id
                               ? Color.primary.opacity(0.10)
                               : (layout == .standard ? nil : Color.clear))
        }
        .alert("New playlist", isPresented: Binding(get: { createWithTrack != nil }, set: { if !$0 { createWithTrack = nil } }),
               presenting: createWithTrack) { track in
            TextField("Playlist name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Create") { model.createPlaylist(name, with: track) }
        }
    }
}

private struct LibraryEmpty: View {
    let importFiles: () -> Void
    @Environment(LibraryModel.self) private var model

    var body: some View {
        if model.importing {
            ProgressView("Importing music").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No music", systemImage: "music.note")
            } actions: {
                if model.activeServer == nil {
                    Button("Import files", systemImage: "square.and.arrow.down", action: importFiles)
                        .buttonStyle(.glassProminent)
                }
            }
        }
    }
}
