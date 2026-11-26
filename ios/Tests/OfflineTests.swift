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
        let cachedFavorite = await library.favorite(track)!
        let savedDownloads = try store.tracks()
        let savedCache = try cache.store!.tracks()
        assert(cachedFavorite.favorite && library.downloaded[0].favorite &&
               savedDownloads[0].favorite && savedCache[0].favorite,
               "Favorite must reach both downloaded and automatically cached metadata")
        let freshCache = PlaybackCache(root: root.appendingPathComponent("playback-cache"))
        let cachedOnly = LibraryModel(downloads: OfflineStore(root: root.appendingPathComponent("empty-downloads")),
                                      persistsSession: false, cache: freshCache)
        assert(cachedOnly.session == nil && cachedOnly.tracks.filter(\.favorite).count == 1,
               "Offline restart lost automatically cached favorites")
        let cachedUnfavorite = await library.favorite(cachedFavorite)!
        let unlikedDownloads = try store.tracks()
        let unlikedCache = try cache.store!.tracks()
        assert(!cachedUnfavorite.favorite && !unlikedDownloads[0].favorite && !unlikedCache[0].favorite)
        assert(store.audio(track) != nil && cache.audio(track) != nil,
               "Favorite metadata update changed audio integrity")
        let identityData = try Data(contentsOf: root.appendingPathComponent("playback-cache").appendingPathExtension("identity.json"))
        assert(!String(decoding: identityData, as: UTF8.self).contains("test-session"),
               "Offline identity must never persist an authentication token")
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
        assert(PlayerModel.supportedPlaybackRates.count == 16 &&
               PlayerModel.supportedPlaybackRates.first == 0.5 &&
               PlayerModel.supportedPlaybackRates.last == 2.0,
               "Supported playback rates must span 0.5x to 2.0x in 0.1x steps")
        assert(PlayerModel.normalizePlaybackRate(0.1) == 0.5 &&
               PlayerModel.normalizePlaybackRate(3.0) == 2.0 &&
               PlayerModel.normalizePlaybackRate(.nan) == 1.0 &&
               PlayerModel.formatPlaybackRate(1.24) == "1.2x")
        snapshotPlayer.setPlaybackRate(1.4)
        snapshotPlayer.stepPlaybackRate(by: 1)
        assert(snapshotPlayer.playbackRate == 1.5)
        snapshotPlayer.stepPlaybackRate(by: -1)
        assert(snapshotPlayer.playbackRate == 1.4)
        snapshotPlayer.append([track], session: library.session)
        let restoredEngine = AVPlayer()
        let restoredPlayer = PlayerModel(downloads: store, cache: cache, player: restoredEngine)
        restoredPlayer.restorePlayback(session: library.session)
        assert(restoredPlayer.current == track && restoredPlayer.queue.map(\.id) == [cloud.id, track.id],
               "Restart lost the current song or queue order, including uncached cloud tracks")
        assert(restoredPlayer.position == 3 && restoredPlayer.duration == track.duration &&
               restoredPlayer.mode == .repeatAll && restoredPlayer.volume == 0.25 &&
               restoredPlayer.playbackRate == 1.4 && restoredEngine.defaultRate == 1.4,
               "Restart lost progress, playback mode, volume or playback rate")
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
               restoredEngine.currentTime().seconds >= 4 && abs(restoredEngine.rate - 1.4) < 0.01,
               restoredPlayer.error ?? "Restored song did not resume from saved progress at restored playback rate")
        restoredPlayer.pause()
        let snapshotData = try Data(contentsOf: root.appendingPathComponent("playback.json"))
        var legacyObject = try JSONSerialization.jsonObject(with: snapshotData) as! [String: Any]
        legacyObject.removeValue(forKey: "playbackRate")
        try JSONSerialization.data(withJSONObject: legacyObject).write(to: root.appendingPathComponent("playback.json"))
        let legacyPlayer = PlayerModel(downloads: store, cache: cache)
        legacyPlayer.restorePlayback(session: library.session)
        assert(legacyPlayer.playbackRate == 1.0, "Legacy snapshots without playbackRate must default to 1.0x")
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
        let expiredCache = PlaybackCache(root: root.appendingPathComponent("playback-cache"))
        let expiredRestart = LibraryModel(downloads: OfflineStore(root: root.appendingPathComponent("empty-downloads")),
                                          persistsSession: false, cache: expiredCache)
        assert(expiredRestart.session == nil && expiredRestart.tracks.count == 1,
               "Expired credentials hid automatic cache after process restart")
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

        // Session automatic renewal, legacy fallback, outage preservation, and 401 expiry handling
        let baseURL = URL(string: CommandLine.arguments[2])!
        func controlPost(_ path: String) async throws {
            var req = URLRequest(url: baseURL.appendingPathComponent(path))
            req.httpMethod = "POST"
            _ = try await URLSession.shared.data(for: req)
        }
        func refreshStats() async throws -> (refresh: Int, session: Int) {
            let (statsData, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("__refresh_stats"))
            let stats = try JSONDecoder().decode([String: Int].self, from: statsData)
            return (stats["refresh"] ?? 0, stats["session"] ?? 0)
        }
        try await controlPost("__online")
        let initialStats = try await refreshStats()
        let renewalLibrary = LibraryModel(downloads: store, persistsSession: false, cache: cache, sessionRenewalInterval: 0.15)
        renewalLibrary.serverInput = CommandLine.arguments[2]
        renewalLibrary.username = "admin"
        renewalLibrary.password = "test-password"
        await renewalLibrary.login()
        assert(renewalLibrary.session != nil && !renewalLibrary.offline)
        for _ in 0..<30 {
            if (try await refreshStats()).refresh > initialStats.refresh { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let afterPeriodic = try await refreshStats()
        assert(afterPeriodic.refresh > initialStats.refresh, "Periodic keepalive did not invoke /auth/refresh")

        try await controlPost("__legacy_refresh")
        await renewalLibrary.renewSessionIfNeeded(force: true)
        let afterFallback = try await refreshStats()
        assert(afterFallback.session > initialStats.session, "Older server 404 did not fall back to /auth/session")
        try await controlPost("__legacy_refresh")

        try await controlPost("__offline")
        renewalLibrary.error = nil
        await renewalLibrary.renewSessionIfNeeded(force: true)
        assert(renewalLibrary.session != nil && renewalLibrary.error == nil, "Transient outage cleared session or surfaced error")
        try await controlPost("__online")

        try await controlPost("__expire")
        await renewalLibrary.renewSessionIfNeeded(force: true)
        assert(renewalLibrary.session == nil && renewalLibrary.offline && renewalLibrary.downloaded.count == 1,
               "401 during renewal did not clear session while preserving offline downloads")

        library.removeDownload(track)
        assert(library.downloaded.isEmpty && library.tracks.isEmpty && store.audio(track) == nil)
        assert(store.sidecar("../escape", name: "cover") == nil)
        assert(store.sidecar(track.id, name: "../../escape") == nil)
        print("PASS: authenticated download, SHA-256 integrity, persisted catalog/artwork/lyrics, offline startup, actual local playback, pause, repeat, server outage, offline logout and deletion")
        print("PASS: separate cloud library, 302 download, SHA-1 content verification independent of track ID, corrupt cloud audio rejection and scoped offline library")
        print("PASS: automatic playback cache, persistence, account/server isolation, truncated cache rejection/repair, cached playback during outage, clearing preserves downloads and cancels pending writes")
        print("PASS: favorite metadata persists in downloads and automatic cache; tokenless restart restores automatic cache after expired credentials")
        print("PASS: Apple automatic session keepalive, legacy /auth/session fallback, transient outage preservation and 401 expiry handling")
    }
}
