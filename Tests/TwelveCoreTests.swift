// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import TwelveCore

private func local(_ name: String) -> Track {
    Track(id: name, title: name, artist: "Twelve Fixtures", album: "Orbit", duration: 12,
          location: .local(file: name + ".mp3", artwork: nil))
}

final class QueueTests: XCTestCase {
    func testShuffledStartKeepsEveryTrackAndRestoresSequence() {
        var queue = PlaybackQueue()
        let tracks = ["A", "B", "C", "D"].map(local)
        queue.replace(tracks, start: 2, shuffle: true)
        XCTAssertEqual(queue.current?.track.id, "C")
        XCTAssertEqual(queue.index, 0)
        XCTAssertEqual(Set(queue.entries.map(\.track.id)), Set(tracks.map(\.id)))
        let current = queue.current?.id
        queue.toggleShuffle()
        XCTAssertEqual(queue.entries.map(\.track.id), tracks.map(\.id))
        XCTAssertEqual(queue.current?.id, current)
    }

    func testDuplicateTrackEntriesKeepTheirIdentityThroughEdits() throws {
        var queue = PlaybackQueue()
        queue.replace([local("A"), local("A"), local("B")], start: 1)
        let id = try XCTUnwrap(queue.current?.id)
        let other = queue.entries[0].id
        XCTAssertNotEqual(other, id)
        queue.add(local("C"), next: true)
        XCTAssertEqual(queue.entries.map(\.track.id), ["A", "A", "C", "B"])
        queue.move(id, by: 1)
        XCTAssertEqual(queue.current?.id, id)
        XCTAssertFalse(queue.remove(other))
        XCTAssertEqual(queue.current?.id, id)
        XCTAssertTrue(queue.remove(id))
        XCTAssertEqual(queue.current?.track.id, "B")
    }

    func testRepeatFlagsAndSnapshotRoundTrip() throws {
        var snapshot = PlaybackSnapshot()
        snapshot.queue.replace([local("A"), local("B")])
        snapshot.queue.repeatMode = .one
        XCTAssertTrue(snapshot.queue.advance(automatically: true))
        XCTAssertEqual(snapshot.queue.current?.track.id, "A")
        XCTAssertTrue(snapshot.queue.advance(automatically: false))
        XCTAssertFalse(snapshot.queue.advance(automatically: false))
        snapshot.queue.repeatMode = .all
        XCTAssertTrue(snapshot.queue.advance(automatically: true))
        XCTAssertEqual(snapshot.queue.current?.track.id, "A")
        snapshot.position = 4.5
        snapshot.speed = 1.5
        snapshot.entryCounted = true
        let roundtrip = try JSONDecoder().decode(PlaybackSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(roundtrip.queue.current?.id, snapshot.queue.current?.id)
        XCTAssertEqual(roundtrip.position, 4.5)
        XCTAssertEqual(roundtrip.speed, 1.5)
        XCTAssertTrue(roundtrip.entryCounted)
    }

    func testLocalSearchAccentAndStatistics() {
        let track = Track(id: "one", title: "Étoile", artist: "", album: "", genre: "Jazz", location: .local(file: "x", artwork: nil))
        XCTAssertTrue(track.matches("etoile"))
        XCTAssertTrue(track.matches("jazz"))
        var stats = PlayStatistics()
        let now = Date()
        stats.record(track.id, at: now)
        stats.record(track.id, at: now)
        XCTAssertEqual(stats.plays[track.id], 2)
        XCTAssertEqual(stats.lastPlayed[track.id], now)
    }
}

private struct TestTransport: HTTPTransport {
    let reply: @Sendable (URLRequest) throws -> Data

    func get(_ request: URLRequest) async throws -> Data { try reply(request) }
}

final class InstantMixTests: XCTestCase {
    func testRelatedTracksExcludeSeedDuplicatesAndUnrelatedSongs() {
        var seed = local("seed")
        seed.artist = "Beyoncé"
        seed.genre = "Pop"
        var both = local("both")
        both.artist = "Guest, BEYONCE"
        both.genre = " pop "
        var genreOnly = local("genre")
        genreOnly.genre = "Pop"
        let unrelated = local("unrelated")
        let candidates = [seed, genreOnly, unrelated, both, both]
        XCTAssertEqual(seed.relatedTracks(in: candidates, limit: 40).map(\.id), ["both", "genre"])
        XCTAssertEqual(seed.relatedTracks(in: candidates, limit: 1).map(\.id), ["both"])
    }
}

final class ProviderTests: XCTestCase, @unchecked Sendable {
    func testJellyfinInstantMixRequestAndDeduplication() async throws {
        var profile = ServerProfile(kind: .jellyfin, name: "Fixture",
                                    baseURL: try ServerAddress.parse("https://music.example.com/jellyfin"),
                                    username: "fixture")
        profile.userID = "listener"
        let transport = TestTransport { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/jellyfin/Songs/seed/InstantMix")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "userId" }?.value, "listener")
            XCTAssertEqual(query?.first { $0.name == "limit" }?.value, "2")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("fixture-token") == true)
            return Data(#"{"Items":[{"Id":"seed","Name":"Seed"},{"Id":"a","Name":"First"},{"Id":"a","Name":"Duplicate"},{"Id":"b","Name":"Second"},{"Id":"c","Name":"Third"}]}"#.utf8)
        }
        let seed = Track(id: "\(profile.id):seed", title: "Seed", artist: "Fixture", album: "Orbit",
                         location: .server(profile: profile.id, item: "seed", artwork: nil))
        let provider = JellyfinProvider(profile: profile, token: "fixture-token", transport: transport)
        let recommendations = try await provider.instantMix(from: seed, limit: 2)
        XCTAssertEqual(recommendations.map(\.title), ["First", "Second"])
    }

    func testServerAddressAndMD5Vectors() throws {
        XCTAssertEqual(try ServerAddress.parse(" https://music.example.com/jellyfin/// ").absoluteString, "https://music.example.com/jellyfin")
        XCTAssertNoThrow(try ServerAddress.parse("http://192.168.219.2:8096"))
        XCTAssertNoThrow(try ServerAddress.parse("http://[::1]:8096"))
        XCTAssertThrowsError(try ServerAddress.parse("http://music.example.com"))
        XCTAssertThrowsError(try ServerAddress.parse("https://music.example.com/#fragment"))
        XCTAssertThrowsError(try ServerAddress.parse("https://user:secret@music.example.com"))
        XCTAssertEqual(SubsonicMD5.hex(Data()), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(SubsonicMD5.hex(Data("abc".utf8)), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(SubsonicMD5.hex(Data(repeating: 97, count: 1_000)), "cabe45dcc9ae5b66ba86600cca6b8ba8")
    }

    func testJellyfinLoginBrowseSearchArtworkAndStreamRoutes() async throws {
        let transport = TestTransport { request in
            let url = try XCTUnwrap(request.url)
            let auth = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertTrue(auth.hasPrefix("MediaBrowser "))
            switch url.path {
            case "/jellyfin/Users/AuthenticateByName":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                let body = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(request.httpBody))
                XCTAssertEqual(body, ["Username": "fixture", "Pw": "test password"])
                return Data(#"{"AccessToken":"test-token","User":{"Id":"user-one"}}"#.utf8)
            case "/jellyfin/Items":
                XCTAssertTrue(auth.contains("Token=\"test-token\""))
                let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
                XCTAssertTrue(query.contains(URLQueryItem(name: "userId", value: "user-one")))
                if query.contains(URLQueryItem(name: "includeItemTypes", value: "Playlist")) {
                    return Data(#"{"Items":[{"Id":"playlist","Name":"Remote playlist"}],"TotalRecordCount":1}"#.utf8)
                }
                if query.contains(where: { $0.name == "searchTerm" }) {
                    XCTAssertTrue(query.contains(URLQueryItem(name: "searchTerm", value: "Tone + Orbit")))
                }
                fallthrough
            case "/jellyfin/Playlists/playlist/Items":
                return Data(#"{"Items":[{"Id":"track","Name":"Orbit Tone","Artists":["Fixture"],"Album":"Orbit","AlbumId":"art","AlbumPrimaryImageTag":"image","IndexNumber":1,"RunTimeTicks":120000000}],"TotalRecordCount":1}"#.utf8)
            default:
                XCTFail("Unexpected Jellyfin path \(url.path)")
                throw MusicError.unavailable
            }
        }
        let profile = ServerProfile(kind: .jellyfin, name: "Jellyfin", baseURL: try ServerAddress.parse("https://music.example.com/jellyfin"), username: "fixture")
        let (signedIn, token) = try await JellyfinProvider.connect(profile, password: "test password", transport: transport)
        XCTAssertEqual(signedIn.userID, "user-one")
        let provider = JellyfinProvider(profile: signedIn, token: token, transport: transport)
        let tracks = try await provider.library()
        let track = try XCTUnwrap(tracks.first)
        XCTAssertEqual(track.duration, 12)
        XCTAssertEqual(track.albumKey, "art")
        let search = try await provider.search("Tone + Orbit")
        XCTAssertEqual(search.first, track)
        let playlists = try await provider.playlists()
        let playlist = try XCTUnwrap(playlists.first)
        let contents = try await provider.tracks(in: playlist)
        XCTAssertEqual(contents.map(\.id), [track.id])
        let stream = try provider.stream(for: track)
        XCTAssertEqual(stream.path, "/jellyfin/Audio/track/stream")
        XCTAssertTrue(stream.query?.contains("static=true") == true)
        XCTAssertTrue(stream.query?.contains("api_key=test-token") == true)
        let art = try XCTUnwrap(provider.artwork(for: track))
        XCTAssertEqual(art.url?.path, "/jellyfin/Items/art/Images/Primary")
        XCTAssertNotNil(art.value(forHTTPHeaderField: "Authorization"))
    }

    func testJellyfinTimedPlainAndMissingLyrics() async throws {
        let profile = ServerProfile(kind: .jellyfin, name: "Fixture",
                                    baseURL: try XCTUnwrap(URL(string: "https://music.example.org/jellyfin")),
                                    username: "fixture", userID: "user")
        func song(_ item: String) -> Track {
            Track(id: item, title: item, artist: "", album: "", location: .server(profile: profile.id, item: item, artwork: nil))
        }
        let transport = TestTransport { request in
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("fixture-token") == true)
            switch request.url?.path {
            case "/jellyfin/Audio/timed/Lyrics":
                return Data(#"{"lyrics":[{"text":"첫 줄","start":12500000},{"text":"Second line","start":35000000},{"text":"","start":50000000}]}"#.utf8)
            case "/jellyfin/Audio/plain/Lyrics":
                return Data(#"{"Lyrics":[{"Text":"Untimed"},{"Text":"가사","Start":null}]}"#.utf8)
            default:
                throw MusicError.server(404)
            }
        }
        let provider = JellyfinProvider(profile: profile, token: "fixture-token", transport: transport)
        let timedResult = try await provider.lyrics(for: song("timed"))
        let timed = try XCTUnwrap(timedResult)
        XCTAssertEqual(timed.lines.first?.text, "첫 줄")
        XCTAssertEqual(timed.lines.first?.start, 1.25)
        XCTAssertNil(timed.activeLine(at: 1.24))
        XCTAssertEqual(timed.activeLine(at: 1.25), 0)
        XCTAssertEqual(timed.activeLine(at: 4), 1)
        XCTAssertEqual(timed.activeLine(at: 5), 2)
        let plainResult = try await provider.lyrics(for: song("plain"))
        let plain = try XCTUnwrap(plainResult)
        XCTAssertFalse(plain.isTimed)
        XCTAssertEqual(plain.lines.map(\.text), ["Untimed", "가사"])
        XCTAssertNil(plain.activeLine(at: 15))
        let missing = try await provider.lyrics(for: song("missing"))
        XCTAssertNil(missing)
    }

    func testSubsonicAuthAndID3Fallback() async throws {
        let transport = TestTransport { request in
            let url = try XCTUnwrap(request.url)
            let params = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            let salt = try XCTUnwrap(params.first(where: { $0.name == "s" })?.value)
            XCTAssertTrue(params.contains(URLQueryItem(name: "t", value: SubsonicMD5.hex(Data(("päss" + salt).utf8)))))
            XCTAssertFalse(params.contains { $0.name == "p" })
            let payload: String
            switch url.lastPathComponent {
            case "ping.view": payload = #"{"status":"ok"}"#
            case "search3.view":
                if params.contains(URLQueryItem(name: "query", value: "")) {
                    payload = #"{"status":"failed","error":{"code":10}}"#
                } else {
                    payload = #"{"status":"ok","searchResult3":{"song":[{"id":"song/one","title":"Lunar Tone","albumId":"album","coverArt":"cover"}]}}"#
                }
            case "getAlbumList2.view":
                payload = #"{"status":"ok","albumList2":{"album":[{"id":"album"}]}}"#
            case "getAlbum.view":
                payload = #"{"status":"ok","album":{"id":"album","song":[{"id":"song/one","title":"Lunar Tone","albumId":"album","coverArt":"cover"}]}}"#
            case "getPlaylists.view":
                payload = #"{"status":"ok","playlists":{"playlist":[{"id":"p1","name":"Fixture"}]}}"#
            case "getPlaylist.view":
                payload = #"{"status":"ok","playlist":{"id":"p1","name":"Fixture","entry":[{"id":"song/one","title":"Lunar Tone"}]}}"#
            default: throw MusicError.unavailable
            }
            return Data(("{\"subsonic-response\":" + payload + "}").utf8)
        }
        let profile = ServerProfile(kind: .subsonic, name: "Subsonic", baseURL: try ServerAddress.parse("https://music.example.com"), username: "me+test")
        let provider = SubsonicProvider(profile: profile, password: "päss", transport: transport)
        try await provider.ping()
        let tracks = try await provider.library()
        let track = try XCTUnwrap(tracks.first)
        let results = try await provider.search("Lunar + Tone")
        XCTAssertEqual(results, tracks)
        let playlists = try await provider.playlists()
        let playlist = try XCTUnwrap(playlists.first)
        let contents = try await provider.tracks(in: playlist)
        XCTAssertEqual(contents.first?.id, track.id)
        let stream = try provider.stream(for: track)
        let query = try XCTUnwrap(URLComponents(url: stream, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(query.contains(URLQueryItem(name: "u", value: "me+test")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "id", value: "song/one")))
        XCTAssertFalse(query.contains { $0.name == "f" })
        XCTAssertEqual(try provider.artwork(for: track)?.url?.path, "/rest/getCoverArt.view")
    }

    func testProviderMapsWrongCredentialsAndMalformedJSON() async throws {
        let profile = ServerProfile(kind: .subsonic, name: "Subsonic", baseURL: try ServerAddress.parse("https://music.example.com"), username: "fixture")
        let unauthorized = TestTransport { _ in Data(#"{"subsonic-response":{"status":"failed","error":{"code":40}}}"#.utf8) }
        do {
            try await SubsonicProvider(profile: profile, password: "wrong", transport: unauthorized).ping()
            XCTFail("Unauthorized response was accepted")
        } catch MusicError.unauthorized {}
        let invalid = TestTransport { _ in Data("invalid".utf8) }
        do {
            try await SubsonicProvider(profile: profile, password: "x", transport: invalid).ping()
            XCTFail("Malformed response was accepted")
        } catch MusicError.invalidResponse {}
    }

    func testLiveJellyfinAudioArtworkAndSearch() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["TWELVE_JELLYFIN_URL"], let user = env["TWELVE_JELLYFIN_USER"],
              let password = env["TWELVE_JELLYFIN_PASSWORD"] else {
            throw XCTSkip("Set TWELVE_JELLYFIN_URL, TWELVE_JELLYFIN_USER and TWELVE_JELLYFIN_PASSWORD to run.")
        }
        let profile = ServerProfile(kind: .jellyfin, name: "Jellyfin", baseURL: try ServerAddress.parse(url), username: user)
        let (signedIn, token) = try await JellyfinProvider.connect(profile, password: password)
        let provider = JellyfinProvider(profile: signedIn, token: token)
        let tracks = try await provider.library()
        let track = try XCTUnwrap(tracks.first(where: { $0.title == (env["TWELVE_JELLYFIN_TRACK"] ?? "Orbit Tone") }))
        let results = try await provider.search(track.title)
        XCTAssertTrue(results.contains { $0.id == track.id })
        XCTAssertGreaterThan(track.duration, 0)
        let transport = ServerTransport()
        var request = URLRequest(url: try provider.stream(for: track))
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        let audio = try await transport.get(request)
        XCTAssertGreaterThan(audio.count, 100)
        let art = try XCTUnwrap(provider.artwork(for: track))
        let image = try await transport.get(art)
        XCTAssertGreaterThan(image.count, 100)
        let playlists = try await provider.playlists()
        if let name = env["TWELVE_JELLYFIN_PLAYLIST"] {
            let playlist = try XCTUnwrap(playlists.first(where: { $0.name == name }))
            let contents = try await provider.tracks(in: playlist)
            XCTAssertTrue(contents.contains { $0.id == track.id })
        }
    }
}

final class FLACMetadataTests: XCTestCase {
    func testVorbisTagsPictureAndTruncation() throws {
        func le(_ value: Int) -> Data {
            Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        func be(_ value: Int) -> Data { Data(le(value).reversed()) }
        func field(_ text: String) -> Data { le(text.utf8.count) + Data(text.utf8) }
        let tags = field("Twelve") + le(3) + field("TiTlE=달빛") + field("TRACKNUMBER=2/3") + field("ALBUM=Orbit")
        let artwork = Data([0xff, 0xd8, 0xff, 0xd9])
        var picture = be(3) + be(10) + Data("image/jpeg".utf8)
        picture += be(0) + Data(repeating: 0, count: 16) + be(artwork.count) + artwork
        let streamInfo = Data([0, 0, 0, 34]) + Data(repeating: 0, count: 34)
        let vorbis = Data([4, 0, 0, UInt8(tags.count)]) + tags
        let cover = Data([0x86, 0, 0, UInt8(picture.count)]) + picture
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".flac")
        defer { try? FileManager.default.removeItem(at: file) }
        let header = Data("fLaC".utf8)
        try (header + streamInfo + vorbis + cover).write(to: file)
        let metadata = try XCTUnwrap(FLACMetadata.read(from: file))
        XCTAssertEqual(metadata.tags["TITLE"], "달빛")
        XCTAssertEqual(metadata.tags["TRACKNUMBER"], "2/3")
        XCTAssertEqual(metadata.artwork, artwork)
        try (header + streamInfo + vorbis + cover.dropLast(2)).write(to: file)
        XCTAssertEqual(FLACMetadata.read(from: file)?.tags["ALBUM"], "Orbit")
        XCTAssertNil(FLACMetadata.read(from: file)?.artwork)
    }
}
