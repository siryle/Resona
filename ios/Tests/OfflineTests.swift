import Foundation
import CryptoKit
import AVFoundation

@main
struct OfflineTests {
    @MainActor static func main() async throws {
        let media = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resona-offline-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineStore(root: root)
        let cache = PlaybackCache(root: root.appendingPathComponent("playback-cache"))
        let library = LibraryModel(downloads: store, persistsSession: false, cache: cache)
        assert(library.session == nil && library.tracks.isEmpty)
        await library.refresh()
        assert(library.offline)
        library.serverInput = CommandLine.arguments[2]
        library.username = "admin"
        library.password = "test-password"
        await library.login()
        assert(library.session != nil && !library.offline && library.tracks.count == 1, library.error ?? "login failed")
        assert(library.artists.first?.artwork == "/api/v1/artists/avatar?name=Resona")
        let legacyArtist = try JSONDecoder().decode(Artist.self, from: Data(#"{"name":"Legacy","tracks":1}"#.utf8))
        assert(legacyArtist.artwork == nil, "Older servers must retain the initial placeholder")
        var avatarRequest = URLRequest(url: library.resource(library.artists[0].artwork!)!)
        avatarRequest.setValue("Bearer \(library.session!.token)", forHTTPHeaderField: "Authorization")
        let (avatarData, avatarResponse) = try await URLSession.shared.data(for: avatarRequest)
        assert((avatarResponse as? HTTPURLResponse)?.statusCode == 200 && !avatarData.isEmpty,
               "Artist artwork must retain authentication and reverse-proxy path prefixes")
        let track = library.tracks[0]
        let liked = await library.favorite(track)
        assert(liked?.favorite == true && library.tracks[0].favorite, "Favorite state did not update")
        library.tracks = []
        let unliked = await library.favorite(liked!)
        assert(unliked?.favorite == false && library.tracks.isEmpty, "Player favorite must work outside the visible library")
        library.tracks = [unliked!]
        assert(store.audio(track) == nil)
        let streaming = PlayerModel(downloads: store, cache: cache)
        streaming.volume = 0
        streaming.play(track, queue: [track], session: library.session)
        for _ in 0..<120 {
            if cache.audio(track) != nil && cache.bytes > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        assert(cache.audio(track) != nil && cache.bytes > 0, cache.message ?? streaming.error ?? "Played song was not cached")
        streaming.stop()
        let restoredCache = PlaybackCache(root: root.appendingPathComponent("playback-cache"))
        restoredCache.activate(library.session!)
        assert(restoredCache.audio(track) != nil, "Playback cache did not survive client restart")
        let otherServer = Session(server: library.session!.server.appendingPathComponent("other"), username: "admin", token: "other-token")
        restoredCache.activate(otherServer)
        assert(restoredCache.audio(track) == nil, "Playback cache leaked between servers")
        restoredCache.activate(library.session!)
        let cachedAudio = restoredCache.audio(track)!
        try Data("truncated".utf8).write(to: cachedAudio)
        assert(restoredCache.audio(track) == nil, "Truncated playback cache accepted")
        cache.start(track, session: library.session!)
        for _ in 0..<80 {
            if cache.audio(track) != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        assert(cache.audio(track) != nil, "Corrupt cache was not repaired")
        let wrong = root.appendingPathComponent("wrong.mp3")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("truncated".utf8).write(to: wrong)
        do {
            try store.save(track, temporary: wrong, cover: nil, lyrics: nil)
            assertionFailure("Incomplete audio was accepted")
        } catch {}
        let incomplete = try store.tracks()
        assert(incomplete.isEmpty)
        await library.download(track)
        assert(library.downloaded.count == 1, library.error ?? "download failed")
        assert(store.audio(track) != nil && store.sidecar(track.id, name: "cover") != nil && store.sidecar(track.id, name: "lyrics") != nil)
        let saved = try Data(contentsOf: store.audio(track)!)
        let original = try Data(contentsOf: media)
        assert(saved == original)
        let reloaded = LibraryModel(downloads: store, persistsSession: false, cache: cache)
        assert(reloaded.tracks.count == 1 && reloaded.albums.count == 1)
        await reloaded.refresh()
        assert(reloaded.session == nil && reloaded.offline && reloaded.tracks.count == 1 && reloaded.albums.count == 1)
        let cloudStore = OfflineStore(root: root.appendingPathComponent("cloud-downloads"))
        let cloudCache = PlaybackCache(root: root.appendingPathComponent("cloud-cache"))
        let cloudLibrary = LibraryModel(downloads: cloudStore, persistsSession: false, cache: cloudCache)
        cloudLibrary.session = library.session
        await cloudLibrary.selectLibrary("cloud")
        let cloud = cloudLibrary.tracks[0]
        let snapshotPlayer = PlayerModel(downloads: store, cache: cache)
        snapshotPlayer.volume = 0
        snapshotPlayer.play(track, queue: [cloud, track], session: library.session)
        snapshotPlayer.pause()
        snapshotPlayer.seek(3)
        snapshotPlayer.mode = .repeatAll
        snapshotPlayer.volume = 0.25
        snapshotPlayer.append([track], session: library.session)
        let restoredEngine = AVPlayer()
        let restoredPlayer = PlayerModel(downloads: store, cache: cache, player: restoredEngine)
        restoredPlayer.restorePlayback(session: library.session)
        assert(restoredPlayer.current == track && restoredPlayer.queue.map(\.id) == [cloud.id, track.id],
               "Restart lost the current song or queue order, including uncached cloud tracks")
        assert(restoredPlayer.position == 3 && restoredPlayer.duration == track.duration &&
               restoredPlayer.mode == .repeatAll && restoredPlayer.volume == 0.25,
               "Restart lost progress, playback mode or volume")
        assert(!restoredPlayer.playing && restoredEngine.currentItem == nil, "Restart unexpectedly opened audio")
        restoredPlayer.seek(4)
        restoredPlayer.restorePlayback(session: library.session)
        assert(restoredPlayer.position == 4, "A repeated startup task reset playback progress")
        restoredPlayer.resume()
        for _ in 0..<40 {
            if restoredEngine.currentTime().seconds >= 4 && restoredPlayer.playing { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        assert(restoredPlayer.isLocal && restoredEngine.currentItem != nil && restoredPlayer.playing &&
               restoredEngine.currentTime().seconds >= 4, restoredPlayer.error ?? "Restored song did not resume from saved progress")
        restoredPlayer.pause()
        let anotherAccount = PlayerModel(downloads: store, cache: cache)
        anotherAccount.restorePlayback(session: Session(server: library.session!.server, username: "other", token: "test-session"))
        assert(anotherAccount.current == nil && anotherAccount.queue.isEmpty, "Playback state leaked between accounts")
        let anotherServer = PlayerModel(downloads: store, cache: cache)
        anotherServer.restorePlayback(session: otherServer)
        assert(anotherServer.current == nil && anotherServer.queue.isEmpty, "Playback state leaked between servers")
        let snapshot = try Data(contentsOf: root.appendingPathComponent("playback.json"))
        assert(!String(decoding: snapshot, as: UTF8.self).contains("test-session"), "Playback snapshot stored credentials")
        restoredPlayer.stop()
        let stoppedPlayer = PlayerModel(downloads: store, cache: cache)
        stoppedPlayer.restorePlayback(session: nil)
        assert(stoppedPlayer.current == nil && stoppedPlayer.queue.isEmpty, "Restart resurrected stopped playback")
        try Data("{broken".utf8).write(to: root.appendingPathComponent("playback.json"))
        let damagedPlayer = PlayerModel(downloads: store, cache: cache)
        damagedPlayer.restorePlayback(session: library.session)
        assert(damagedPlayer.current == nil && damagedPlayer.queue.isEmpty, "Corrupt state prevented an empty startup")
        print("PASS: playback restart restores current song, ordered mixed-source queue, progress, mode and volume; lazy audio resumes from saved progress; account isolation, stopped and corrupt state")
        cloudCache.start(cloud, session: cloudLibrary.session!)
        for _ in 0..<80 {
            if cloudCache.audio(cloud) != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        assert(cloudCache.audio(cloud) != nil, cloudCache.message ?? "Cloud cache failed")
        assert(cloud.library == "cloud" && cloud.id != track.id && cloud.hashAlgorithm == "sha1")
        let artwork = cloudLibrary.resource("/api/v1/tracks/\(cloud.id)/cover?v=revision")!
        assert(artwork.path == "/music/api/v1/tracks/\(cloud.id)/cover" && artwork.query == "v=revision",
               "Versioned cloud artwork lost its query or server path prefix")
        do {
            try cloudStore.save(cloud, temporary: wrong, cover: nil, lyrics: nil)
            assertionFailure("Corrupt cloud audio was accepted")
        } catch {}
        await cloudLibrary.download(cloud)
        assert(cloudStore.audio(cloud) != nil, cloudLibrary.error ?? "302 cloud download failed")
        let cloudBytes = try Data(contentsOf: cloudStore.audio(cloud)!)
        assert(cloudBytes == original)
        await cloudLibrary.logout()
        assert(cloudLibrary.tracks.count == 1 && cloudLibrary.tracks[0].library == "cloud")
        await cloudLibrary.selectLibrary("local")
        assert(cloudLibrary.tracks.isEmpty && cloudLibrary.libraryDownloads.isEmpty,
               "Cloud downloads leaked into local library")
        cloudLibrary.removeDownload(cloud)
        await cloudLibrary.clearPlaybackCache()
        let player = PlayerModel(downloads: store, cache: cache)
        player.volume = 0
        player.play(track, queue: [track], session: nil)
        for _ in 0..<80 {
            if player.position > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        assert(player.isLocal && player.playing && player.position > 0, player.error ?? "offline playback did not start")
        assert(player.lyrics.count == 2)
        player.pause()
        assert(!player.playing)
        player.resume()
        assert(player.isLocal)
        _ = try await library.request("../../__expire", method: "POST")
        await library.refresh()
        assert(library.session == nil && library.offline && library.downloaded.count == 1)
        library.password = "test-password"
        await library.login()
        assert(library.session != nil && !library.offline)
        _ = try await library.request("../../__offline", method: "POST")
        await library.refresh()
        assert(library.offline && library.tracks.count == 1 && library.session != nil)
        let cachedPlayer = PlayerModel(downloads: OfflineStore(root: root.appendingPathComponent("empty")), cache: cache)
        cachedPlayer.volume = 0
        cachedPlayer.play(track, queue: [track], session: library.session)
        for _ in 0..<50 {
            if cachedPlayer.position > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        assert(cachedPlayer.isLocal && cachedPlayer.position > 0, "Cached song fetched unavailable server")
        cachedPlayer.stop()
        await library.clearPlaybackCache()
        assert(cache.audio(track) == nil && cache.bytes == 0 && store.audio(track) != nil,
               "Clearing playback cache removed explicit downloads")
        cache.start(track, session: library.session!)
        await cache.clear()
        try await Task.sleep(nanoseconds: 200_000_000)
        assert(cache.audio(track) == nil && cache.bytes == 0, "An in-flight task repopulated a cleared cache")
        await library.logout()
        player.connectionChanged(nil)
        assert(library.session == nil && library.tracks.count == 1 && library.downloaded.count == 1)
        assert(player.isLocal && player.current?.id == track.id)
        player.cycleMode(); assert(player.mode == .repeatAll)
        player.cycleMode(); assert(player.mode == .repeatOne)
        player.cycleMode(); assert(player.mode == .shuffle)
        player.next(automatic: true)
        assert(player.current?.id == track.id && player.position == 0, "Single-song shuffle must loop")
        player.cycleMode(); assert(player.mode == .sequential)
        player.append([track, track], session: nil)
        assert(player.queue.count == 1)
        player.seek(player.duration - 0.1)
        player.resume()
        for _ in 0..<30 {
            if !player.playing && player.position >= player.duration - 0.2 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        assert(!player.playing && player.position >= player.duration - 0.2, "playing=\(player.playing) position=\(player.position) duration=\(player.duration)")
        player.resume()
        for _ in 0..<30 {
            if player.position > 0 && player.position < 2 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        assert(player.playing && player.position < 2)
        player.stop()
        assert(player.current == nil && !player.playing)
        library.removeDownload(track)
        assert(library.downloaded.isEmpty && library.tracks.isEmpty && store.audio(track) == nil)
        assert(store.sidecar("../escape", name: "cover") == nil)
        assert(store.sidecar(track.id, name: "../../escape") == nil)
        print("PASS: authenticated download, SHA-256 integrity, persisted catalog/artwork/lyrics, offline startup, actual local playback, pause, repeat, server outage, offline logout and deletion")
        print("PASS: separate cloud library, 302 download, SHA-1 content verification independent of track ID, corrupt cloud audio rejection and scoped offline library")
        print("PASS: automatic playback cache, persistence, account/server isolation, truncated cache rejection/repair, cached playback during outage, clearing preserves downloads and cancels pending writes")
    }
}
