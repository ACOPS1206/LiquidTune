// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct TwelveApp: App {
    @State private var model = LibraryModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TwelveRoot()
                .environment(model)
                .preferredColorScheme(model.appearance == .system ? nil : (model.appearance == .dark ? .dark : .light))
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { model.playback.save() }
                }
        }
    }
}

private enum AppTab: Hashable {
    case activity, library, search
}

struct BrowseDetail: Identifiable, Hashable {
    enum Destination {
        case tracks([Track])
        case album([Track])
        case localPlaylist(UUID)
        case serverPlaylist(ServerPlaylist)
    }

    let id = UUID()
    let title: String
    let subtitle: String
    let glyph: String
    let artwork: Track?
    let destination: Destination

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct TwelveRoot: View {
    @Environment(LibraryModel.self) private var model
    @State private var tab: AppTab = .activity
    @State private var activityPath: [BrowseDetail] = []
    @State private var libraryPath: [BrowseDetail] = []
    @State private var searchPath: [BrowseDetail] = []
    @State private var searchQuery = ""
    @State private var showSettings = false
    @State private var showPlayer = false
    @State private var showImport = false
    @State private var importFromSettings = false

    var body: some View {
        tabs
            .tint(.primary)
            .onChange(of: model.activeServer) { _, _ in
                activityPath.removeAll()
                libraryPath.removeAll()
                searchPath.removeAll()
            }
            .onChange(of: model.playback.current == nil) { _, empty in
                if empty { showPlayer = false }
            }
            .sheet(isPresented: $showSettings, onDismiss: finishSettings) {
                SettingsScreen(importFiles: {
                    importFromSettings = true
                    showSettings = false
                })
            }
            .fullScreenCover(isPresented: $showPlayer) {
                PlayerScreen()
            }
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.audio, UTType(filenameExtension: "flac") ?? .audio],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    model.selectSource(nil)
                    tab = .library
                    libraryPath.removeAll()
                    Task { await model.importFiles(urls) }
                case .failure(let error):
                    model.message = error.localizedDescription
                }
            }
            .alert("LiquidTune", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK") { model.message = nil }
            } message: {
                Text(model.message ?? "")
            }
    }

    private func finishSettings() {
        if importFromSettings {
            importFromSettings = false
            showImport = true
        }
    }

    @ViewBuilder private var tabs: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            tabContent.safeAreaBar(edge: .bottom, spacing: 0) {
                if let track = model.playback.current {
                    MiniPlayer(track: track) { showPlayer = true }
                        .frame(maxWidth: 520)
                        .glassEffect(.regular)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
        } else {
            tabContent
                .tabBarMinimizeBehavior(.onScrollDown)
                .tabViewBottomAccessory {
                    if let track = model.playback.current {
                        MiniPlayer(track: track) { showPlayer = true }
                    }
                }
        }
    }

    private var tabContent: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: .activity) {
                page("Home", path: $activityPath) {
                    HomeScreen(open: { activityPath.append($0) }, importFiles: { showImport = true })
                }
            }
            Tab("Library", systemImage: "music.note.list", value: .library) {
                page(nil, path: $libraryPath) {
                    LibraryScreen(open: { libraryPath.append($0) }, importFiles: { showImport = true })
                }
            }
            Tab(value: .search, role: .search) {
                page("Search", path: $searchPath) {
                    SearchScreen(query: searchQuery, open: { searchPath.append($0) })
                }
                .searchable(text: $searchQuery, prompt: "Songs, albums, artists")
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSearchActivation(.searchTabSelection)
    }

    @ViewBuilder private func browseDestination(_ target: BrowseDetail) -> some View {
        if case let .tracks(tracks) = target.destination {
            DetailScreen(detail: target, tracks: tracks)
        } else {
            CollectionDetailScreen(detail: target)
        }
    }

    private func page<Content: View>(_ title: String?, path: Binding<[BrowseDetail]>, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack(path: path) {
            content()
                .safeAreaInset(edge: .top, spacing: 0) { sourceStatus }
                .navigationTitle(title ?? "")
                .navigationSubtitle(title == nil ? "" : model.sourceName)
                .navigationDestination(for: BrowseDetail.self, destination: browseDestination)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { sourceMenu }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") { showSettings = true }
                    }
                }
        }
    }

    private var sourceMenu: some View {
        Menu {
            Picker("Music source", selection: Binding(get: { model.activeServer }, set: { model.selectSource($0) })) {
                Label("On this device", systemImage: "iphone").tag(nil as UUID?)
                ForEach(model.servers) { server in
                    Label(server.name, systemImage: "music.note.house").tag(Optional(server.id))
                }
            }
            if let id = model.activeServer {
                Button("Refresh library", systemImage: "arrow.clockwise") { model.requestRefresh(id) }
            }
            Button("Manage sources", systemImage: "gearshape") { showSettings = true }
        } label: {
            Label(model.sourceName, systemImage: model.activeServer == nil ? "iphone" : "music.note.house")
                .labelStyle(.iconOnly)
        }
        .accessibilityLabel("Music source, \(model.sourceName)")
    }

    @ViewBuilder private var sourceStatus: some View {
        if let id = model.activeServer {
            if model.loading.contains(id) {
                ProgressView("Updating library")
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            if let message = model.sourceMessages[id] {
                HStack {
                    Text(message).font(.footnote)
                    Spacer(minLength: 6)
                    Button("Retry") { model.requestRefresh(id) }.buttonStyle(.glass)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
        }
    }
}

private struct MiniPlayer: View {
    let track: Track
    let open: () -> Void
    @Environment(LibraryModel.self) private var model
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var inline: Bool { placement == .inline }

    var body: some View {
        let playback = model.playback
        let active = playback.playing || playback.waiting
        HStack(spacing: 6) {
            Button(action: open) {
                HStack(spacing: inline ? 6 : 10) {
                    Cover(track: track, knownImage: playback.artwork, radius: inline ? 5 : 8)
                        .frame(width: inline ? 24 : 38, height: inline ? 24 : 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                        if !inline && !track.artist.isEmpty {
                            Text(track.artist).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, inline ? 2 : 5)
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Now playing, \(track.title)")
            Button {
                playback.toggle()
            } label: {
                if playback.waiting {
                    ProgressView().controlSize(.small).frame(width: 24)
                } else {
                    Image(systemName: active ? "pause.fill" : "play.fill")
                        .font(.body.weight(.semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 24)
                }
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityLabel(active ? "Pause" : "Play")
            if !inline {
                Button("Next", systemImage: "forward.end.fill") { playback.next() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .frame(minWidth: 35, minHeight: 44)
            }
        }
        .padding(.horizontal, inline ? 7 : 12)
    }
}
