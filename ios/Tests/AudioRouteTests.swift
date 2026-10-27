import AVFoundation
import CryptoKit
import Foundation
import SwiftUI

@main
struct AudioRouteTests: App {
    var body: some Scene {
        WindowGroup {
            Color.clear.task {
                do {
                    try await Self.run()
                    fflush(stdout)
                    exit(EXIT_SUCCESS)
                } catch {
                    print("FAIL: \(error)")
                    fflush(stdout)
                    exit(EXIT_FAILURE)
                }
            }
        }
    }

    @MainActor static func run() async throws {
        let media = Bundle.main.url(forResource: "song", withExtension: "mp3")!
        let data = try Data(contentsOf: media)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resona-route-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineStore(root: root)
        let track = Track(
            id: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            title: "Route Test", artist: "Resona", albumArtist: "Resona", album: "Tests",
            year: "2026", number: 1, disc: 1, duration: 60, format: "mp3",
            bitrate: 128000, sampleRate: 44100, artwork: nil, favorite: false
        )
        try store.save(track, temporary: media, cover: nil, lyrics: nil)
        let engine = AVPlayer()
        let player = PlayerModel(downloads: store, cache: PlaybackCache(root: root.appendingPathComponent("cache")), player: engine)
        player.volume = 0
        player.play(track, queue: [track], session: nil)
        await settle()
        assert(engine.rate > 0, player.error ?? "Playback did not start")
        let session = AVAudioSession.sharedInstance()
        assert(session.category == .playback && session.routeSharingPolicy == .longFormAudio,
               "Music must participate in the system long-form audio route")

        for reason in [AVAudioSession.RouteChangeReason.newDeviceAvailable, .routeConfigurationChange] {
            // AVPlayer can pause independently of the user's playback intent during a route transition.
            engine.pause()
            await settle()
            assert(!player.playing)
            await route(reason)
            assert(engine.rate > 0 && player.playing, "Active playback did not recover after \(reason)")
        }

        player.pause()
        await route(.newDeviceAvailable)
        await route(.routeConfigurationChange)
        assert(engine.rate == 0 && !player.playing, "Connecting headphones restarted user-paused audio")

        player.resume()
        await route(.oldDeviceUnavailable)
        assert(engine.rate == 0 && !player.playing, "Headphone removal did not pause playback")
        await route(.newDeviceAvailable)
        await route(.routeConfigurationChange)
        assert(engine.rate == 0, "Reconnecting headphones restarted disconnected audio")

        player.resume()
        await interruption(.began)
        await route(.newDeviceAvailable)
        await route(.routeConfigurationChange)
        assert(engine.rate == 0, "A route change resumed audio during an interruption")
        await interruption(.ended, options: [.shouldResume])
        assert(engine.rate > 0, "Resumable interruption lost playback intent")

        await interruption(.began)
        await interruption(.ended)
        await route(.newDeviceAvailable)
        assert(engine.rate == 0, "A non-resumable interruption restarted audio")

        player.resume()
        await interruption(.began)
        player.pause()
        await interruption(.ended, options: [.shouldResume])
        await route(.newDeviceAvailable)
        assert(engine.rate == 0, "Pausing during an interruption lost user intent")

        player.resume()
        engine.pause()
        await route(.categoryChange)
        await route(.override)
        assert(engine.rate == 0, "An unrelated route notification restarted audio")
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: session,
                                        userInfo: [AVAudioSessionRouteChangeReasonKey: UInt.max])
        await settle()
        assert(engine.rate == 0, "An unknown route notification restarted audio")
        player.stop()
        await route(.newDeviceAvailable)
        assert(engine.currentItem == nil && !player.playing, "A route notification restarted stopped audio")
        print("PASS: iOS music routing, device connection/configuration recovery, disconnect pause, user pause, interruptions and stopped playback")
    }

    @MainActor static func route(_ reason: AVAudioSession.RouteChangeReason) async {
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(),
                                        userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
        await settle()
    }

    @MainActor static func interruption(_ type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions = []) async {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                                        userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue,
                                                   AVAudioSessionInterruptionOptionKey: options.rawValue])
        await settle()
    }

    static func settle() async {
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
}
